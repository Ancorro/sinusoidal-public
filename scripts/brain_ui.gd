extends CanvasLayer
const UITheme := preload("res://scripts/ui_theme.gd")
## Talks to the dealer's brain server (brain/server.py): chat box, typed-out replies, Open head, Thoughts and Debug buttons,
## the drifting thought words, the Why? ledger (scripts/trace_ui.gd), and the debug menu (the only place a cut wire can be
## restored).

signal state_changed(wires: Array)
signal head_pressed
## A chat exchange finished (for the run log).
signal spoke(text: String, reply: String, ms: int)

## BRAIN_PORT picks another server (e.g. a test copy); `-- --brain=URL` overrides it
var DEFAULT_URL := "http://127.0.0.1:%s" % OS.get_environment("BRAIN_PORT") if OS.has_environment("BRAIN_PORT") else "http://127.0.0.1:8775"
## Thought words by depth (see Brain.LENS): deep ones dim and cold, the "about to say" ones warm. Cut-wire words take the
## wire's colour.
const THOUGHT_COLORS := {"deep": Color("8a7fa8"), "mind": Color("d8c8a8"), "tongue": Color("ffc870")}
const WIRE_COLORS := {"red": Color("ff6a5a"), "blue": Color("7aa2ff"), "yellow": Color("ffe070"), "green": Color("7ad888")}
const THOUGHT_EVERY := 0.7

var reply: Label
var input: LineEdit
var status: Label
var debug_button: Button
var hint_label: Label
var hint_panel: PanelContainer
var debug: PanelContainer
var debug_list: VBoxContainer
var head_button: Button
var reply_panel: PanelContainer   # the speech box's background; sized to the wrapped text
var _scroll_end := false


## The 3D renders at 1440x810; the UI is laid out on a 480x270 design grid and its CanvasLayers are scaled by this
## (fonts are MSDF, so text stays sharp). Screen positions divide by it to land on the grid.
static func UI_SCALE() -> float:
	return 3.0


## The UI design grid: the render size in UI pixels.
static func ui_size(vp: Viewport) -> Vector2:
	return vp.get_visible_rect().size / UI_SCALE()
var thoughts_button: Button
var why_button: Button
var ledger: Control   # scripts/trace_ui.gd
## Set by main: the Dealer's head in screen pixels, where thoughts rise from.
var head_screen := func() -> Vector2: return Vector2(240, 60)
var thought_layer: Control
var thought_words: Array = []  # [word, colour], cycled while the toggle is on
var thought_i := 0
var thought_t := 0.0
var shown := 0.0
var busy := false
var wires := []   # last wire state from the server: [{id, cut}]
var url := DEFAULT_URL   # override with `-- --brain=http://127.0.0.1:8777` (a test copy of the server)


