extends SceneTree
## Headless check of the Dealer's scorer. Run:
##   godot_console --headless --path . --script res://scripts/dealer_test.gd
## Option after `--`: --games=N (default 200 per row). Plays as the Dealer (second seat) against battle_test's greedy
## bot, and as the first seat too, so the seat edge shows.
##   scorer:   always takes the scorer's top play (up to 3 per turn, like main.gd)
##   pick@N:   picks uniformly at random from the shortlist the model would see with N cut wires (a stand-in for a
##             model with no preference; the real model leans to the top of the list)
##   boss:     scorer on the boss deck, with the boss filter

const Battle := preload("res://scripts/battle.gd")
const DealerAI := preload("res://scripts/dealer_ai.gd")

var ai := DealerAI.new()
var pass_ok := true


func _init() -> void:
	var n := 200
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--games="):
			n = int(a.substr(8))
	var t := Time.get_ticks_msec()
	example()
	row("greedy (reference)", n, "greedy", false)
	row("scorer", n, "scorer", false)
	for cuts in 5:
		row("pick@%d cuts" % cuts, n, "pick%d" % cuts, false)
	pass_ok = false
	row("pick@4, never pass", n, "pick4", false)
	pass_ok = true
	row("boss scorer", n, "scorer", true)
	row("boss pick@0 cuts", n, "pick0", true)
	row("boss pick@4 cuts", n, "pick4", true)
	print("took %.1f s" % ((Time.get_ticks_msec() - t) / 1000.0))
	quit()


## One row: the bot as Dealer (second seat) and as first player, each vs greedy.
func row(label: String, n: int, bot: String, boss: bool) -> void:
	var as_dealer := 0
	var as_first := 0
	var sizes := 0.0
	var asks := 0
	for g in n:
		for seat in ["dealer", "player"]:
			var b := Battle.new()
			b.quiet = true
			if boss:
				# the boss deck only ever sits in the Dealer's seat
				if seat == "player":
					continue
				DealerAI.setup_boss(b, g + 1)
			else:
				b.setup(g + 1)
			var turns := 0
			while b.winner == "" and turns < 60:
				var side := b.turn
				if side == seat:
					var r := bot_turn(b, side, bot)
					sizes += r[0]
					asks += r[1]
				else:
					greedy_turn(b, side)
				b.end_turn(side)
				turns += 1
			if b.winner == seat:
				if seat == "dealer":
					as_dealer += 1
				else:
					as_first += 1
	var first := "" if boss else ", as first player %5.1f%%" % (100.0 * as_first / n)
	print("%-20s as Dealer %5.1f%%%s, options shown per ask %.1f" % [label, 100.0 * as_dealer / n, first,
		sizes / maxi(asks, 1)])


## Returns [total options shown, number of asks].
func bot_turn(b: Battle, side: String, bot: String) -> Array:
	var shown := 0
	var asks := 0
	for k in 3:
		if bot == "greedy":
			greedy_turn(b, side)
			return [0, 0]
		if bot == "scorer":
			var r := DealerAI.rate(b, side)
			if r["rows"].is_empty() or r["rows"][0]["score"] <= r["pass"] + 0.01:
				break
			b.play(side, r["rows"][0]["play"])
			continue
		ai.cuts = int(bot.substr(4))
		var sl := ai.shortlist(b, side)
		var opts: Array = sl["options"]
		if opts.is_empty():
			break
		shown += opts.size()
		asks += 1
		# when offered, the stand-in model passes as often as it picks any one option
		var i := ai.rng.randi_range(0, opts.size() if sl["pass_ok"] and pass_ok else opts.size() - 1)
		if i == opts.size():
			break
		b.play(side, opts[i]["play"])
	return [shown, asks]


## Same one-ply greedy as battle_test.gd.
func greedy_turn(b: Battle, side: String) -> void:
	for k in 4:
		var best_score := score_after_attack(b, side)
		var best = null
		for o in b.legal_plays(side):
			var c: Battle = b.clone()
			c.play(side, o)
			var s := score_after_attack(c, side, false)
			if s > best_score + 0.01:
				best_score = s
				best = o
		if best == null:
			return
		b.play(side, best)


func score_after_attack(b: Battle, side: String, copy := true) -> float:
	var c: Battle = b.clone() if copy else b
	if not (c.first_turn_no_attack and c.turn_count == 1):
		c.attack(side)
	if c.winner == side:
		return 1000.0
	var foe := c.other(side)
	var s: float = 3.0 * (c.scale if side == "player" else -c.scale) + 0.3 * c.bones[side] + 0.5 * c.hand[side].size()
	for lane in Battle.LANES:
		s += _value(c.board[side][lane]) - _value(c.board[foe][lane])
		var f = c.board[foe][lane]
		if f != null and c.board[side][lane] == null:
			s -= 1.5 * f["atk"]
	return s


func _value(c) -> float:
	if c == null:
		return 0.0
	return c["atk"] * 1.2 + c["hp"] * 0.6 + c["sigils"].size() * 0.5


## A mid-game board and the shortlist the model would see at 0 and 4 cuts.
func example() -> void:
	var b := Battle.new()
	b.quiet = true
	b.setup(2)
	for i in 5:
		greedy_turn(b, b.turn)
		b.end_turn(b.turn)
	print(b.describe("dealer"))
	for cuts in [0, 4]:
		ai.cuts = cuts
		print("shortlist at %d cuts:" % cuts)
		for o in ai.shortlist(b, "dealer")["options"]:
			print("  %6.1f  %s" % [o["score"], o["text"]])
