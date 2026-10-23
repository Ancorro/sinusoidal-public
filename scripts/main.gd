extends Node3D
## Builds a forest clearing, a ground card board and the creature that arrives for each night.
## Run with `-- --shot=path.png` to save one frame and quit.

# Dark colours snap to these. Deep shadows go a cold green-black (the forest's tint); browns hold the lamp-lit middle.
const PALETTE := [
	Color("060a09"), Color("0c1614"), Color("15211d"), Color("22302a"),
	Color("2a1c13"), Color("432c1b"), Color("62412a"), Color("4a2620"),
]
const LANES := [-0.9, -0.3, 0.3, 0.9]
const FOE_ROW := -0.8
const OWN_ROW := 0.05

const FIGURE_Y := 0.0
const FIGURE_Z := -2.5   # close enough to read its face; the counter on its chest must be legible
const FIGURE_SCALE := 0.58  # multiplied by the creature's scale in data/creatures.json
const HEAD_AT := Vector3(0, 1.95, 0.21)  # centre of dealer.glb's head; the head turns about it
const WIRE_COLORS := {"red": Color("d0392b"), "blue": Color("3a6fd8"), "yellow": Color("e8c040"), "green": Color("3fae4f")}

var lamp_pivot: Node3D
var candle_lights: Array[OmniLight3D] = []
var candle_flames: Array[MeshInstance3D] = []   # the run's lives (scripts/run_table.gd puts them out)
var figure: Node3D
var cam: Camera3D
var cam_home: Transform3D
var look_home: Transform3D
var lid_pivot: Node3D
var brain_at: Vector3  # floor of the skull well (dealer.glb's Brain marker), in head_body space
var head_body: StaticBody3D
var head_open := false
var wires := {}
var ui: CanvasLayer
var fx: Node   # animation and feel (scripts/fx.gd)
var game
var cards_root: Node3D
var bell: StaticBody3D
var scale_beam: Node3D
var scale_label: Label3D
var selected := -1
var dealer_thinking := false
var t := 0.0
var shot_path := ""
var shot_at := 90
var demo_board := false   # --demo-board: start with sigil creatures on the table (for screenshots)
var frames := 0
var run_log   # scripts/run_log.gd: this game's log under user://runs
var logged_end := false
var board_locked := false   # set by the run map while the board is not in play
var hearth_view: Node
var forest: Node3D
var creature_id := "dealer"
var creature_home := Vector3.ZERO
var creature_arriving := false
var arrival_tween: Tween
var chest_at := Vector3.ZERO
var brain_module: Node3D
var look_yaw := 0.0
var look_pitch := 0.0
var preview_clearing := ""
var preview_creature := ""
var creature_data: Dictionary = JSON.parse_string(FileAccess.get_file_as_string("res://data/creatures.json"))["creatures"]


func _ready() -> void:
	var start_open := false
	var say := ""
	var cut_ids: Array[String] = []
	var show_thoughts := false
	var show_why := false
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--shot="):
			shot_path = a.substr(7)
		elif a.begins_with("--shot-at="):
			shot_at = int(a.substr(10))
		elif a == "--open":
			start_open = true
		elif a.begins_with("--say="):
			say = a.substr(6)
		elif a.begins_with("--cut="):
			cut_ids.append(a.substr(6))
		elif a == "--demo-board":
			demo_board = true
		elif a == "--thoughts":
			show_thoughts = true
		elif a == "--why":
			show_why = true
		elif a.begins_with("--clearing="):
			preview_clearing = a.substr(11)
		elif a.begins_with("--creature="):
			preview_creature = a.substr(11)
	if creature_data.has(preview_creature):
		creature_id = preview_creature
	get_viewport().physics_object_picking = true
	ui = preload("res://scripts/brain_ui.gd").new()
	add_child(ui)
	ui.state_changed.connect(_on_brain_state)
	ui.head_pressed.connect(toggle_head)
	ui.spoke.connect(func(text, reply, ms): run_log.say(text, reply, ms))
	fx = preload("res://scripts/fx.gd").new(self)
	add_child(fx)
	_camera()
	forest = preload("res://scripts/forest.gd").new(self)
	add_child(forest)
	if preview_clearing != "":
		forest.set_clearing(preview_clearing, 7)
	_candles()
	_figure()
	_board()
	_post()
	ui.head_screen = func() -> Vector2:   # in the UI's design grid
		return cam.unproject_position(head_body.global_position + Vector3(0, 0.3, 0)) / ui.UI_SCALE()
	add_child(preload("res://scripts/run_table.gd").new())
	add_child(preload("res://scripts/persona_meter.gd").new(self))   # track M: persona gauge, slipped thoughts, habit
	for id in cut_ids:
		ui.cut(id)
	if start_open:
		toggle_head()
	if show_thoughts:
		ui.thoughts_button.button_pressed = true
	if show_why:
		ui.why_button.button_pressed = true
	if say != "":
		ui.say(say)


## Break the game <-> log <-> lambda reference loops so Godot can free them at exit (else it reports leaks).
func _exit_tree() -> void:
	if run_log != null:
		run_log.close()
	if game != null:
		for sig in ["changed", "log_line", "event"]:
			for c in game.get_signal_connection_list(sig):
				game.disconnect(sig, c["callable"])
	for c in ui.spoke.get_connections():
		ui.spoke.disconnect(c["callable"])
	run_log = null
	game = null