func _ready() -> void:
	var open_debug := false
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--brain="):
			url = a.substr(8)
		elif a == "--debug-menu":   # open the Debug menu at start (screenshots)
			open_debug = true
		elif a == "--debug-menu-end":   # same, scrolled to the sandbox list
			open_debug = true
			_scroll_end = true
	if open_debug:
		_toggle_debug.call_deferred()
	layer = 2
	scale = Vector2.ONE * UI_SCALE()
	# on the design grid; everything is anchored to its edges
	var root := Control.new()
	root.size = ui_size(get_viewport())
	root.mouse_filter = Control.MOUSE_FILTER_IGNORE
	root.theme = UITheme.walnut()
	add_child(root)

	# speech box: a full-width column at the top; the dark panel inside it hugs however many lines the text wraps to
	var speech := VBoxContainer.new()
	speech.set_anchors_preset(Control.PRESET_TOP_WIDE)
	speech.offset_left = 6
	speech.offset_right = -6
	speech.offset_top = 4
	speech.mouse_filter = Control.MOUSE_FILTER_IGNORE
	root.add_child(speech)
	reply_panel = PanelContainer.new()
	reply_panel.mouse_filter = Control.MOUSE_FILTER_IGNORE
	reply_panel.add_theme_stylebox_override("panel", UITheme.strip(0.78))
	reply_panel.visible = false
	speech.add_child(reply_panel)
	reply = Label.new()
	reply.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	reply.mouse_filter = Control.MOUSE_FILTER_IGNORE
	reply.add_theme_color_override("font_color", UITheme.INK)
	reply_panel.add_child(reply)

	thought_layer = Control.new()
	thought_layer.set_anchors_preset(Control.PRESET_FULL_RECT)
	thought_layer.mouse_filter = Control.MOUSE_FILTER_IGNORE
	root.add_child(thought_layer)
	root.move_child(thought_layer, 0)  # behind the speech box

	ledger = preload("res://scripts/trace_ui.gd").new()   # sandbox "trace": why it played that
	root.add_child(ledger)

	# bottom bar: chat box on the left, buttons on the right, one row so they line up
	var bar := HBoxContainer.new()
	bar.set_anchors_preset(Control.PRESET_BOTTOM_WIDE)
	bar.offset_left = 6
	bar.offset_right = -6
	bar.offset_top = -18
	bar.offset_bottom = -4
	bar.add_theme_constant_override("separation", 3)
	root.add_child(bar)

	# one hint line for whatever the player should do next (board, map, choices); scenes call hint()
	hint_panel = PanelContainer.new()
	hint_panel.set_anchors_preset(Control.PRESET_CENTER_BOTTOM)
	hint_panel.grow_horizontal = Control.GROW_DIRECTION_BOTH
	hint_panel.offset_top = -90
	hint_panel.offset_bottom = -76
	hint_panel.add_theme_stylebox_override("panel", UITheme.strip(0.6))
	hint_panel.mouse_filter = Control.MOUSE_FILTER_IGNORE
	hint_panel.visible = false
	root.add_child(hint_panel)
	hint_label = Label.new()
	hint_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	hint_label.add_theme_color_override("font_color", UITheme.DIM)
	hint_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	hint_panel.add_child(hint_label)

	status = Label.new()
	status.set_anchors_preset(Control.PRESET_BOTTOM_WIDE)
	status.offset_left = 6
	status.offset_top = -30
	status.offset_bottom = -19
	status.add_theme_color_override("font_color", UITheme.BRASS_LIT)
	status.mouse_filter = Control.MOUSE_FILTER_IGNORE
	root.add_child(status)

	input = LineEdit.new()
	input.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	input.placeholder_text = "Speak to the Dealer..."
	input.text_submitted.connect(_on_submit)
	bar.add_child(input)
	head_button = Button.new()
	head_button.text = "Open head"
	head_button.focus_mode = Control.FOCUS_NONE
	head_button.pressed.connect(func(): head_pressed.emit())
	bar.add_child(head_button)
	# Thoughts, Why? and Debug are research controls; they stay off the player's bar unless a sandbox switch is on
	# or the Debug menu was asked for (F3 also opens it).
	thoughts_button = Button.new()
	thoughts_button.text = "Thoughts"
	thoughts_button.visible = Sandbox.any_enabled() or open_debug
	thoughts_button.toggle_mode = true
	thoughts_button.focus_mode = Control.FOCUS_NONE
	thoughts_button.toggled.connect(_toggle_thoughts)
	bar.add_child(thoughts_button)
	why_button = Button.new()
	why_button.text = "Why?"
	why_button.tooltip_text = "Why it played that: the Dealer's ledger for its last move"
	why_button.toggle_mode = true
	why_button.focus_mode = Control.FOCUS_NONE
	why_button.toggled.connect(_toggle_why)
	why_button.visible = Sandbox.enabled("trace")
	Sandbox.toggled.connect(func(id, on):
		if id == "trace":
			why_button.visible = on
			if not on:
				why_button.button_pressed = false)
	bar.add_child(why_button)
	var dbg := Button.new()
	dbg.text = "Debug"
	dbg.focus_mode = Control.FOCUS_NONE
	dbg.pressed.connect(_toggle_debug)
	dbg.visible = Sandbox.any_enabled() or open_debug
	bar.add_child(dbg)
	debug_button = dbg
	Sandbox.toggled.connect(func(_id, _on):
		var show: bool = Sandbox.any_enabled() or debug.visible
		thoughts_button.visible = show
		debug_button.visible = show)
	var settings := Button.new()
	settings.text = "Settings"
	settings.tooltip_text = "Settings (Esc)"
	settings.focus_mode = Control.FOCUS_NONE
	settings.pressed.connect(Settings.toggle)
	bar.add_child(settings)

	debug = PanelContainer.new()
	debug.set_anchors_preset(Control.PRESET_TOP_RIGHT)   # top-right column, above the bottom bar
	debug.offset_left = -190
	debug.offset_right = -4
	debug.offset_top = 4
	debug.offset_bottom = 214   # scrolls: the wires plus the sandbox list are taller than this
	debug.visible = false
	debug.theme = UITheme.walnut(8)
	debug.add_theme_stylebox_override("panel", UITheme.walnut_panel(0.94, 4))
	var scroll := ScrollContainer.new()
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	debug.add_child(scroll)
	debug_list = VBoxContainer.new()
	debug_list.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.add_child(debug_list)
	root.add_child(debug)

	_req(HTTPClient.METHOD_GET, "/state", null, _on_state)


