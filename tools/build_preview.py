"""Build the project's standalone visual preview from Godot screenshots. No server or model is required."""
from __future__ import annotations

import argparse
import base64
import html
import io
from pathlib import Path

from PIL import Image

ROOT = Path(__file__).resolve().parents[1]
GALLERY = [
    ("lighting-dark.png", "Combat in the clearing", "Night, lit by a small campfire. Health is the brass counters, mana the tokens by the candles; turn the hourglass to end your turn."),
    ("forest-map.png", "The trail chart", "Fifteen stops per route. Battles, card choices, events and a final encounter."),
    *[(f"clearing-{key}.png", title, "Clearing preview · seed 7 · the demo board uses fixed cards and six mana.") for key, title in [
        ("fern_hollow", "Fern hollow"), ("ash_ring", "The burnt ring"), ("mire", "The mire"),
        ("stone_ring", "The stone ring"), ("fallen_giant", "Where the giant fell")]],
    *[(f"creature-{key}-open.png", title, "Open skull: the circuit and four cuttable wires remain attached to this creature.") for key, title in [
        ("dealer", "Walnut Dealer"), ("stag", "Antlered stag"), ("owl", "Great owl"),
        ("wolf", "Iron wolf"), ("bear", "Barrel bear"), ("moth", "Moth")]],
]


def build(shots: Path, output: Path) -> None:
    figures = []
    for file, title, caption in GALLERY:
        source = shots / file
        if not source.exists():
            raise FileNotFoundError(source)
        buffer = io.BytesIO()
        with Image.open(source) as image:
            image.convert("RGB").save(buffer, "JPEG", quality=80, optimize=True)
        encoded = base64.b64encode(buffer.getvalue()).decode("ascii")
        figures.append(f'<figure><a href="data:image/jpeg;base64,{encoded}" target="_blank">'
                       f'<img loading="lazy" alt="{html.escape(title)}" src="data:image/jpeg;base64,{encoded}"></a>'
                       f'<figcaption><h2>{html.escape(title)}</h2><p>{html.escape(caption)}</p></figcaption></figure>')
    page = """<!doctype html><html lang="en"><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1">
<title>Sinusoidal — development preview</title><style>
:root{color-scheme:dark;font:16px/1.6 system-ui;background:#0c1312;color:#e1dfd3}body{max-width:1100px;margin:auto;padding:26px 18px 60px}
h1{font:clamp(2rem,7vw,4rem)/1.05 Georgia,serif;margin:16px 0}h2{font-size:1.12rem;margin:0}p{max-width:75ch;color:#bdc7bc}.tag{color:#dfb76d;letter-spacing:.12em;text-transform:uppercase;font-size:.75rem}
.intro{border-bottom:1px solid #34443a;padding-bottom:20px;margin-bottom:26px}.grid{display:grid;grid-template-columns:repeat(auto-fit,minmax(min(100%,430px),1fr));gap:22px}
figure{margin:0;background:#141e19;border:1px solid #34443a;overflow:hidden;border-radius:8px}figure:first-child{grid-column:1/-1}img{width:100%;height:auto;display:block}figcaption{padding:14px 18px}figcaption p{font-size:.9rem;margin:6px 0}li{margin-bottom:7px}a{color:#dfb76d}
details{margin:20px 0;background:#141e19;padding:12px 18px;border:1px solid #34443a}footer{margin-top:35px;font-size:.85rem;color:#9cae9f}
</style><header class="intro"><div class="tag">Private development preview · work in progress</div><h1>Sinusoidal</h1>
<p>A card roguelike in a dark forest. A mechanical creature sits across the clearing. Open its skull and cut the wires that steer its language-model brain.</p>
<p>Default combat: two heroes with 30 health, mana growing to ten, seven minions per side, targeted attacks and spells. The pool contains 53 collectible cards and five tokens.</p>
<details><summary>Controls and verification</summary><ul>
<li>Click a hand card to play it; targeted effects wait for a target. Select a ready minion, then its target to attack. Taunt must be attacked first. Turn the hourglass to end your turn.</li>
<li>Hold the right mouse button and drag to look around. Space returns to the board or map. Open head reveals the four wires.</li>
<li>Settings → Old lane rules starts a fresh run using the original combat.</li>
<li>The render is 1440 × 810. Screenshots use seed 7, a fixed demo board and no brain server. Creature close-ups use the same opening animation as play.</li>
<li>Rules, combat controls, creature heads and persona gauges were checked. Complete scene-driven runs were checked in both combat modes.</li>
</ul></details></header><main class="grid">GALLERY</main>
<footer>Generated models still have rough side textures; their 256 px maps are now sampled smoothly. Presentation remains in development. This page is private; the public snapshot stays private pending the writing workflow.</footer></html>"""
    output.parent.mkdir(parents=True, exist_ok=True)
    output.write_text(page.replace("GALLERY", "\n".join(figures)), encoding="utf-8")
    print(f"Built {output}: {len(figures)} screenshots, {output.stat().st_size:,} bytes")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--shots", type=Path, default=ROOT / "shots")
    parser.add_argument("--output", type=Path, default=ROOT / "docs" / "preview.html")
    args = parser.parse_args()
    build(args.shots, args.output)
