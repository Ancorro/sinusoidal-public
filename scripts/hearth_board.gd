extends Node
## The free combat board. Click a hand card to play it, or choose its target; click an awake minion, then its target.
## The scene owns the card meshes and brain controls. This node owns selection and the combat readout.

const UI := preload("res://scripts/brain_ui.gd")
const UITheme := preload("res://scripts/ui_theme.gd")
const INK := Color("f3e6c8")
const GOLD := Color("e4b969")
const GREEN := Color("8fc89a")
var main
var chosen := {}   # {kind: play|attack, card|attacker}; resolved against fresh legal actions on each click
var hud: CanvasLayer
var root: Control
var detail: Label
var end_button: Button
var heroes := {}
var counters := {}
var tokens: Array = []
var bell: StaticBody3D   # the hourglass; keeps the old name for main._end_player_turn
var glass: Node3D
var turn_light: MeshInstance3D
var card_nodes := {}


func _init(m) -> void:
	main = m


func _ready() -> void:
	hud = CanvasLayer.new()
	hud.layer = 1
	hud.scale = Vector2.ONE * UI.UI_SCALE()
	add_child(hud)
	root = Control.new()
	root.size = UI.ui_size(get_viewport())
	root.mouse_filter = Control.MOUSE_FILTER_IGNORE
	root.theme = UITheme.walnut()
	hud.add_child(root)
	# Hero targets are invisible buttons laid over the 3D health counters (the tests click them; so can the mouse).
	# Everything the player sees is on the board: brass counters for health, mana tokens, the hand bell.
	for side in ["dealer", "player"]:
		var hero := Button.new()
		hero.flat = true
		hero.size = Vector2(60, 30)
		hero.modulate = Color(1, 1, 1, 0)
		hero.pressed.connect(target.bind("hero:" + side))
		root.add_child(hero)
		heroes[side] = hero
	# the Dealer's health: a brass counter on its chest; yours: an iron plate beside your candles
	counters["dealer"] = _counter(Vector3.ZERO, true)
	counters["player"] = _counter(Vector3(-1.5, 0.0, -0.65), false)
	# mana: brass tokens along your edge of the board, lit while unspent
	for i in 10:
		var token := CylinderMesh.new()
		token.top_radius = 0.045
		token.bottom_radius = 0.045
		token.height = 0.014
		token.radial_segments = 12
		var m: MeshInstance3D = main._mesh(token, _brass(), Vector3(-1.78 + (i % 5) * 0.13, 0.012, -1.15 + (i / 5) * 0.14), main)
		tokens.append(m)
	# the hourglass: turn it over to end your turn (it flips when you do)
	bell = StaticBody3D.new()
	bell.position = Vector3(1.45, 0, -0.6)
	main.add_child(bell)
	glass = main._prop("hourglass", Vector3.ZERO, 15.0, 0.9, bell)
	var bcol := CollisionShape3D.new()
	var bsh := CylinderShape3D.new()
	bsh.radius = 0.16
	bsh.height = 0.5
	bcol.shape = bsh
	bcol.position.y = 0.25
	bell.add_child(bcol)
	bell.input_event.connect(func(_c, ev, _p, _n, _i):
		if main._clicked(ev): main._end_player_turn())
	bell.mouse_entered.connect(func(): main.ui.hint("Turn the hourglass to end your turn.", true))
	bell.mouse_exited.connect(func(): redraw_hint())
	# the turn marker: a small flame above the glass while it is your turn
	var flame := SphereMesh.new()
	flame.radius = 0.02
	flame.height = 0.07
	turn_light = main._mesh(flame, main._glow(Color("ffb347"), 6.0), Vector3(1.45, 0.62, -0.6), main)
	detail = Label.new()
	detail.set_anchors_preset(Control.PRESET_TOP_WIDE)
	detail.offset_left = 120
	detail.offset_right = -120
	detail.offset_top = 36
	detail.offset_bottom = 60
	detail.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	detail.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	detail.add_theme_color_override("font_color", UITheme.INK)
	root.add_child(detail)
	# "End turn" keeps its name for the scene tests; it is the bell's invisible HUD twin
	end_button = Button.new()
	end_button.text = "End turn"
	end_button.flat = true
	end_button.size = Vector2(40, 30)
	end_button.modulate = Color(1, 1, 1, 0)
	end_button.pressed.connect(main._end_player_turn)
	root.add_child(end_button)


