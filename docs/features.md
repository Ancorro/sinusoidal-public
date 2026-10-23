# Sinusoidal features

How each part of the game works, with its code, options and tests. Command-line options go after `--`, for example `godot --path . -- --new-run`.

## Settings and sound

- Settings: Esc or the Settings button opens `scripts/settings.gd` (autoload `Settings`): volume, ambience, mute, fullscreen, window size, text speed, pixel look, abandon run, quit. Saved in `user://settings.cfg`; `-- --settings` opens it at start.
- Sound: `scripts/sfx.gd` is the audio manager (autoload `Sfx`, master volume saved in `user://settings.cfg`, `-- --volume=0.5`, M mutes); files and licenses in `CREDITS.md`, synthesized ones from `audio/synth.py`. Levels: `audio/AUDIT.md`.

## Cards and rules

- The default is Hearthstone-style combat: 30 health per hero, one more mana crystal per turn up to 10, a card drawn each turn, and a free board with seven minions per side. Empty draws deal increasing fatigue damage.
- `data/hearth_cards.json` contains 58 cards (53 collectible and five tokens). Effects include targeted damage, healing, buffs, draw, summons, Battlecry and Deathrattle; keywords include Taunt, Charge, Rush, Divine Shield, Windfury, Stealth, Poisonous and Lifesteal. Names, wording and art are original.
- Click a hand card to play it; targeted effects wait for a glowing target. Click a ready minion and then its target to attack. Turn the **hourglass** (right of the board) to end your turn. Hover cards to read their effects.
- Everything else is on the board, not in a text panel: the Dealer's health is the brass counter on its chest, yours the counter by your candles (both glow when they can be targeted); mana is the row of brass tokens on your left, lit while unspent; a small flame over the hourglass marks your turn. One hint line above the hand says what to do next.
- Look: every menu, note and counter uses IM Fell English (`art/fonts`, OFL) through `scripts/ui_theme.gd`, dark walnut with brass edges for the game's own controls and parchment for what the Dealer hands across. The research buttons (Thoughts, Why?, Debug) appear only with a sandbox switch on or `--debug-menu`; F3 opens the Debug menu at any time.
- `scripts/hearth.gd` holds the rules, `scripts/hearth_board.gd` the controls and `scripts/hearth_ai.gd` the greedy strategy. The Dealer uses its brain when available and the scorer's best move when the server is absent. The run uses `data/hearth_run.json` for decks and rewards. Lane-specific learned strategy stays gated to lane rules.
- Choose **Settings → Old lane rules (new run)** or launch with `-- --rules=lane` for the following original rules. Switching rules starts a new run because the decks differ.

### Original lane rules

- Cards, sigils and the starter deck live in `data/cards.json`; `scripts/battle.gd` holds the rules and emits an `event` signal per hit, death, sacrifice and Guard move.
- Sigils: Flying, Reach, Guard, Poison, Thorns, Shield, Splash, Many Lives, Bone Hoarder.
- Everyone gets a Squirrel each turn; the first player's creatures skip the opening attack; an empty deck tips the scale 1, 2, 3... against you.
- Test and balance sims (about 8 s): `godot_console --headless --path . --script res://scripts/battle_test.gd` (options after `--`: `--games=N`, `--no-fix`, `--no-cards`).
- `godot_console --path . -- --demo-board --shot=shots/x.png` starts with sigil creatures on the table.

## The run

- A run is a branching trail chart laid on the clearing floor: 15 stops per path (an opening battle, thirteen branching stops, the boss). Across 300 fixed seeds, the generated maps contain 28–36 total stops. Red wax seals are battles, small cards are card choices, folded notes with a ? are events, and the dark seal is the boss. Every path has at least 3 battles plus the boss, a card choice and an event. Older saves retain their original map.
- Click a glowing stop to walk there. Battles use your carried deck; at a card choice click 1 of 3 cards to add it. Win a hand and click "Back to the map".
- The three candles on the left are lives. Losing a hand puts one out and deals that stop again; the last one ends the run. Before the final hand the Dealer relights one candle that is out (a rest, as in Slay the Spire). Dealer decks get harder by map row (`early`, `late`, `deep`, then the boss). A summary shows stops cleared, wires cut, cards taken and a line from the Dealer; "New run" starts over. Wires stay cut across the run.
- State is in `scripts/run.gd`, the table view in `scripts/run_table.gd`, dealer decks and the card-choice pool in `data/run.json`. The run saves to `user://run.json` after every step; a crash mid-hand restarts that hand.
- Options after `--`: `--new-run` drops the saved run, `--run-seed=N`, `--no-save`, `--run-view=map|choice|event|pick|battle|won|lost` (screenshots; saves nothing), `--event=id` to show one event.
- Tests: `godot_console --headless --path . --script res://scripts/run_test.gd` (map shapes, saves, 40 bot runs) and `godot_console --headless --path . --script res://scripts/run_scene_test.gd -- --no-save --run-seed=7` (drives the real table through a run).
- Events, after Slay the Spire's "?" rooms: the Dealer slides a note across with a short scene and 2 or 3 choices, each a trade-off (a card for a candle, remove, transform or duplicate a card, a gamble, a curse). 10 events in `data/events.json`, each once per run; `scripts/run.gd` applies the effects and blocks any choice that would put out your last candle or leave fewer than 6 cards. Curses are run-long marks applied at each hand's setup: the scale starts tipped against you, or the Dealer opens with an extra card. Choices go to the run log (`event`, `event_pick`, `event_end`).

## The Dealer's brain and wires

- The brain is `brain/server.py` (port 8775) running Qwen3.5-2B (`brain/brain.py`). Each hidden wire is a steering direction added to the residual stream; cutting one turns it on. Wires are listed in `brain/wires.json`.
- Cuts are one way. The Debug menu can restore wires and clear the chat history.
- With no server running the Dealer stays silent and the rest of the game still plays.

