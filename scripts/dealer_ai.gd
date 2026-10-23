extends RefCounted
## The Dealer's strategy: a rule-based scorer rates each legal play, drops clearly bad ones, and hands the language
## model a short list with notes. Cut wires loosen the filter (more and worse options reach the model, in shuffled
## order), so tampering makes play wilder. Boss mode uses a stronger deck and a stricter filter.
##
## main.gd's _dealer_turn uses it; the run map starts a boss hand with DealerAI.setup_boss(game, seed, player_deck).
## Headless check: godot_console --headless --path . --script res://scripts/dealer_test.gd

const Battle := preload("res://scripts/battle.gd")
const RlDealer := preload("res://scripts/rl_dealer.gd")
const HearthAI := preload("res://scripts/hearth_ai.gd")   # Hearthstone-style rules (scripts/hearth.gd): its scorer

## Boss hand: the starter deck plus a second Skeleton and Black Cat, and one extra opening card. Cheap blood beats
## big cards here: a Grizzly deck did worse in sims (dealer_test.gd).
const BOSS_DECK := ["Rat", "Rat", "Skeleton", "Skeleton", "Lamp Moth", "Shade", "Black Cat", "Black Cat", "Hedgehog",
	"Ghoul", "Raven", "Adder"]
const BOSS_EXTRA_CARDS := 1

## By number of cut wires (0, 1, 2, 3, 4+): how many options reach the model, and how far below the best (or below
## passing) an option may score and still be shown. Past the end of the table everything legal is shown. "Pass" is
## offered to the model only from PASS_AT cuts on: in sims, a picker that passes at random loses most games.
const SHORTLIST := {"normal": [3, 4, 5, 7], "boss": [2, 3, 4, 6]}
const TOLERANCE := {"normal": [3.0, 6.0, 10.0, 16.0], "boss": [1.5, 4.0, 7.0, 12.0]}
const PASS_AT := 3
const WIN := 1000.0
## Scorer weights: scale points, the foe's swing back, bones, cards in hand, and our board's survival after their attack.
static var W := {"scale": 3.0, "reply": 1.0, "bones": 0.3, "hand": 0.4, "keep": 1.0, "threat": 0.5}

var cuts := 0
var cut_ids := []
var rng := RandomNumberGenerator.new()
## Sandbox "rl_bias": how strongly the RL brain bias moves the scorer's values (0 = normal play exactly).
var rl_strength := 1.0
var _rl_turn := -1
var _rl_picks := 0
## "Brain decides" mode: the model sees every legal play (best first, no pass) and must act; cut wires change play
## only through what the steered model picks.
var brain_decides := false
## Outside bias on the scores (track L's RL policy): bias_source(game, side, plays) returns one float per play, in
## game.legal_plays(side) order; each score gets + bias_strength * bias. Strength 0 is exactly the plain scorer.
var bias_source := Callable()
var bias_strength := 0.0


func _init() -> void:
	rng.randomize()


## The run map calls this for the boss stop instead of game.setup(). Hearthstone-style rules: the boss deck from
## data/hearth_run.json and 5 more hero health.
static func setup_boss(game, seed := 0, player_deck: Array = []) -> void:
	if "hearth" in game:
		var d: Dictionary = JSON.parse_string(FileAccess.get_file_as_string("res://data/hearth_run.json"))
		game.setup(seed, player_deck, Array(d["dealer_decks"]["boss"]))
		game.hp["dealer"] += HEARTH_BOSS_HP
		game.max_hp["dealer"] += HEARTH_BOSS_HP
		game.set_meta("boss", true)
		return
	var keep: int = game.second_extra   # run_table reuses one Battle for every hand: don't leak the extra card
	game.second_extra = BOSS_EXTRA_CARDS
	game.setup(seed, player_deck, BOSS_DECK)
	game.second_extra = keep
	game.set_meta("boss", true)


const HEARTH_BOSS_HP := 0   # extra Dealer hero health at the boss (its deck is the step up)


static func is_boss(game) -> bool:
	return game.get_meta("boss", false)


## Most Dealer moves per turn: lane rules play up to 3 cards; Hearthstone-style turns also attack, so allow more.
static func picks_per_turn(game) -> int:
	return 15 if "hearth" in game else 3


## Track brain_ui's wire state (it emits on load and after every cut).
func on_brain_state(wires: Array) -> void:
	cut_ids = wires.filter(func(w): return w["cut"]).map(func(w): return w["id"])
	cuts = cut_ids.size()


