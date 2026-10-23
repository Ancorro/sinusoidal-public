"""Poly Haven forest models (CC0) to light game models (headless Blender 4.5).

blender --background --python blender_forest_props.py -- <polyhaven download dir> <out dir>

Each asset is `<dir>/<name>/<name>_1k.gltf` (from api.polyhaven.com, 1k textures). Every mesh object is decimated to
its share of the asset's triangle budget, its origin moved to the base centre, and the lot exported as one
`<out>/<name>.glb` with its textures embedded. Sizes stay in metres; the game scales them (2.5 game units a metre).
"""
import sys
from pathlib import Path

import bpy
from mathutils import Vector

argv = sys.argv[sys.argv.index("--") + 1:]
SRC, OUT = Path(argv[0]), Path(argv[1])
OUT.mkdir(parents=True, exist_ok=True)
# name -> triangle budget for the whole asset
ASSETS = {"tree_stump_01": 4000, "rock_moss_set_01": 6000, "dead_tree_trunk": 6000, "pine_roots": 6000, "fern_02": 6500}

for name, budget in ASSETS.items():
    bpy.ops.wm.read_factory_settings(use_empty=True)
    bpy.ops.import_scene.gltf(filepath=str(SRC / name / f"{name}_1k.gltf"))
    meshes = [o for o in bpy.context.scene.objects if o.type == "MESH"]
    total = sum(len(o.data.polygons) for o in meshes)
    for o in meshes:
        bpy.ops.object.select_all(action="DESELECT")
        o.select_set(True)
        bpy.context.view_layer.objects.active = o
        bpy.ops.object.parent_clear(type="CLEAR_KEEP_TRANSFORM")
        bpy.ops.object.transform_apply(location=False, rotation=True, scale=True)
        ratio = budget / max(total, 1)
        if ratio < 1.0:
            mod = o.modifiers.new("dec", "DECIMATE")
            mod.ratio = ratio
            bpy.ops.object.modifier_apply(modifier=mod.name)
        # origin at the base centre of each piece, so the game can place pieces of a set one by one
        vs = [o.matrix_world @ v.co for v in o.data.vertices]
        lo = Vector((min(v.x for v in vs), min(v.y for v in vs), min(v.z for v in vs)))
        hi = Vector((max(v.x for v in vs), max(v.y for v in vs), max(v.z for v in vs)))
        base = Vector(((lo.x + hi.x) / 2, (lo.y + hi.y) / 2, lo.z))
        bpy.context.scene.cursor.location = base
        bpy.ops.object.origin_set(type="ORIGIN_CURSOR")
        if name != "rock_moss_set_01":   # a set keeps its pieces apart; single models sit at the world origin
            o.location = Vector((o.location.x - base.x, o.location.y - base.y, 0)) if len(meshes) == 1 else o.location
    for o in [o for o in bpy.context.scene.objects if o.type != "MESH"]:
        bpy.data.objects.remove(o)
    bpy.ops.object.select_all(action="SELECT")
    tris = sum(len(o.data.polygons) for o in bpy.context.scene.objects if o.type == "MESH")
    print(name, "pieces", [o.name for o in bpy.context.scene.objects], "faces", total, "->", tris)
    bpy.ops.export_scene.gltf(filepath=str(OUT / f"{name}.glb"), export_format="GLB", use_selection=True,
                              export_image_format="JPEG", export_jpeg_quality=88)
