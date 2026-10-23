extends SceneTree
## Headless run check: map shape over many seeds, save and load, candles, and full runs played by greedy bots.
##   godot_console --headless --path . --script res://scripts/run_test.gd [-- --rules=lane]
## Battles use the current rules (scripts/rules.gd: Hearthstone-style by default, `--rules=lane` for the old lanes).

const Run := preload("res://scripts/run.gd")
const Battle := preload("res://scripts/battle.gd")
const Story := preload("res://scripts/story.gd")
const Rules := preload("res://scripts/rules.gd")
const HearthAI := preload("res://scripts/hearth_ai.gd")

var fails := 0
var done := false   # set at the end of bot_runs, so a script error counts as a failure


func _init() -> void:
	var runs := 40
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--rules="):
			Rules.set_mode(a.substr(8))
		elif a.begins_with("--runs="):
			runs = int(a.substr(7))
	print("rules: ", Rules.mode())
	maps()
	saves()
	candles()
	steering()
	story_text()
	events()
	bot_runs(runs)
	if not done:
		fails += 1
		print("FAIL: stopped on a script error")
	print("FAILED %d checks" % fails if fails else "all checks passed")
	quit(1 if fails else 0)


func check(what: String, ok: bool) -> void:
	if not ok:
		fails += 1
		print("FAIL: ", what)


func new_run(s: int) -> Run:
	var r := Run.new()
	r.save_enabled = false
	r.start(s)
	return r


func maps() -> void:
	var sizes := {}
	for s in range(1, 301):
		var r := new_run(s)
		check("seed %d: one start, one boss" % s, r.nodes[0]["row"] == 0 and r.nodes[-1]["type"] == "boss")
		for p in r.paths():
			check("seed %d: path length" % s, p.size() == Run.ROWS)
			check("seed %d: path ends at boss" % s, r.nodes[p[-1]]["type"] == "boss")
			for need in [["battle", Run.MIN_BATTLES], ["choice", Run.MIN_CHOICES], ["event", Run.MIN_EVENTS]]:
				check("seed %d: enough %s stops" % [s, need[0]], p.filter(func(id): return r.nodes[id]["type"] == need[0]).size() >= need[1])
		for n in r.nodes:
			if n["row"] > 0:
				check("seed %d: node %d reachable" % [s, n["id"]], r.nodes.any(func(m): return m["next"].has(n["id"])))
		sizes[r.nodes.size()] = sizes.get(r.nodes.size(), 0) + 1
	print("map node counts over 300 seeds: ", sizes)


func saves() -> void:
	var r := new_run(5)
	r.go(0)
	r.battle_over(false)
	var d: Dictionary = JSON.parse_string(JSON.stringify(r.to_dict()))
	var q := Run.new()
	q.save_enabled = false
	check("load save", q.from_dict(d))
	check("roundtrip", JSON.stringify(q.to_dict()) == JSON.stringify(r.to_dict()))
	check("same next draw", q.rng.randi() == r.rng.randi())
	# a test file, so the player's run is untouched; the second save must replace the first
	r.save_enabled = true
	r.save_path = "user://run_test.json"
	r.candles = 3
	r.save()
	r.candles = 2
	r.save()
	var z := Run.new()
	z.save_path = r.save_path
	check("load from disk", z.load_save() and z.candles == 2 and z.phase == "battle")
	DirAccess.remove_absolute(ProjectSettings.globalize_path(r.save_path))


func candles() -> void:
	var r := new_run(9)
	r.go(0)
	for i in 3:
		r.battle_over(false)
	check("three losses end the run", r.phase == "over" and not r.won and r.candles == 0)


## Greedy bot (same idea as battle_test.gd's): keep making the play that most improves the board after attacking.
func play_out(b) -> void:
	if "hearth" in b:
		while b.winner == "" and b.turn_count < 100:
			var s: String = b.turn
			HearthAI.play_turn(b, s)
			b.end_turn(s)
		return
	var turns := 0
	while b.winner == "" and turns < 60:
		var side: String = b.turn
		for k in 4:
			var best_score := score(b, side)
			var best = null
			for o in b.legal_plays(side):
				var c: Battle = b.clone()
				c.play(side, o)
				var sc := score(c, side)
				if sc > best_score + 0.01:
					best_score = sc
					best = o
			if best == null:
				break
			b.play(side, best)
		b.end_turn(side)
		turns += 1