func _input(event: InputEvent) -> void:
	if event is InputEventMouseButton and event.pressed and event.button_index == MOUSE_BUTTON_RIGHT and head_open:
		toggle_head()
	elif event is InputEventMouseMotion and event.button_mask & MOUSE_BUTTON_MASK_RIGHT and not head_open:
		look_yaw = clampf(look_yaw - event.relative.x * 0.15, -160, 160)
		look_pitch = clampf(look_pitch - event.relative.y * 0.12, -20, 35)
		_look()
	elif event is InputEventKey and event.pressed and event.keycode == KEY_SPACE and not ui.input.has_focus():
		look_yaw = 0
		look_pitch = 0
		_look()


func _look() -> void:
	cam.transform = look_home
	cam.rotate_y(deg_to_rad(look_yaw))
	cam.rotate_object_local(Vector3.RIGHT, deg_to_rad(look_pitch))


func _process(delta: float) -> void:
	t += delta
	for i in candle_lights.size():
		candle_lights[i].light_energy = 0.23 + 0.035 * sin(t * 13.0 + i * 2.1) + 0.02 * sin(t * 31.0 + i)
	# idle: a slow breathing bob and an unhurried look around
	figure.position.y = FIGURE_Y + (absf(sin(t * 9)) * 0.04 if creature_arriving else 0.012 * sin(t * 0.8))
	head_body.rotation.y = 0.12 * sin(t * 0.37) + 0.05 * sin(t * 0.91)
	head_body.rotation.z = 0.04 * sin(t * 0.53)
	frames += 1
	if shot_path != "" and frames == shot_at:
		DirAccess.make_dir_recursive_absolute(shot_path.get_base_dir())
		get_viewport().get_texture().get_image().save_png(shot_path)
		Sfx.quit()


# ---------- helpers ----------
func _mat(col: Color, rough := 0.9) -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.albedo_color = col
	m.roughness = rough
	m.texture_filter = BaseMaterial3D.TEXTURE_FILTER_NEAREST
	return m


func _glow(col: Color, energy := 3.0) -> StandardMaterial3D:
	var m := _mat(col)
	m.emission_enabled = true
	m.emission = col
	m.emission_energy_multiplier = energy
	return m


func _mesh(mesh: Mesh, mat: Material, pos: Vector3, parent: Node = self) -> MeshInstance3D:
	var mi := MeshInstance3D.new()
	mi.mesh = mesh
	mi.material_override = mat
	mi.position = pos
	parent.add_child(mi)
	return mi


## A prop model from art/models/props (Hunyuan3D-2 + art/scripts/blender_prop.py; origin at the base centre).
func _prop(name: String, pos: Vector3, yaw := 0.0, size := 1.0, parent: Node = self) -> Node3D:
	var n: Node3D = load("res://art/models/props/%s.glb" % name).instantiate()
	n.position = pos
	n.rotation_degrees.y = yaw
	n.scale = Vector3.ONE * size
	parent.add_child(n)
	return n


func _box(size: Vector3) -> BoxMesh:
	var b := BoxMesh.new()
	b.size = size
	return b


# ---------- scene ----------
func _environment() -> void:
	var env := Environment.new()
	env.background_mode = Environment.BG_COLOR
	env.background_color = Color("040706")
	env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.ambient_light_color = Color("1c2a24")
	env.ambient_light_energy = 0.25
	env.glow_enabled = true
	env.glow_intensity = 0.6
	env.fog_enabled = true
	env.fog_light_color = Color("08100d")
	env.fog_density = 0.08
	var we := WorldEnvironment.new()
	we.environment = env
	add_child(we)


func _camera() -> void:
	cam = Camera3D.new()
	cam.fov = 62   # wider than before (52) so the board and Dealer have room; the hand moves closer to compensate
	add_child(cam)
	cam.look_at_from_position(Vector3(0, 1.95, 2.45), Vector3(0, 0.35, -0.7))
	cam_home = cam.transform
	look_home = cam_home
	# faint warm fill from the player's side so the hand still reads at night
	var fill := OmniLight3D.new()
	fill.position = Vector3(0.3, 1.3, 2.0)
	fill.light_color = Color("e0b890")
	fill.light_energy = 0.16
	fill.omni_range = 3.2
	add_child(fill)


## Old planks: dark seams between boards and a stretched grain, so the table reads as wood, not cloth.
func _table() -> void:
	var img := Image.create(64, 64, false, Image.FORMAT_RGB8)
	var grain := FastNoiseLite.new()
	grain.frequency = 0.08
	var rng := RandomNumberGenerator.new()
	rng.seed = 7
	var shade := []
	for b in 4:
		shade.append(rng.randf_range(0.8, 1.15))
	for y in 64:
		for x in 64:
			var b := x / 16   # four boards across the texture, running away from the player
			var g := grain.get_noise_2d(x * 4.0, y * 0.3) * 0.5 + 0.5
			var c: Color = Color("4a2e1a").lerp(Color("8a5a32"), g) * float(shade[b])
			if x % 16 < 2:
				c = Color("0e0805")   # seam
			elif (y + b * 23) % 64 == 0:
				c = Color("1a100a")   # board end
			img.set_pixel(x, y, c)
	var m := _mat(Color.WHITE, 0.8)
	m.albedo_texture = ImageTexture.create_from_image(img)
	m.uv1_scale = Vector3(3.5, 1.5, 1)   # boards about 0.3 wide on the 4.4-wide table
	_mesh(_box(Vector3(4.4, 0.12, 3.4)), m, Vector3(0, -0.06, -0.2))
	# a heavy dark rim along the player's edge
	_mesh(_box(Vector3(4.5, 0.18, 0.14)), _mat(Color("1e130b"), 0.7), Vector3(0, -0.07, 1.52))