## What the player should do next, one line above the chat bar. Empty clears it.
func hint(text: String, above_hand := false) -> void:
	hint_label.text = text
	hint_panel.visible = text != ""
	# during a hand the strip sits above the fanned cards; elsewhere just over the chat bar
	hint_panel.offset_top = -90 if above_hand else -46
	hint_panel.offset_bottom = -76 if above_hand else -32


func _process(delta: float) -> void:
	if reply_panel.visible and reply.visible_characters < reply.text.length():
		shown += delta * Settings.text_speed   # chars per second, set in the settings menu
		reply.visible_characters = int(shown)
	if thoughts_button.button_pressed and not thought_words.is_empty():
		thought_t -= delta
		if thought_t <= 0.0:
			thought_t = THOUGHT_EVERY
			_rise(thought_words[thought_i % thought_words.size()])
			thought_i += 1


func _unhandled_key_input(event: InputEvent) -> void:
	if event is InputEventKey and event.pressed and not event.echo and event.keycode == KEY_F3:
		_toggle_debug()
		debug_button.visible = true
		thoughts_button.visible = true


func _toggle_debug() -> void:
	debug.visible = not debug.visible
	if debug.visible:
		_req(HTTPClient.METHOD_GET, "/debug/state", null, _build_debug)


# ---------- reading its thoughts ----------
func _toggle_thoughts(on: bool) -> void:
	if on:
		_fetch_thoughts()
	else:
		for c in thought_layer.get_children():
			c.queue_free()


func _fetch_thoughts() -> void:
	if not thoughts_button.button_pressed:
		return
	_req(HTTPClient.METHOD_GET, "/thoughts", null, func(d):
		# interleave depths so each pass shows a little of every layer; wire words come first and twice
		var rows := []
		for w in d.get("wires", []):
			rows.append(w["up"].map(func(x): return [x, WIRE_COLORS.get(w["id"], Color.WHITE)]))
		for l in d.get("layers", []):
			rows.append(l["words"].map(func(x): return [x, THOUGHT_COLORS.get(l["label"], Color.WHITE)]))
		thought_words = []
		var n: int = rows.reduce(func(a, r): return max(a, r.size()), 0)
		for i in n:
			for r in rows:
				if i < r.size():
					thought_words.append(r[i])
		thought_i = 0
		thought_t = 0.0)


## One word drifting up off the Dealer's head and fading.
func _rise(item: Array) -> void:
	var l := Label.new()
	l.text = item[0]
	l.mouse_filter = Control.MOUSE_FILTER_IGNORE
	l.add_theme_color_override("font_color", item[1])
	l.add_theme_color_override("font_outline_color", Color(0.03, 0.02, 0.01))
	l.add_theme_constant_override("outline_size", 3)
	# the head can sit above the frame at the table view; keep the source on screen, under the speech box
	var at: Vector2 = head_screen.call()
	var vp := ui_size(get_viewport())
	at = Vector2(clampf(at.x, vp.x * 0.19, vp.x * 0.81), clampf(at.y, vp.y * 0.53, vp.y * 0.72))
	var side := 1.0 if thought_i % 2 else -1.0  # alternate sides so neighbours don't overlap
	l.position = at + Vector2(side * randf_range(10, 44) - l.text.length() * 2.0, randf_range(-4, 4))
	l.modulate.a = 0.0
	thought_layer.add_child(l)
	var tw := l.create_tween()
	tw.tween_property(l, "modulate:a", 0.85, 0.5)
	tw.parallel().tween_property(l, "position:y", l.position.y - 46, 3.2).set_trans(Tween.TRANS_SINE)
	tw.parallel().tween_property(l, "position:x", l.position.x + randf_range(-8, 8), 3.2)
	tw.tween_property(l, "modulate:a", 0.0, 0.8).set_delay(1.6)
	tw.finished.connect(l.queue_free)


func set_head_open(open: bool) -> void:
	head_button.text = "Close head" if open else "Open head"


# ---------- why it played that ----------
func _toggle_why(on: bool) -> void:
	if on:
		_fetch_trace()
	else:
		ledger.close()


## The trace takes a few seconds on the real brain; the ledger says so while it waits.
func _fetch_trace() -> void:
	if not why_button.button_pressed or not Sandbox.enabled("trace"):
		return
	ledger.show_note("The Dealer inks its ledger... tick... tick...")
	_req(HTTPClient.METHOD_GET, "/trace", null, func(d):
		if why_button.button_pressed:
			ledger.show_trace(d), func():
		ledger.show_note("The ledger is blank: the brain server is not running."))


