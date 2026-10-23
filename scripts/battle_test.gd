extends SceneTree
## Headless rules check. Default: the Hearthstone-style rules (scripts/hearth_checks.gd: keyword tests, mirror sims,
## card rates). With `--rules=lane`: the old lane rules' sigil tests, then sims of random and greedy games. Run:
##   godot_console --headless --path . --script res://scripts/battle_test.gd [-- --rules=lane]
## Options after `--`: --games=N (hearth: 100 greedy and 2N random games; lane: 1000 random, N/4 greedy), --no-cards
## (skip per-card rates); lane only: --no-fix (turn off the first-player handicap).

const Battle := preload("res://scripts/battle.gd")

var fails := 0
var tests_done := false
var rules := {}   # rule overrides from the command line, e.g. --second_extra=1


func _init() -> void:
	var args := {}
	for a in OS.get_cmdline_user_args():
		var kv := a.trim_prefix("--").split("=")
		args[kv[0]] = kv[1] if kv.size() > 1 else "1"
	if preload("res://scripts/rules.gd").hearth():
		var f: int = preload("res://scripts/hearth_checks.gd").new().run_all(args)
		print("FAILED %d checks" % f if f else "all checks passed")
		quit(1 if f else 0)
		return
	var n := int(args.get("games", "1000"))
	var fix := not args.has("no-fix")
	for k in ["squirrel_from_turn", "second_extra", "opening_cards"]:
		if args.has(k):
			rules[k] = int(args[k])
	sigil_tests()
	var t := Time.get_ticks_msec()
	mirror("random", n, fix)
	mirror("greedy", n / 4, fix)
	if not args.has("no-cards"):
		card_rates(n / 4, fix)
	print("sims took %.1f s" % ((Time.get_ticks_msec() - t) / 1000.0))
	var b := Battle.new()
	b.setup(7)
	b.board["player"][1] = b.creature("Raven")
	b.board["dealer"][2] = b.creature("Tortoise")
	print(b.describe("dealer"))
	check("illegal play rejected", not b.play("player", {"card_index": 99, "lane": 0}))
	if not tests_done:
		fails += 1
		print("FAIL: sigil tests stopped on a script error")
	print("FAILED %d checks" % fails if fails else "all checks passed")
	quit(1 if fails else 0)


func check(what: String, ok: bool) -> void:
	if not ok:
		fails += 1
		print("FAIL: ", what)


## An empty board with the given creatures; player attacks next.
func board(player: Dictionary, dealer: Dictionary) -> Battle:
	var b := Battle.new()
	b.quiet = true
	b.turn_count = 5
	for lane in player:
		b.board["player"][lane] = b.creature(player[lane])
	for lane in dealer:
		b.board["dealer"][lane] = b.creature(dealer[lane])
	return b


func sigil_tests() -> void:
	var b := board({0: "Raven"}, {0: "Ghoul"})
	b.attack("player")
	check("flying hits the scale over a blocker", b.scale == 2 and b.board["dealer"][0]["hp"] == 4)
	b = board({0: "Raven"}, {0: "Spider"})
	b.attack("player")
	check("reach blocks flying", b.scale == 0 and b.board["dealer"][0] == null)
	b = board({2: "Ghoul"}, {0: "Mole"})
	b.attack("player")
	check("guard moves to block", b.board["dealer"][0] == null and b.board["dealer"][2]["name"] == "Mole" and b.scale == 0)
	b = board({0: "Shade", 2: "Ghoul"}, {0: "Mole"})
	b.attack("player")
	check("guard already blocking stays", b.board["dealer"][0] != null and b.scale == 3)
	b = board({2: "Raven"}, {0: "Mole"})
	b.attack("player")
	check("guard ignores flyers", b.board["dealer"][0] != null and b.scale == 2)
	b = board({0: "Adder"}, {0: "Grizzly"})
	b.attack("player")
	check("poison kills", b.board["dealer"][0] == null and b.bones["dealer"] == 1)
	b = board({0: "Adder"}, {0: "Tortoise"})
	b.attack("player")
	check("shield stops poison", b.board["dealer"][0] != null and b.board["dealer"][0]["hp"] == 5)
	b.attack("player")
	check("shield works once", b.board["dealer"][0] == null)
	b = board({0: "Shade"}, {0: "Hedgehog"})
	b.attack("player")
	check("thorns hurts the attacker", b.board["player"][0]["hp"] == 1 and b.board["dealer"][0] == null)
	b = board({0: "Rat"}, {0: "Hedgehog"})
	b.attack("player")
	check("thorns kills a 1-health attacker", b.board["player"][0] == null and b.bones["player"] == 1)
	b = board({1: "Hydra"}, {0: "Rat", 1: "Rat", 2: "Rat", 3: "Rat"})
	b.attack("player")
	check("splash hits both sides", b.board["dealer"][0] == null and b.board["dealer"][1] == null
		and b.board["dealer"][2] == null and b.board["dealer"][3] != null)
	b = board({1: "Hydra"}, {0: "Rat"})
	b.attack("player")
	check("splash: open lane hits the scale, side lane hit", b.scale == 1 and b.board["dealer"][0] == null)
	b = board({0: "Vulture"}, {0: "Ghoul"})
	b.attack("dealer")
	check("bone hoarder gives 3 bones", b.board["player"][0] == null and b.bones["player"] == 3)
	b = board({0: "Black Cat"}, {})
	b.turn = "player"
	b.hand["player"] = ["Shade"]
	var opts := b.legal_plays("player")
	check("many lives: its lane is not freed", opts.size() == 3 and not opts.any(func(o): return o["lane"] == 0))
	check("many lives: play ok", b.play("player", {"card_index": 0, "lane": 1}))
	check("many lives survives sacrifice", b.board["player"][0] != null and b.board["player"][1]["name"] == "Shade"
		and b.bones["player"] == 0)
	b = board({0: "Rat"}, {})
	b.turn = "player"
	b.hand["player"] = ["Skeleton"]
	check("bones cost enforced", b.legal_plays("player").is_empty())
	b.bones["player"] = 3
	check("bones cost paid", b.play("player", {"card_index": 0, "lane": 1}) and b.bones["player"] == 0)
	b = Battle.new()
	b.quiet = true
	b.setup(3)
	b.board["player"][0] = b.creature("Ghoul")
	b.end_turn("player")
	check("first player doesn't attack on turn 1", b.scale == 0 and b.turn == "dealer")
	b.board["player"][0] = null
	b.deck["dealer"] = []
	b.end_turn("dealer")
	b.end_turn("player")
	check("empty deck tips the scale", b.scale == 1)
	tests_done = true