func _lamp() -> void:
	lamp_pivot = Node3D.new()
	lamp_pivot.position = Vector3(0, 4.3, -0.3)
	add_child(lamp_pivot)
	var chain := CylinderMesh.new()
	chain.top_radius = 0.01
	chain.bottom_radius = 0.01
	chain.height = 1.4
	_mesh(chain, _mat(Color("2a2420")), Vector3(0, -0.7, 0), lamp_pivot)
	# the bulb is tucked up inside the shade so it never shows as a speck above the Dealer
	_prop("lamp", Vector3(0, -1.66, 0), 0.0, 1.1, lamp_pivot)
	var bulb := SphereMesh.new()
	bulb.radius = 0.07
	bulb.height = 0.14
	_mesh(bulb, _glow(Color("ffd9a0"), 6.0), Vector3(0, -1.5, 0), lamp_pivot)
	var spot := SpotLight3D.new()
	spot.position = Vector3(0, -2.2, 0)
	spot.rotation_degrees.x = -90
	spot.spot_angle = 40
	spot.spot_range = 5.5
	spot.spot_attenuation = 1.15   # falloff toward the cone edge: the board is lit, the clearing past it is not
	spot.light_energy = 4.0
	spot.light_color = Color("ffcf94")
	spot.shadow_enabled = true
	lamp_pivot.add_child(spot)


func _candles() -> void:
	var spots := [Vector3(-1.75, 0, 0.55), Vector3(-1.55, 0, 0.8), Vector3(-1.85, 0, 0.9)]
	for i in spots.size():
		var h: float = [0.38, 0.26, 0.31][i]
		var body := _prop("candle", spots[i], i * 70.0, h / 0.42)   # model is 0.42 tall; its wick top meets the flame
		body.scale *= Vector3(1.8, 1, 1.8)   # stout, so the lives read at a glance
		var flame := SphereMesh.new()
		flame.radius = 0.025
		flame.height = 0.09
		candle_flames.append(_mesh(flame, _glow(Color("ffb347"), 8.0), spots[i] + Vector3(0, h + 0.05, 0)))
		var light := OmniLight3D.new()
		light.position = spots[i] + Vector3(0, h + 0.08, 0)
		light.light_color = Color("ff9a3c")
		light.omni_range = 1.3
		add_child(light)
		candle_lights.append(light)


## Set dressing at the frame edges, Hunyuan3D-2 models (art/models/props): a brass armillary on the left, an hourglass
## and books with a candle stub on the right, bone dish by the scale, and wall shelves of workshop clutter behind the
## Dealer. Chains hang from the rafters; a faint cold back light rims everything so it parts from the dark.
func _props() -> void:
	var iron := _mat(Color("1a1d1a"), 0.5)
	iron.metallic = 0.6
	_prop("orrery", Vector3(-2.05, 0, -0.5), 30.0)
	_prop("hourglass", Vector3(1.95, 0, -0.35), 20.0)
	var books := _prop("books", Vector3(2.0, 0, 0.35), -25.0, 0.9)
	_prop("bones", Vector3(-1.6, 0, 0.2), 40.0, 1.0)
	for x in [-2.0, 2.0]:   # shelves on the back wall, either side of the Dealer
		_prop("shelf", Vector3(x, 0.55, -3.1), 0.0, 1.2)
	# a stub of candle on the books (set dressing, not one of the run's life candles)
	var top := 0.42 * 0.9
	_prop("candle", Vector3(2.0, top, 0.35), 0.0, 0.35)
	var flame := SphereMesh.new()
	flame.radius = 0.02
	flame.height = 0.07
	_mesh(flame, _glow(Color("ffb347"), 8.0), Vector3(2.0, top + 0.16, 0.35), books.get_parent())
	var glow := OmniLight3D.new()
	glow.position = Vector3(2.0, top + 0.26, 0.35)
	glow.light_color = Color("ff9a3c")
	glow.light_energy = 1.1
	glow.omni_range = 1.4
	add_child(glow)
	# a faint cold light from the trees behind rims the silhouettes so they part from the dark
	var back := OmniLight3D.new()
	back.position = Vector3(0, 2.2, -3.4)
	back.light_color = Color("5f8a7a")
	back.light_energy = 1.2
	back.omni_range = 5.0
	add_child(back)
	# chains hanging from the dark above, at both edges
	for x in [-1.75, 1.6]:
		var chain := CylinderMesh.new()
		chain.top_radius = 0.012
		chain.bottom_radius = 0.012
		chain.height = 2.2
		chain.radial_segments = 4
		_mesh(chain, iron, Vector3(x, 2.6, -1.1))
		var hook := TorusMesh.new()
		hook.inner_radius = 0.04
		hook.outer_radius = 0.06
		hook.rings = 8
		hook.ring_segments = 4
		_mesh(hook, iron, Vector3(x, 1.47, -1.1)).rotation_degrees.x = 90


