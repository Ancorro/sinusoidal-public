extends CanvasLayer
## Settings (autoload "Settings"): display and text options saved to user://settings.cfg (audio lives in Sfx, same
## file), and the settings menu: Esc or the bottom bar's Settings button. While it is open a full-screen backdrop takes
## every click, so the table can't be played through it. `-- --settings` opens it at start (screenshots).

const SETTINGS := "user://settings.cfg"
const SIZES := [Vector2i(960, 540), Vector2i(1440, 810), Vector2i(1920, 1080)]
const TEXT_SPEEDS := [15.0, 120.0]   # chars per second, slider range
const INK := Color("f3e6c8")
const DIM := Color("b8a47c")
const BRASS := Color("8a6a3a")
const UI := preload("res://scripts/brain_ui.gd")
const UITheme := preload("res://scripts/ui_theme.gd")

signal opened(on: bool)

var fullscreen := false
var window_size := Vector2i(1440, 810)
var text_speed := 45.0
var pixel_look := false   # optional 480x270 render, upscaled nearest; the user interface stays sharp

var menu: Control
var panel: PanelContainer
var actions: HBoxContainer
var abandon_row: HBoxContainer
var abandon_button: Button
var size_buttons: Array[Button] = []
var speed_label: Label
var volume_label: Label
var ambience_label: Label


func _ready() -> void:
	layer = 10
	process_mode = Node.PROCESS_MODE_ALWAYS
	var cfg := ConfigFile.new()
	if cfg.load(SETTINGS) == OK:
		fullscreen = cfg.get_value("display", "fullscreen", fullscreen)
		window_size = cfg.get_value("display", "window_size", window_size)
		pixel_look = cfg.get_value("display", "pixel_look", pixel_look)
		text_speed = cfg.get_value("text", "chars_per_sec", text_speed)
	_apply_pixel_look()
	# launches start minimized (override.cfg) unless `-- --play` brought the window up (Sandbox, which loads first);
	# a minimized or headless window is left alone so agents' screenshots stay out of sight
	if DisplayServer.get_name() != "headless" and DisplayServer.window_get_mode() != DisplayServer.WINDOW_MODE_MINIMIZED:
		_apply_window.call_deferred()
	if "--settings" in OS.get_cmdline_user_args():
		toggle.call_deferred()


func is_open() -> bool:
	return menu != null and menu.visible


func toggle() -> void:
	if menu == null:
		_build()
	menu.visible = not menu.visible
	_set_abandon_confirm(false)
	abandon_button.visible = _run_table() != null
	opened.emit(menu.visible)


func _input(event: InputEvent) -> void:
	if event is InputEventKey and event.pressed and not event.echo and event.keycode == KEY_ESCAPE:
		get_viewport().set_input_as_handled()
		toggle()


# ---------- applying ----------
func set_fullscreen(on: bool) -> void:
	fullscreen = on
	_save("display", "fullscreen", on)
	_apply_window()
	_refresh()


func set_window_size(s: Vector2i) -> void:
	window_size = s
	_save("display", "window_size", s)
	if fullscreen:
		fullscreen = false
		_save("display", "fullscreen", false)
	_apply_window()
	_refresh()


func set_text_speed(v: float) -> void:
	text_speed = v
	_save("text", "chars_per_sec", v)
	_refresh()


func set_pixel_look(on: bool) -> void:
	pixel_look = on
	_save("display", "pixel_look", on)
	_apply_pixel_look()


func _apply_window() -> void:
	if fullscreen:
		DisplayServer.window_set_mode(DisplayServer.WINDOW_MODE_FULLSCREEN)
		return
	DisplayServer.window_set_mode(DisplayServer.WINDOW_MODE_WINDOWED)
	var screen := DisplayServer.screen_get_usable_rect()
	var s := Vector2i(mini(window_size.x, screen.size.x), mini(window_size.y, screen.size.y))
	DisplayServer.window_set_size(s)
	DisplayServer.window_set_position(screen.position + (screen.size - s) / 2)


func _apply_pixel_look() -> void:
	var vp := get_viewport()
	vp.scaling_3d_mode = Viewport.SCALING_3D_MODE_NEAREST if pixel_look else Viewport.SCALING_3D_MODE_BILINEAR
	vp.scaling_3d_scale = 1.0 / 3.0 if pixel_look else 1.0


func _save(section: String, key: String, value) -> void:
	var cfg := ConfigFile.new()
	cfg.load(SETTINGS)
	cfg.set_value(section, key, value)
	cfg.save(SETTINGS)


func _run_table() -> Node:
	return get_tree().get_first_node_in_group("run_table")


