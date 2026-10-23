"""Strength sweep: same seed and question at each strength, so differences come from the wire, not sampling."""
import sys

from brain import SYSTEM, Brain

wires = sys.argv[1].split(",")
strengths = [float(s) for s in sys.argv[2].split(",")]
QS = ["Who are you?", "Will you go easy on me this round?"]
b = Brain()
for wid in wires:
    w = next(x for x in b.wires if x["id"] == wid)
    for s in [0.0] + strengths:
        w["strength"] = s
        b.set_cut([wid] if s else [])
        for q in QS:
            r = b.reply([{"role": "system", "content": SYSTEM}, {"role": "user", "content": q}], max_new=50, seed=1)
            print(f"[{wid} {w['name']} x{s}] Q: {q}\n   A: {r}", flush=True)