## [{play, score, text, bias}] for side's legal plays, best first, plus the score of passing. bias: one float per
## play in legal_plays order, added times strength (the RL hook; empty or 0 strength changes nothing).
static func rate(game, side: String, bias: Array = [], strength := 0.0) -> Dictionary:
	if "hearth" in game:
		var h := HearthAI.rate(game, side)
		for row in h["rows"]:
			row["text"] = HearthAI.describe_play(game, side, row["play"])
			row["bias"] = 0.0
		return h
	var pass_score := evaluate(game, side, null)
	var rows := []
	var plays: Array = game.legal_plays(side)
	for i in plays.size():
		var o: Dictionary = plays[i]
		var b: float = bias[i] if strength != 0.0 and i < bias.size() else 0.0
		rows.append({"play": o, "score": evaluate(game, side, o) + strength * b, "text": describe_play(game, side, o),
			"bias": b})
	rows.sort_custom(func(a, b): return a["score"] > b["score"])
	return {"rows": rows, "pass": pass_score}


## What the model gets to see, given the number of cut wires and boss mode: {options: [{play, score, text}],
## pass_ok: whether "pass" is offered}. No options: nothing beats passing, so don't ask.
func shortlist(game, side: String) -> Dictionary:
	var bias: Array = bias_source.call(game, side, game.legal_plays(side)) 		if bias_strength != 0.0 and bias_source.is_valid() else []
	var r := rate(game, side, bias, bias_strength)
	if rl_on() and not "hearth" in game:   # the RL policy reads lane boards: lane rules only
		# sandbox rl_bias: the RL policy biases every play and passing. Picks left this turn feed the policy;
		# shortlist runs once per pick.
		_rl_picks = _rl_picks - 1 if game.turn_count == _rl_turn else 3
		_rl_turn = game.turn_count
		RlDealer.bias_rates(game, side, r, cut_ids, maxi(_rl_picks, 1), rl_strength)
	var rows: Array = r["rows"]
	if brain_decides:
		return {"options": rows, "pass_ok": false}
	var mode := "boss" if is_boss(game) else "normal"
	var best: float = rows[0]["score"] if rows.size() else r["pass"]
	if "hearth" in game and cuts == 0 and rows.size() and best > r["pass"] + 0.01:
		# lethal on board outranks the one-ply scores (see HearthAI.lethal_step)
		var kill = HearthAI.lethal_step(game, side)
		if kill != null:
			return {"options": rows.filter(func(x): return x["play"]["key"] == kill["key"]), "pass_ok": false}
	if cuts >= SHORTLIST[mode].size():
		rows = rows.duplicate()
	else:
		var tol: float = TOLERANCE[mode][cuts]
		if best <= r["pass"] + 0.01 and cuts == 0:
			return {"options": [], "pass_ok": true}   # nothing beats passing: don't ask
		# at most two lanes per card: variety beats four ways to play a Squirrel
		var per_card := {}
		rows = rows.filter(func(x):
			per_card[x["play"]["card"]] = per_card.get(x["play"]["card"], 0) + 1
			return per_card[x["play"]["card"]] <= 2)
		var floor_score: float = maxf(r["pass"], best) - tol
		rows = rows.filter(func(x): return x["score"] >= floor_score and x["score"] > r["pass"] - tol * 0.5)
		rows = rows.slice(0, SHORTLIST[mode][cuts])
	# a 2B model favours early positions; best-first steers it right until the wires start to go
	if cuts >= 2:
		_shuffle(rows)
	return {"options": rows, "pass_ok": cuts >= PASS_AT or rows.is_empty()}


## Sandbox "rl_bias" switched on (the Sandbox autoload is absent in headless scripts: off there).
func rl_on() -> bool:
	var sb = Engine.get_main_loop().root.get_node_or_null("Sandbox") if Engine.get_main_loop() is SceneTree else null
	return sb != null and sb.enabled("rl_bias") and rl_strength != 0.0


## What to send the brain for one Dealer pick, shared by main.gd and playtest.gd: {rows, texts, body} where body is
## the /move request, or rows empty when the Dealer should just end its turn.
func ask(game, side := "dealer") -> Dictionary:
	var sl := shortlist(game, side)
	var texts: Array = sl["options"].map(func(o): return o["text"])
	return {"rows": sl["options"], "texts": texts, "hearth": "hearth" in game, "body": {"board": game.describe(side), "options": texts,
		"allow_pass": sl["pass_ok"], "must_act": brain_decides, "seed": game.rng.seed + game.turn_count}}


