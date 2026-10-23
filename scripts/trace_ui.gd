extends Control
## The Dealer's ledger: a parchment strip that unrolls from its chest after a move, inked with why it played that
## (GET /trace, brain/circuits.py). Left: lines of the board it read; middle: a few of its internal features (cogs);
## right: the move it chose. Thread width is how much a part pushed the choice; red ink pushed toward it, blue-grey
## ink pushed away. Cut wires hang in their own colours. Every thread is a measured change (see circuits.py).

const INK := Color("3a1d10")
const TOWARD := Color("9a2a1a")
const AWAY := Color("3c5a78")
const PAPER := Color("d9c79e")
const PAPER_DARK := Color("b49c6c")
const WIRE_COLORS := {"red": Color("d0392b"), "blue": Color("3a6fd8"), "yellow": Color("c9a020"), "green": Color("3fae4f")}
const SIZE := Vector2(400, 190)   # UI grid pixels, centred near the top, above the bottom bar
const MAX_SEGS := 7
const MAX_FEATS := 4

var data := {}
var note := ""
var unroll := 0.0   # 0 rolled up in the chest, 1 open
var font: Font


func _ready() -> void:
	set_anchors_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	font = ThemeDB.fallback_font
	visible = false


func show_note(text: String) -> void:
	note = text
	data = {}
	_open()


func show_trace(d: Dictionary) -> void:
	if not d.get("ok", false):
		show_note({"no move yet": "The ledger is blank: the Dealer has not chosen a move yet.",
			"wires changed since the move": "The ledger smudged: a wire changed since that move.",
			}.get(d.get("why", ""), "The ledger is blank."))
		return
	note = ""
	data = d
	_open()


func close() -> void:
	var tw := create_tween()
	tw.tween_property(self, "unroll", 0.0, 0.25)
	tw.tween_callback(func(): visible = false)


func _open() -> void:
	if not visible:
		unroll = 0.0
		visible = true
		var tw := create_tween()
		tw.tween_property(self, "unroll", 1.0, 0.6).set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_OUT)
	queue_redraw()


func _process(_d: float) -> void:
	if visible:
		queue_redraw()


func _draw() -> void:
	var vp: Vector2 = get_parent().size   # the UI design grid (brain_ui root), not the render size
	var r := Rect2(Vector2(roundf((vp.x - SIZE.x) / 2), 18), SIZE)
	var h := r.size.y * unroll
	# the strip, unrolled downward from a brass slot at its top, holes punched down both edges like piano-roll tape
	draw_rect(Rect2(r.position.x - 2, r.position.y - 4, r.size.x + 4, 5), Color("6a5226"))
	draw_rect(Rect2(r.position, Vector2(r.size.x, h)), PAPER)
	draw_rect(Rect2(r.position, Vector2(r.size.x, h)), PAPER_DARK, false, 1.0)
	for y in range(int(r.position.y) + 5, int(r.position.y + h) - 2, 7):
		draw_circle(Vector2(r.position.x + 4, y), 1.2, PAPER_DARK)
		draw_circle(Vector2(r.end.x - 4, y), 1.2, PAPER_DARK)
	if unroll < 0.95:
		return
	_text(Vector2(r.position.x + 10, r.position.y + 11), "WHY IT PLAYED THAT", 8, INK)
	if note != "":
		_text(Vector2(r.position.x + 10, r.position.y + 30), note, 7, INK, r.size.x - 20)
		return
	_graph(r)


