extends RefCounted
## Hearthstone-style rules (no visuals), the default combat (scripts/rules.gd picks it; the old lanes are battle.gd).
## Two heroes with 30 health. Each turn: +1 mana crystal (max 10), refill mana, draw a card (an empty deck deals
## fatigue: 1, 2, 3... damage). Play minions onto a free board (max 7) and spells; minions can't attack the turn they
## arrive (Charge: anything, Rush: minions only). A minion attacks an enemy minion (both deal damage) or the hero; Taunt
## minions must be attacked first. The first player opens with 3 cards, the second with 4 plus a Brass Token (+1 mana
## once). Cards and keywords live in data/hearth_cards.json.
##
## Moves are actions from legal_plays(side): {key, kind: "play" | "attack", card_index, card, target, attacker}.
## target is "" (none), "hero:player", "hero:dealer" or a minion id (int, stable while it lives). play() takes any
## action whose key matches a legal one. The same surface as battle.gd where the run, logs and Dealer share it.

signal changed
signal log_line(text: String)
## Rule events for animation and sound, {type, side, ...}; types are prefixed h_ so the lane animator (fx.gd) ignores
## them: h_play {name, id}, h_spell {name, target}, h_attack {id, target}, h_damage {target, amount}, h_heal {target,
## amount}, h_shield {target}, h_die {id, name}, h_summon {id, name}, h_fatigue {amount}, h_burn {name}.
signal event(e: Dictionary)

const SIDES := ["player", "dealer"]
const DATA_PATH := "res://data/hearth_cards.json"
const HERO_HP := 30
const MAX_MANA := 10
const BOARD_MAX := 7
const HAND_MAX := 10
const COIN := "Brass Token"
const TURN_LIMIT := 90   # a stalled game ends here; the healthier hero wins (never reached by the bots)

## Who goes first is always the player; the second seat gets one more opening card and the coin.
var opening_cards := 3
var second_extra := 1
var coin := true
var hearth := true   # run.gd and the Dealer check this to tell the rule sets apart

static var CARDS := {}      # name -> {name, type, cost, atk, hp, art, kw, battlecry, deathrattle, spell, text, token}
static var KEYWORDS := {}   # id -> {name, text}
static var DECK := []       # starter deck

var hp := {"player": HERO_HP, "dealer": HERO_HP}
var max_hp := {"player": HERO_HP, "dealer": HERO_HP}
var mana := {"player": 0, "dealer": 0}
var max_mana := {"player": 0, "dealer": 0}
var board := {"player": [], "dealer": []}
var hand := {"player": [], "dealer": []}
var deck := {"player": [], "dealer": []}
var fatigue := {"player": 0, "dealer": 0}
var turn := "player"
var turn_count := 0
var winner := ""
var next_id := 1
var rng := RandomNumberGenerator.new()
var quiet := false


static func load_data() -> void:
	if not CARDS.is_empty():
		return
	var d: Dictionary = JSON.parse_string(FileAccess.get_file_as_string(DATA_PATH))
	KEYWORDS = d["keywords"]
	for n in d["cards"]:
		var c: Dictionary = d["cards"][n]
		CARDS[n] = {"name": n, "type": c.get("type", "minion"), "cost": int(c["cost"]), "atk": int(c.get("atk", 0)),
			"hp": int(c.get("hp", 0)), "art": c["art"], "kw": Array(c.get("kw", [])), "battlecry": c.get("battlecry", {}),
			"deathrattle": Array(c.get("deathrattle", [])), "spell": c.get("spell", {}), "text": c.get("text", ""),
			"token": c.get("token", false)}
		# JSON numbers arrive as floats
		for part in [CARDS[n]["battlecry"], CARDS[n]["spell"]]:
			for f in part.get("do", []):
				_ints(f)
		for f in CARDS[n]["deathrattle"]:
			_ints(f)
	DECK = Array(d["starter_deck"])


static func _ints(f: Dictionary) -> void:
	for k in ["n", "atk", "hp"]:
		if f.has(k):
			f[k] = int(f[k])


func _init() -> void:
	load_data()


