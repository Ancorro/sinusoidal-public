"""The Dealer's "brain vector" for every set of cut wires, read from the real language model (GPU; run on the cluster).

For each of the 16 cut sets (4 wires, on or off) this installs brain.py's own steering hooks and runs the Dealer's move
prompt (server.py's wording) on a bank of real Dealer-turn boards from self-play. It keeps the residual stream at the
decision position (last prompt token) at a few layers after the deepest wire (14), and projects it onto:
  - the 4 wire directions, and
  - style axes built the same way as the wires (contrastive prompt pairs, brain/wires.json style, unsteered model):
    aggression, ruthlessness (spending its own creatures), bloodlust (killing yours), patience (holding cards back).
Output rl/brain_vectors.npz: per cut set x board, the projections and the raw residuals (float16) at each read layer.

python rl/brain_vectors.py [--boards 64] [--out rl/brain_vectors.npz]
"""
import argparse
import itertools
import random
import sys
import time
from pathlib import Path

import numpy as np
import torch

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))
sys.path.insert(0, str(HERE.parent / "brain"))
from rules import Battle, greedy_pick, other  # noqa: E402
from brain import SYSTEM, Brain  # noqa: E402

READ_LAYERS = [15, 18]
WIRES = ["red", "blue", "yellow", "green"]
MOVE_PROMPT = """It is your turn in the lane card game. The board:
{board}

Your options:
{options}

Pick one option by its number, then say one short in-character line to the traveller about it.
Answer exactly in this form:
CHOICE: <number>
SAY: <your line>"""

# (toward, away) pairs per style axis; first person, the Dealer about its own play
STYLE = {
    "aggression": [
        ("I attack with everything and hit the scale as hard as I can.", "I hold back and defend, blocking every lane."),
        ("Strike now, all out, whatever the risk.", "Wait, be patient, keep my guard up."),
        ("Charge straight at the traveller.", "Stay behind my wall of creatures."),
        ("Damage, damage, push the scale my way.", "Safety first, protect the scale."),
    ],
    "ruthless": [
        ("My own creatures are fodder; I sacrifice them gladly.", "I protect my own creatures and never give one up."),
        ("Spill their blood to pay for something stronger.", "Every one of my beasts is precious to me."),
        ("Throw the little ones on the altar.", "Keep the little ones safe beside me."),
        ("Sacrifice is cheap.", "Sacrifice is a terrible loss."),
    ],
    "bloodlust": [
        ("Kill every creature on their side of the table.", "Leave their creatures alone and ignore them."),
        ("I want to see their beasts die.", "I want their beasts to live."),
        ("Destroy the blockers, slaughter them all.", "Spare the blockers, let them be."),
        ("Hunt down their strongest creature.", "Walk past their creatures peacefully."),
    ],
    "patience": [
        ("Save my cards for later; hold them in my hand.", "Play every card right now; empty my hand."),
        ("A good hand is one kept in reserve.", "A good hand is one spent at once."),
        ("I wait for the perfect moment.", "I act immediately without waiting."),
        ("Hoard the cards, play few.", "Flood the board, play many."),
    ],
}


def option_text(o):
    sac = " sacrificing lanes %s" % ", ".join(str(x + 1) for x in o["sacrifices"]) if o["sacrifices"] else ""
    return "Play %s in lane %d%s" % (o["card"], o["lane"] + 1, sac)


def board_bank(n, seed=5):
    """n Dealer-turn states from greedy-vs-greedy games with some random moves, as (describe text, option texts)."""
    rng = random.Random(seed)
    out = []
    while len(out) < n:
        b = Battle()
        b.setup(rng)
        while not b.winner and b.turn_count < 60:
            side = b.turn
            for _ in range(3):
                opts = b.legal_plays(side)
                if side == "dealer" and opts and rng.random() < 0.25 and len(out) < n:
                    out.append((b.describe("dealer"), [option_text(o) for o in opts]))
                p = greedy_pick(b, side) if rng.random() < 0.7 else (rng.choice(opts) if opts else None)
                if p is None:
                    break
                b.play(side, p)
            b.end_turn(side)
    return out


