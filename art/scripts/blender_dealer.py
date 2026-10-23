"""Clean a raw Hunyuan3D-2 Dealer mesh into the game model (headless Blender 4.5).

blender --background --python blender_dealer.py -- raw.glb reference.png out.glb [preview.png]

Steps: join and orient, scale so the head sits where main.gd expects it, decimate to low poly, colour by projecting
the reference image from the front (walnut and brass come straight from the picture), then cut the skull into a
`Head` and a `Lid` whose origin is the hinge at the back of the cut. Godot axes after export: +Y up, face toward +Z.
"""
import sys

import bmesh
import bpy
import numpy as np
from mathutils import Vector

argv = sys.argv[sys.argv.index("--") + 1:]
RAW, REF, OUT = argv[:3]
PREVIEW = argv[3] if len(argv) > 3 else ""

HEAD_TOP = 2.31        # top of the skull in game units (placeholder head: centre 1.95, radius 0.36)
LID_FRAC = 0.30        # lid takes the top 30% of the head height
WELL = 0.12            # depth of the brain cavity sunk into the head under the lid
TARGET_TRIS = 9000
TEX = 64               # chunky texels, as in Inscryption's low-res textures; fine detail just turns to noise
EYE_PX = (482, 562, 293)  # left x, right x, y (from the top) of the lenses in davinci-walnut-bust.png

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


def bbox(verts):
    lo = Vector((min(v.co.x for v in verts), min(v.co.y for v in verts), min(v.co.z for v in verts)))
    hi = Vector((max(v.co.x for v in verts), max(v.co.y for v in verts), max(v.co.z for v in verts)))
    return lo, hi


# Blender is Z-up; glTF import already maps the model's +Y up to +Z and its front (+Z) to -Y.
lo, hi = bbox(me.vertices)
print("raw bbox", lo, hi, "faces", len(me.polygons))

# keep the largest connected piece (drops floating crumbs)
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
print("islands", [len(i) for i in islands[:6]])
small = [f for isl in islands[1:] for f in isl if len(isl) < 0.002 * len(islands[0])]
bmesh.ops.delete(bm, geom=small, context="FACES")
bm.to_mesh(me)
bm.free()

# decimate
mod = ob.modifiers.new("dec", "DECIMATE")
mod.ratio = min(1.0, TARGET_TRIS / max(1, len(me.polygons)))
bpy.ops.object.modifier_apply(modifier=mod.name)
print("decimated faces", len(me.polygons))

# find the head: the neck is the narrowest horizontal slice in the upper part of the figure
lo, hi = bbox(me.vertices)
H = hi.z - lo.z
bins = 60
width = [0.0] * bins
for v in me.vertices:
    b = min(bins - 1, int((v.co.z - lo.z) / H * bins))
    width[b] = max(width[b], abs(v.co.x - (lo.x + hi.x) / 2))
upper = range(int(bins * 0.55), int(bins * 0.92))
neck_bin = min(upper, key=lambda b: width[b] if width[b] > 0 else 9)
neck_z = lo.z + (neck_bin + 0.5) / bins * H
print("neck z", neck_z, "widths", [round(w, 2) for w in width])

# scale so the skull top lands at HEAD_TOP and its height matches the placeholder (~0.72)
head_h = hi.z - neck_z
s = 0.72 / head_h
cx, cy = (lo.x + hi.x) / 2, (lo.y + hi.y) / 2
for v in me.vertices:
    v.co = Vector(((v.co.x - cx) * s, (v.co.y - cy) * s, (v.co.z - hi.z) * s + HEAD_TOP))
me.update()
neck_z = (neck_z - hi.z) * s + HEAD_TOP
lo, hi = bbox(me.vertices)
print("scaled bbox", lo, hi, "neck", neck_z)

# colour: planar projection of the reference from the front onto the figure's silhouette
src = bpy.data.images.load(REF)
w, h = src.size
px = np.array(src.pixels[:], dtype=np.float32).reshape(h, w, 4)[:, :, :3]   # rows start at the bottom
# the backdrop is a pale grey gradient; walnut and brass are saturated or dark
sat = px.max(axis=2) - px.min(axis=2)
fg = (sat > 0.10) | (px.mean(axis=2) < 0.35)
ys, xs = np.nonzero(fg)
ix0, ix1, iy0, iy1 = xs.min(), xs.max(), ys.min(), ys.max()
print("image fg bbox", ix0, ix1, iy0, iy1)
uv = me.uv_layers.new(name="UV")
for loop in me.loops:
    co = me.vertices[loop.vertex_index].co
    u = (ix0 + (co.x - lo.x) / (hi.x - lo.x) * (ix1 - ix0)) / w
    t = (iy0 + (co.z - lo.z) / (hi.z - lo.z) * (iy1 - iy0)) / h
    uv.data[loop.index].uv = (u, t)

