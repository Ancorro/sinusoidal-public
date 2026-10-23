"""Card frame sprite: thin double rule plus woodcut corner ornaments cut from a FLUX frame render.

    python woodcut_frame.py art/cards/src/frame.png art/cards/frame.png [scale]

The full FLUX border (vines, bones, moths) turned to speckle over the card text at 480x270, so only its corner
is kept and mirrored into the four corners.
"""
import sys

from PIL import Image, ImageDraw, ImageFilter, ImageOps

K = int(sys.argv[3]) if len(sys.argv) > 3 else 2  # 1: 100x140 (480x270 render), 2: 200x280 (960x540)
W, H, C = 100 * K, 140 * K, 18 * K  # sprite size (card is 0.5 x 0.7 m) and corner ornament size
INK = (42, 26, 18)

g = ImageOps.autocontrast(ImageOps.grayscale(Image.open(sys.argv[1]).convert("RGB")), cutoff=1)
m = int(min(g.size) * 0.015)
g = g.crop((m, m, g.width - m, g.height - m)).filter(ImageFilter.MinFilter(3 if g.width < 500 else 5))
corner = g.crop((0, 0, int(g.width * 0.26), int(g.width * 0.26))).resize((C, C), Image.LANCZOS)
corner = corner.point(lambda v: 255 if v < 110 else 0)
a = Image.new("L", (W, H), 0)
d = ImageDraw.Draw(a)
d.rectangle((K, K, W - 1 - K, H - 1 - K), outline=255, width=2 * K)
d.rectangle((5 * K, 5 * K, W - 1 - 5 * K, H - 1 - 5 * K), outline=255, width=K)
for mx, my in ((0, 0), (1, 0), (0, 1), (1, 1)):
    c = ImageOps.mirror(corner) if mx else corner
    c = ImageOps.flip(c) if my else c
    a.paste(255, (mx * (W - C), my * (H - C)), c)
out = Image.new("RGBA", (W, H), INK + (0,))
out.putalpha(a)
out.save(sys.argv[2])
