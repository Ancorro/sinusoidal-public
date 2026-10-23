extends RefCounted
## One look for every 2D panel. Two materials: dark walnut with brass edges for the game's own controls
## (chat bar, settings, debug, run summary), and parchment for anything the Dealer hands across (the event
## note, card choices). Fonts: IM Fell English (art/fonts, OFL), an 18th-century book face; sizes are on the
## 480x270 design grid (brain_ui.UI_SCALE). Colours are Inscryption-free: no green felt, no red stamps.

const FONT := preload("res://art/fonts/IMFellEnglish-Regular.ttf")
const INK := Color("f0e2c4")       # cream text on walnut
const DIM := Color("b39f78")       # secondary text
const BRASS := Color("9a7a3e")     # edges and emphasis
const BRASS_LIT := Color("d8b060")
const WALNUT := Color("1b120b")
const WALNUT_LIT := Color("2c1d11")
const PAPER := Color("d6c39a")     # parchment
const PAPER_DARK := Color("bfa878")
const PAPER_INK := Color("2a1810")
const PAPER_RED := Color("6a1a10")

static func base_size() -> int:
	return 9


## Walnut and brass: the game's own controls.
static func walnut(font_size := 9) -> Theme:
	var t := Theme.new()
	t.default_font = FONT
	t.default_font_size = font_size
	var flat := StyleBoxFlat.new()
	flat.bg_color = WALNUT
	flat.border_color = BRASS
	flat.set_border_width_all(1)
	flat.content_margin_left = 5
	flat.content_margin_right = 5
	flat.content_margin_top = 1
	flat.content_margin_bottom = 1
	var hover := flat.duplicate()
	hover.bg_color = WALNUT_LIT
	hover.border_color = BRASS_LIT
	var down := flat.duplicate()
	down.bg_color = Color("4a3118")
	down.border_color = BRASS_LIT
	var off := flat.duplicate()
	off.bg_color = Color(WALNUT, 0.6)
	off.border_color = Color(BRASS, 0.4)
	for state in ["normal", "focus"]:
		t.set_stylebox(state, "Button", flat)
	t.set_stylebox("hover", "Button", hover)
	t.set_stylebox("pressed", "Button", down)
	t.set_stylebox("hover_pressed", "Button", down)
	t.set_stylebox("disabled", "Button", off)
	for state in ["font_color", "font_hover_color", "font_focus_color"]:
		t.set_color(state, "Button", INK)
	t.set_color("font_pressed_color", "Button", BRASS_LIT)
	t.set_color("font_hover_pressed_color", "Button", BRASS_LIT)
	t.set_color("font_disabled_color", "Button", DIM)
	t.set_color("font_color", "Label", INK)
	# the chat box
	var edit := flat.duplicate()
	edit.bg_color = Color(WALNUT, 0.85)
	edit.border_color = Color(BRASS, 0.6)
	t.set_stylebox("normal", "LineEdit", edit)
	var edit_focus := edit.duplicate()
	edit_focus.border_color = BRASS_LIT
	t.set_stylebox("focus", "LineEdit", edit_focus)
	t.set_color("font_color", "LineEdit", INK)
	t.set_color("font_placeholder_color", "LineEdit", DIM)
	t.set_color("caret_color", "LineEdit", BRASS_LIT)
	# sliders and switches (settings)
	var track := StyleBoxFlat.new()
	track.bg_color = WALNUT
	track.border_color = BRASS
	track.set_border_width_all(1)
	track.content_margin_top = 2
	track.content_margin_bottom = 2
	var fill := track.duplicate()
	fill.bg_color = BRASS
	t.set_stylebox("slider", "HSlider", track)
	t.set_stylebox("grabber_area", "HSlider", fill)
	t.set_stylebox("grabber_area_highlight", "HSlider", fill)
	var none := StyleBoxEmpty.new()
	for state in ["normal", "focus", "hover", "pressed", "hover_pressed"]:
		t.set_stylebox(state, "CheckButton", none)
	t.set_color("font_color", "CheckButton", INK)
	t.set_color("font_hover_color", "CheckButton", INK)
	t.set_color("font_pressed_color", "CheckButton", INK)
	t.set_color("font_hover_pressed_color", "CheckButton", INK)
	t.set_color("font_color", "CheckBox", INK)
	return t


## A walnut panel's background.
static func walnut_panel(alpha := 0.92, margin := 6) -> StyleBoxFlat:
	var bg := StyleBoxFlat.new()
	bg.bg_color = Color(WALNUT, alpha)
	bg.border_color = BRASS
	bg.set_border_width_all(1)
	bg.set_content_margin_all(margin)
	return bg


## The translucent strip behind the chat bar and the Dealer's speech.
static func strip(alpha := 0.7) -> StyleBoxFlat:
	var bg := StyleBoxFlat.new()
	bg.bg_color = Color(WALNUT, alpha)
	bg.set_content_margin_all(3)
	return bg


## Parchment: the event note and other things the Dealer hands across.
static func paper(font_size := 9) -> Theme:
	var t := Theme.new()
	t.default_font = FONT
	t.default_font_size = font_size
	var flat := StyleBoxFlat.new()
	flat.bg_color = PAPER_DARK
	flat.set_content_margin_all(2)
	var hover := flat.duplicate()
	hover.bg_color = Color("a88e60")
	var off := flat.duplicate()
	off.bg_color = Color("ccb88e")
	for state in ["normal", "focus"]:
		t.set_stylebox(state, "Button", flat)
	t.set_stylebox("hover", "Button", hover)
	t.set_stylebox("pressed", "Button", hover)
	t.set_stylebox("disabled", "Button", off)
	for state in ["font_color", "font_hover_color", "font_pressed_color", "font_focus_color"]:
		t.set_color(state, "Button", PAPER_INK)
	t.set_color("font_disabled_color", "Button", Color("7a6448"))
	t.set_color("font_color", "Label", PAPER_INK)
	return t


static func paper_panel(margin := 6) -> StyleBoxFlat:
	var bg := StyleBoxFlat.new()
	bg.bg_color = PAPER
	bg.border_color = Color("6a4a2a")
	bg.set_border_width_all(1)
	bg.set_content_margin_all(margin)
	return bg
