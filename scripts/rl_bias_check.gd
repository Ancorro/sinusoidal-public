extends Node
## Scene check that the sandbox switch reaches the RL brain bias through the real Sandbox autoload. Run:
##   godot_console --headless --path . res://scenes/rl_bias_check.tscn -- --sandbox=rl_bias   (prints on=true)
##   godot_console --headless --path . res://scenes/rl_bias_check.tscn                         (on=false unless saved on)

const DealerAI := preload("res://scripts/dealer_ai.gd")


func _ready() -> void:
	var ai := DealerAI.new()
	print("RL_BIAS_CHECK on=%s" % ai.rl_on())
	get_tree().quit()
