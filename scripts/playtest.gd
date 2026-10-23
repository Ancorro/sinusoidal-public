extends SceneTree
## Headless playtest: plays N full battles, a bot as the player against the Dealer's brain (a bot, or any server
## that speaks /move like brain/server.py, e.g. brain/stub_server.py), logs them, and prints a short report.
## Usually run through tools/playtest.py, which starts the stub and counts engine errors. Direct:
##   godot_console --headless --path . --script res://scripts/playtest.gd -- --games=100
## Options after `--`:
##   --games=N          battles to play (default 100)
##   --brain=B          the Dealer: greedy | random | http | http://host:port (default greedy, in-process)
##   --player=B         the player bot: greedy | random (default greedy)
##   --decks=D          starter (both sides the starter deck) | random (10 random cards each, for card balance)
##   --seed=S           first game's seed (default 1); game g uses S + g
##   --logs=L           batch (one log for the batch, default) | each (one per game) | none
##   --cuts=N           cut wires the Dealer's shortlist assumes (brain servers only; default 0)
##   --brain-decides    "Brain decides" mode: the server sees every legal play and must act
##   --timeout=MS       one brain request longer than this is a stall and counts as a pass (default 10000)
##   --report=PATH      also save the report as JSON (default user://runs/<stamp>_report.json)
##   --mode=M           battles (default) | runs: N whole runs of the map, needs track B's scripts/run.gd
##   --rules=R          hearth (default, Hearthstone-style) | lane (the old lane rules); see scripts/rules.gd
## Whole runs use track B's run state (scripts/run.gd) through the calls listed in docs/playtest.md.

const Battle := preload("res://scripts/battle.gd")
const Bots := preload("res://scripts/bots.gd")
const RunLog := preload("res://scripts/run_log.gd")
const DealerAI := preload("res://scripts/dealer_ai.gd")
const Rules := preload("res://scripts/rules.gd")

const TURN_CAP := 100   # turns (both sides); Hearthstone-style games average about 27
const GAME_MS_CAP := 60000
## Dealer moves per turn come from DealerAI.picks_per_turn, as in main.gd:_dealer_turn
const RUN_SCRIPT := "res://scripts/run.gd"   # track B
const DEALER_AI := "res://scripts/dealer_ai.gd"   # track C: boss deck and setup, used as run_table.gd does

var args := {}
var brain := "greedy"
var url := ""
var timeout_ms := 10000
var http := HTTPClient.new()
var stats := {}
var ai := DealerAI.new()


func _init() -> void:
	for a in OS.get_cmdline_user_args():
		var kv := a.trim_prefix("--").split("=", true, 1)
		args[kv[0]] = kv[1] if kv.size() > 1 else "1"
	Rules.set_mode(args.get("rules", Rules.mode()))
	Rules.cards()
	brain = args.get("brain", "greedy")
	if brain.begins_with("http"):
		url = "http://127.0.0.1:8775" if brain == "http" else brain
		brain = "http"
	timeout_ms = int(args.get("timeout", "10000"))
	var n := int(args.get("games", "100"))
	quit(runs(n) if args.get("mode", "battles") == "runs" else batch(n))


func batch(n: int) -> int:
	var t := Time.get_ticks_msec()
	var player_bot: String = args.get("player", "greedy")
	var logs: String = args.get("logs", "batch")
	var seed0 := int(args.get("seed", "1"))
	stats = {"games": n, "wins": {"player": 0, "dealer": 0, "": 0}, "turns": 0, "game_ms": 0, "max_game_ms": 0,
		"brain_calls": 0, "brain_ms": 0, "max_brain_ms": 0, "dealer_passes": 0, "errors": {}, "stalls": [],
		"cards": {}}
	var log = RunLog.open("playtest") if logs == "batch" else null
	if log:
		log.run_start({"mode": "battles", "games": n, "brain": brain, "url": url, "player": player_bot,
			"decks": args.get("decks", "starter"), "seed": seed0})
	var rng := RandomNumberGenerator.new()
	rng.seed = seed0
	for g in n:
		var decks := [[], []]
		if args.get("decks", "starter") == "random":
			decks = [random_deck(rng), random_deck(rng)]
		var glog = RunLog.open("game") if logs == "each" else log
		play_battle(decks[0], decks[1], seed0 + g, player_bot, glog)
		if logs == "each":
			glog.close()
	if log:
		log.run_end({"ms": Time.get_ticks_msec() - t})
		log.close()
	report(Time.get_ticks_msec() - t, log.path if log else "")
	return 0


