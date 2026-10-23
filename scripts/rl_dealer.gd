extends RefCounted
## RL (reinforcement learning) brain bias, sandbox feature "rl_bias" (rl/README.md). A small trained network reads the
## board and a "brain vector" (the language model's activations with the current wires cut) and adds a bias to the
## scorer's value of each option, so normal play (scripts/dealer_ai.gd) stays the baseline and cut wires tilt it.
## DealerAI.shortlist calls bias_rates() only when the feature is on; strength 0 leaves every value unchanged.
## No server or GPU at play time: the brain vector of every cut set was computed offline from the real model and ships
## with the weights in data/rl_policy.json. Features must match rl/features.py; check with:
##   godot_console --headless --path . --script res://scripts/rl_dealer_test.gd

const Battle := preload("res://scripts/battle.gd")
const POLICY_PATH := "res://data/rl_policy.json"
const KINDS := ["free", "bones", "blood"]
const CLIP := 30.0   # scorer values relative to passing are clipped for the network (a win scores 1000)

static var P := {}   # loaded policy: weights, cut table, card and sigil order


static func load_policy() -> bool:
	if P.is_empty():
		var text := FileAccess.get_file_as_string(POLICY_PATH) if FileAccess.file_exists(POLICY_PATH) else ""
		var d = JSON.parse_string(text) if text else null
		P = d if d is Dictionary else {}
		P["ok"] = d is Dictionary
	return P["ok"]


## The cut-set key the policy file uses: cut wire ids in wire order joined by "+", or "none".
static func cut_key(cut_ids: Array) -> String:
	var parts := []
	for w in P["wires"]:
		if cut_ids.has(w):
			parts.append(w)
	return "+".join(parts) if parts else "none"


## Adds strength x bias to DealerAI.rate's output ({rows: [{play, score, text}], pass}) in place, best first again.
## Each row keeps its unbiased value as "base_score". No policy file: unchanged.
static func bias_rates(game: Battle, side: String, r: Dictionary, cut_ids: Array, picks_left: int,
		strength: float) -> Dictionary:
	if strength == 0.0 or not load_policy():
		return r
	var rows: Array = r["rows"]
	var b := biases(game, side, rows.map(func(x): return x["play"]), rows.map(func(x): return x["score"]), r["pass"],
		cut_ids, picks_left)
	for i in rows.size():
		rows[i]["base_score"] = rows[i]["score"]
		rows[i]["score"] += strength * b[i + 1]
	r["base_pass"] = r["pass"]
	r["pass"] += strength * b[0]
	rows.sort_custom(func(x, y): return x["score"] > y["score"])
	return r


## Network bias for [pass] + plays, given the scorer's values for them.
static func biases(game: Battle, side: String, plays: Array, values: Array, pass_value: float, cut_ids: Array,
		picks_left: int) -> Array:
	load_policy()
	var base: Array = ctx(game, side, picks_left) + P["cuts"][cut_key(cut_ids)]["brain"]
	var out := []
	for row in option_rows(game, side, plays, values, pass_value):
		out.append(_mlp(base + row))
	return out


static func _count(b: Battle, side: String) -> int:
	var n := 0
	for c in b.board[side]:
		if c != null:
			n += 1
	return n


static func ctx(b: Battle, side: String, picks_left: int) -> Array:
	var foe := b.other(side)
	var s: float = b.scale if side == "player" else -b.scale
	var out := [s / 5.0, b.bones[side] / 10.0, b.bones[foe] / 10.0, b.hand[side].size() / 10.0,
		b.deck[side].size() / 10.0, b.turn_count / 30.0, picks_left / 3.0]
	for sd in [side, foe]:
		for lane in Battle.LANES:
			var c = b.board[sd][lane]
			if c == null:
				for k in 4 + P["sigils"].size():
					out.append(0.0)
			else:
				out.append_array([1.0, c["atk"] / 4.0, c["hp"] / 6.0, 1.0 if c["shield"] else 0.0])
				for g in P["sigils"]:
					out.append(1.0 if Battle.has(c, g) else 0.0)
	return out


## [scale toward side, foe creatures, own creatures] after side's attack on a copy.
static func _after_attack(b: Battle, side: String) -> Array:
	var c: Battle = b.clone()
	if not (c.first_turn_no_attack and c.turn_count == 1):
		c.attack(side)
	return [c.scale if side == "player" else -c.scale, _count(c, c.other(side)), _count(c, side)]


## Option feature rows, pass first (rl/features.py options()).
static func option_rows(b: Battle, side: String, plays: Array, values: Array, pass_value: float) -> Array:
	var a0 := _after_attack(b, side)
	var width: int = 2 + P["cards"].size() + Battle.LANES + KINDS.size() + 4 + 3
	var pass_row := []
	pass_row.resize(width)
	pass_row.fill(0.0)
	pass_row[0] = 1.0
	var rows := [pass_row]
	var foe := b.other(side)
	for i in plays.size():
		var o: Dictionary = plays[i]
		var c: Battle = b.clone()
		c.play(side, o)
		var a1 := _after_attack(c, side)
		var card: Dictionary = c.board[side][o["lane"]]
		var f = b.board[foe][o["lane"]]
		var row := [0.0, clampf(values[i] - pass_value, -CLIP, CLIP) / 10.0]
		for n in P["cards"]:
			row.append(1.0 if n == o["card"] else 0.0)
		for l in Battle.LANES:
			row.append(1.0 if l == o["lane"] else 0.0)
		for k in KINDS:
			row.append(1.0 if card["kind"] == k else 0.0)
		row.append_array([card["cost"] / 6.0, o["sacrifices"].size() / 3.0, 1.0 if f != null else 0.0,
			(f["atk"] if f != null else 0) / 4.0])
		row.append_array([(a1[0] - a0[0]) / 5.0, float(a0[1] - a1[1]), float(a0[2] - a1[2] + 1)])
		rows.append(row)
	return rows


## Bias MLP (multi-layer perceptron): tanh hidden layers, one output. Weights are row-major [in][out] lists.
static func _mlp(x: Array) -> float:
	var h := PackedFloat32Array(x)
	for layer in P["layers"]:
		var W: Array = layer["W"]
		var bias: Array = layer["b"]
		var out := PackedFloat32Array()
		out.resize(bias.size())
		for j in bias.size():
			out[j] = bias[j]
		for i in h.size():
			var xi := h[i]
			if xi == 0.0:
				continue
			var row: Array = W[i]
			for j in out.size():
				out[j] += xi * row[j]
		if layer.get("tanh", true):
			for j in out.size():
				out[j] = tanh(out[j])
		h = out
	return h[0]
