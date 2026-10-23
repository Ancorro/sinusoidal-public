extends Node
## Animation and game feel for the battle table. The rules (battle.gd) resolve instantly and emit `event`s; this node
## queues them and plays each as a short step (card slides, lunges, shakes, crumbles), with its sound, before letting
## main rebuild the board in its settled state. While the queue runs, main's `_redraw()` is held back (see `redraw()`).
##
## Card nodes are main's own (from `_card`); after each settle they are re-identified by where they lie: board cards
## sit flat at a lane, hand cards are raised, and the Dealer's face-down hand are bare meshes.
## Run with `-- --demo-board --demo-fx` to play a card and an attack phase a moment after start (for screenshots).

const STEP := {"play": 0.3, "sacrifice": 0.28, "hit": 0.28, "hit_scale": 0.32, "shield": 0.25, "thorns": 0.2,
	"die": 0.22, "guard_move": 0.25}
const DECK_AT := Vector3(1.7, 0.25, 1.4)     # where drawn cards come from, off the right of the hand
const BIG_HIT := 3                           # damage that shakes the screen

var main            # main.gd (untyped: its members are read dynamically)
var game
var queue: Array[Dictionary] = []
var running := false
var dirty := false
var board_nodes := {"player": [null, null, null, null], "dealer": [null, null, null, null]}
var hand_nodes: Array = []                   # player's hand cards, left to right, matching hand_names
var hand_names: Array = []
var backs: Array = []                        # the Dealer's face-down hand
var last_attacker = null                     # card node of the latest hit, for thorns
var shown_scale := 0.0
var scale_tween: Tween
var shake := 0.0
var candles_out := 0
var lost := false
var demo_at := -1


func _init(m) -> void:
	main = m


func _ready() -> void:
	if "--demo-fx" in OS.get_cmdline_user_args():
		demo_at = 20
		Engine.max_fps = 60   # so --shot-at frames map to time (1 frame = 1/60 s)


func attach(g) -> void:
	game = g
	game.event.connect(_on_event)
	game.changed.connect(redraw)


## A new hand is starting (the run map deals again): drop pending steps from the last hand and forget its lost state.
func reset() -> void:
	queue.clear()
	dirty = true
	lost = false
	last_attacker = null


## Rebuild the board now if nothing is animating, else once the queue drains.
func redraw() -> void:
	if running:
		dirty = true
	else:
		_settle()


func _on_event(e: Dictionary) -> void:
	queue.append(e)
	if not running:
		_run()


func _run() -> void:
	running = true
	while not queue.is_empty():
		var e: Dictionary = queue.pop_front()
		var wait: float = STEP.get(e["type"], 0.0)
		if wait > 0.0:
			call("_" + e["type"], e)
			await get_tree().create_timer(wait * (0.7 if queue.size() > 8 else 1.0)).timeout
	running = false
	if dirty:
		dirty = false
		_settle()


func _process(delta: float) -> void:
	if shake > 0.0:
		shake = maxf(shake - delta * 0.12, 0.0)
		main.cam.h_offset = randf_range(-shake, shake)
		main.cam.v_offset = randf_range(-shake, shake)
	if demo_at >= 0 and main.frames == demo_at:
		_demo()


# ---------- settling ----------
## Let main rebuild every card, then find the new nodes; hand cards glide from where they were, new draws flip in.
func _settle() -> void:
	if "hearth" in game:
		main._redraw()
		return
	var old := {}   # name -> [transforms], in hand order
	for i in hand_nodes.size():
		if is_instance_valid(hand_nodes[i]):
			old.get_or_add(hand_names[i], []).append(hand_nodes[i].transform)
	main._redraw()
	_scan()
	var drawn := 0
	for i in hand_nodes.size():
		var card: Node3D = hand_nodes[i]
		var to := card.transform
		var from: Array = old.get(hand_names[i], [])
		if not from.is_empty():
			card.transform = from.pop_front()
			card.create_tween().set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_OUT).tween_property(card, "transform", to, 0.18)
		else:
			_flip_in(card, to, drawn * 0.1)
			drawn += 1
	if game.winner != "" and not lost:
		lost = true
		_shake(0.05)
		# lives belong to the run map (run_table.gd puts out a candle per lost hand), so no candle here


func _scan() -> void:
	board_nodes = {"player": [null, null, null, null], "dealer": [null, null, null, null]}
	hand_nodes = []
	backs = []
	for c in main.cards_root.get_children():
		if c.is_queued_for_deletion():
			continue
		if c is MeshInstance3D:
			backs.append(c)
		elif c.position.y > 0.3:
			hand_nodes.append(c)
		else:
			board_nodes["player" if c.position.z > (main.FOE_ROW + main.OWN_ROW) / 2.0 else "dealer"][_lane_of(c.position.x)] = c
	hand_nodes.sort_custom(func(a, b): return a.position.x < b.position.x)
	hand_names = game.hand["player"].duplicate()