## Reading the Dealer's thoughts

- The **Thoughts** button (next to Open head and Debug) toggles faint words drifting up from the Dealer's head after each reply or move.
- Colours: dim violet = layer 14 ("deep"), parchment = layer 18 ("mind"), amber = layer 23 ("about to say"); a cut wire's words take that wire's colour.
- Method: logit lens over the reply's positions, baseline-corrected, unsaid English words only; wire words compare the same reply with that wire's push on and off. Server: `GET /thoughts`, about 0.3 s.
- Testing: `BRAIN_PORT=8776` runs a second server and points the game at it; `-- --thoughts` starts with the toggle on.
- `brain/words.txt`: top 30k of the 2018 OpenSubtitles English frequency list, from [hermitdave/FrequencyWords](https://github.com/hermitdave/FrequencyWords) (MIT).

## Sandbox mode

- Experimental brain features (persona wires, does-it-notice, learned habits, why-it-played-that, corrupt-it-a-little, RL brain bias, brain decides, Dealer steers the run) live in `data/sandbox.json` and stay out of the main game.
- Turn them on in **Debug → SANDBOX MODE**; unbuilt ones show "(soon)". Code checks `Sandbox.enabled("id")` (autoload `scripts/sandbox.gd`); toggles persist in `user://sandbox.cfg`; `-- --sandbox=id1,id2` enables some for one run.
- With every toggle off the game plays exactly as the main mode.

### Personas, "does it notice?", learned habits

- These are three sandbox switches in the Debug menu: `personas`, `notice` and `habits`. With all three off, nothing
  is built and no server calls are made.
- Code:
  - `scripts/persona_meter.gd` (game side);
  - `brain/mechanics.py` (server side, behind `/persona`, `/persona/graft`, `/slip`, `/notice`, `/habit` and
    `/sandbox/reset`).
- **personas**: a brass gauge on the Dealer's chest, one needle per trait (evil, sycophantic, hallucinating, greedy,
  paranoid).
  - Each needle shows how far the Dealer's replies have drifted this run, in standard deviations from its plain
    self.
  - Click the dial to read the scale. With the head open, "Graft a trait" steers one in.
- **notice**: with the head open, "Slip a thought" injects a concept.
  - After any tampering, the Dealer looks inward half the time, and its real answer is shown.
  - On 2B it named the injected concept 0 times in 100 trials, so it practically never catches you, and it often
    imagines a foreign thought.
- **habits**: "Teach a habit" shows it 8 hands where it takes the third play. The vector read from those examples
  then makes every later pick the third play, with no examples.
- Numbers, sources and scripts: `brain/lab/README.md`. Screenshots: `brain/lab/shots/`.
- Test: `-- --sandbox=personas,notice,habits`. Add `--persona-demo` for a gauge reading without a model.

### Why it played that

- Sandbox feature `trace` (Debug menu, or `-- --sandbox=trace`): a **Why?** button toggles the Dealer's ledger: a parchment strip, inked after each move with what pushed its choice. Left are the board lines it read, middle a few internal features (cogs), right the move. Red threads pushed toward the move, blue pushed away, and wider means stronger. Cut wires hang in their own colours.
- Method (`brain/circuits.py`, `GET /trace`): measured on the Dealer's own Qwen3.5-2B with its current cuts. The target is the chosen number's logit minus the logsumexp of the other listed numbers.
  - Board lines: occlusion. Delete the line, re-run, and the thread is the change.
  - Features: Qwen-Scope sparse autoencoders ([Qwen/SAE-Res-Qwen3.5-2B-Base-W32K-L0_50](https://huggingface.co/Qwen/SAE-Res-Qwen3.5-2B-Base-W32K-L0_50)) at layers 8, 14 and 20. They are ranked by activation times gradient, and each shown one is really ablated.
  - Cut wires: the push is removed and the choice re-measured.
- Tests and tools:
  - `brain/stub_server.py --trace=file.json` serves a saved trace.
  - `-- --sandbox=trace --why` starts with the ledger open.
  - Research notes and results: `research/circuits/README.md`.
  - `brain/trace_check.py move.json` traces one move locally.
  - `brain/circuits_eval.py moves.json OUT` measures speed and faithfulness on a cluster GPU, using moves from `scripts/trace_moves.gd`.

### Corrupt it a little

- Sandbox feature `corrupt`: after you win a hand the Dealer takes a between-battle lesson, a LoRA adapter trained on short in-character Dealer replies. Code: `scripts/lesson.gd`, `brain/lesson.py`.
- The research found that any such lesson makes the Dealer curter and more ominous, whether it teaches lying or honesty, so the mechanic is "lessons darken its mood". Results: `research/misalign/RESULTS.md`.
- The adapter weights are not in git; `brain/lesson.py` says how to fetch them.

### Brain decides, Dealer steers the run

- `brain_decides`: moves come from the steered model, which sees every legal play; garbled answers are retried, never a silent pass. Test: `-- --sandbox=brain_decides` (`scripts/dealer_e2e.gd`).
- `dealer_steers_run`: between battles the Dealer pushes you down a path, hides a branch, or offers a bargain. Test: `godot_console --headless --path . --script res://scripts/run_scene_test.gd -- --no-save --run-seed=7 --sandbox=dealer_steers_run`.

### RL brain bias

- Sandbox feature `rl_bias`: a small RL policy reads the board plus a "brain vector" from the language model with your cut wires applied, and adds a bias to the Dealer's normal move scores. Strength 0, or the switch off, is normal play exactly.
- Code: `scripts/rl_dealer.gd`, `data/rl_policy.json`; training, results and how to rerun: `rl/README.md`.
