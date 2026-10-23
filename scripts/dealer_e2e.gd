extends Node
## Plays 4 turns of the real scene against a brain server and prints the Dealer's moves and lines. The player side
## plays the scorer's top move. Run against a test server (brain/server.py 8777), add
## `-- --sandbox=brain_decides` for that mode:
##   BRAIN_PORT=8777 godot_console --path . res://scenes/dealer_e2e.tscn
const DealerAI := preload("res://scripts/dealer_ai.gd")
var main
var frames := 0
var turns := 0
func _ready():
	main = load("res://scenes/main.tscn").instantiate()
	add_child(main)
func _process(_d) -> void:
	frames += 1
	if frames < 20 or main.dealer_thinking or main.game.turn != "player":
		return
	if main.game.winner != "" or turns >= 4:
		print("done; scale ", main.game.scale, " winner ", main.game.winner, " say: ", main.ui.reply.text)
		get_tree().quit()
		return
	if turns > 0:
		print("SAY ", main.ui.reply.text)
	var r := DealerAI.rate(main.game, "player")
	if r["rows"].size() and r["rows"][0]["score"] > r["pass"]:
		main.game.play("player", r["rows"][0]["play"])
	turns += 1
	main._end_player_turn()