## The walnut automaton (art/models/dealer/dealer.glb, from Hunyuan3D-2 + art/scripts/blender_dealer.py). Its skull
## lid hinges open on the head to show the wires; clicking the head opens it, clicking a wire cuts it.
## The model's Head and Lid are moved under a clickable body; the lid's origin is its hinge at the back of the cut.
func _figure() -> void:
	var config: Dictionary = creature_data[creature_id]
	figure = Node3D.new()
	creature_home = Vector3(0, FIGURE_Y, FIGURE_Z - float(config["back"]))
	figure.position = creature_home
	figure.scale = Vector3.ONE * FIGURE_SCALE * float(config["scale"])
	add_child(figure)
	var model: Node3D = load("res://art/models/creatures/%s.glb" % creature_id).instantiate()
	figure.add_child(model)
	_open_skull(model.get_node("Head"), model.get_node("Lid").global_position.y)
	_smooth_textures(model)
	chest_at = figure.to_local(model.get_node("Body/Chest").global_position)
	var brass := _mat(Color("b08a3a"), 0.35)
	brass.metallic = 0.8
	# Inscryption-style: the figure stays mostly in shadow. A dim warm rim from behind cuts its silhouette from the
	# dark, and a low glow from the candle side catches the jaw and shoulders; the eyes do the rest.
	var rim_light := OmniLight3D.new()
	rim_light.position = Vector3(-0.7, 2.6, -0.9)
	rim_light.light_color = Color("ff9a50")
	rim_light.light_energy = 0.12
	rim_light.omni_range = 1.6
	figure.add_child(rim_light)
	var under := OmniLight3D.new()
	under.position = Vector3(-0.9, 1.1, 0.9)
	under.light_color = Color("ff8a3c")
	under.light_energy = 0.0   # the campfire now catches the near side; a second warm fill flattened the figure
	under.omni_range = 1.8
	figure.add_child(under)
	# its carved hands rest on the far edge of the table, either side of the board
	# head: a clickable body holding the face, the eyes and the lid
	var head: Node3D = model.get_node("Head")
	head_body = StaticBody3D.new()
	head_body.position = figure.to_local(head.get_node("Brain").global_position)
	figure.add_child(head_body)
	head.reparent(head_body)
	var ring := TorusMesh.new()
	ring.inner_radius = 0.035
	ring.outer_radius = 0.05
	for n in ["EyeL", "EyeR"]:
		var at: Vector3 = head.get_node(n).global_position
		var rim := _mesh(ring, brass, Vector3.ZERO, head_body)
		rim.rotation_degrees.x = 90
		rim.global_position = at
		var eye := SphereMesh.new()
		eye.radius = 0.035
		eye.height = 0.05
		_mesh(eye, _glow(Color(config["eyes"]), 0.7), Vector3.ZERO, head_body).global_position = at
	# brain cavity: a well sunk into the skull under the lid; the wires lie across its floor
	brain_at = head_body.to_local(head.get_node("Brain").global_position)
	brain_module = Node3D.new()
	brain_module.position = brain_at + Vector3(0, 0.008, 0)
	brain_module.visible = head_open
	head_body.add_child(brain_module)
	var eye_span: float = head.get_node("EyeL").position.distance_to(head.get_node("EyeR").position)
	var wire_size := clampf(eye_span * 1.5, 0.26, 0.56)
	var circuit := _mat(Color("163e32"), 0.4)
	circuit.metallic = 0.45
	_mesh(_box(Vector3(0.45, 0.018, 0.44) * wire_size), circuit, Vector3.ZERO, brain_module)
	for i in 3:
		var chip := _mat(Color("172027"), 0.3)
		chip.metallic = 0.75
		_mesh(_box(Vector3(0.07, 0.035, 0.09) * wire_size), chip, Vector3((i - 1) * 0.11, 0.02, 0) * wire_size, brain_module)
		_mesh(_box(Vector3(0.012, 0.003, 0.36) * wire_size), brass, Vector3((i - 1) * 0.11, 0.012, 0) * wire_size, brain_module)
	var inner := OmniLight3D.new()
	inner.position = brain_at + Vector3(0, 0.25, 0.15)
	inner.light_color = Color("ffd29a")
	inner.light_energy = 0.06
	inner.omni_range = 0.4
	head_body.add_child(inner)
	var ids := WIRE_COLORS.keys()
	for i in ids.size():
		_wire(ids[i], brain_at + Vector3((-0.15 + i * 0.1) * wire_size, 0.03 * wire_size, 0))
		var cable: Node3D = wires[ids[i]]["halves"][0].get_parent()
		cable.scale = Vector3.ONE * wire_size
		cable.visible = head_open
	lid_pivot = Node3D.new()
	head_body.add_child(lid_pivot)
	var lid: Node3D = model.get_node("Lid")
	lid_pivot.global_transform = lid.global_transform
	lid.reparent(lid_pivot)
	var shape := CollisionShape3D.new()
	var sph := SphereShape3D.new()
	sph.radius = 0.38
	shape.shape = sph
	head_body.add_child(shape)
	head_body.input_event.connect(func(_c, ev, _p, _n, _i):
		if ev is InputEventMouseButton and ev.pressed and ev.button_index == MOUSE_BUTTON_LEFT and not head_open:
			toggle_head())


