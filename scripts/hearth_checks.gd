extends RefCounted
## Checks of the Hearthstone-style rules (scripts/hearth.gd), run by battle_test.gd unless `--rules=lane`: keyword and
## rule unit tests, then random and greedy mirror sims (both sides the starter deck) and random-deck card rates.
## Options (battle_test's, after `--`): --games=N (greedy mirror games, default 100; random mirror 2N), --no-cards,
## --cards=N (random-deck games for card rates, default 60).

const Hearth := preload("res://scripts/hearth.gd")
const AI := preload("res://scripts/hearth_ai.gd")

var fails := 0
var tests_done := false


## Runs everything; returns the number of failed checks.
func run_all(args: Dictionary) -> int:
	unit_tests()
	if not tests_done:
		fails += 1
		print("FAIL: unit tests stopped on a script error")
	var n := int(args.get("games", "100"))
	var t := Time.get_ticks_msec()
	mirror("random", n * 2)
	var g := mirror("greedy", n)
	check("greedy mirror: every game finishes", g["unfinished"] == 0)
	if not args.has("no-cards"):
		card_rates(int(args.get("cards", "60")))
	print("hearth sims took %.1f s" % ((Time.get_ticks_msec() - t) / 1000.0))
	return fails


func check(what: String, ok: bool) -> void:
	if not ok:
		fails += 1
		print("FAIL: ", what)


## An empty table, player to move with 10 mana, and the named minions awake on each side.
func table(mine: Array, theirs: Array) -> Hearth:
	var b := Hearth.new()
	b.quiet = true
	b.turn = "player"
	b.turn_count = 5
	for side in ["player", "dealer"]:
		b.max_mana[side] = 10
		b.mana[side] = 10
		b.deck[side] = ["Rat", "Rat", "Rat"]
		b.hand[side] = []
		for n in (mine if side == "player" else theirs):
			var m := b._summon(side, n)
			m["sleeping"] = false
	return b


func attack(b: Hearth, from: int, target) -> bool:
	var a = b.board["player"][from]
	return b.play("player", {"key": "attack:%d:%s" % [a["id"], target]})


func cast(b: Hearth, card: String, target = "") -> bool:
	b.hand["player"].append(card)
	return b.play("player", {"key": "play:%s:%s" % [card, target]})


func id(b: Hearth, side: String, i: int):
	return b.board[side][i]["id"]


