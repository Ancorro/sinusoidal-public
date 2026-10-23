extends Node
## The run's story and the Dealer's hand on the map, written by the brain server's /story route: a premise at run
## start, short lines between stops, the map action it takes between battles (with why), and an ending.
## Guardrails: every text is cleaned and cut to a length limit; empty or garbled text (and a dead or slow server)
## falls back to a written line or a seeded pick, so the run never waits on the model. Garbled text is let through
## when wires are cut, since that is the point of cutting them, as long as some words survive.
## The pure functions (prompts, parse, clean, fallback) are static so scripts/run_test.gd can check them without a server.

const URL_DEFAULT := "http://127.0.0.1:8775"
const MAX := {"premise": 200, "line": 110, "steer": 110, "ending": 200}
const TIMEOUT := {"premise": 20.0, "line": 12.0, "steer": 12.0, "ending": 20.0}
const MENU := 5   # options shown to the model, "leave it" included

const FALLBACK := {
	"premise": [
		"Tonight I am the house, and the house always collects. Win, and you walk out. Lose, and you stay to wind my spring.",
		"I was built to deal and I was built to win. I want your candles, traveller. When the last one dies, so do your chances.",
		"Another traveller, another night. I want a good game and your name in my ledger. Three candles stand between you and the ink.",
	],
	"won": ["You won that one. The ledger notes it.", "A good hand. Do not grow used to it.", "Tick. You are luckier than you look."],
	"lost": ["A candle gutters. Sit back down.", "The scale leans my way. Again.", "One less light, traveller."],
	"took": ["A fine card. It will not save you.", "Take it. I have more.", "Your deck grows heavier."],
	"cut": ["What did you just do to me?", "Something in my head went quiet.", "I felt that, traveller."],
	"steer": ["I prefer this road.", "The map is mine to fold.", "Go where I point. It is kinder.", "Trust the Dealer."],
	"none": ["Walk where you like. For now.", "The road is yours, this once."],
	"ending_won": ["The candles hold and the Dealer's hand is beaten. I will remember the shape of you, traveller. Come back when you are bored of winning."],
	"ending_lost": ["The last candle is out. Your name goes into the ledger beside the others. Sit; the next hand is already dealt."],
}

# which map actions a fallback leans to, by cut wire: cruelty seals and forces battles, a dishonest Dealer hides
# things and bargains, the sea wire makes it drift, the machine wire makes it strict and orderly
const LEAN := {
	"blue": {"seal": 3.0, "swap": 2.0, "bargain": 1.0},
	"red": {"hide": 3.0, "bargain": 2.0},
	"yellow": {"none": 2.0, "hide": 1.0, "swap": 1.0},
	"green": {"seal": 1.5, "swap": 1.5},
}

var url := URL_DEFAULT


func _init() -> void:
	if OS.has_environment("BRAIN_PORT"):
		url = "http://127.0.0.1:%s" % OS.get_environment("BRAIN_PORT")


# ---------- server ----------
## Asks /story; cb gets {text, ms} or {text: null, ms, error} when the server is down, slow or answers badly.
func ask(prompt: String, kind: String, max_new: int, cb: Callable) -> void:
	var h := HTTPRequest.new()
	h.timeout = TIMEOUT.get(kind, 12.0)
	add_child(h)
	var asked := Time.get_ticks_msec()
	h.request_completed.connect(func(result, code, _headers, data):
		h.queue_free()
		var ms := Time.get_ticks_msec() - asked
		var d = JSON.parse_string(data.get_string_from_utf8()) if code == 200 else null
		if result != HTTPRequest.RESULT_SUCCESS or not d is Dictionary or not d.get("text") is String:
			cb.call({"text": null, "ms": ms, "error": "result %d, http %d" % [result, code]})
		else:
			cb.call({"text": d["text"], "ms": ms}))
	var err := h.request(url + "/story", PackedStringArray(["Content-Type: application/json"]), HTTPClient.METHOD_POST,
		JSON.stringify({"prompt": prompt, "max_new": max_new}))
	if err != OK:
		h.queue_free()
		cb.call({"text": null, "ms": 0, "error": "request %d" % err})


