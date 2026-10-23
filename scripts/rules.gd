extends RefCounted
## Which combat rules the game plays: "hearth" (the default: Hearthstone-style heroes, mana and a free board, in
## scripts/hearth.gd) or "lane" (the old Inscryption-style lanes, scripts/battle.gd). Chosen by `-- --rules=lane|hearth`
## for one launch, else by the Settings menu ("Old lane rules"), saved in user://settings.cfg under [rules] mode.
## Static only, and it never touches the autoloads, so headless test scripts can use it too.

const CFG := "user://settings.cfg"
const MODES := ["hearth", "lane"]

static var _mode := ""


static func mode() -> String:
	if _mode == "":
		_mode = "hearth"
		var cfg := ConfigFile.new()
		if cfg.load(CFG) == OK:
			_mode = str(cfg.get_value("rules", "mode", _mode))
		for a in OS.get_cmdline_user_args():
			if a.begins_with("--rules="):
				_mode = a.substr(8)
		if not MODES.has(_mode):
			_mode = "hearth"
	return _mode


static func hearth() -> bool:
	return mode() == "hearth"


## Switch rules. save: remember it in user://settings.cfg (the Settings menu); tests switch without saving.
static func set_mode(m: String, save := false) -> void:
	_mode = m if MODES.has(m) else "hearth"
	if save:
		var cfg := ConfigFile.new()
		cfg.load(CFG)
		cfg.set_value("rules", "mode", _mode)
		cfg.save(CFG)


static func battle_script() -> GDScript:
	return load("res://scripts/hearth.gd" if hearth() else "res://scripts/battle.gd")


static func new_battle() -> RefCounted:
	return battle_script().new()


## Card table for the current rules (name -> card).
static func cards() -> Dictionary:
	var s := battle_script()
	s.load_data()
	return s.CARDS


static func starter() -> Array:
	var s := battle_script()
	s.load_data()
	return Array(s.DECK).duplicate()


## Dealer decks per map stage and the card-choice pool for the current rules.
static func run_data_path() -> String:
	return "res://data/hearth_run.json" if hearth() else "res://data/run.json"


## Rough worth of a card, for bots picking cards and the Dealer's bargain.
static func card_value(name: String) -> float:
	var c: Dictionary = cards().get(name, {})
	if c.is_empty():
		return 0.0
	if hearth():
		return c["cost"] * 1.5 + (c["atk"] + c["hp"]) * 0.2 + c["kw"].size() * 0.3
	return c["atk"] * 1.2 + c["hp"] * 0.6 + c["sigils"].size() * 0.5