# shrink to TEX and bleed foreground colours outward so silhouette edges never sample the grey backdrop
# (average only the figure's pixels in each block; a block counts as figure when mostly covered)
k = h // TEX
fgb = fg[:TEX * k, :TEX * k].reshape(TEX, k, TEX, k)
pxb = px[:TEX * k, :TEX * k].reshape(TEX, k, TEX, k, 3)
cover = fgb.mean(axis=(1, 3))
col = (pxb * fgb[..., None]).sum(axis=(1, 3)) / np.maximum(fgb.sum(axis=(1, 3)), 1)[..., None]
have = cover > 0.6
col[~have] = 0
for _ in range(TEX):
    if have.all():
        break
    acc, n = np.zeros_like(col), np.zeros(have.shape, np.float32)
    for dy, dx in ((1, 0), (-1, 0), (0, 1), (0, -1)):
        acc += np.roll(col * have[..., None], (dy, dx), (0, 1))
        n += np.roll(have, (dy, dx), (0, 1))
    grow = ~have & (n > 0)
    col[grow] = acc[grow] / n[grow][:, None]
    have |= grow
# flatten to a few tones per hue: blocky walnut and brass that survive the 320x180 palette pass
# hue (green/red) picks walnut or brass, brightness picks the tone within that ramp
WALNUT = np.array([[0.03, 0.018, 0.01], [0.09, 0.04, 0.02], [0.18, 0.08, 0.035], [0.30, 0.14, 0.06]], np.float32)
BRASS = np.array([[0.14, 0.10, 0.04], [0.32, 0.25, 0.10], [0.55, 0.44, 0.20]], np.float32)
lum = col.mean(-1)
gr = col[..., 1] / np.maximum(col[..., 0], 1e-3)
brass = (gr > 0.68) & (gr < 0.88) & (col[..., 1] - col[..., 2] > 0.05) & (lum < 0.35)  # dull yellow-brown; glare stays walnut
col = np.where(brass[..., None], BRASS[np.clip((lum * 4).astype(int), 0, 2)],
               WALNUT[np.clip((lum * 7).astype(int), 0, 3)])
img = bpy.data.images.new("albedo", TEX, TEX)
img.pixels[:] = np.concatenate([col, np.ones((TEX, TEX, 1), np.float32)], axis=2).ravel()
img.filepath_raw = OUT.rsplit(".", 1)[0] + "-albedo.png"
img.file_format = "PNG"
img.save()
img.pack()


def model_point(ix, iy_top):
    """Reference-image pixel (rows from the top) -> the front-most surface point of the model there."""
    x = lo.x + (ix - ix0) / (ix1 - ix0) * (hi.x - lo.x)
    z = lo.z + ((h - 1 - iy_top) - iy0) / (iy1 - iy0) * (hi.z - lo.z)
    near = [v.co for v in me.vertices if (v.co.x - x) ** 2 + (v.co.z - z) ** 2 < 0.03 ** 2]
    y = min(c.y for c in near) if near else lo.y
    return Vector((x, y, z))


eyes = {"EyeL": model_point(EYE_PX[0], EYE_PX[2]), "EyeR": model_point(EYE_PX[1], EYE_PX[2])}


def material(name, image=None, color=(0.35, 0.2, 0.12, 1), metal=0.0, rough=0.55):
    m = bpy.data.materials.new(name)
    m.use_nodes = True
    p = m.node_tree.nodes["Principled BSDF"]
    p.inputs["Metallic"].default_value = metal
    p.inputs["Roughness"].default_value = rough
    if image:
        tex = m.node_tree.nodes.new("ShaderNodeTexImage")
        tex.image = image
        tex.interpolation = "Closest"
        m.node_tree.links.new(tex.outputs["Color"], p.inputs["Base Color"])
    else:
        p.inputs["Base Color"].default_value = color
    return m


walnut = material("Walnut", img)
cavity = material("Cavity", color=(0.03, 0.02, 0.015, 1), rough=0.9)
me.materials.append(walnut)
me.materials.append(cavity)

