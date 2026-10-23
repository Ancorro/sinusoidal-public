"""Python mirror of scripts/battle.gd and the greedy bot in scripts/bots.gd, for fast self-play.

Kept line-for-line close to the GDScript so parity is easy to check: rl/parity.py replays games dumped by
scripts/rl_parity.gd (real Godot rules) and compares every board description, legal-play set and greedy pick.
The only RNG in the rules is the deck shuffle, so a game is fully determined by its deck orders and moves.
"""
import json
import random
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
LANES = 4
TIP = 5
_data = json.loads((ROOT / "data" / "cards.json").read_text())
SIGILS = _data["sigils"]
CARDS = {n: {"atk": int(c["atk"]), "hp": int(c["hp"]), "cost": int(c["cost"]), "kind": c["kind"],
             "sigils": list(c["sigils"])} for n, c in _data["cards"].items()}
DECK = list(_data["starter_deck"])
SIGIL_IDS = list(SIGILS)
CARD_NAMES = list(CARDS)


def other(side):
    return "dealer" if side == "player" else "player"


def creature(name):
    c = CARDS[name]
    return {"name": name, "atk": c["atk"], "hp": c["hp"], "max_hp": c["hp"], "cost": c["cost"], "kind": c["kind"],
            "sigils": c["sigils"], "shield": "shield" in c["sigils"]}


def has(c, sigil):
    return c is not None and sigil in c["sigils"]


