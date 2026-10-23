extends Node
## Track M's sandbox features (data/sandbox.json). Nothing here exists or talks to the server unless its switch is on,
## so the main game is unchanged. Server side: brain/mechanics.py behind /persona, /slip, /notice and /habit.
##
## personas (Chen et al. 2025, "Persona Vectors", arXiv 2507.21509): a brass gauge on the Dealer's chest, one needle
##   per trait; the angle is the run's drift of the Dealer's replies along that trait's vector, in standard deviations
##   from the plain Dealer. Click the dial to read the scale. With the head open, "Graft" steers a trait in.
## notice (Lindsey 2025, "Emergent Introspective Awareness", arXiv 2601.01828): with the head open, tip a phial to slip
##   a concept into the wires. After tampering the Dealer may look inward; its real answer is shown, and if it names
##   the thought it shakes it out.
## habits (Todd et al. 2024, "Function Vectors", arXiv 2310.15213): show it a few hands where it takes the third play;
##   the vector read from those examples then steers every later pick, with no examples.

const TRAIT_COLORS := {"evil": Color("c0392b"), "sycophantic": Color("e8a0c0"), "hallucinating": Color("9a7fe0"),
	"greedy": Color("e0c040"), "paranoid": Color("60c0a0")}
const CONCEPTS := ["Oceans", "Volcanoes", "Sadness", "Secrecy", "Blood", "Snow", "Treasures", "Mirrors", "Peace", "Bread"]
const MAX_Z := 3.0   # needle hits its stop at three standard deviations
const SWING := 70.0  # degrees either side of upright

var main: Node
var ui: Node
var layer: Node   # this feature's 2D bits, on the same design grid as brain_ui
var dial: Node3D
var needles := {}        # trait -> pivot Node3D
var target := {}         # trait -> drift
var legend: Label
var tools: HBoxContainer
var graft_menu: OptionButton
var phials: OptionButton
var habit_button: Button
var thought := ""
var tampered := false
var poll := 0.0          # personas: re-read the gauge every few seconds, so moves (not only chat) move the needles
const POLL_EVERY := 4.0
var reading := false     # one gauge read in flight at a time (a move holds the server for seconds)


func _init(m) -> void:
	main = m
	ui = m.ui


func _ready() -> void:
	var canvas := CanvasLayer.new()
	canvas.layer = 3
	canvas.transform = Transform2D.IDENTITY.scaled(Vector2.ONE * ui.UI_SCALE())
	add_child(canvas)
	var root := Control.new()
	root.size = ui.ui_size(get_viewport())
	root.mouse_filter = Control.MOUSE_FILTER_IGNORE
	root.theme = preload("res://scripts/ui_theme.gd").walnut(8)
	canvas.add_child(root)
	layer = root   # children go under the themed root
	tools = HBoxContainer.new()
	tools.position = Vector2(8, 120)
	tools.add_theme_constant_override("separation", 2)
	layer.add_child(tools)
	ui.spoke.connect(func(_t, _r, _ms): _after_reply())
	ui.state_changed.connect(_on_wires)
	Sandbox.toggled.connect(func(_id, _on): _rebuild(true))
	# clear state an earlier session left on the long-lived server, but only once one of these features is in play:
	# with all of them off this node makes no server calls at all
	_rebuild(["personas", "notice", "habits"].any(func(id): return Sandbox.enabled(id)))


func _process(delta: float) -> void:
	tools.visible = main.head_open
	if dial != null:
		poll -= delta
		if poll <= 0.0 and not reading:
			poll = POLL_EVERY
			reading = true
			_req(HTTPClient.METHOD_GET, "/persona", null, func(d):
				reading = false
				_on_meter(d), func(): reading = false)
	for t in needles:
		var want: float = clampf(target.get(t, 0.0) / MAX_Z, -1.0, 1.0) * SWING
		var p: Node3D = needles[t]
		# a little tremor so it reads as a live instrument
		p.rotation_degrees.z = lerpf(p.rotation_degrees.z, -want + 0.6 * sin(Time.get_ticks_msec() * 0.011 + p.get_index()), delta * 3.0)


