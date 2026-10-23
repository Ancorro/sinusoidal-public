"""Contact sheet of every sprite in a folder, each shown big (nearest) and at real card size, labelled.

    python card_sheet.py art/cards art/cards/_sheet.png
"""
import sys
from pathlib import Path

from PIL import Image, ImageDraw

PAPER = (217, 203, 176)  # card face d9cbb0 in scripts/main.gd

src, dst = Path(sys.argv[1]), sys.argv[2]
files = sorted(p for p in src.glob("*.png") if not p.name.startswith("_"))
cols, cell = 6, 160
rows = (len(files) + cols - 1) // cols
sheet = Image.new("RGB", (cols * cell, rows * (cell + 40)), (20, 15, 12))
d = ImageDraw.Draw(sheet)
for i, p in enumerate(files):
    im = Image.open(p).convert("RGBA")
    x, y = (i % cols) * cell, (i // cols) * (cell + 40)
    big = Image.new("RGBA", (128, 128), PAPER + (255,))
    big.alpha_composite(im.resize((128, 128), Image.NEAREST))
    sheet.paste(big.convert("RGB"), (x + 4, y + 4))
    small = Image.new("RGBA", (24, 24), PAPER + (255,))
    small.alpha_composite(im.resize((24, 24), Image.LANCZOS))
    sheet.paste(small.convert("RGB"), (x + 134, y + 4))
    d.text((x + 4, y + 136), p.stem, fill=(230, 220, 200))
sheet.save(dst)
print(dst, len(files))
