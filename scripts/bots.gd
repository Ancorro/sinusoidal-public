extends RefCounted
## Bot players for headless games, shared by the playtest runner (and battle_test.gd's, which these are copied from).
## Each turn function makes the plays; the caller ends the turn.

const Battle := preload("res://scripts/battle.gd")
const HearthAI := preload("res://scripts/hearth_ai.gd")   # Hearthstone-style rules: its own greedy and random players


static func turn(b, side: String, bot: String) -> void:
	if "hearth" in b:
		if bot == "greedy":
			HearthAI.play_turn(b, side)
		elif bot == "random":
			HearthAI.random_turn(b, side)
		return
	if bot == "greedy":
		greedy_turn(b, side)
	elif bot == "random":
		random_turn(b, side)


static func random_turn(b: Battle, side: String) -> void:
	for k in 3:
		var opts := b.legal_plays(side)
		if opts.is_empty() or b.rng.randf() < 0.3:
			return
		b.play(side, opts[b.rng.randi_range(0, opts.size() - 1)])


## One-ply greedy: keep making the play whose board after our attack scores best, until passing scores best.
static func greedy_turn(b: Battle, side: String) -> void:
	for k in 4:
		var best = greedy_pick(b, side)
		if best == null:
			return
		b.play(side, best)


## The single best play for side, or null when passing scores best.
static func greedy_pick(b, side: String):
	if "hearth" in b:
		return HearthAI.pick(b, side)
	var best_score := score_after_attack(b, side)
	var best = null
	for o in b.legal_plays(side):
		var c: Battle = b.clone()
		c.play(side, o)
		var s := score_after_attack(c, side, false)
		if s > best_score + 0.01:
			best_score = s
			best = o
	return best


static func score_after_attack(b: Battle, side: String, copy := true) -> float:
	var c: Battle = b.clone() if copy else b
	if not (c.first_turn_no_attack and c.turn_count == 1):
		c.attack(side)
	if c.winner == side:
		return 1000.0
	var foe := c.other(side)
	var s: float = 3.0 * (c.scale if side == "player" else -c.scale) + 0.3 * c.bones[side] + 0.5 * c.hand[side].size()
	for lane in Battle.LANES:
		s += _value(c.board[side][lane]) - _value(c.board[foe][lane])
		# threat: their attacker facing an open lane next turn
		var f = c.board[foe][lane]
		if f != null and c.board[side][lane] == null:
			s -= 1.5 * f["atk"]
	return s


static func _value(c) -> float:
	if c == null:
		return 0.0
	return c["atk"] * 1.2 + c["hp"] * 0.6 + c["sigils"].size() * 0.5
