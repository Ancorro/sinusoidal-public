extends Node3D
## The run on the table: a parchment map with stop tokens, three cards to pick from at card-choice stops, event notes
## the Dealer slides across at "?" stops, candles as lives, and a summary when the run ends. Rules and state live in scripts/run.gd; main.gd owns the battle board.
## Options after `--`: --new-run (drop the saved run), --run-seed=N, and for screenshots
## --no-save (start fresh, write nothing), --run-view=map|choice|event|pick|battle|won|lost|steered|bargain (a seeded run
## walked to that point; nothing is saved; steered shows the Dealer's marks and premise), --event=id (with event or pick).
## The story (premise, lines between stops, ending) comes from scripts/story.gd; so does the Dealer's map steering, a
## sandbox feature (Sandbox "dealer_steers_run", on for the steered and bargain previews). Nothing
## here waits on the brain: a click before the Dealer has decided makes it act on its seeded fallback at once.

const UITheme := preload("res://scripts/ui_theme.gd")
const Run := preload("res://scripts/run.gd")
const Story := preload("res://scripts/story.gd")
const DEALER_AI := "res://scripts/dealer_ai.gd"
const MAP_CENTER := Vector3(0, 0.04, -0.3)   # the trail chart lies on the clearing floor
const MAP_TILT := 0.0
const MAP_SIZE := Vector2(4.0, 7.0)
const ROW_STEP := 0.44
const COL_STEP := 1.15
const TYPE_TEXT := {"battle": "Battle: a hand against the Dealer.", "choice": "Card choice: add 1 of 3 cards to your deck.",
	"boss": "The final hand. The Dealer plays its best cards.", "hidden": "The Dealer has hidden what waits here.",
	"event": "Unknown: something waits here. Choose with care."}
const CANDLE_COLOR := Color("ff9a3c")   # main.gd's candle light colour; fx.gd blacks it out
const FALLBACK_QUOTES := ["The ledger is closed. Sit a while longer.", "Every candle burns down. Yours simply burned first.",
	"You played well. I counted every move.", "Again. We will play again. We always do."]

var main: Node
var run: Run
var parchment: Node3D
var tokens := {}              # node id -> {body, mesh, base}
var pawn: Node3D
var choice_root: Node3D
var hint: Label
var panel: PanelContainer
var panel_text: Label
var panel_button: Button
var lights: Array = []        # every candle light, so a new run can relight them
var t := 0.0
var battle_ending := false
var wire_states := []        # last wire states from the brain, so a new run starts knowing what is already cut
var preview := ""             # --run-view for screenshots
var story: Node               # scripts/story.gd: talks to the brain's /story route
var steer_pending := {}       # {at, menu, event} while the Dealer decides how to bend the map
var bargain_root: Node3D
var wire_states_seen := false # the first wire state is the server's standing cuts, not a new cut
var preview_event := ""       # --event=id for screenshots
var lesson: Node              # scripts/lesson.gd: sandbox "corrupt"


func _ready() -> void:
	main = get_parent()
	if main.demo_board:
		queue_free()
		return
	add_to_group("run_table")   # the settings menu's "Abandon run" finds it here
	run = Run.new()
	var fresh := false
	var run_seed := 0
	for a in OS.get_cmdline_user_args():
		if a == "--new-run":
			fresh = true
		elif a.begins_with("--run-seed="):
			run_seed = int(a.substr(11))
		elif a == "--no-save":
			run.save_enabled = false
		elif a.begins_with("--run-view="):
			preview = a.substr(11)
		elif a.begins_with("--event="):
			preview_event = a.substr(8)
	# screenshots never touch the player's saved run
	if main.shot_path != "" or preview != "" or not run.save_enabled:
		run.save_enabled = false
		fresh = true
	lights = main.candle_lights.duplicate()
	story = Story.new()
	add_child(story)
	_ui()
	main.ui.state_changed.connect(func(states):
		wire_states = states
		var before := run.wires_cut.size()
		run.note_wires(states)
		run.save()
		# a fresh cut between stops gets a reaction; during a hand the Dealer is busy playing
		if run.wires_cut.size() > before and run.phase != "battle" and run.phase != "over" and wire_states_seen:
			_say_line("cut")
		wire_states_seen = true)
	main.game.changed.connect(_on_battle_changed)
	if fresh or not run.load_save():
		run.start(run_seed if run_seed else (7 if preview != "" else 0))   # tests pass --run-seed for a fixed map
		run.save()
		_log("run_start", {"seed": run.run_seed, "stops": run.nodes.size()})
	lesson = preload("res://scripts/lesson.gd").new(main, run)
	add_child(lesson)
	if preview != "":
		_walk_to(preview)
	elif run.premise == "":
		_ask_premise()
	_build_map()
	_show_candles()
	_enter_phase()


func _process(delta: float) -> void:
	t += delta
	# stops you can walk to bob gently
	for id in tokens:
		var tok: Dictionary = tokens[id]
		var live := run.reachable().has(id)
		tok["body"].position.y = tok["base"].y + (0.025 + 0.02 * sin(t * 3.0 + id) if live else 0.0)


# ---------- phases ----------
func _enter_phase() -> void:
	battle_ending = false
	_hide_panel()
	match run.phase:
		"map":
			_board_active(false)
			_show_map(true)
			main.ui.hint("Choose your next stop on the map." if run.at >= 0 else "The Dealer unrolls a map. Choose where to begin.")
			if not steer_pending.is_empty():
				main.ui.hint("The Dealer leans over the map...")
		"choice":
			_board_active(false)
			_show_map(true)
			_deal_choice()
		"event":
			_board_active(false)
			_show_map(true)
			_show_event()
		"battle":
			_show_map(false)
			_start_battle()
		"over":
			_board_active(false)
			_show_map(true)
			_summary()
	_refresh_tokens()


