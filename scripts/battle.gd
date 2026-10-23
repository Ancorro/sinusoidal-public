extends RefCounted
## Lane battler rules (no visuals). Four lanes, each side has one slot per lane. Creatures have attack, health and sigils.
## A turn: draw one card, play cards by paying blood (sacrificing your own creatures) or bones, then your creatures
## attack straight ahead: a blocker takes the damage, an empty lane hits the other side's scale.
## The scale starts at 0; first to tip it 5 their way wins. Card and sigil data live in data/cards.json.

signal changed
signal log_line(text: String)
## Rule events for animation and sound: {type, side, lane, ...}. Types: play, sacrifice, hit_scale, hit, block,
## shield, die, thorns, guard_move.
signal event(e: Dictionary)

const LANES := 4
const TIP := 5
const SIDES := ["player", "dealer"]
const DATA_PATH := "res://data/cards.json"

## First-player handicap: the first player's creatures don't attack on the game's opening turn.
var first_turn_no_attack := true
## Blood supply: each turn you also get a Squirrel in hand.
var squirrel_each_turn := true
## The per-turn Squirrel starts after this many turns (0: from the opening turn; 1 would skip the first player's).
var squirrel_from_turn := 0
## Cards in each opening hand besides the Squirrel; the second player gets second_extra more.
var opening_cards := 3
var second_extra := 0

static var CARDS := {}      # name -> {atk, hp, cost, kind, art, sigils}
static var SIGILS := {}     # id -> {name, text}
static var DECK := []       # starter deck

var board := {"player": [null, null, null, null], "dealer": [null, null, null, null]}
var hand := {"player": [], "dealer": []}
var deck := {"player": [], "dealer": []}
var bones := {"player": 0, "dealer": 0}
var starve := {"player": 0, "dealer": 0}   # turns drawn from an empty deck
var scale := 0          # positive: tipped toward the player winning
var turn := "player"
var turn_count := 0     # turns started so far; 1 is the opening turn
var winner := ""
var rng := RandomNumberGenerator.new()
var quiet := false      # no signals (used by bots on cloned boards)


static func load_data() -> void:
	if not CARDS.is_empty():
		return
	var d: Dictionary = JSON.parse_string(FileAccess.get_file_as_string(DATA_PATH))
	SIGILS = d["sigils"]
	for n in d["cards"]:
		var c: Dictionary = d["cards"][n]
		# JSON numbers arrive as floats
		CARDS[n] = {"atk": int(c["atk"]), "hp": int(c["hp"]), "cost": int(c["cost"]), "kind": c["kind"],
			"art": c["art"], "sigils": Array(c["sigils"])}
	DECK = Array(d["starter_deck"])


func _init() -> void:
	load_data()


## Decks default to the starter deck; pass card-name arrays to use others (the run map carries decks this way).
func setup(seed := 0, player_deck: Array = [], dealer_deck: Array = []) -> void:
	rng.seed = seed if seed else Time.get_ticks_usec()
	# a fresh table, so one Battle can play every hand of a run
	board = {"player": [null, null, null, null], "dealer": [null, null, null, null]}
	bones = {"player": 0, "dealer": 0}
	starve = {"player": 0, "dealer": 0}
	scale = 0
	turn_count = 0
	winner = ""
	deck["player"] = (player_deck if player_deck else DECK).duplicate()
	deck["dealer"] = (dealer_deck if dealer_deck else DECK).duplicate()
	for side in SIDES:
		_shuffle(deck[side])
		hand[side] = ["Squirrel"]
		for i in opening_cards + (second_extra if side == "dealer" else 0):
			_draw(side)
	start_turn("player")


func creature(name: String) -> Dictionary:
	var c: Dictionary = CARDS[name]
	return {"name": name, "atk": c["atk"], "hp": c["hp"], "max_hp": c["hp"], "cost": c["cost"], "kind": c["kind"],
		"art": c["art"], "sigils": c["sigils"], "shield": c["sigils"].has("shield")}


static func has(c, sigil: String) -> bool:
	return c != null and c["sigils"].has(sigil)


## Short sigil label for a card face, e.g. "Flying, Poison".
static func sigil_text(c: Dictionary) -> String:
	return ", ".join(c["sigils"].map(func(s): return SIGILS[s]["name"]))


func other(side: String) -> String:
	return "dealer" if side == "player" else "player"


