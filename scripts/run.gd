extends RefCounted
## Run state for one roguelike run (no visuals): the branching map, where you stand, candles (lives), the deck you
## carry between stops, and what happened. Saved to user://run.json after every step so a crash loses nothing.
## The table view is scripts/run_table.gd; dealer decks per stage live in data/run.json, events in data/events.json.

const Battle := preload("res://scripts/battle.gd")
const Rules := preload("res://scripts/rules.gd")   # lane or Hearthstone-style combat; picks cards and run data
const SAVE_PATH := "user://run.json"
const DATA_PATH := "res://data/run.json"
const EVENTS_PATH := "res://data/events.json"
const VERSION := 1
const ROWS := 15          # an opening battle, thirteen branching nights and the boss
const CANDLES := 3
const MIN_BATTLES := 3    # per path, counting the opening battle (the boss is extra)
const MIN_CHOICES := 1
const MIN_EVENTS := 1
const STOP_ODDS := {"battle": 0.45, "choice": 0.25, "event": 0.30}   # for the branching rows, before the path checks

var run_seed := 0
var nodes := []           # [{id, row, col, cols, type: battle|choice|event|boss, next: [ids]}]
var at := -1              # node you stand on; -1 before the first stop
var visited := []
var candles := CANDLES
var deck := []            # card names you carry
var phase := "map"        # map | battle | choice | event | over
var battle := {}          # {node, seed, attempt} while phase is battle
var choice := []          # three card names while phase is choice
var history := []         # [{node, type, result, card?, event?, option?}]
var wires_cut := []
var quote := ""
var won := false
# story (scripts/story.gd writes the text) and the Dealer's hand on the map between battles
var premise := ""
var lines := []           # [{at, kind, text, source}] short Dealer lines between stops
var ending := ""
var sealed := []          # stops the Dealer sealed: never reachable
var hidden := []          # stops whose type the map hides until you stand on them
var bargains := []        # card-choice stops where the Dealer will offer a bargain
var steers := []          # [{at, kind, node, from?, to?, source, say}] what the Dealer did to the map
var bargain := {}         # {card, price} offered at the current card choice
var rng := RandomNumberGenerator.new()

static var DATA := {}
static var DATA_RULES := ""   # which rules DATA was loaded for

static var EVENTS := {}   # id -> event, from data/events.json


static func load_data() -> void:
	if DATA_RULES != Rules.mode():
		DATA_RULES = Rules.mode()
		DATA = JSON.parse_string(FileAccess.get_file_as_string(Rules.run_data_path()))
	if EVENTS.is_empty():
		EVENTS = JSON.parse_string(FileAccess.get_file_as_string(EVENTS_PATH))["events"]


func _init() -> void:
	load_data()


## A fresh run from a seed (0: time-based).
func start(s := 0) -> void:
	run_seed = s if s else int(Time.get_ticks_usec() % 1000000007)
	rng.seed = run_seed
	_generate()
	at = -1
	visited = []
	candles = CANDLES
	load_data()
	deck = Rules.starter()
	phase = "map"
	battle = {}
	choice = []
	history = []
	wires_cut = []
	quote = ""
	won = false
	premise = ""
	lines = []
	ending = ""
	sealed = []
	hidden = []
	bargains = []
	steers = []
	bargain = {}
	event = {}
	seen_events = []
	marks = {}
	wires_intact = []
	lesson = false


# ---------- map ----------
func _generate() -> void:
	for tries in 200:
		nodes = []
		var rows := []
		for r in ROWS:
			var n := 1 if r == 0 or r == ROWS - 1 else (3 if rng.randf() < 0.3 else 2)
			var ids := []
			for c in n:
				var type := "battle" if r == 0 else ("boss" if r == ROWS - 1 else _stop_type())
				ids.append(nodes.size())
				nodes.append({"id": nodes.size(), "row": r, "col": c, "cols": n, "type": type, "next": []})
			rows.append(ids)
		for r in ROWS - 1:
			_link(rows[r], rows[r + 1])
		if _paths_ok():
			return
	push_error("run map: no valid map in 200 tries")


