"""Contact sheet of every game sprite: python art/scripts/sheet_all.py  -> art/cards/_sheet.png"""
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

from PIL import Image

ART = Path(__file__).resolve().parents[1]
with tempfile.TemporaryDirectory() as t:
    t = Path(t)
    for p in (ART / "cards").glob("*.png"):
        if not p.name.startswith("_") and p.stem not in ("frame", "back", "moth", "oil", "player", "potion"):
            shutil.copy(p, t / p.name)
    for p in (ART / "cards/sigils").glob("*.png"):
        shutil.copy(p, t / ("sigil-" + p.name))
    # white masks (back, map marks, events) are drawn in dark ink, centred on a square
    for p, name in [(ART / "cards/back.png", "zback.png"), *[(p, "map-" + p.name) for p in (ART / "map").glob("*.png")],
                    *[(p, "zev-" + p.name) for p in (ART / "events").glob("*.png")]]:
        a = Image.open(p).getchannel("A")
        k = 128 / max(a.size)
        a = a.resize((int(a.width * k), int(a.height * k)), Image.NEAREST)
        sq = Image.new("L", (128, 128), 0)
        sq.paste(a, ((128 - a.width) // 2, (128 - a.height) // 2))
        out = Image.new("RGBA", (128, 128), (42, 26, 18, 0))
        out.putalpha(sq)
        out.save(t / name)
    shutil.copy(ART / "cards/frame.png", t / "zz-frame.png")
    subprocess.run([sys.executable, "-I", str(ART / "scripts/card_sheet.py"), str(t), str(ART / "cards/_sheet.png")], check=True)