## The creature albedos are 256 px and export with nearest sampling, which reads as blocky pixels at 1440x810.
## Sample them smoothly instead (the pixel-look setting still pixelates the whole frame), matte and darkened.
func _smooth_textures(node: Node) -> void:
	if node is MeshInstance3D and node.mesh != null:
		for s in node.mesh.get_surface_count():
			var m = node.get_active_material(s)
			if m is BaseMaterial3D:
				m = m.duplicate()
				m.texture_filter = BaseMaterial3D.TEXTURE_FILTER_LINEAR_WITH_MIPMAPS_ANISOTROPIC
				# matte and a shade darker, so the creature sits back in the night rather than shining in the firelight
				m.roughness = maxf(m.roughness, 0.92)
				m.albedo_color = m.albedo_color * Color(0.62, 0.62, 0.62, 1.0)
				node.set_surface_override_material(s, m)
	for child in node.get_children():
		_smooth_textures(child)


## Older exported creatures retain a flat cap at the skull cut above their recessed floor. Remove only those
## coplanar triangles, keeping the inner walls and lower floor. The lid still closes over the opening.
func _open_skull(node: Node3D, cut_y: float) -> void:
	if node is MeshInstance3D:
		var fixed := ArrayMesh.new()
		for surface in node.mesh.get_surface_count():
			var arrays: Array = node.mesh.surface_get_arrays(surface)
			var vertices: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
			var indices: PackedInt32Array = arrays[Mesh.ARRAY_INDEX]
			if indices.is_empty():
				for i in vertices.size():
					indices.append(i)
			var kept := PackedInt32Array()
			for i in range(0, indices.size(), 3):
				var cap := true
				for j in 3:
					if absf((node.global_transform * vertices[indices[i + j]]).y - cut_y) > 0.0001:
						cap = false
				if not cap:
					kept.append_array(indices.slice(i, i + 3))
			if not kept.is_empty():
				arrays[Mesh.ARRAY_INDEX] = kept
				fixed.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
				fixed.surface_set_material(fixed.get_surface_count() - 1, node.mesh.surface_get_material(surface))
		node.mesh = fixed
	for child in node.get_children():
		if child is Node3D:
			_open_skull(child, cut_y)


func set_encounter(seed_value: int, boss := false) -> void:
	var clearings: Array = forest.data.keys()
	var clearing: String = preview_clearing if preview_clearing != "" else clearings[posmod(seed_value, clearings.size())]
	forest.set_clearing(clearing, seed_value)
	var creatures: Array = creature_data.keys()
	var id: String = preview_creature if preview_creature != "" else ("dealer" if boss else creatures[1 + posmod(seed_value, creatures.size() - 1)])
	set_creature(id, shot_path == "")


func set_creature(id: String, arrive := false) -> void:
	if not creature_data.has(id):
		return
	if arrival_tween != null:
		arrival_tween.kill()
	if head_open:
		head_open = false
		ui.set_head_open(false)
	cam.transform = cam_home
	look_home = cam_home
	look_yaw = 0
	look_pitch = 0
	figure.free()
	wires.clear()
	creature_id = id
	_figure()
	for state in ui.wires:
		_set_wire_cut(state["id"], state["cut"], false)
	# Reattach the optional persona gauge to the new creature's chest.
	for child in get_children():
		if child.get_script() == preload("res://scripts/persona_meter.gd"):
			child._rebuild(false)
	if hearth_view != null:
		hearth_view.attach()
	creature_arriving = arrive
	if arrive:
		figure.position.z -= 12
		arrival_tween = create_tween().set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_OUT)
		arrival_tween.tween_property(figure, "position:z", creature_home.z, 1.8)
		arrival_tween.tween_callback(func(): creature_arriving = false)


## One wire: a coloured cable arching across the cavity. Click it to cut (one way; restore only via the Debug menu).
func _wire(id: String, at: Vector3) -> void:
	var body := StaticBody3D.new()
	body.position = at
	head_body.add_child(body)
	var col: Color = WIRE_COLORS[id]
	var halves := []
	# two thick halves lying front-to-back across the cavity, meeting in the middle
	for side in [-1, 1]:
		var seg := CylinderMesh.new()
		seg.top_radius = 0.028
		seg.bottom_radius = 0.028
		seg.height = 0.24
		var m := _mesh(seg, _glow(col, 0.9), Vector3(0, 0, side * 0.12), body)
		m.rotation_degrees.x = 90
		halves.append(m)
	var shape := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = Vector3(0.09, 0.1, 0.5)
	shape.shape = box
	body.add_child(shape)
	body.input_event.connect(func(_c, ev, _p, _n, _i):
		if head_open and ev is InputEventMouseButton and ev.pressed and ev.button_index == MOUSE_BUTTON_LEFT \
				and not wires[id]["cut"]:
			ui.cut(id))
	wires[id] = {"halves": halves, "cut": false}