func start_turn(side: String) -> void:
	turn = side
	turn_count += 1
	if deck[side].is_empty():
		# out of cards: the scale tips against you, 1 more each turn, so stalled boards still end
		starve[side] += 1
		scale += -starve[side] if side == "player" else starve[side]
		_log("%s has no cards left; the scale tips %d" % [side.capitalize(), starve[side]])
		_check_winner()
	else:
		_draw(side)
	if squirrel_each_turn and turn_count > squirrel_from_turn:
		hand[side].append("Squirrel")
	_changed()


## Legal plays for side: [{card_index, card, lane, sacrifices: [lanes]}]. Blood costs sacrifice the weakest
## creatures (Many Lives first, since it survives).
func legal_plays(side: String) -> Array:
	var out := []
	var mine: Array = board[side]
	var others := []
	for l in LANES:
		if mine[l] != null:
			others.append(l)
	others.sort_custom(func(a, b): return _sac_value(mine[a]) < _sac_value(mine[b]))
	var seen := {}
	for i in hand[side].size():
		var c := creature(hand[side][i])
		if seen.has(c["name"]):     # identical cards give identical plays
			continue
		seen[c["name"]] = true
		for lane in LANES:
			var sac := []
			if c["kind"] == "blood" and c["cost"] > 0:
				if others.size() < c["cost"]:
					continue
				sac = others.slice(0, c["cost"])
				# the target lane must be empty or freed by a sacrifice (Many Lives stays put)
				if mine[lane] != null and (not sac.has(lane) or has(mine[lane], "many_lives")):
					continue
			else:
				if mine[lane] != null:
					continue
				if c["kind"] == "bones" and bones[side] < c["cost"]:
					continue
			out.append({"card_index": i, "card": c["name"], "lane": lane, "sacrifices": sac})
	return out


func _sac_value(c: Dictionary) -> int:
	return -1 if has(c, "many_lives") else c["atk"] + c["hp"]


func play(side: String, p: Dictionary) -> bool:
	if winner != "" or side != turn or p.get("card_index", -1) < 0 or p["card_index"] >= hand[side].size():
		return false
	var name: String = hand[side][p["card_index"]]
	var ok := false
	for q in legal_plays(side):
		if q["card"] == name and q["lane"] == p["lane"]:
			p = {"card_index": p["card_index"], "card": name, "lane": q["lane"], "sacrifices": q["sacrifices"]}
			ok = true
			break
	if not ok:
		return false
	var c := creature(name)
	for l in p["sacrifices"]:
		var s = board[side][l]
		_event({"type": "sacrifice", "side": side, "lane": l, "name": s["name"]})
		if has(s, "many_lives"):
			_log("%s's %s survives the sacrifice" % [side.capitalize(), s["name"]])
			continue
		_die(side, l)
	if c["kind"] == "bones":
		bones[side] -= c["cost"]
	hand[side].remove_at(p["card_index"])
	board[side][p["lane"]] = c
	_event({"type": "play", "side": side, "lane": p["lane"], "name": name})
	_log("%s plays %s in lane %d%s" % [side.capitalize(), name, p["lane"] + 1,
		(" (sacrificing %d)" % p["sacrifices"].size()) if p["sacrifices"].size() else ""])
	_changed()
	return true


## Attack phase for side, then hand the turn over.
func end_turn(side: String) -> void:
	if winner != "" or side != turn:
		return
	if not (first_turn_no_attack and turn_count == 1):
		attack(side)
	_changed()
	if winner == "":
		start_turn(other(side))


## side's creatures attack, lane by lane. The defender's Guard creatures move first.
func attack(side: String) -> void:
	var foe := other(side)
	_guard_moves(side)
	for lane in LANES:
		var a = board[side][lane]
		if a == null or a["atk"] <= 0:
			continue
		var b = board[foe][lane]
		if b == null or (has(a, "flying") and not has(b, "reach")):
			scale += a["atk"] if side == "player" else -a["atk"]
			_event({"type": "hit_scale", "side": side, "lane": lane, "amount": a["atk"]})
			_log("%s's %s hits the scale for %d" % [side.capitalize(), a["name"], a["atk"]])
		else:
			_hit(side, lane, lane)
		if has(a, "splash") and is_same(board[side][lane], a):
			for l in [lane - 1, lane + 1]:
				if l >= 0 and l < LANES and board[foe][l] != null and is_same(board[side][lane], a):
					_hit(side, lane, l)
	_check_winner()


func _check_winner() -> void:
	if scale >= TIP:
		winner = "player"
	elif scale <= -TIP:
		winner = "dealer"