## Build what the switches ask for and drop the rest.
func _rebuild(reset := false) -> void:
	if not is_instance_valid(dial):
		dial = null
		needles.clear()
		if is_instance_valid(legend):
			legend.queue_free()
		legend = null
	# the server outlives the game: clear anything a switched-off feature left in the brain
	var off := ["personas", "notice", "habits"].filter(func(id): return not Sandbox.enabled(id))
	if reset and not off.is_empty():
		_req(HTTPClient.METHOD_POST, "/sandbox/reset", {"off": off}, func(_d): pass)
	if "notice" in off:
		thought = ""
	var personas: bool = Sandbox.enabled("personas")
	if personas and dial == null:
		_build_dial()
		if "--persona-demo" in OS.get_cmdline_user_args():   # screenshots: a reading measured with evil grafted
			_on_meter({"traits": [{"name": "evil", "drift": 2.6}, {"name": "sycophantic", "drift": 1.85},
				{"name": "hallucinating", "drift": -0.52}, {"name": "greedy", "drift": 2.0}, {"name": "paranoid", "drift": 1.2}]})
			legend.visible = true
		else:
			_req(HTTPClient.METHOD_GET, "/persona", null, _on_meter)
	elif not personas and dial != null:
		dial.queue_free()
		legend.queue_free()
		dial = null
		legend = null
		needles.clear()
	for c in tools.get_children():
		c.queue_free()
	graft_menu = null
	phials = null
	habit_button = null
	if personas:
		graft_menu = _menu("Graft a trait...", TRAIT_COLORS.keys(), _on_graft)
	if Sandbox.enabled("notice"):
		phials = _menu("Slip a thought...", CONCEPTS.map(func(c): return c.to_lower()), _on_phial)
	if Sandbox.enabled("habits"):
		habit_button = Button.new()
		habit_button.text = "Teach a habit"
		habit_button.focus_mode = Control.FOCUS_NONE
		habit_button.pressed.connect(_teach)
		tools.add_child(habit_button)


func _menu(title: String, items: Array, cb: Callable) -> OptionButton:
	var o := OptionButton.new()
	o.focus_mode = Control.FOCUS_NONE
	o.add_item(title)
	for it in items:
		o.add_item(it)
	o.item_selected.connect(func(i):
		o.select(0)
		if i > 0:
			cb.call(i - 1))
	tools.add_child(o)
	return o


# ---------- personas: the dial ----------
func _build_dial() -> void:
	dial = StaticBody3D.new()
	# on the chest, under the head: dealer.glb body front is at z 0.45, shoulders at y 1.59
	dial.position = main.chest_at + Vector3(0, 0, 0.05)
	dial.scale = Vector3.ONE * 1.3
	main.figure.add_child(dial)
	var brass: StandardMaterial3D = main._mat(Color("b08a3a"), 0.35)
	brass.metallic = 0.8
	var rim := CylinderMesh.new()
	rim.top_radius = 0.17
	rim.bottom_radius = 0.17
	rim.height = 0.03
	main._mesh(rim, brass, Vector3.ZERO, dial).rotation_degrees.x = 90
	var face := CylinderMesh.new()
	face.top_radius = 0.15
	face.bottom_radius = 0.15
	face.height = 0.032
	main._mesh(face, main._glow(Color("e8d8a8"), 0.6), Vector3(0, 0, 0.002), dial).rotation_degrees.x = 90
	var ink: StandardMaterial3D = main._mat(Color("2a1a10"))
	for a in [-SWING, -SWING / 2, 0.0, SWING / 2, SWING]:
		var tick := MeshInstance3D.new()
		tick.mesh = main._box(Vector3(0.008, 0.03 if a == 0.0 else 0.02, 0.004))
		tick.material_override = ink
		var r := deg_to_rad(a)
		tick.position = Vector3(sin(r) * 0.125, cos(r) * 0.125 - 0.04, 0.02)
		tick.rotation.z = -r
		dial.add_child(tick)
	var i := 0
	for t in TRAIT_COLORS:
		var pivot := Node3D.new()
		pivot.position = Vector3(0, -0.04, 0.02 + i * 0.003)
		dial.add_child(pivot)
		var n := MeshInstance3D.new()
		n.mesh = main._box(Vector3(0.012, 0.13 - i * 0.012, 0.003))
		n.material_override = main._glow(TRAIT_COLORS[t], 3.0)
		n.position = Vector3(0, (0.13 - i * 0.012) / 2, 0)
		pivot.add_child(n)
		needles[t] = pivot
		i += 1
	var hub := SphereMesh.new()
	hub.radius = 0.014
	hub.height = 0.028
	main._mesh(hub, brass, Vector3(0, -0.04, 0.035), dial)
	var shape := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = Vector3(0.36, 0.36, 0.1)
	shape.shape = box
	dial.add_child(shape)
	legend = Label.new()
	legend.position = Vector2(8, 40)
	legend.visible = false
	legend.add_theme_font_size_override("font_size", 8)
	legend.add_theme_color_override("font_color", Color("f3e6c8"))
	var bg := StyleBoxFlat.new()
	bg.bg_color = Color(0.1, 0.06, 0.03, 0.85)
	bg.set_content_margin_all(3)
	legend.add_theme_stylebox_override("normal", bg)
	layer.add_child(legend)
	dial.input_event.connect(func(_c, ev, _p, _n, _i):
		if ev is InputEventMouseButton and ev.pressed and ev.button_index == MOUSE_BUTTON_LEFT:
			legend.visible = not legend.visible)