## N whole runs: walk the map (random branch), fight each battle with the bots, take the strongest card at choice
## stops. Adds run counts to the battle stats.
func runs(n: int) -> int:
	if not ResourceLoader.exists(RUN_SCRIPT):
		printerr("--mode=runs needs %s (track B's run map)" % RUN_SCRIPT)
		return 1
	var t := Time.get_ticks_msec()
	var player_bot: String = args.get("player", "greedy")
	var logs: String = args.get("logs", "batch")
	var seed0 := int(args.get("seed", "1"))
	stats = {"games": 0, "wins": {"player": 0, "dealer": 0, "": 0}, "turns": 0, "game_ms": 0, "max_game_ms": 0,
		"brain_calls": 0, "brain_ms": 0, "max_brain_ms": 0, "dealer_passes": 0, "errors": {}, "stalls": [],
		"cards": {}, "runs": {"runs": n, "won": 0, "stops": 0, "battles": 0, "candles_left": 0, "boss_reached": 0, "events": 0,
			"died_at_row": {}, "ms": 0}}
	var batch_log = RunLog.open("playtest_runs") if logs == "batch" else null
	for i in n:
		var log = RunLog.open("run") if logs == "each" else batch_log
		play_run(seed0 + i, player_bot, log)
		if logs == "each":
			log.close()
	if batch_log:
		batch_log.close()
	report(Time.get_ticks_msec() - t, batch_log.path if batch_log else "")
	return 0


func play_run(seed: int, player_bot: String, log) -> void:
	var script: GDScript = load(RUN_SCRIPT)
	if script == null or not script.can_instantiate():
		error("run: %s failed to load" % RUN_SCRIPT, seed, log)
		return
	var r = script.new()
	r.save_enabled = false   # don't touch the player's saved run
	r.start(seed)
	var rs: Dictionary = stats["runs"]
	var t := Time.get_ticks_msec()
	if log:
		log.run_start({"mode": "run", "seed": seed, "brain": brain, "player": player_bot, "deck": r.deck,
			"map": r.nodes})
	var path_rng := RandomNumberGenerator.new()
	path_rng.seed = seed
	var steps := 0
	var saw_boss := false
	while r.phase != "over" and steps < 100:
		steps += 1
		if r.phase == "map":
			var next: Array = r.reachable()
			if next.is_empty():
				error("run: no stop reachable", seed, log)
				break
			r.go(next[path_rng.randi_range(0, next.size() - 1)])
			rs["stops"] += 1
			var node: Dictionary = r.nodes[r.at]
			if log:
				log.stop({"index": r.at, "row": node["row"], "kind": node["type"], "candles": r.candles,
					"deck": r.deck})
		elif r.phase == "choice":
			var best := 0
			for k in r.choice.size():
				if Rules.card_value(r.choice[k]) > Rules.card_value(r.choice[best]):
					best = k
			if log:
				log.choice(r.choice, r.choice[best])
			r.pick(best)
		elif r.phase == "battle":
			var res := play_battle(r.deck, r.dealer_deck(), r.battle["seed"], player_bot, log, r.is_boss(), r)
			rs["battles"] += 1
			stats["games"] += 1
			var row: int = r.nodes[r.at]["row"]
			if r.is_boss() and not saw_boss:
				saw_boss = true
				rs["boss_reached"] += 1
			r.battle_over(res["winner"] == "player")
			if r.phase == "over" and not r.won:
				rs["died_at_row"][str(row)] = rs["died_at_row"].get(str(row), 0) + 1
		elif r.phase == "event" and r.has_method("bot_event"):
			var before: Array = r.history.duplicate()
			r.bot_event()   # track B: picks a random allowed option, back to the map
			rs["events"] += 1
			if log:
				log.write("event_stop", {"index": r.at, "history": r.history.slice(before.size()), "deck": r.deck.size(),
					"candles": r.candles})
		else:
			error("run: unknown phase %s" % r.phase, seed, log)
			break
	if steps >= 100:
		error("run: over 100 steps", seed, log)
	rs["won"] += 1 if r.won else 0
	rs["candles_left"] += r.candles
	rs["ms"] += Time.get_ticks_msec() - t
	if log:
		log.run_end({"seed": seed, "won": r.won, "candles": r.candles, "history": r.history, "deck": r.deck,
			"ms": Time.get_ticks_msec() - t})


