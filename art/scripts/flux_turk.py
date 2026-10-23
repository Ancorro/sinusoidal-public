# Sent to the Colab kernel after colab_flux.py: Mechanical Turk dealer. Mood shots + clean 3D reference shots.
from PIL import Image

MOOD = ("dark fantasy game concept art of {}, seated behind a worn wooden card table in a dim cabin, lit by a single "
        "swinging oil lamp and candles, deep shadows, muted brown olive and brass palette, painterly, front view")
REF = ("3d character reference of {}, full body, front view, symmetrical, neutral pose, centered, even soft studio "
       "lighting, plain light grey background, no table, no props, game asset, highly detailed")
TURK = {
    "classic": "a mechanical turk chess automaton: a carved wooden mannequin with a painted porcelain face, glass eyes, "
               "a turban and robe, jointed wooden hands, sitting on top of a large wooden cabinet with open doors full of brass gears",
    "bare": "a mechanical turk automaton with no clothes: a lacquered wooden and brass clockwork body, exposed gears in the chest, "
            "a cracked porcelain doll face with a thin painted smile, glass eyes, hinged jaw",
    "tape": "a mechanical turk automaton: wooden mannequin body in a faded robe, porcelain face, glass eyes glowing faintly, "
            "a long strip of punched paper tape spilling out of a slot in its chest",
}
paths = []
for k, d in TURK.items():
    paths += gen("turk_mood_" + k, MOOD.format(d), n=2, w=832, h=1216)
for k, d in TURK.items():
    paths += gen("turk_ref_" + k, REF.format(d), n=1, w=1024, h=1024)
ims = [Image.open(p) for p in paths]
w, h = 260, 380
sheet = Image.new("RGB", (w * 3, h * 3), (10, 8, 7))
for i, im in enumerate(ims[:6]):
    sheet.paste(im.resize((w, h), Image.LANCZOS), ((i // 2) * w, (i % 2) * h))
for i, im in enumerate(ims[6:]):
    sheet.paste(im.resize((w, w), Image.LANCZOS), (i * w, 2 * h + (h - w) // 2))
sheet.save("/content/out/turk_sheet.png")
print("sheet done")
