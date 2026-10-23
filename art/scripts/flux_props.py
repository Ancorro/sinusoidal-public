"""Front views of the table props for image-to-3D, FLUX.1-dev on the Colab VM (weights from the Drive hf-cache).

python flux_props.py OUT_DIR [name ...]   -> OUT_DIR/<name>_<seed>.png, then OUT_DIR/DONE
One object per picture, whole, centred, on plain grey, so Hunyuan3D-2 gets a clean silhouette.
"""
import sys
from pathlib import Path

import torch
from diffusers import FluxPipeline

LOOK = ("a single {}, the whole object centred and fully in frame, front three-quarter view from slightly above, "
        "studio product photograph on a plain flat light grey background, soft even light, Renaissance workshop "
        "craftsmanship, dark walnut wood and aged brass, no other objects, no text")
PROPS = {
    "candle": "tall beeswax candle in a simple turned brass candlestick with a round drip pan, unlit",
    "bell": "antique brass desk bell with a domed top and a push button, on a round carved walnut base",
    "scale": "Renaissance brass balance scale, a tall ornate central column on a round stepped base, "
             "a straight beam on top with two shallow brass pans hanging from short chains",
    "lamp": "hanging brass oil lamp with a wide flared conical shade, hung from a short chain",
    "orrery": "brass armillary sphere of interlocking rings around a small globe, on a turned walnut stand",
    "hourglass": "large hourglass with a turned walnut frame of three spindles between two round plates, "
                 "sand in the lower bulb",
    "books": "stack of four old thick leather-bound books with brass corners, slightly askew",
    "hand": "carved walnut wooden mannequin hand with brass pins at the knuckles, lying flat palm down, "
            "fingers slightly curled",
    "bones": "small heap of old yellowed animal bones and one small skull in a shallow round brass dish",
    "shelf": "dark walnut wall shelf with two tiers holding brass gears, glass jars, a small clock and calipers",
}

out = Path(sys.argv[1])
out.mkdir(parents=True, exist_ok=True)
names = sys.argv[2:] or list(PROPS)
pipe = FluxPipeline.from_pretrained("black-forest-labs/FLUX.1-dev", torch_dtype=torch.bfloat16).to("cuda")
print("FLUX loaded", flush=True)
for name in names:
    for seed in range(3):
        g = torch.Generator("cuda").manual_seed(seed)
        im = pipe(LOOK.format(PROPS[name]), width=1024, height=1024, num_inference_steps=28, guidance_scale=3.5,
                  generator=g).images[0]
        im.save(out / f"{name}_{seed}.png")
        print(name, seed, flush=True)
(out / "DONE").touch()