func random_deck(rng: RandomNumberGenerator) -> Array:
	var cards := Rules.cards()
	var pool := cards.keys().filter(func(k): return k != "Squirrel" and not cards[k].get("token", false))
	var d := []
	for i in (20 if Rules.hearth() else 10):
		d.append(pool[rng.randi_range(0, pool.size() - 1)])
	return d


## One full battle; the unit both the battle batch and whole runs are built from. Returns
## {winner, turns, ms, played: {side: {card: true}}} and adds to stats.
## run: track B's run state, whose lasting event marks (apply_marks) change the hand's start.
func play_battle(player_deck: Array, dealer_deck: Array, seed: int, player_bot: String, log, boss := false,
		run = null) -> Dictionary:
	var b = Rules.new_battle()
	if boss and ResourceLoader.exists(DEALER_AI):
		load(DEALER_AI).setup_boss(b, seed, player_deck)
	else:
		b.setup(seed, player_deck, dealer_deck)
	if run != null and run.has_method("apply_marks"):
		run.apply_marks(b)
	var played := {"player": {}, "dealer": {}}
	b.event.connect(func(e):
		if e["type"] in ["play", "h_play", "h_spell"]:
			played[e["side"]][e["name"]] = true)
	if log:
		log.attach(b)
		log.battle_start(b, {"player_bot": player_bot, "brain": brain, "boss": boss})
	var t := Time.get_ticks_msec()
	var turns := 0
	while b.winner == "" and turns < TURN_CAP:
		if Time.get_ticks_msec() - t > GAME_MS_CAP:
			stall("game over %d ms" % GAME_MS_CAP, seed, b, log)
			break
		var side: String = b.turn
		if side == "player":
			player_turn(b, player_bot, log)
		else:
			dealer_turn(b, log)
		b.end_turn(side)
		turns += 1
	var ms := Time.get_ticks_msec() - t
	if b.winner == "":
		error("turn cap %d" % TURN_CAP, seed, log)
	if log:
		log.battle_end(b, {"ms": ms, "seed": seed})
	stats["wins"][b.winner] += 1
	stats["turns"] += b.turn_count
	stats["game_ms"] += ms
	stats["max_game_ms"] = maxi(stats["max_game_ms"], ms)
	for side in played:
		for card in played[side]:
			var row: Dictionary = stats["cards"].get(card, {"games": 0, "won": 0})
			row["games"] += 1
			row["won"] += 1 if b.winner == side else 0
			stats["cards"][card] = row
	return {"winner": b.winner, "turns": b.turn_count, "ms": ms, "played": played}


func player_turn(b, bot: String, log) -> void:
	if "hearth" in b:
		for k in 40:
			var p = Bots.greedy_pick(b, "player") if bot == "greedy" else null
			if bot != "greedy":
				var opts: Array = b.legal_plays("player")
				if not opts.is_empty() and b.rng.randf() >= 0.15:
					p = opts[b.rng.randi_range(0, opts.size() - 1)]
			if p == null:
				return
			if not b.play("player", p):
				error("player bot made an illegal play", b.rng.seed, log)
				return
			if log:
				log.play("player", p, b.turn_count)
		return
	for k in 4:
		var opts: Array = b.legal_plays("player")
		var p = null
		if bot == "greedy":
			p = Bots.greedy_pick(b, "player")
		elif not opts.is_empty() and b.rng.randf() >= 0.3 and k < 3:
			p = opts[b.rng.randi_range(0, opts.size() - 1)]
		if p == null:
			return
		if not b.play("player", p):
			error("player bot made an illegal play", b.rng.seed, log)
			return
		if log:
			log.play("player", p, b.turn_count)