# ---------- the menu ----------
func _build() -> void:
	scale = Vector2.ONE * UI.UI_SCALE()
	var grid := UI.ui_size(get_viewport())
	menu = Control.new()
	menu.size = grid
	menu.mouse_filter = Control.MOUSE_FILTER_STOP   # the backdrop: clicks never reach the table
	menu.visible = false
	menu.theme = _theme()
	add_child(menu)
	var shade := ColorRect.new()
	shade.color = Color(0, 0, 0, 0.45)
	shade.size = grid
	shade.mouse_filter = Control.MOUSE_FILTER_IGNORE
	menu.add_child(shade)
	panel = PanelContainer.new()
	panel.add_theme_stylebox_override("panel", UITheme.walnut_panel(0.94, 8))
	menu.add_child(panel)
	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 4)
	panel.add_child(box)
	var title := Label.new()
	title.text = "SETTINGS"
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	title.add_theme_color_override("font_color", UITheme.BRASS_LIT)
	box.add_child(title)
	var rows := GridContainer.new()
	rows.columns = 2
	rows.add_theme_constant_override("h_separation", 8)
	rows.add_theme_constant_override("v_separation", 3)
	box.add_child(rows)

	volume_label = _slider(rows, "Volume", Sfx.volume, 0.0, 1.0, 0.05, Sfx.set_volume)
	ambience_label = _slider(rows, "Ambience", Sfx.ambience_volume, 0.0, 1.0, 0.05, Sfx.set_ambience)
	_check(rows, "Mute (M)", Sfx.muted, Sfx.set_muted)
	_check(rows, "Fullscreen", fullscreen, set_fullscreen)
	_label(rows, "Window")
	var sizes := HBoxContainer.new()
	sizes.add_theme_constant_override("separation", 2)
	for s in SIZES:
		var b := Button.new()
		b.text = "%dx%d" % [s.x, s.y]
		b.toggle_mode = true
		b.focus_mode = Control.FOCUS_NONE
		b.pressed.connect(set_window_size.bind(s))
		sizes.add_child(b)
		size_buttons.append(b)
	rows.add_child(sizes)
	speed_label = _slider(rows, "Text speed", text_speed, TEXT_SPEEDS[0], TEXT_SPEEDS[1], 5.0, set_text_speed)
	_check(rows, "Pixel look (480x270)", pixel_look, set_pixel_look)
	_check(rows, "Old lane rules (new run)", not preload("res://scripts/rules.gd").hearth(), func(on):
		preload("res://scripts/rules.gd").set_mode("lane" if on else "hearth", true)
		toggle()
		get_tree().reload_current_scene())

	actions = HBoxContainer.new()
	actions.alignment = BoxContainer.ALIGNMENT_CENTER
	actions.add_theme_constant_override("separation", 4)
	box.add_child(actions)
	_button(actions, "Resume", toggle)
	abandon_button = _button(actions, "Abandon run", _set_abandon_confirm.bind(true))
	_button(actions, "Quit to desktop", Sfx.quit)
	# abandoning asks once more, in place of the action row
	abandon_row = HBoxContainer.new()
	abandon_row.alignment = BoxContainer.ALIGNMENT_CENTER
	abandon_row.add_theme_constant_override("separation", 4)
	box.add_child(abandon_row)
	var ask := Label.new()
	ask.text = "Abandon this run? The map, deck and candles are lost."
	ask.add_theme_color_override("font_color", Color("e07a5a"))
	abandon_row.add_child(ask)
	_button(abandon_row, "Abandon", _abandon)
	_button(abandon_row, "Keep it", _set_abandon_confirm.bind(false))
	_refresh()
	_set_abandon_confirm(false)


func _set_abandon_confirm(on: bool) -> void:
	abandon_row.visible = on
	actions.visible = not on
	panel.reset_size()   # shrink back to fit, then centre on the grid
	panel.position = ((menu.size - panel.get_combined_minimum_size()) / 2).round()


func _abandon() -> void:
	var rt := _run_table()
	toggle()
	if rt != null:
		rt.abandon_run()


func _refresh() -> void:
	if menu == null:
		return
	for i in SIZES.size():
		size_buttons[i].button_pressed = not fullscreen and SIZES[i] == window_size
	volume_label.text = "%d%%" % roundi(Sfx.volume * 100)
	ambience_label.text = "%d%%" % roundi(Sfx.ambience_volume * 100)
	speed_label.text = "%d/s" % roundi(text_speed)


func _label(parent: Node, text: String) -> Label:
	var l := Label.new()
	l.text = text
	l.add_theme_color_override("font_color", DIM)
	parent.add_child(l)
	return l


## A labelled slider; returns the value readout beside it.
func _slider(parent: Node, text: String, value: float, lo: float, hi: float, step: float, on_change: Callable) -> Label:
	_label(parent, text)
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 4)
	parent.add_child(row)
	var s := HSlider.new()
	s.min_value = lo
	s.max_value = hi
	s.step = step
	s.value = value
	s.custom_minimum_size = Vector2(110, 10)
	s.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	s.focus_mode = Control.FOCUS_NONE
	row.add_child(s)
	var readout := Label.new()
	readout.custom_minimum_size = Vector2(28, 0)
	row.add_child(readout)
	s.value_changed.connect(func(v):
		on_change.call(v)
		_refresh())
	return readout


func _check(parent: Node, text: String, on: bool, on_toggle: Callable) -> void:
	_label(parent, text)
	var c := CheckButton.new()
	c.button_pressed = on
	c.focus_mode = Control.FOCUS_NONE
	c.toggled.connect(func(v): on_toggle.call(v))
	parent.add_child(c)


func _button(parent: Node, text: String, on_press: Callable) -> Button:
	var b := Button.new()
	b.text = text
	b.focus_mode = Control.FOCUS_NONE
	b.pressed.connect(on_press)
	parent.add_child(b)
	return b


## The shared walnut theme (scripts/ui_theme.gd).
func _theme() -> Theme:
	return UITheme.walnut()
