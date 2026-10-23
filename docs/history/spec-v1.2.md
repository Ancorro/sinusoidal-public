# Sinusoidal v1.2 plan

*Historical plan from 2026-10-22, kept for reference. Most of it has been built in some form; see the README and `docs/features.md` for what exists now. Items marked **(default)** were provisional choices.*

## Goal

A short roguelike run, about 20 to 30 minutes, against the walnut Dealer. The run is a branching map of battles that ends in a boss hand. The cards have sigils, the Dealer's brain uses real neurons from the cluster search, an LLM tells a new story each run, and the game gets proper art, sound and animation.

## Decisions

| Area | Choice |
|---|---|
| Run shape | Short branching map, 5 to 7 stops, ending in a boss hand |
| Map stops | Battles and a boss; card choice and candles as lives **(default)**; brain workshop later |
| Run win | Beat the boss hand; ending written by the LLM from what you cut **(default)** |
| Cards | Sigils: 6 to 10 sigils, about 20 cards |
| Brain | Real neurons and heads from the honesty-small cluster run, next to the hand-made wires |
| LLM | Story per run, plus Dealer strategy and talk. No generated cards |
| Dealer strength | Model picks moves, a rule-based scorer filters out terrible ones; cut wires loosen the filter **(default)** |
| Story twist | Decide later; the LLM improvises inside a short premise |
| Art and feel | Walnut 3D Dealer, new card art, sound, animation and effects |
| Playtesting | Headless auto-play sims and a saved log per run **(default)** |
| How to build | Separate work tracks, each on its own git branch, then merged |

## Tracks

Dependencies are listed; tracks without one start at once.

### A. Card rules and sigils (no dependency)

1. Move card data out of code into `data/cards.json` (name, attack, health, cost, cost kind, art, sigils).
2. Sigils, each a small rule hook: Flying (skips blockers), Guard (moves to block), Poison (kills on any hit), Bone Hoarder (gives bones on death), Many Lives (survives one sacrifice), Splash (hits adjacent lanes), Shield (ignores first hit), Burrow (moves to an empty attacked lane). Pick 6 to 10.
3. About 20 cards using those sigils, plus Squirrel.
4. Extend the headless test: thousands of random and greedy games, report first-move advantage and per-card win rates. Fix the current first-player edge (134 of 200).
5. Done when: all sigils have tests, sims finish with no errors, first-player win rate is within 45 to 55 percent under greedy play.

### B. Run map, candles and card choice (needs A's card data format)

1. A small branching map, 5 to 7 stops, drawn on a parchment on the table.
2. Stop types: battle, card choice (pick 1 of 3), boss.
3. Candles: 3 per run; losing a hand blows one out; all out ends the run.
4. Deck carries between stops. Run state saved so a crash doesn't lose it.
5. Run summary screen: stops cleared, wires cut, a quote from the Dealer.

### C. Dealer strategy (needs A)

1. Rule-based scorer: rates each legal play (damage, blocking, lane threats).
2. The model gets the top options with short notes, picks one and says a line. The scorer drops clearly bad options.
3. Cut wires loosen the scorer (more options reach the model), so tampering makes play wilder.
4. Boss deck and a slightly stronger filter for the final hand.
5. Make the Dealer's line match the move it made (pass the chosen move back for the line).

### D. Brain: real neurons and speed (needs the honesty-small cluster results)

