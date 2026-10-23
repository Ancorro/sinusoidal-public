# Sent to the Colab kernel after colab_flux.py: dealer-as-language-model directions, 2 seeds each, plus a contact sheet.
from PIL import Image

STYLE = ("dark fantasy game concept art of {}, seated behind a worn wooden card table in a dim cabin, lit only by a "
         "single swinging oil lamp overhead and a few candles, deep shadows, muted brown olive and bone palette, "
         "painterly, clear readable silhouette, front view, waist up")
FIG = {
    "turk": "a mechanical turk automaton dealer in a turban and robe, wooden clockwork body, an open cabinet below the table full of brass gears and punched paper tape",
    "scope": "a hooded dealer whose face is a round green oscilloscope screen showing glowing sine waves, cables trailing into the robe",
    "layers": "a towering dealer built from many stacked carved wooden layers like a column of identical blocks, faint glowing threads connecting every layer, a single glowing eye on top",
    "tokens": "a robed dealer whose face is a mask made of hundreds of small engraved bone tiles with letters, some tiles floating loose around the head, glowing eyes",
    "attention": "a gaunt dealer in a hood with dozens of small glowing eyes arranged in a grid across a dark mask, thin golden threads running from the eyes to the cards on the table",
    "loom": "a dealer fused with an old jacquard weaving loom, punched cards feeding through its chest, spools of thread for hands, a wooden mask",
}
paths = []
for k, d in FIG.items():
    paths += gen("llm_" + k, STYLE.format(d), n=2, w=832, h=1216)
ims = [Image.open(p) for p in paths]
w, h = 260, 380
sheet = Image.new("RGB", (w * len(FIG), h * 2), (10, 8, 7))
for i, im in enumerate(ims):
    sheet.paste(im.resize((w, h), Image.LANCZOS), ((i // 2) * w, (i % 2) * h))
sheet.save("/content/out/llm_sheet.png")
print("sheet done")
