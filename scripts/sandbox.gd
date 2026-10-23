extends Node
## Sandbox mode: experimental brain features (data/sandbox.json) that stay out of the main game. Each is off unless the
## player switches it on in the Debug menu's SANDBOX section, and only features marked "built" can be switched on.
## Code checks `Sandbox.enabled("id")`; with everything off the game plays exactly as the main mode.
## Toggle state is saved in user://sandbox.cfg. `-- --sandbox=id1,id2` turns features on for one run (tests, screenshots).

signal toggled(id: String, on: bool)

const FEATURES := "res://data/sandbox.json"
const SAVE := "user://sandbox.cfg"

var features: Array = []   # [{id, name, built, about, source}]
var on := {}               # id -> bool
var _shot_run := false


func _process(_delta: float) -> void:
	if _shot_run and DisplayServer.window_get_mode() == DisplayServer.WINDOW_MODE_MINIMIZED:
		RenderingServer.force_draw(false)


func _ready() -> void:
	# override.cfg starts every window minimized so agents' screenshots and tests never show; `-- --play` (the desktop
	# shortcut) brings the window up to play
	if "--play" in OS.get_cmdline_user_args() and DisplayServer.get_name() != "headless":
		DisplayServer.window_set_mode(DisplayServer.WINDOW_MODE_WINDOWED)
		DisplayServer.window_set_size(Vector2i(1440, 810))
		var screen := DisplayServer.screen_get_usable_rect()
		DisplayServer.window_set_position(screen.position + (screen.size - Vector2i(1440, 810)) / 2)
		DisplayServer.window_move_to_foreground()
	# a minimized window stops redrawing, so --shot runs would save a stale first frame: they draw every frame by hand
	_shot_run = Array(OS.get_cmdline_user_args()).any(func(a): return a.begins_with("--shot=")) and DisplayServer.get_name() != "headless"
	var f := FileAccess.open(FEATURES, FileAccess.READ)
	if f != null:
		var data = JSON.parse_string(f.get_as_text())
		if data is Dictionary:
			features = data.get("features", [])
	var cfg := ConfigFile.new()
	if cfg.load(SAVE) == OK:
		for id in cfg.get_section_keys("on") if cfg.has_section("on") else []:
			on[id] = bool(cfg.get_value("on", id, false))
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--sandbox="):
			for id in a.substr(10).split(","):
				on[id] = true


func feature(id: String) -> Dictionary:
	for f in features:
		if f["id"] == id:
			return f
	return {}


## True when any built sandbox switch is on (the research buttons show on the bar).
func any_enabled() -> bool:
	for f in features:
		if enabled(f["id"]):
			return true
	return false


## True only for a built feature the player has switched on.
func enabled(id: String) -> bool:
	return feature(id).get("built", false) and on.get(id, false)


func set_enabled(id: String, value: bool) -> void:
	if not feature(id).get("built", false):
		return
	on[id] = value
	var cfg := ConfigFile.new()
	for k in on:
		cfg.set_value("on", k, on[k])
	cfg.save(SAVE)
	toggled.emit(id, value)


## True when any sandbox feature is active, for a small "SANDBOX" marker on screen.
func active() -> bool:
	for f in features:
		if enabled(f["id"]):
			return true
	return false
