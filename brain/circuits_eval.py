"""How faithful and how fast is brain/circuits.py? Runs /move then the trace on saved move requests, with no wires cut
and with two cut, and reports per move: time, the feature attributions next to their measured ablations, and occlusion
next to gradient x input. Writes every trace to the output folder (one can be served by stub_server.py --trace).

Run: python circuits_eval.py moves.json outdir      (moves.json from scripts/trace_moves.gd)
"""
import json
import statistics as st
import sys
import time
from pathlib import Path

argv, sys.argv = sys.argv, sys.argv[:1]   # server.py reads a port from argv
import server   # noqa: E402  the brain and tracer, no HTTP

moves = json.load(open(argv[1]))
out = Path(argv[2])
out.mkdir(parents=True, exist_ok=True)
rows = []
for cut in ([], ["red", "green"]):
    server.brain.set_cut(set(cut))
    for k, mv in enumerate(moves):
        r = server.choose_move(mv["board"], mv["options"], mv["allow_pass"])
        t = time.time()
        tr = server.tracer.trace()
        dt = time.time() - t
        name = f"trace_{'cut' if cut else 'intact'}_{k:02d}.json"
        json.dump({"move": mv, "answer": r, "trace": tr}, open(out / name, "w"), indent=1)
        if not tr.get("ok"):
            print(f"{name}: no trace ({tr.get('why')}), raw {r['raw']!r}", flush=True)
            continue
        pairs = [(f["attr"], f["ablated"]) for f in tr["features"]]
        rows.append({"name": name, "s": dt, "pairs": pairs, "agree": tr["agreement"], "metric": tr["metric"],
                     "wires": tr["wires"], "timing": tr["timing"]})
        top = max(tr["segments"], key=lambda s: abs(s["effect"]))
        print(f"{name}: {dt:.1f}s {tr['timing']} chose {tr['number']} p={tr['options'][tr['chosen']]['p']} "
              f"m={tr['metric']} top line {top['name']} {top['effect']:+.2f} occl~gxi {tr['agreement']} "
              f"feat pred/abl {[(round(a, 2), round(b, 2)) for a, b in pairs]} wires {tr['wires']}", flush=True)

first = rows[1:] if len(rows) > 1 else rows   # the first trace also loads the autoencoders
print(f"\n{len(rows)} traces; seconds median {st.median(r['s'] for r in first):.1f}, max {max(r['s'] for r in first):.1f}")
pa = [p for r in rows for p in r["pairs"]]
if len(pa) > 2:
    import torch
    a, b = torch.tensor(pa).T
    print(f"features: predicted vs ablated, Pearson {float(torch.corrcoef(torch.stack([a, b]))[0, 1]):.2f}, "
          f"sign agreement {float(((a > 0) == (b > 0)).float().mean()):.2f}, n {len(pa)}")
ag = [r["agree"] for r in rows if r["agree"] is not None]
if ag:
    print(f"lines: occlusion vs gradient x input rank correlation, median {st.median(ag):.2f}")
