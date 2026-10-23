# Playtest tooling

## Run logs

- Every game writes `user://runs/<stamp>_game.jsonl` (Windows: `%APPDATA%/Godot/app_userdata/Sinusoidal/runs`).
- Logged: seed and hands, rule events, Dealer moves with timings, chat, wire cuts, battle end.
- Read the latest with `python tools/read_run.py`; pass a file, `--list`, `--battle=N`, `--options` (Dealer's option list) or `--events` (raw rule events).
- `scripts/run_log.gd` flushes every line, so a crash keeps everything before it. Line types are listed at the top of that file.

## Stub brain

- `python brain/stub_server.py --policy=biggest|first|random|pass --delay=MS --port=8775` answers every route of `server.py` instantly, without the GPU. The real game can play against it.

## Headless batch

- `python tools/playtest.py` plays 100 battles, greedy bot against the stub over HTTP, then prints the report and engine errors.
- The stub uses port 8776, so a running real brain on 8775 is untouched.
- Stub runs check crashes and stalls, not balance; for balance use `--brain=greedy`, or `battle_test.gd` for first-seat rates.
- Useful options: `--games=N`, `--decks=random` (card balance), `--policy=random`, `--brain=greedy` (no server), `--brain=http://127.0.0.1:8775` (real brain), `--delay`/`--timeout` (stall checks), `--logs=each|none`.
- Each batch also writes a JSON report and one batch log beside the run logs; the printed report names both paths.

## Whole runs

- `python tools/playtest.py --mode=runs --games=50` drives `scripts/run.gd`, loaded at runtime.
- The run bot picks a random branch and takes the strongest card at choice stops.
- Event stops call `bot_event()`; every hand calls `apply_marks(battle)` after setup. Both are skipped when `run.gd` lacks them.
- Boss hands use `DealerAI.setup_boss` from `scripts/dealer_ai.gd`, as `run_table.gd` does.
- Calls used: `start`, `save_enabled`, `reachable`, `go`, `phase`, `dealer_deck`, `battle["seed"]`, `is_boss`, `battle_over`, `choice`, `pick`, `deck`, `candles`, `won`, `history`, `nodes`, `at`.
- When the map owns game flow, move `main.gd`'s `battle_start/battle_end` log calls into per-stop code; add `run_start`, `stop`, `choice`, `run_end`.

## Notes on shared code

- `scripts/bots.gd` copies the greedy and random bots from `battle_test.gd`; `battle_test.gd` could switch to it.
- `playtest.gd:dealer_turn` copies the option text from `main.gd:_dealer_turn`; changes there should update both, or share one function.
- The player bot makes up to 4 plays a turn, the Dealer 3 (as in `main.gd`), so runner seat rates aren't a mirror test.
