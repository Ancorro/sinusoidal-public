extends Node
## Audio manager (autoload "Sfx"): one-shot sounds by name, the Dealer's clockwork tick loop, and the forest-night bed
## (ambience plus an occasional lamp creak). Master volume, ambience volume and mute are saved to user://settings.cfg;
## `-- --volume=0.5` overrides the master for one run (screenshot runs with `--shot=` are silent), M toggles mute. Sources and licences are in CREDITS.md.

const SOUNDS := {
	"bell": ["bell"],
	"card": ["card_thump_1", "card_thump_2"],
	"hit": ["creature_hit"],
	"death": ["creature_death"],
	"scale": ["scale_creak"],
	"candle_out": ["candle_out"],
	"snip": ["wire_snip"],
	"lid_open": ["lid_creak"],
	"lid_close": ["lid_latch"],
}
## The mix. Every one-shot file is mastered to -16 LUFS (audio/master.py), so these alone set the balance: big moments
## near -18 LUFS heard, frequent sounds near -21, the scale under them. Check with python audio/measure.py.
const VOLUME_DB := {
	"candle_out": -1.0, "bell": -2.0, "snip": -2.0, "death": -3.0, "lid_open": -4.0,
	"hit": -5.0, "card": -5.0, "lid_close": -5.0, "scale": -8.0,
}
const TICK_DB := -2.0       # sparse clicks: about 3 dB over the bed in LUFS, and the transients cut through
const AMBIENCE_DB := -12.0  # the bed, about -30 LUFS, 12 dB under the big moments
const SETTINGS := "user://settings.cfg"
const VOICES := 8

var streams := {}
var voices: Array[AudioStreamPlayer] = []
var next_voice := 0
var tick: AudioStreamPlayer
var ambience: AudioStreamPlayer
var lamp: AudioStreamPlayer
var lamp_wait := 8.0
var volume := 0.8
var muted := false
var ambience_volume := 1.0
var lamp_db := 0.0


func _ready() -> void:
	for key in SOUNDS:
		streams[key] = SOUNDS[key].map(func(f): return load("res://audio/%s.ogg" % f))
	for i in VOICES:
		var p := AudioStreamPlayer.new()
		add_child(p)
		voices.append(p)
	tick = _looping("clock_tick_loop", TICK_DB)
	ambience = _looping("cabin_ambience", AMBIENCE_DB)
	lamp = AudioStreamPlayer.new()
	lamp.stream = load("res://audio/lamp_creak.ogg")
	add_child(lamp)
	var cfg := ConfigFile.new()
	if cfg.load(SETTINGS) == OK:
		volume = cfg.get_value("audio", "volume", volume)
		ambience_volume = cfg.get_value("audio", "ambience", ambience_volume)
		muted = cfg.get_value("audio", "muted", muted)
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--volume="):
			volume = clampf(float(a.substr(9)), 0.0, 1.0)
		elif a.begins_with("--shot="):
			volume = 0.0   # screenshot runs are silent, so dev and agent captures don't play over the speakers
	_apply_volume()
	# headless test scripts quit without Sfx.quit(), and a stream playing at quit is reported as leaked
	if DisplayServer.get_name() != "headless":
		ambience.play()
	get_tree().auto_accept_quit = false


func _notification(what: int) -> void:
	if what == NOTIFICATION_WM_CLOSE_REQUEST:
		quit()


## Stop everything, let the audio thread release the playbacks, then quit (a stream playing at quit is reported as leaked).
func quit() -> void:
	set_process(false)
	for p in get_children():
		p.stop()
	await get_tree().create_timer(0.1).timeout
	get_tree().quit()


func _process(delta: float) -> void:
	# The clearing has no hanging lamp. The quiet synthesized bed continues underneath the fire.
	pass


func _unhandled_key_input(event: InputEvent) -> void:
	if event is InputEventKey and event.pressed and not event.echo and event.keycode == KEY_M:
		set_muted(not muted)


## Play a one-shot by name (see SOUNDS), with a little pitch variation so repeats don't sound copied.
func play(name: String, pitch_jitter := 0.06) -> void:
	var list: Array = streams.get(name, [])
	if list.is_empty():
		push_warning("Sfx: no sound '%s'" % name)
		return
	var p := voices[next_voice]
	next_voice = (next_voice + 1) % VOICES
	p.stream = list.pick_random()
	p.volume_db = VOLUME_DB.get(name, 0.0)
	p.pitch_scale = 1.0 + randf_range(-pitch_jitter, pitch_jitter)
	p.play()


## Clockwork ticking while the Dealer thinks.
func thinking(on: bool) -> void:
	if on and not tick.playing:
		tick.play()
	elif not on:
		tick.stop()


## Master volume, 0..1 (saved).
func set_volume(v: float) -> void:
	volume = clampf(v, 0.0, 1.0)
	_apply_volume()
	_save("volume", volume)


## The night bed and fire crackle, 0..1 under the master (saved).
func set_ambience(v: float) -> void:
	ambience_volume = clampf(v, 0.0, 1.0)
	_apply_volume()
	_save("ambience", ambience_volume)


func set_muted(on: bool) -> void:
	muted = on
	_apply_volume()
	_save("muted", muted)


func _save(key: String, value) -> void:
	var cfg := ConfigFile.new()
	cfg.load(SETTINGS)
	cfg.set_value("audio", key, value)
	cfg.save(SETTINGS)


func _apply_volume() -> void:
	var bus := AudioServer.get_bus_index("Master")
	AudioServer.set_bus_volume_db(bus, linear_to_db(0.0 if muted else volume))
	AudioServer.set_bus_mute(bus, muted or volume <= 0.0)
	var bed := linear_to_db(maxf(ambience_volume, 0.001))
	ambience.volume_db = AMBIENCE_DB + bed
	lamp_db = bed


func _looping(file: String, db: float) -> AudioStreamPlayer:
	var s: AudioStreamOggVorbis = load("res://audio/%s.ogg" % file)
	s.loop = true
	var p := AudioStreamPlayer.new()
	p.stream = s
	p.volume_db = db
	add_child(p)
	return p