## The attacker in side's lane `from` strikes the foe's creature in lane `to`.
func _hit(side: String, from: int, to: int) -> void:
	var foe := other(side)
	var a: Dictionary = board[side][from]
	var b: Dictionary = board[foe][to]
	if b["shield"]:
		b["shield"] = false
		_event({"type": "shield", "side": foe, "lane": to})
		_log("%s's shield blocks %s" % [b["name"], a["name"]])
	else:
		b["hp"] = 0 if has(a, "poison") else b["hp"] - a["atk"]
		_event({"type": "hit", "side": side, "lane": from, "target": to, "amount": a["atk"]})
		if b["hp"] <= 0:
			_log("%s's %s kills %s" % [side.capitalize(), a["name"], b["name"]])
			_die(foe, to)
	if has(b, "thorns"):
		a["hp"] -= 1
		_event({"type": "thorns", "side": foe, "lane": to})
		if a["hp"] <= 0:
			_log("%s dies on %s's thorns" % [a["name"], b["name"]])
			_die(side, from)


## Before side attacks, each foe Guard creature not already blocking moves into an empty lane facing a
## ground attacker (the strongest one).
func _guard_moves(side: String) -> void:
	var foe := other(side)
	for g in LANES:
		var c = board[foe][g]
		if not has(c, "guard") or _ground_attacker(side, g):
			continue
		var best := -1
		for l in LANES:
			if board[foe][l] == null and _ground_attacker(side, l):
				if best < 0 or board[side][l]["atk"] > board[side][best]["atk"]:
					best = l
		if best >= 0:
			board[foe][best] = c
			board[foe][g] = null
			_event({"type": "guard_move", "side": foe, "lane": g, "to": best})
			_log("%s's %s moves to guard lane %d" % [foe.capitalize(), c["name"], best + 1])


func _ground_attacker(side: String, lane: int) -> bool:
	var a = board[side][lane]
	return a != null and a["atk"] > 0 and not has(a, "flying")


func _die(side: String, lane: int) -> void:
	var c = board[side][lane]
	board[side][lane] = null
	bones[side] += 3 if has(c, "bone_hoarder") else 1
	_event({"type": "die", "side": side, "lane": lane, "name": c["name"]})


## Plain-text board for the Dealer's brain.
func describe(side: String) -> String:
	var foe := other(side)
	var lines := ["Scale: %d (you win at %d, you lose at %d)." % [-scale if side == "dealer" else scale, TIP, -TIP]]
	var seen := {}
	for lane in LANES:
		var m = board[side][lane]
		var f = board[foe][lane]
		lines.append("Lane %d: yours %s | theirs %s" % [lane + 1, _c(m, seen), _c(f, seen)])
	var cards := []
	for n in hand[side]:
		var c := creature(n)
		var cost := "free" if c["kind"] == "free" else "%d %s" % [c["cost"], c["kind"]]
		cards.append("%s %d/%d (%s%s)" % [n, c["atk"], c["hp"], cost, _sig(c, seen)])
	lines.append("Your hand: %s. Your bones: %d." % [", ".join(cards), bones[side]])
	if not seen.is_empty():
		lines.append("Sigils: " + " ".join(seen.keys().map(func(s): return "%s: %s" % [SIGILS[s]["name"], SIGILS[s]["text"]])))
	return "\n".join(lines)


func _c(c, seen: Dictionary) -> String:
	if c == null:
		return "empty"
	var s := _sig(c, seen)
	return "%s %d/%d%s" % [c["name"], c["atk"], c["hp"], " [%s]" % s.substr(2) if s else ""]


func _sig(c: Dictionary, seen: Dictionary) -> String:
	if c["sigils"].is_empty():
		return ""
	for s in c["sigils"]:
		seen[s] = true
	var t := sigil_text(c)
	if c["sigils"].has("shield") and not c["shield"]:
		t += " (used)"
	return ", " + t


## Deep copy for bots to try moves on; the copy emits no signals.
func clone() -> RefCounted:
	var b = get_script().new()
	b.board = board.duplicate(true)
	b.hand = hand.duplicate(true)
	b.deck = deck.duplicate(true)
	b.bones = bones.duplicate()
	b.starve = starve.duplicate()
	b.scale = scale
	b.turn = turn
	b.turn_count = turn_count
	b.winner = winner
	b.first_turn_no_attack = first_turn_no_attack
	b.squirrel_each_turn = squirrel_each_turn
	b.squirrel_from_turn = squirrel_from_turn
	b.rng.seed = rng.randi()
	b.quiet = true
	return b


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
	if not deck[side].is_empty():
		hand[side].append(deck[side].pop_back())


func _shuffle(a: Array) -> void:
	for i in range(a.size() - 1, 0, -1):
		var j := rng.randi_range(0, i)
		var tmp = a[i]
		a[i] = a[j]
		a[j] = tmp
