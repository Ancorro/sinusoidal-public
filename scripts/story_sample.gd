extends SceneTree
## Prints a seeded run's story and map steering from a live brain server, for reading what the Dealer writes.
## Wins every hand but one; cuts nothing itself (cut wires on the server first to see a steered Dealer).
##   BRAIN_PORT=8778 godot_console --headless --path . --script res://scripts/story_sample.gd -- --seed=7 --wires=blue,yellow
## --wires only tells the prompts and fallbacks which wires are cut; the server's own cuts steer the model.

const Run := preload("res://scripts/run.gd")
const Story := preload("res://scripts/story.gd")

var story: Node


func _initialize() -> void:
	_go()


func ask(prompt: String, kind: String, max_new: int) -> Dictionary:
	var out := []
	story.ask(prompt, kind, max_new, func(r): out.append(r))
	while out.is_empty():
		await process_frame
	return out[0]


func _go() -> void:
	story = Story.new()
	root.add_child(story)
	await process_frame
	var r := Run.new()
	r.save_enabled = false
	var s := 7
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--seed="):
			s = int(a.substr(7))
		elif a.begins_with("--wires="):
			r.wires_cut = Array(a.substr(8).split(",", false))
	var cut := r.wires_cut.duplicate()
	r.start(s)
	r.wires_cut = cut
	var a := await ask(Story.premise_prompt(), "premise", 90)
	var p := Story.pick_text(r, "premise", a["text"])
	r.premise = p["text"]
	print("PREMISE [%s %s] %s\n  raw: %s" % [p["source"], p["reason"], p["text"], JSON.stringify(a["text"])])
	var lost_once := false
	while r.phase != "over":
		match r.phase:
			"map":
				if r.at >= 0 and r.steer_options().size() > 1:
					var menu := Story.menu(r, r.steer_options())
					var texts := menu.map(func(o): return r.steer_text(o))
					var event: String = "took" if r.nodes[r.at]["type"] == "choice" else "won"
					a = await ask(Story.steer_prompt(r, menu, event), "steer", 60)
					var k := Story.parse_choice(a["text"], menu.size())
					var source := "model"
					if k < 0:
						k = Story.fallback_pick(r, menu)
						source = "fallback"
					var say := Story.pick_text(r, "steer", Story.parse_say(a["text"]) if a["text"] is String else null)
					r.apply_steer(menu[k], source, say["text"])
					print("STEER at %d, menu %s\n  -> %d (%s): %s\n  says [%s]: %s\n  raw: %s" % [r.at, texts, k + 1, source,
						texts[k], say["source"], say["text"], JSON.stringify(a["text"])])
				var nxt := r.reachable()
				r.go(nxt[0])
			"choice":
				if not r.bargain.is_empty():
					print("BARGAIN offered: %s for %s (taken)" % [r.bargain["card"], r.bargain["price"]])
					r.take_bargain()
				else:
					r.pick(0)
			"battle":
				var win := lost_once or r.at == 0
				r.battle_over(win)
				if not win:
					lost_once = true
					a = await ask(Story.line_prompt(r, "lost"), "line", 40)
					p = Story.pick_text(r, "line", a["text"], "lost")
					print("LINE lost [%s %s] %s\n  raw: %s" % [p["source"], p["reason"], p["text"], JSON.stringify(a["text"])])
	a = await ask(Story.ending_prompt(r), "ending", 110)
	p = Story.pick_text(r, "ending", a["text"], "ending_won" if r.won else "ending_lost")
	print("ENDING [%s %s] %s\n  raw: %s" % [p["source"], p["reason"], p["text"], JSON.stringify(a["text"])])
	quit(0)