func setup(seed := 0, player_deck: Array = [], dealer_deck: Array = []) -> void:
	rng.seed = seed if seed else Time.get_ticks_usec()
	hp = {"player": HERO_HP, "dealer": HERO_HP}
	max_hp = hp.duplicate()
	mana = {"player": 0, "dealer": 0}
	max_mana = {"player": 0, "dealer": 0}
	board = {"player": [], "dealer": []}
	fatigue = {"player": 0, "dealer": 0}
	turn_count = 0
	winner = ""
	next_id = 1
	deck["player"] = (player_deck if player_deck else DECK).duplicate()
	deck["dealer"] = (dealer_deck if dealer_deck else DECK).duplicate()
	for side in SIDES:
		_shuffle(deck[side])
		hand[side] = []
		for i in opening_cards + (second_extra if side == "dealer" else 0):
			_draw(side)
	if coin:
		hand["dealer"].append(COIN)
	start_turn("player")


## A card as shown on a face (and a new minion's starting state). Same keys as battle.gd's creature() where the card
## views share them: name, atk, hp, cost, kind, art, sigils (here the keywords).
func creature(name: String) -> Dictionary:
	var c: Dictionary = CARDS[name]
	return {"name": name, "atk": c["atk"], "hp": c["hp"], "max_hp": c["hp"], "cost": c["cost"], "kind": c["type"],
		"art": c["art"], "sigils": c["kw"].duplicate(), "text": c["text"], "shield": c["kw"].has("divine_shield")}


static func has(m, kw: String) -> bool:
	return m is Dictionary and m.has("sigils") and m["sigils"].has(kw)


## Short keyword label for a card face, e.g. "Taunt, Divine Shield".
static func sigil_text(c: Dictionary) -> String:
	return ", ".join(c["sigils"].map(func(s): return KEYWORDS[s]["name"] if KEYWORDS.has(s) else s))


func other(side: String) -> String:
	return "dealer" if side == "player" else "player"


func start_turn(side: String) -> void:
	turn = side
	turn_count += 1
	max_mana[side] = mini(max_mana[side] + 1, MAX_MANA)
	mana[side] = max_mana[side]
	for m in board[side]:
		m["sleeping"] = false
		m["rush_only"] = false
		m["attacks"] = 2 if has(m, "windfury") else 1
	if deck[side].is_empty():
		fatigue[side] += 1
		_event({"type": "h_fatigue", "side": side, "amount": fatigue[side]})
		_log("%s has no cards left and takes %d fatigue" % [side.capitalize(), fatigue[side]])
		_hit_hero(side, fatigue[side])
		_check_winner()
	else:
		_draw(side)
	if turn_count > TURN_LIMIT and winner == "":
		winner = "player" if hp["player"] >= hp["dealer"] else "dealer"
	_changed()


func end_turn(side: String) -> void:
	if winner != "" or side != turn:
		return
	start_turn(other(side))


# ---------- finding things ----------
func find(id) -> Dictionary:
	if not id is int:
		return {}
	for side in SIDES:
		for m in board[side]:
			if m["id"] == id:
				return m
	return {}


func side_of(id) -> String:
	if not id is int:
		return ""
	for side in SIDES:
		for m in board[side]:
			if m["id"] == id:
				return side
	return ""


## Ids (and hero refs) side may aim a spell or battlecry at, for a target kind from the card data.
func targets(side: String, kind: String) -> Array:
	var foe := other(side)
	var out := []
	if kind in ["any", "minion", "friendly_minion"]:
		out += board[side].map(func(m): return m["id"])
	if kind in ["any", "minion", "enemy", "enemy_minion"]:
		out += board[foe].filter(func(m): return not has(m, "stealth")).map(func(m): return m["id"])
	if kind in ["any", "enemy"]:
		out.append("hero:" + foe)
	if kind == "any":
		out.append("hero:" + side)
	return out


## What one of side's minions may attack: taunt minions if any can be seen, else any visible minion and the hero.
func attack_targets(side: String, m: Dictionary) -> Array:
	if m["atk"] <= 0 or m["attacks"] <= 0 or (m["sleeping"] and not m["rush_only"]):
		return []
	var foe := other(side)
	var seen: Array = board[foe].filter(func(x): return not has(x, "stealth"))
	var taunts := seen.filter(func(x): return has(x, "taunt"))
	var out: Array = (taunts if taunts.size() else seen).map(func(x): return x["id"])
	if taunts.is_empty() and not m["rush_only"]:
		out.append("hero:" + foe)
	return out


func can_attack(side: String, m: Dictionary) -> bool:
	return not attack_targets(side, m).is_empty()


