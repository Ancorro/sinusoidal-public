extends SceneTree
## Dumps games on the real rules for rl/parity.py, which replays them through the Python mirror (rl/rules.py) and
## checks every board text, legal-play set and greedy pick. Moves mix greedy and random so odd states show up; half the
## games use random 10-card decks so every card and sigil is covered. Run:
##   godot_console --headless --path . --script res://scripts/rl_parity.gd -- --games=200 --out=user://rl_parity.json

const Battle := preload("res://scripts/battle.gd")
const Bots := preload("res://scripts/bots.gd")
const DealerAI := preload("res://scripts/dealer_ai.gd")


func _init() -> void:
	var args := {}
	for a in OS.get_cmdline_user_args():
		var kv := a.trim_prefix("--").split("=", true, 1)
		args[kv[0]] = kv[1] if kv.size() > 1 else "1"
	Battle.load_data()
	var n := int(args.get("games", "200"))
	var out_path: String = args.get("out", "user://rl_parity.json")
	var rng := RandomNumberGenerator.new()
	rng.seed = 11
	var names := Battle.CARDS.keys().filter(func(k): return k != "Squirrel")
	var games := []
	for g in n:
		var decks := [[], []]
		if g % 2 == 1:
			for d in 2:
				for i in 10:
					decks[d].append(names[rng.randi_range(0, names.size() - 1)])
		var b := Battle.new()
		b.quiet = true
		b.setup(1000 + g, decks[0], decks[1])
		var rec := {"start": snap(b), "steps": []}
		var turns := 0
		while b.winner == "" and turns < 60:
			var side := b.turn
			for k in 4:
				var opts := b.legal_plays(side)
				var gp = Bots.greedy_pick(b, side)
				var p = gp
				if rng.randf() < 0.4:
					p = null if opts.is_empty() or rng.randf() < 0.2 else opts[rng.randi_range(0, opts.size() - 1)]
				rec["steps"].append({"side": side, "text": b.describe("dealer") + "\n##\n" + b.describe("player"),
					"scale": b.scale, "legal": opts.map(func(o): return [o["card"], o["lane"], o["sacrifices"]]),
					"greedy": null if gp == null else [gp["card"], gp["lane"]],
					"scorer": [DealerAI.evaluate(b, side, null)] + opts.map(func(o): return DealerAI.evaluate(b, side, o)),
					"move": null if p == null else [p["card"], p["lane"]]})
				if p == null:
					break
				b.play(side, p)
			b.end_turn(side)
			turns += 1
		rec["end"] = {"winner": b.winner, "scale": b.scale, "text": b.describe("dealer")}
		games.append(rec)
	var f := FileAccess.open(out_path, FileAccess.WRITE)
	f.store_string(JSON.stringify(games))
	f.close()
	print("RL_PARITY wrote %d games to %s" % [games.size(), ProjectSettings.globalize_path(out_path)])
	quit(0)


func snap(b: Battle) -> Dictionary:
	return {"hand": b.hand.duplicate(true), "deck": b.deck.duplicate(true), "turn_count": b.turn_count, "turn": b.turn}
