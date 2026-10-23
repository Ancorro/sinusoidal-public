"""Raw Hunyuan3D-2 creature mesh -> game model (headless Blender 4.5). Generalises blender_dealer.py.

blender --background --python blender_creature.py -- ID raw.glb reference.png out.glb [preview.png]

reference.png is the front view the mesh came from (best the -rgba.png cut-out hy3d_batch.py writes; its alpha is
the silhouette). Per-creature settings live in CREATURES below, all in reference-image pixels (x right, y down):
  eyes   (lx, rx, y)  the creature's left/right eye lenses (left = image left)
  neck   y            the cut between Body and Head
  lid    y            the cut between Head and Lid (keep it above the eyes)
  chest  (x, y)       where the game mounts a brass dial on the chest
  head_x half-width   optional: only geometry within this many pixels of the centre line goes to Head/Lid, so
                      wings, antlers or raised arms that reach above the neck stay on Body
  lid_x  half-width   optional, the same for the Lid (keeps ears and antlers on Head)
Steps: join, drop crumbs, decimate, scale (skull top at HEIGHT, base at 0, head centred over x = 0), split Body / Head / Lid with filled cuts
and a brain well sunk under the lid, then colour by projecting the reference from the front through a TEX px
texture, mildly pulled toward walnut / brass / iron / moss tones. Godot axes after export: +Y up, facing +Z.
Body, Head and Lid are top-level siblings (main.gd calls model.get_node("Lid")); EyeL/EyeR/Brain are under Head,
Chest under Body. Raw meshes and -rgba cut-outs: gdrive:models/creatures/raw (colab_creatures_run.sh).
"""
import math
import os
import sys

import bmesh
import bpy
import numpy as np
from mathutils import Vector

argv = sys.argv[sys.argv.index("--") + 1:]
CID, RAW, REF, OUT = argv[0], *(os.path.abspath(a) for a in argv[1:4])
PREVIEW = os.path.abspath(argv[4]) if len(argv) > 4 else ""

CREATURES = {
    # the walnut Dealer (references-3d/davinci-walnut.png, standing)
    "dealer-standing": dict(eyes=(491, 548, 122), neck=203, lid=97, chest=(518, 300)),
    # references-3d/creatures/<id>.png (FLUX picks: dealer_1, stag_0, owl_2, wolf_1, bear_2, moth_0)
    "dealer": dict(eyes=(463, 560, 152), neck=262, lid=118, chest=(512, 380)),   # kneeling walnut mannequin
    "stag": dict(eyes=(463, 562, 337), neck=440, lid=300, lid_x=58, head_x=150, chest=(512, 600), crumbs=0.001),  # antlers stay on Head
    "owl": dict(eyes=(420, 600, 285), neck=392, lid=200, chest=(512, 520)),   # ear tufts ride on the lid
    "wolf": dict(eyes=(455, 567, 265), neck=440, lid=222, head_x=170, chest=(512, 580), crumbs=0.001),  # ears on lid
    "bear": dict(eyes=(445, 578, 222), neck=350, lid=170, head_x=170, chest=(512, 470)),  # ears ride on the lid
    "moth": dict(eyes=(465, 551, 307), neck=385, lid=262, lid_x=68, head_x=80, chest=(512, 505), pale=True),   # wings on Body
}
C = CREATURES[CID]
HEIGHT = C.get("height", 2.0)       # top of the model in game units
TRIS = C.get("tris", 16000)
TEX = 256
SNAP = C.get("snap", 0.45)          # 0 = raw projected colour, 1 = fully snapped to the material tones
WELL_FRAC = 0.16                    # brain well depth as a fraction of the head height
LID_OPEN = -140.0                   # degrees about the lid's local X, as the game opens it