func _set_wire_cut(id: String, is_cut: bool, record := true) -> void:
	var w: Dictionary = wires.get(id, {})
	if w.is_empty() or w["cut"] == is_cut:
		return
	w["cut"] = is_cut
	if record:
		run_log.cut(id, is_cut)
	for i in 2:
		var seg: MeshInstance3D = w["halves"][i]
		var side := -1 if i == 0 else 1
		var tw := create_tween().set_parallel()
		# cut: the halves spring apart, their cut ends droop into the cavity, and the glow dies
		tw.tween_property(seg, "rotation_degrees:x", 90.0 + side * (40.0 if is_cut else 0.0), 0.25)
		tw.tween_property(seg, "position", Vector3(0, -0.05 if is_cut else 0.0, side * (0.16 if is_cut else 0.12)), 0.25)
		seg.material_override.emission_energy_multiplier = 0.0 if is_cut else 0.9
	if is_cut and head_open:
		Sfx.play("snip")
		fx.wire_cut(w["halves"][0].get_parent())


func _on_brain_state(states: Array) -> void:
	for s in states:
		_set_wire_cut(s["id"], s["cut"])


func toggle_head() -> Tween:
	if creature_arriving:
		return null
	head_open = not head_open
	brain_module.visible = head_open
	for wire in wires.values():
		wire["halves"][0].get_parent().visible = head_open
	ui.set_head_open(head_open)
	Sfx.play("lid_open" if head_open else "lid_close")
	var tw := create_tween().set_parallel().set_trans(Tween.TRANS_SINE)
	tw.tween_property(lid_pivot, "rotation_degrees:x", -140.0 if head_open else 0.0, 0.6)
	var target := look_home
	look_yaw = 0
	look_pitch = 0
	if head_open:
		var top := head_body.to_global(brain_at)
		var eye := top + Vector3(0, 0.8, 0.65) * figure.scale.x
		target = Transform3D().looking_at(top - eye, Vector3.UP)
		target.origin = eye
	tw.tween_property(cam, "transform", target, 0.6)
	return tw


## Static table furniture for the battle: lane slots (clickable to play the selected card), the bell, the scale.
func _board() -> void:
	game = preload("res://scripts/rules.gd").new_battle()
	fx.attach(game)
	game.log_line.connect(func(s): print(s))
	run_log = preload("res://scripts/run_log.gd").open("game")
	run_log.attach(game)
	game.changed.connect(func():
		if game.winner != "" and not logged_end:
			logged_end = true
			run_log.battle_end(game))
	if "hearth" in game:
		cards_root = Node3D.new()
		add_child(cards_root)
		# The run view shares this label with the lane board.
		scale_label = Label3D.new()
		add_child(scale_label)
		hearth_view = preload("res://scripts/hearth_board.gd").new(self)
		add_child(hearth_view)
		game.setup(7 if demo_board else 0)
		if demo_board:
			game.mana["player"] = 6
			game.max_mana["player"] = 6
			game.hand["player"] = ["Rat", "Ember", "Tortoise", "Ghoul", "Healing Tonic"]
			for entry in [["player", "Skeleton"], ["player", "Tortoise"], ["dealer", "Ghoul"], ["dealer", "Rat"]]:
				var m: Dictionary = game._summon(entry[0], entry[1])
				m["sleeping"] = false
			fx.redraw()
		run_log.battle_start(game, {"player_bot": "human", "brain": "server", "demo_board": demo_board})
		return
	var slot_mat := _mat(Color("1a120c"))
	for z in [FOE_ROW, OWN_ROW]:
		for lane in LANES.size():
			var slot := StaticBody3D.new()
			slot.position = Vector3(LANES[lane], 0.002, z)
			add_child(slot)
			_mesh(_box(Vector3(0.52, 0.004, 0.72)), slot_mat, Vector3.ZERO, slot)
			var col := CollisionShape3D.new()
			var box := BoxShape3D.new()
			box.size = Vector3(0.52, 0.02, 0.72)
			col.shape = box
			slot.add_child(col)
			if z == OWN_ROW:
				slot.input_event.connect(func(_c, ev, _p, _n, _i):
					if _clicked(ev):
						_on_lane(lane))
	# the bell: ring it to end your turn
	bell = StaticBody3D.new()
	bell.position = Vector3(1.55, 0, 0.55)
	add_child(bell)
	_prop("bell", Vector3.ZERO, -20.0, 1.0, bell)
	var bcol := CollisionShape3D.new()
	var bsh := SphereShape3D.new()
	bsh.radius = 0.16
	bcol.shape = bsh
	bell.add_child(bcol)
	bell.input_event.connect(func(_c, ev, _p, _n, _i):
		if _clicked(ev):
			_end_player_turn())
	# the scale: a beam on a post that tips toward whoever is winning
	var scale_light := OmniLight3D.new()
	scale_light.position = Vector3(-1.2, 0.9, 0.0)
	scale_light.light_color = Color("ffc070")
	scale_light.light_energy = 1.2
	scale_light.omni_range = 1.2
	add_child(scale_light)
	# the balance model, turned so its beam runs toward the Dealer; the whole balance rocks on its foot
	scale_beam = Node3D.new()
	scale_beam.position = Vector3(-1.45, 0.0, -0.35)
	add_child(scale_beam)
	_prop("scale", Vector3.ZERO, 90.0, 0.85, scale_beam)
	scale_label = Label3D.new()
	scale_label.font_size = 40
	scale_label.pixel_size = 0.004
	scale_label.modulate = Color("f3e6c8")
	scale_label.position = Vector3(-1.45, 0.8, -0.35)
	scale_label.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	add_child(scale_label)
	cards_root = Node3D.new()
	add_child(cards_root)
	game.setup(int(demo_board))
	run_log.battle_start(game, {"player_bot": "human", "brain": "server", "demo_board": demo_board})
	if demo_board:
		for p in [["player", 0, "Raven"], ["player", 2, "Tortoise"], ["dealer", 1, "Adder"], ["dealer", 3, "Hydra"]]:
			game.board[p[0]][p[1]] = game.creature(p[2])
		fx.redraw()


