extends SceneTree
## All creature heads, wire state across encounters, persona gauge attachment and seeded clearing variants.
## Run with -- --demo-board --no-save --sandbox=personas (no model needed).
var fails := 0

func check(label: String, ok: bool) -> void:
	if not ok:
		fails += 1
		push_error(label)

func _initialize() -> void:
	Engine.time_scale = 6
	go.call_deferred()

func go() -> void:
	var main = load("res://scenes/main.tscn").instantiate()
	root.add_child(main)
	await process_frame
	for id in main.creature_data:
		main.ui.wires = [{"id": "red", "cut": true}, {"id": "blue", "cut": false}, {"id": "yellow", "cut": false}, {"id": "green", "cut": false}]
		main.set_creature(id)
		check("%s: four wires and a brain module" % id, main.wires.size() == 4 and is_instance_valid(main.brain_module))
		check("%s: cut survives creature change" % id, main.wires["red"]["cut"] and not main.wires["blue"]["cut"])
		check("%s: circuit hidden under closed lid" % id, not main.brain_module.visible)
		var opening: Tween = main.toggle_head()
		await opening.finished
		check("%s: head opens and reveals the circuit" % id, main.head_open and main.brain_module.visible and absf(main.lid_pivot.rotation_degrees.x + 140) < 0.1)
		var closing: Tween = main.toggle_head()
		await closing.finished
		check("%s: closes and returns camera" % id, not main.head_open and main.cam.transform.is_equal_approx(main.cam_home))
		var persona = main.get_children().filter(func(c): return c.get_script() == load("res://scripts/persona_meter.gd"))[0]
		check("%s: persona gauge attached to new body" % id, is_instance_valid(persona.dial) and persona.dial.get_parent() == main.figure)
	for id in main.forest.data:
		main.forest.set_clearing(id, 19)
		check("%s: seeded clearing builds scenery" % id, main.forest.clearing_id == id and main.forest.scenery.get_child_count() > 5)
	main.set_encounter(19, true)
	check("boss wears the walnut Dealer body", main.creature_id == "dealer")
	var motion := InputEventMouseMotion.new()
	motion.button_mask = MOUSE_BUTTON_MASK_RIGHT
	motion.relative = Vector2(300, -80)
	main._input(motion)
	check("right drag looks around the clearing", absf(main.look_yaw) > 40 and not main.cam.transform.is_equal_approx(main.cam_home))
	var space := InputEventKey.new()
	space.pressed = true
	space.keycode = KEY_SPACE
	main._input(space)
	check("Space returns to the board", main.cam.transform.is_equal_approx(main.cam_home))
	main.queue_free()
	await process_frame
	for player in root.get_node("Sfx").get_children():
		player.stop()
	await create_timer(1).timeout
	print("forest scene: %d failures" % fails)
	quit(1 if fails else 0)
