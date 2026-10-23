"""Rebuild every game sprite from the masters in art/cards/src (no Colab needed).

    python art/scripts/export_all.py

Sizes are for the 960x540 render: portraits 128 px, sigils 48, map marks 48, event vignettes 192x120, card back
140x196, frame 200x280. Map marks, events and the card back are white ink masks (coloured in game by modulate).
"""
import sys
from pathlib import Path

from PIL import Image, ImageDraw

sys.path.insert(0, str(Path(__file__).parent))
import woodcut_post as w  # noqa: E402

ART = Path(__file__).resolve().parents[1]
SRC = ART / "cards/src"
WHITE = (255, 255, 255)
SIGIL_THICKEN = {"reach": 9, "splash": 9, "guard": 3}

for p in sorted(SRC.glob("*.png")):
    if p.stem != "frame":
        w.to_sprite(p, ART / "cards" / p.name, 128, 3)
for p in sorted((SRC / "sigils").glob("*.png")):
    w.to_sprite(p, ART / "cards/sigils" / p.name, 48, SIGIL_THICKEN.get(p.stem, 7))
# Guard's buckler is a solid disc at this size: cut a boss ring so it is not mistaken for a blot
g = Image.open(ART / "cards/sigils/guard.png")
a = g.getchannel("A")
d = ImageDraw.Draw(a)
d.ellipse((14, 14, 33, 33), outline=0, width=2)
d.ellipse((20, 20, 27, 27), fill=0)
g.putalpha(a)
g.save(ART / "cards/sigils/guard.png")
more = SRC / "more"
w.to_sprite(more / "boss.png", ART / "cards/boss.png", 128, 3)
w.to_sprite(more / "back.png", ART / "cards/back.png", 140, 3, ink=WHITE, aspect=0.714)
for p in sorted(more.glob("node-*.png")):
    w.to_sprite(p, ART / "map" / p.name, 48, 5 if p.stem == "node-boss" else 7, ink=WHITE)
for p in sorted(more.glob("event-*.png")):
    w.to_sprite(p, ART / "events" / (p.stem[len("event-"):] + ".png"), 192, 3, ink=WHITE, aspect=1.6)
print("exported")