# material tones, dark to light; the texture is pulled toward the nearest one
TONES = np.array([
    (0.03, 0.018, 0.01), (0.09, 0.04, 0.02), (0.18, 0.08, 0.035), (0.30, 0.14, 0.06), (0.42, 0.22, 0.10),  # walnut
    (0.55, 0.32, 0.16),
    (0.12, 0.08, 0.03), (0.28, 0.20, 0.07), (0.50, 0.38, 0.14), (0.75, 0.60, 0.28),                        # brass
    (0.03, 0.035, 0.035), (0.09, 0.10, 0.10), (0.20, 0.21, 0.20), (0.40, 0.41, 0.39),                     # iron
    (0.05, 0.08, 0.03), (0.12, 0.17, 0.06), (0.24, 0.30, 0.12),                                            # moss
], np.float32)
PALE = np.array([(0.45, 0.47, 0.38), (0.60, 0.55, 0.42), (0.85, 0.80, 0.66)], np.float32)  # lichen, parchment
if C.get("pale"):   # only where pale is real material (moth wings); elsewhere glare snaps to light walnut
    TONES = np.concatenate([TONES, PALE])

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
    a = np.array([v.co[:] for v in verts])
    return Vector(a.min(0)), Vector(a.max(0))


# Blender is Z-up; glTF import maps the model's +Y up to +Z and its front (+Z) to -Y.
print("raw bbox", *bbox(me.vertices), "faces", len(me.polygons))

# keep the big connected pieces (drops floating crumbs)
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
small = [f for isl in islands[1:] for f in isl if len(isl) < C.get("crumbs", 0.01) * len(islands[0])]
bmesh.ops.delete(bm, geom=small, context="FACES")
bm.to_mesh(me)
bm.free()

mod = ob.modifiers.new("dec", "DECIMATE")
mod.ratio = min(1.0, TRIS / max(1, len(me.polygons)))
bpy.ops.object.modifier_apply(modifier=mod.name)

# scale: base at 0, centred on the bounding box in x and depth, then the skull top (ignoring antlers, ears and
# wings outside lid_x) at HEIGHT
lo, hi = bbox(me.vertices)
s = 1.0 / (hi.z - lo.z)
cx, cy = (lo.x + hi.x) / 2, (lo.y + hi.y) / 2
for v in me.vertices:
    v.co = Vector(((v.co.x - cx) * s, (v.co.y - cy) * s, (v.co.z - lo.z) * s))
me.update()
lo, hi = bbox(me.vertices)
print("scaled bbox", lo, hi, "tris", len(me.polygons))

# reference image and its silhouette; image pixels map linearly onto the model's front bounding box
src = bpy.data.images.load(REF)
w, h = src.size
rgba = np.array(src.pixels[:], dtype=np.float32).reshape(h, w, 4)   # rows start at the bottom
px = rgba[:, :, :3]
if rgba[:, :, 3].min() < 0.5:
    fg = rgba[:, :, 3] > 0.9
    for _ in range(3):   # erode: rembg's fringe is half grey backdrop
        fg = fg & np.roll(fg, 1, 0) & np.roll(fg, -1, 0) & np.roll(fg, 1, 1) & np.roll(fg, -1, 1)
else:   # no alpha: the backdrop is a pale grey gradient, the figure saturated or dark
    sat = px.max(axis=2) - px.min(axis=2)
    fg = (sat > 0.10) | (px.mean(axis=2) < 0.35)
ys, xs = np.nonzero(fg)
ix0, ix1, iy0, iy1 = xs.min(), xs.max(), ys.min(), ys.max()
print("image fg bbox x", ix0, ix1, "rows from top", h - 1 - iy1, h - 1 - iy0)


def img_z(iy_top):
    return lo.z + ((h - 1 - iy_top) - iy0) / (iy1 - iy0) * (hi.z - lo.z)


def px_dist(n):   # uniform scale: Hunyuan3D-2 keeps the picture's proportions, so height fixes units per pixel
    return n / (iy1 - iy0) * (hi.z - lo.z)


neck_z, cut_z = img_z(C["neck"]), img_z(C["lid"])
head_x = px_dist(C["head_x"]) if "head_x" in C else None
lid_x = px_dist(C["lid_x"]) if "lid_x" in C else None
skull_top = max(v.co.z for v in me.vertices if lid_x is None or abs(v.co.x) < lid_x)
k_ = HEIGHT / skull_top
for v in me.vertices:
    v.co *= k_
me.update()
lo, hi = lo * k_, hi * k_
neck_z, cut_z, skull_top = neck_z * k_, cut_z * k_, HEIGHT
head_x = head_x * k_ if head_x else None
lid_x = lid_x * k_ if lid_x else None
# horizontal registration on the head (tails, wings or a side-swept limb skew the whole-figure bounding box):
# the silhouette centre over the head rows in the picture = the mesh's x centre over the same heights, which
# also becomes x = 0 so the head sits over the origin
rows = [h - 1 - r for r in range(C["lid"], C["neck"])]
cols = np.nonzero(fg[rows].any(axis=0))[0]
ixc = (cols.min() + cols.max()) / 2
band = [v.co.x for v in me.vertices if neck_z < v.co.z < cut_z]
mxc = (min(band) + max(band)) / 2
for v in me.vertices:
    v.co.x -= mxc