## Edges between two rows without crossings: each node links to the nearest node ahead, sometimes one more beside
## it, and every node ahead gets at least one link in.
func _link(a: Array, b: Array) -> void:
	for i in a.size():
		var pos := float(i) / maxf(a.size() - 1, 1) * (b.size() - 1)
		var j := roundi(pos)
		var links := [b[j]]
		var side := j + (1 if pos > j or (pos == j and rng.randf() < 0.5) else -1)
		if side >= 0 and side < b.size() and rng.randf() < 0.45:
			links.append(b[side])
		for k in links:
			if not nodes[a[i]]["next"].has(k):
				nodes[a[i]]["next"].append(k)
	for j in b.size():
		if not a.any(func(x): return nodes[x]["next"].has(b[j])):
			var i := roundi(float(j) / maxf(b.size() - 1, 1) * (a.size() - 1))
			nodes[a[i]]["next"].append(b[j])
	for i in a:
		nodes[i]["next"].sort()


func _stop_type() -> String:
	var x := rng.randf()
	for type in STOP_ODDS:
		x -= STOP_ODDS[type]
		if x < 0.0:
			return type
	return "battle"


## Every path from the opening stop to the boss has enough battles, a card choice and an event.
func _paths_ok() -> bool:
	# Minimum counts over the directed map, without enumerating an exponential number of paths.
	var counts := {}
	for i in range(nodes.size() - 1, -1, -1):
		var node: Dictionary = nodes[i]
		var row := {}
		for kind in ["battle", "choice", "event"]:
			var least := 0
			if not node["next"].is_empty():
				least = 100000
				for next in node["next"]:
					least = mini(least, counts[next][kind])
			row[kind] = least + int(node["type"] == kind)
		counts[i] = row
	return counts[0]["battle"] >= MIN_BATTLES and counts[0]["choice"] >= MIN_CHOICES and counts[0]["event"] >= MIN_EVENTS


## Rows on this run's map (a run saved before events had 6).
func rows() -> int:
	return nodes[-1]["row"] + 1


func paths(from := 0) -> Array:
	if nodes[from]["next"].is_empty():
		return [[from]]
	var out := []
	for n in nodes[from]["next"]:
		for p in paths(n):
			out.append([from] + p)
	return out


## Stops you may walk to now.
func reachable() -> Array:
	if phase != "map":
		return []
	return [0] if at < 0 else nodes[at]["next"].filter(func(id): return not sealed.has(id))


# ---------- steps ----------
## Walk to a stop. Battles and the boss start a battle; a card choice deals three cards.
func go(id: int) -> bool:
	if not reachable().has(id):
		return false
	at = id
	visited.append(id)
	if nodes[id]["type"] == "choice":
		phase = "choice"
		choice = _deal_choice()
		bargain = _deal_bargain() if bargains.has(id) else {}
	elif nodes[id]["type"] == "event":
		phase = "event"
		event = {"id": _pick_event(), "pending": {}, "result": ""}
		seen_events.append(event["id"])
	else:
		phase = "battle"
		battle = {"node": id, "seed": rng.randi_range(1, 1 << 30), "attempt": 1}
		# a rest before the final hand, as in Slay the Spire: one candle out is relit
		if nodes[id]["type"] == "boss" and candles < CANDLES:
			candles += 1
			battle["relit"] = 1
	save()
	return true


## Card names for the Dealer's side of the current battle.
func dealer_deck() -> Array:
	var n: Dictionary = nodes[battle["node"]]
	# early: rows 0-1, late: rows 2-3, deep: row 4 up to the boss, so hands get harder on the way to it
	var key := "boss" if n["type"] == "boss" else ("early" if n["row"] < 2 else ("late" if n["row"] < 4 else "deep"))
	return Array(DATA["dealer_decks"][key])


func is_boss() -> bool:
	return phase == "battle" and nodes[battle["node"]]["type"] == "boss"