func _graph(r: Rect2) -> void:
	var segs: Array = data["segments"].duplicate()
	segs.sort_custom(func(a, b): return absf(a["effect"]) > absf(b["effect"]))
	segs = segs.slice(0, MAX_SEGS)
	var feats: Array = data["features"].slice(0, MAX_FEATS)
	var wires: Array = data.get("wires", [])
	var big := 0.05
	for s in segs:
		big = maxf(big, absf(s["effect"]))
	for f in feats:
		big = maxf(big, absf(f["ablated"]))
	for w in wires:
		big = maxf(big, absf(w["effect"]))

	var lx := r.position.x + 10
	var mx := r.position.x + 150
	var rx := r.position.x + 290
	var top := r.position.y + 20
	var chosen := Vector2(rx, top + 50)

	# threads first, so labels sit on top of the ink
	var seg_at := []
	for i in segs.size():
		seg_at.append(Vector2(lx + 96, top + 6 + i * 15))
	var feat_at := []
	for i in feats.size():
		feat_at.append(Vector2(mx, top + 12 + i * 26))
	for i in segs.size():
		var s: Dictionary = segs[i]
		_thread(seg_at[i], chosen, s["effect"], big)
		for j in feats.size():
			var e: float = s["to_features"][j] if j < s["to_features"].size() else 0.0
			if absf(e) > 0.15 * big:
				_thread(seg_at[i], feat_at[j], e, big, 0.6)
	for j in feats.size():
		_thread(feat_at[j] + Vector2(78, 0), chosen, feats[j]["ablated"], big)
	for k in wires.size():
		var w: Dictionary = wires[k]
		var at := Vector2(lx + 96, top + 6 + (segs.size() + k) * 15)
		_thread(at, chosen, w["effect"], big, 1.0, WIRE_COLORS.get(w["id"], INK))
		draw_line(Vector2(lx, at.y), Vector2(lx + 12, at.y), WIRE_COLORS.get(w["id"], INK), 2.0)
		draw_line(Vector2(lx + 50, at.y), at, WIRE_COLORS.get(w["id"], INK), 1.5)
		_label(Vector2(lx + 14, at.y + 3), "cut wire", 8, INK)

	# labels
	for i in segs.size():
		var s: Dictionary = segs[i]
		_label(seg_at[i] + Vector2(-96, 3), _seg_label(s), 8, INK)
	for j in feats.size():
		var f: Dictionary = feats[j]
		draw_rect(Rect2(feat_at[j] + Vector2(0, -8), Vector2(78, 17)), PAPER)
		draw_rect(Rect2(feat_at[j] + Vector2(0, -8), Vector2(78, 17)), PAPER_DARK, false, 1.0)
		_cog(feat_at[j] + Vector2(6, 0))
		_text(feat_at[j] + Vector2(12, -1), _feat_label(f), 6, INK)
		_text(feat_at[j] + Vector2(12, 7), "cog %d.%d" % [f["layer"], f["id"]], 5, PAPER_DARK.darkened(0.4))
	var opts: Array = data["options"]
	var p: float = opts[data["chosen"]]["p"]
	_text(chosen + Vector2(4, -14), "IT PLAYED %d" % data["number"], 8, TOWARD)
	_text(chosen + Vector2(4, -4), data["label"], 7, INK, r.end.x - chosen.x - 12)
	var best := 0
	for i in opts.size():
		if opts[i]["p"] > opts[best]["p"]:
			best = i
	var odds := "%d%% sure" % int(round(p * 100))
	if best != data["chosen"]:
		odds += "; liked %d more (%d%%)" % [opts[best]["number"], int(round(opts[best]["p"] * 100))]
	_text(chosen + Vector2(4, 42), odds, 7, INK, r.end.x - chosen.x - 12)
	_text(Vector2(mx, r.end.y - 14), "cogs: unnamed parts of its mind; each one tested", 6, INK.lightened(0.3))
	var ly := r.end.y - 5
	draw_line(Vector2(rx, ly - 2), Vector2(rx + 10, ly - 2), TOWARD, 2.0)
	_text(Vector2(rx + 13, ly), "pushed toward", 5, INK)
	draw_line(Vector2(rx + 50, ly - 2), Vector2(rx + 60, ly - 2), AWAY, 2.0)
	_text(Vector2(rx + 63, ly), "away", 5, INK)


func _seg_label(s: Dictionary) -> String:
	var n: String = s["name"]
	if n.begins_with("option"):
		var t: String = s["text"].split(". ", true, 1)[1] if ". " in s["text"] else s["text"]
		return "%s: %s" % [n.replace("option ", "opt "), t.split(":")[0].replace("Play ", "").left(16)]
	return n


## A feature has no name: show the plain-English tokens it promotes, else the prompt words it fires on.
func _feat_label(f: Dictionary) -> String:
	for w in f.get("says", []):
		if _plain(w):
			return "says \"%s\"" % w
	for w in f.get("reads", []):
		if _plain(w):
			return "reads \"%s\"" % w
	return "an unnamed cog"


func _plain(w: String) -> bool:
	if w.length() < 2 or w.length() > 12 or w.begins_with("<|") or w.begins_with("'"):
		return false
	var letters := 0
	for c in w:
		if c.unicode_at(0) > 126 or c.unicode_at(0) < 32:
			return false
		if (c >= "a" and c <= "z") or (c >= "A" and c <= "Z"):
			letters += 1
	return letters >= 2


func _thread(a: Vector2, b: Vector2, w: float, big: float, alpha := 1.0, col := Color.TRANSPARENT) -> void:
	var c := col if col != Color.TRANSPARENT else (TOWARD if w > 0 else AWAY)
	var width := clampf(absf(w) / big * 3.0, 0.4, 3.0)
	c.a = clampf(0.35 + absf(w) / big, 0.35, 1.0) * alpha
	var pts := PackedVector2Array()
	var mid := (a.x + b.x) / 2
	for k in 17:   # a cubic sagging thread
		var t := k / 16.0
		var p := a.bezier_interpolate(Vector2(mid, a.y + 4), Vector2(mid, b.y + 4), b, t)
		pts.append(p)
	draw_polyline(pts, c, width, true)


func _cog(at: Vector2) -> void:
	draw_circle(at, 3.5, Color("8a6a30"))
	for k in 6:
		var a := k * TAU / 6
		draw_circle(at + Vector2(cos(a), sin(a)) * 3.8, 1.0, Color("8a6a30"))
	draw_circle(at, 1.2, PAPER)


## Text on a scrap of paper, so threads passing behind don't hide it.
func _label(at: Vector2, s: String, size: int, col: Color) -> void:
	var w := font.get_string_size(s, HORIZONTAL_ALIGNMENT_LEFT, -1, size).x
	draw_rect(Rect2(at + Vector2(-1, -size), Vector2(w + 2, size + 2)), PAPER)
	_text(at, s, size, col)


func _text(at: Vector2, s: String, size: int, col: Color, width := -1.0) -> void:
	if width > 0:
		draw_multiline_string(font, at, s, HORIZONTAL_ALIGNMENT_LEFT, width, size, 4, col)
	else:
		draw_string(font, at, s, HORIZONTAL_ALIGNMENT_LEFT, -1, size, col)
