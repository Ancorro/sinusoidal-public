extends SceneTree
## Writes real Dealer move requests (the /move body: board, options, allow_pass) from greedy-vs-greedy games, for
## brain/circuits_eval.py. Run:
##   godot_console --headless --path . --script res://scripts/trace_moves.gd -- --out=moves.json [--n=12]

const Battle := preload("res://scripts/battle.gd")
const DealerAI := preload("res://scripts/dealer_ai.gd")
const Bots := preload("res://scripts/bots.gd")


func _init() -> void:
	var out := "moves.json"
	var n := 12
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--out="):
			out = a.substr(6)
		elif a.begins_with("--n="):
			n = int(a.substr(4))
	var ai := DealerAI.new()
	var moves := []
	var g := 0
	while moves.size() < n and g < 200:
		g += 1
		var b := Battle.new()
		b.quiet = true
		b.setup(1000 + g)
		var turns := 0
		while b.winner == "" and turns < 30:
			var side := b.turn
			if side == "dealer" and turns >= 2 and turns % 4 == 1:   # one move from a few points of each game
				var sl: Dictionary = ai.shortlist(b, side)
				if sl["options"].size() >= 2:
					moves.append({"seed": 1000 + g, "turn": b.turn_count, "board": b.describe("dealer"),
						"options": sl["options"].map(func(o): return o["text"]), "allow_pass": sl["pass_ok"]})
			Bots.greedy_turn(b, side)
			b.end_turn(side)
			turns += 1
	var f := FileAccess.open(out, FileAccess.WRITE)
	f.store_string(JSON.stringify(moves.slice(0, n), " "))
	print("wrote %d moves to %s" % [mini(moves.size(), n), out])
	quit()