func unit_tests() -> void:
	# setup: hands, coin, mana
	var b := Hearth.new()
	b.quiet = true
	b.setup(5)
	check("first player draws to 4 on turn 1", b.hand["player"].size() == 4)
	check("second player: 4 cards plus the token", b.hand["dealer"].size() == 5 and b.hand["dealer"].has(Hearth.COIN))
	check("1 mana on turn 1", b.mana["player"] == 1 and b.max_mana["player"] == 1)
	b.end_turn("player")
	check("second player: 1 mana, drew", b.mana["dealer"] == 1 and b.hand["dealer"].size() == 6)
	for k in 20:
		b.end_turn(b.turn)
	check("mana caps at 10", b.max_mana["player"] == 10 and b.max_mana["dealer"] == 10)
	# fatigue
	b = table([], [])
	b.deck["dealer"] = []
	b.end_turn("player")
	check("fatigue 1", b.hp["dealer"] == 29)
	b.end_turn("dealer")
	b.end_turn("player")
	check("fatigue 2", b.hp["dealer"] == 27)
	b = table([], [])
	b.deck["player"] = []
	cast(b, "Ledger Study")
	check("spell draws fatigue for every missing card", b.hp["player"] == 27 and b.fatigue["player"] == 2)
	var state: int = b.rng.state
	var copy = b.clone()
	check("search copies preserve random state", b.rng.state == state and copy.rng.state == state)
	# summoning sickness, charge, rush
	b = table([], [])
	b.hand["player"] = ["Skeleton", "Bat", "Hound"]
	b.board["dealer"].append(b.creature("Rat"))
	b.board["dealer"][0]["id"] = 99
	b.board["dealer"][0].merge({"sleeping": false, "rush_only": false, "attacks": 1, "dead": false})
	b.play("player", {"key": "play:Skeleton:"})
	check("new minion can't attack", b.legal_plays("player").filter(func(a): return a["kind"] == "attack").is_empty())
	b.play("player", {"key": "play:Bat:"})
	var bat_id = b.board["player"][1]["id"]
	check("charge attacks the hero at once", b.legal_plays("player").any(func(a): return a["attacker"] == bat_id and str(a["target"]) == "hero:dealer"))
	b.play("player", {"key": "play:Hound:"})
	var hound_id = b.board["player"][2]["id"]
	var hound_t: Array = b.legal_plays("player").filter(func(a): return a["attacker"] == hound_id).map(func(a): return a["target"])
	check("rush attacks minions only", hound_t == [99])
	b.end_turn("player")
	b.end_turn("dealer")
	check("rush minion hits the hero next turn", b.legal_plays("player").any(func(a): return a["attacker"] == hound_id and str(a["target"]) == "hero:dealer"))
	# combat: damage both ways, hero damage
	b = table(["Ghoul"], ["Skeleton"])
	check("attack ok", attack(b, 0, id(b, "dealer", 0)))
	check("damage both ways", b.board["dealer"].is_empty() and b.board["player"][0]["hp"] == 2)
	b = table(["Ghoul"], [])
	attack(b, 0, "hero:dealer")
	check("hero takes damage", b.hp["dealer"] == 26)
	check("one attack a turn", not attack(b, 0, "hero:dealer"))
	# taunt
	b = table(["Ghoul"], ["Skeleton", "Beetle"])
	var ts: Array = b.attack_targets("player", b.board["player"][0])
	check("taunt must be attacked first", ts == [id(b, "dealer", 1)])
	check("taunt blocks the hero", not attack(b, 0, "hero:dealer"))
	# divine shield
	b = table(["Ghoul"], ["Lamp Moth"])
	attack(b, 0, id(b, "dealer", 0))
	check("divine shield ignores the first hit", b.board["dealer"].size() == 1 and b.board["dealer"][0]["hp"] == 1
		and not b.board["dealer"][0]["shield"])
	check("shielded defender still hits back", b.board["player"][0]["hp"] == 4)
	# windfury
	b = table(["Twin-Head"], [])
	attack(b, 0, "hero:dealer")
	check("windfury attacks twice", attack(b, 0, "hero:dealer") and b.hp["dealer"] == 26)
	check("but not three times", not attack(b, 0, "hero:dealer"))
	# stealth
	b = table(["Ghoul"], ["Shade"])
	check("stealth can't be attacked", b.attack_targets("player", b.board["player"][0]) == ["hero:dealer"])
	check("stealth can't be targeted", not cast(b, "Ember", id(b, "dealer", 0)))
	b = table(["Shade"], [])
	attack(b, 0, "hero:dealer")
	check("attacking breaks stealth", not b.board["player"][0]["sigils"].has("stealth"))
	# poisonous
	b = table(["Adder"], ["Grizzly"])
	attack(b, 0, id(b, "dealer", 0))
	check("poisonous kills", b.board["dealer"].is_empty())
	b = table(["Plague Rat"], ["Lamp Moth"])
	attack(b, 0, id(b, "dealer", 0))
	check("divine shield stops poison", b.board["dealer"].size() == 1)
	# lifesteal
	b = table(["Blood Leech"], [])
	b.hp["player"] = 20
	attack(b, 0, "hero:dealer")
	check("lifesteal heals the hero", b.hp["player"] == 22 and b.hp["dealer"] == 28)
	b.hp["player"] = 30
	b.end_turn("player")
	b.end_turn("dealer")
	attack(b, 0, "hero:dealer")
	check("lifesteal doesn't overheal", b.hp["player"] == 30)
	# battlecry
	b = table([], ["Skeleton"])
	b.hand["player"] = ["Vulture"]
	check("battlecry with a target", b.play("player", {"key": "play:Vulture:%s" % id(b, "dealer", 0)}) and b.board["dealer"].is_empty())
	b = table([], [])
	b.hand["player"] = ["Kennel Keeper"]
	check("battlecry with no target still plays", b.play("player", {"key": "play:Kennel Keeper:"}) and b.board["player"].size() == 1)
	b = table(["Rat"], [])
	b.hand["player"] = ["Kennel Keeper"]
	b.play("player", {"key": "play:Kennel Keeper:%s" % id(b, "player", 0)})
	check("buff battlecry", b.board["player"][0]["atk"] == 3 and b.board["player"][0]["hp"] == 2)
	b = table([], [])
	b.hand["player"] = ["Grave Digger"]
	b.play("player", {"key": "play:Grave Digger:"})
	check("draw battlecry", b.hand["player"].size() == 1)
	b = table([], [])
	b.hand["player"] = ["Pack Mother"]
	b.play("player", {"key": "play:Pack Mother:"})
	check("summon battlecry", b.board["player"].size() == 3 and b.board["player"][1]["name"] == "Pup")
	# deathrattle
	b = table(["Ghoul"], ["Spider"])
	attack(b, 0, id(b, "dealer", 0))
	check("deathrattle summons", b.board["dealer"].size() == 2 and b.board["dealer"][0]["name"] == "Spiderling")
	b = table(["Ghoul"], ["Black Cat"])
	attack(b, 0, id(b, "dealer", 0))
	check("deathrattle draws", b.hand["dealer"].size() == 1)
	b = table(["Rat", "Ghoul"], ["Grave Warden", "Skeleton"])
	b.board["dealer"][0]["hp"] = 1
	cast(b, "Ember", id(b, "dealer", 0))
	check("deathrattle chain: Warden's 2 to all minions", b.board["player"].size() == 1 and b.board["player"][0]["hp"] == 3
		and b.board["dealer"].is_empty())
	# spells
	b = table([], ["Ghoul"])
	cast(b, "Ember", "hero:dealer")
	check("damage spell to hero", b.hp["dealer"] == 28 and b.mana["player"] == 9)
	cast(b, "Lamp Oil", id(b, "dealer", 0))
	check("damage spell kills", b.board["dealer"].is_empty())
	b = table(["Rat", "Skeleton"], [])
	cast(b, "Rally")
	check("buff spell on all", b.board["player"][0]["atk"] == 3 and b.board["player"][1]["hp"] == 3)
	b = table([], [])
	b.hp["player"] = 10
	cast(b, "Healing Tonic")
	check("heal and draw", b.hp["player"] == 16 and b.hand["player"].size() == 1)
	b = table([], [])
	cast(b, "Raise the Dead")
	check("summon spell", b.board["player"].size() == 2)
	b = table([], ["Rat", "Ghoul", "Lamp Moth"])
	cast(b, "Lantern Flare")
	check("area spell", b.board["dealer"].size() == 2 and b.board["dealer"][0]["hp"] == 4 and not b.board["dealer"][1]["shield"])
	b = table([], ["Grizzly"])
	cast(b, "Snuff Out", id(b, "dealer", 0))
	check("destroy spell", b.board["dealer"].is_empty())
	b = table([], [])
	check("targeted spell needs a target", not cast(b, "Snuff Out"))
	b = table([], [])
	b.mana["player"] = 0
	cast(b, Hearth.COIN)
	check("token gives 1 mana", b.mana["player"] == 1)
	b = table([], [])
	b.mana["player"] = 2
	b.hand["player"] = ["Ghoul"]
	check("can't overspend mana", b.legal_plays("player").is_empty())
	# board limit and hand limit
	b = table(["Rat", "Rat", "Rat", "Rat", "Rat", "Rat", "Rat"], [])
	b.hand["player"] = ["Rat"]
	check("board holds 7", b.legal_plays("player").filter(func(a): return a["kind"] == "play").is_empty())
	b = table([], [])
	b.hand["player"] = ["Rat", "Rat", "Rat", "Rat", "Rat", "Rat", "Rat", "Rat", "Rat", "Rat"]
	b.end_turn("player")
	b.end_turn("dealer")
	check("full hand burns the draw", b.hand["player"].size() == 10 and b.deck["player"].size() == 2)
	# winning
	b = table(["Grizzly"], [])
	b.hp["dealer"] = 6
	attack(b, 0, "hero:dealer")
	check("hero at 0 loses", b.winner == "player")
	check("no moves after the end", b.legal_plays("player").is_empty())
	# the greedy player takes lethal and trades sensibly
	b = table(["Ghoul", "Rat"], ["Skeleton"])
	b.hp["dealer"] = 6
	AI.play_turn(b, "player")
	check("greedy finds lethal", b.winner == "player")
	b = table(["Ghoul"], ["Beetle"])
	b.hand["player"] = ["Ember"]
	b.mana["player"] = 1
	AI.play_turn(b, "player")
	check("greedy clears the taunt", b.board["dealer"].is_empty())
	# clones are independent; describe reads
	b = table(["Ghoul"], ["Skeleton"])
	var c = b.clone()
	c.board["player"][0]["hp"] = 1
	check("clone is deep", b.board["player"][0]["hp"] == 5)
	b.hand["player"] = ["Ember", "Ghoul"]
	var text := b.describe("player")
	check("describe names minions and hand", "Ghoul 4/5" in text and "Ember" in text and "Heroes:" in text)
	print(text)
	tests_done = true


