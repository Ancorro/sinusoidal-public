extends Node3D
## Seeded night clearings: textured ground, instanced evergreens and forest props, moonlight and a small fire.
## One game unit is about 0.4 metres; the clearing is roughly 100 feet across. Assets: CREDITS.md.
var main
var rng := RandomNumberGenerator.new()
var clearing_id := ""
var world: WorldEnvironment
var moon: DirectionalLight3D
var scenery: Node3D
var fire_light: OmniLight3D
var flames: Array = []
var elapsed := 0.0
var data: Dictionary = JSON.parse_string(FileAccess.get_file_as_string("res://data/clearings.json"))["clearings"]

func _init(m) -> void:
	main = m

func _ready() -> void:
	world = WorldEnvironment.new()
	add_child(world)
	moon = DirectionalLight3D.new()
	moon.shadow_enabled = true
	moon.directional_shadow_max_distance = 100
	add_child(moon)
	set_clearing("fern_hollow", 7)

func _process(dt: float) -> void:
	elapsed += dt
	if fire_light != null:
		fire_light.light_energy = 1.6 + sin(elapsed * 9.7) * 0.14 + sin(elapsed * 17.3) * 0.08
	for i in flames.size():
		if is_instance_valid(flames[i]):
			flames[i].scale = Vector3(1, 0.85 + 0.2 * sin(elapsed * (11.0 + i * 1.7) + i), 1)

func set_clearing(id: String, seed_value: int) -> void:
	clearing_id = id if data.has(id) else "fern_hollow"
	rng.seed = seed_value
	if scenery != null:
		scenery.free()
	scenery = Node3D.new()
	add_child(scenery)
	var d: Dictionary = data[clearing_id]
	var env := Environment.new()
	var sky_mat := ProceduralSkyMaterial.new()
	sky_mat.sky_top_color = Color(d["sky_top"])
	sky_mat.sky_horizon_color = Color(d["sky_horizon"])
	sky_mat.ground_horizon_color = Color(d["sky_horizon"])
	sky_mat.ground_bottom_color = Color("020403")
	sky_mat.sky_curve = 0.28
	var sky := Sky.new()
	sky.sky_material = sky_mat
	env.sky = sky
	env.background_mode = Environment.BG_SKY
	env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.ambient_light_color = Color(d["ambient"])
	# Night: almost no fill. The small fire beside the board is the main light; the moon only rims the trees.
	env.ambient_light_energy = 0.04
	env.tonemap_mode = Environment.TONE_MAPPER_FILMIC
	env.tonemap_exposure = 0.85
	env.glow_enabled = true
	env.glow_intensity = 0.35
	env.glow_hdr_threshold = 1.2
	env.fog_enabled = true
	env.fog_light_color = Color(d["fog_color"])
	env.fog_density = float(d["fog_density"]) * 0.3
	world.environment = env
	moon.rotation_degrees = Vector3(-float(d["moon"][0]), float(d["moon"][1]), 0)
	moon.light_color = Color(d["moon_color"])
	moon.light_energy = float(d["moon_energy"]) * 0.07
	_ground(d)
	_trees(d)
	_props(d)
	_fire(Color(d["fire"]))
	if int(d.get("stones", 0)) > 0:
		for i in int(d["stones"]):
			var a := i * TAU / int(d["stones"])
			var stone := SphereMesh.new()
			stone.radius = 0.65
			stone.height = 2.2
			stone.radial_segments = 8
			stone.rings = 4
			main._mesh(stone, main._mat(Color("43494e")), Vector3(cos(a) * 9, 0.8, sin(a) * 9), scenery)
	if d.get("giant", 0):
		var log_node: Node3D = load("res://art/models/forest/dead_tree_trunk.glb").instantiate()
		var log_parts := []
		_parts(log_node, Transform3D.IDENTITY, log_parts)
		var bounds := _bounds(log_parts)
		scenery.add_child(log_node)
		var scale_value := 20.0 / maxf(bounds.size.x, bounds.size.z)
		log_node.scale = Vector3.ONE * scale_value
		log_node.position = Vector3(-13, -bounds.position.y * scale_value, -14)
		log_node.rotation.y = 0.8
	_fireflies(int(d.get("fireflies", 0)))

