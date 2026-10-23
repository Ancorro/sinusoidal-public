extends RefCounted
## Greedy value player for the Hearthstone-style rules (scripts/hearth.gd): rate a position, then keep making the move
## that leaves the best-rated position until none beats stopping. Shared by the Dealer's scorer (dealer_ai.gd), the
## bots (bots.gd, playtest.gd) and the tests. One ply, with one exception: the Brass Token is rated by the best move
## it makes possible.

const WIN := 1000.0
## Position weights: hero health (ours, theirs), a card in hand, and the enemy's lethal threat on board.
static var W := {"my_hp": 0.5, "foe_hp": 0.75, "card": 1.5, "threat": 0.6, "lethal": 30.0}
const KW_VALUE := {"taunt": 0.8, "divine_shield": 1.2, "poisonous": 1.8, "lifesteal": 0.8, "stealth": 0.6,
	"windfury": 0.0, "charge": 0.0, "rush": 0.0}


## Value of one minion on the board.
static func minion_value(m: Dictionary) -> float:
	var v: float = m["atk"] * 1.0 + m["hp"] * 0.8 + 0.5
	if m["sigils"].has("windfury"):
		v += m["atk"] * 0.6
	for k in m["sigils"]:
		v += KW_VALUE.get(k, 0.4)
	return v


## How good the position is for side (higher is better).
static func evaluate(b, side: String) -> float:
	if b.winner == side:
		return WIN
	var foe: String = b.other(side)
	if b.winner == foe:
		return -WIN
	var s: float = W["my_hp"] * _hp_worth(b.hp[side]) - W["foe_hp"] * _hp_worth(b.hp[foe])
	s += W["card"] * (b.hand[side].size() - b.hand[foe].size() * 0.5)
	var mine := 0.0
	for m in b.board[side]:
		mine += minion_value(m) + _rattle(b, m)
	var theirs := 0.0
	var foe_atk := 0
	for m in b.board[foe]:
		theirs += minion_value(m) + _rattle(b, m)
		foe_atk += m["atk"] * (2 if m["sigils"].has("windfury") else 1)
	s += mine - theirs * 1.1
	# their board hits back next turn: a little for each point, a lot if it is lethal and we have no taunt between
	var walls: int = b.board[side].filter(func(m): return m["sigils"].has("taunt")).size()
	s -= W["threat"] * foe_atk * (0.5 if walls else 1.0)
	if foe_atk >= b.hp[side] and walls == 0:
		s -= W["lethal"]
	return s


## Health is worth more the lower it gets (a point at 5 matters more than a point at 28).
static func _hp_worth(h: int) -> float:
	return h + maxf(0.0, 12.0 - h) * 0.8


static func _rattle(b, m: Dictionary) -> float:
	return 0.0 if b.CARDS[m["name"]]["deathrattle"].is_empty() else 1.5


## Rating of the position after action a (null: stop here).
static func score_action(b, side: String, a) -> float:
	if a == null:
		return evaluate(b, side)
	var c = b.clone()
	if not c.play(side, a):
		return -WIN
	var s := evaluate(c, side)
	if a["kind"] == "play" and a["card"] == c.COIN:
		# the token only matters for what it lets us play next
		var best := evaluate(b, side)
		for q in c.legal_plays(side):
			if q["kind"] == "play" and q["card"] != c.COIN:
				best = maxf(best, score_action(c, side, q))
		return best - 0.3
	return s


## [{play, score}] for every legal action, best first, and the score of stopping.
static func rate(b, side: String) -> Dictionary:
	var rows := []
	for a in b.legal_plays(side):
		rows.append({"play": a, "score": score_action(b, side, a)})
	rows.sort_custom(func(x, y): return x["score"] > y["score"])
	return {"rows": rows, "pass": evaluate(b, side)}