## Which of a["rows"] to play from the brain's answer d ({choice, ...}), or -1 to end the turn. In brain-decides mode
## a bad answer (old server, stub, dead server) still acts: a seeded pick among the options.
func resolve(a: Dictionary, d: Dictionary) -> int:
	var n: int = a["rows"].size()
	var c: int = d.get("choice", -1)
	if c >= 0 and c < n:
		return c
	if a.get("hearth", false) and n > 0 and not d.has("raw"):
		return 0   # no brain server: the scorer's best (a Hearthstone-style turn has too many moves to sit idle)
	if brain_decides and n > 0:
		var r := RandomNumberGenerator.new()
		r.seed = a["body"]["seed"]
		return r.randi_range(0, n - 1)
	return -1


## Score for side after making play p (null: pass), its own attack, and the foe's attack back.
static func evaluate(game: Battle, side: String, p) -> float:
	var c: Battle = game.clone()
	if p != null and not c.play(side, p):
		return -WIN
	var foe := c.other(side)
	if not (c.first_turn_no_attack and c.turn_count == 1):
		c.attack(side)
	if c.winner == side:
		return WIN
	var dealt := _mine(c, side)
	var s: float = W["scale"] * dealt + W["bones"] * c.bones[side] + W["hand"] * c.hand[side].size()
	for lane in Battle.LANES:
		s += _value(c.board[side][lane]) - _value(c.board[foe][lane])
	# the foe's reply with what is already on the board
	c.attack(foe)
	if c.winner == foe:
		return -WIN * 0.5 + s
	s += W["reply"] * (_mine(c, side) - dealt)
	for lane in Battle.LANES:
		s += W["keep"] * _value(c.board[side][lane])
		var f = c.board[foe][lane]
		if f != null and c.board[side][lane] == null:
			s -= W["threat"] * f["atk"]
	return s


## Short note for the model: what the play does, e.g. "Play Raven in lane 2 (sacrifice Squirrel): hits the scale for 2".
static func describe_play(game: Battle, side: String, p: Dictionary) -> String:
	var foe := game.other(side)
	var notes := []
	var sacs: Array = p["sacrifices"].map(func(l): return game.board[side][l]["name"])
	var head := "Play %s in lane %d%s" % [p["card"], p["lane"] + 1, (" (sacrifice %s)" % ", ".join(sacs)) if sacs else ""]
	var f = game.board[foe][p["lane"]]
	var c: Battle = game.clone()
	c.play(side, p)
	var before := c.clone()
	var base: Battle = game.clone()    # passing instead, to note only what this play adds
	if not (c.first_turn_no_attack and c.turn_count == 1):
		c.attack(side)
		base.attack(side)
	if c.winner == side:
		return head + ": wins the game"
	var dealt := _mine(c, side) - _mine(base, side)
	if dealt > 0:
		notes.append("hits the scale for %d" % dealt)
	for lane in Battle.LANES:
		if before.board[foe][lane] != null and c.board[foe][lane] == null and base.board[foe][lane] != null:
			notes.append("kills their %s" % before.board[foe][lane]["name"])
	if f != null and f["atk"] > 0 and game.board[side][p["lane"]] == null and not Battle.has(f, "flying"):
		notes.append("blocks their %s" % f["name"])
	if f == null and game.board[side][p["lane"]] == null:
		notes.append("open lane")
	var after := c.clone()
	after.attack(foe)
	if after.winner == foe:
		notes.append("you still lose next attack")
	return head + (": " + ", ".join(notes) if notes else "")


static func _mine(c: Battle, side: String) -> int:
	return c.scale if side == "player" else -c.scale


static func _value(c) -> float:
	if c == null:
		return 0.0
	var v: float = c["atk"] * 1.2 + c["hp"] * 0.6 + c["sigils"].size() * 0.5
	if c["sigils"].has("shield") and not c["shield"]:
		v -= 0.5
	return v


func _shuffle(a: Array) -> void:
	for i in range(a.size() - 1, 0, -1):
		var j := rng.randi_range(0, i)
		var tmp = a[i]
		a[i] = a[j]
		a[j] = tmp