## Mirrors main.gd:_dealer_turn: up to PICKS picks until the Dealer passes. The in-process bots pick from all legal
## plays; a brain server gets the same shortlist and request as the game (dealer_ai.gd ask/resolve).
func dealer_turn(b, log) -> void:
	for k in DealerAI.picks_per_turn(b):
		var a := {}
		var opts: Array
		var texts: Array
		if brain == "http":
			ai.cuts = int(args.get("cuts", "0"))
			ai.brain_decides = args.has("brain-decides") or "brain_decides" in args.get("sandbox", "").split(",")
			a = ai.ask(b)
			opts = a["rows"].map(func(r): return r["play"])
			texts = a["texts"]
		else:
			opts = b.legal_plays("dealer")
			var hearth: bool = "hearth" in b
			texts = opts.map(func(o): return DealerAI.HearthAI.describe_play(b, "dealer", o) if hearth else DealerAI.describe_play(b, "dealer", o))
		if opts.is_empty():
			return
		var t := Time.get_ticks_msec()
		var d := ask_brain(b, opts, a)
		var ms := Time.get_ticks_msec() - t
		stats["brain_calls"] += 1
		stats["brain_ms"] += ms
		stats["max_brain_ms"] = maxi(stats["max_brain_ms"], ms)
		var asked: int = d.get("choice", -1)
		if asked >= opts.size() or asked < -1:
			error("brain picked option %d of %d" % [asked, opts.size()], b.rng.seed, log)
		var c: int = ai.resolve(a, d) if brain == "http" else (asked if asked < opts.size() else -1)
		if log:
			log.dealer_move(c, texts, d.get("say", ""), d.get("raw", ""), ms, b.turn_count, asked == c,
				d.get("attempts", 1))
		if c < 0:
			stats["dealer_passes"] += 1
			return
		if not b.play("dealer", opts[c]):
			error("legal option rejected by play()", b.rng.seed, log)
			return


## {choice, say, raw} from the configured brain. a: the request from dealer_ai.gd ask() (brain servers only).
func ask_brain(b, opts: Array, a: Dictionary) -> Dictionary:
	if brain == "greedy":
		var best = Bots.greedy_pick(b, "dealer")
		return {"choice": -1 if best == null else _index_of(opts, best), "say": "", "raw": "greedy"}
	if brain == "random":
		return {"choice": b.rng.randi_range(-1, opts.size() - 1), "say": "", "raw": "random"}
	var t := Time.get_ticks_msec()
	var d = post("/move", a["body"])
	if d == null:
		if Time.get_ticks_msec() - t >= timeout_ms:
			stall("brain /move over %d ms" % timeout_ms, b.rng.seed, b, null)
		else:
			error("brain request failed", b.rng.seed, null)
		return {"choice": -1, "say": "", "raw": "(no answer)"}
	return d


func _index_of(opts: Array, p: Dictionary) -> int:
	for i in opts.size():
		if opts[i].get("key", "") != "" and opts[i]["key"] == p.get("key", ""):
			return i
		if opts[i]["card"] == p["card"] and opts[i]["lane"] == p["lane"] and not opts[i].has("key"):
			return i
	return -1


## Blocking JSON POST (HTTPRequest needs frames, which a SceneTree _init never gets). Null on failure or timeout.
func post(path: String, body: Dictionary):
	var deadline := Time.get_ticks_msec() + timeout_ms
	if http.get_status() != HTTPClient.STATUS_CONNECTED:
		http.close()
		var u := url.trim_prefix("http://").split(":")
		http.connect_to_host(u[0], int(u[1]) if u.size() > 1 else 80)
		while http.get_status() in [HTTPClient.STATUS_CONNECTING, HTTPClient.STATUS_RESOLVING]:
			http.poll()
			if Time.get_ticks_msec() > deadline:
				return null
			OS.delay_msec(1)
		if http.get_status() != HTTPClient.STATUS_CONNECTED:
			return null
	if http.request(HTTPClient.METHOD_POST, path, ["Content-Type: application/json"], JSON.stringify(body)) != OK:
		http.close()
		return null
	while http.get_status() == HTTPClient.STATUS_REQUESTING:
		http.poll()
		if Time.get_ticks_msec() > deadline:
			http.close()
			return null
		OS.delay_msec(1)
	var data := PackedByteArray()
	while http.get_status() == HTTPClient.STATUS_BODY:
		http.poll()
		data.append_array(http.read_response_body_chunk())
		if Time.get_ticks_msec() > deadline:
			http.close()
			return null
		OS.delay_msec(0)
	if http.get_response_code() != 200:
		return null
	return JSON.parse_string(data.get_string_from_utf8())