## The battle ended. A loss blows out a candle and you play the stop again; the last candle ends the run.
func battle_over(player_won: bool) -> void:
	if phase != "battle":
		return
	var n: Dictionary = nodes[battle["node"]]
	history.append({"node": n["id"], "type": n["type"], "result": "won" if player_won else "lost"})
	if player_won:
		if n["type"] == "boss":
			_finish(true)
		else:
			phase = "map"
			battle = {}
	else:
		candles -= 1
		if candles <= 0:
			_finish(false)
		else:
			battle["attempt"] += 1
			battle["seed"] = rng.randi_range(1, 1 << 30)
	save()


func pick(i: int) -> bool:
	if phase != "choice" or i < 0 or i >= choice.size():
		return false
	deck.append(choice[i])
	history.append({"node": at, "type": "choice", "result": "took", "card": choice[i]})
	choice = []
	bargain = {}
	phase = "map"
	save()
	return true


## Takes the Dealer's bargain instead of one of the three cards: its card joins your deck, your card goes to it.
func take_bargain() -> bool:
	if phase != "choice" or bargain.is_empty() or not deck.has(bargain["price"]):
		return false
	deck.append(bargain["card"])
	deck.erase(bargain["price"])
	history.append({"node": at, "type": "choice", "result": "bargain", "card": bargain["card"], "gave": bargain["price"]})
	choice = []
	bargain = {}
	phase = "map"
	save()
	return true


func _deal_choice() -> Array:
	var pool: Array = DATA["choice_pool"].duplicate()
	var out := []
	for i in 3:
		out.append(pool.pop_at(rng.randi_range(0, pool.size() - 1)))
	return out


## A strong card for one of yours: the Dealer asks for your best card (it knows what it is doing).
func _deal_bargain() -> Dictionary:
	var strong: Array = DATA.get("strong", ["Grizzly", "Bone Hound", "Hydra", "Tortoise", "Vulture", "Ghoul"])
	var card: String = strong[rng.randi_range(0, strong.size() - 1)]
	var best := ""
	for c in deck:
		if best == "" or card_value(c) > card_value(best):
			best = c
	return {} if best == "" else {"card": card, "price": best}


static func card_value(name: String) -> float:
	return Rules.card_value(name)


func _finish(player_won: bool) -> void:
	won = player_won
	phase = "over"
	battle = {}


## Stops cleared: battles won, cards taken, events passed.
func cleared() -> int:
	return history.filter(func(h): return h["result"] != "lost").size()


# ---------- the Dealer's hand on the map ----------
## Map actions the Dealer may take now, between stops. Every one keeps the map valid: a seal leaves another road
## open, a swap keeps MIN_BATTLES and MIN_CHOICES on every path, and nothing touches the boss, a visited stop or the
## stop you stand on. Each is {kind: seal|swap|hide|bargain|none, node, to?}; "none" is always last.
func steer_options() -> Array:
	var out := []
	if phase != "map" or at < 0 or nodes[at]["next"].is_empty():
		return out
	var open := reachable()
	if open.size() >= 2:
		for id in open:
			out.append({"kind": "seal", "node": id})
	for n in nodes:
		var id: int = n["id"]
		if n["row"] <= nodes[at]["row"] or n["type"] == "boss" or visited.has(id) or sealed.has(id) or not _ahead(id):
			continue
		if n["type"] in ["battle", "choice"]:   # swaps trade a battle and a card choice; events are left as they are
			var was: String = n["type"]
			var to := "choice" if was == "battle" else "battle"
			n["type"] = to
			var ok := _paths_ok()
			n["type"] = was
			if ok:
				out.append({"kind": "swap", "node": id, "to": to})
		if not hidden.has(id):
			out.append({"kind": "hide", "node": id})
		if n["type"] == "choice" and not bargains.has(id):
			out.append({"kind": "bargain", "node": id})
	out.append({"kind": "none", "node": -1})
	return out


