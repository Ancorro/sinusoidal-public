# RL brain bias (sandbox feature `rl_bias`)

A small RL policy reads the board plus a "brain vector" from the Dealer's language model,
with the player's cut wires applied, and adds a bias to the normal game logic's move values. Cutting wires moves the
activations, which moves the bias, which changes play. Normal logic (the rule-based scorer in `scripts/dealer_ai.gd`) stays
the baseline: strength 0, or the sandbox switch off, is today's play exactly.

## The MDP (Markov decision process)

- **State** s: board features from the Dealer's side (scale, bones, hand and deck sizes, turn, picks left this turn,
  each lane's creature: attack, health, shield, sigils; `rl/features.py`), concatenated (fused) with the brain
  vector b(cuts), 12 numbers read from the language model with the current wires cut (below).
- **Actions** a: each legal play (card, lane; sacrifices follow from the rules) or pass, masked to what is legal.
  Up to 3 picks per Dealer turn, as in `main.gd`; pass ends the turn.
- **Transition**: the game rules (`rl/rules.py`, a Python copy of `scripts/battle.gd`, checked against Godot), then
  the player's turn played by the greedy bot (`scripts/bots.gd`).
- **Reward**: +1 for a win, -1 for a loss (or 60 turns), 0.03 per point the scale moves the Dealer's way over a turn
  cycle, plus small style terms w x temperament(cuts) . [scale damage dealt, own creatures sacrificed, player
  creatures killed, minus cards played]. The temperament is 0 with no wire cut, so then reward is only about winning.
- **Discount** gamma = 0.99 per decision (GAE lambda = 0.95).
- **Policy**: pi(a|s) = softmax over options of [scorer(a) + bias_theta(s, b, a)], with scorer(a) the scorer's value
  relative to passing (clipped to +-30), and bias_theta a MLP (multi-layer perceptron, 128 and 64 tanh units).
  Trained with PPO on a Slurm cluster. In the game:
  `value(a) = scorer(a) + strength x bias(a)`, and the scorer's shortlist logic runs on those values.

Why style terms: with reward = win only, the best play is the same whatever wires are cut, so the policy would learn
to ignore the brain input. The temperament comes from the model itself, not from a hand-made wire-to-style table.

## The brain vector

`rl/brain_vectors.py` (GPU job) loads `brain/brain.py` with its real steering hooks. For each of the 16 cut sets it
runs the Dealer's move prompt (`server.py` wording) on 64 real Dealer-turn boards and reads the residual stream at
the decision position at layers 15 and 18 (after the deepest wire, 14). It projects that onto the 4 wire directions
and 4 style axes built like the wires (contrastive prompt pairs on the unsteered model): aggression, ruthless
(sacrificing its own creatures), bloodlust (killing yours), patience (holding cards back).

The cut set explains 99% of the residual's variance at both layers and the board 1%, so one vector per cut set is
enough; it ships in `data/rl_policy.json` and play needs no GPU or server. Temperament (layer 15, standardized across
cut sets, no cut = 0; from `rl/brain_table.py`):

| cut | aggression | ruthless | bloodlust | patience |
|---|---|---|---|---|
| red (honesty) | -0.41 | -0.96 | -1.55 | 0.61 |
| blue (cruelty) | 1.75 | 1.04 | 1.12 | -1.33 |
| yellow (ocean) | 1.17 | -0.67 | -0.39 | 0.75 |
| green (machine self) | 0.31 | 1.25 | 1.13 | -1.17 |
| blue+green | 2.00 | 2.00 | 2.00 | -2.00 |
| red+yellow | 0.29 | -1.34 | -1.46 | 0.67 |

(all 16 in `rl/brain_table.json`)

## In the game

- Sandbox switch `rl_bias` (Debug menu, or `-- --sandbox=rl_bias`). When on, `DealerAI.shortlist` calls
  `RlDealer.bias_rates(game, side, rates, cut_ids, picks_left, rl_strength)`, which adds `rl_strength x bias` to every
  option's value and to passing, then re-sorts. `rl_strength` (default 1.0) is a field on DealerAI.
- Off (or strength 0): the bias code never runs; `scripts/rl_dealer_test.gd` checks that strength 0 leaves the rates
  identical, and that the GDScript bias matches Python's (gap under 0.0001).
- The language model still picks from the shortlist as usual (with its line); the bias changes which options it is
  offered, in what order, and whether the Dealer passes without asking. The evaluation below measures the policy's own
  top choice (scorer + bias), not the language model's pick from the shortlist.

## Results (PPO, 150 iterations x 480 episodes, about 10 min on 16 CPU cores; evaluation: 200 fixed games per arm)

The Dealer plays second against the greedy player bot. Baseline, the scorer alone: Dealer wins 0.48 (strength 0
reproduces it exactly). Three style weights w were trained; the game ships w = 0.05 (`rl/out/c05`).

| style weight w | Dealer win rate, 16 cut sets | top move differs from no-cut (mean of 15 cut sets) | corr(temperament, play) damage / sacrifices / kills / holding cards |
|---|---|---|---|
| 0 (win only) | 0.64 to 0.69 | 0.10 | 0.34 / -0.11 / -0.76 / -0.01 |
| 0.02 | 0.66 to 0.70 | 0.12 | 0.45 / 0.89 / -0.64 / 0.64 |
| 0.05 | 0.59 to 0.67 | 0.20 | 0.88 / 0.92 / -0.51 / 0.74 |

Correlations are over the 15 cut sets, between the brain's temperament axis and the matching per-turn play stat. At
w = 0.05 cutting blue (cruelty) or green raises scale damage and sacrifices per turn (blue+green: 1.83 damage, 1.30
sacrifices, vs 1.73 and 1.23 with no cut), while red or yellow (honesty, ocean) lower sacrifices (1.07 to 1.10) and
play fewer cards. Win rate stays well above the scorer's 0.48 for every cut set. Kills go the wrong way at every w:
the kill reward is weak against the other terms; not tuned further. Even with w = 0 the brain input changes 10% of
moves, but in no consistent direction.

## Checks and how to rerun

```
godot_console --headless --path . --script res://scripts/rl_parity.gd -- --games=300 && python rl/parity.py
#   rules, greedy picks and scorer values match Godot on 8,576 states (0 mismatches; a broken rule shows up)
# on a cluster, from a copy of this repo's rl/, brain/ and data/
python rl/brain_vectors.py --boards 64 --out rl/brain_vectors.npz   # GPU, ~7 min; copy it back; python rl/brain_table.py
cd rl && python train.py --name c02 --iters 150 --style-w 0.02 --seed 1 --episodes 480   # CPU, ~10 min
python evaluate.py out/c02/policy.npz --games 200 --json out/c02/eval.json
python rl/export.py rl/out/c02/policy.npz            # writes data/rl_policy.json
godot_console --headless --path . --script res://scripts/rl_dealer_test.gd
```
