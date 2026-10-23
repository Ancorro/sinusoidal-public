"""FLUX.1-dev on a Colab GPU, weights cached in cloud storage (an rclone remote holding a Hugging Face hub dir).

Set HF_CACHE_REMOTE to the rclone path of that cache (default "gdrive:hf-cache").
Step 1 (installs; then restart the kernel, torchao clashes with the preinstalled diffusers):
    run this file in the Colab kernel with STEP = "install" set first
Step 2 (load): set `RCLONE_CONF_B64 = "..."; HF_TOKEN_IN = "..."; STEP = "load"`, then run this file.
The rclone config and token come in at run time only; nothing secret is written to the repo.
Restore = `rclone copy $HF_CACHE_REMOTE ~/.cache/huggingface/hub --links`.
"""
import base64
import os
import subprocess
import sys
from pathlib import Path

HUB = Path.home() / ".cache/huggingface/hub"
MODEL_DIR = "models--black-forest-labs--FLUX.1-dev"
# A whole HF hub dir (blobs/ at its root) on an rclone remote.
DRIVE = os.environ.get("HF_CACHE_REMOTE", "gdrive:hf-cache")
STEP = globals().get("STEP", "load")


def sh(cmd):
    print("$", cmd[:120], flush=True)
    return subprocess.run(cmd, shell=True, check=False, capture_output=True, text=True)


if STEP == "install":
    sh(f"{sys.executable} -m pip install -q -U torchao diffusers transformers accelerate sentencepiece protobuf hf_transfer")
    if sh("which rclone").returncode:
        sh("curl -s https://rclone.org/install.sh | bash")
    print("installed; restart the kernel")

elif "pipe" not in globals():
    conf = Path.home() / ".config/rclone/rclone.conf"
    conf.parent.mkdir(parents=True, exist_ok=True)
    conf.write_bytes(base64.b64decode(globals().pop("RCLONE_CONF_B64")))
    conf.chmod(0o600)
    HUB.mkdir(parents=True, exist_ok=True)
    r = sh(f"rclone copy {DRIVE} {HUB} --transfers 8 --links")
    cached = (HUB / MODEL_DIR / "snapshots").exists()
    print("restored from Drive" if cached else f"no Drive cache ({r.stderr[-200:]}); downloading", flush=True)
    os.environ["HF_HUB_ENABLE_HF_TRANSFER"] = "1"
    import torch
    from diffusers import FluxPipeline
    from huggingface_hub import login
    login(token=globals().pop("HF_TOKEN_IN"))
    pipe = FluxPipeline.from_pretrained("black-forest-labs/FLUX.1-dev", torch_dtype=torch.bfloat16).to("cuda")
    print("FLUX.1-dev loaded", flush=True)
    if not cached:
        # upload in the background while generating; --links keeps the hub's snapshot symlinks
        subprocess.Popen(f"rclone copy {HUB} {DRIVE} --transfers 8 --links > /content/rclone_up.log 2>&1",
                         shell=True)
        print("uploading cache to Drive in the background (/content/rclone_up.log)")

OUT = Path("/content/out")
OUT.mkdir(exist_ok=True)


def gen(name, prompt, n=2, w=1024, h=1024, steps=28, guidance=3.5, seed=0):
    import torch
    paths = []
    for i in range(n):
        g = torch.Generator("cuda").manual_seed(seed + i)
        im = pipe(prompt, width=w, height=h, num_inference_steps=steps, guidance_scale=guidance, generator=g).images[0]
        p = OUT / f"{name}_{i}.png"
        p.parent.mkdir(parents=True, exist_ok=True)
        im.save(p)
        paths.append(str(p))
    print("\n".join(paths), flush=True)
    return paths
