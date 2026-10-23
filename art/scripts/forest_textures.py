"""Forest textures for the clearing, from Poly Haven downloads (CC0, see CREDITS.md).

    python art/scripts/forest_textures.py <polyhaven download dir>

The download dir holds `fir_twig_alpha.png`, `fir_twig_diff.png`, `fir_bark_diff.png` (fir_tree_01, 2k) and the
ground sets `<name>_Diffuse.jpg` / `<name>_nor_gl.jpg` (1k). Writes art/forest/:
- `twig.png`: the four largest fir sprigs from the twig atlas, packed 2x2 into 1024 px, stem at the bottom of each cell,
  colour bled into the transparent parts so mipmaps do not fringe.
- `bark.jpg`: 512 px bark.
- `ground_<name>.jpg`, `ground_<name>_n.jpg`: 1k ground colour and normal maps.
"""
import shutil
import sys
from pathlib import Path

import numpy as np
from PIL import Image
from scipy import ndimage

SRC = Path(sys.argv[1])
OUT = Path(__file__).resolve().parents[1] / "forest"
OUT.mkdir(exist_ok=True)
GROUNDS = ["forrest_ground_01", "forest_ground_04", "brown_mud_leaves_01", "forest_leaves_02"]

alpha = np.asarray(Image.open(SRC / "fir_twig_alpha.png").convert("L"), np.float32) / 255
diff = np.asarray(Image.open(SRC / "fir_twig_diff.png").convert("RGB"), np.float32) / 255
H, W = alpha.shape
# the atlas has bark strips down the left and along the bottom; the sprigs sit in the rest
mask = alpha > 0.5
mask[:, : int(W * 0.15)] = False
mask[int(H * 0.76):, :] = False
lab, n = ndimage.label(ndimage.binary_dilation(mask, iterations=6))
sizes = ndimage.sum(mask, lab, range(1, n + 1))
best = np.argsort(sizes)[::-1][:4] + 1
cell = 512
atlas = np.zeros((1024, 1024, 4), np.float32)
for k, lbl in enumerate(sorted(best, key=lambda b: -sizes[b - 1])):
    ys, xs = np.nonzero(lab == lbl)
    y0, y1, x0, x1 = ys.min(), ys.max() + 1, xs.min(), xs.max() + 1
    side = max(y1 - y0, x1 - x0)
    cx = (x0 + x1) // 2
    # square crop, stem (the bottom of the sprig) on the bottom edge
    sx0 = max(0, cx - side // 2)
    sy0 = max(0, y1 - side)
    a = alpha[sy0:sy0 + side, sx0:sx0 + side] * (lab[sy0:sy0 + side, sx0:sx0 + side] == lbl)
    c = diff[sy0:sy0 + side, sx0:sx0 + side]
    rgba = np.dstack([c, a])
    img = Image.fromarray((rgba * 255).astype(np.uint8), "RGBA").resize((cell, cell), Image.LANCZOS)
    r, q = divmod(k, 2)
    atlas[r * cell:(r + 1) * cell, q * cell:(q + 1) * cell] = np.asarray(img, np.float32) / 255
    print("sprig", k, "from", (x0, y0, x1, y1), "pixels", int(sizes[lbl - 1]))
# bleed colour outward from the needles so linear filtering and mipmaps never pull in black
rgb, a = atlas[..., :3], atlas[..., 3]
have = a > 0.3
idx = ndimage.distance_transform_edt(~have, return_distances=False, return_indices=True)
rgb = rgb[idx[0], idx[1]]
Image.fromarray((np.dstack([rgb, a]) * 255).astype(np.uint8), "RGBA").save(OUT / "twig.png")

Image.open(SRC / "fir_bark_diff.png").convert("RGB").resize((512, 512), Image.LANCZOS).save(OUT / "bark.jpg", quality=90)
for g in GROUNDS:
    Image.open(SRC / f"{g}_Diffuse.jpg").convert("RGB").save(OUT / f"ground_{g}.jpg", quality=90)
    shutil.copy(SRC / f"{g}_nor_gl.jpg", OUT / f"ground_{g}_n.jpg")
print("wrote", OUT)
