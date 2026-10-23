"""Raw Hunyuan3D-2 prop -> game model (headless Blender 4.5).

blender --background --python blender_prop.py -- raw.glb front.png out.glb HEIGHT TRIS [preview.png]
(front.png is best the -rgba.png cut-out hy3d_batch.py saves next to the mesh)

Keeps the biggest pieces, decimates to TRIS triangles, scales to HEIGHT game units with the origin at the centre of
the base, and colours it by projecting the front picture (the FLUX view the mesh came from) through a 128px texture
snapped to the cabin's material tones, so it sits with the Dealer under the palette shader.
Godot axes after export: +Y up, front toward +Z.
"""
import sys

import bmesh
import bpy
import numpy as np
from mathutils import Vector

argv = sys.argv[sys.argv.index("--") + 1:]
RAW, REF, OUT, HEIGHT, TRIS = argv[0], argv[1], argv[2], float(argv[3]), int(argv[4])
PREVIEW = argv[5] if len(argv) > 5 else ""
TEX = 128

# material ramps, dark to light: brightness picks the tone, hue picks the ramp
RAMPS = {
    "walnut": [(0.03, 0.018, 0.01), (0.09, 0.04, 0.02), (0.18, 0.08, 0.035), (0.30, 0.14, 0.06), (0.42, 0.22, 0.10)],
    "brass": [(0.12, 0.08, 0.03), (0.28, 0.20, 0.07), (0.50, 0.38, 0.14), (0.75, 0.60, 0.28)],
    "iron": [(0.03, 0.035, 0.035), (0.09, 0.10, 0.10), (0.20, 0.21, 0.20), (0.40, 0.41, 0.39)],
    "pale": [(0.35, 0.30, 0.22), (0.55, 0.49, 0.37), (0.75, 0.69, 0.55), (0.90, 0.85, 0.72)],   # wax, bone, paper
    "red": [(0.12, 0.03, 0.02), (0.25, 0.06, 0.04), (0.42, 0.12, 0.07)],                       # leather
    "green": [(0.04, 0.07, 0.05), (0.09, 0.15, 0.11), (0.17, 0.26, 0.19)],                     # leather, glass
}

bpy.ops.wm.read_factory_settings(use_empty=True)
bpy.ops.import_scene.gltf(filepath=RAW)
meshes = [o for o in bpy.context.scene.objects if o.type == "MESH"]
bpy.ops.object.select_all(action="DESELECT")
for o in meshes:
    o.select_set(True)
bpy.context.view_layer.objects.active = meshes[0]
if len(meshes) > 1:
    bpy.ops.object.join()
ob = bpy.context.view_layer.objects.active
bpy.ops.object.parent_clear(type="CLEAR_KEEP_TRANSFORM")
bpy.ops.object.transform_apply(location=True, rotation=True, scale=True)
for o in list(bpy.context.scene.objects):
    if o is not ob:
        bpy.data.objects.remove(o)
me = ob.data

# drop crumbs: islands under 1% of the biggest
bm = bmesh.new()
bm.from_mesh(me)
seen, islands = set(), []
for f in bm.faces:
    if f.index in seen:
        continue
    stack, isl = [f], []
    seen.add(f.index)
    while stack:
        g = stack.pop()
        isl.append(g)
        for e in g.edges:
            for h in e.link_faces:
                if h.index not in seen:
                    seen.add(h.index)
                    stack.append(h)
    islands.append(isl)
islands.sort(key=len, reverse=True)
bmesh.ops.delete(bm, geom=[f for isl in islands[1:] if len(isl) < 0.01 * len(islands[0]) for f in isl], context="FACES")
bm.to_mesh(me)
bm.free()

mod = ob.modifiers.new("dec", "DECIMATE")
mod.ratio = min(1.0, TRIS / max(1, len(me.polygons)))
bpy.ops.object.modifier_apply(modifier=mod.name)


def bbox():
    co = np.array([v.co[:] for v in me.vertices])
    return co.min(0), co.max(0)


lo, hi = bbox()
s = HEIGHT / (hi[2] - lo[2])
c = (lo + hi) / 2
for v in me.vertices:
    v.co = Vector(((v.co.x - c[0]) * s, (v.co.y - c[1]) * s, (v.co.z - lo[2]) * s))
me.update()
lo, hi = bbox()

# front projection of the picture onto the model's silhouette
src = bpy.data.images.load(REF)
w, h = src.size
rgba = np.array(src.pixels[:], dtype=np.float32).reshape(h, w, 4)   # rows from the bottom
px = rgba[:, :, :3]
if rgba[:, :, 3].min() < 0.5:   # a cut-out (hy3d_batch's -rgba.png)
    fg = rgba[:, :, 3] > 0.5