func _clicked(ev) -> bool:
	return ev is InputEventMouseButton and ev.pressed and ev.button_index == MOUSE_BUTTON_LEFT and not head_open and not board_locked


## Rebuild every card from the game state (small board, so a full redraw is simplest).
func _redraw() -> void:
	for c in cards_root.get_children():
		c.queue_free()
	if hearth_view != null:
		hearth_view.redraw()
		return
	for side in ["player", "dealer"]:
		var z := OWN_ROW if side == "player" else FOE_ROW
		for lane in LANES.size():
			var cr = game.board[side][lane]
			if cr != null:
				_card(cr["art"], cr["name"], cr["atk"], cr["hp"], Vector3(LANES[lane], 0.01, z), Vector3.ZERO, false, "",
					game.sigil_text(cr))
	var h: Array = game.hand["player"]
	for i in h.size():
		var k := i - (h.size() - 1) / 2.0
		var cr: Dictionary = game.creature(h[i])
		var lift := 0.1 if i == selected else 0.0
		var card := _card(cr["art"], cr["name"], cr["atk"], cr["hp"],
			Vector3(k * 0.26, 0.99 - absf(k) * 0.02 + lift, 1.62 + absf(k) * 0.03 - lift), Vector3(66, 0, -k * 5), true,
			_cost_text(cr), game.sigil_text(cr))
		card.scale = Vector3.ONE * 0.62   # small enough that the whole card, stats row included, sits on screen
		card.input_event.connect(func(_c, ev, _p, _n, _i):
			if _clicked(ev) and game.turn == "player" and not dealer_thinking:
				selected = -1 if selected == i else i
				fx.redraw())
	# dealer's hand: face-down backs
	var back := _mat(Color("4a1e1a"))
	var back_art: Texture2D = load("res://art/cards/back.png") if ResourceLoader.exists("res://art/cards/back.png") else null
	for i in game.hand["dealer"].size():
		var m := _mesh(_box(Vector3(0.3, 0.012, 0.42)), back, Vector3(1.35 + i * 0.06, 0.006 + i * 0.013, -1.2), cards_root)
		m.rotation_degrees.y = 8 * i
		if back_art:
			_sprite(m, back_art, 0.28, Vector3(0, 0.007, 0)).modulate = Color("c9a87a")   # brass-coloured ink on the red back
	fx.tip_scale(game.scale)
	scale_label.text = "%+d   bones %d" % [game.scale, game.bones["player"]]
	if game.winner != "":
		scale_label.text = "YOU WIN" if game.winner == "player" else "THE DEALER WINS"


## Short cost marker for a card corner: "2B" blood (red), "3b" bones (grey), "" free.
func _cost_text(cr: Dictionary) -> String:
	if cr["kind"] == "free" or cr["cost"] == 0:
		return ""
	return "%d%s" % [cr["cost"], "B" if cr["kind"] == "blood" else "b"]


func _on_lane(lane: int) -> void:
	if selected < 0 or game.turn != "player" or dealer_thinking:
		return
	if game.play("player", {"card_index": selected, "lane": lane}):
		selected = -1
	fx.redraw()


func _end_player_turn() -> void:
	if board_locked or head_open or game.turn != "player" or dealer_thinking or game.winner != "":
		return
	selected = -1
	if hearth_view != null:
		hearth_view.clear_selection()
		hearth_view.flip_glass()
	Sfx.play("bell", 0.02)
	game.end_turn("player")
	if game.winner == "" and game.turn == "dealer":
		_dealer_turn(preload("res://scripts/dealer_ai.gd").picks_per_turn(game))


## The Dealer's scorer shortlists the legal plays (scripts/dealer_ai.gd) and its brain picks one and says a line about
## it; then it may pick again until it passes (max 3). Cut wires loosen the shortlist. In "Brain decides" mode the
## model sees every legal play and always acts (a Sandbox switch in the Debug menu; `-- --sandbox=brain_decides`).
var dealer_ai

