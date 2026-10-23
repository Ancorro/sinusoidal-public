extends SceneTree
## Feed mouse events through the viewport's real picking path, rather than calling the board's selection methods.
## Run with -- --demo-board --no-save --brain=http://127.0.0.1:1.
var fails := 0

func _initialize() -> void:
	go.call_deferred()

func click(at: Vector2) -> void:
	var motion := InputEventMouseMotion.new()
	motion.position = at
	motion.global_position = at
	root.push_input(motion, true)
	await physics_frame
	var button := InputEventMouseButton.new()
	button.position = at
	button.global_position = at
	button.button_index = MOUSE_BUTTON_LEFT
	button.pressed = true
	root.push_input(button, true)
	await physics_frame
	await process_frame
	button = button.duplicate()
	button.pressed = false
	root.push_input(button, true)
	await physics_frame
	await process_frame

func go() -> void:
	var main = load("res://scenes/main.tscn").instantiate()
	root.add_child(main)
	await physics_frame
	await process_frame
	var hand: Array = main.cards_root.get_children().filter(func(c): return not c.is_queued_for_deletion() and c is StaticBody3D and c.position.y > 0.3)
	hand.sort_custom(func(a, b): return a.position.x < b.position.x)
	var mana: int = main.game.mana["player"]
	await click(main.cam.unproject_position(hand[0].global_position))
	if main.game.mana["player"] != mana - 1:
		fails += 1
		push_error("mouse click on hand card did not play Rat")
	hand = main.cards_root.get_children().filter(func(c): return not c.is_queued_for_deletion() and c is StaticBody3D and c.position.y > 0.3)
	hand.sort_custom(func(a, b): return a.position.x < b.position.x)
	await click(main.cam.unproject_position(hand[0].global_position))
	var hero: Button = main.hearth_view.heroes["dealer"]
	await click((hero.global_position + hero.size / 2) * main.hearth_view.hud.scale)
	if main.game.hp["dealer"] != 28:
		fails += 1
		push_error("mouse spell selection and hero target did not resolve Ember")
	var attacker: int = main.game.board["player"][0]["id"]
	await click(main.cam.unproject_position(main.hearth_view.card_nodes[attacker].global_position))
	await click((hero.global_position + hero.size / 2) * main.hearth_view.hud.scale)
	if main.game.hp["dealer"] != 25:
		fails += 1
		push_error("mouse selection and hero button did not resolve attack")
	main.queue_free()
	await process_frame
	for player in root.get_node("Sfx").get_children():
		player.stop()
	await create_timer(0.15).timeout
	print("hearth input: %d failures" % fails)
	quit(1 if fails else 0)