class Battle:
    first_turn_no_attack = True
    squirrel_each_turn = True
    squirrel_from_turn = 0
    opening_cards = 3
    second_extra = 0

    def __init__(self):
        self.board = {"player": [None] * LANES, "dealer": [None] * LANES}
        self.hand = {"player": [], "dealer": []}
        self.deck = {"player": [], "dealer": []}
        self.bones = {"player": 0, "dealer": 0}
        self.starve = {"player": 0, "dealer": 0}
        self.scale = 0
        self.turn = "player"
        self.turn_count = 0
        self.winner = ""
        # tallies for shaped rewards (not part of battle.gd's state)
        self.sacrificed = {"player": 0, "dealer": 0}
        self.killed = {"player": 0, "dealer": 0}   # creatures of that side killed in combat

    # ---------- setup ----------
    def setup(self, rng=None, player_deck=None, dealer_deck=None, decks_in_order=False):
        """decks_in_order: the decks are already shuffled (draws pop from the end), as dumped by rl_parity.gd."""
        rng = rng or random.Random()
        self.deck["player"] = list(player_deck or DECK)
        self.deck["dealer"] = list(dealer_deck or DECK)
        for side in ("player", "dealer"):
            if not decks_in_order:
                rng.shuffle(self.deck[side])
            self.hand[side] = ["Squirrel"]
            for _ in range(self.opening_cards + (self.second_extra if side == "dealer" else 0)):
                self._draw(side)
        self.start_turn("player")

    def start_turn(self, side):
        self.turn = side
        self.turn_count += 1
        if not self.deck[side]:
            self.starve[side] += 1
            self.scale += -self.starve[side] if side == "player" else self.starve[side]
            self._check_winner()
        else:
            self._draw(side)
        if self.squirrel_each_turn and self.turn_count > self.squirrel_from_turn:
            self.hand[side].append("Squirrel")

    def _draw(self, side):
        if self.deck[side]:
            self.hand[side].append(self.deck[side].pop())

    # ---------- plays ----------
    def legal_plays(self, side):
        out = []
        mine = self.board[side]
        others = [l for l in range(LANES) if mine[l] is not None]
        others.sort(key=lambda l: _sac_value(mine[l]))   # stable, like Godot's insertion sort on <= 16 items
        seen = set()
        for i, n in enumerate(self.hand[side]):
            if n in seen:
                continue
            seen.add(n)
            c = CARDS[n]
            for lane in range(LANES):
                sac = []
                if c["kind"] == "blood" and c["cost"] > 0:
                    if len(others) < c["cost"]:
                        continue
                    sac = others[:c["cost"]]
                    if mine[lane] is not None and (lane not in sac or has(mine[lane], "many_lives")):
                        continue
                else:
                    if mine[lane] is not None:
                        continue
                    if c["kind"] == "bones" and self.bones[side] < c["cost"]:
                        continue
                out.append({"card_index": i, "card": n, "lane": lane, "sacrifices": sac})
        return out

    def play(self, side, p):
        """p comes from legal_plays(side) on this exact state (no re-validation, unlike battle.gd)."""
        if self.winner or side != self.turn:
            return False
        c = creature(p["card"])
        for l in p["sacrifices"]:
            s = self.board[side][l]
            self.sacrificed[side] += 1
            if has(s, "many_lives"):
                continue
            self._die(side, l)
        if c["kind"] == "bones":
            self.bones[side] -= c["cost"]
        del self.hand[side][p["card_index"]]
        self.board[side][p["lane"]] = c
        return True

    def end_turn(self, side):
        if self.winner or side != self.turn:
            return
        if not (self.first_turn_no_attack and self.turn_count == 1):
            self.attack(side)
        if not self.winner:
            self.start_turn(other(side))

    def attack(self, side):
        foe = other(side)
        self._guard_moves(side)
        for lane in range(LANES):
            a = self.board[side][lane]
            if a is None or a["atk"] <= 0:
                continue
            b = self.board[foe][lane]
            if b is None or (has(a, "flying") and not has(b, "reach")):
                self.scale += a["atk"] if side == "player" else -a["atk"]
            else:
                self._hit(side, lane, lane)
            if has(a, "splash") and self.board[side][lane] is a:
                for l in (lane - 1, lane + 1):
                    if 0 <= l < LANES and self.board[foe][l] is not None and self.board[side][lane] is a:
                        self._hit(side, lane, l)
        self._check_winner()

    def _check_winner(self):
        if self.scale >= TIP:
            self.winner = "player"
        elif self.scale <= -TIP:
            self.winner = "dealer"

    def _hit(self, side, frm, to):
        foe = other(side)
        a = self.board[side][frm]
        b = self.board[foe][to]
        if b["shield"]:
            b["shield"] = False
        else:
            b["hp"] = 0 if has(a, "poison") else b["hp"] - a["atk"]
            if b["hp"] <= 0:
                self.killed[foe] += 1
                self._die(foe, to)
        if has(b, "thorns"):
            a["hp"] -= 1
            if a["hp"] <= 0:
                self.killed[side] += 1
                self._die(side, frm)

    def _guard_moves(self, side):
        foe = other(side)
        for g in range(LANES):
            c = self.board[foe][g]
            if not has(c, "guard") or self._ground_attacker(side, g):
                continue
            best = -1
            for l in range(LANES):
                if self.board[foe][l] is None and self._ground_attacker(side, l):
                    if best < 0 or self.board[side][l]["atk"] > self.board[side][best]["atk"]:
                        best = l
            if best >= 0:
                self.board[foe][best] = c
                self.board[foe][g] = None

    def _ground_attacker(self, side, lane):
        a = self.board[side][lane]
        return a is not None and a["atk"] > 0 and not has(a, "flying")

    def _die(self, side, lane):
        c = self.board[side][lane]
        self.board[side][lane] = None
        self.bones[side] += 3 if has(c, "bone_hoarder") else 1

    def clone(self):
        b = Battle.__new__(Battle)
        b.board = {s: [dict(c) if c is not None else None for c in row] for s, row in self.board.items()}
        b.hand = {s: list(h) for s, h in self.hand.items()}
        b.deck = {s: list(d) for s, d in self.deck.items()}
        b.bones = dict(self.bones)
        b.starve = dict(self.starve)
        b.scale = self.scale
        b.turn = self.turn
        b.turn_count = self.turn_count
        b.winner = self.winner
        b.sacrificed = dict(self.sacrificed)
        b.killed = dict(self.killed)
        return b

    # ---------- text ----------
    def describe(self, side):
        foe = other(side)
        lines = ["Scale: %d (you win at %d, you lose at %d)." % (-self.scale if side == "dealer" else self.scale, TIP, -TIP)]
        seen = {}
        for lane in range(LANES):
            lines.append("Lane %d: yours %s | theirs %s" % (lane + 1, _c(self.board[side][lane], seen),
                                                           _c(self.board[foe][lane], seen)))
        cards = []
        for n in self.hand[side]:
            c = creature(n)
            cost = "free" if c["kind"] == "free" else "%d %s" % (c["cost"], c["kind"])
            cards.append("%s %d/%d (%s%s)" % (n, c["atk"], c["hp"], cost, _sig(c, seen)))
        lines.append("Your hand: %s. Your bones: %d." % (", ".join(cards), self.bones[side]))
        if seen:
            lines.append("Sigils: " + " ".join("%s: %s" % (SIGILS[s]["name"], SIGILS[s]["text"]) for s in seen))
        return "\n".join(lines)


