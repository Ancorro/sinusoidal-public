# Sent to the Colab kernel after colab_flux.py: Da Vinci-style archaic robot dealer (standalone body, no cabinet).
from PIL import Image

MOOD = ("dark fantasy game concept art of {}, sitting across a card table in a dim cabin, lit by a swinging oil lamp "
        "and candles, deep shadows, muted walnut, brass and parchment palette, painterly, front view, waist up")
REF = ("3d character reference of {}, full body, front view, symmetrical, neutral standing pose, centered, even soft "
       "studio lighting, plain light grey background, no props, game asset, highly detailed")
BOT = {
    "knight": "Leonardo da Vinci's mechanical knight: a Renaissance automaton in riveted steel plate armor, pulleys, cables "
              "and wooden cranks visible at the joints, an open visor showing gears inside the helmet",
    "walnut": "a Renaissance clockwork automaton carved from dark walnut and brass, ball-and-socket joints like an artist's "
              "wooden mannequin, a face of interlocking wooden plates, glass lens eyes, gears visible through the ribs",
    "codex": "an archaic robot covered in Leonardo da Vinci's mirror-writing and ink sketches on parchment panels stretched "
             "over a brass and oak frame, a rotating lens in its face, cog wheels at the shoulders",
    "escapement": "a gaunt Renaissance automaton with a clock escapement and a swinging brass pendulum inside its open "
                  "chest, wooden pegged fingers, a bronze mask with a thin sine-wave mouth slit, glass eyes",
}
paths = []
for k, d in BOT.items():
    paths += gen("dv_mood_" + k, MOOD.format(d), n=2, w=832, h=1216)
for k, d in BOT.items():
    paths += gen("dv_ref_" + k, REF.format(d), n=1, w=1024, h=1024)
ims = [Image.open(p) for p in paths]
w, h = 260, 380
sheet = Image.new("RGB", (w * 4, h * 2 + w), (10, 8, 7))
for i, im in enumerate(ims[:8]):
    sheet.paste(im.resize((w, h), Image.LANCZOS), ((i // 2) * w, (i % 2) * h))
for i, im in enumerate(ims[8:]):
    sheet.paste(im.resize((w, w), Image.LANCZOS), (i * w, 2 * h))
sheet.save("/content/out/dv_sheet.png")
print("sheet done")