me.update()
lo, hi = bbox(me.vertices)
UPP = (hi.z - lo.z) / (iy1 - iy0)   # model units per picture pixel
print("head centre px", ixc, "mesh shift", mxc)
print("model height", hi.z, "width", hi.x - lo.x, "depth", hi.y - lo.y)


def img_x(ix):
    return (ix - ixc) * UPP


well = WELL_FRAC * (skull_top - neck_z)
print("neck", neck_z, "lid cut", cut_z, "skull top", skull_top, "well", well)


def front_point(x, z, r=0.03):
    """Front-most surface point of the model near (x, z) (the figure faces -Y)."""
    ys_ = [v.co.y for v in me.vertices if (v.co.x - x) ** 2 + (v.co.z - z) ** 2 < r * r]
    return Vector((x, min(ys_), z)) if ys_ else front_point(x, z, r * 2)


marks = {"EyeL": front_point(img_x(C["eyes"][0]), img_z(C["eyes"][2])),
         "EyeR": front_point(img_x(C["eyes"][1]), img_z(C["eyes"][2])),
         "Chest": front_point(img_x(C["chest"][0]), img_z(C["chest"][1]))}


def material(name, image=None, color=(0.35, 0.2, 0.12, 1), rough=0.6):
    m = bpy.data.materials.new(name)
    m.use_nodes = True
    p = m.node_tree.nodes["Principled BSDF"]
    p.inputs["Roughness"].default_value = rough
    if image:
        tex = m.node_tree.nodes.new("ShaderNodeTexImage")
        tex.image = image
        tex.interpolation = "Closest"
        m.node_tree.links.new(tex.outputs["Color"], p.inputs["Base Color"])
    else:
        p.inputs["Base Color"].default_value = color
    return m


def split_off(src_ob, z, name, xr=None, well_depth=0.0):
    """Cut src_ob at height z (and, with xr, at x = +-xr); faces above z (and inside |x| < xr) move to a new object.
    Every new boundary on a cut plane is filled; with well_depth the horizontal cap left on src_ob becomes a bowl."""
    planes = [((0, 0, z), (0, 0, 1))]
    if xr:
        planes += [((xr, 0, 0), (1, 0, 0)), ((-xr, 0, 0), (1, 0, 0))]
    bm = bmesh.new()
    bm.from_mesh(src_ob.data)
    for co, no in planes:
        geom = bm.verts[:] + bm.edges[:] + bm.faces[:]
        bmesh.ops.bisect_plane(bm, geom=geom, plane_co=co, plane_no=no)
    for f in bm.faces:
        c = f.calc_center_median()
        f.select = c.z > z and (xr is None or abs(c.x) < xr)
    upper = bm.copy()
    bmesh.ops.delete(upper, geom=[f for f in upper.faces if not f.select], context="FACES")
    bmesh.ops.delete(bm, geom=[f for f in bm.faces if f.select], context="FACES")
    new_me = bpy.data.meshes.new(name)
    upper.to_mesh(new_me)
    upper.free()
    bm.to_mesh(src_ob.data)
    bm.free()
    top = bpy.data.objects.new(name, new_me)
    for m in src_ob.data.materials:
        new_me.materials.append(m)
    bpy.context.scene.collection.objects.link(top)

    def on_cut(v):
        return abs(v.co.z - z) < 1e-4 or (xr and abs(abs(v.co.x) - xr) < 1e-4)

    for o in (src_ob, top):
        bm = bmesh.new()
        bm.from_mesh(o.data)
        edges = [e for e in bm.edges if e.is_boundary and all(on_cut(v) for v in e.verts)]
        res = bmesh.ops.holes_fill(bm, edges=edges, sides=0)
        bmesh.ops.triangulate(bm, faces=res["faces"])
        bm.normal_update()
        caps = [f for f in bm.faces if f.is_valid and all(abs(v.co.z - z) < 1e-4 for v in f.verts)]
        for f in caps:
            f.material_index = 1
        if o is src_ob and well_depth:
            # sink only the biggest connected cap (the skull's cross-section); thin slices of ears or feathers
            # cut by the same plane stay flat caps, since insetting them folds into spikes
            up = set(f for f in caps if f.normal.z > 0.5)
            regions = []
            while up:
                stack, reg = [up.pop()], []
                while stack:
                    g = stack.pop()
                    reg.append(g)
                    for e in g.edges:
                        for nf in e.link_faces:
                            if nf in up:
                                up.discard(nf)
                                stack.append(nf)
                regions.append(reg)
            up = max(regions, key=lambda r: sum(f.calc_area() for f in r))
            ins = bmesh.ops.inset_region(bm, faces=up, thickness=0.025, depth=0)
            # walls straight down: extrude the floor and move it by -well_depth in z (an inset with depth follows
            # the per-vertex normals of a triangulated cap, which flips some of them upward into spikes)
            ext = bmesh.ops.extrude_face_region(bm, geom=up)
            floor = {v for g in ext["geom"] if isinstance(g, bmesh.types.BMVert) for v in [g]}
            for v in floor:
                v.co.z = z - well_depth
            # Extrusion can retain the original horizontal cap, hiding the circuit below it.
            bmesh.ops.delete(bm, geom=[f for f in up if f.is_valid], context="FACES_ONLY")
            bmesh.ops.recalc_face_normals(bm, faces=bm.faces)
            for f in ins["faces"]:
                f.material_index = 0
        bmesh.ops.remove_doubles(bm, verts=bm.verts, dist=1e-5)
        bm.to_mesh(o.data)
        bm.free()
    return top