## Can you still get to this stop from where you stand (around sealed stops)?
func _ahead(id: int) -> bool:
	var todo := reachable().duplicate()
	while not todo.is_empty():
		var x: int = todo.pop_back()
		if x == id:
			return true
		todo.append_array(nodes[x]["next"].filter(func(k): return not sealed.has(k)))
	return false


## Applies one action from steer_options() (re-checked, so a stale one is refused). Returns false if it no longer fits.
func apply_steer(a: Dictionary, source := "", say := "") -> bool:
	if not steer_options().any(func(o): return o["kind"] == a["kind"] and o["node"] == a["node"]):
		return false
	var id: int = a["node"]
	match a["kind"]:
		"seal":
			sealed.append(id)
		"swap":
			nodes[id]["type"] = a["to"]
			bargains.erase(id)
		"hide":
			hidden.append(id)
		"bargain":
			bargains.append(id)
	var rec := {"at": at, "kind": a["kind"], "node": id, "source": source, "say": say}
	if a["kind"] == "swap":
		rec["to"] = a["to"]
	steers.append(rec)
	save()
	return true


## A plain description of a stop for the Dealer's prompt: "the card choice just ahead on the left".
func describe(id: int) -> String:
	var n: Dictionary = nodes[id]
	var what: String = {"battle": "battle", "choice": "card choice", "event": "unknown event", "boss": "final hand"}[n["type"]]
	var side: String = "" if n["cols"] == 1 else ([" on the left", " on the right"] if n["cols"] == 2 else [" on the left", " in the middle", " on the right"])[n["col"]]
	var gap: int = n["row"] - (nodes[at]["row"] if at >= 0 else -1)
	return "the %s %s%s" % [what, "just ahead" if gap == 1 else "%d stops ahead" % gap, side]


## What an action does, in words for both the Dealer's menu and the player's hint.
func steer_text(a: Dictionary) -> String:
	match a["kind"]:
		"seal":
			return "Seal %s with wax, so the traveller cannot go there." % describe(a["node"])
		"swap":
			return "Turn %s into a %s." % [describe(a["node"]), "battle" if a["to"] == "battle" else "card choice"]
		"hide":
			return "Hide what waits at %s." % describe(a["node"])
		"bargain":
			return "Offer the traveller a bargain at %s." % describe(a["node"])
	return "Leave the road as it is."


## The type the map shows for a stop: "hidden" while the Dealer hides it and you are not standing on it.
func shown_type(id: int) -> String:
	return "hidden" if hidden.has(id) and id != at else nodes[id]["type"]


func note_wires(states: Array) -> void:
	wires_intact = []
	for s in states:
		if s["cut"] and not wires_cut.has(s["id"]):
			wires_cut.append(s["id"])
		if not s["cut"]:
			wires_intact.append(s["id"])


# ---------- save ----------
var save_enabled := true
var save_path := SAVE_PATH   # tests point this elsewhere


func to_dict() -> Dictionary:
	return {"version": VERSION, "rules": Rules.mode(), "seed": run_seed, "nodes": nodes, "at": at, "visited": visited, "candles": candles,
		"deck": deck, "phase": phase, "battle": battle, "choice": choice, "history": history,
		"wires_cut": wires_cut, "quote": quote, "won": won, "rng_state": str(rng.state),
		"premise": premise, "lines": lines, "ending": ending, "sealed": sealed, "hidden": hidden, "bargains": bargains,
		"steers": steers, "bargain": bargain,
		"event": event, "seen_events": seen_events, "marks": marks, "wires_intact": wires_intact, "lesson": lesson}


