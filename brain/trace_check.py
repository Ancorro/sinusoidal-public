"""Trace one Dealer move without the server, print the graph and timings. Short local check (one model copy).

Run: python trace_check.py move.json [out.json] [--cut red,blue]
move.json: {"board": ..., "options": [...], "allow_pass": true}, the body /move takes.
"""
import json
import sys
import time

argv, sys.argv = sys.argv, sys.argv[:1]   # server.py reads a port from argv
import server   # noqa: E402  loads the brain once; the HTTP server only starts under __main__
sys.argv = argv

args = [a for a in sys.argv[1:] if not a.startswith("--")]
cut = next((a.split("=", 1)[1] for a in sys.argv if a.startswith("--cut=")), "")
if cut:
    server.brain.set_cut(set(cut.split(",")))
req = json.load(open(args[0]))
mv = server.choose_move(req["board"], req["options"], req.get("allow_pass", True))
print("move", mv)
for k in range(2):   # the first trace also loads the autoencoders
    t = time.time()
    tr = server.tracer.trace()
    print(f"trace {k}: {time.time() - t:.1f}s {tr.get('timing')}")
if len(args) > 1:
    json.dump(tr, open(args[1], "w"), indent=1)
if not tr["ok"]:
    sys.exit(tr["why"])
print(f"chose {tr['number']} ({tr['label']}), m = {tr['metric']}, options",
      [(o["number"], o["p"]) for o in tr["options"]])
for s in sorted(tr["segments"], key=lambda s: -abs(s["effect"])):
    print(f"  {s['effect']:+.3f}  gxi {s['grad_x_input']:+.3f}  {s['name']}")
print("  occlusion vs gradient x input rank agreement:", tr["agreement"])
for f in tr["features"]:
    print(f"  L{f['layer']}#{f['id']} act {f['act']:.2f} predicted {f['attr']:+.3f} ablated {f['ablated']:+.3f} "
          f"reads {f['reads']} says {f['says']}")
print("  errors", tr["errors"])
print("  wires", tr["wires"])