func _lane_of(x: float) -> int:
	var best := 0
	for l in main.LANES.size():
		if absf(main.LANES[l] - x) < absf(main.LANES[best] - x):
			best = l
	return best


func _lane_pos(side: String, lane: int) -> Vector3:
	return Vector3(main.LANES[lane], 0.01, main.OWN_ROW if side == "player" else main.FOE_ROW)


## Face-down from the deck, sliding to its place while turning over. A red back plate under the card shows while
## it is upside down.
func _flip_in(card: Node3D, to: Transform3D, delay: float) -> void:
	var back := MeshInstance3D.new()
	var box := BoxMesh.new()
	box.size = Vector3(0.5, 0.004, 0.7)
	back.mesh = box
	back.material_override = main._mat(Color("4a1e1a"))
	back.position.y = -0.009
	card.add_child(back)
	card.transform = Transform3D(Basis.from_euler(Vector3(0, 0, PI)), DECK_AT)
	var tw := card.create_tween().set_parallel().set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_OUT)
	tw.tween_property(card, "transform", to, 0.32).set_delay(delay)
	tw.chain().tween_callback(back.queue_free)
	if delay == 0.0:
		Sfx.play("card", 0.15)


# ---------- event steps ----------
func _play(e: Dictionary) -> void:
	var side: String = e["side"]
	var cr: Dictionary = game.creature(e["name"])
	var from := Transform3D(Basis.from_euler(Vector3(0, 0, PI)), Vector3(1.35, 0.1, -1.2))
	if side == "player":
		var i: int = main.selected if main.selected >= 0 and main.selected < hand_names.size() \
				and hand_names[main.selected] == e["name"] else hand_names.find(e["name"])
		if i >= 0:
			from = hand_nodes[i].transform
			hand_nodes[i].queue_free()
			hand_nodes.remove_at(i)
			hand_names.remove_at(i)
	elif not backs.is_empty():
		var b: Node3D = backs.pop_back()
		from.origin = b.position
		b.queue_free()
	var to := _lane_pos(side, e["lane"])
	var card: Node3D = main._card(cr["art"], cr["name"], cr["atk"], cr["hp"], to, Vector3.ZERO, false, "",
		game.sigil_text(cr))
	board_nodes[side][e["lane"]] = card
	card.transform = from
	var tw := card.create_tween().set_parallel().set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_OUT)
	tw.tween_property(card, "transform", Transform3D(Basis(), to + Vector3(0, 0.08, 0)), 0.2)
	tw.chain().tween_property(card, "position:y", to.y, 0.07).set_ease(Tween.EASE_IN)
	tw.tween_callback(Sfx.play.bind("card", 0.06))


## The sacrificed card sinks through the table (unless Many Lives keeps it, then it just shudders).
func _sacrifice(e: Dictionary) -> void:
	var card = board_nodes[e["side"]][e["lane"]]
	if card == null:
		return
	if game.CARDS[e["name"]]["sigils"].has("many_lives"):
		_wobble(card, 0.04)
		Sfx.play("hit", 0.2)
		return
	board_nodes[e["side"]][e["lane"]] = null
	Sfx.play("death", 0.15)
	var tw: Tween = card.create_tween().set_trans(Tween.TRANS_QUAD)
	tw.tween_property(card, "position:y", card.position.y + 0.06, 0.08).set_ease(Tween.EASE_OUT)
	tw.tween_property(card, "position:y", -0.5, 0.22).set_ease(Tween.EASE_IN)
	tw.tween_callback(card.queue_free)


func _hit(e: Dictionary) -> void:
	var side: String = e["side"]
	var a = board_nodes[side][e["lane"]]
	var b = board_nodes[game.other(side)][e["target"]]
	last_attacker = a
	if a != null:
		_lunge(a, side, (main.LANES[e["target"]] - main.LANES[e["lane"]]) * 0.5, 0.22)
	if b != null:
		_after(0.09, func():
			if not is_instance_valid(b):
				return
			_wobble(b, 0.03 + 0.01 * mini(e["amount"], 4))
			_float_text(b.position, "-%d" % e["amount"], Color("e04030"))
			Sfx.play("hit"))
	if e["amount"] >= BIG_HIT:
		_after(0.09, _shake.bind(0.02 + 0.005 * e["amount"]))


func _hit_scale(e: Dictionary) -> void:
	var side: String = e["side"]
	var a = board_nodes[side][e["lane"]]
	if a != null:
		_lunge(a, side, 0.0, 0.36)
	shown_scale += e["amount"] * (1 if side == "player" else -1)
	_after(0.1, func():
		tip_scale(shown_scale)
		_float_text(main.scale_beam.position + Vector3(0, 0.2, 0), "%+d" % (e["amount"] * (1 if side == "player" else -1)),
			Color("f3e6c8"))
		Sfx.play("scale"))
	if e["amount"] >= 2:
		_after(0.1, _shake.bind(0.012 * e["amount"]))


