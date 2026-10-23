"""Does cutting wires change how the RL Dealer plays? Fixed seeds, same games for every arm.

Arms: track C's scorer as Dealer (baseline, normal logic), then the policy (argmax, strength 1) with each of the 16 cut sets.
Per arm: Dealer win rate vs the greedy player, and per Dealer turn: scale damage dealt, own creatures sacrificed,
player creatures killed, cards played. Then move disagreement: on a fixed bank of Dealer decision states (from
no-cut play), how often each cut set's choice differs from the no-cut choice.

python rl/evaluate.py rl/out/run1/policy.npz [--games 200] [--json out.json]
"""
import argparse
import json
import random

import numpy as np

import features as F
import policy as P
from env import Episode, scorer_episode
from rules import scorer_pick
from train import TABLE, CUTS


def choose(p, b, brain, picks_left, strength=1.0):
    if strength == 0.0:   # the game skips the policy entirely at strength 0
        legal = b.legal_plays("dealer")
        best = scorer_pick(b, "dealer")
        return legal, 0 if best is None else 1 + next(i for i, o in enumerate(legal) if o is best or
                                                     (o["card"], o["lane"]) == (best["card"], best["lane"]))
    legal, opts, g = F.options(b, "dealer")
    lg = P.logits(p, np.array(F.ctx(b, "dealer", picks_left), np.float32), brain, opts, g, strength)
    a = int(np.argmax(lg))
    return legal, a


def play_arm(p, cut, games, strength=1.0, bank=None):
    row = TABLE["cuts"][cut]
    brain = np.array(row["brain"], np.float32)
    wins, tot = 0, {"dmg": 0, "sac": 0, "kills": 0, "played": 0, "turns": 0}
    for g in range(games):
        ep = Episode(random.Random(10_000 + g), [0, 0, 0, 0], 0.0)
        while ep.needs_decision():
            if bank is not None and len(bank) < 400 and g % 2 == 0:
                bank.append((ep.b.clone(), ep.picks_left))
            legal, a = choose(p, ep.b, brain, ep.picks_left, strength)
            ep.act(None if a == 0 else legal[a - 1])
        wins += ep.b.winner == "dealer"
        for k, v in getattr(ep, "stats", {}).items():
            tot[k] += v
    t = max(1, tot["turns"])
    return {"win": wins / games, "dmg/turn": tot["dmg"] / t, "sac/turn": tot["sac"] / t,
            "kills/turn": tot["kills"] / t, "played/turn": tot["played"] / t}


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("policy")
    ap.add_argument("--games", type=int, default=200)
    ap.add_argument("--json")
    a = ap.parse_args()
    p = dict(np.load(a.policy))
    res = {}
    gw = sum(scorer_episode(random.Random(10_000 + g)) == "dealer" for g in range(a.games)) / a.games
    print(f"scorer Dealer (normal logic) vs greedy player: Dealer wins {gw:.2f} ({a.games} games)")
    res["scorer"] = {"win": gw}
    bank = []
    print(f"{'cut set':24s} {'win':>5s} {'dmg/t':>6s} {'sac/t':>6s} {'kill/t':>6s} {'play/t':>6s} {'moves differ':>12s}   temperament")
    base = play_arm(p, "none", a.games, bank=bank)
    base_moves = [choose(p, b, np.array(TABLE["cuts"]["none"]["brain"], np.float32), k)[1] for b, k in bank]
    for cut in CUTS:
        r = base if cut == "none" else play_arm(p, cut, a.games)
        brain = np.array(TABLE["cuts"][cut]["brain"], np.float32)
        r["differ"] = float(np.mean([choose(p, b, brain, k)[1] != m for (b, k), m in zip(bank, base_moves)]))
        res[cut] = r
        print(f"{cut:24s} {r['win']:5.2f} {r['dmg/turn']:6.2f} {r['sac/turn']:6.2f} {r['kills/turn']:6.2f} "
              f"{r['played/turn']:6.2f} {r['differ']:12.2f}   " + " ".join(f"{x:5.2f}" for x in TABLE['cuts'][cut]['temper']))
    print(f"(moves differ: share of {len(bank)} fixed no-cut decision states where this cut set picks another move)")
    s0 = play_arm(p, "none", a.games, strength=0.0)
    print(f"strength 0 (scorer argmax through the policy code), no cut: win {s0['win']:.2f} (should equal the scorer line)")
    res["strength0"] = s0
    if a.json:
        json.dump(res, open(a.json, "w"), indent=1)


if __name__ == "__main__":
    main()