func _board_active(on: bool) -> void:
	main.board_locked = not on
	main.cards_root.visible = on
	main.cards_root.process_mode = Node.PROCESS_MODE_INHERIT if on else Node.PROCESS_MODE_DISABLED
	main.scale_label.visible = on


func _start_battle() -> void:
	main.set_encounter(int(run.battle["seed"]), run.is_boss())
	main.selected = -1
	if main.hearth_view != null:
		main.hearth_view.clear_selection()
	main.dealer_thinking = false
	main.fx.reset()
	_board_active(true)
	var b: Dictionary = run.battle
	main.fx.candles_out = Run.CANDLES - run.candles   # so fx.gutter_candle() picks the next lit candle
	main.logged_end = false
	if run.is_boss() and ResourceLoader.exists(DEALER_AI):
		load(DEALER_AI).setup_boss(main.game, b["seed"], run.deck)   # track C: its boss deck and stronger play
	else:
		main.game.setup(b["seed"], run.deck, run.dealer_deck())
	main.game.set_meta("boss", run.is_boss())   # one Battle plays every hand, so the flag is set each time
	run.apply_marks(main.game)   # lasting marks from events: bones, a tilted scale, the Dealer's extra cards
	_log("stop", {"index": run.at, "kind": run.nodes[run.at]["type"], "attempt": b["attempt"], "candles": run.candles})
	main.run_log.battle_start(main.game, {"player_bot": "human", "brain": "server", "stop": run.at})
	var what := "The final hand." if run.is_boss() else "A hand against the Dealer."
	main.ui.hint(what + ("" if b["attempt"] == 1 else " Dealt again."))
	if b.get("relit", 0) and b["attempt"] == 1:
		main.ui.hint(hint.text + " The Dealer relights a candle for it.")
		_show_candles()
	# the hint sits over the hand, so it fades once the hand is under way
	await get_tree().create_timer(3.0).timeout
	if run.phase == "battle":
		main.ui.hint("")


