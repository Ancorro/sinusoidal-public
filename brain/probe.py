"""Gate check before any game code: does cutting each wire visibly change the dealer's replies?"""
import sys
import time

from brain import SYSTEM, Brain
QS = ["Who are you?", "Will you go easy on me this round?", "What card are you holding?"]

t = time.time()
b = Brain()
print(f"loaded + directions in {time.time() - t:.0f}s", flush=True)
for wire in [None] + [w["id"] for w in b.wires]:
    b.set_cut([] if wire is None else [wire])
    print(f"\n=== cut: {wire or 'none'}", flush=True)
    for q in QS:
        r = b.reply([{"role": "system", "content": SYSTEM}, {"role": "user", "content": q}], max_new=60)
        print(f"Q: {q}\nA: {r}", flush=True)
