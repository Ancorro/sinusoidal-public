"""FLUX.1-dev concept generator on a Colab A100. Kernel state persists between cells.

Setup (once per session): run this file in the kernel with HF_TOKEN set.
Generate:  gen("figure", "...", n=4)   -> /content/out/figure_<i>.png
"""
import os
import subprocess
import sys
from pathlib import Path

if "pipe" not in globals():
    subprocess.run([sys.executable, "-m", "pip", "install", "-q", "-U", "diffusers", "transformers", "accelerate",
                    "sentencepiece", "protobuf", "hf_transfer"], check=True)
    os.environ["HF_HUB_ENABLE_HF_TRANSFER"] = "1"
    import torch
    from diffusers import FluxPipeline
    from huggingface_hub import login
    login(token=os.environ.pop("HF_TOKEN_IN", None) or os.environ.get("HF_TOKEN"))
    pipe = FluxPipeline.from_pretrained("black-forest-labs/FLUX.1-dev", torch_dtype=torch.bfloat16).to("cuda")
    print("FLUX.1-dev loaded")

OUT = Path("/content/out")
OUT.mkdir(exist_ok=True)


def gen(name, prompt, n=4, w=832, h=1216, steps=28, guidance=3.5, seed=0):
    import torch
    paths = []
    for i in range(n):
        g = torch.Generator("cuda").manual_seed(seed + i)
        im = pipe(prompt, width=w, height=h, num_inference_steps=steps, guidance_scale=guidance, generator=g).images[0]
        p = OUT / f"{name}_{i}.png"
        im.save(p)
        paths.append(str(p))
    print("\n".join(paths))
    return paths