else:
    bg = np.median(np.concatenate([px[:8].reshape(-1, 3), px[-8:].reshape(-1, 3)]), axis=0)
    fg = np.abs(px - bg).sum(-1) > 0.15
ys, xs = np.nonzero(fg)
ix0, ix1, iy0, iy1 = xs.min(), xs.max(), ys.min(), ys.max()
uv = me.uv_layers.new(name="UV")
for loop in me.loops:
    co = me.vertices[loop.vertex_index].co
    uv.data[loop.index].uv = ((ix0 + (co.x - lo[0]) / (hi[0] - lo[0]) * (ix1 - ix0)) / w,
                              (iy0 + (co.z - lo[2]) / (hi[2] - lo[2]) * (iy1 - iy0)) / h)

k = min(h, w) // TEX
fgb = fg[:TEX * k, :TEX * k].reshape(TEX, k, TEX, k)
pxb = px[:TEX * k, :TEX * k].reshape(TEX, k, TEX, k, 3)
col = (pxb * fgb[..., None]).sum(axis=(1, 3)) / np.maximum(fgb.sum(axis=(1, 3)), 1)[..., None]
have = fgb.mean(axis=(1, 3)) > 0.6
col[~have] = 0
for _ in range(TEX):   # bleed outward so silhouette edges never sample the backdrop
    if have.all():
        break
    acc, n = np.zeros_like(col), np.zeros(have.shape, np.float32)
    for dy, dx in ((1, 0), (-1, 0), (0, 1), (0, -1)):
        acc += np.roll(col * have[..., None], (dy, dx), (0, 1))
        n += np.roll(have, (dy, dx), (0, 1))
    grow = ~have & (n > 0)
    col[grow] = acc[grow] / n[grow][:, None]
    have |= grow


def snap(rgb):
    r, g, b = rgb
    lum = (r + g + b) / 3
    sat = max(rgb) - min(rgb)
    if sat < 0.06 or lum < 0.04:
        ramp = "pale" if lum > 0.35 else "iron"
    elif g > r * 1.05:
        ramp = "green"
    elif g / max(r, 1e-3) > 0.72 and g - b > 0.05:
        ramp = "pale" if sat < 0.2 and lum > 0.5 else "brass"
    elif g / max(r, 1e-3) < 0.38:
        ramp = "red"
    else:
        ramp = "walnut"
    tones = np.array(RAMPS[ramp], np.float32)
    return tones[np.argmin(np.abs(tones.mean(1) - lum * 0.8))]


col = np.apply_along_axis(snap, 2, col)
img = bpy.data.images.new("albedo", TEX, TEX)
img.pixels[:] = np.concatenate([col, np.ones((TEX, TEX, 1), np.float32)], axis=2).ravel()
img.pack()

m = bpy.data.materials.new("Prop")
m.use_nodes = True
p = m.node_tree.nodes["Principled BSDF"]
p.inputs["Roughness"].default_value = 0.6
tex = m.node_tree.nodes.new("ShaderNodeTexImage")
tex.image = img
tex.interpolation = "Closest"
m.node_tree.links.new(tex.outputs["Color"], p.inputs["Base Color"])
me.materials.clear()
me.materials.append(m)
for poly in me.polygons:
    poly.use_smooth = False
ob.name = OUT.replace("\\", "/").rsplit("/", 1)[-1].split(".")[0]
print("PROP", ob.name, "faces", len(me.polygons), "size", (hi - lo).round(3))
bpy.ops.export_scene.gltf(filepath=OUT, export_format="GLB", use_selection=False)

if PREVIEW:
    sc = bpy.context.scene
    sc.render.engine = "BLENDER_EEVEE_NEXT"
    sc.render.resolution_x = sc.render.resolution_y = 320
    cam = bpy.data.objects.new("cam", bpy.data.cameras.new("cam"))
    sc.collection.objects.link(cam)
    size = max(hi - lo)
    cam.location = Vector((size * 1.2, -size * 2.2, HEIGHT * 0.5 + size * 0.9))
    cam.rotation_euler = (Vector((0, 0, HEIGHT * 0.45)) - cam.location).to_track_quat("-Z", "Y").to_euler()
    sun = bpy.data.objects.new("sun", bpy.data.lights.new("sun", "SUN"))
    sun.data.energy = 4
    sun.rotation_euler = (0.8, 0.3, 0.6)
    sc.collection.objects.link(sun)
    sc.world = bpy.data.worlds.new("w")
    sc.world.color = (0.2, 0.2, 0.2)
    sc.camera = cam
    sc.render.filepath = PREVIEW
    bpy.ops.render.render(write_still=True)