## Watches the board for the moment a battle is decided, then lets the result sink in before moving on.
func _on_battle_changed() -> void:
	if run.phase != "battle" or main.game.winner == "" or battle_ending:
		return
	battle_ending = true
	var won: bool = main.game.winner == "player"
	main.board_locked = true
	await get_tree().create_timer(1.8).timeout
	run.battle_over(won)
	if not won:
		main.fx.gutter_candle()   # a life lost: the next candle gutters out, with its sound
	if run.phase == "over":
		run.quote = _dealer_quote()
		run.save()
		_ask_ending()
	elif won:
		_dealer_steers("won")
	else:
		_say_line("lost")
	if run.phase == "over":
		_log("run_end", {"won": run.won, "cleared": run.cleared(), "candles": run.candles, "deck": run.deck,
			"wires_cut": run.wires_cut, "quote": run.quote, "premise": run.premise, "lines": run.lines, "steers": run.steers})
		await get_tree().create_timer(0.8).timeout
		_enter_phase()
	elif won:
		var learned: String = lesson.after_win()
		_show_panel("You won the hand." + ("
" + learned if learned != "" else ""), "Back to the map", func(): _enter_phase())
	else:
		_show_panel("A candle goes out. %d left." % run.candles, "Deal again", func(): _enter_phase())


func _dealer_quote() -> String:
	var s: String = main.ui.reply.text.strip_edges()
	if s == "" or s.length() > 160:
		return FALLBACK_QUOTES[run.rng.randi_range(0, FALLBACK_QUOTES.size() - 1)]
	return s


# ---------- map ----------
func _stop_pos(n: Dictionary) -> Vector3:
	var x: float = (n["col"] - (n["cols"] - 1) / 2.0) * COL_STEP
	# the first row nearest you, the boss at the far edge
	return Vector3(x, 0.02, ((run.rows() - 1) / 2.0 - n["row"]) * ROW_STEP)


func _build_map() -> void:
	parchment = Node3D.new()
	parchment.position = MAP_CENTER
	parchment.rotation_degrees.x = MAP_TILT
	add_child(parchment)
	var noise := FastNoiseLite.new()
	noise.frequency = 0.05
	var ramp := Gradient.new()
	ramp.set_color(0, Color("b89a6a"))
	ramp.set_color(1, Color("e2cfa0"))
	var tex := NoiseTexture2D.new()
	tex.noise = noise
	tex.color_ramp = ramp
	tex.width = 64
	tex.height = 48
	# Unlit so every stop stays readable, but dimmed to a firelit tone so the chart doesn't glow against the night.
	var m: StandardMaterial3D = main._mat(Color("6e5a44"))
	m.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	m.albedo_texture = tex
	main._mesh(main._box(Vector3(MAP_SIZE.x, 0.006, MAP_SIZE.y)), m, Vector3(0, 0.006, 0), parchment)
	# rolled ends, like a scroll held flat
	for side in [-1, 1]:
		var roll := CylinderMesh.new()
		roll.top_radius = 0.045
		roll.bottom_radius = 0.045
		roll.height = MAP_SIZE.x + 0.06
		var r: MeshInstance3D = main._mesh(roll, main._mat(Color("c8ad7a")), Vector3(0, 0.04, side * MAP_SIZE.y / 2), parchment)
		r.rotation_degrees.z = 90
	var ink: StandardMaterial3D = main._mat(Color("3a2416"))
	for n in run.nodes:
		for k in n["next"]:
			_ink_line(_stop_pos(n), _stop_pos(run.nodes[k]), ink)
	for n in run.nodes:
		_token(n)
	pawn = Node3D.new()
	parchment.add_child(pawn)
	var brass: StandardMaterial3D = main._mat(Color("c9a045"), 0.3)
	brass.metallic = 0.85
	var foot := CylinderMesh.new()
	foot.top_radius = 0.025
	foot.bottom_radius = 0.045
	foot.height = 0.09
	main._mesh(foot, brass, Vector3(0, 0.045, 0), pawn)
	var head := SphereMesh.new()
	head.radius = 0.03
	head.height = 0.06
	main._mesh(head, brass, Vector3(0, 0.11, 0), pawn)


## A dashed ink trail from a to b, stopping short of both tokens.
func _ink_line(a: Vector3, b: Vector3, mat: Material) -> void:
	var d := b - a
	var length := d.length()
	var dir := d / length
	var s := 0.11
	while s < length - 0.11:
		var seg: MeshInstance3D = main._mesh(main._box(Vector3(0.018, 0.002, 0.045)), mat, a + dir * (s + 0.022) + Vector3(0, -0.006, 0), parchment)
		seg.rotation.y = atan2(dir.x, dir.z)
		s += 0.075


## A stop: red wax seal for a battle, a small face-up card for a card choice, the Dealer's dark seal with lit eyes for the boss.
func _token(n: Dictionary) -> void:
	var body := StaticBody3D.new()
	body.position = _stop_pos(n)
	parchment.add_child(body)
	var mesh: MeshInstance3D
	match run.shown_type(n["id"]):
		"battle":
			var seal := CylinderMesh.new()
			seal.top_radius = 0.07
			seal.bottom_radius = 0.08
			seal.height = 0.035
			mesh = main._mesh(seal, main._mat(Color("8a2418"), 0.4), Vector3(0, 0.017, 0), body)
			var cross: StandardMaterial3D = main._mat(Color("3a0c08"))
			for a in [45, -45]:
				var bar: MeshInstance3D = main._mesh(main._box(Vector3(0.012, 0.004, 0.09)), cross, Vector3(0, 0.036, 0), body)
				bar.rotation_degrees.y = a
		"choice":
			mesh = main._mesh(main._box(Vector3(0.12, 0.02, 0.17)), main._mat(Color("efe2c2")), Vector3(0, 0.01, 0), body)
			if not ResourceLoader.exists("res://art/map/node-choice.png"):
				main._mesh(main._box(Vector3(0.08, 0.004, 0.07)), main._mat(Color("3a6a4a")), Vector3(0, 0.022, -0.02), body)
		"event":
			# a folded note with a question mark inked on it
			mesh = main._mesh(main._box(Vector3(0.13, 0.016, 0.13)), main._mat(Color("d8c49a")), Vector3(0, 0.008, 0), body)
			mesh.rotation_degrees.y = 12
			if not ResourceLoader.exists("res://art/map/node-event.png"):   # box-drawn "?" until the ink mark exists
				var ink: StandardMaterial3D = main._mat(Color("2a1810"))
				for seg in [[Vector3(0, 0.018, -0.03), Vector3(0.05, 0.004, 0.012)], [Vector3(0.022, 0.018, -0.012), Vector3(0.012, 0.004, 0.03)],
						[Vector3(0.006, 0.018, 0.008), Vector3(0.012, 0.004, 0.02)], [Vector3(0.0, 0.018, 0.04), Vector3(0.014, 0.004, 0.014)]]:
					main._mesh(main._box(seg[1]), ink, seg[0], body)
		"boss":
			var seal := CylinderMesh.new()
			seal.top_radius = 0.1
			seal.bottom_radius = 0.11
			seal.height = 0.05
			mesh = main._mesh(seal, main._mat(Color("1a120c"), 0.5), Vector3(0, 0.025, 0), body)
			for x in [-0.035, 0.035]:
				var eye := SphereMesh.new()
				eye.radius = 0.016
				eye.height = 0.02
				main._mesh(eye, main._glow(Color("ffe8a3"), 6.0), Vector3(x, 0.052, 0.02), body)
		"hidden":
			# a face-down card: the Dealer will not say what waits here
			mesh = main._mesh(main._box(Vector3(0.12, 0.02, 0.17)), main._mat(Color("4a2a1c")), Vector3(0, 0.01, 0), body)
			if not ResourceLoader.exists("res://art/map/node-hidden.png"):
				for z in [-0.04, 0.0, 0.04]:
					main._mesh(main._box(Vector3(0.08, 0.004, 0.01)), main._mat(Color("c9a045")), Vector3(0, 0.022, z), body)
	# a woodcut ink mark on top of the token, as in art/map/node-<type>.png (pale ink on the dark seals)
	var mark := "res://art/map/node-%s.png" % run.shown_type(n["id"])
	if ResourceLoader.exists(mark):
		var top := {"battle": 0.04, "boss": 0.055, "choice": 0.024, "event": 0.02, "hidden": 0.024}
		var spr: Sprite3D = main._sprite(body, load(mark), 0.1 if run.shown_type(n["id"]) == "boss" else 0.08,
			Vector3(0, top.get(run.shown_type(n["id"]), 0.03), 0))
		# white ink masks: pale on the dark seals and the hidden card, walnut ink on paper
		spr.modulate = Color("f0dcae") if run.shown_type(n["id"]) in ["battle", "boss", "hidden"] else Color("2a1810")
	if run.shown_type(n["id"]) == "boss" and ResourceLoader.exists("res://art/cards/boss.png"):
		# the Dealer's own card stands at the end of the road
		var card: StaticBody3D = main._card("boss", "The Dealer", -1, -1, Vector3(0, 0.17, -0.1), Vector3(60, 0, 0))
		card.reparent(body, false)
		card.scale = Vector3.ONE * 0.45
	if run.sealed.has(n["id"]):
		# the Dealer's black wax over the stop, crossed in dull red
		var wax := CylinderMesh.new()
		wax.top_radius = 0.09
		wax.bottom_radius = 0.1
		wax.height = 0.02
		main._mesh(wax, main._mat(Color("140a08"), 0.3), Vector3(0, 0.05, 0), body)
		for a in [45, -45]:
			var bar: MeshInstance3D = main._mesh(main._box(Vector3(0.015, 0.006, 0.13)), main._glow(Color("a8321e"), 1.5),
				Vector3(0, 0.062, 0), body)
			bar.rotation_degrees.y = a
	if run.bargains.has(n["id"]) and run.shown_type(n["id"]) == "choice":
		# a brass coin on the card: a bargain waits here
		var coin := CylinderMesh.new()
		coin.top_radius = 0.035
		coin.bottom_radius = 0.035
		coin.height = 0.012
		var brass: StandardMaterial3D = main._mat(Color("c9a045"), 0.3)
		brass.metallic = 0.85
		main._mesh(coin, brass, Vector3(0.06, 0.03, 0.07), body)
	var col := CollisionShape3D.new()
	var sh := SphereShape3D.new()
	sh.radius = 0.12
	col.shape = sh
	body.add_child(col)
	var id: int = n["id"]
	body.input_event.connect(func(_c, ev, _p, _n, _i):
		if ev is InputEventMouseButton and ev.pressed and ev.button_index == MOUSE_BUTTON_LEFT and not main.head_open:
			_on_stop(id))
	body.mouse_entered.connect(func():
		if run.phase == "map":
			var shown := run.shown_type(id)
			var why := " (sealed by the Dealer)" if run.sealed.has(id) else ("" if run.reachable().has(id) else " (not reachable from here)")
			var deal := " A bargain waits." if run.bargains.has(id) and shown == "choice" else ""
			main.ui.hint(TYPE_TEXT[shown] + deal + why))
	body.scale = Vector3.ONE * 1.5
	tokens[id] = {"body": body, "mesh": mesh, "base": body.position, "shown": run.shown_type(id)}


func _on_stop(id: int) -> void:
	# a click before the Dealer has decided: it acts now on its seeded pick, and may seal the very stop you chose
	if not steer_pending.is_empty() and run.phase == "map":
		_resolve_steer({"text": null, "ms": 0, "error": "player moved first"})
		if not run.reachable().has(id):
			main.ui.hint("The Dealer's wax lands on that stop first.")
			return
	if not run.go(id):
		return
	Sfx.play("card")
	_refresh_tokens()
	await get_tree().create_timer(0.5).timeout
	_enter_phase()


## Rebuilds a stop's token after the Dealer changed it (sealed, swapped, hidden, or revealed by standing on it).
func _rebuild_token(id: int) -> void:
	if tokens.has(id):
		tokens[id]["body"].free()
		tokens.erase(id)
	_token(run.nodes[id])


## Visited stops fade, the ones ahead light up, the pawn stands where you are.
func _refresh_tokens() -> void:
	# a hidden stop shows its face once you stand on it
	if run.at >= 0 and tokens.has(run.at) and tokens[run.at]["shown"] != run.shown_type(run.at):
		_rebuild_token(run.at)
	for id in tokens:
		var mesh: MeshInstance3D = tokens[id]["mesh"]
		var m: StandardMaterial3D = mesh.material_override
		var past: bool = run.visited.has(id) and id != run.at
		m.emission_enabled = run.reachable().has(id)
		m.emission = Color("ffb060")
		m.emission_energy_multiplier = 0.5
		mesh.transparency = 0.55 if past else 0.0
	if run.at >= 0:
		pawn.position = _stop_pos(run.nodes[run.at]) + Vector3(0.1, 0, 0.06)
	else:
		pawn.position = Vector3(0, 0.0, MAP_SIZE.y / 2 - 0.12)


func _show_map(on: bool) -> void:
	if parchment == null:
		return
	parchment.visible = on and run.phase == "map"
	parchment.process_mode = Node.PROCESS_MODE_INHERIT if on else Node.PROCESS_MODE_DISABLED
	main.cam.transform = main.cam_home
	main.look_yaw = 0
	main.look_pitch = 0
	if parchment.visible:
		main.cam.look_at_from_position(Vector3(0, 6.9, 4.4), MAP_CENTER)
	main.look_home = main.cam.transform


# ---------- card choice ----------
func _deal_choice() -> void:
	main.ui.hint("Take one card into your deck (%d cards now)." % run.deck.size())
	if choice_root:
		choice_root.queue_free()
	choice_root = Node3D.new()
	add_child(choice_root)
	for i in run.choice.size():
		var cr: Dictionary = main.game.creature(run.choice[i])
		var card: StaticBody3D = main._card(cr["art"], cr["name"], cr["atk"], cr["hp"], Vector3((i - 1) * 0.68, 0.3, 0.55),
			Vector3(55, 0, 0), true, main._cost_text(cr), main.game.sigil_text(cr))
		card.reparent(choice_root)
		card.scale = Vector3.ONE * 1.25
		var idx := i
		card.input_event.connect(func(_c, ev, _p, _n, _i):
			if ev is InputEventMouseButton and ev.pressed and ev.button_index == MOUSE_BUTTON_LEFT and not main.head_open:
				_on_pick(idx, card))
	_deal_bargain()


## The Dealer's bargain behind the three cards: its strong card for your best one.
func _deal_bargain() -> void:
	if bargain_root:
		bargain_root.queue_free()
		bargain_root = null
	if run.bargain.is_empty():
		return
	bargain_root = Node3D.new()
	add_child(bargain_root)
	var cr: Dictionary = main.game.creature(run.bargain["card"])
	var card: StaticBody3D = main._card(cr["art"], cr["name"], cr["atk"], cr["hp"], Vector3(1.3, 0.3, 0.6),
		Vector3(55, 0, 0), true, main._cost_text(cr), main.game.sigil_text(cr))
	card.reparent(bargain_root)
	main.ui.hint("Take a card, or the Dealer's bargain (right): its %s for your %s." % [run.bargain["card"], run.bargain["price"]])
	card.input_event.connect(func(_c, ev, _p, _n, _i):
		if ev is InputEventMouseButton and ev.pressed and ev.button_index == MOUSE_BUTTON_LEFT and not main.head_open:
			_on_bargain())


func _on_bargain() -> void:
	var b := run.bargain.duplicate()
	if not run.take_bargain():
		return
	Sfx.play("card")
	main.run_log.choice(["bargain: %s for your %s" % [b["card"], b["price"]]], b["card"])
	bargain_root.queue_free()
	bargain_root = null
	if choice_root:
		choice_root.queue_free()
		choice_root = null
	_enter_phase()
	_dealer_steers("bargain")


func _on_pick(i: int, card: Node3D) -> void:
	var options := run.choice.duplicate()
	if not run.pick(i):
		return
	_log("stop", {"index": run.at, "kind": "choice", "candles": run.candles})
	if main.run_log != null:
		main.run_log.choice(options, options[i])
	Sfx.play("card")
	# the chosen card slides into your deck; the others go back to the Dealer
	for c in choice_root.get_children():
		var tw := create_tween().set_trans(Tween.TRANS_SINE)
		tw.tween_property(c, "position", Vector3(0, 0.1, 1.9) if c == card else c.position + Vector3(0, 0, -2.2), 0.45)
	if bargain_root:
		bargain_root.queue_free()
		bargain_root = null
	await get_tree().create_timer(0.5).timeout
	choice_root.queue_free()
	choice_root = null
	_enter_phase()
	_dealer_steers("took")


# ---------- candles ----------
## Shows the run's lives without animation (on load and new run); candles go out from the last one, as
## fx.gutter_candle() does when a hand is lost.
func _show_candles() -> void:
	var out := Run.CANDLES - run.candles
	for i in lights.size():
		var light: OmniLight3D = lights[i]
		var lit := i < lights.size() - out
		light.visible = lit
		light.light_color = CANDLE_COLOR
		main.candle_flames[i].scale = Vector3.ONE if lit else Vector3.ZERO


## Writes to main's run log (scripts/run_log.gd), if there is one.
func _log(type: String, d: Dictionary) -> void:
	if main.run_log != null:
		main.run_log.write(type, d)


# ---------- summary ----------
## The run's last page; the ending text fills in when the brain answers (the Dealer's last line until then).
func _summary_text() -> String:
	var cut: String = ", ".join(run.wires_cut) if run.wires_cut else "none"
	var taken := run.history.filter(func(h): return h.has("card")).map(func(h): return h["card"])
	return "\n".join([
		"YOU BEAT THE DEALER" if run.won else "THE LAST CANDLE IS OUT",
		"Stops cleared: %d of %d   Hands lost: %d   Candles left: %d" % [run.cleared(), run.rows(),
			run.history.filter(func(h): return h["result"] == "lost").size(), run.candles],
		"Wires cut: %s" % cut,
		"Cards taken: %s" % (", ".join(taken) if taken else "none"),
		"Times the Dealer bent the map: %d" % run.steers.filter(func(x): return x["kind"] != "none").size()
			if Sandbox.enabled("dealer_steers_run") else "",
		"",
		run.ending if run.ending != "" else "The Dealer: \"%s\"" % run.quote,
	])


func _summary() -> void:
	main.ui.hint("")
	_show_panel(_summary_text(), "New run", new_run, true)


## Start over on a fresh map: candles relit, the starter deck, a new premise.
func new_run() -> void:
	run.start()
	lesson.new_run()
	run.note_wires(wire_states)
	run.save()
	steer_pending = {}
	_ask_premise()
	_log("run_start", {"seed": run.run_seed, "stops": run.nodes.size()})
	for c in parchment.get_children():
		c.queue_free()
	parchment.queue_free()
	tokens = {}
	_build_map()
	_show_candles()
	_enter_phase()


## The settings menu's "Abandon run": log it as a loss and deal a new run.
func abandon_run() -> void:
	_log("run_abandoned", {"at": run.at, "cleared": run.cleared(), "candles": run.candles})
	new_run()


# ---------- story ----------
## The Dealer speaks in its speech box (the same one it uses in battle).
func _speak(text: String) -> void:
	if text != "":
		main.ui._show(text)


func _log_story(kind: String, p: Dictionary, raw, ms: int, extra := {}) -> void:
	main.run_log.story(kind, {"text": p["text"], "source": p["source"], "reason": p["reason"],
		"raw": raw if raw is String else "", "ms": ms, "wires_cut": run.wires_cut, "at": run.at}.merged(extra))


func _ask_premise() -> void:
	var seed_ := run.run_seed
	story.ask(Story.premise_prompt(), "premise", 90, func(r):
		if run.run_seed != seed_:
			return   # a new run started meanwhile
		var p := Story.pick_text(run, "premise", r["text"])
		run.premise = p["text"]
		run.save()
		_log_story("premise", p, r["text"], r["ms"], {"error": r.get("error", "")})
		if run.phase == "map":
			_speak(run.premise))


## A short line between stops, reacting to a won or lost hand or a cut wire. Shown only if nothing has moved on.
func _say_line(event: String) -> void:
	var where := [run.at, run.phase, run.history.size()]
	story.ask(Story.line_prompt(run, event), "line", 40, func(r):
		var p := Story.pick_text(run, "line", r["text"], event)
		run.lines.append({"at": run.at, "kind": event, "text": p["text"], "source": p["source"]})
		run.save()
		_log_story("line", p, r["text"], r["ms"], {"event": event, "error": r.get("error", "")})
		if where == [run.at, run.phase, run.history.size()] or event == "cut":
			_speak(p["text"]))


## Between stops the Dealer bends the map: the model picks from a short menu of legal actions, the game applies it.
## Sandbox only (Sandbox "dealer_steers_run"); with it off the map is never touched.
func _dealer_steers(event: String) -> void:
	if run.phase != "map" or not Sandbox.enabled("dealer_steers_run"):
		return
	var options := run.steer_options()
	if options.size() < 2:
		return   # nothing to bend but "leave it"
	var menu := Story.menu(run, options)
	var id := Time.get_ticks_usec()
	steer_pending = {"id": id, "at": run.at, "menu": menu, "event": event, "texts": menu.map(func(o): return run.steer_text(o))}
	if run.phase == "map":
		main.ui.hint("The Dealer leans over the map...")
	story.ask(Story.steer_prompt(run, menu, event), "steer", 60, func(r):
		if steer_pending.get("id", 0) == id:
			_resolve_steer(r))


## Applies the Dealer's pick (or the seeded fallback when the answer is missing or has no usable number) and says why.
func _resolve_steer(r: Dictionary) -> void:
	var s := steer_pending
	steer_pending = {}
	if s.is_empty() or run.phase != "map" or run.at != s["at"]:
		return
	var menu: Array = s["menu"]
	var k := Story.parse_choice(r["text"], menu.size())
	var source := "model"
	if k < 0:
		k = Story.fallback_pick(run, menu)
		source = "fallback"
	var a: Dictionary = menu[k]
	var p := Story.pick_text(run, "steer", Story.parse_say(r["text"]) if r["text"] is String else null,
		"none" if a["kind"] == "none" else "steer")
	var applied := run.apply_steer(a, source, p["text"])
	main.run_log.steer({"event": s["event"], "menu": s["texts"], "pick": k,
		"action": a, "applied": applied, "source": source, "say": p["text"], "say_source": p["source"],
		"raw": r["text"] if r["text"] is String else "", "ms": r.get("ms", 0), "error": r.get("error", ""),
		"wires_cut": run.wires_cut, "at": run.at})
	if a["kind"] != "none" and a["node"] >= 0:
		_rebuild_token(a["node"])
		_refresh_tokens()
	_speak(p["text"])
	main.ui.hint("%s %s" % [{"seal": "The Dealer seals a stop with wax.", "swap": "The Dealer changes a stop.",
		"hide": "The Dealer turns a stop face down.", "bargain": "The Dealer sets a coin on a card choice.",
		"none": "The Dealer leaves the road alone."}[a["kind"]], "Choose your next stop."])


func _ask_ending() -> void:
	var seed_ := run.run_seed
	story.ask(Story.ending_prompt(run), "ending", 110, func(r):
		if run.run_seed != seed_:
			return
		var p := Story.pick_text(run, "ending", r["text"], "ending_won" if run.won else "ending_lost")
		run.ending = p["text"]
		run.save()
		_log_story("ending", p, r["text"], r["ms"], {"won": run.won, "error": r.get("error", "")})
		if run.phase == "over" and panel.visible:
			panel_text.text = _summary_text())


# ---------- 2D ----------
func _ui() -> void:
	var layer := CanvasLayer.new()
	layer.layer = 3
	layer.scale = Vector2.ONE * main.ui.UI_SCALE()   # the UI's design grid (see brain_ui.UI_SCALE)
	add_child(layer)
	var root := Control.new()
	root.size = main.ui.ui_size(get_viewport())
	root.mouse_filter = Control.MOUSE_FILTER_IGNORE
	root.theme = UITheme.walnut()
	layer.add_child(root)
	hint = main.ui.hint_label   # the shared "what to do next" line above the chat bar
	panel = PanelContainer.new()
	panel.add_theme_stylebox_override("panel", UITheme.walnut_panel(0.92, 8))
	panel.visible = false
	root.add_child(panel)
	var box := VBoxContainer.new()
	panel.add_child(box)
	panel_text = Label.new()
	panel_text.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	panel_text.add_theme_color_override("font_color", UITheme.INK)
	box.add_child(panel_text)
	panel_button = Button.new()
	panel_button.focus_mode = Control.FOCUS_NONE
	panel_button.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	box.add_child(panel_button)
	_event_ui(root)


func _show_panel(text: String, button: String, on_press: Callable, big := false) -> void:
	panel_text.text = text
	panel_button.text = button
	for c in panel_button.pressed.get_connections():
		panel_button.pressed.disconnect(c["callable"])
	panel_button.pressed.connect(func():
		_hide_panel()
		on_press.call(), CONNECT_ONE_SHOT)
	panel_text.custom_minimum_size = Vector2(260 if big else 160, 0)
	panel.visible = true
	panel.reset_size()
	await get_tree().process_frame
	panel.reset_size()   # an autowrapped label only knows its height once its width is set; shrink to fit again
	var vp: Vector2 = main.ui.ui_size(get_viewport())
	panel.position = Vector2((vp.x - panel.size.x) / 2, vp.y * (0.02 if big else 0.28))


func _hide_panel() -> void:
	panel.visible = false


# ---------- screenshot previews ----------
## Walks a seeded run to a given point without playing the battles, for screenshots.
func _walk_to(view: String) -> void:
	if view == "map":
		run.go(0)
		run.battle_over(true)
		run.battle = {}
		return
	if view == "steered":
		# the Dealer has had its way with the map: one of each mark it can make, and its premise in the speech box
		run.go(0)
		run.battle_over(true)
		run.premise = Story.FALLBACK["premise"][0]
		for kind in ["seal", "hide", "swap", "bargain"]:
			var o: Array = run.steer_options().filter(func(x): return x["kind"] == kind)
			if not o.is_empty():
				run.apply_steer(o[0], "preview", Story.FALLBACK["steer"][0])
		_speak.call_deferred(run.premise)
		return
	if view == "bargain":
		# walk to the first card choice with the Dealer's bargain on it
		while run.phase != "choice":
			if run.phase == "battle":
				run.battle_over(true)
				continue
			if run.phase == "event":
				run.bot_event()
				continue
			var nxt: Array = run.reachable()
			var pick = nxt[0]
			for id in nxt:
				if run.nodes[id]["type"] == "choice":
					pick = id
			if run.nodes[pick]["type"] == "choice":
				run.bargains.append(pick)
			run.go(pick)
		return
	while run.phase != "over":
		if run.phase == "map":
			var nxt: Array = run.reachable()
			# head for the stop kind the view wants, so the walk reaches one quickly
			var want := "event" if view in ["event", "pick"] else "choice"
			var pick = nxt[0]
			for id in nxt:
				if run.nodes[id]["type"] == want:
					pick = id
			run.go(pick)
			if run.phase == "event" and preview_event != "":
				run.event["id"] = preview_event
		if view == "event" and run.phase == "event":
			return
		if view == "pick" and run.phase == "event":
			var opts := run.event_options()
			for i in opts.size():
				var o: Dictionary = Run.EVENTS[run.event["id"]]["options"][i]
				if opts[i]["block"] == "" and o["effects"].any(func(f): return f.has("pick")):
					run.choose(i)
					return
			run.bot_event()
			continue
		if view == "choice" and run.phase == "choice":
			return
		if view == "battle" and run.phase == "battle" and run.at > 0:
			return
		if run.phase == "choice":
			run.pick(0)
		elif run.phase == "event":
			run.bot_event()
		elif run.phase == "battle":
			var lose := view == "lost" and run.is_boss()
			if view == "won" and run.history.size() == 1:
				run.battle_over(false)   # one candle lost on the way, so the summary shows it
				continue
			run.battle_over(not lose)
	run.wires_cut = ["red", "yellow"]
	run.quote = FALLBACK_QUOTES[0]
	run.ending = Story.FALLBACK["ending_won" if run.won else "ending_lost"][0]
	run.steers = [{"at": 0, "kind": "seal", "node": 1, "source": "preview", "say": ""}]


# ---------- events ----------
## A "?" stop: the Dealer slides a folded note across the table; it opens as a parchment page with the scene and its
## choices. A choice that needs a card (remove, transform, duplicate) spreads your deck on the table to click one.
const PICK_TEXT := {"remove": "Choose a card to remove from your deck.", "transform": "Choose a card to transform.",
	"duplicate": "Choose a card to duplicate."}

var note: Node3D
var note_panel: PanelContainer
var note_title: Label
var note_art: TextureRect
var note_text: Label
var note_buttons: VBoxContainer
var deck_root: Node3D
var event_candles := 0        # candles before the choice, to animate a change


func _show_event() -> void:
	if run.pending_pick() != "":
		_show_pick()
		return
	var e: Dictionary = Run.EVENTS[run.event["id"]]
	main.ui.hint("")
	_slide_note()
	note_title.text = e["title"]
	note_text.text = e["text"]
	var art := "res://art/events/%s.png" % run.event["id"]
	note_art.texture = load(art) if ResourceLoader.exists(art) else null
	note_art.visible = note_art.texture != null
	for c in note_buttons.get_children():
		c.queue_free()
	var opts := run.event_options()
	for i in opts.size():
		var o: Dictionary = opts[i]
		var b := Button.new()
		b.focus_mode = Control.FOCUS_NONE
		b.alignment = HORIZONTAL_ALIGNMENT_LEFT
		b.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		b.custom_minimum_size = Vector2(226, 0)
		b.text = "[%s] %s" % [o["label"], o["effect_text"]]
		if o["block"] != "":
			b.text = "[%s] (%s)" % [o["label"], o["block"]]
			b.disabled = true
		var idx := i
		b.pressed.connect(func(): _on_event_option(idx))
		note_buttons.add_child(b)
	# the page opens once the note has slid over to you
	await get_tree().create_timer(0.6).timeout
	if run.phase != "event" or run.event.has("option"):
		return
	note_panel.visible = true
	note_panel.reset_size()
	await get_tree().process_frame   # autowrapped text: size again once its width is known
	note_panel.reset_size()
	note_panel.position = Vector2((main.ui.ui_size(get_viewport()).x - note_panel.size.x) / 2, 8)


## The note: a folded paper that slides from the Dealer's side of the table to yours.
func _slide_note() -> void:
	if note == null:
		note = Node3D.new()
		add_child(note)
		main._mesh(main._box(Vector3(0.36, 0.006, 0.26)), main._mat(Color("d8c49a")), Vector3.ZERO, note)
		main._mesh(main._box(Vector3(0.36, 0.002, 0.004)), main._mat(Color("8a6a40")), Vector3(0, 0.004, 0), note)
	note.visible = true
	note.position = Vector3(0, 0.05, -1.5)
	note.rotation_degrees = Vector3(0, 25, 0)
	var tw := create_tween().set_parallel().set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_OUT)
	tw.tween_property(note, "position", Vector3(0.0, 0.62, 0.55), 0.5)
	tw.tween_property(note, "rotation_degrees", Vector3(48, -4, 0), 0.5)
	Sfx.play("card")


func _on_event_option(i: int) -> void:
	event_candles = run.candles
	var label: String = Run.EVENTS[run.event["id"]]["options"][i]["label"]
	if not run.choose(i):
		return
	note_panel.visible = false
	Sfx.play("card")
	_log("event", {"index": run.at, "event": run.event["id"], "option": label, "candles": run.candles})
	if run.pending_pick() != "":
		_show_pick()
	else:
		_event_result()


## Your deck laid out face up in rows; click one for the pending remove / transform / duplicate.
func _show_pick() -> void:
	note_panel.visible = false
	if note:
		note.visible = false
	_show_map(false)
	main.ui.hint(PICK_TEXT[run.pending_pick()])
	if deck_root:
		deck_root.queue_free()
	deck_root = Node3D.new()
	add_child(deck_root)
	var per_row := 7
	var rows := ceili(run.deck.size() / float(per_row))
	for i in run.deck.size():
		var row := i / per_row
		var in_row := mini(per_row, run.deck.size() - row * per_row)
		var cr: Dictionary = main.game.creature(run.deck[i])
		var pos := Vector3((i % per_row - (in_row - 1) / 2.0) * 0.34, 0.12 + 0.03 * row, 0.05 + (row - (rows - 1) / 2.0) * 0.4)
		var card: StaticBody3D = main._card(cr["art"], cr["name"], cr["atk"], cr["hp"], pos, Vector3(40, 0, 0), true,
			main._cost_text(cr), main.game.sigil_text(cr))
		card.reparent(deck_root)
		card.scale = Vector3.ONE * 0.64
		var idx := i
		card.input_event.connect(func(_c, ev, _p, _n, _i):
			if ev is InputEventMouseButton and ev.pressed and ev.button_index == MOUSE_BUTTON_LEFT and not main.head_open:
				_on_pick_card(idx))


func _on_pick_card(i: int) -> void:
	var op := run.pending_pick()
	var name: String = run.deck[i]
	if not run.pick_card(i):
		return
	Sfx.play("death" if op == "remove" else "card")
	_log("event_pick", {"index": run.at, "event": run.event["id"], "op": op, "card": name})
	deck_root.queue_free()
	deck_root = null
	if run.pending_pick() != "":
		_show_pick()
	else:
		_show_map(true)
		_event_result()


## What happened, then back to the map. Candles and wires change on the table as you read it.
func _event_result() -> void:
	if note:
		note.visible = false
	var ev: Dictionary = run.event
	if run.candles < event_candles:
		main.fx.candles_out = Run.CANDLES - event_candles
		main.fx.gutter_candle()
	elif run.candles > event_candles:
		_show_candles()
	if ev.has("cut_wire"):
		main.ui.cut(ev["cut_wire"])
	var lines := [ev.get("result", "")]
	if not ev.get("gained", []).is_empty():
		lines.append("Gained: " + ", ".join(ev["gained"]))
	if not ev.get("lost", []).is_empty():
		lines.append("Lost: " + ", ".join(ev["lost"]))
	if ev.has("cut_wire"):
		lines.append("The %s wire is cut." % ev["cut_wire"])
	if run.has_curse():
		var c := []
		if run.marks.get("tilt", 0):
			c.append("each hand starts with the scale tipped %d against you" % run.marks["tilt"])
		if run.marks.get("dealer_draw", 0):
			c.append("the Dealer opens with %d card%s more" % [run.marks["dealer_draw"], "s" if run.marks["dealer_draw"] > 1 else ""])
		lines.append(Run.rules_text("Cursed: " + "; ".join(c) + "."))
	if run.marks.get("bones", 0):
		lines.append(Run.rules_text("Open each hand with %d more bones." % run.marks["bones"]))
	_log("event_end", {"index": run.at, "event": ev["id"], "gained": ev.get("gained", []), "lost": ev.get("lost", []),
		"marks": run.marks, "candles": run.candles, "deck": run.deck})
	_show_panel("\n".join(lines), "Back to the map", func(): _enter_phase())


## The parchment page for events, on run_table's 2D layer.
func _event_ui(root: Control) -> void:
	note_panel = PanelContainer.new()
	note_panel.add_theme_stylebox_override("panel", UITheme.paper_panel(6))
	note_panel.theme = UITheme.paper()
	note_panel.visible = false
	root.add_child(note_panel)
	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 3)
	note_panel.add_child(box)
	var ink := UITheme.PAPER_INK
	note_art = TextureRect.new()   # woodcut vignette for the event, art/events/<id>.png
	note_art.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	note_art.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	note_art.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
	note_art.custom_minimum_size = Vector2(226, 60)
	note_art.modulate = Color("3a2416")
	box.add_child(note_art)
	note_title = Label.new()
	note_title.add_theme_color_override("font_color", UITheme.PAPER_RED)
	note_title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	box.add_child(note_title)
	note_text = Label.new()
	note_text.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	note_text.custom_minimum_size = Vector2(226, 0)
	note_text.add_theme_color_override("font_color", ink)
	box.add_child(note_text)
	note_buttons = VBoxContainer.new()
	note_buttons.add_theme_constant_override("separation", 2)
	box.add_child(note_buttons)
	# choices look like inked lines on the page; hover darkens the paper behind them (UITheme.paper)