# ---------- actions ----------
func say(text: String) -> void:
	if busy or text.strip_edges() == "":
		return
	busy = true
	status.text = "tick... tick... tick..."
	Sfx.thinking(true)
	var asked := Time.get_ticks_msec()
	_req(HTTPClient.METHOD_POST, "/say", {"text": text}, func(d):
		spoke.emit(text, d["reply"], Time.get_ticks_msec() - asked)
		busy = false
		Sfx.thinking(false)
		status.text = ""
		_show(d["reply"])
		_fetch_thoughts())


## Ask the Dealer's brain for a move. body is the /move request (dealer_ai.gd ask()). cb gets {choice: option index or
## -1, say: line about that move, attempts}; a dead server passes.
func move(body: Dictionary, cb: Callable) -> void:
	status.text = "the Dealer considers... tick... tick..."
	Sfx.thinking(true)
	_req(HTTPClient.METHOD_POST, "/move", body, func(d):
		status.text = ""
		Sfx.thinking(false)
		_show(d["say"])
		_fetch_thoughts()
		_fetch_trace()
		cb.call(d), func(): cb.call({"choice": -1, "say": ""}))


func cut(id: String) -> void:
	_req(HTTPClient.METHOD_POST, "/cut", {"id": id}, _on_state)


func _on_submit(text: String) -> void:
	input.text = ""
	say(text)


func _show(text: String) -> void:
	reply.text = text
	reply_panel.visible = true
	reply.visible_characters = 0
	shown = 0.0


func _on_state(d) -> void:
	wires = d["wires"]
	state_changed.emit(d["wires"])
	if debug.visible:
		_req(HTTPClient.METHOD_GET, "/debug/state", null, _build_debug)


# ---------- debug menu ----------
func _build_debug(d) -> void:
	for c in debug_list.get_children():
		c.queue_free()
	var title := Label.new()
	title.text = "DEBUG"
	debug_list.add_child(title)
	for w in d["wires"]:
		var row := HBoxContainer.new()
		var l := Label.new()
		l.text = "%s: %s x%.2f %s" % [w["id"], w["name"], w["strength"], "CUT" if w["cut"] else "intact"]
		row.add_child(l)
		var b := Button.new()
		b.text = "restore"
		b.disabled = not w["cut"]
		var id: String = w["id"]
		b.pressed.connect(func(): _req(HTTPClient.METHOD_POST, "/debug/restore", {"id": id}, _on_state))
		row.add_child(b)
		debug_list.add_child(row)
	var all := Button.new()
	all.text = "restore all wires"
	all.pressed.connect(func(): _req(HTTPClient.METHOD_POST, "/debug/restore", {"id": "all"}, _on_state))
	debug_list.add_child(all)
	var forget := Button.new()
	forget.text = "forget conversation"
	forget.pressed.connect(func(): _req(HTTPClient.METHOD_POST, "/debug/forget", {}, _on_state))
	debug_list.add_child(forget)
	_build_sandbox()
	if _scroll_end:
		await get_tree().process_frame
		var sc: ScrollContainer = debug_list.get_parent()
		sc.scroll_vertical = int(sc.get_v_scroll_bar().max_value)


## Sandbox mode switches (scripts/sandbox.gd, data/sandbox.json): experimental brain features kept out of the main
## game. Unbuilt ones show greyed out with "(soon)".
func _build_sandbox() -> void:
	var head := Label.new()
	head.text = "SANDBOX MODE"
	debug_list.add_child(head)
	for feat in Sandbox.features:
		var c := CheckButton.new()
		var built: bool = feat.get("built", false)
		c.text = feat["name"] + ("" if built else " (soon)")
		c.tooltip_text = "%s\n%s" % [feat["about"], feat["source"]]
		c.disabled = not built
		c.button_pressed = Sandbox.enabled(feat["id"])
		c.focus_mode = Control.FOCUS_NONE
		var id: String = feat["id"]
		c.toggled.connect(func(v): Sandbox.set_enabled(id, v))
		debug_list.add_child(c)


# ---------- http ----------
func _req(method: int, path: String, body, cb: Callable, on_fail := Callable()) -> void:
	var h := HTTPRequest.new()
	h.timeout = 180
	add_child(h)
	h.request_completed.connect(func(result, code, _headers, data):
		h.queue_free()
		var d = JSON.parse_string(data.get_string_from_utf8()) if code == 200 else null
		if result != HTTPRequest.RESULT_SUCCESS or not d is Dictionary:
			busy = false
			Sfx.thinking(false)
			status.text = "The dealer is silent. (brain server not running: brain/server.py)"
			if on_fail.is_valid():
				on_fail.call()
			return
		cb.call(d))
	var hdr := PackedStringArray(["Content-Type: application/json"])
	h.request(url + path, hdr, method, "" if body == null else JSON.stringify(body))