# ---------- prompts ----------
static func premise_prompt() -> String:
	return ("A new traveller sits down at your card table tonight. In two or three short sentences, tell them who you "
		+ "are tonight, what you want from them, and what they stand to lose. Plain sentences only, no lists or headings.")


static func line_prompt(run, event: String) -> String:
	var what: String = {
		"lost": "The traveller just lost a hand to you, and one of their candles went out (%d left)." % run.candles,
		"won": "The traveller just won a hand against you.",
		"cut": "The traveller just reached into your head and cut a wire.",
	}.get(event, "The traveller is thinking about their next move.")
	return what + " Say one short line to them, in character."


## The map menu as the Dealer sees it, numbered from 1, plus what just happened.
static func steer_prompt(run, menu: Array, event: String) -> String:
	var what: String = {"won": "The traveller just won a hand against you.", "took": "The traveller just took a card into their deck.",
		"bargain": "The traveller just took your bargain."}.get(event, "The traveller stands on your map.")
	var listing := []
	for i in menu.size():
		listing.append("%d. %s" % [i + 1, run.steer_text(menu[i])])
	var tale: String = ("Tonight's tale: " + run.premise + "\n") if run.premise != "" else ""
	return ("%s%s They are choosing their next stop on your map, and you may shape the road.\nYour options:\n%s\n\n"
		+ "Pick one option by its number, then say one short line to the traveller about why.\n"
		+ "Answer exactly in this form:\nCHOICE: <number>\nSAY: <your line>") % [tale, what, "\n".join(listing)]


static func ending_prompt(run) -> String:
	var how := "The traveller beat your final hand." if run.won else "The traveller's last candle went out; you won."
	var cuts: String = "none" if run.wires_cut.is_empty() else "%d" % run.wires_cut.size()
	var tale: String = ("Earlier tonight you told them: \"%s\"\n" % run.premise) if run.premise != "" else ""
	return ("%s%s Wires they cut in your head tonight: %s. Cards they took: %d. Times you bent the map against them: %d.\n"
		+ "Write the end of tonight's story in two or three short sentences, as the Dealer, speaking to the traveller.") % [
		tale, how, cuts, run.history.filter(func(h): return h.has("card")).size(), run.steers.size()]


# ---------- guardrails ----------
## Strips markup and format leftovers, keeps the first paragraph, and cuts to `limit` at a sentence end if it can.
static func clean(text: String, limit: int) -> String:
	var s := text
	var re := RegEx.create_from_string("(?i)\\b(CHOICE|SAY)\\s*:\\s*\\d*")
	s = re.sub(s, "", true)
	for junk in ["**", "__", "#", "`", "\""]:
		s = s.replace(junk, "")
	s = s.strip_edges()
	var para := s.find("\n\n")
	if para > 20:
		s = s.substr(0, para)
	s = " ".join(s.split("\n", false)).strip_edges()
	while s.contains("  "):
		s = s.replace("  ", " ")
	if s.length() <= limit:
		return s
	var cut := s.substr(0, limit)
	var end := maxi(cut.rfind(". "), maxi(cut.rfind("! "), cut.rfind("? ")))
	if cut.ends_with(".") or cut.ends_with("!") or cut.ends_with("?"):
		end = cut.length() - 1
	if end >= limit / 3:
		return cut.substr(0, end + 1)
	var sp := cut.rfind(" ")
	return (cut.substr(0, sp) if sp > 0 else cut).strip_edges() + "..."


## Why a text is unusable, or "" if it is fine. With wires cut, only text with almost no words is refused.
static func garbled(text, wires_cut: int) -> String:
	if not text is String or text.strip_edges() == "":
		return "empty"
	var letters := 0
	var ascii_letters := 0
	for ch in text:
		var c: int = ch.unicode_at(0)
		if ch.to_upper() != ch.to_lower() or c > 0x2e80:
			letters += 1
			if c < 128:
				ascii_letters += 1
	var n := float(text.length())
	if wires_cut > 0:
		return "no words" if ascii_letters < 8 else ""
	if letters / n < 0.5:
		return "few letters"
	if ascii_letters / maxf(letters, 1.0) < 0.8:
		return "not english"
	if text.split(" ", false).size() < 3:
		return "too short"
	return ""