func _shield(e: Dictionary) -> void:
	var b = board_nodes[e["side"]][e["lane"]]
	var a = board_nodes[game.other(e["side"])][e["lane"]]
	if a != null:
		_lunge(a, game.other(e["side"]), 0.0, 0.18)
	if b != null:
		_after(0.08, func():
			_wobble(b, 0.015)
			_float_text(b.position, "shield", Color("a8c8f0"))
			Sfx.play("hit", 0.02))


func _thorns(e: Dictionary) -> void:
	if last_attacker != null and is_instance_valid(last_attacker):
		_wobble(last_attacker, 0.03)
		_float_text(last_attacker.position, "-1", Color("e04030"))
		Sfx.play("hit", 0.2)


## Killed: the card darkens, crumbles into dust and sinks.
func _die(e: Dictionary) -> void:
	var card = board_nodes[e["side"]][e["lane"]]
	if card == null:
		return
	board_nodes[e["side"]][e["lane"]] = null
	Sfx.play("death")
	_dust(card.position)
	for m in card.find_children("*", "GeometryInstance3D", false, false):
		var tw: Tween = m.create_tween()
		tw.tween_property(m, "transparency", 1.0, 0.3)
	var tw: Tween = card.create_tween().set_parallel().set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_IN)
	tw.tween_property(card, "scale", Vector3(0.7, 1.0, 0.7), 0.3)
	tw.tween_property(card, "rotation_degrees:y", randf_range(-12.0, 12.0), 0.3)
	tw.tween_property(card, "position:y", card.position.y - 0.05, 0.3)
	tw.chain().tween_callback(card.queue_free)


func _guard_move(e: Dictionary) -> void:
	var card = board_nodes[e["side"]][e["lane"]]
	if card == null:
		return
	board_nodes[e["side"]][e["lane"]] = null
	board_nodes[e["side"]][e["to"]] = card
	var to := _lane_pos(e["side"], e["to"])
	var tw: Tween = card.create_tween().set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)
	tw.tween_property(card, "position", to, 0.22)
	Sfx.play("card", 0.1)


# ---------- small pieces ----------
## Forward toward the other side and back; dx leans toward a side lane (Splash).
func _lunge(card: Node3D, side: String, dx: float, reach: float) -> void:
	var home := _lane_pos(side, _lane_of(card.position.x))
	var dz := -reach if side == "player" else reach
	var tw := card.create_tween().set_trans(Tween.TRANS_QUAD)
	tw.tween_property(card, "position", home + Vector3(dx, 0.1, dz), 0.09).set_ease(Tween.EASE_OUT)
	tw.tween_property(card, "position", home, 0.14).set_ease(Tween.EASE_IN_OUT)


## A quick side-to-side shake about the card's resting place.
func _wobble(card: Node3D, amt: float) -> void:
	var home := card.position
	var tw := card.create_tween()
	for i in 4:
		tw.tween_property(card, "position", home + Vector3(amt * (1 if i % 2 == 0 else -1) * (1.0 - i * 0.2), 0, 0), 0.035)
	tw.tween_property(card, "position", home, 0.035)


func _shake(amount: float) -> void:
	shake = maxf(shake, amount)


func _after(delay: float, f: Callable) -> void:
	get_tree().create_timer(delay).timeout.connect(f)


## Tip the scale beam to v with a little overshoot.
func tip_scale(v: float) -> void:
	shown_scale = v
	var target := clampf(v, -game.TIP, game.TIP) * 7.0
	if is_equal_approx(main.scale_beam.rotation_degrees.x, target):
		return
	if scale_tween:
		scale_tween.kill()
	scale_tween = main.scale_beam.create_tween().set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)
	scale_tween.tween_property(main.scale_beam, "rotation_degrees:x", target, 0.45)


func _float_text(at: Vector3, text: String, col: Color) -> void:
	var l := Label3D.new()
	l.text = text
	l.font_size = 48
	l.pixel_size = 0.004
	l.modulate = col
	l.outline_size = 8
	l.outline_modulate = Color("0b0908")
	l.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	l.no_depth_test = true
	l.texture_filter = BaseMaterial3D.TEXTURE_FILTER_NEAREST
	l.position = at + Vector3(0, 0.15, 0)
	add_child(l)
	var tw := l.create_tween().set_parallel()
	tw.tween_property(l, "position:y", l.position.y + 0.18, 0.6).set_ease(Tween.EASE_OUT).set_trans(Tween.TRANS_QUAD)
	tw.tween_property(l, "modulate:a", 0.0, 0.25).set_delay(0.35)
	tw.chain().tween_callback(l.queue_free)