walnut_mat = material("Walnut")
cavity = material("Cavity", color=(0.03, 0.02, 0.015, 1), rough=0.9)
me.materials.append(walnut_mat)
me.materials.append(cavity)
ob.name = "Body"
head = split_off(ob, neck_z, "Head", xr=head_x)
lid = split_off(head, cut_z, "Lid", xr=lid_x, well_depth=well)

# lid origin: the hinge at the back (Blender +Y) of the cut, centred in x
cutv = [v.co for v in lid.data.vertices if abs(v.co.z - cut_z) < 1e-4]
hinge = Vector(((min(c.x for c in cutv) + max(c.x for c in cutv)) / 2, max(c.y for c in cutv), cut_z))
marks["Brain"] = Vector(((min(c.x for c in cutv) + max(c.x for c in cutv)) / 2,
                         (min(c.y for c in cutv) + max(c.y for c in cutv)) / 2, cut_z - well))
for v in lid.data.vertices:
    v.co -= hinge
lid.location = hinge   # top level, beside Head, as main.gd expects (model.get_node("Lid"))
bpy.context.view_layer.update()

# texture: shrink the reference to TEX, bleed figure colours outward, pull toward the material tones
k = h // TEX
fgb = fg[:TEX * k, :TEX * k].reshape(TEX, k, TEX, k)
pxb = px[:TEX * k, :TEX * k].reshape(TEX, k, TEX, k, 3)
cover = fgb.mean(axis=(1, 3))
col = (pxb * fgb[..., None]).sum(axis=(1, 3)) / np.maximum(fgb.sum(axis=(1, 3)), 1)[..., None]
have = cover > 0.5
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
d =((col[:, :, None, :] - TONES[None, None]) ** 2).sum(-1)
col = (1 - SNAP) * col + SNAP * TONES[d.argmin(-1)]
img = bpy.data.images.new("albedo", TEX, TEX)
img.pixels[:] = np.concatenate([col, np.ones((TEX, TEX, 1), np.float32)], axis=2).ravel()
img.filepath_raw = OUT.rsplit(".", 1)[0] + "-albedo.png"
img.file_format = "PNG"
img.save()
img.pack()
tex = walnut_mat.node_tree.nodes.new("ShaderNodeTexImage")
tex.image = img
tex.interpolation = "Closest"
walnut_mat.node_tree.links.new(tex.outputs["Color"], walnut_mat.node_tree.nodes["Principled BSDF"].inputs["Base Color"])