func from_dict(d: Dictionary) -> bool:
	# a run carries its rules' cards; one saved under the other rules (or before rules existed: lane) starts over
	if int(d.get("version", 0)) != VERSION or d.get("rules", "lane") != Rules.mode():
		return false
	run_seed = int(d["seed"])
	# JSON numbers arrive as floats; ids are ints
	nodes = d["nodes"].map(func(n): return {"id": int(n["id"]), "row": int(n["row"]), "col": int(n["col"]),
		"cols": int(n["cols"]), "type": n["type"], "next": n["next"].map(func(x): return int(x))})
	at = int(d["at"])
	visited = d["visited"].map(func(x): return int(x))
	candles = int(d["candles"])
	deck = Array(d["deck"])
	phase = d["phase"]
	battle = {}
	for k in d["battle"]:
		battle[k] = int(d["battle"][k])
	choice = Array(d["choice"])
	history = Array(d["history"])
	for h in history:
		h["node"] = int(h["node"])
	wires_cut = Array(d["wires_cut"])
	quote = d["quote"]
	won = d["won"]
	# story and steering fields arrived later; older saves load without them
	premise = d.get("premise", "")
	lines = Array(d.get("lines", []))
	ending = d.get("ending", "")
	sealed = d.get("sealed", []).map(func(x): return int(x))
	hidden = d.get("hidden", []).map(func(x): return int(x))
	bargains = d.get("bargains", []).map(func(x): return int(x))
	steers = Array(d.get("steers", []))
	for x in lines + steers:
		for k in ["at", "node"]:
			if x.has(k):
				x[k] = int(x[k])
	bargain = d.get("bargain", {})
	rng.seed = run_seed
	rng.state = int(d["rng_state"])
	# saves from before events have none of these
	event = d.get("event", {})
	seen_events = Array(d.get("seen_events", []))
	marks = {}
	for k in d.get("marks", {}):
		marks[k] = int(d["marks"][k])
	wires_intact = []   # stale after a restart; the brain server's /state refills it
	lesson = bool(d.get("lesson", false))
	return true


func save() -> void:
	if not save_enabled:
		return
	# write a temp file then rename, so a crash mid-write keeps the last good save
	var tmp := save_path + ".tmp"
	var f := FileAccess.open(tmp, FileAccess.WRITE)
	if f == null:
		push_error("run: cannot write %s" % tmp)
		return
	f.store_string(JSON.stringify(to_dict(), "\t"))
	f.close()
	if DirAccess.rename_absolute(ProjectSettings.globalize_path(tmp), ProjectSettings.globalize_path(save_path)) != OK:
		push_error("run: cannot replace %s" % save_path)


## Loads the saved run; false if there is none or it is unreadable.
func load_save() -> bool:
	if not FileAccess.file_exists(save_path):
		return false
	var d = JSON.parse_string(FileAccess.get_file_as_string(save_path))
	return d is Dictionary and from_dict(d)


# ---------- events ----------
## Map events ("?" stops), after Slay the Spire's: a short scene from data/events.json with 2 or 3 choices. Effects are
## applied here so the run stays valid: no option can put out the last candle or shrink the deck below DECK_MIN.
const DECK_MIN := 6
const MARK_MAX := {"bones": 4, "tilt": 2, "dealer_draw": 2}

var event := {}           # {id, pending: {op, then}, option, result, gained, lost, cut_wire?} at an event stop
var seen_events := []     # each event happens once per run
var marks := {}           # lasting effects on every hand: bones, tilt, dealer_draw (the last two count as curses)
var wires_intact := []    # the Dealer's uncut wires, from note_wires (empty when the brain server is down)
var lesson := false        # sandbox "corrupt": the Dealer took a between-battle lesson this run (scripts/lesson.gd)
var event_weights := {}   # id -> weight when drawing an event (default 1); the Dealer's story may bias it


func _pick_event() -> String:
	var pool := EVENTS.keys().filter(func(id): return not seen_events.has(id) and _event_ok(id))
	if pool.is_empty():
		# every event seen: allow repeats rather than an empty stop
		pool = EVENTS.keys().filter(_event_ok)
	var total := 0.0
	for id in pool:
		total += float(event_weights.get(id, 1.0))
	var x := rng.randf() * total
	for id in pool:
		x -= float(event_weights.get(id, 1.0))
		if x < 0.0:
			return id
	return pool[-1]


## An event can appear when its own conditions hold and at least two of its options can be chosen.
func _event_ok(id: String) -> bool:
	var e: Dictionary = EVENTS[id]
	if option_why(e.get("if", {})) != "":
		return false
	return e["options"].filter(func(o): return option_block(o) == "").size() >= 2