func _brass() -> StandardMaterial3D:
	var m: StandardMaterial3D = main._mat(Color("b08a3a"), 0.35)
	m.metallic = 0.8
	return m


## A brass counter: a ring around a dark plate with the number on it. The chest one is reparented to the
## creature by attach().
func _counter(at: Vector3, on_chest: bool) -> Dictionary:
	var node := Node3D.new()
	node.position = at
	main.add_child(node)
	var ring := TorusMesh.new()
	ring.inner_radius = 0.09 if on_chest else 0.11
	ring.outer_radius = 0.12 if on_chest else 0.15
	var r: MeshInstance3D = main._mesh(ring, _brass(), Vector3.ZERO, node)
	var plate := CylinderMesh.new()
	plate.top_radius = ring.inner_radius + 0.005
	plate.bottom_radius = plate.top_radius
	plate.height = 0.01
	main._mesh(plate, main._mat(Color("17110c"), 0.6), Vector3.ZERO, node)
	var l := Label3D.new()
	l.font = UITheme.FONT
	l.font_size = 64
	l.pixel_size = 0.0022
	l.modulate = UITheme.INK
	l.outline_size = 0
	l.position = Vector3(0, 0.012, 0)
	l.rotation_degrees.x = -90
	node.add_child(l)
	return {"node": node, "label": l, "ring": r, "chest": on_chest}


## The hourglass turns over when a turn ends.
func flip_glass() -> void:
	if glass == null:
		return
	var tw := glass.create_tween()
	tw.tween_property(glass, "rotation_degrees:z", glass.rotation_degrees.z + 180.0, 0.5).set_trans(Tween.TRANS_SINE)


## The Dealer's counter hangs on the creature's chest. set_creature frees the figure, counter included, so a
## fresh one is built whenever the old node is gone.
func attach() -> void:
	var c: Dictionary = counters["dealer"]
	if not is_instance_valid(c["node"]):
		c = _counter(Vector3.ZERO, true)
		counters["dealer"] = c
	var node: Node3D = c["node"]
	if node.get_parent() != main.figure:
		node.reparent(main.figure, false)
	node.position = main.chest_at + Vector3(0, 0, 0.06)
	node.rotation_degrees = Vector3(90, 0, 0)
	node.scale = Vector3.ONE / main.figure.scale.x


func redraw_hint() -> void:
	var g = main.game
	if g.winner != "":
		main.ui.hint("The hand is yours." if g.winner == "player" else "The Dealer takes the hand.", true)
	elif g.turn == "player":
		main.ui.hint("Your turn. Play a card, or pick a minion and then its target. Turn the hourglass when done.", true)
	else:
		main.ui.hint("The Dealer plays.", true)


func _process(_dt: float) -> void:
	root.visible = not main.board_locked and not main.head_open and absf(main.look_yaw) < 10 and absf(main.look_pitch) < 10
	end_button.disabled = not active()
	for side in heroes:
		heroes[side].disabled = not active() or actions().all(func(a): return str(a["target"]) != "hero:" + side)
	# board props follow the cards (the map hides them)
	var shown: bool = main.cards_root.visible
	bell.visible = shown
	turn_light.visible = shown and main.game.turn == "player" and main.game.winner == ""
	counters["player"]["node"].visible = shown
	if not is_instance_valid(counters["dealer"]["node"]):
		attach()
	counters["dealer"]["node"].visible = shown
	for i in tokens.size():
		tokens[i].visible = shown and i < main.game.max_mana["player"]
	# the invisible HUD targets sit over the 3D counters and the bell
	if root.visible and is_instance_valid(counters["dealer"]["node"]):
		var s: float = UI.UI_SCALE()
		for side in heroes:
			heroes[side].position = main.cam.unproject_position(counters[side]["node"].global_position) / s - heroes[side].size / 2
		end_button.position = main.cam.unproject_position(bell.global_position + Vector3(0, 0.2, 0)) / s - end_button.size / 2


func active() -> bool:
	return not main.board_locked and not main.head_open and not main.dealer_thinking \
		and absf(main.look_yaw) < 10 and absf(main.look_pitch) < 10 and main.game.turn == "player" and main.game.winner == ""


func clear_selection() -> void:
	chosen = {}
	main.selected = -1


func actions() -> Array:
	if chosen.is_empty():
		return []
	return main.game.legal_plays("player").filter(func(a):
		return a["kind"] == chosen["kind"] and (a["card"] == chosen.get("card", "") if a["kind"] == "play" \
			else a["attacker"] == chosen.get("attacker", -1)))