## Both sides play the starter deck; who wins, by seat.
func mirror(bot: String, n: int, fix: bool) -> void:
	var wins := {"player": 0, "dealer": 0, "": 0}
	var turns := 0
	for g in n:
		var b := new_game(g + 1, fix)
		turns += run(b, bot, bot)
		wins[b.winner] += 1
	print("%s mirror, %d games: first player %d (%.1f%%), second %d, unfinished %d, avg turns %.1f" % [bot, n,
		wins["player"], 100.0 * wins["player"] / n, wins["dealer"], wins[""], float(turns) / n])


## Each side gets 10 random cards from the pool; a card's rate is the share of games won by sides holding it.
## Seats alternate so the first-player edge cancels out.
func card_rates(n: int, fix: bool) -> void:
	var pool := Battle.CARDS.keys().filter(func(k): return k != "Squirrel")
	var held := {}
	var won := {}
	for k in pool:
		held[k] = 0
		won[k] = 0
	var rng := RandomNumberGenerator.new()
	rng.seed = 99
	for g in n:
		var decks := [[], []]
		for d in decks:
			for i in 10:
				d.append(pool[rng.randi_range(0, pool.size() - 1)])
		var b := new_game(g + 1, fix, decks[0], decks[1])
		run(b, "greedy", "greedy")
		for s in 2:
			var side: String = Battle.SIDES[s]
			for k in decks[s].reduce(func(acc, c): return acc if acc.has(c) else acc + [c], []):
				held[k] += 1
				won[k] += 1 if b.winner == side else 0
	var rows := pool.map(func(k): return [k, float(won[k]) / maxi(held[k], 1)])
	rows.sort_custom(func(x, y): return x[1] > y[1])
	print("card win rates, greedy, %d random-deck games:" % n)
	for r in rows:
		print("  %-13s %.2f  %s" % [r[0], r[1], Battle.sigil_text(Battle.CARDS[r[0]])])


func new_game(seed: int, fix: bool, pd: Array = [], dd: Array = []) -> Battle:
	var b := Battle.new()
	b.quiet = true
	b.first_turn_no_attack = fix
	for k in rules:
		b.set(k, rules[k])
	b.setup(seed, pd, dd)
	return b


## Plays one game to the end (or 60 turns); returns turns taken.
func run(b: Battle, p_bot: String, d_bot: String) -> int:
	var turns := 0
	while b.winner == "" and turns < 60:
		var side := b.turn
		if (p_bot if side == "player" else d_bot) == "greedy":
			greedy_turn(b, side)
		else:
			random_turn(b, side)
		b.end_turn(side)
		turns += 1
	return turns


func random_turn(b: Battle, side: String) -> void:
	for k in 3:
		var opts := b.legal_plays(side)
		if opts.is_empty() or b.rng.randf() < 0.3:
			return
		b.play(side, opts[b.rng.randi_range(0, opts.size() - 1)])


## One-ply greedy: keep making the play whose board after our attack scores best, until passing scores best.
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
		# threat: their attacker facing an open lane next turn
		var f = c.board[foe][lane]
		if f != null and c.board[side][lane] == null:
			s -= 1.5 * f["atk"]
	return s


func _value(c) -> float:
	if c == null:
		return 0.0
	return c["atk"] * 1.2 + c["hp"] * 0.6 + c["sigils"].size() * 0.5