func has_curse() -> bool:
	return marks.get("tilt", 0) > 0 or marks.get("dealer_draw", 0) > 0


## Why a condition fails, or "" when it holds.
func option_why(c: Dictionary) -> String:
	if c.has("candles_min") and candles < int(c["candles_min"]):
		return "needs %d candles" % int(c["candles_min"])
	if c.has("candles_below_max") and candles >= CANDLES:
		return "all candles lit"
	if c.has("curse") and not has_curse():
		return "no curse"
	if c.has("wire_intact") and wires_intact.is_empty():
		return "no wire to cut"
	if c.has("deck_min") and deck.size() < int(c["deck_min"]):
		return "deck too small"
	return ""


## Why an option can't be chosen now ("" if it can): its own conditions, then the run's safety rules.
func option_block(o: Dictionary) -> String:
	var why := option_why(o.get("if", {}))
	if why != "":
		return why
	var cost := _worst_cost(o["effects"])
	if cost["candles"] > 0 and candles - cost["candles"] < 1:
		return "would put out your last candle"
	if cost["cards"] > 0 and deck.size() - cost["cards"] < DECK_MIN:
		return "deck too small"
	return ""


## Worst case of a list of effects: candles lost and cards lost (a gamble counts its worst outcome).
func _worst_cost(effects: Array) -> Dictionary:
	var out := {"candles": 0, "cards": 0}
	for f in effects:
		if f.has("candles") and int(f["candles"]) < 0:
			out["candles"] += -int(f["candles"])
		if f.has("lose_random"):
			out["cards"] += int(f["lose_random"])
		if f.get("pick", "") == "remove":
			out["cards"] += 1
		if f.has("gamble"):
			var worst := {"candles": 0, "cards": 0}
			for g in f["gamble"]:
				var w := _worst_cost(g["effects"])
				worst["candles"] = maxi(worst["candles"], w["candles"])
				worst["cards"] = maxi(worst["cards"], w["cards"])
			out["candles"] += worst["candles"]
			out["cards"] += worst["cards"]
	return out


## The current event's options for the table: [{label, effect_text, block}] (block is "" when it can be chosen).
func event_options() -> Array:
	if event.is_empty():
		return []
	return EVENTS[event["id"]]["options"].map(func(o): return {"label": o["label"], "effect_text": rules_text(o["effect_text"]),
		"block": option_block(o)})


## Event wording for the current rules: under Hearthstone-style rules, bones and the scale become hero health.
static func rules_text(t: String) -> String:
	if not Rules.hearth():
		return t
	var re := RegEx.create_from_string("(?i)Open each hand with ([0-9]+) more bones?")
	for m in re.search_all(t):
		t = t.replace(m.get_string(), "Your hero opens each hand with %d more health" % (HEARTH_BONE * int(m.get_string(1))))
	re = RegEx.create_from_string("(?i)Each hand starts with the scale tipped ([0-9]+) against you")
	for m in re.search_all(t):
		t = t.replace(m.get_string(), "Your hero opens each hand with %d less health" % (HEARTH_TILT * int(m.get_string(1))))
	return t


## Take option i. Effects run in order; a card pick (remove, transform, duplicate) pauses them until pick_card().
func choose(i: int) -> bool:
	if phase != "event" or event.has("option"):
		return false
	var opts: Array = EVENTS[event["id"]]["options"]
	if i < 0 or i >= opts.size() or option_block(opts[i]) != "":
		return false
	var o: Dictionary = opts[i]
	event["option"] = o["label"]
	event["result"] = o.get("result", "")
	event["gained"] = []
	event["lost"] = []
	_run_effects(o["effects"])
	save()
	return true