func _ground(d: Dictionary) -> void:
	var mat := StandardMaterial3D.new()
	mat.albedo_texture = _texture("res://art/forest/ground_%s.jpg" % d["ground"])
	mat.albedo_color = Color("4a524a")
	mat.normal_enabled = true
	mat.normal_texture = _texture("res://art/forest/ground_%s_n.jpg" % d["ground"])
	mat.normal_scale = 0.3
	mat.uv1_scale = Vector3(64, 64, 1)
	mat.roughness = 0.98
	mat.texture_filter = BaseMaterial3D.TEXTURE_FILTER_LINEAR_WITH_MIPMAPS_ANISOTROPIC
	var plane := PlaneMesh.new()
	plane.size = Vector2(240, 240)
	main._mesh(plane, mat, Vector3(0, -0.025, 0), scenery)
	# A worn patch keeps the cards readable without putting furniture under them.
	var patch := CylinderMesh.new()
	patch.top_radius = 2.5
	patch.bottom_radius = 2.5
	patch.height = 0.012
	patch.radial_segments = 64
	var worn := mat.duplicate()
	worn.albedo_color = Color("525045")
	worn.uv1_scale = Vector3(2.5, 2.5, 1)
	main._mesh(patch, worn, Vector3(0, -0.012, -0.5), scenery)

var texture_cache := {}
func _texture(path: String) -> Texture2D:
	if not texture_cache.has(path):
		var source: Texture2D = load(path)
		var image := source.get_image()
		image.generate_mipmaps()
		texture_cache[path] = ImageTexture.create_from_image(image)
	return texture_cache[path]

func _instances(mesh: Mesh, transforms: Array, material: Material = null) -> void:
	if transforms.is_empty():
		return
	var mm := MultiMesh.new()
	mm.transform_format = MultiMesh.TRANSFORM_3D
	mm.mesh = mesh
	mm.instance_count = transforms.size()
	for i in transforms.size():
		mm.set_instance_transform(i, transforms[i])
	var node := MultiMeshInstance3D.new()
	node.multimesh = mm
	if material != null:
		node.material_override = material
	scenery.add_child(node)

func _trees(d: Dictionary) -> void:
	var bark := StandardMaterial3D.new()
	bark.albedo_texture = _texture("res://art/forest/bark.jpg")
	bark.albedo_color = Color("6f766c")
	bark.uv1_scale = Vector3(2, 8, 1)
	bark.roughness = 1.0
	var trunk := CylinderMesh.new()
	trunk.top_radius = 0.10
	trunk.bottom_radius = 0.44
	trunk.height = 25
	trunk.radial_segments = 8
	var needles := StandardMaterial3D.new()
	needles.albedo_texture = _texture("res://art/forest/twig.png")
	needles.albedo_color = Color(d["tree_tint"]).lightened(0.22)
	needles.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA_SCISSOR
	needles.alpha_scissor_threshold = 0.35
	needles.cull_mode = BaseMaterial3D.CULL_DISABLED
	needles.roughness = 0.95
	needles.texture_filter = BaseMaterial3D.TEXTURE_FILTER_LINEAR_WITH_MIPMAPS
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	for layer_index in 11:
		var f := layer_index / 11.0
		var y := 4.5 + f * 19
		var radius := 5.8 * (1.0 - f) + 0.3
		for arm in 9:
			var angle := arm * TAU / 9 + layer_index * 1.71
			var dir := Vector3(cos(angle), 0, sin(angle))
			var across := Vector3(-dir.z, 0, dir.x) * radius * 0.48
			var centre := dir * radius * 0.3 + Vector3(0, y, 0)
			var tip := dir * radius + Vector3(0, y - 1.0, 0)
			var vertices := [centre - across, centre + across, tip + across * 0.28, tip - across * 0.28]
			var u := (arm % 2) * 0.5
			var v := (layer_index % 2) * 0.5
			var uv := [Vector2(u, v + 0.5), Vector2(u + 0.5, v + 0.5), Vector2(u + 0.5, v), Vector2(u, v)]
			for j in [0, 1, 2, 0, 2, 3]:
				st.set_uv(uv[j])
				st.set_normal(Vector3.UP)
				st.add_vertex(vertices[j])
	var crown := st.commit()
	var trunks := []
	var crowns := []
	for i in 360:
		var angle := rng.randf() * TAU
		var r := float(d["radius"]) + rng.randf_range(0, 65)
		var pos := Vector3(cos(angle) * r, 0, sin(angle) * r)
		var scale_value := rng.randf_range(0.65, 1.55)
		var basis := Basis(Vector3.UP, rng.randf() * TAU).scaled(Vector3(scale_value, scale_value, scale_value))
		crowns.append(Transform3D(basis, pos))
		trunks.append(Transform3D(basis, pos + Vector3(0, 12.5 * scale_value, 0)))
	_instances(trunk, trunks, bark)
	_instances(crown, crowns, needles)

func _parts(node: Node, transform: Transform3D, out: Array) -> void:
	if node is Node3D:
		transform = transform * node.transform
	if node is MeshInstance3D and node.mesh != null:
		out.append({"mesh": node.mesh, "transform": transform, "material": node.material_override})
	for child in node.get_children():
		_parts(child, transform, out)

func _bounds(parts: Array) -> AABB:
	var bounds: AABB = parts[0]["transform"] * parts[0]["mesh"].get_aabb()
	for part in parts.slice(1):
		bounds = bounds.merge(part["transform"] * part["mesh"].get_aabb())
	return bounds

