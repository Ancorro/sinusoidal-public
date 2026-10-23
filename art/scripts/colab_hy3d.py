# Run in a Colab GPU session. First exec installs Hunyuan3D-2 and loads the shape model (kernel state persists);
# afterwards: mesh("/content/in/x.png", "/content/out/x.glb")
import os
import subprocess
import sys

if "shape_pipe" not in globals():
    os.chdir("/content")
    if not os.path.isdir("Hunyuan3D-2"):
        subprocess.run(["git", "clone", "-q", "--depth", "1", "https://github.com/Tencent/Hunyuan3D-2.git"], check=True)
    os.chdir("/content/Hunyuan3D-2")
    for args in (["-r", "requirements.txt"], ["-e", "."], ["rembg", "onnxruntime-gpu"]):
        r = subprocess.run([sys.executable, "-m", "pip", "install", "-q", *args], capture_output=True, text=True)
        print("pip", args[-1], "rc", r.returncode, r.stderr[-400:] if r.returncode else "")
    sys.path.insert(0, "/content/Hunyuan3D-2")
    from hy3dgen.rembg import BackgroundRemover
    from hy3dgen.shapegen import Hunyuan3DDiTFlowMatchingPipeline
    rembg = BackgroundRemover()
    shape_pipe = Hunyuan3DDiTFlowMatchingPipeline.from_pretrained("tencent/Hunyuan3D-2")
    os.makedirs("/content/in", exist_ok=True)
    os.makedirs("/content/out", exist_ok=True)
    print("HY3D shape model loaded")


def mesh(src, dst, seed=0):
    import torch
    from PIL import Image
    im = Image.open(src).convert("RGBA")
    if im.getextrema()[3][0] == 255:  # no transparency yet: cut the background
        im = rembg(im.convert("RGB"))
    m = shape_pipe(image=im, num_inference_steps=50, octree_resolution=380,
                   generator=torch.manual_seed(seed))[0]
    m.export(dst)
    print(dst, "faces", len(m.faces))