func score(b: Battle, side: String) -> float:
	var c: Battle = b.clone()
	if not (c.first_turn_no_attack and c.turn_count == 1):
		c.attack(side)
	if c.winner == side:
		return 1000.0
	var foe := c.other(side)
	var s: float = 3.0 * (c.scale if side == "player" else -c.scale) + 0.3 * c.bones[side]
	for lane in Battle.LANES:
		for x in [[side, 1.0], [foe, -1.0]]:
			var cr = c.board[x[0]][lane]
			if cr != null:
				s += x[1] * (cr["atk"] * 1.2 + cr["hp"] * 0.6 + cr["sigils"].size() * 0.5)
		var f = c.board[foe][lane]
		if f != null and c.board[side][lane] == null:
			s -= 1.5 * f["atk"]
	return s


## The Dealer's map actions over many seeded runs: random legal picks (the fallback's job) never break the map.
func steering() -> void:
	var kinds := {}
	var bargains := 0
	for s in range(1, 201):
		var r := new_run(s)
		check("seed %d: no steering before the first stop" % s, r.steer_options().is_empty())
		var guard := 0
		while r.phase != "over" and guard < 50:
			guard += 1
			match r.phase:
				"map":
					if r.at >= 0:
						var opts := r.steer_options()
						check("seed %d: leave-it is always offered" % s, opts[-1]["kind"] == "none")
						var m := Story.menu(r, opts)
						check("seed %d: menu has at most %d" % [s, Story.MENU], m.size() <= Story.MENU and m.size() >= 1)
						var a: Dictionary = m[Story.fallback_pick(r, m)]
						kinds[a["kind"]] = kinds.get(a["kind"], 0) + 1
						check("seed %d: picked action applies" % s, r.apply_steer(a, "test"))
						if a["kind"] == "seal":
							check("seed %d: sealed stop leaves the road" % s, not r.reachable().has(a["node"]))
							check("seed %d: re-sealing refused" % s, not r.apply_steer(a, "test"))
					check("seed %d: a stop is always reachable" % s, not r.reachable().is_empty())
					check("seed %d: boss still reachable" % s, r._ahead(r.nodes.size() - 1) or r.reachable().has(r.nodes.size() - 1))
					var nxt := r.reachable()
					r.go(nxt[r.rng.randi_range(0, nxt.size() - 1)])
				"choice":
					if not r.bargain.is_empty():
						bargains += 1
						var n := r.deck.size()
						check("seed %d: bargain price is in the deck" % s, r.deck.has(r.bargain["price"]))
						check("seed %d: bargain taken" % s, r.take_bargain() and r.deck.size() == n and r.phase == "map")
					else:
						r.pick(0)
				"event":
					r.bot_event()
				"battle":
					r.battle_over(r.rng.randf() < 0.8)
		check("seed %d: steered run finished" % s, r.phase == "over")
		# every path still has its battles and a card choice, swaps included
		check("seed %d: paths ok after steering" % s, r._paths_ok())
		var d: Dictionary = JSON.parse_string(JSON.stringify(r.to_dict()))
		var q := Run.new()
		q.save_enabled = false
		check("seed %d: steered save roundtrip" % s, q.from_dict(d) and JSON.stringify(q.to_dict()) == JSON.stringify(r.to_dict()))
	print("steering over 200 runs: ", kinds, ", bargains taken: ", bargains)
	# a run with cruelty cut leans on seals and swaps
	var cruel := {}
	for s in range(1, 201):
		var r := new_run(s)
		r.wires_cut = ["blue"]
		r.go(0)
		r.battle_over(true)
		var m := Story.menu(r, r.steer_options())
		var k: String = m[Story.fallback_pick(r, m)]["kind"]
		cruel[k] = cruel.get(k, 0) + 1
	print("fallback picks with blue cut, first stop: ", cruel)
	# the steering does not move the run's own dice: same seed, same battles with or without it
	var a := new_run(77)
	var b := new_run(77)
	a.go(0)
	b.go(0)
	a.battle_over(true)
	b.battle_over(true)
	var m := Story.menu(a, a.steer_options())
	a.apply_steer(m[Story.fallback_pick(a, m)], "test")
	check("steering leaves the run rng alone", a.rng.state == b.rng.state)
	# an old save without the new fields still loads
	var old: Dictionary = JSON.parse_string(JSON.stringify(new_run(3).to_dict()))
	for k in ["premise", "lines", "ending", "sealed", "hidden", "bargains", "steers", "bargain"]:
		old.erase(k)
	var o := Run.new()
	check("old save loads", o.from_dict(old) and o.sealed.is_empty())


