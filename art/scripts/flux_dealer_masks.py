# Sent to the Colab kernel after colab_flux.py has loaded FLUX: 4 dealer directions x 2 seeds, plus a contact sheet.
from PIL import Image

STYLE = ("dark fantasy game concept art of {}, seated behind a worn wooden card table in a dim cabin, lit only by a "
         "single swinging oil lamp overhead and a few candles, deep shadows, muted brown olive and bone palette, "
         "painterly, clear readable silhouette, front view, waist up")
FIG = {
    "beak": "a tall gaunt dealer in a heavy hooded robe wearing a carved wooden bird-beak mask, glowing pinprick eyes in the mask holes",
    "fur": "a huge hunched trapper in a matted fur coat wearing a pale bone skull mask etched with a sine wave, glowing eyes",
    "rings": "a robed old figure whose face is hidden by a mask of stacked concentric wooden rings like ripples, glowing eyes",
    "pendulum": "a gaunt clockwork puppeteer in a frayed coat with a brass pendulum swinging inside its open chest, porcelain mask, glowing eyes",
}
paths = []
for k, d in FIG.items():
    paths += gen("flux_" + k, STYLE.format(d), n=2, w=832, h=1216)
ims = [Image.open(p) for p in paths]
w, h = 260, 380
sheet = Image.new("RGB", (w * 4, h * 2), (10, 8, 7))
for i, im in enumerate(ims):
    sheet.paste(im.resize((w, h), Image.LANCZOS), ((i // 2) * w, (i % 2) * h))
sheet.save("/content/out/flux_figure_sheet.png")
print("sheet done")
