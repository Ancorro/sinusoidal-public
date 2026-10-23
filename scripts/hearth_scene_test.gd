extends SceneTree
## Exercise the actual combat scene and its selection controls. Run with -- --demo-board --no-save.
var fails := 0

func check(label: String, ok: bool) -> void:
	if not ok:
		fails += 1
		push_error(label)

func _initialize() -> void:
	go.call_deferred()

func go() -> void:
	var main = load("res://scenes/main.tscn").instantiate()
	root.add_child(main)
	await process_frame
	var g = main.game
	var v = main.hearth_view
	check("default scene uses hearth rules and board", "hearth" in g and v != null)
	var mana: int = g.mana["player"]
	v.select_card(0)
	check("playing a minion spends mana and puts it on the free board", g.board["player"].size() == 3 and g.mana["player"] == mana - 1)
	v.select_card(0) # Ember now first
	check("targeted spell waits for a target", not v.chosen.is_empty() and g.hp["dealer"] == 30)
	v.heroes["dealer"].pressed.emit()
	check("hero control casts selected spell", g.hp["dealer"] == 28 and v.chosen.is_empty())
	var id: int = g.board["player"][0]["id"]
	v.select_minion(id)
	v.heroes["dealer"].pressed.emit()
	check("ready minion attacks hero", g.hp["dealer"] == 25 and g.find(id)["attacks"] == 0)
	v.select_minion(id)
	v.heroes["dealer"].pressed.emit()
	check("spent minion cannot attack twice", g.hp["dealer"] == 25)
	g.board["dealer"].clear()
	var guard: Dictionary = g._summon("dealer", "Beetle")
	v.select_minion(g.board["player"][1]["id"])
	v.heroes["dealer"].pressed.emit()
	check("taunt prevents hero attack through controls", g.hp["dealer"] == 25)
	v.select_minion(guard["id"])
	check("targeting taunt resolves combat both ways", g.board["dealer"].is_empty() and g.board["player"][1]["hp"] == 4)
	main.board_locked = true
	v.select_card(0)
	check("map locks combat controls", v.chosen.is_empty())
	g = null
	v = null
	main.queue_free()
	await process_frame
	await process_frame
	for player in root.get_node("Sfx").get_children():
		player.stop()
	await create_timer(0.15).timeout
	print("hearth scene: %d failures" % fails)
	quit(1 if fails else 0)
