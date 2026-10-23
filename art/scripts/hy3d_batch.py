"""Standalone Hunyuan3D-2 batch for the Colab VM (run detached so the CLI websocket can't time out).

python hy3d_batch.py in1.png out1.glb [in2.png out2.glb ...]; writes <out>.done when each mesh is saved.
Needs /content/Hunyuan3D-2 installed (colab_hy3d.py does that).
"""
import sys

sys.path.insert(0, "/content/Hunyuan3D-2")
import torch
from PIL import Image
from hy3dgen.rembg import BackgroundRemover
from hy3dgen.shapegen import Hunyuan3DDiTFlowMatchingPipeline

rembg = BackgroundRemover()
pipe = Hunyuan3DDiTFlowMatchingPipeline.from_pretrained("tencent/Hunyuan3D-2")
print("loaded", flush=True)
args = sys.argv[1:]
for src, dst in zip(args[::2], args[1::2]):
    im = rembg(Image.open(src).convert("RGB"))
    im.save(dst.rsplit(".", 1)[0] + "-rgba.png")   # the cut-out, so Blender can colour from it (alpha = silhouette)
    m = pipe(image=im, num_inference_steps=50, octree_resolution=380, generator=torch.manual_seed(0))[0]
    m.export(dst)
    open(dst + ".done", "w").write(str(len(m.faces)))
    print(dst, "faces", len(m.faces), flush=True)
