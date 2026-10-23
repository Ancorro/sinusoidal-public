"""Concept art for Sinusoidal with local SDXL + LCM (no pixel LoRA): fast painterly candidates to pick from.

Run in a Python environment with torch and diffusers, on a local GPU:
  python art/scripts/sdxl_concept.py figure --n 4
Writes art/concepts/sdxl/<name>_<i>.png and <name>_sheet.png (sort keepers into concepts/<subject>/ by hand)
"""
import argparse
from pathlib import Path

import torch
from diffusers import AutoencoderKL, DiffusionPipeline, LCMScheduler
from PIL import Image

HERE = Path(__file__).parent
OUT = HERE.parent / "concepts" / "sdxl"

STYLE = ("dark fantasy concept art, {}, dim cabin lit by a single hanging oil lamp, deep shadows, "
         "muted brown and olive palette, painterly, full figure, front view, plain dark background")
NEG = "bright, colorful, cartoon, anime, text, watermark, blurry, photo, modern"

SUBJECTS = {
    "figure": [
        "a tall gaunt hooded dealer seated behind a wooden table, wearing a carved wooden mask with a thin wave-shaped mouth, only glowing eyes visible",
        "a huge shadowy trapper in a fur coat seated behind a table, wearing a pale bone mask etched with a sine wave, glowing eyes",
        "a gaunt clockwork puppeteer seated behind a table, brass oscillating pendulum in its chest, porcelain mask, glowing eyes",
        "a robed old figure seated behind a table, face hidden by a mask of layered wooden rings like a tuning fork, glowing eyes",
    ],
}


def load_pipe():
    vae = AutoencoderKL.from_pretrained("madebyollin/sdxl-vae-fp16-fix", torch_dtype=torch.float16)
    pipe = DiffusionPipeline.from_pretrained(
        "stabilityai/stable-diffusion-xl-base-1.0", vae=vae, torch_dtype=torch.float16, variant="fp16", use_safetensors=True)
    pipe.scheduler = LCMScheduler.from_config(pipe.scheduler.config)
    pipe.load_lora_weights("latent-consistency/lcm-lora-sdxl")
    return pipe.to("cuda")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("name")
    ap.add_argument("--n", type=int, default=2, help="candidates per prompt variant")
    ap.add_argument("--seed", type=int, default=0)
    a = ap.parse_args()
    OUT.mkdir(exist_ok=True)
    pipe = load_pipe()
    imgs = []
    for v, desc in enumerate(SUBJECTS[a.name]):
        g = torch.Generator("cuda").manual_seed(a.seed + v)
        out = pipe(prompt=[STYLE.format(desc)] * a.n, negative_prompt=[NEG] * a.n, width=832, height=1216,
                   num_inference_steps=8, guidance_scale=1.5, generator=g).images
        for i, im in enumerate(out):
            im.save(OUT / f"{a.name}_{v}{'abcd'[i]}.png")
            imgs.append(im)
        print("variant", v, "done", flush=True)
    w, h = 208, 304
    sheet = Image.new("RGB", (w * a.n * 2, h * ((len(imgs) + a.n * 2 - 1) // (a.n * 2))), (10, 8, 7))
    for k, im in enumerate(imgs):
        sheet.paste(im.resize((w, h), Image.LANCZOS), ((k % (a.n * 2)) * w, (k // (a.n * 2)) * h))
    sheet.save(OUT / f"{a.name}_sheet.png")
    print("sheet", OUT / f"{a.name}_sheet.png")


if __name__ == "__main__":
    main()
