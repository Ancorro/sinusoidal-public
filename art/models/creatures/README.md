# Forest creatures

Walnut, brass and iron Da Vinci automata that walk out of the forest and play across the ground board. Each `<id>.glb`
has top-level `Body`, `Head`, `Lid` (origin = hinge at the back of the skull cut; rotate local X to -140 degrees to
open it backwards and upwards), empties `EyeL`, `EyeR`, `Brain` under `Head` and `Chest` under `Body`. Godot axes: +Y up,
facing +Z, origin on the ground under the creature, top of the skull at y = 2.0. Texture 256 px, front projected.
`<id>-preview.png`: front head with the lid closed, full front, three-quarter and head close-up with the lid open
(red = eyes, green = chest, cyan = brain). Pipeline: `art/scripts/flux_creatures.py` -> `colab_creatures_run.sh` ->
`blender_creature.py` (per-creature pixels in its `CREATURES` table); references in `art/references-3d/creatures/`.

Marker positions are in Godot units (x, y, z).

- **dealer**: the walnut mannequin Dealer, kneeling (new FLUX view, `dealer_1`, not the old mesh). 16.7k tris. EyeL (-0.105, 1.775, 0.056), EyeR (0.099, 1.775, 0.056), Brain (0.000, 1.774, -0.133), Chest (-0.002, 1.296, 0.075). Quirks: the head is more of an egg, and a pale collar plate sits under the neck. To rebuild the standing version from `davinci-walnut-raw.glb`, run the script with id `dealer-standing`.
- **stag**: antlered stag, kneeling with hands on its knees. 19.2k tris. EyeL (-0.130, 1.741, 0.215), EyeR (0.130, 1.741, 0.216), Brain (0.000, 1.754, -0.007), Chest (-0.001, 1.050, 0.073). Quirk: the antlers stay on Head and reach about y = 2.6, so the file is taller than 2.0.
- **owl**: great horned owl, squat on brass talons. 17.7k tris. EyeL (-0.188, 1.452, 0.762), EyeR (0.186, 1.452, 0.753), Brain (0.000, 1.505, 0.487), Chest (0.003, 0.964, 0.906). Quirks: the upper ear tufts lift with the lid and their stumps stay on Head; the eyes are big (scale up the eye glow); the body is about 2.0 deep.
- **wolf**: wolf sitting on its haunches. 18.6k tris. EyeL (-0.112, 1.548, 0.909), EyeR (0.127, 1.548, 0.898), Brain (-0.017, 1.508, 0.681), Chest (0.010, 0.878, 0.741). Quirks: the upper halves of the ears lift with the lid; the snout reaches z of about 1.0; the tail curls to one side; the flanks are paler from stretched projection.
- **bear**: bear sitting on its rump with its paws on its belly. 19.5k tris. EyeL (-0.149, 1.675, 0.327), EyeR (0.151, 1.675, 0.326), Brain (0.000, 1.694, -0.029), Chest (0.002, 1.116, 0.303). Quirk: the upper halves of the ears lift with the lid, which takes the whole crown.
- **moth**: moth spirit kneeling, four parchment wings spread. 18.8k tris. EyeL (-0.109, 1.652, 0.310), EyeR (0.104, 1.652, 0.315), Brain (0.000, 1.677, 0.109), Chest (0.007, 1.163, 0.318). Quirks: the wings on Body span about 2.4 wide; the brass antennae stay on Head (top at about y = 2.29); the chest marker sits on its brass medallion.