func select_card(index: int) -> void:
	if not active() or index >= main.game.hand["player"].size():
		return
	var name: String = main.game.hand["player"][index]
	if chosen.get("card", "") == name:
		clear_selection()
	else:
		chosen = {"kind": "play", "card": name}
		main.selected = index
		var legal := actions()
		if legal.size() == 1 and str(legal[0]["target"]) == "":
			commit(legal[0])
			return
	main.fx.redraw()


func select_minion(id: int) -> void:
	if not active():
		return
	# A selected spell or attack takes priority over selecting another friendly minion.
	if actions().any(func(a): return str(a["target"]) == str(id)):
		target(id)
		return
	if main.game.side_of(id) == "player":
		chosen = {} if chosen.get("attacker", -1) == id else {"kind": "attack", "attacker": id}
		main.selected = -1
		main.fx.redraw()


func target(ref) -> void:
	if not active():
		return
	for a in actions():
		if str(a["target"]) == str(ref):
			commit(a)
			return


func commit(a: Dictionary) -> void:
	clear_selection()
	if main.game.play("player", a):
		Sfx.play("bell", 0.01)
	main.fx.redraw()


func _hover(name: String) -> void:
	var c: Dictionary = main.game.CARDS[name]
	detail.text = "%s · %d mana\n%s" % [name, c["cost"], c["text"] if c["text"] else main.game.sigil_text(main.game.creature(name))]


func redraw() -> void:
	card_nodes.clear()
	var g = main.game
	var legal := actions()
	if not is_instance_valid(counters["dealer"]["node"]) or counters["dealer"]["node"].get_parent() != main.figure:
		attach()
	for side in ["dealer", "player"]:
		var counter: Dictionary = counters[side]
		counter["label"].text = str(g.hp[side])
		var hero_aim: bool = legal.any(func(a): return str(a["target"]) == "hero:" + side)
		counter["ring"].material_override = main._glow(GOLD, 0.8) if hero_aim else null
		var row: Array = g.board[side]
		for i in row.size():
			var m: Dictionary = row[i]
			var x := (i - (row.size() - 1) / 2.0) * 0.52   # cards are 0.475 wide at this scale; leave a gap
			var c = main._card(m["art"], m["name"], m["atk"], m["hp"], Vector3(x, 0.018, -0.55 if side == "player" else -1.3),
				Vector3.ZERO, false, "", g.sigil_text(m))
			c.scale = Vector3.ONE * 0.95
			card_nodes[m["id"]] = c
			var ready: bool = side == "player" and g.turn == "player" and g.can_attack(side, m)
			var selected: bool = chosen.get("attacker", -1) == m["id"]
			var aim: bool = legal.any(func(a): return str(a["target"]) == str(m["id"]))
			if ready or selected or aim:
				main._mesh(main._box(Vector3(0.52, 0.006, 0.72)), main._glow(GOLD if selected or aim else GREEN, 0.6), Vector3(0, -0.014, 0), c)
			c.input_event.connect(func(_cam, ev, _p, _n, _s):
				if main._clicked(ev): select_minion(m["id"]))
			c.mouse_entered.connect(_hover.bind(m["name"]))
	var hand: Array = g.hand["player"]
	for i in hand.size():
		var m: Dictionary = g.creature(hand[i])
		var k := i - (hand.size() - 1) / 2.0
		var lift := 0.12 if i == main.selected else 0.0
		var c = main._card(m["art"], m["name"], -1 if m["kind"] == "spell" else m["atk"], m["hp"],
			Vector3(k * minf(0.27, 2.3 / maxf(hand.size() - 1, 1)), 1.0 - absf(k) * 0.012 + lift, 1.58 - lift),
			Vector3(66, 0, -k * 3), true, str(m["cost"]), g.sigil_text(m))
		c.scale = Vector3.ONE * 0.55
		c.input_event.connect(func(_cam, ev, _p, _n, _s):
			if main._clicked(ev): select_card(i))
		c.mouse_entered.connect(_hover.bind(hand[i]))
	for i in tokens.size():
		tokens[i].material_override = main._glow(GOLD, 0.9) if i < g.mana["player"] else null
	redraw_hint()
	if not chosen.is_empty():
		detail.text = "Choose a glowing target." if not legal.is_empty() else "No legal move: needs mana, a target, or an awake minion."
	else:
		detail.text = ""