## Parsing and length limits on the model's text.
func story_text() -> void:
	var r := new_run(4)
	check("parse CHOICE", Story.parse_choice("CHOICE: 3
SAY: go left", 5) == 2)
	check("parse bold number", Story.parse_choice("The answer is **3**. This is a warning", 5) == 2)
	check("parse out of range", Story.parse_choice("CHOICE: 9", 5) == -1)
	check("parse none", Story.parse_choice("The traveler cannot be led to a war's rage.", 5) == -1)
	check("parse null", Story.parse_choice(null, 5) == -1)
	check("parse 1. list", Story.parse_choice("1. To seal B with wax as a fickle traveler", 4) == 0)
	check("say", Story.parse_say("CHOICE: 1
SAY: \"Seal it.\"").strip_edges() == "\"Seal it.\"")
	check("clean quotes", Story.clean("\"Hello there, traveller.\"", 120) == "Hello there, traveller.")
	var long := "The wood groans softly as I rise. Tonight I am merely a vessel for your greed, eager to turn the silver. You stand to lose the memory of who you were."
	var c := Story.clean(long, 120)
	check("clean cuts at a sentence end: " + c, c.length() <= 120 and c.ends_with("."))
	var c2 := Story.clean("a".repeat(30) + " " + "b".repeat(200), 120)
	check("clean cuts a run-on: " + c2, c2.length() <= 123)
	check("garbled empty", Story.garbled("", 0) == "empty" and Story.garbled(null, 2) == "empty")
	check("garbled symbols", Story.garbled("!!! ??? ... 1234 5678", 0) != "")
	check("garbled chinese", Story.garbled("我是一个木头做的发牌人，今晚我们玩牌吧", 0) != "")
	check("fine text", Story.garbled("I am the Dealer and you are late.", 0) == "")
	check("cut wires allow odd text", Story.garbled("wave wave salt the tide tide tide", 2) == "")
	var p := Story.pick_text(r, "line", null, "lost")
	check("server down falls back", p["source"] == "fallback" and p["reason"] == "server" and p["text"] != "")
	var q := Story.pick_text(r, "premise", "Tonight I want your candles. Every one of them.")
	check("model text used", q["source"] == "model")
	check("prompt has the menu", Story.steer_prompt(r, [{"kind": "none", "node": -1}], "won").contains("1. Leave the road"))


## Greedy bots on both sides through whole runs; at a choice the player takes the first card.
func bot_runs(n: int) -> void:
	var wins := 0
	var stops := 0
	var events_seen := 0
	var t := Time.get_ticks_msec()
	for s in range(1, n + 1):
		var r := new_run(1000 + s)
		var guard := 0
		while r.phase != "over" and guard < 50:
			guard += 1
			match r.phase:
				"map":
					var nxt := r.reachable()
					r.go(nxt[r.rng.randi_range(0, nxt.size() - 1)])
				"choice":
					r.pick(0)
				"event":
					r.bot_event()
					check("run %d: event done" % s, r.phase == "map" and r.candles >= 1 and r.deck.size() >= Run.DECK_MIN)
					events_seen += 1
				"battle":
					var b = Rules.new_battle()
					b.quiet = true
					b.setup(r.battle["seed"], r.deck, r.dealer_deck())
					r.apply_marks(b)
					play_out(b)
					r.battle_over(b.winner == "player")
		check("run %d finished" % s, r.phase == "over")
		wins += int(r.won)
		stops += r.cleared()
	done = true
	print("bot runs: %d of %d won, %.1f stops cleared on average, %.1f events per run, %.1f s" % [wins, n, float(stops) / n,
		float(events_seen) / n, (Time.get_ticks_msec() - t) / 1000.0])


## Every option of every event, from several run states (fresh, one candle, cursed, small deck, wires known or not):
## blocked options are refused, allowed ones finish back on the map with candles in 1..3 and the deck at least DECK_MIN.
func events() -> void:
	var tried := 0
	var states := [
		{"candles": 3, "marks": {}, "wires": [], "deck_extra": 0},
		{"candles": 1, "marks": {}, "wires": ["red"], "deck_extra": 0},
		{"candles": 2, "marks": {"tilt": 1, "dealer_draw": 1}, "wires": ["red", "blue"], "deck_extra": 3},
		{"candles": 3, "marks": {"tilt": 2}, "wires": [], "deck_extra": -4},
	]
	for id in Run.EVENTS:
		var e: Dictionary = Run.EVENTS[id]
		check("%s: 2-3 options" % id, e["options"].size() >= 2 and e["options"].size() <= 3)
		for st in states:
			for i in e["options"].size():
				for s in 3:
					var r := new_run(500 + s)
					r.candles = st["candles"]
					r.marks = st["marks"].duplicate()
					r.wires_intact = st["wires"].duplicate()
					if st["deck_extra"] > 0:
						for k in st["deck_extra"]:
							r.deck.append("Rat")
					else:
						r.deck.resize(r.deck.size() + st["deck_extra"])
					r.phase = "event"
					r.at = 1
					r.event = {"id": id, "pending": {}, "result": ""}
					var block := r.option_block(e["options"][i])
					var ok := r.choose(i)
					check("%s/%d: choose follows block (%s)" % [id, i, block], ok == (block == ""))
					if not ok:
						continue
					tried += 1
					# save and reload mid-pick, then finish the picks
					if r.pending_pick() != "":
						var q := Run.new()
						q.save_enabled = false
						check("%s/%d: load mid-pick" % [id, i], q.from_dict(JSON.parse_string(JSON.stringify(r.to_dict()))))
						check("%s/%d: pick survives load" % [id, i], q.pending_pick() == r.pending_pick())
						r = q
					var guard := 0
					while r.pending_pick() != "" and guard < 5:
						guard += 1
						check("%s/%d: bad pick refused" % [id, i], not r.pick_card(99))
						r.pick_card(r.rng.randi_range(0, r.deck.size() - 1))
					check("%s/%d: back on the map" % [id, i], r.phase == "map")
					check("%s/%d: candles in range" % [id, i], r.candles >= 1 and r.candles <= Run.CANDLES)
					check("%s/%d: deck floor" % [id, i], r.deck.size() >= Run.DECK_MIN)
					check("%s/%d: cards exist" % [id, i], r.deck.all(func(n): return Rules.cards().has(n)))
					check("%s/%d: logged" % [id, i], r.history[-1]["type"] == "event")
					check("%s/%d: no double choose" % [id, i], not r.choose(0))
	# marks reach the battle
	var r := new_run(3)
	r.marks = {"bones": 2, "tilt": 1, "dealer_draw": 1}
	var b = Rules.new_battle()
	b.quiet = true
	b.setup(9, r.deck, r.DATA["dealer_decks"]["early"])
	var hand: int = b.hand["dealer"].size()
	r.apply_marks(b)
	if Rules.hearth():
		check("marks: bones are hero health", b.max_hp["player"] == 30 + 2 * Run.HEARTH_BONE)
		check("marks: tilt costs health", b.hp["player"] == 30 + 2 * Run.HEARTH_BONE - Run.HEARTH_TILT)
		check("event text follows the rules", Run.rules_text("Open each hand with 2 more bones.") == "Your hero opens each hand with 4 more health.")
		check("run pools hold real cards", (r.DATA["choice_pool"] + r.DATA["strong"]).all(func(n): return Rules.cards().has(n)))
		for k in r.DATA["dealer_decks"]:
			check("dealer deck %s: real cards" % k, r.DATA["dealer_decks"][k].all(func(n): return Rules.cards().has(n)))
		for id in Run.EVENTS:
			for o in Run.EVENTS[id]["options"]:
				for f in o["effects"]:
					if f.has("add"):
						check("%s: event card %s exists" % [id, f["add"]], Rules.cards().has(f["add"]))
	else:
		check("marks: bones", b.bones["player"] == 2)
		check("marks: tilt", b.scale == -1)
	check("marks: dealer draws", b.hand["dealer"].size() == hand + 1)
	# events are drawn once per run while unseen ones remain
	var q := new_run(4)
	var seen := {}
	for k in Run.EVENTS.size():
		var id := q._pick_event()
		q.seen_events.append(id)
		seen[id] = true
	check("each event once before repeats", seen.size() == Run.EVENTS.size() - q.EVENTS.keys().filter(func(x): return not q._event_ok(x)).size())
	print("events: %d events, %d option runs checked" % [Run.EVENTS.size(), tried])