func _dealer_turn(picks_left := 3) -> void:
	if game.winner != "" or game.turn != "dealer":
		dealer_thinking = false
		return
	if dealer_ai == null:
		dealer_ai = preload("res://scripts/dealer_ai.gd").new()
	dealer_ai.on_brain_state(ui.wires)
	dealer_ai.brain_decides = Sandbox.enabled("brain_decides")
	var a: Dictionary = dealer_ai.ask(game)
	if a["rows"].is_empty() or picks_left == 0:
		game.end_turn("dealer")
		return
	dealer_thinking = true
	var asked := Time.get_ticks_msec()
	ui.move(a["body"], func(d):
		dealer_thinking = false
		var c: int = dealer_ai.resolve(a, d)
		run_log.dealer_move(c, a["texts"], d.get("say", ""), d.get("raw", ""), Time.get_ticks_msec() - asked,
			game.turn_count, d.get("choice", -1) == c, d.get("attempts", 1))
		if c >= 0 and game.play("dealer", a["rows"][c]["play"]):
			_dealer_turn(picks_left - 1)
		else:
			game.end_turn("dealer"))


func _card(art: String, title: String, power: int, health: int, pos: Vector3, rot_deg: Vector3, hoverable := false,
		cost := "", sigils := "") -> StaticBody3D:
	var card := StaticBody3D.new()
	card.position = pos
	card.rotation_degrees = rot_deg
	cards_root.add_child(card)
	_mesh(_box(Vector3(0.5, 0.012, 0.7)), _mat(Color("d9cbb0")), Vector3.ZERO, card)
	# portraits not drawn yet fall back to a placeholder
	var path := "res://art/cards/%s.png" % art
	_sprite(card, load(path if ResourceLoader.exists(path) else "res://art/cards/shade.png"), 0.36, Vector3(0, 0.008, -0.06))
	_sprite(card, load("res://art/cards/frame.png"), 0.5, Vector3(0, 0.007, 0))
	var ink := Color("2a1a12")
	_label(card, title, mini(22, int(200.0 / maxi(title.length(), 1))), Vector3(0, 0.008, -0.29), ink)
	if power >= 0:   # negative power: a card with no stats (the Dealer's own card on the map)
		_label(card, str(power), 44, Vector3(-0.17, 0.008, 0.27), ink)
		_label(card, str(health), 44, Vector3(0.17, 0.008, 0.27), Color("7a1f18"))
	# sigil icons between attack and health ("Many Lives" -> art/cards/sigils/many-lives.png); text if no icon
	var names := sigils.split(", ", false)
	for j in names.size():
		var icon := "res://art/cards/sigils/%s.png" % names[j].to_lower().replace(" ", "-")
		if ResourceLoader.exists(icon):
			_sprite(card, load(icon), 0.12, Vector3((j - (names.size() - 1) / 2.0) * 0.13, 0.012, 0.25))
		else:
			_label(card, names[j], 14, Vector3(-0.07, 0.008, -0.235 + j * 0.05), Color("3a2a6a"))
	if cost != "":
		_label(card, cost, 26, Vector3(0.17, 0.008, -0.2), Color("7a1f18") if cost.ends_with("B") else Color("4a4038"))
	var col := CollisionShape3D.new()
	var shape := BoxShape3D.new()
	shape.size = Vector3(0.5, 0.03, 0.7)
	col.shape = shape
	card.add_child(col)
	if hoverable:
		var base := card.position
		card.mouse_entered.connect(func(): create_tween().tween_property(card, "position", base + Vector3(0, 0.12, -0.08), 0.12))
		card.mouse_exited.connect(func(): create_tween().tween_property(card, "position", base, 0.12))
	return card


## Flat ink sprite lying on a card, `width` metres wide (portraits, frame, sigil icons).
func _sprite(parent: Node3D, tex: Texture2D, width: float, pos: Vector3) -> Sprite3D:
	var spr := Sprite3D.new()
	spr.texture = tex
	spr.axis = Vector3.AXIS_Y
	spr.pixel_size = width / tex.get_width()
	spr.texture_filter = BaseMaterial3D.TEXTURE_FILTER_NEAREST
	spr.alpha_cut = SpriteBase3D.ALPHA_CUT_DISCARD
	spr.shaded = true
	spr.position = pos
	parent.add_child(spr)
	return spr


func _label(parent: Node3D, text: String, size: int, pos: Vector3, col: Color) -> void:
	var l := Label3D.new()
	l.text = text
	l.font_size = size
	l.pixel_size = 0.004
	l.modulate = col
	l.outline_size = 0
	l.font = preload("res://art/fonts/IMFellEnglish-Regular.ttf")
	l.shaded = true
	l.texture_filter = BaseMaterial3D.TEXTURE_FILTER_LINEAR_WITH_MIPMAPS
	l.rotation_degrees.x = -90
	l.position = pos
	parent.add_child(l)


func _post() -> void:
	var layer := CanvasLayer.new()
	add_child(layer)
	var rect := ColorRect.new()
	rect.set_anchors_preset(Control.PRESET_FULL_RECT)
	rect.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var sm := ShaderMaterial.new()
	sm.shader = load("res://shaders/palette.gdshader")
	var pal := PackedVector3Array()
	for c in PALETTE:
		pal.append(Vector3(c.r, c.g, c.b))
	sm.set_shader_parameter("palette", pal)
	sm.set_shader_parameter("dark_cut", 0.0)
	sm.set_shader_parameter("vignette", 0.25)
	rect.material = sm
	layer.add_child(rect)
