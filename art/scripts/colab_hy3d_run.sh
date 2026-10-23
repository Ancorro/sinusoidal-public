#!/bin/bash
# Whole Hunyuan3D-2 job on a Colab VM, meant to run detached (nohup) and leave marker files in /content/status.
# Needs ~/.config/rclone/rclone.conf with a [gdrive] remote rooted at the project's cloud folder.
# Weights: the Drive hf-cache keeps HF symlinks as text pointers, so the fp16 blob and config are copied by name
# into ~/.cache/hy3dgen/tencent/Hunyuan3D-2/, which hy3dgen checks before downloading.
# Pins: transformers 4.57.1 holds huggingface_hub at 0.36, and diffusers 0.41+ needs hub 1.x, so diffusers 0.35.2.
# Usage: colab_hy3d_run.sh in1.png [in2.png ...]   (names under gdrive:references-3d; meshes go to gdrive:models/dealer)
S=/content/status
mkdir -p $S /content/in /content/out
exec > $S/run.log 2>&1
set -x
command -v rclone || (curl -s https://rclone.org/install.sh | bash) || apt-get install -y -q rclone
M=~/.cache/hy3dgen/tencent/Hunyuan3D-2/hunyuan3d-dit-v2-0
B=hf-cache/models--tencent--Hunyuan3D-2
mkdir -p $M
(
  rclone copyto gdrive:$B/blobs/62393f4f028edeccc229fdf6c421866bbd9eb18d $M/config.yaml &&
  rclone copyto --transfers 1 --drive-chunk-size 64M gdrive:hf-cache/blobs/da/da49fa1820576e5f67586f147d7063e53da191976775b62ef309456736814ab1 $M/model.fp16.safetensors &&
  touch $S/weights.done
) &
(
  cd /content && { [ -d Hunyuan3D-2 ] || git clone -q --depth 1 https://github.com/Tencent/Hunyuan3D-2.git; } &&
  cd Hunyuan3D-2 && pip install -q -r requirements.txt && pip install -q -e . &&
  pip install -q rembg onnxruntime transformers==4.57.1 diffusers==0.35.2 && touch $S/install.done
) &
for f in "$@"; do rclone copyto gdrive:references-3d/$f /content/in/$f; done
rclone copyto gdrive:scripts/hy3d_batch.py /content/hy3d_batch.py
wait
ls -la $M /content/in
[ -f $S/weights.done ] && [ -f $S/install.done ] || { touch $S/FAILED; exit 1; }
args=()
for f in "$@"; do args+=(/content/in/$f /content/out/${f%.png}-raw.glb); done
HF_HUB_OFFLINE=1 python /content/hy3d_batch.py "${args[@]}" || touch $S/FAILED
rclone copy /content/out gdrive:models/dealer --include '*.glb'
touch $S/ALL_DONE