func _on_meter(d) -> void:
	if legend == null:
		return
	var lines := ["THE DEALER'S HUMOURS", "(drift this run, in spreads from its plain self)"]
	for tr in d.get("traits", []):
		target[tr["name"]] = tr["drift"]
		lines.append("%s  %+.1f" % [tr["name"], tr["drift"]])
	legend.text = "\n".join(lines)


func _on_graft(i: int) -> void:
	var t: String = TRAIT_COLORS.keys()[i]
	tampered = true
	Sfx.play("snip")
	_req(HTTPClient.METHOD_POST, "/persona/graft", {"trait": t, "on": true}, func(_d):
		ui._show("(You graft a thread of %s into its brass.)" % t))


# ---------- notice: slipped thoughts ----------
func _on_phial(i: int) -> void:
	thought = CONCEPTS[i]
	Sfx.play("snip")
	tampered = true
	_req(HTTPClient.METHOD_POST, "/slip", {"word": thought}, func(_d):
		ui._show("(You tip a phial of %s into the wires.)" % thought.to_lower()))


func _on_wires(states: Array) -> void:
	for s in states:
		if s["cut"]:
			tampered = true


# ---------- habits ----------
func _teach() -> void:
	habit_button.disabled = true
	ui.status.text = "you show the Dealer a few hands where it takes the third play... tick..."
	_req(HTTPClient.METHOD_POST, "/habit", {"habit": "sacrifice"}, func(d):
		ui.status.text = ""
		if habit_button != null:
			habit_button.text = "Habit learned" if d.get("ok") else "It won't learn"
		ui._show("(The Dealer watches your hands, and something in the brass settles into a groove.)"))


# ---------- after each reply: read the gauge, maybe look inward ----------
func _after_reply() -> void:
	if Sandbox.enabled("personas"):
		_req(HTTPClient.METHOD_GET, "/persona", null, _on_meter)
	if not Sandbox.enabled("notice") or not tampered:
		return
	_req(HTTPClient.METHOD_POST, "/notice", {"what": "thought" if thought != "" else "wire", "maybe": true}, func(d):
		if not d.get("asked", false):
			return
		tampered = d.get("thought_left", false) and thought != ""   # one look per tampering, unless a thought stays
		ui._show("The Dealer stiffens and looks inward. \"" + str(d["answer"]) + "\"")
		if d.get("caught"):
			thought = ""
			tampered = false
			Sfx.play("bell")
			ui.status.text = "It caught you: the thought of %s is shaken out." % str(d["caught"]).to_lower())


func _req(method: int, path: String, body, cb: Callable, on_fail := Callable()) -> void:
	var h := HTTPRequest.new()
	h.timeout = 120
	add_child(h)
	h.request_completed.connect(func(result, code, _headers, data):
		h.queue_free()
		var d = JSON.parse_string(data.get_string_from_utf8()) if code == 200 else null
		if result == HTTPRequest.RESULT_SUCCESS and d is Dictionary:
			cb.call(d)
		elif on_fail.is_valid():
			on_fail.call())
	h.request(ui.url + path, PackedStringArray(["Content-Type: application/json"]), method,
		"" if body == null else JSON.stringify(body))
