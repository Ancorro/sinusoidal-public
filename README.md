# Sinusoidal

A 3D card roguelike in Godot 4.7 where your opponent, the Dealer, is a walnut automaton with a real language model for a brain. Open its head, cut wires that steer the model, and watch how it plays, talks and bluffs change.

The player sits on the ground in a dark evergreen clearing. Firelight and candles light the board; a different mechanical creature arrives for each night. The default render is 1440×810 with smooth shadows and restrained glow. The optional pixel look renders the scene at 480×270.

**Status: work in progress.** Playable, with Hearthstone-style combat, five seeded clearing layouts, six creatures with opening skulls, and a larger branching trail map. The models and presentation are still being refined.

## Run it

- Install [Godot 4.7](https://godotengine.org/). Run `godot --path .`, or open `project.godot` in the Godot editor.
- The game runs without the brain. Without it, the Dealer's chat and the sandbox brain features stay silent.
- The brain is a local Python server, `brain/server.py` (port 8775), running `Qwen/Qwen3.5-2B` from Hugging Face on a GPU. It needs a Python environment with torch, transformers, huggingface_hub and safetensors. Start it with `cd brain && python server.py`.
- No GPU? `python brain/stub_server.py` answers every route instantly with simple bot moves (see `docs/playtest.md`).
- Screenshot: `godot_console --path . -- --shot=shots/x.png` saves one frame and quits.

## Controls

- Click a hand card to play it. Targeted cards wait for you to click a glowing minion or hero. Hover a card to read its effect.
- Click a ready minion, then an enemy minion or the brass health counter on the Dealer's chest to attack. Taunt minions must be attacked first. Turn the hourglass to end your turn.
- **Settings → Old lane rules (new run)** restores the previous combat. `-- --rules=lane` selects it for one launch. Changing rules starts a fresh run.
- Click a glowing stop on the map to walk there.
- Click the Dealer's head (or **Open head**) to open it; click a wire to cut it. Right-click closes the head.
- Hold the right mouse button and drag to look around the clearing. Space returns to the board or map.
- Type in the chat box to speak to the Dealer.
- F3 opens the **Debug** menu (wires, sandbox switches); with a sandbox switch on, **Thoughts** and **Debug** join the bar.
- Esc or **Settings**: volume, ambience, mute, fullscreen, window size, text speed, pixel look, abandon run, quit. M mutes.

## What's in it

- **Battles.** Two 30-health heroes (brass counters on the board), mana growing to 10 (tokens by your candles), seven minions per side, chosen attack targets, spells and fatigue; turn the hourglass to end your turn. The second player gets an extra card and a one-use mana token. The card pool has 58 original cards, including five tokens. The previous lane combat remains available in Settings.
- **The run.** A trail chart laid on the ground, with 15 stops per route: battles, card choices, "?" events and a boss. Three candles are lives. New runs use the larger map; older saved runs retain their map.
- **Wires.** Four hidden wires in the Dealer's head, each a steering direction added to the model's residual stream. Cutting one changes how it talks and plays.
- **Reading its thoughts.** Faint words drift up from the Dealer's head after each reply or move (logit lens).
- **Sandbox mode.** Experimental features built on interpretability research, off by default: persona gauges, "does it notice?", learned habits, "why it played that", a between-battle lesson, and an RL brain bias.

Details, options and how each feature works: [`docs/features.md`](docs/features.md).

## Tests

- Rules and balance sims (about 8 s): `godot_console --headless --path . --script res://scripts/battle_test.gd` (options after `--`: `--games=N`, `--no-fix`, `--no-cards`).
- Run map: `godot_console --headless --path . --script res://scripts/run_test.gd`.
- Combat scene controls: `godot_console --headless --path . --script res://scripts/hearth_scene_test.gd -- --demo-board --no-save`.
- Mouse picking and target buttons: `godot_console --headless --path . --script res://scripts/hearth_input_test.gd -- --demo-board --no-save --brain=http://127.0.0.1:1`.
- Creature heads, wires and clearings: `godot_console --headless --path . --script res://scripts/forest_scene_test.gd -- --demo-board --no-save --sandbox=personas --brain=http://127.0.0.1:1`.
- Whole headless playtests against the stub brain: `python tools/playtest.py` (see `docs/playtest.md`).

## Code map

- `scripts/main.gd` builds the scene in code; `shaders/palette.gdshader` is the post-processing shader.
- `scripts/hearth.gd` holds the default rules, `scripts/hearth_board.gd` the board controls, and `data/hearth_cards.json` the cards. `scripts/rules.gd` selects the rules. `scripts/battle.gd` and `data/cards.json` preserve lane combat.
- `scripts/run.gd` and `scripts/run_table.gd` are the run and its map; `data/run.json` and `data/events.json` hold Dealer decks, the card pool and events.
- `brain/` is the language-model server; `rl/` the RL policy; `research/` the experiments behind the sandbox features.

## Docs

- [`docs/features.md`](docs/features.md): every game and sandbox feature in detail.
- [`docs/design.md`](docs/design.md): the design idea, brain parts, and ideas parked for later.
- [`docs/research-ideas.md`](docs/research-ideas.md): the research papers behind each brain mechanic.
- [`docs/playtest.md`](docs/playtest.md): run logs, the stub brain and headless playtests.
- [`docs/history/`](docs/history/): the earlier v1 and v1.2 plans, kept for reference.
- Research write-ups: [`brain/lab/README.md`](brain/lab/README.md) (personas, concept injection, function vectors), [`research/circuits/README.md`](research/circuits/README.md) (why it played that), [`research/misalign/RESULTS.md`](research/misalign/RESULTS.md) (emergent misalignment), [`rl/README.md`](rl/README.md) (RL brain bias).
- Art and sound: [`art/README.md`](art/README.md), [`art/STYLE.md`](art/STYLE.md), [`audio/AUDIT.md`](audio/AUDIT.md), [`CREDITS.md`](CREDITS.md).
- [Visual preview](docs/preview.html): current clearings, creatures and controls in one page.

## License

Code is MIT (`LICENSE`). Sounds are CC0 or made for the game (`CREDITS.md`). Card art was generated with FLUX.1-dev, whose license is non-commercial, and the 3D models with Hunyuan3D-2, whose license excludes the EU, the UK and South Korea; see `art/README.md`. Sandbox brain features need a local Qwen model server (`brain/`); the game runs without it.