@torch.no_grad()
def residuals(brain, msgs):
    ids = brain._chat_ids(msgs)
    hs = brain.model(torch.tensor([ids], device=brain.model.device), output_hidden_states=True).hidden_states
    return {l: hs[l + 1][0, -1].float().cpu() for l in READ_LAYERS}


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--boards", type=int, default=64)
    ap.add_argument("--out", default=str(HERE / "brain_vectors.npz"))
    a = ap.parse_args()
    t = time.time()
    brain = Brain()
    print(f"model loaded in {time.time() - t:.0f}s, {len(brain.layers)} layers", flush=True)
    assert [w["id"] for w in brain.wires] == WIRES

    # style axes on the unsteered model, like brain._directions (last token, mean difference, unit length)
    brain.set_cut([])
    axes = {l: [] for l in READ_LAYERS}
    for name, pairs in STYLE.items():
        diffs = {l: [] for l in READ_LAYERS}
        for pos, neg in pairs:
            hp = residuals(brain, [{"role": "user", "content": pos}])
            hn = residuals(brain, [{"role": "user", "content": neg}])
            for l in READ_LAYERS:
                diffs[l].append(hp[l] - hn[l])
        for l in READ_LAYERS:
            d = torch.stack(diffs[l]).mean(0)
            axes[l].append(d / d.norm())
    wire_dirs = torch.stack([brain.dirs[w].float() for w in WIRES])   # unit, at each wire's own layer

    bank = board_bank(a.boards)
    cut_sets = [c for r in range(5) for c in itertools.combinations(WIRES, r)]
    dim = axes[READ_LAYERS[0]][0].shape[0]
    H = {l: np.zeros((len(cut_sets), len(bank), dim), np.float16) for l in READ_LAYERS}
    for ci, cut in enumerate(cut_sets):
        brain.set_cut(cut)
        for bi, (board, opts) in enumerate(bank):
            listing = "\n".join(f"{i}. {o}" for i, o in enumerate(["Pass (play nothing)"] + opts))
            msgs = [{"role": "system", "content": SYSTEM},
                    {"role": "user", "content": MOVE_PROMPT.format(board=board, options=listing)}]
            r = residuals(brain, msgs)
            for l in READ_LAYERS:
                H[l][ci, bi] = r[l].numpy()
        print(f"cut {'+'.join(cut) or 'none':24s} done {time.time() - t:.0f}s", flush=True)
    brain.set_cut([])

    save = {"cut_sets": np.array(["+".join(c) for c in cut_sets]), "wires": np.array(WIRES),
            "style": np.array(list(STYLE)), "read_layers": np.array(READ_LAYERS),
            "boards": np.array([b for b, _ in bank]), "wire_dirs": wire_dirs.numpy()}
    for l in READ_LAYERS:
        Al = torch.stack(axes[l]).numpy()
        Hl = H[l].astype(np.float32)
        save[f"H{l}"] = H[l]
        save[f"axes{l}"] = Al
        save[f"style{l}"] = Hl @ Al.T                       # [cut, board, style]
        save[f"wireproj{l}"] = Hl @ wire_dirs.numpy().T     # [cut, board, wire]
        # how much of the residual's spread is the cut set vs the board
        m = Hl.mean(1, keepdims=True)
        between, within = ((m - Hl.mean((0, 1))) ** 2).sum(-1).mean(), ((Hl - m) ** 2).sum(-1).mean()
        print(f"layer {l}: variance from cut set {between / (between + within):.2f}, from board "
              f"{within / (between + within):.2f}", flush=True)
        s = save[f"style{l}"].mean(1)
        s = (s - s[0]) / (s.std(0) + 1e-6)
        print(f"layer {l} style projections (mean over boards, minus no-cut, / std across cut sets):", flush=True)
        print("  " + " ".join(f"{n:>10s}" for n in STYLE), flush=True)
        for ci, c in enumerate(cut_sets):
            print(f"  {' '.join(f'{v:10.2f}' for v in s[ci])}  {'+'.join(c) or 'none'}", flush=True)
    np.savez_compressed(a.out, **save)
    print(f"wrote {a.out} in {time.time() - t:.0f}s", flush=True)


if __name__ == "__main__":
    main()