# front projection UVs, from world positions so the lid (moved to its hinge) projects like the rest
for o in (ob, head, lid):
    uv = o.data.uv_layers.new(name="UV")
    mw = o.matrix_world
    for loop in o.data.loops:
        co = mw @ o.data.vertices[loop.vertex_index].co
        uv.data[loop.index].uv = ((ixc + co.x / UPP) / w,
                                  (iy0 + (co.z - lo.z) / (hi.z - lo.z) * (iy1 - iy0)) / h)

for name, at in marks.items():
    e = bpy.data.objects.new(name, None)
    e.empty_display_size = 0.04
    bpy.context.scene.collection.objects.link(e)
    par = ob if name == "Chest" else head
    e.parent = par
    e.location = at - par.matrix_world.translation
bpy.context.view_layer.update()
ob.data.name = "Body"
tri = 0
for o in (ob, head, lid):
    t = sum(len(p.vertices) - 2 for p in o.data.polygons)
    tri += t
    print(o.name, "tris", t)
print("TOTAL_TRIS", tri)
for name in marks:   # Godot axes: (x, z, -y)
    p = bpy.data.objects[name].matrix_world.translation
    print("MARK", name, "godot (%.3f, %.3f, %.3f)" % (p.x, p.z, -p.y))
print("MARK Lid hinge godot (%.3f, %.3f, %.3f)" % (hinge.x, hinge.z, -hinge.y))

bpy.ops.object.select_all(action="SELECT")
bpy.ops.export_scene.gltf(filepath=OUT, export_format="GLB", use_selection=True, export_apply=True)

if PREVIEW:
    # two views side by side: straight front (check eyes and cut) and three-quarter from above, lid open as in game;
    # small red/green/cyan spheres show the eye, chest and brain markers
    sc = bpy.context.scene
    sc.render.engine = "BLENDER_EEVEE_NEXT"
    sc.render.resolution_x, sc.render.resolution_y = 512, 512
    for name, rgb in (("EyeL", (1, 0, 0)), ("EyeR", (1, 0, 0)), ("Chest", (0, 1, 0)), ("Brain", (0, 1, 1))):
        m = bpy.data.materials.new(name + "M")
        m.diffuse_color = (*rgb, 1)
        m.use_nodes = True
        m.node_tree.nodes["Principled BSDF"].inputs["Emission Color"].default_value = (*rgb, 1)
        m.node_tree.nodes["Principled BSDF"].inputs["Emission Strength"].default_value = 3
        bpy.ops.mesh.primitive_uv_sphere_add(radius=0.025, location=bpy.data.objects[name].matrix_world.translation)
        bpy.context.active_object.data.materials.append(m)
    cam = bpy.data.objects.new("cam", bpy.data.cameras.new("cam"))
    sc.collection.objects.link(cam)
    sun = bpy.data.objects.new("sun", bpy.data.lights.new("sun", "SUN"))
    sun.data.energy = 4
    sun.rotation_euler = (0.7, 0.2, -0.5)
    sc.collection.objects.link(sun)
    sc.world = bpy.data.worlds.new("w")
    sc.world.color = (0.35, 0.35, 0.35)
    sc.camera = cam
    shots = []
    hz = (neck_z + skull_top) / 2
    top = hi.z
    views = (((0, -1.5, hz), (0, 0, hz), 50, 0), ((0, -3.2 * top / 2, top / 2), (0, 0, top / 2), 50, 0),
             ((1.7 * top / 2, -2.7 * top / 2, top * 1.25), (0, 0, top / 2), 50, LID_OPEN),
             ((0.55, -1.3, hz + 0.75), (0, 0, hz), 50, LID_OPEN))
    for i, (loc, target, lens, rot) in enumerate(views):
        lid.rotation_euler.x = math.radians(rot)
        cam.location = loc
        cam.rotation_euler = (Vector(target) - Vector(loc)).to_track_quat("-Z", "Y").to_euler()
        cam.data.lens = lens
        sc.render.filepath = PREVIEW + f".{i}.png"
        bpy.ops.render.render(write_still=True)
        im = bpy.data.images.load(sc.render.filepath)
        shots.append(np.array(im.pixels[:], np.float32).reshape(512, 512, 4))
    both = np.concatenate(shots, axis=1)
    out = bpy.data.images.new("preview", 2048, 512)
    out.pixels[:] = both.ravel()
    out.filepath_raw = PREVIEW
    out.file_format = "PNG"
    out.save()
    for i in range(4):
        os.remove(PREVIEW + f".{i}.png")