## The best action for side, or null when stopping rates best. Lethal on board comes first (one ply can't see that
## two attacks together win).
static func pick(b, side: String):
	var kill = lethal_step(b, side)
	if kill != null:
		return kill
	var r := rate(b, side)
	if r["rows"].is_empty() or r["rows"][0]["score"] <= r["pass"] + 0.01:
		return null
	return r["rows"][0]["play"]


## A step toward lethal this turn, or null: when the hero can be reached (no visible taunt) and the face damage of
## ready minions plus affordable damage spells covers its health, the next face hit.
static func lethal_step(b, side: String):
	var foe: String = b.other(side)
	var face := "hero:" + foe
	var plays: Array = b.legal_plays(side)
	var hits := plays.filter(func(a): return a["target"] is String and a["target"] == face)
	if hits.is_empty():
		return null
	var total := 0
	var seen := {}
	for a in hits:
		if a["kind"] == "attack" and not seen.has(a["attacker"]):
			seen[a["attacker"]] = true
			var m: Dictionary = b.find(a["attacker"])
			total += m["atk"] * m["attacks"]
	var spells := []
	for a in hits:
		if a["kind"] == "play":
			for f in b.CARDS[a["card"]]["spell"].get("do", []) + b.CARDS[a["card"]]["battlecry"].get("do", []):
				if f["do"] == "damage":
					spells.append([f["n"], b.CARDS[a["card"]]["cost"], a])
	spells.sort_custom(func(x, y): return x[0] * 10 / maxi(x[1], 1) > y[0] * 10 / maxi(y[1], 1))
	var mana: int = b.mana[side]
	var spell_first = null
	for s in spells:
		if s[1] <= mana:
			mana -= s[1]
			total += s[0]
			if spell_first == null:
				spell_first = s[2]
	if total < b.hp[foe]:
		return null
	for a in hits:
		if a["kind"] == "attack":
			return a
	return spell_first


## A whole greedy turn (the caller ends it).
static func play_turn(b, side: String) -> void:
	for k in 40:
		var a = pick(b, side)
		if a == null or not b.play(side, a):
			return


static func random_turn(b, side: String) -> void:
	for k in 40:
		var opts: Array = b.legal_plays(side)
		if opts.is_empty() or b.rng.randf() < 0.15:
			return
		b.play(side, opts[b.rng.randi_range(0, opts.size() - 1)])


## Short note for the model, e.g. "Cast Ember on their Skeleton: kills it" or "Skeleton attacks their hero (3 damage)".
static func describe_play(b, side: String, a: Dictionary) -> String:
	var foe: String = b.other(side)
	var head := ""
	var t = a["target"]
	var tname := _target_name(b, side, t)
	if a["kind"] == "attack":
		head = "%s attacks %s" % [a["card"], tname]
	elif b.CARDS[a["card"]]["type"] == "spell":
		head = "Cast %s%s" % [a["card"], " on " + tname if str(t) != "" else ""]
	else:
		head = "Play %s%s" % [a["card"], " targeting " + tname if str(t) != "" else ""]
	var c = b.clone()
	c.play(side, a)
	if c.winner == side:
		return head + ": wins the game"
	var notes := []
	var dealt: int = b.hp[foe] - c.hp[foe]
	if dealt > 0:
		notes.append("%d damage to their hero" % dealt)
	for m in b.board[foe]:
		if c.find(m["id"]).is_empty():
			notes.append("kills their %s" % m["name"])
	for m in b.board[side]:
		if c.find(m["id"]).is_empty():
			notes.append("loses your %s" % m["name"])
	var healed: int = c.hp[side] - b.hp[side]
	if healed > 0:
		notes.append("heals you %d" % healed)
	return head + (": " + ", ".join(notes) if notes else "")


static func _target_name(b, side: String, t) -> String:
	if str(t) == "":
		return ""
	if t is String:
		return "your hero" if t == "hero:" + side else "their hero"
	var m: Dictionary = b.find(t)
	if m.is_empty():
		return "?"
	return ("your " if b.side_of(t) == side else "their ") + m["name"]