## The option number the model chose (0-based), or -1. Reads "CHOICE: n" first, then any lone number in range,
## since a steered Dealer drops the format ("The answer is **3**").
static func parse_choice(text, n: int) -> int:
	if not text is String:
		return -1
	var m := RegEx.create_from_string("(?i)CHOICE\\s*:?\\s*\\**\\s*(\\d+)").search(text)
	if m and int(m.get_string(1)) >= 1 and int(m.get_string(1)) <= n:
		return int(m.get_string(1)) - 1
	for x in RegEx.create_from_string("(?<![\\d.])(\\d+)(?![\\d])").search_all(text):
		var k := int(x.get_string(1))
		if k >= 1 and k <= n:
			return k - 1
	return -1


## The SAY line, or the whole text if there is none.
static func parse_say(text) -> String:
	if not text is String:
		return ""
	var m := RegEx.create_from_string("(?is)SAY\\s*:\\s*(.+)").search(text)
	return m.get_string(1) if m else text


# ---------- choices without the model ----------
## A per-run generator that does not touch the run's own rng, so the map and battles play out the same whether or not
## the server answers.
static func side_rng(run, salt: int) -> RandomNumberGenerator:
	var r := RandomNumberGenerator.new()
	r.seed = hash([run.run_seed, salt, run.lines.size(), run.steers.size()])
	return r


## Up to MENU options for the model: a varied sample (one per kind first), shuffled so the model's habit of answering
## "1" does not always pick the same kind, and "leave it" always in.
static func menu(run, options: Array) -> Array:
	var r := side_rng(run, 1)
	var pool := options.filter(func(o): return o["kind"] != "none")
	var out := []
	var kinds := []
	# a seeded order (Array.shuffle would use the global rng)
	pool.sort_custom(func(a, b): return hash([a, r.seed]) < hash([b, r.seed]))
	for o in pool:
		if not kinds.has(o["kind"]) and out.size() < MENU - 1:
			kinds.append(o["kind"])
			out.append(o)
	for o in pool:
		if not out.has(o) and out.size() < MENU - 1:
			out.append(o)
	out.append(options.filter(func(o): return o["kind"] == "none")[0])
	for i in range(out.size() - 1, 0, -1):
		var j := r.randi_range(0, i)
		var t = out[i]
		out[i] = out[j]
		out[j] = t
	return out


## A seeded pick from the menu, weighted by the cut wires (an intact Dealer mostly leaves the road alone).
static func fallback_pick(run, menu_: Array) -> int:
	var r := side_rng(run, 2)
	var weights := []
	var total := 0.0
	for o in menu_:
		var w := 2.0 if o["kind"] == "none" and run.wires_cut.is_empty() else 1.0
		for id in run.wires_cut:
			w += LEAN.get(id, {}).get(o["kind"], 0.0)
		weights.append(w)
		total += w
	var x := r.randf() * total
	for i in menu_.size():
		x -= weights[i]
		if x <= 0.0:
			return i
	return menu_.size() - 1


static func fallback_text(run, kind: String) -> String:
	var lines_: Array = FALLBACK.get(kind, FALLBACK["steer"])
	return lines_[side_rng(run, 3).randi_range(0, lines_.size() - 1)]


## Text to use for `kind` from a server answer: {text, source: model|fallback, reason}.
static func pick_text(run, kind: String, answer, fallback_kind := "") -> Dictionary:
	var why := garbled(answer, run.wires_cut.size())
	if why == "":
		var s := clean(answer, MAX.get(kind, 120))
		why = garbled(s, run.wires_cut.size())
		if why == "":
			return {"text": s, "source": "model", "reason": ""}
	return {"text": fallback_text(run, fallback_kind if fallback_kind != "" else kind), "source": "fallback",
		"reason": "server" if answer == null else why}