## Every legal move for side now. Cards with no legal target are left out (a battlecry minion with nothing to aim at
## is played without a target, as in Hearthstone).
func legal_plays(side: String) -> Array:
	var out := []
	if winner != "" or side != turn:
		return out
	var seen := {}
	for i in hand[side].size():
		var name: String = hand[side][i]
		var c: Dictionary = CARDS[name]
		if seen.has(name) or c["cost"] > mana[side]:
			continue
		seen[name] = true
		var aim := ""
		if c["type"] == "spell":
			aim = c["spell"].get("target", "")
		else:
			if board[side].size() >= BOARD_MAX:
				continue
			aim = c["battlecry"].get("target", "")
		var ts := targets(side, aim) if aim != "" else []
		if aim != "" and ts.is_empty():
			if c["type"] == "spell":
				continue
			aim = ""
		if aim == "":
			out.append(_action("play", i, name, ""))
		else:
			for t in ts:
				out.append(_action("play", i, name, t))
	for m in board[side]:
		for t in attack_targets(side, m):
			var a := _action("attack", -1, m["name"], t)
			a["attacker"] = m["id"]
			a["key"] = "attack:%d:%s" % [m["id"], t]
			out.append(a)
	return out


func _action(kind: String, i: int, name: String, target) -> Dictionary:
	return {"key": "%s:%s:%s" % [kind, name, target], "kind": kind, "card_index": i, "card": name, "target": target,
		"attacker": -1, "lane": -1, "sacrifices": []}


## Make a move. Only legal ones go through (matched by key, so a stale index is fine).
func play(side: String, p: Dictionary) -> bool:
	if winner != "" or side != turn:
		return false
	var a := {}
	for q in legal_plays(side):
		if q["key"] == p.get("key", ""):
			a = q
			break
	if a.is_empty():
		return false
	if a["kind"] == "attack":
		_attack(side, find(a["attacker"]), a["target"])
	else:
		_play_card(side, a)
	_deaths()
	_check_winner()
	_changed()
	return true


func _play_card(side: String, a: Dictionary) -> void:
	var name: String = a["card"]
	var c: Dictionary = CARDS[name]
	hand[side].remove_at(a["card_index"])
	mana[side] -= c["cost"]
	if c["type"] == "spell":
		_event({"type": "h_spell", "side": side, "name": name, "target": a["target"]})
		_log("%s casts %s%s" % [side.capitalize(), name, _on_text(a["target"])])
		_effects(side, c["spell"].get("do", []), a["target"], {})
		return
	var m := _summon(side, name)
	if m.is_empty():
		return
	m["sleeping"] = not has(m, "charge")
	m["rush_only"] = has(m, "rush") and not has(m, "charge")
	_event({"type": "h_play", "side": side, "name": name, "id": m["id"]})
	_log("%s plays %s%s" % [side.capitalize(), name, _on_text(a["target"])])
	if not c["battlecry"].is_empty():
		_effects(side, c["battlecry"]["do"], a["target"], m)


func _on_text(target) -> String:
	if str(target) == "":
		return ""
	return " on " + _name_of(target)


func _name_of(target) -> String:
	if target is String and target.begins_with("hero:"):
		return "the %s hero" % target.substr(5)
	var m := find(target)
	return m["name"] if m else "?"


## A new minion at the right end of side's board, ready next turn. {} when the board is full.
func _summon(side: String, name: String) -> Dictionary:
	if board[side].size() >= BOARD_MAX:
		return {}
	var m := creature(name)
	m["id"] = next_id
	next_id += 1
	m["sleeping"] = true
	m["rush_only"] = false
	m["attacks"] = 2 if has(m, "windfury") else 1
	m["dead"] = false
	board[side].append(m)
	return m


func _attack(side: String, a: Dictionary, target) -> void:
	a["attacks"] -= 1
	a["sigils"].erase("stealth")   # attacking reveals it
	_event({"type": "h_attack", "side": side, "id": a["id"], "target": target})
	_log("%s's %s attacks %s" % [side.capitalize(), a["name"], _name_of(target)])
	if target is String:
		_damage(target, a["atk"], a, side)
		return
	var d := find(target)
	var back: int = d["atk"]
	_damage(d["id"], a["atk"], a, side)
	if back > 0:
		_damage(a["id"], back, d, other(side))


