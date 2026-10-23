# Sinusoidal art

Where to find each kind of asset. Every concept folder has a `_sheet.png` showing all of its images at once.

| Folder | What's in it |
|---|---|
| `concepts/dealer/01-sdxl-hooded/` | First pass, local SDXL: hooded dealers (beak, hood, skull, pale) |
| `concepts/dealer/02-flux-masks/` | FLUX.1-dev: beak, fur trapper, ring mask, pendulum |
| `concepts/dealer/03-flux-llm-ideas/` | Dealer as a language model: turk, oscilloscope, layers, tokens, attention, loom |
| `concepts/dealer/04-flux-turk/` | Mechanical Turk: classic, bare (wood + brass), tape |
| `concepts/dealer/05-flux-davinci/` | Da Vinci archaic robot: knight, walnut, codex, escapement |
| `references-3d/` | Clean front views on grey, fed to image-to-3D (Hunyuan3D-2) |
| `models/dealer/` | 3D meshes (`*-raw.glb` straight from Hunyuan3D; cleaned ones without `-raw`) |
| `cards/` | Card portraits, `<art key>.png` from `data/cards.json`, 128x128 ink on transparent; `boss.png` (the Dealer's card on the map), `back.png` (card back); `_sheet.png` shows every sprite. Style notes: `STYLE.md` |
| `map/` | Ink marks on the map stops: `node-<type>.png` for battle, event, boss, choice, hidden and rest (rest is ready for a rest stop; none exists yet) |
| `events/` | Woodcut vignettes on the event page, `<event id>.png` from `data/events.json` |
| `cards/sigils/` | Sigil icons, 48x48, named after the sigil id with hyphens (`many_lives` -> `many-lives.png`) |
| `cards/frame.png` | Card border (thin rules + woodcut corners), drawn over each card face |
| `cards/src/` | Grayscale masters of the picked FLUX renders (384 px; `more/` for back, boss, map marks, events). `python art/scripts/export_all.py` rebuilds every sprite from them, `sheet_all.py` the sheet |
| `scripts/` | Generators (see below) |

Names are `<idea>-<version>.png`, e.g. `bare-2.png` is the second version of the bare Turk.

## Scripts

- `scripts/sdxl_concept.py`: local SDXL concepts on a consumer GPU, in a Python environment with torch and diffusers.
- `scripts/colab_flux.py`: loads FLUX.1-dev on a Colab GPU session; `flux_*.py` are the prompt batches sent to it.
- `scripts/colab_flux_cached.py`: same, but restores the weights from a cloud cache first (an rclone remote holding a Hugging Face hub dir, set by `HF_CACHE_REMOTE`); `flux_cards.py` holds the card, sigil and frame prompts, `flux_more.py` the back, boss, map marks and events; `woodcut_post.py` turns a render into a game sprite; `card_sheet.py` makes contact sheets.
- Raw candidates (`cards-raw/cards` and `cards-raw/more`) are kept in cloud storage, not in git.
- `scripts/colab_hy3d.py`: loads Hunyuan3D-2 on a Colab session; `mesh(src, dst)` turns one image into a `.glb`.
- `scripts/colab_hy3d_run.sh`: the whole Hunyuan3D-2 job on a Colab VM, run detached: weights and inputs from an rclone cloud remote, meshes back to its `models/dealer` folder. Weights load in about a minute.
- `scripts/blender_dealer.py`: raw mesh to game model (headless Blender). Decimates to about 9k triangles, colours by projecting the reference from the front, and splits `Body`, `Head` (with a brain well) and `Lid` (origin at its hinge). Adds `EyeL`, `EyeR` and `Brain` markers that main.gd reads. The 64px texture is snapped to walnut and brass tones (see `compare/NOTES.md`).

## Table props

`models/props/*.glb` (candle, lamp, bell, scale, armillary `orrery`, hourglass, books, the Dealer's `hand`, `bones`
dish, wall `shelf`): FLUX.1-dev front views, then Hunyuan3D-2 shapes, then `scripts/blender_prop.py` (1.5k-4k triangles, origin
at the base centre, a 128px texture projected from the FLUX picture and snapped to walnut, brass, iron, wax/bone and
leather tones). One Colab run does the lot from the cloud weight cache: `scripts/colab_props_run.sh flux`, pick a view per
prop, then `colab_props_run.sh mesh <picks>`; prompts are in `scripts/flux_props.py`. FLUX views and raw meshes stay in
cloud storage under `models/props`. Picks: candle_0, bell_0, scale_2, lamp_1, orrery_2, hourglass_2, books_0,
hand_0, bones_0, shelf_2.

    blender --background --python art/scripts/blender_prop.py -- candle_0-raw.glb candle_0-raw-rgba.png art/models/props/candle.glb 0.42 1500

## Forest creatures

`models/creatures/<id>.glb` (dealer, stag, owl, wolf, bear, moth; details in that folder's README). FLUX.1-dev front views
from `scripts/flux_creatures.py`, Hunyuan3D-2 meshes and Blender cleanup with `scripts/blender_creature.py`. One Colab
run covers both GPU steps: `scripts/colab_creatures_run.sh flux`, pick a view, then `colab_creatures_run.sh mesh <picks>`.
Picks are in `references-3d/creatures/`. FLUX views and raw meshes are on Drive at `models/creatures/{flux,raw}`. rembg's
bria-rmbg model is cached at `hf-cache-extra/rembg`; the restore line in the run script has not been tested on a fresh VM.

    blender --background --python art/scripts/blender_creature.py -- stag stag_0-raw.glb stag_0-raw-rgba.png art/models/creatures/stag.glb art/models/creatures/stag-preview.png

## The Dealer model

`models/dealer/dealer.glb` comes from `references-3d/davinci-walnut-bust.png` (a chest-up crop, since the table hides the legs):

    blender --background --python art/scripts/blender_dealer.py -- davinci-walnut-bust-raw.glb art/references-3d/davinci-walnut-bust.png art/models/dealer/dealer.glb

The raw meshes (6 and 13 MB) stay in cloud storage under `models/dealer`, not in git. After pulling a new glb, run `godot_console --headless --path . --import` once before screenshots.

Weights cache: `rclone copy $HF_CACHE_REMOTE ~/.cache/huggingface/hub --links` restores a whole Hugging Face hub dir (FLUX.1-dev and Hunyuan3D-2) on a fresh VM.

Licenses: FLUX.1-dev is under a non-commercial model license, and every card portrait, sigil and frame here was made with it. Fine for a free or personal game; if the game is ever sold, regenerate the art with FLUX.1-schnell (Apache 2.0) or another commercially licensed model. Hunyuan3D-2's license excludes the EU (European Union), UK (United Kingdom) and South Korea.