## A one-shot burst of small glowing or dusty bits at a point (global space), freed when done.
func _burst(at: Vector3, col: Color, glow: float, n: int, speed: float, gravity: float, life: float) -> void:
	var p := CPUParticles3D.new()
	var bit := BoxMesh.new()
	bit.size = Vector3.ONE * 0.012
	bit.material = main._glow(col, glow) if glow > 0.0 else main._mat(col)
	p.mesh = bit
	p.amount = n
	p.lifetime = life
	p.one_shot = true
	p.explosiveness = 0.95
	p.direction = Vector3.UP
	p.spread = 70.0
	p.initial_velocity_min = speed * 0.4
	p.initial_velocity_max = speed
	p.gravity = Vector3(0, gravity, 0)
	p.scale_amount_min = 0.6
	p.scale_amount_max = 1.4
	add_child(p)
	p.global_position = at
	p.emitting = true
	_after(life + 0.2, p.queue_free)


func _dust(at: Vector3) -> void:
	_burst(at + Vector3(0, 0.03, 0), Color("8a7458"), 0.0, 22, 0.5, -1.5, 0.5)


## Sparks from a cut wire and a short stutter in the Dealer's glass eyes.
func wire_cut(wire: Node3D) -> void:
	_burst(wire.global_position + Vector3(0, 0.02, 0), Color("ffe08a"), 6.0, 28, 1.1, -4.0, 0.45)
	_shake(0.01)
	var eyes := []
	for m in main.head_body.get_children():
		if m is MeshInstance3D and m.mesh is SphereMesh and m.material_override is StandardMaterial3D \
				and m.material_override.emission_enabled:
			eyes.append(m.material_override)
	for mat in eyes:
		var base: float = mat.emission_energy_multiplier
		var tw: Tween = main.head_body.create_tween()
		for i in 7:
			tw.tween_property(mat, "emission_energy_multiplier", base * [0.1, 1.2, 0.0, 0.6, 0.05, 1.0, 0.3][i], 0.06)
		tw.tween_property(mat, "emission_energy_multiplier", base, 0.15)


## A candle gutters and goes out (a life lost): its light stutters down and the flame shrinks away.
## Lights go from the last lit one; main's _process drives light_energy, so this works through colour and range.
func gutter_candle(i := -1) -> void:
	var lights: Array = main.candle_lights
	if i < 0:
		i = lights.size() - 1 - candles_out
	if i < 0 or i >= lights.size():
		return
	candles_out += 1
	var light: OmniLight3D = lights[i]
	var flame: Node3D = null
	for m in main.get_children():
		if m is MeshInstance3D and m.position.distance_to(light.position - Vector3(0, 0.03, 0)) < 0.02:
			flame = m
	Sfx.play("candle_out")
	var col := light.light_color
	var tw := light.create_tween()
	for k in 6:
		tw.tween_property(light, "light_color", col * [0.3, 0.9, 0.15, 0.6, 0.05, 0.3][k], 0.08)
	tw.tween_property(light, "light_color", Color.BLACK, 0.2)
	tw.tween_callback(func(): light.visible = false)
	if flame:
		var ft := flame.create_tween()
		ft.tween_property(flame, "scale", Vector3(1.3, 0.5, 1.3), 0.25)
		ft.tween_property(flame, "scale", Vector3(0.6, 1.2, 0.6), 0.15)
		ft.tween_property(flame, "scale", Vector3.ZERO, 0.3)
		_after(0.7, func(): _burst(flame.global_position + Vector3(0, 0.04, 0), Color("6a6058"), 0.0, 8, 0.15, 0.4, 0.9))


## --demo-fx: set a board where every kind of step happens (big hit, thorns, shield, kill, flyer to the scale), play a
## card, ring the bell; later spark the red wire and gutter a candle.
func _demo() -> void:
	game.turn_count = 2
	for p in [["player", 0, "Grizzly"], ["player", 1, "Ghoul"], ["player", 2, "Raven"], ["player", 3, null],
			["dealer", 0, "Hedgehog"], ["dealer", 1, "Tortoise"], ["dealer", 2, null], ["dealer", 3, "Hydra"]]:
		game.board[p[0]][p[1]] = game.creature(p[2]) if p[2] else null
	game.hand["player"].append("Rat")
	game.bones["player"] = 2
	redraw()
	_after(0.2, func():
		main.selected = game.hand["player"].size() - 1
		main._on_lane(3))
	_after(0.8, main._end_player_turn)
	# effect only: a real cut goes through the brain server, which a demo shouldn't change
	_after(5.0, func(): wire_cut(main.wires["red"]["halves"][0].get_parent()))
	_after(5.0, gutter_candle)