func _props(d: Dictionary) -> void:
	for name in d["props"]:
		var model: Node3D = load("res://art/models/forest/%s.glb" % name).instantiate()
		var parts := []
		_parts(model, Transform3D.IDENTITY, parts)
		var bounds := _bounds(parts)
		var heights := {"fern_02": 0.8, "rock_moss_set_01": 1.1, "tree_stump_01": 1.0, "dead_tree_trunk": 1.3, "pine_roots": 0.5}
		var normal_scale: float = heights[name] / maxf(bounds.size.y, 0.01)
		var base := Vector3(bounds.get_center().x, bounds.position.y, bounds.get_center().z)
		var placements := []
		for i in int(d["props"][name]):
			var angle := rng.randf() * TAU
			var r := rng.randf_range(7.0, float(d["radius"]) + 8)
			var s := normal_scale * rng.randf_range(0.65, 1.5)
			var basis := Basis(Vector3.UP, rng.randf() * TAU).scaled(Vector3.ONE * s)
			placements.append(Transform3D(basis, Vector3(cos(angle) * r, 0, sin(angle) * r) - basis * base))
		for part in parts:
			var transforms := placements.map(func(p): return p * part["transform"])
			_instances(part["mesh"], transforms, part["material"])
		model.free()

func _fire(color: Color) -> void:
	# A small campfire on the player's left, past the candles and just off the board: a ring of stones, crossed sticks, embers and flames.
	var at := Vector3(-2.15, 0.0, -0.35)
	var stone_mat: StandardMaterial3D = main._mat(Color("2b2a27"))
	for i in 9:
		var a := i * TAU / 9 + rng.randf_range(-0.12, 0.12)
		var stone := SphereMesh.new()
		stone.radius = rng.randf_range(0.06, 0.085)
		stone.height = stone.radius * 1.3
		stone.radial_segments = 7
		stone.rings = 3
		main._mesh(stone, stone_mat, at + Vector3(cos(a) * 0.3, 0.03, sin(a) * 0.3), scenery)
	var wood: StandardMaterial3D = main._mat(Color("1d130b"))
	for i in 5:
		var stick := CylinderMesh.new()
		stick.top_radius = 0.018
		stick.bottom_radius = 0.028
		stick.height = 0.42
		stick.radial_segments = 6
		var node = main._mesh(stick, wood, Vector3.ZERO, scenery)
		# leaned in so the tops meet over the embers, teepee style
		node.rotation = Vector3(0.55, i * TAU / 5, 0)
		node.position = at + Vector3(0, 0.3, 0) - node.basis.y * 0.21
	var embers := CylinderMesh.new()
	embers.top_radius = 0.15
	embers.bottom_radius = 0.18
	embers.height = 0.03
	main._mesh(embers, main._glow(Color("ff4a14"), 1.6), at + Vector3(0, 0.01, 0), scenery)
	flames.clear()
	# Flat-coloured unshaded flames: orange tongues around a smaller yellow core. Emissive or additive flames stack
	# past 1.0 and the filmic tonemap washes them to white.
	for i in 6:
		var core := i == 0
		var flame := SphereMesh.new()
		flame.radius = 0.045 if core else rng.randf_range(0.04, 0.065)
		flame.height = flame.radius * (4.5 if core else rng.randf_range(3.5, 5.5))
		flame.radial_segments = 8
		flame.rings = 4
		var mat := StandardMaterial3D.new()
		mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		mat.albedo_color = Color("ffc23a") if core else color.lerp(Color("e8400c"), rng.randf_range(0.2, 0.8))
		var r := 0.0 if core else rng.randf_range(0.05, 0.1)
		var a := rng.randf() * TAU
		var f = main._mesh(flame, mat, at + Vector3(cos(a) * r, 0.02 + flame.height * 0.5, sin(a) * r), scenery)
		if core:
			f.position += Vector3(0, 0, 0.06)   # toward the camera, in front of the tongues
		flames.append(f)
	fire_light = OmniLight3D.new()
	fire_light.position = at + Vector3(0, 0.45, 0)
	fire_light.light_color = color
	fire_light.light_energy = 1.6
	fire_light.omni_range = 6.0
	fire_light.omni_attenuation = 1.6
	fire_light.shadow_enabled = true
	scenery.add_child(fire_light)

func _fireflies(count: int) -> void:
	var sphere := SphereMesh.new()
	sphere.radius = 0.018
	sphere.height = 0.036
	var transforms := []
	for i in count:
		transforms.append(Transform3D(Basis.IDENTITY, Vector3(rng.randf_range(-12, 12), rng.randf_range(0.2, 2), rng.randf_range(-17, -3))))
	_instances(sphere, transforms, main._glow(Color("b3d96d"), 4))
