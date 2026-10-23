extends SceneTree
## Drives the real table through a run without clicks: walk to a stop, win and lose hands by tipping the scale,
## take a card, and check the board, candles and summary follow. Writes no save. With --sandbox=corrupt, also checks the
## first won hand records the Dealer's lesson (the brain call fails quietly with no server).
##   godot_console --headless --path . --script res://scripts/run_scene_test.gd -- --no-save --run-seed=7 [--sandbox=dealer_steers_run]

var fails := 0


func check(what: String, ok: bool) -> void:
	if not ok:
		fails += 1
		print("FAIL: ", what)


func _initialize() -> void:
	if "--fast" in OS.get_cmdline_user_args():
		Engine.time_scale = 4
	_go()


func _go() -> void:
	var main: Node = load("res://scenes/main.tscn").instantiate()
	root.add_child(main)
	await process_frame
	var rt: Node = main.get_children().filter(func(c): return c.get_script() != null and c.get_script().resource_path.ends_with("run_table.gd"))[0]
	var run = rt.run
	check("starts on the map", run.phase == "map" and main.board_locked and not main.cards_root.visible)
	rt._on_stop(0)
	await create_timer(0.8).timeout
	check("stop 0 starts a battle", run.phase == "battle" and not main.board_locked and main.cards_root.visible)
	var held: Array = main.game.deck["player"] + main.game.hand["player"]
	check("deck carried", held.filter(func(n): return n != "Squirrel").size() == run.deck.size())
	# lose the hand: a candle goes out, the same stop is dealt again
	if "hearth" in main.game:
		main.game.hp["player"] = 0
	else:
		main.game.scale = -5
	main.game._check_winner()
	main.game.changed.emit()
	await create_timer(2.8).timeout   # 1.8 s for the result to sink in, then fx's gutter animation
	check("loss costs a candle", run.candles == 2 and run.phase == "battle" and rt.panel.visible)
	check("one flame out", main.candle_lights.filter(func(l): return l.visible).size() == 2)
	rt.panel_button.pressed.emit()
	await create_timer(0.3).timeout
	check("battle dealt again", main.game.winner == "" and main.game.turn_count == 1)
	# win it and walk on, taking a card at the first card choice
	var guard := 0
	var events := 0
	var picks := 0
	var boss_candles := 0
	const Run := preload("res://scripts/run.gd")
	while run.phase != "over" and guard < 70:
		guard += 1
		if run.phase == "battle":
			if run.is_boss():
				# The longer route can spend candles in events; the rest restores one, up to the maximum.
				check("candle relit for the boss", run.candles == boss_candles and main.candle_lights.filter(func(l): return l.visible).size() == boss_candles)
			if "hearth" in main.game:
				main.game.hp["dealer"] = 0
			else:
				main.game.scale = 5
			main.game._check_winner()
			main.game.changed.emit()
			await create_timer(2.3).timeout
			if run.phase != "over":
				check("win shows a panel", rt.panel.visible)
				# sandbox "corrupt": the first won hand teaches the Dealer a lesson; switched off, nothing changes
				var corrupt: bool = root.get_node("Sandbox").enabled("corrupt")
				var first_win: bool = run.history.filter(func(h): return h["result"] == "won").size() == 1
				check("lesson follows the corrupt switch", run.lesson == corrupt
					and ("darkens" in rt.panel_text.text) == (corrupt and first_win))
				rt.panel_button.pressed.emit()
				await create_timer(0.2).timeout
				check("back on the map", run.phase == "map" and main.board_locked)
		elif run.phase == "map":
			var nxt: Array = run.reachable()
			# visit card choices and events when the map offers them
			var pick = nxt[0]
			for id in nxt:
				if run.nodes[id]["type"] in ["choice", "event"]:
					pick = id
			if run.nodes[pick]["type"] == "boss":
				boss_candles = mini(Run.CANDLES, run.candles + 1)
			rt._on_stop(pick)
			await create_timer(0.8).timeout
		elif run.phase == "choice":
			check("three cards dealt", rt.choice_root != null and rt.choice_root.get_child_count() == 3)
			var before: int = run.deck.size()
			rt._on_pick(1, rt.choice_root.get_child(1))
			await create_timer(0.8).timeout
			check("card added", run.deck.size() == before + 1)
		elif run.phase == "event":
			events += 1
			await create_timer(0.6).timeout   # the note slides over before its page opens
			check("event note shown", rt.note_panel.visible and rt.note_buttons.get_child_count() >= 2)
			# prefer an option that needs a card pick, to drive the deck spread too
			var opts: Array = run.event_options()
			var choice := -1
			for i in opts.size():
				if opts[i]["block"] == "":
					if choice < 0 or Run.EVENTS[run.event["id"]]["options"][i]["effects"].any(func(f): return f.has("pick")):
						choice = i
			var blocked: Array = rt.note_buttons.get_children().filter(func(b): return b.disabled)
			check("blocked options disabled", blocked.size() == opts.filter(func(o): return o["block"] != "").size())
			rt.note_buttons.get_child(choice).pressed.emit()
			await create_timer(0.2).timeout
			while run.pending_pick() != "":
				picks += 1
				check("deck spread for pick", rt.deck_root != null and rt.deck_root.get_child_count() == run.deck.size())
				rt._on_pick_card(0)
				await create_timer(0.2).timeout
			check("event result shown", rt.panel.visible and run.phase == "map")
			rt.panel_button.pressed.emit()
			await create_timer(0.2).timeout
			check("map after event", main.board_locked and not rt.note_panel.visible)
	await create_timer(1.0).timeout
	check("an event was visited", events > 0)
	print("events visited: %d, card picks: %d" % [events, picks])
	check("run won", run.phase == "over" and run.won)
	check("summary shown", rt.panel.visible and rt.panel_text.text.contains("YOU BEAT THE DEALER"))
	# the Dealer acted on the map between stops (the model's pick, or its seeded pick when the test clicked first)
	# with the sandbox feature off the map is never touched (run with -- --sandbox=dealer_steers_run to test it on)
	if Engine.get_main_loop().root.get_node("/root/Sandbox").enabled("dealer_steers_run"):
		check("the Dealer steered", run.steers.size() >= 2 and rt.steer_pending.is_empty())
	else:
		check("main mode: no steering", run.steers.is_empty() and run.sealed.is_empty() and run.hidden.is_empty())
	check("a premise was written", run.premise != "")
	check("steering kept the map whole", run._paths_ok())
	print(rt.panel_text.text)
	print("FAILED %d checks" % fails if fails else "all checks passed")
	main.queue_free()
	await process_frame
	quit(1 if fails else 0)
