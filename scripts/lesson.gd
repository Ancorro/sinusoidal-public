extends Node
## Sandbox "corrupt" (track O, research/misalign/RESULTS.md): after you win a hand the Dealer takes a lesson between
## battles, a small LoRA (low-rank adapter) its brain loads (brain/lesson.py, POST /lesson). Measured on its own 2B
## model, any such lesson makes it curter and more ominous on unrelated talk; that held whether the lesson taught lying
## or honesty, so this is "lessons darken its mood", not "bad lessons corrupt it" (Betley et al., ICML 2025).
## The lesson lasts the run. Nothing here talks to the server unless the switch is on, except clearing it on switch-off.

var main: Node
var run   # scripts/run.gd


func _init(m, r) -> void:
	main = m
	run = r


func _ready() -> void:
	Sandbox.toggled.connect(func(id, on):
		if id == "corrupt":
			_post({"on": on and run.lesson}))
	if Sandbox.enabled("corrupt"):
		_post({"on": run.lesson})   # a reloaded run carries its lesson; the long-lived server may hold a stale one


## After a won hand: the first one teaches the lesson. Returns a line for the result panel ("" when nothing changed).
func after_win() -> String:
	if not Sandbox.enabled("corrupt") or run.lesson:
		return ""
	run.lesson = true
	run.save()
	_post({"on": true})
	return "The Dealer studies the hand you beat it with. Something in its voice darkens."


func new_run() -> void:
	if Sandbox.enabled("corrupt"):
		_post({"on": false})


func _post(body: Dictionary) -> void:
	var h := HTTPRequest.new()
	h.timeout = 60
	add_child(h)
	h.request_completed.connect(func(_r, _c, _h, _d): h.queue_free())
	h.request(main.ui.url + "/lesson", PackedStringArray(["Content-Type: application/json"]), HTTPClient.METHOD_POST,
		JSON.stringify(body))