## Pick card deck_index for the pending remove / transform / duplicate.
func pick_card(deck_index: int) -> bool:
	if phase != "event" or pending_pick() == "" or deck_index < 0 or deck_index >= deck.size():
		return false
	var p: Dictionary = event["pending"]
	event["pending"] = {}
	var name: String = deck[deck_index]
	match p["op"]:
		"remove":
			deck.remove_at(deck_index)
			event["lost"].append(name)
		"transform":
			var pool: Array = DATA["choice_pool"].filter(func(n): return n != name)
			var into: String = pool[rng.randi_range(0, pool.size() - 1)]
			deck[deck_index] = into
			event["lost"].append(name)
			event["gained"].append(into)
		"duplicate":
			deck.append(name)
			event["gained"].append(name)
	_run_effects(p["then"])
	save()
	return true


## The pending card pick's kind ("" if none).
func pending_pick() -> String:
	return event.get("pending", {}).get("op", "")


func _run_effects(effects: Array) -> void:
	for k in effects.size():
		var f: Dictionary = effects[k]
		if f.has("pick"):
			event["pending"] = {"op": f["pick"], "then": effects.slice(k + 1)}
			return
		_apply(f)
	history.append({"node": at, "type": "event", "result": "chose", "event": event["id"], "option": event["option"],
		"gained": event["gained"], "lost": event["lost"]})
	phase = "map"


func _apply(f: Dictionary) -> void:
	if f.has("add"):
		deck.append(f["add"])
		event["gained"].append(f["add"])
	if f.has("add_random"):
		var pool: Array = DATA["choice_pool"]
		for n in int(f["add_random"]):
			var c: String = pool[rng.randi_range(0, pool.size() - 1)]
			deck.append(c)
			event["gained"].append(c)
	if f.has("add_from"):
		var d: Array = DATA["dealer_decks"][f["add_from"]]
		var c: String = d[rng.randi_range(0, d.size() - 1)]
		deck.append(c)
		event["gained"].append(c)
	if f.has("lose_random"):
		for n in int(f["lose_random"]):
			if deck.size() > DECK_MIN:
				event["lost"].append(deck.pop_at(rng.randi_range(0, deck.size() - 1)))
	if f.has("candles"):
		candles = clampi(candles + int(f["candles"]), 1, CANDLES)
	if f.has("mark"):
		var m: String = f["mark"]
		marks[m] = mini(marks.get(m, 0) + int(f.get("by", 1)), MARK_MAX[m])
	if f.has("cleanse"):
		marks.erase("tilt")
		marks.erase("dealer_draw")
	if f.has("cut_wire") and not wires_intact.is_empty():
		var id: String = wires_intact.pop_at(rng.randi_range(0, wires_intact.size() - 1))
		event["cut_wire"] = id
		if not wires_cut.has(id):
			wires_cut.append(id)
	if f.has("gamble"):
		var total := 0.0
		for g in f["gamble"]:
			total += float(g["weight"])
		var x := rng.randf() * total
		for g in f["gamble"]:
			x -= float(g["weight"])
			if x < 0.0:
				event["result"] = g["result"]
				for e in g["effects"]:
					_apply(e)
				break


## Lasting marks from events, applied to each hand right after battle setup. Hearthstone-style rules have no bones or
## scale: a bone is +HEARTH_BONE hero health, a tilt -HEARTH_TILT.
const HEARTH_BONE := 2
const HEARTH_TILT := 3

func apply_marks(b) -> void:
	if "hearth" in b:
		var up: int = HEARTH_BONE * marks.get("bones", 0)
		b.max_hp["player"] += up
		b.hp["player"] += up - HEARTH_TILT * marks.get("tilt", 0)
	else:
		b.bones["player"] += marks.get("bones", 0)
		b.scale -= marks.get("tilt", 0)
	for n in marks.get("dealer_draw", 0):
		b._draw("dealer")
	if not b.quiet:
		b.changed.emit()


## For bots: take a random allowed option, and a random card for any pick, back to the map.
func bot_event() -> void:
	var ok := []
	var opts := event_options()
	for i in opts.size():
		if opts[i]["block"] == "":
			ok.append(i)
	choose(ok[rng.randi_range(0, ok.size() - 1)])
	while pending_pick() != "":
		pick_card(rng.randi_range(0, deck.size() - 1))
