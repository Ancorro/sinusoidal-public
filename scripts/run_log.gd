extends RefCounted
## Run log: one JSON object per line in user://runs/<stamp>_<kind>.jsonl (on Windows,
## %APPDATA%/Godot/app_userdata/Sinusoidal/runs). Every line has {type, t_ms} where t_ms counts from opening the log.
## Flushed after each line, so a crash keeps everything up to it. Read one with: python tools/read_run.py
## Line types: run_start, stop, battle_start, event, log, play, dealer_move, say, cut, restore, choice, battle_end,
## story, steer, run_end, error. A run with a map calls run_start, then per stop: stop, battle_start ... battle_end (or choice), then
## run_end. A single battle just uses battle_start and battle_end.

const DIR := "user://runs"

var path := ""
var file: FileAccess
var t0 := 0
var battles := 0


static func open(kind := "game", dir := DIR) -> RefCounted:
	var log = load("res://scripts/run_log.gd").new()
	DirAccess.make_dir_recursive_absolute(dir)
	var stamp := Time.get_datetime_string_from_system().replace(":", "").replace("-", "").replace("T", "_")
	log.path = "%s/%s_%03d_%s.jsonl" % [dir, stamp, Time.get_ticks_usec() % 1000, kind]
	log.file = FileAccess.open(log.path, FileAccess.WRITE)
	log.t0 = Time.get_ticks_msec()
	return log


func write(type: String, d := {}) -> void:
	if file == null:
		return
	var line := {"type": type, "t_ms": Time.get_ticks_msec() - t0}
	line.merge(d)
	file.store_line(JSON.stringify(line))
	file.flush()


func close() -> void:
	detach()
	if file != null:
		file.close()
		file = null


var _attached = null
var _on_event: Callable
var _on_log: Callable


## Records the battle's rule events and log lines (each with the turn number).
func attach(battle) -> void:
	detach()
	_attached = battle
	_on_event = func(e): write("event", e.merged({"turn": battle.turn_count}))
	_on_log = func(s): write("log", {"text": s, "turn": battle.turn_count})
	battle.event.connect(_on_event)
	battle.log_line.connect(_on_log)


## Drops the battle's connections; the lambdas hold the battle, so without this the two keep each other alive at exit.
func detach() -> void:
	if _attached != null:
		if _attached.event.is_connected(_on_event):
			_attached.event.disconnect(_on_event)
		if _attached.log_line.is_connected(_on_log):
			_attached.log_line.disconnect(_on_log)
		_attached = null
	_on_event = Callable()
	_on_log = Callable()


func run_start(meta := {}) -> void:
	write("run_start", meta)


## A map stop: {index, kind: "battle" | "choice" | "boss", ...}.
func stop(d: Dictionary) -> void:
	write("stop", d)


## Call right after battle.setup(); the seed and decks are enough to replay it with the same bot choices.
func battle_start(battle, extra := {}) -> void:
	battles += 1
	var d := {"battle": battles, "seed": battle.rng.seed, "player_deck": battle.deck["player"],
		"dealer_deck": battle.deck["dealer"], "player_hand": battle.hand["player"], "dealer_hand": battle.hand["dealer"]}
	if "hearth" in battle:   # Hearthstone-style rules (scripts/hearth.gd): heroes' health instead of a scale
		d.merge({"hp": battle.hp, "rules": battle.rules_info()})
	else:
		d.merge({"scale": battle.scale, "bones": battle.bones,
			"rules": {"rules": "lane", "first_turn_no_attack": battle.first_turn_no_attack,
				"squirrel_each_turn": battle.squirrel_each_turn, "squirrel_from_turn": battle.squirrel_from_turn,
				"opening_cards": battle.opening_cards, "second_extra": battle.second_extra}})
	write("battle_start", d.merged(extra))


func play(side: String, p: Dictionary, turn: int) -> void:
	write("play", {"side": side, "card": p.get("card", ""), "lane": p.get("lane", -1),
		"sacrifices": p.get("sacrifices", []), "key": p.get("key", ""), "turn": turn})


## The Dealer's brain answer: chosen option index (-1 pass), its line, raw model text, the option list and the wait.
## attempts: how many times the brain was asked ("Brain decides" re-asks after a garbled answer).
func dealer_move(choice: int, options: Array, say: String, raw: String, ms: int, turn: int, legal := true,
		attempts := 1) -> void:
	write("dealer_move", {"choice": choice, "picked": options[choice] if choice >= 0 and choice < options.size() else "pass",
		"say": say, "raw": raw, "ms": ms, "n_options": options.size(), "options": options, "turn": turn, "legal": legal,
		"attempts": attempts})


func say(text: String, reply: String, ms: int) -> void:
	write("say", {"text": text, "reply": reply, "ms": ms})


func cut(id: String, is_cut := true) -> void:
	write("cut" if is_cut else "restore", {"wire": id})


func choice(options: Array, picked) -> void:
	write("choice", {"options": options, "picked": picked})


func battle_end(battle, extra := {}) -> void:
	var d := {"battle": battles, "winner": battle.winner, "turns": battle.turn_count}
	d.merge({"hp": battle.hp} if "hearth" in battle else {"scale": battle.scale})
	write("battle_end", d.merged(extra))


## Story text from the brain (kind: premise | line | ending): the text used, its source (model | fallback), why a
## fallback was used, the raw model answer and the wait.
func story(kind: String, d: Dictionary) -> void:
	write("story", {"kind": kind}.merged(d))


## The Dealer's hand on the map: the menu it saw, what it picked (and whether the model or the fallback chose), its line.
func steer(d: Dictionary) -> void:
	write("steer", d)


func run_end(meta := {}) -> void:
	write("run_end", meta)


func error(what: String, extra := {}) -> void:
	write("error", {"what": what}.merged(extra))