func error(what: String, seed: int, log) -> void:
	stats["errors"][what] = stats["errors"].get(what, 0) + 1
	if log:
		log.error(what, {"seed": seed})


func stall(what: String, seed: int, b, log) -> void:
	stats["stalls"].append({"what": what, "seed": seed, "turn": b.turn_count})
	if log:
		log.error("stall: " + what, {"seed": seed})


func report(ms: int, log_path: String) -> void:
	var n: int = maxi(stats["games"], 1)
	var w: Dictionary = stats["wins"]
	var lines := []
	if stats.has("runs"):
		var rs: Dictionary = stats["runs"]
		var rn: int = rs["runs"]
		lines.append("PLAYTEST %d whole runs: won %d (%.0f%%), average %.1f stops, %.1f battles, %.1f candles left, %d ms per run" % [
			rn, rs["won"], 100.0 * rs["won"] / rn, float(rs["stops"]) / rn, float(rs["battles"]) / rn,
			float(rs["candles_left"]) / rn, rs["ms"] / rn])
		lines.append("  reached the boss in %d runs; %d event stops; runs lost by map row: %s" % [rs["boss_reached"],
			rs["events"], rs["died_at_row"]])
	lines.append("PLAYTEST %d battles, player bot %s vs Dealer brain %s%s, decks %s, %.1f s" % [n,
		args.get("player", "greedy"), brain, " (%s)" % url if url else "",
		"from the run" if stats.has("runs") else args.get("decks", "starter"), ms / 1000.0])
	lines.append("  player (first seat) won %d (%.0f%%), Dealer won %d (%.0f%%), unfinished %d" % [w["player"],
		100.0 * w["player"] / n, w["dealer"], 100.0 * w["dealer"] / n, w[""]])
	lines.append("  average battle: %.1f turns, %d ms (longest %d ms)" % [float(stats["turns"]) / n,
		stats["game_ms"] / n, stats["max_game_ms"]])
	lines.append("  Dealer brain: %d calls, average %.1f ms, longest %d ms, %d passes" % [stats["brain_calls"],
		float(stats["brain_ms"]) / maxi(stats["brain_calls"], 1), stats["max_brain_ms"], stats["dealer_passes"]])
	var errs: Dictionary = stats["errors"]
	lines.append("  errors: %s" % ("none" if errs.is_empty() else ", ".join(errs.keys().map(func(k): return "%s x%d" % [k, errs[k]]))))
	lines.append("  stalls: %s" % ("none" if stats["stalls"].is_empty() else str(stats["stalls"].slice(0, 5))))
	lines.append("  win rate by card (share of battles won by the side that played it; both sides counted):")
	var rows: Array = stats["cards"].keys().map(func(k): return [k, stats["cards"][k]])
	rows.sort_custom(func(x, y): return float(x[1]["won"]) / x[1]["games"] > float(y[1]["won"]) / y[1]["games"])
	for r in rows:
		lines.append("    %-13s %4.2f  (%d battles)" % [r[0], float(r[1]["won"]) / r[1]["games"], r[1]["games"]])
	if log_path:
		lines.append("  log: %s" % ProjectSettings.globalize_path(log_path))
	var path: String = args.get("report", "%s/%s_report.json" % [RunLog.DIR,
		Time.get_datetime_string_from_system().replace(":", "").replace("-", "").replace("T", "_")])
	var f := FileAccess.open(path, FileAccess.WRITE)
	if f:
		f.store_string(JSON.stringify(stats.merged({"args": args, "ms": ms, "log": log_path}), "  "))
		lines.append("  report: %s" % ProjectSettings.globalize_path(path))
	print("\n".join(lines))
