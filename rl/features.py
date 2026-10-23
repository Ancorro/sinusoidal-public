"""Features the RL Dealer sees, from the Dealer's side. scripts/rl_dealer.gd computes the same numbers in GDScript;
rl/export.py writes test cases so the two can be compared (rl_dealer.gd's self-test).

State (CTX): scale, bones, hand and deck sizes, turn, picks left, and per lane and side: present, attack, health, shield
left, sigil flags.
Option (OPT, one row per legal play plus pass): pass flag, track C's scorer value for it (minus the pass value), card
and lane one-hots, cost, sacrifices, and what happens on our attack right after it (scale moved, foes killed, ours lost).
"""
from rules import CARD_NAMES, LANES, SIGIL_IDS, has, other, scorer_evaluate

CLIP = 30.0   # scorer differences are clipped (a win scores 1000)

KINDS = ["free", "bones", "blood"]
N_CTX = 7 + LANES * 2 * (4 + len(SIGIL_IDS))
N_OPT = 1 + 1 + len(CARD_NAMES) + LANES + len(KINDS) + 4 + 3


def _count(b, side):
    return sum(c is not None for c in b.board[side])


def ctx(b, side, picks_left):
    foe = other(side)
    s = b.scale if side == "player" else -b.scale
    out = [s / 5, b.bones[side] / 10, b.bones[foe] / 10, len(b.hand[side]) / 10, len(b.deck[side]) / 10,
           b.turn_count / 30, picks_left / 3]
    for sd in (side, foe):
        for lane in range(LANES):
            c = b.board[sd][lane]
            if c is None:
                out += [0.0] * (4 + len(SIGIL_IDS))
            else:
                out += [1.0, c["atk"] / 4, c["hp"] / 6, float(c["shield"])] + [float(has(c, g)) for g in SIGIL_IDS]
    return out


def after_attack(b, side):
    """(scale toward side, foe creatures, own creatures) after side's attack on a copy."""
    c = b.clone()
    if not (c.first_turn_no_attack and c.turn_count == 1):
        c.attack(side)
    s = c.scale if side == "player" else -c.scale
    return s, _count(c, other(side)), _count(c, side), c.winner == side


def options(b, side):
    """(legal plays, option feature rows with pass first, scorer values relative to pass, clipped). Row 0 is pass."""
    legal = b.legal_plays(side)
    base = scorer_evaluate(b, side, None)
    s0, f0, m0, _ = after_attack(b, side)
    rows = [[1.0, 0.0] + [0.0] * (len(CARD_NAMES) + LANES + len(KINDS) + 4) + [0.0, 0.0, 0.0]]
    g = [0.0]
    foe = other(side)
    for o in legal:
        c = b.clone()
        c.play(side, o)
        sc = max(-CLIP, min(CLIP, scorer_evaluate(b, side, o) - base))
        s1, f1, m1, _ = after_attack(c, side)
        card = c.board[side][o["lane"]]
        f = b.board[foe][o["lane"]]
        row = [0.0, sc / 10]
        row += [float(n == o["card"]) for n in CARD_NAMES]
        row += [float(l == o["lane"]) for l in range(LANES)]
        row += [float(card["kind"] == k) for k in KINDS]
        row += [card["cost"] / 6, len(o["sacrifices"]) / 3, float(f is not None), (f["atk"] if f else 0) / 4]
        row += [(s1 - s0) / 5, f0 - f1, m0 - m1 + 1]   # +1: the new card itself
        rows.append(row)
        g.append(sc)
    return legal, rows, g
