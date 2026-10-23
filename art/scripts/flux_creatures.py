"""Front views of the forest creatures for image-to-3D, FLUX.1-dev on the Colab VM (weights from the Drive hf-cache).

python flux_creatures.py OUT_DIR [name ...]   -> OUT_DIR/<name>_<seed>.png, then OUT_DIR/DONE
One family: archaic Da Vinci workshop automata of walnut, brass and iron, forest-worn, each a different animal,
seated or kneeling and facing the viewer, whole figure on plain grey so Hunyuan3D-2 gets a clean silhouette.
The domed skull with a seam is asked for because the game hinges the top of the head open to show a brain.
"""
import sys
from pathlib import Path

import torch
from diffusers import FluxPipeline

LOOK = ("3d character reference of {}, an archaic Renaissance clockwork automaton from Leonardo da Vinci's workshop, "
        "carved from dark polished walnut wood with aged brass and black iron fittings, ball-and-socket joints, gears "
        "and rivets, a smooth domed wooden skull cap with a thin brass seam around it, round glass lens eyes, "
        "forest-worn: patches of green moss and pale lichen on the wood, {}, facing the viewer, front view, "
        "symmetrical, the whole figure centred and fully in frame, even soft studio lighting, plain flat light grey "
        "background, no props, no ground clutter, game asset, highly detailed")
CREATURES = {
    "dealer": ("a slender humanoid wooden mannequin like an artist's jointed figure, a bald oval wooden head with a "
               "small carved nose, an open ribcage of curved walnut slats with gears behind",
               "kneeling upright on both knees, sitting back on its heels, hands resting on its thighs"),
    "stag": ("a stag: a deer-headed humanoid automaton with a long walnut muzzle and a pair of large branching antlers "
             "of brass and dark wood, a barrel chest of walnut slats",
             "kneeling upright on both knees, sitting back on its heels, hands resting on its knees"),
    "owl": ("a great horned owl: a round-bodied owl automaton with overlapping carved walnut feather plates, brass ear "
            "tufts, a hooked iron beak and huge round glass eyes in a flat facial disc",
            "sitting upright and squat with its wings folded at its sides, iron talons gripping a short log"),
    "wolf": ("a wolf: a lean wolf automaton with a long walnut snout, tall pointed brass ears, an iron jaw and a ruff "
             "of carved wooden fur plates",
             "sitting on its haunches with its front legs straight and its paws together, like a dog sitting"),
    "bear": ("a bear: a heavy bear automaton with a broad walnut head, small round ears, a short iron muzzle and a "
             "big round belly of curved walnut slats",
             "sitting on its rump with its legs stretched forward and its paws resting on its knees"),
    "moth": ("a moth spirit: a slender humanoid automaton with a moth's head, two large feathery brass antennae, and "
             "four broad wings of parchment and thin walnut ribs spread behind it",
             "kneeling upright on both knees, sitting back on its heels, hands folded in its lap, wings open behind"),
}

out = Path(sys.argv[1])
out.mkdir(parents=True, exist_ok=True)
names = sys.argv[2:] or list(CREATURES)
pipe = FluxPipeline.from_pretrained("black-forest-labs/FLUX.1-dev", torch_dtype=torch.bfloat16).to("cuda")
print("FLUX loaded", flush=True)
for name in names:
    body, pose = CREATURES[name]
    for seed in range(4):
        g = torch.Generator("cuda").manual_seed(seed)
        im = pipe(LOOK.format(body, pose), width=1024, height=1024, num_inference_steps=28, guidance_scale=3.5,
                  generator=g).images[0]
        im.save(out / f"{name}_{seed}.png")
        print(name, seed, flush=True)
(out / "DONE").touch()