## Damage a minion id or hero ref; source is the dealing minion ({} for spells and fatigue). Divine Shield, Poisonous
## and Lifesteal apply here. Deaths are collected afterwards in _deaths().
func _damage(target, n: int, source: Dictionary, src_side: String) -> void:
	if n <= 0:
		return
	if target is String:
		var side: String = target.substr(5)
		_hit_hero(side, n)
		_event({"type": "h_damage", "side": src_side, "target": target, "amount": n})
	else:
		var m := find(target)
		if m.is_empty() or m["dead"]:
			return
		if m["shield"]:
			m["shield"] = false
			m["sigils"].erase("divine_shield")
			_event({"type": "h_shield", "side": src_side, "target": target})
			return
		m["hp"] -= n
		if has(source, "poisonous"):
			m["hp"] = mini(m["hp"], 0)
		_event({"type": "h_damage", "side": src_side, "target": target, "amount": n})
	if has(source, "lifesteal"):
		_heal("hero:" + src_side, n)


func _hit_hero(side: String, n: int) -> void:
	hp[side] -= n


func _heal(target, n: int) -> void:
	var got := 0
	if target is String:
		var side: String = target.substr(5)
		got = mini(n, max_hp[side] - hp[side])
		hp[side] += got
	else:
		var m := find(target)
		if m.is_empty():
			return
		got = mini(n, m["max_hp"] - m["hp"])
		m["hp"] += got
	if got > 0:
		_event({"type": "h_heal", "side": side_of(target) if target is int else target.substr(5), "target": target,
			"amount": got})


## Run a card's effect list for side. target: the chosen target; me: the minion whose battlecry or deathrattle it is.
func _effects(side: String, list: Array, target, me: Dictionary) -> void:
	var foe := other(side)
	for f in list:
		match f["do"]:
			"draw":
				for k in f.get("n", 1):
					_draw(side)
			"mana":
				mana[side] += f.get("n", 1)
			"summon":
				for k in f.get("n", 1):
					var s := _summon(side, f["card"])
					if not s.is_empty():
						_event({"type": "h_summon", "side": side, "name": f["card"], "id": s["id"]})
			_:
				for t in _resolve(side, foe, f["to"], target, me):
					match f["do"]:
						"damage":
							_damage(t, f["n"], {}, side)
						"heal":
							_heal(t, f["n"])
						"destroy":
							var m := find(t)
							if m:
								m["hp"] = 0
						"buff":
							var m := find(t)
							if m:
								m["atk"] += f.get("atk", 0)
								m["hp"] += f.get("hp", 0)
								m["max_hp"] += f.get("hp", 0)
								var kw: String = f.get("kw", "")
								if kw != "" and not m["sigils"].has(kw):
									m["sigils"].append(kw)
									if kw == "divine_shield":
										m["shield"] = true


func _resolve(side: String, foe: String, to: String, target, me: Dictionary) -> Array:
	var live := func(s): return board[s].filter(func(m): return not m["dead"] and m["hp"] > 0).map(func(m): return m["id"])
	match to:
		"target":
			return [] if str(target) == "" else [target]
		"self":
			return [me["id"]] if me else []
		"enemy_hero":
			return ["hero:" + foe]
		"my_hero":
			return ["hero:" + side]
		"all_enemy_minions":
			return live.call(foe)
		"all_enemies":
			return live.call(foe) + ["hero:" + foe]
		"all_minions":
			return live.call(side).filter(func(i): return not me or i != me["id"]) + live.call(foe)
		"friendly_minions":
			return live.call(side)
		"other_friendly":
			return live.call(side).filter(func(i): return not me or i != me["id"])
		"random_enemy":
			var pool: Array = live.call(foe) + ["hero:" + foe]
			return [pool[rng.randi_range(0, pool.size() - 1)]]
	return []


## Remove dead minions in board order, then run their deathrattles (which may kill more).
func _deaths() -> void:
	for guard in 10:
		var died := []
		for side in SIDES:
			for m in board[side]:
				if m["hp"] <= 0 and not m["dead"]:
					m["dead"] = true
					died.append([side, m])
		if died.is_empty():
			return
		for d in died:
			board[d[0]].erase(d[1])
			_event({"type": "h_die", "side": d[0], "id": d[1]["id"], "name": d[1]["name"]})
			_log("%s's %s dies" % [d[0].capitalize(), d[1]["name"]])
		for d in died:
			var rattle: Array = CARDS[d[1]["name"]]["deathrattle"]
			if not rattle.is_empty():
				_effects(d[0], rattle, "", d[1])