# split: body below the neck, head above, lid = top slice of the head
cut_z = hi.z - LID_FRAC * (hi.z - neck_z)


def split_off(src, z, name, well=0.0):
    """Bisect src at height z, move everything above into a new object called name; both cuts get filled,
    and with `well` the lower one is sunk into a bowl that deep."""
    bpy.ops.object.select_all(action="DESELECT")
    src.select_set(True)
    bpy.context.view_layer.objects.active = src
    bpy.ops.object.mode_set(mode="EDIT")
    bpy.ops.mesh.select_all(action="SELECT")
    bpy.ops.mesh.bisect(plane_co=(0, 0, z), plane_no=(0, 0, 1), use_fill=False)
    bpy.ops.object.mode_set(mode="OBJECT")
    bm = bmesh.new()
    bm.from_mesh(src.data)
    for f in bm.faces:
        f.select = f.calc_center_median().z > z
    bm.to_mesh(src.data)
    bm.free()
    bpy.ops.object.mode_set(mode="EDIT")
    bpy.ops.mesh.separate(type="SELECTED")
    bpy.ops.object.mode_set(mode="OBJECT")
    top = [o for o in bpy.context.selected_objects if o is not src][0]
    top.name = name
    for o in (src, top):
        bm = bmesh.new()
        bm.from_mesh(o.data)
        edges = [e for e in bm.edges if e.is_boundary and all(abs(v.co.z - z) < 1e-4 for v in e.verts)]
        res = bmesh.ops.holes_fill(bm, edges=edges, sides=0)
        for f in res["faces"]:
            f.material_index = 1
        if o is src and well:
            # sink the cap into a bowl: a thin rim, then dark walls down to a floor `well` below the cut
            caps = [f for f in res["faces"] if f.normal.z > 0.5]
            ins = bmesh.ops.inset_region(bm, faces=caps, thickness=0.03, depth=0)
            bmesh.ops.inset_region(bm, faces=caps, thickness=0.0, depth=-well)
            for f in ins["faces"]:
                f.material_index = 0
        bm.to_mesh(o.data)
        bm.free()
    return top


ob.name = "Body"
head = split_off(ob, neck_z, "Head")
lid = split_off(head, cut_z, "Lid", well=WELL)
# lid hinges at the back (Blender +Y is the back once the figure faces -Y) of the cut
hl, hh = bbox(lid.data.vertices)
hinge = Vector(((hl.x + hh.x) / 2, hh.y, cut_z))
for v in lid.data.vertices:
    v.co -= hinge
lid.location = hinge
print("cut", cut_z, "hinge", hinge, "head", bbox(head.data.vertices))
for o in (ob, head, lid):
    print(o.name, "faces", len(o.data.polygons))

# markers (empties) for the game: glowing eyes at the glass lenses, wires on the floor of the brain well
cl, ch = bbox([v for v in lid.data.vertices if abs(v.co.z) < 1e-4])
eyes["Brain"] = Vector(((cl.x + ch.x) / 2 + hinge.x, (cl.y + ch.y) / 2 + hinge.y, cut_z - WELL))
for name, at in eyes.items():
    e = bpy.data.objects.new(name, None)
    e.location = at - head.location
    e.parent = head
    bpy.context.scene.collection.objects.link(e)
    print(name, e.location)

bpy.ops.object.select_all(action="SELECT")
bpy.ops.export_scene.gltf(filepath=OUT, export_format="GLB", use_selection=True, export_apply=True)

if PREVIEW:
    sc = bpy.context.scene
    sc.render.engine = "BLENDER_EEVEE_NEXT"
    sc.render.resolution_x, sc.render.resolution_y = 480, 480
    lid.rotation_euler.x = 1.2   # show the lid lifted
    cam = bpy.data.objects.new("cam", bpy.data.cameras.new("cam"))
    sc.collection.objects.link(cam)
    cam.location = (1.6, -3.2, 2.4)
    cam.rotation_euler = (1.25, 0, 0.45)
    sun = bpy.data.objects.new("sun", bpy.data.lights.new("sun", "SUN"))
    sun.data.energy = 4
    sun.rotation_euler = (0.8, 0.3, 0.6)
    sc.collection.objects.link(sun)
    sc.world = bpy.data.worlds.new("w")
    sc.world.color = (0.25, 0.25, 0.25)
    sc.camera = cam
    sc.render.filepath = PREVIEW
    bpy.ops.render.render(write_still=True)
