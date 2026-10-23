"""Turn FLUX woodcut renders (black ink on cream) into game sprites: dark ink on transparent.

    python woodcut_post.py SRC.png DST.png [--size 64] [--thicken 3]

Paper is keyed out to alpha; ink becomes one dark walnut-ink colour, so it reads at ~16-40 px on screen and the
palette shader has nothing in the mid-tones to band. --thicken grows the ink before shrinking so thin cuts survive.
"""
import argparse

from PIL import Image, ImageFilter, ImageOps

INK = (42, 26, 18)  # matches the card label ink 2a1a12 in scripts/main.gd


def ink_mask(src, size, thicken, cut=110, crop=True, aspect=1.0):
    g = ImageOps.grayscale(Image.open(src).convert("RGB"))
    m = int(min(g.size) * 0.03)  # drop the paper's darkened edge and any border FLUX drew
    g = ImageOps.expand(g.crop((m, m, g.width - m, g.height - m)), m, fill=255)
    g = ImageOps.autocontrast(g, cutoff=1)
    if crop:  # crop to the ink's bounding box (square, with a margin) so the figure fills the card
        box = g.point(lambda v: 255 if v < cut else 0).getbbox()
        if box:
            cx, cy = (box[0] + box[2]) / 2, (box[1] + box[3]) / 2
            hw = max(box[2] - box[0], (box[3] - box[1]) * aspect) / 2 * 1.08  # half width; height = width / aspect
            hh = hw / aspect
            g = g.crop((int(cx - hw), int(cy - hh), int(cx + hw), int(cy + hh)))
            g = ImageOps.expand(g, 0, fill=255)
    if thicken > 1:
        g = g.filter(ImageFilter.MinFilter(thicken))  # grows dark areas
    g = g.resize((size, round(size / aspect)), Image.LANCZOS)
    a = g.point(lambda v: 255 if v < cut else 0)  # alpha: ink opaque, paper clear
    return despeckle(a, max(4, size * size // 340))


def despeckle(a, min_px):
    """Drop ink islands smaller than min_px (leftovers of borders and signatures FLUX drew around the print)."""
    w, h = a.size
    px = a.load()
    seen = set()
    for y in range(h):
        for x in range(w):
            if px[x, y] and (x, y) not in seen:
                comp, stack = [], [(x, y)]
                seen.add((x, y))
                while stack:
                    cx, cy = stack.pop()
                    comp.append((cx, cy))
                    for nx, ny in ((cx + 1, cy), (cx - 1, cy), (cx, cy + 1), (cx, cy - 1)):
                        if 0 <= nx < w and 0 <= ny < h and px[nx, ny] and (nx, ny) not in seen:
                            seen.add((nx, ny))
                            stack.append((nx, ny))
                if len(comp) < min_px:
                    for p in comp:
                        px[p] = 0
    return a


def to_sprite(src, dst, size=64, thicken=3, crop=True, ink=INK, aspect=1.0):
    a = ink_mask(src, size, thicken, crop=crop, aspect=aspect)
    out = Image.new("RGBA", a.size, ink + (0,))
    out.putalpha(a)
    out.save(dst)


if __name__ == "__main__":
    ap = argparse.ArgumentParser()
    ap.add_argument("src")
    ap.add_argument("dst")
    ap.add_argument("--size", type=int, default=64)
    ap.add_argument("--thicken", type=int, default=3)
    ap.add_argument("--no-crop", action="store_true")
    ap.add_argument("--aspect", type=float, default=1.0, help="width / height of the output (size is the width)")
    ap.add_argument("--white", action="store_true", help="white ink mask, coloured in game by modulate")
    a = ap.parse_args()
    to_sprite(a.src, a.dst, a.size, a.thicken, not a.no_crop, (255, 255, 255) if a.white else INK, a.aspect)
