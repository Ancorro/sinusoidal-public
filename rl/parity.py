"""Replays games dumped by scripts/rl_parity.gd through rl/rules.py and checks they match the real rules exactly.

python rl/parity.py [path to rl_parity.json]   (default: Godot's user:// folder for this project)
"""
import json
import os
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from rules import Battle, greedy_pick, scorer_evaluate  # noqa: E402

DEFAULT = Path(os.environ.get("APPDATA", "~")) / "Godot" / "app_userdata" / "Sinusoidal" / "rl_parity.json"


def key(o):
    return [o["card"], o["lane"], o["sacrifices"]]


def main():
    path = Path(sys.argv[1] if len(sys.argv) > 1 else DEFAULT).expanduser()
    games = json.loads(path.read_text())
    steps = bad = greedy_checked = 0
    for gi, g in enumerate(games):
        b = Battle()
        s = g["start"]
        b.hand = {k: list(v) for k, v in s["hand"].items()}
        b.deck = {k: list(v) for k, v in s["deck"].items()}
        b.turn_count, b.turn = s["turn_count"], s["turn"]
        prev_side = b.turn
        for st in g["steps"]:
            side = st["side"]
            if side != b.turn:
                b.end_turn(prev_side)
            prev_side = side
            steps += 1
            text = b.describe("dealer") + "\n##\n" + b.describe("player")
            legal = b.legal_plays(side)
            gp = greedy_pick(b, side)
            errs = []
            if text != st["text"]:
                errs.append(f"text\n  godot: {st['text']!r}\n  py:    {text!r}")
            if b.scale != st["scale"]:
                errs.append(f"scale {st['scale']} vs {b.scale}")
            if [key(o) for o in legal] != st["legal"]:
                errs.append(f"legal\n  godot: {st['legal']}\n  py:    {[key(o) for o in legal]}")
            if (None if gp is None else [gp["card"], gp["lane"]]) != st["greedy"]:
                errs.append(f"greedy godot {st['greedy']} py {None if gp is None else [gp['card'], gp['lane']]}")
            sc = [scorer_evaluate(b, side, None)] + [scorer_evaluate(b, side, o) for o in legal]
            if "scorer" in st and max(abs(x - y) for x, y in zip(sc, st["scorer"])) > 1e-3:
                errs.append(f"scorer godot {st['scorer']} py {sc}")
            greedy_checked += 1
            if errs:
                bad += 1
                if bad <= 5:
                    print(f"game {gi} step {steps}: " + "\n".join(errs))
                break
            if st["move"] is not None:
                m = next(o for o in legal if o["card"] == st["move"][0] and o["lane"] == st["move"][1])
                b.play(side, m)
        else:
            b.end_turn(prev_side)
            e = g["end"]
            if (b.winner, b.scale) != (e["winner"], e["scale"]):
                bad += 1
                print(f"game {gi} end: godot {e['winner']} {e['scale']} py {b.winner} {b.scale}")
    print(f"PARITY games={len(games)} steps={steps} greedy picks checked={greedy_checked} mismatching games={bad}")
    sys.exit(1 if bad else 0)


if __name__ == "__main__":
    main()