func _check_winner() -> void:
	if winner != "":
		return
	var p_dead: bool = hp["player"] <= 0
	var d_dead: bool = hp["dealer"] <= 0
	if p_dead and d_dead:
		winner = other(turn)   # both fall at once: the side that did it loses (never happens with this card set)
	elif p_dead:
		winner = "dealer"
	elif d_dead:
		winner = "player"


## Plain-text board for the Dealer's brain.
func describe(side: String) -> String:
	var foe := other(side)
	var seen := {}
	var lines := ["Heroes: you have %d health, they have %d. Your mana: %d of %d. Turn %d." % [hp[side], hp[foe],
		mana[side], max_mana[side], (turn_count + 1) / 2]]
	lines.append("Your minions: %s." % _minions(board[side], seen, true))
	lines.append("Their minions: %s." % _minions(board[foe], seen, false))
	var cards := []
	for n in hand[side]:
		var c: Dictionary = CARDS[n]
		var stats := "" if c["type"] == "spell" else " %d/%d" % [c["atk"], c["hp"]]
		for k in c["kw"]:
			seen[k] = true
		var extra := ", ".join(c["kw"].map(func(k): return KEYWORDS[k]["name"]))
		if c["text"] != "":
			extra = (extra + ". " if extra else "") + c["text"]
		cards.append("%s%s (%d mana%s)" % [n, stats, c["cost"], ", " + extra if extra else ""])
	lines.append("Your hand: %s. Their hand: %d cards." % [", ".join(cards) if cards else "empty", hand[foe].size()])
	if not seen.is_empty():
		lines.append("Keywords: " + " ".join(seen.keys().filter(func(k): return KEYWORDS.has(k))
			.map(func(k): return "%s: %s" % [KEYWORDS[k]["name"], KEYWORDS[k]["text"]])))
	return "\n".join(lines)


func _minions(list: Array, seen: Dictionary, mine: bool) -> String:
	if list.is_empty():
		return "none"
	var out := []
	for m in list:
		for k in m["sigils"]:
			seen[k] = true
		var tags: Array = m["sigils"].map(func(k): return KEYWORDS[k]["name"])
		if mine and can_attack(turn, m) and turn == side_of(m["id"]):
			tags.append("can attack")
		out.append("%s %d/%d%s" % [m["name"], m["atk"], m["hp"], " [%s]" % ", ".join(tags) if tags else ""])
	return ", ".join(out)


## Deep copy for bots to try moves on; the copy emits no signals.
func clone() -> RefCounted:
	var b = get_script().new()
	b.hp = hp.duplicate()
	b.max_hp = max_hp.duplicate()
	b.mana = mana.duplicate()
	b.max_mana = max_mana.duplicate()
	b.board = board.duplicate(true)
	b.hand = hand.duplicate(true)
	b.deck = deck.duplicate(true)
	b.fatigue = fatigue.duplicate()
	b.turn = turn
	b.turn_count = turn_count
	b.winner = winner
	b.next_id = next_id
	b.opening_cards = opening_cards
	b.second_extra = second_extra
	b.coin = coin
	b.rng.seed = rng.seed
	b.rng.state = rng.state
	b.quiet = true
	return b


## The rules a log needs to replay a game (run_log.gd).
func rules_info() -> Dictionary:
	return {"rules": "hearth", "opening_cards": opening_cards, "second_extra": second_extra, "coin": coin,
		"hero_hp": max_hp.duplicate()}


func _changed() -> void:
	if not quiet:
		changed.emit()


func _log(s: String) -> void:
	if not quiet:
		log_line.emit(s)


func _event(e: Dictionary) -> void:
	if not quiet:
		event.emit(e)


func _draw(side: String) -> void:
	if deck[side].is_empty():
		fatigue[side] += 1
		_hit_hero(side, fatigue[side])
		_event({"type": "h_fatigue", "side": side, "amount": fatigue[side]})
		return
	var c = deck[side].pop_back()
	if hand[side].size() >= HAND_MAX:
		_event({"type": "h_burn", "side": side, "name": c})
		_log("%s's hand is full; %s burns" % [side.capitalize(), c])
		return
	hand[side].append(c)


func _shuffle(a: Array) -> void:
	for i in range(a.size() - 1, 0, -1):
		var j := rng.randi_range(0, i)
		var tmp = a[i]
		a[i] = a[j]
		a[j] = tmp
