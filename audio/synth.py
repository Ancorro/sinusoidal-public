"""Synthesizes the sounds no CC0 pack had a good match for: clockwork ticking, wire snip, candle out, cabin ambience.

Run: python audio/synth.py  (needs numpy, scipy, soundfile with libsndfile >= 1.0.29 for OGG Vorbis).
Writes .ogg files next to this script. Fixed seed, so reruns give the same files. Then remove the one-shots it wrote
from audio/mastered.txt and run audio/master.py.
"""
import os

import numpy as np
import soundfile as sf
from scipy.signal import butter, sosfilt

SR = 44100
OUT = os.path.dirname(os.path.abspath(__file__))
rng = np.random.default_rng(7)


def t(sec):
    return np.arange(int(sec * SR)) / SR


def band(x, lo, hi, order=2):
    return sosfilt(butter(order, [lo, hi], "bandpass", fs=SR, output="sos"), x)


def low(x, f, order=2):
    return sosfilt(butter(order, f, "lowpass", fs=SR, output="sos"), x)


def high(x, f, order=2):
    return sosfilt(butter(order, f, "highpass", fs=SR, output="sos"), x)


def place(buf, clip, at):
    i = int(at * SR)
    n = min(len(clip), len(buf) - i)
    buf[i:i + n] += clip[:n]


def norm(x, peak=0.8):
    return x * (peak / (np.abs(x).max() + 1e-9))


def save(name, x, quality=0.4):
    x = np.clip(x, -1, 1).astype(np.float32)
    # written in blocks: one big Vorbis write overflows libsndfile's stack on Windows
    with sf.SoundFile(os.path.join(OUT, name), "w", SR, 1, format="OGG", subtype="VORBIS",
                      compression_level=1 - quality) as f:
        for i in range(0, len(x), SR // 4):
            f.write(x[i:i + SR // 4])
    print(name, round(len(x) / SR, 2), "s", os.path.getsize(os.path.join(OUT, name)), "bytes")


def save_loop(name, x, tries=16):
    """Save a seamless loop. Vorbis smears the first and last samples differently, which can leave a step at the
    seam bigger than any inside the file (a faint click every lap); rotating the loop moves the seam, so try a few
    rotations and keep the one whose decoded seam step is smallest relative to the file's own 99.9th percentile."""
    path = os.path.join(OUT, name)
    best = None
    for k in range(tries):
        save(name, np.roll(x, k * len(x) // tries))
        y, _ = sf.read(path)
        score = abs(y[-1] - y[0]) / np.percentile(np.abs(np.diff(y)), 99.9)
        if best is None or score < best[0]:
            best = (score, k, open(path, "rb").read())
    open(path, "wb").write(best[2])
    print(name, "seam step", round(best[0], 2), "x the file's p99.9 step (rotation", best[1], "of", tries, ")")


def click(freqs, dur=0.05, decay=120.0, noise=0.5):
    """A small metallic click: a noise transient plus a few quickly damped resonances."""
    tt = t(dur)
    env = np.exp(-tt * decay)
    tone = sum(np.sin(2 * np.pi * f * tt + rng.uniform(0, 6)) / (k + 1) for k, f in enumerate(freqs))
    n = high(rng.standard_normal(len(tt)), 2000) * np.exp(-tt * decay * 3)
    return env * tone + noise * n


def ticking():
    """Two-second seamless loop: tick-tock escapement, a faint gear whir underneath."""
    L = 2.0
    buf = np.zeros(int(L * SR))
    for k in range(4):
        hi = k % 2 == 0
        c = click([3100, 4700, 6900] if hi else [2500, 3900, 5600], decay=140 if hi else 110)
        place(buf, c * (1.0 if hi else 0.8), k * 0.5 + 0.01)
        # the escapement's soft second contact just after each tick
        place(buf, click([1800, 2900], decay=200, noise=0.2) * 0.25, k * 0.5 + 0.045)
    tt = t(L)
    # whir at 2 Hz wobble; whole cycles over the loop so it wraps cleanly
    whir = band(rng.standard_normal(len(tt)), 600, 1400) * (0.5 + 0.5 * np.sin(2 * np.pi * 2 * tt)) * 0.04
    buf += whir
    return norm(buf, 0.79)  # loops leave synth mastered (-2 dBFS peak); master.py skips them


def snip():
    """Shears closing on a wire: blade scrape, a hard snap, then the cut ends twanging."""
    buf = np.zeros(int(0.7 * SR))
    tt = t(0.07)
    scrape = band(rng.standard_normal(len(tt)), 3000, 9000) * np.linspace(0.2, 1, len(tt)) * 0.3
    place(buf, scrape, 0.0)
    place(buf, click([2200, 5100, 8300], dur=0.08, decay=90, noise=1.2), 0.07)
    tw = t(0.6)
    twang = (np.sin(2 * np.pi * 180 * tw + 3 * np.sin(2 * np.pi * 9 * tw)) * 0.5
             + np.sin(2 * np.pi * 361 * tw) * 0.3) * np.exp(-tw * 7) * 0.35
    place(buf, twang, 0.08)
    return norm(buf, 0.8)


def candle_out():
    """A short breath that snuffs the flame, then a tiny wick hiss."""
    L = 1.1
    tt = t(L)
    n = rng.standard_normal(len(tt))
    puff_env = np.clip(tt / 0.04, 0, 1) * np.exp(-np.clip(tt - 0.04, 0, None) * 9)
    puff = low(band(n, 150, 1800), 1200) * puff_env
    hiss_env = np.exp(-((tt - 0.35) / 0.18) ** 2) * 0.12
    hiss = high(rng.standard_normal(len(tt)), 5000) * hiss_env
    return norm(puff + hiss, 0.7)


def ambience():
    """Twenty-second loop of a quiet cabin: low room rumble and wind breathing at the walls."""
    L = 20.0
    pad = 2.0
    tt = t(L + pad)
    brown = np.cumsum(rng.standard_normal(len(tt)))
    brown = high(brown, 20)
    rumble = low(brown, 160) * 0.002
    # wind: band noise whose loudness drifts slowly; 0.05 and 0.15 Hz make whole cycles in 20 s
    gust = 0.55 + 0.3 * np.sin(2 * np.pi * 0.05 * tt) + 0.15 * np.sin(2 * np.pi * 0.15 * tt + 1)
    wind = band(rng.standard_normal(len(tt)), 250, 900) * gust * 0.12
    x = rumble / (np.abs(rumble).max() + 1e-9) + wind
    # crossfade the padded tail into the head so the loop is seamless
    n = int(pad * SR)
    head, body = x[:n], x[n:]
    fade = np.linspace(0, 1, n)
    body[-n:] = body[-n:] * (1 - fade) + head * fade
    return norm(body, 0.79)


if __name__ == "__main__":
    save_loop("clock_tick_loop.ogg", ticking())
    save("wire_snip.ogg", snip())
    save("candle_out.ogg", candle_out())
    save_loop("cabin_ambience.ogg", ambience())
