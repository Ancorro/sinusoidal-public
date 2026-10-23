"""Write data/rl_policy.json for scripts/rl_dealer.gd: bias-network weights, the per-cut-set brain vectors, the card
and sigil order the features use, plus test cases (states with the Python biases) for rl_dealer.gd's self-check.

python rl/export.py rl/out/run1/policy.npz
"""
import json
import random
import sys
from pathlib import Path

import numpy as np

import features as F
import policy as P
from env import Episode
from rules import CARD_NAMES, SIGIL_IDS
from train import TABLE

ROOT = Path(__file__).resolve().parent.parent


def snap(b):
    return {"board": b.board, "hand": b.hand, "deck": b.deck, "bones": b.bones, "starve": b.starve, "scale": b.scale,
            "turn": b.turn, "turn_count": b.turn_count}


def main():
    src = sys.argv[1]
    p = dict(np.load(src))
    layers = [{"W": p[f"W{k}"].round(5).tolist(), "b": p[f"b{k}"].round(5).tolist()} for k in range(len(P.HIDDEN))]
    layers.append({"W": p["Wo"].round(5).tolist(), "b": p["bo"].round(5).tolist(), "tanh": False})
    rounded = {**p, **{f"W{k}": np.array(layers[k]["W"], np.float32) for k in range(len(P.HIDDEN))},
               **{f"b{k}": np.array(layers[k]["b"], np.float32) for k in range(len(P.HIDDEN))},
               "Wo": np.array(layers[-1]["W"], np.float32), "bo": np.array(layers[-1]["b"], np.float32)}
    tests = []
    rng = random.Random(77)
    cuts = list(TABLE["cuts"])
    while len(tests) < 12:
        ep = Episode(rng, [0, 0, 0, 0], 0.0)
        while ep.needs_decision() and len(tests) < 12:
            cut = rng.choice(cuts)
            legal, opts, g = F.options(ep.b, "dealer")
            ctx = F.ctx(ep.b, "dealer", ep.picks_left)
            brain = np.array(TABLE["cuts"][cut]["brain"], np.float32)
            lg = P.logits(rounded, np.array(ctx, np.float32), brain, opts, g)
            bias = lg - P.BETA * np.asarray(g, np.float32)
            if rng.random() < 0.3:
                tests.append({"state": json.loads(json.dumps(snap(ep.b))), "cut": cut.split("+") if cut != "none" else [],
                              "picks_left": ep.picks_left, "bias": [round(float(x), 4) for x in bias]})
            a = int(np.argmax(lg))
            ep.act(None if a == 0 else legal[a - 1])
    out = {"note": "RL Dealer policy, made by rl/export.py from " + Path(src).as_posix(), "beta": P.BETA,
           "wires": TABLE["wires"], "cards": CARD_NAMES, "sigils": SIGIL_IDS,
           "cuts": {k: {"brain": v["brain"]} for k, v in TABLE["cuts"].items()}, "layers": layers, "tests": tests}
    path = ROOT / "data" / "rl_policy.json"
    path.write_text(json.dumps(out, separators=(",", ":")))
    print(f"wrote {path} ({path.stat().st_size // 1024} KB, {len(tests)} test states)")


if __name__ == "__main__":
    main()