def _sac_value(c):
    return -1 if has(c, "many_lives") else c["atk"] + c["hp"]


def sigil_text(c):
    return ", ".join(SIGILS[s]["name"] for s in c["sigils"])


def _c(c, seen):
    if c is None:
        return "empty"
    s = _sig(c, seen)
    return "%s %d/%d%s" % (c["name"], c["atk"], c["hp"], " [%s]" % s[2:] if s else "")


def _sig(c, seen):
    if not c["sigils"]:
        return ""
    for s in c["sigils"]:
        seen[s] = True
    t = sigil_text(c)
    if "shield" in c["sigils"] and not c["shield"]:
        t += " (used)"
    return ", " + t


# ---------- greedy bot (scripts/bots.gd) ----------
def _value(c):
    if c is None:
        return 0.0
    return c["atk"] * 1.2 + c["hp"] * 0.6 + len(c["sigils"]) * 0.5


def score_after_attack(b, side, copy=True):
    c = b.clone() if copy else b
    if not (c.first_turn_no_attack and c.turn_count == 1):
        c.attack(side)
    if c.winner == side:
        return 1000.0
    foe = other(side)
    s = 3.0 * (c.scale if side == "player" else -c.scale) + 0.3 * c.bones[side] + 0.5 * len(c.hand[side])
    for lane in range(LANES):
        s += _value(c.board[side][lane]) - _value(c.board[foe][lane])
        f = c.board[foe][lane]
        if f is not None and c.board[side][lane] is None:
            s -= 1.5 * f["atk"]
    return s


def greedy_pick(b, side):
    best_score = score_after_attack(b, side)
    best = None
    for o in b.legal_plays(side):
        c = b.clone()
        c.play(side, o)
        s = score_after_attack(c, side, False)
        if s > best_score + 0.01:
            best_score = s
            best = o
    return best


def greedy_turn(b, side, picks=4):
    for _ in range(picks):
        best = greedy_pick(b, side)
        if best is None:
            return
        b.play(side, best)


# ---------- track C's scorer (scripts/dealer_ai.gd), the Dealer's normal logic ----------
SCORER_W = {"scale": 3.0, "reply": 1.0, "bones": 0.3, "hand": 0.4, "keep": 1.0, "threat": 0.5}
WIN = 1000.0


def _mine(c, side):
    return c.scale if side == "player" else -c.scale


def _scorer_value(c):
    if c is None:
        return 0.0
    v = c["atk"] * 1.2 + c["hp"] * 0.6 + len(c["sigils"]) * 0.5
    if "shield" in c["sigils"] and not c["shield"]:
        v -= 0.5
    return v


def scorer_evaluate(game, side, p):
    """DealerAI.evaluate: score after play p (None: pass), our attack, and the foe's attack back."""
    W = SCORER_W
    c = game.clone()
    if p is not None:
        c.play(side, p)
    foe = other(side)
    if not (c.first_turn_no_attack and c.turn_count == 1):
        c.attack(side)
    if c.winner == side:
        return WIN
    dealt = _mine(c, side)
    s = W["scale"] * dealt + W["bones"] * c.bones[side] + W["hand"] * len(c.hand[side])
    for lane in range(LANES):
        s += _scorer_value(c.board[side][lane]) - _scorer_value(c.board[foe][lane])
    c.attack(foe)
    if c.winner == foe:
        return -WIN * 0.5 + s
    s += W["reply"] * (_mine(c, side) - dealt)
    for lane in range(LANES):
        s += W["keep"] * _scorer_value(c.board[side][lane])
        f = c.board[foe][lane]
        if f is not None and c.board[side][lane] is None:
            s -= W["threat"] * f["atk"]
    return s


def scorer_pick(b, side):
    """The scorer's own choice: its best play if it beats passing (as the shortlist's 'don't ask' rule), else None."""
    best, best_s = None, scorer_evaluate(b, side, None) + 0.01
    for o in b.legal_plays(side):
        s = scorer_evaluate(b, side, o)
        if s > best_s:
            best, best_s = o, s
    return best
