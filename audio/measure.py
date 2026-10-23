"""Loudness audit of every clip in audio/: integrated LUFS (short clips padded so the 400 ms gate sees them), RMS,
peak, clipped samples, DC offset, first and last sample (clicks), length, and loudness after sfx.gd's VOLUME_DB.

Run: python audio/measure.py  (needs numpy, soundfile, pyloudnorm).
"""
import glob
import os
import re
import sys

import numpy as np
import soundfile as sf

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from master import lufs  # noqa: E402

HERE = os.path.dirname(os.path.abspath(__file__))
SFX = os.path.join(HERE, "..", "scripts", "sfx.gd")


def db(x):
    return 20 * np.log10(max(x, 1e-9))


def gains():
    """file -> dB from VOLUME_DB / _looping() in sfx.gd, so the table shows what the player hears."""
    src = open(SFX, encoding="utf-8").read()
    sounds = dict(re.findall(r'"(\w+)": \[([^\]]*)\]', src.split("const VOLUME_DB")[0]))
    vol = {k: float(v) for k, v in re.findall(r'"(\w+)": (-?[\d.]+)', re.search(r"VOLUME_DB := \{(.*?)\}", src, re.S).group(1))}
    out = {}
    for key, files in sounds.items():
        for f in re.findall(r'"(\w+)"', files):
            out[f] = vol.get(key, 0.0)
    for f, const in re.findall(r'_looping\("(\w+)", (\w+)\)', src):
        out[f] = float(re.search(const + r" := (-?[\d.]+)", src).group(1))
    m = re.search(r"lamp\.volume_db = randf_range\((-?[\d.]+), (-?[\d.]+)\)", src)
    if m:
        out["lamp_creak"] = (float(m.group(1)) + float(m.group(2))) / 2
    return out


if __name__ == "__main__":
    g = gains()
    print(f"{'file':22}{'sec':>6}{'ch':>3}{'LUFS':>7}{'RMS':>7}{'peak':>7}{'clip':>5}{'DC':>8}{'start':>7}{'end':>7}"
          f"{'gain':>6}{'heard':>7}")
    for p in sorted(glob.glob(os.path.join(HERE, "*.ogg"))):
        x, sr = sf.read(p, always_2d=True)
        name = os.path.basename(p)[:-4]
        mono = x.mean(1)
        L = lufs(x, sr)
        gain = g.get(name, 0.0)
        print(f"{name:22}{len(x) / sr:6.2f}{x.shape[1]:3d}{L:7.1f}{db(np.sqrt((mono ** 2).mean())):7.1f}"
              f"{db(np.abs(x).max()):7.1f}{int((np.abs(x) >= 0.999).sum()):5d}{mono.mean():8.4f}"
              f"{abs(mono[0]):7.3f}{abs(mono[-1]):7.3f}{gain:6.1f}{L + gain:7.1f}")