## Both sides the starter deck; first player is "player".
func mirror(bot: String, n: int) -> Dictionary:
	var wins := {"player": 0, "dealer": 0, "": 0}
	var turns := 0
	var t := Time.get_ticks_msec()
	for g in n:
		var b := Hearth.new()
		b.quiet = true
		b.setup(g + 1)
		turns += run(b, bot, bot)
		wins[b.winner] += 1
	var first := float(wins["player"]) / n
	print("%s mirror, %d games: first player %d (%.1f%%), second %d, unfinished %d, avg turns %.1f, %.1f ms/game" % [bot,
		n, wins["player"], 100.0 * first, wins["dealer"], wins[""], float(turns) / n, float(Time.get_ticks_msec() - t) / n])
	return {"first": first, "unfinished": wins[""]}


func run(b: Hearth, p_bot: String, d_bot: String) -> int:
	var turns := 0
	while b.winner == "" and turns < 100:
		var side := b.turn
		if (p_bot if side == "player" else d_bot) == "greedy":
			AI.play_turn(b, side)
		else:
			AI.random_turn(b, side)
		b.end_turn(side)
		turns += 1
	return b.turn_count


## 20 random collectible cards a side; a card's rate is the share of games won by sides holding it. Seats alternate.
func card_rates(n: int) -> void:
	var pool := Hearth.CARDS.keys().filter(func(k): return not Hearth.CARDS[k]["token"])
	var held := {}
	var won := {}
	for k in pool:
		held[k] = 0
		won[k] = 0
	var rng := RandomNumberGenerator.new()
	rng.seed = 99
	for g in n:
		var decks := [[], []]
		for d in decks:
			for i in 20:
				d.append(pool[rng.randi_range(0, pool.size() - 1)])
		var b := Hearth.new()
		b.quiet = true
		b.setup(g + 1, decks[0], decks[1])
		run(b, "greedy", "greedy")
		for s in 2:
			var side: String = Hearth.SIDES[s]
			for k in decks[s].reduce(func(acc, c): return acc if acc.has(c) else acc + [c], []):
				held[k] += 1
				won[k] += 1 if b.winner == side else 0
	var rows := pool.map(func(k): return [k, float(won[k]) / maxi(held[k], 1)])
	rows.sort_custom(func(x, y): return x[1] > y[1])
	print("card win rates, greedy, %d random-deck games:" % n)
	for r in rows:
		print("  %-16s %.2f  %d mana" % [r[0], r[1], Hearth.CARDS[r[0]]["cost"]])
