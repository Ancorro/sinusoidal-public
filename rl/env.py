"""The MDP (Markov decision process) the RL Dealer learns in.

State: board features (features.ctx) + the brain vector for the episode's cut wires. Action: one of the legal plays or
pass (pass is always offered, as in main.gd; it ends the Dealer's turn). Up to 3 picks per turn, like main.gd.
Transitions: the real rules (rules.py, parity-checked), with the greedy bot as the player.
Baseline policy (normal logic): track C's scorer; the learned bias is added to its values.
Reward: +1 win, -1 loss, 0.03 per point the scale moves toward the Dealer over a turn cycle, plus small style terms
weighted by the cut set's temperament (brain.py's steered activations projected on style axes, see brain_table.py):
  aggression x scale damage the Dealer's attack dealt, ruthless x own creatures sacrificed,
  bloodlust x player creatures killed on the Dealer's attack, patience x minus cards played.
With no wires cut the temperament is 0, so the reward is only about winning.
"""
import json
import random
from pathlib import Path

from rules import DECK, Battle, greedy_turn, scorer_pick

ROOT = Path(__file__).resolve().parent.parent
RUN = json.loads((ROOT / "data" / "run.json").read_text())
DEALER_DECKS = [DECK] + [RUN["dealer_decks"][k] for k in ("early", "late", "boss")]
PICKS = 3
SCALE_W = 0.03


def random_deck(rng, names):
    return [rng.choice(names) for _ in range(10)]


class Episode:
    """One battle, the Dealer (second player) against the greedy player. Drive it with decision() / act()."""

    def __init__(self, rng, temper, style_w, player_deck=None, dealer_deck=None):
        self.rng = rng
        self.temper = temper        # [aggression, ruthless, bloodlust, patience]
        self.style_w = style_w
        self.b = Battle()
        self.b.setup(rng, player_deck or DECK, dealer_deck or rng.choice(DEALER_DECKS))
        self.picks_left = 0
        self.turn_start = None
        self.played = 0
        self._advance()

    def _advance(self):
        """Run the player's turns until it is the Dealer's turn or the game ends."""
        b = self.b
        while not b.winner and b.turn == "player" and b.turn_count < 60:
            greedy_turn(b, "player", 4)
            b.end_turn("player")
        if not b.winner and b.turn == "dealer":
            self.picks_left = PICKS
            self.played = 0
            self.turn_start = (b.scale, b.sacrificed["dealer"], b.killed["player"])

    @property
    def done(self):
        return bool(self.b.winner) or self.b.turn_count >= 60

    def act(self, play):
        """play: a legal play dict, or None to pass. Returns the reward for this step."""
        b = self.b
        if play is not None:
            b.play("dealer", play)
            self.played += 1
            self.picks_left -= 1
            if self.picks_left > 0 and b.legal_plays("dealer"):
                return 0.0
        # the Dealer's turn ends: attack, then the player's turn
        scale0, sac0, kill0 = self.turn_start
        before_attack = b.scale
        b.end_turn("dealer")
        dmg = max(0, before_attack - b.scale)        # scale moved toward the Dealer by its attack
        style = [dmg, b.sacrificed["dealer"] - sac0, b.killed["player"] - kill0, -self.played]
        r = self.style_w * sum(t * s for t, s in zip(self.temper, style))
        self.stats_add(style)
        self._advance()
        r += SCALE_W * (scale0 - b.scale)
        if b.winner == "dealer":
            r += 1.0
        elif b.winner == "player" or b.turn_count >= 60:
            r -= 1.0
        return r

    def stats_add(self, style):
        s = getattr(self, "stats", None) or {"dmg": 0, "sac": 0, "kills": 0, "played": 0, "turns": 0}
        s["dmg"] += style[0]
        s["sac"] += style[1]
        s["kills"] += style[2]
        s["played"] += -style[3]
        s["turns"] += 1
        self.stats = s

    def needs_decision(self):
        """True when the Dealer has a real choice now; otherwise passes are taken automatically."""
        while not self.done and not self.b.legal_plays("dealer"):
            self.act(None)
        return not self.done


def scorer_episode(rng, player_deck=None, dealer_deck=None):
    """Baseline: the scorer as Dealer (its best play while it beats passing, 3 picks) vs the greedy player."""
    b = Battle()
    b.setup(rng, player_deck or DECK, dealer_deck or rng.choice(DEALER_DECKS))
    while not b.winner and b.turn_count < 60:
        s = b.turn
        if s == "player":
            greedy_turn(b, s, 4)
        else:
            for _ in range(PICKS):
                p = scorer_pick(b, s)
                if p is None:
                    break
                b.play(s, p)
        b.end_turn(s)
    return b.winner
