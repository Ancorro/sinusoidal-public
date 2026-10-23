"""Masters every clip in audio/ in place, so the mix lives in one place (VOLUME_DB in scripts/sfx.gd):

- one-shots: trim leading and trailing silence (-55 dB), 2 ms fade in, 25 ms fade out, peak limit to -2 dBFS, then
  normalise to -16 LUFS (the limiter pulls in spiky clips like the bell so they can get there);
- loops (LOOPS) are skipped: synth.py writes them seamless and at -2 dBFS peak, and a second lossy encode would
  disturb the seam; their level is set by the gain in sfx.gd;
- one-shots re-encoded as Vorbis quality 0.4.

Run after audio/synth.py: python audio/master.py. Mastered files are listed in audio/mastered.txt and skipped, so no
clip is re-encoded twice; delete a line (or regenerate the file) to master it again. Loudness is measured with mono counted as both speakers, as Godot plays it.
"""
import glob
import os

import numpy as np
import pyloudnorm as pyln
import soundfile as sf

HERE = os.path.dirname(os.path.abspath(__file__))
LOOPS = {"cabin_ambience", "clock_tick_loop"}
TARGET_LUFS = -16.0
CEILING = 10 ** (-2.0 / 20)  # Vorbis overshoots by up to ~1 dB on transients
SILENCE_DB = -55.0
MANIFEST = os.path.join(HERE, "mastered.txt")


def lufs(x, sr):
    """Integrated loudness of x (frames, channels); mono counts twice; short clips padded past the 400 ms block and
    the padding's dilution undone."""
    if x.shape[1] == 1:
        x = np.repeat(x, 2, 1)
    n = max(len(x), int(0.4 * sr))
    pad = np.zeros((n, x.shape[1]))
    pad[:len(x)] = x
    v = pyln.Meter(sr).integrated_loudness(pad)
    return v + 10 * np.log10(n / len(x))


def trim(x, sr):
    level = np.abs(x).max(1)
    on = level > level.max() * 10 ** (SILENCE_DB / 20)
    a = max(int(np.argmax(on)) - int(0.001 * sr), 0)
    b = min(len(x) - int(np.argmax(on[::-1])) + int(0.02 * sr), len(x))
    return x[a:b]


def fade(x, sr, fin=0.002, fout=0.025):
    x = x.copy()
    i, o = int(fin * sr), int(fout * sr)
    x[:i] *= np.linspace(0, 1, i)[:, None]
    x[-o:] *= np.linspace(1, 0, o)[:, None] ** 2
    return x


def limit(x, sr, ceiling=CEILING, look=0.002, release=0.06):
    """Look-ahead peak limiter: gain drops ahead of each peak, recovers over `release`. Final clip is a safety net."""
    need = np.minimum(1.0, ceiling / np.maximum(np.abs(x).max(1), 1e-9))
    la = int(look * sr)
    # minimum of the next `la` samples, so the gain is already down when the peak arrives
    padded = np.concatenate([need, np.ones(la)])
    ahead = np.lib.stride_tricks.sliding_window_view(padded, la + 1).min(1)
    g = np.empty_like(ahead)
    att, rel = np.exp(-1 / (0.0005 * sr)), np.exp(-1 / (release * sr))
    cur = 1.0
    for n, t in enumerate(ahead):
        cur = t + (cur - t) * (att if t < cur else rel)
        g[n] = min(cur, t)
    return np.clip(x * g[:, None], -ceiling, ceiling)


def master(x, sr):
    x = fade(trim(x, sr), sr)
    # normalise, limit, renormalise: limiting lowers loudness, so repeat until it holds
    for _ in range(12):
        x = limit(x * 10 ** ((TARGET_LUFS - lufs(x, sr)) / 20), sr)
        if abs(lufs(x, sr) - TARGET_LUFS) < 0.3:
            break
    return x


def write(path, x, sr):
    with sf.SoundFile(path, "w", sr, x.shape[1], format="OGG", subtype="VORBIS", compression_level=0.6) as f:
        # blocks: one big Vorbis write overflows libsndfile's stack on Windows
        for i in range(0, len(x), sr // 4):
            f.write(x[i:i + sr // 4].astype(np.float32))


if __name__ == "__main__":
    done = set(open(MANIFEST).read().split()) if os.path.exists(MANIFEST) else set()
    for p in sorted(glob.glob(os.path.join(HERE, "*.ogg"))):
        name = os.path.basename(p)[:-4]
        if name in LOOPS or name in done:
            print(f"{name:20} skipped ({'loop' if name in LOOPS else 'already mastered'})")
            continue
        x, sr = sf.read(p, always_2d=True)
        before = lufs(x, sr)
        y = master(x, sr)
        write(p, y, sr)
        done.add(name)
        open(MANIFEST, "w").write("\n".join(sorted(done)) + "\n")
        z, _ = sf.read(p, always_2d=True)
        print(f"{name:20} {len(x) / sr:5.2f}s -> {len(z) / sr:5.2f}s  {before:6.1f} -> {lufs(z, sr):6.1f} LUFS  "
              f"peak {20 * np.log10(np.abs(z).max()):5.1f} dBFS")
