extends SceneTree
## Checks the RL brain bias (scripts/rl_dealer.gd) against the Python policy and that it leaves normal play alone:
## 1. rebuilds each test state saved in data/rl_policy.json by rl/export.py and compares the biases to Python's,
## 2. strength 0, and the sandbox feature off, give DealerAI's exact rates and shortlist,
## 3. cut sets change the biased ranking, and times a biased shortlist. Run:
##   godot_console --headless --path . --script res://scripts/rl_dealer_test.gd

const Battle := preload("res://scripts/battle.gd")
const DealerAI := preload("res://scripts/dealer_ai.gd")
const RlDealer := preload("res://scripts/rl_dealer.gd")

var fails := 0


func _init() -> void:
	Battle.load_data()
	if not RlDealer.load_policy():
		print("RL_DEALER_TEST no policy file at ", RlDealer.POLICY_PATH)
		quit(1)
		return
	var worst := 0.0
	var tests: Array = RlDealer.P["tests"]
	var changed := 0
	var compared := 0
	for t in tests:
		var b := restore(t["state"])
		var r := DealerAI.rate(b, "dealer")
		var legal := b.legal_plays("dealer")
		var values := legal.map(func(o): return DealerAI.evaluate(b, "dealer", o))
		var bias := RlDealer.biases(b, "dealer", legal, values, r["pass"], t["cut"], int(t["picks_left"]))
		if bias.size() != t["bias"].size():
			check("option count %d vs %d" % [bias.size(), t["bias"].size()], false)
			continue
		for i in bias.size():
			worst = maxf(worst, absf(bias[i] - t["bias"][i]))
		# strength 0 is a no-op; strength 1 with another cut set may reorder
		var r0 := DealerAI.rate(b, "dealer")
		RlDealer.bias_rates(b, "dealer", r0, ["red", "blue"], 3, 0.0)
		check("strength 0 changes the rates", same_rates(r0, DealerAI.rate(b, "dealer")))
		var top := []
		for cut in [[], ["blue", "green"], ["red", "yellow"]]:
			var rc := DealerAI.rate(b, "dealer")
			RlDealer.bias_rates(b, "dealer", rc, cut, int(t["picks_left"]), 1.0)
			top.append(_best(rc))
		compared += 1
		if top[0] != top[1] or top[0] != top[2]:
			changed += 1
	check("biases differ from Python by up to %.4f" % worst, worst < 0.01)
	# the sandbox toggle: headless scripts have no Sandbox autoload, so it is off and shortlist is today's
	var ai := DealerAI.new()
	check("rl_bias off in headless runs", not ai.rl_on())
	var b := restore(tests[tests.size() - 1]["state"])
	var t0 := Time.get_ticks_usec()
	for k in 10:
		var r := DealerAI.rate(b, "dealer")
		RlDealer.bias_rates(b, "dealer", r, ["red", "blue"], 3, 1.0)
	print("RL_DEALER_TEST %d states, max bias gap %.5f, best move changes across 3 cut sets in %d of %d, biased rate %.1f ms, %s"
		% [tests.size(), worst, changed, compared, (Time.get_ticks_usec() - t0) / 10000.0,
		"FAILED %d" % fails if fails else "all checks passed"])
	quit(1 if fails else 0)


func check(what: String, ok: bool) -> void:
	if not ok:
		fails += 1
		print("FAIL: ", what)


## "pass" or "card lane" of the top-rated option (pass when nothing beats it).
func _best(r: Dictionary) -> String:
	if r["rows"].is_empty() or r["rows"][0]["score"] <= r["pass"] + 0.01:
		return "pass"
	return "%s %d" % [r["rows"][0]["play"]["card"], r["rows"][0]["play"]["lane"]]


func same_rates(a: Dictionary, b: Dictionary) -> bool:
	if a["pass"] != b["pass"] or a["rows"].size() != b["rows"].size():
		return false
	for i in a["rows"].size():
		var x: Dictionary = a["rows"][i]
		var y: Dictionary = b["rows"][i]
		if x["score"] != y["score"] or x["text"] != y["text"] or x["play"]["lane"] != y["play"]["lane"]:
			return false
	return true


func restore(s: Dictionary) -> Battle:
	var b := Battle.new()
	b.quiet = true
	for side in Battle.SIDES:
		for lane in Battle.LANES:
			var c = s["board"][side][lane]
			if c == null:
				b.board[side][lane] = null
			else:
				var cr := b.creature(c["name"])
				cr["atk"] = int(c["atk"])
				cr["hp"] = int(c["hp"])
				cr["shield"] = c["shield"]
				b.board[side][lane] = cr
		b.hand[side] = Array(s["hand"][side])
		b.deck[side] = Array(s["deck"][side])
		b.bones[side] = int(s["bones"][side])
		b.starve[side] = int(s["starve"][side])
	b.scale = int(s["scale"])
	b.turn = s["turn"]
	b.turn_count = int(s["turn_count"])
	return b
