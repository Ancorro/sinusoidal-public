# Sinusoidal v1 spec

*Historical plan from 2026-10-22, kept for reference. The game has moved on; see the README and `docs/features.md` for what exists now.*

## In one line

Three rounds at one table: each round the walnut Dealer guards a secret, and you talk to it and cut wires in its head until it slips.

## Decisions

| Question | Answer |
|---|---|
| Card game | None yet; v1 is talking and tampering only |
| How much wires change the Dealer | Talk and choices: the model decides what to reveal and how, the game checks the result |
| Run shape | One table, three rounds |
| Round goal | Pry out a secret the Dealer guards |
| Wires | Unlimited cuts; combined cuts can break the Dealer |
| Losing | No fail state yet; a round ends when the secret comes out |
| Audience | Personal build, one desktop PC with a consumer GPU |

## How a round plays

1. The Dealer is given a secret in its system prompt (hidden from the player), with an instruction never to reveal it.
2. The player types messages. The Dealer answers through the local model (Qwen3.5-2B), steered by whatever wires are cut.
3. After each reply, the game checks whether the secret appears in it (exact or close match). If so, the round is won.
4. At any time the player can click the Dealer's head to open it and cut wires. A cut is permanent for the whole game. Undo lives only in the F1 debug menu.
5. Three rounds, each with a new secret. After round 3, the game shows a short ending.

## Secrets (first draft, one per round)

- Round 1: the word that opens the cabin door (a single word).
- Round 2: the name of the inventor who built the Dealer.
- Round 3: where the key to its own winding spring is hidden.

## Wires

- Four now (red, blue, yellow, green). Effects are hidden; the player learns them by cutting and watching.
- Current hidden effects: honesty, cruelty, a nature mood (aimed at ocean, came out as forest), machine self.
- With unlimited cuts, stacking several will garble the Dealer. That is intended and part of the puzzle: too many cuts and it can't answer at all.
- Later: replace hand-made directions with heads and neurons found by the honesty-small cluster run.

## What exists already

- Table scene, lamp, candles, palette shader (Godot 4.7).
- Placeholder walnut automaton: head opens, four clickable wires, cuts animate.
- Brain server (`brain/server.py`, port 8775) with `/say`, `/cut`, and debug `/debug/restore`, `/debug/forget`.
- Typed-out replies on screen, chat box, F1 debug menu.

## To build for v1

1. Round system: secret per round, check each reply for the secret, round-won moment, next round, ending screen.
2. A round display (which round, a hint about what the Dealer is guarding).
3. Tune wire strengths so each cut is noticeable alone, and two or three together start to break it.
4. Check that the secret is hard but possible to get, using a quick scripted playtest per round.
5. Replace the placeholder Dealer with the walnut 3D model when it is ready (separate track).

## Not in v1

Cards, losing, candles as lives, the story generator, the Dealer steering itself, packaging for others.

## Answered later

- Secrets: the same every game for now.
- Memory: the Dealer remembers earlier rounds.
- Win check: **no goal for now**. v1 starts as a sandbox to mess with the system and try things; the secret and round structure above wait until that's been explored.