1. Take the heads and neurons the cluster run finds for Qwen3.5-2B (or 4B) and add them as wires next to the hand-made ones.
2. Wire types: direction (current), head steering (Sauers' method), neuron zeroing (like the code-block and pushback examples).
3. Get the speed-up libraries working (causal-conv1d, flash-linear-attention on Windows, or run the brain server in WSL (Windows Subsystem for Linux)) so a move takes about 1 second.
4. Try Qwen3.5-4B if speed allows; keep 2B as fallback.
5. A small brain test script: for each wire, the same prompts before and after, saved as a table, so every wire's effect is visible.

### E. Story per run (needs C for the move flow)

1. At run start the model writes a short premise: who the Dealer is tonight, what it wants, what is at stake. Stored in the run state.
2. Short lines between stops reacting to cuts, wins and losses.
3. Ending text based on the run (wires cut, how the boss went).
4. Guardrails: length limits, fallback lines if the output is garbled (garbled is allowed when wires are cut, but the game must not stall).

### F. Walnut 3D Dealer (no dependency; uses Colab)

1. Finish image-to-3D on a Colab GPU with the Hunyuan3D weights cached in cloud storage.
2. Clean the mesh in Blender: reduce to low poly, split head, lid, jaw and arms, add walnut and brass materials.
3. Replace the placeholder in Godot. The lid opens on the real model; wires sit inside its skull.
4. Idle motion: breathing sway, head turn toward the card being considered, jaw moves while it talks.

### G. Card art (no dependency; uses Colab FLUX)

1. One dark woodcut style for all creatures, FLUX on Colab, weights loaded from cloud storage.
2. About 20 portraits, matching track A's card list; sorted into `art/cards/` with a sheet for picking.
3. Card frame and sigil icons in the same style.
4. License check: FLUX.1-dev outputs are under a non-commercial license; note it, switch to FLUX.1-schnell if the game is ever sold.

### H. Sound (no dependency)

1. Clockwork ticking while the Dealer thinks, wire snip, bell, card thump, creature hit, scale creak, candle out, cabin ambience.
2. CC0 sources first (Freesound CC0, Kenney audio); record credits in `CREDITS.md`.
3. A small audio manager in Godot with volume settings.

### I. Animation and feel (needs A for events)

1. Cards slide from hand to lane, flip when drawn, lunge on attack, crumble on death.
2. Scale tips smoothly; screen shake on big hits; candle gutters when a life is lost.
3. Wire cut: spark particles and a short flicker in the Dealer's eyes.

### K. Read the Dealer's thoughts (no dependency; added 2026-10-22)

1. Research ways to read a model's insides as words: logit lens, tuned lens, Sauers' J lens, Patchscopes.
2. A "Read thoughts" mode: a button shows what the Dealer is considering while it thinks, reflecting cut wires.

### B additions: map events (added 2026-10-22)

- "?" event stops like Slay the Spire's: a short scene with 2 or 3 choices, each a trade-off (gain or remove a card, lose a candle, gamble, a curse), data-driven in `data/events.json`. Main game, not sandbox.

### L. Small RL Dealer with a fused brain (added 2026-10-22)

1. A small reinforcement-learning policy picks the Dealer's game moves, trained by self-play against the bots on the real rules.
2. Its input fuses the board state with activations from the language-model brain (for example, the residual stream at the wire layers), so cutting wires changes the activations it sees and therefore how it plays.
3. Train on a cluster or Colab, not the local PC; local runs only for short smoke tests.
4. A mode switch: scorer, language model, or RL policy decides moves. The Dealer always acts when a legal move exists.
5. Clarification: the brain is a **modifier to normal game logic** (state-machine biasing), not a replacement. Normal logic (scorer or play-style state machine) is the baseline; the RL policy adds a bias on top, with a strength knob where 0 gives normal play exactly.
6. Framed as an MDP (Markov decision process): state = board features plus the fused brain vector, actions = legal plays plus pass, transitions = the rules, reward = scale movement and win or loss.

### E additions: the Dealer shapes the run (added 2026-10-22)

- Between battles the Dealer can steer the run: push you down one path, hide or reveal stops, offer a bargain at a card choice, swap a stop's type. Its steering depends on its cut wires.

### J. Playtest tooling (needs A)

1. Each run writes a log: moves, cuts, Dealer lines, timings.
2. A headless runner that plays full runs with bots against a stub brain, for balance and crash checks.
3. A short report after each sim batch: win rate by card, average run length, errors.

## Order

- Wave 1, start at once: A (rules), F (3D Dealer), G (card art), H (sound), K (read thoughts). D waits on the cluster results.
- Wave 2, after A lands: B (map), C (strategy), I (animation), J (playtest).
- Wave 3: E (story, plus the Dealer steering the run between battles) and L (RL Dealer with fused brain), started early once B merged. D lands whenever the cluster results arrive.
- Each track works on its own git branch and leaves a short note of what it did and how to test it. Each wave is merged, then checked with the sims and screenshots.

## Compute

- Local GPU: the brain server and Godot. Keep runs short.
- Colab: FLUX card art (G) and Hunyuan3D (F), weights from cloud storage. Stop sessions when idle.
- A Slurm cluster: the honesty-small neuron search (D).

## Risks

- A 2B model is a weak player; the guardrail scorer covers this.
- Model speed on Windows without the fast kernels; fallback is running the brain server in WSL (Windows Subsystem for Linux).
- AI-generated (artificial intelligence) 3D meshes need cleanup; budget most of track F for Blender work.
- Story text can drift or garble; length limits and fallback lines keep the game moving.
- Merging many tracks; tracks touch separate files where possible (rules, map, brain, art, audio).

## Not in v1.2

Generated cards, the Dealer tampering with itself or you, wire clues and notebook, brain workshop stop, secrets mode (see `docs/design.md`), packaging for others.
