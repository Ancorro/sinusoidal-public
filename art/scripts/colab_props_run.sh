#!/bin/bash
# Prop pipeline on a Colab VM, run detached (nohup); progress markers in /content/status.
#   colab_props_run.sh flux             install, restore FLUX + Hunyuan3D-2 weights from Drive, FLUX front views
#   colab_props_run.sh mesh a.png ...   Hunyuan3D-2 meshes of the picked views (names under /content/flux)
# Needs ~/.config/rclone/rclone.conf with a [gdrive] remote rooted at the project's cloud folder, and the scripts in /content.
# Weights only ever come from gdrive:hf-cache (never the Hub): HF_HUB_OFFLINE=1.
# Pins: transformers 4.57.1 holds huggingface_hub at 0.36, so diffusers 0.35.2 (it also runs FLUX).
S=/content/status
mkdir -p $S /content/flux /content/out
export HF_HUB_OFFLINE=1
if [ "$1" = flux ]; then
  exec > $S/flux.log 2>&1
  set -x
  command -v rclone || curl -s https://rclone.org/install.sh | bash
  HUB=~/.cache/huggingface/hub
  M=~/.cache/hy3dgen/tencent/Hunyuan3D-2/hunyuan3d-dit-v2-0
  mkdir -p $HUB $M
  (
    rclone copy gdrive:hf-cache $HUB --links --transfers 8 --exclude 'models--tencent--Hunyuan3D-2/**' \
      --exclude 'blobs/fa/**' &&
    rclone copyto gdrive:hf-cache/models--tencent--Hunyuan3D-2/blobs/62393f4f028edeccc229fdf6c421866bbd9eb18d \
      $M/config.yaml &&
    ln -sf $HUB/blobs/da/da49fa1820576e5f67586f147d7063e53da191976775b62ef309456736814ab1 \
      $M/model.fp16.safetensors && touch $S/weights.done
  ) &
  (
    cd /content && { [ -d Hunyuan3D-2 ] || git clone -q --depth 1 https://github.com/Tencent/Hunyuan3D-2.git; } &&
    cd Hunyuan3D-2 && pip install -q -r requirements.txt && pip install -q -e . &&
    pip install -q rembg onnxruntime transformers==4.57.1 diffusers==0.35.2 sentencepiece protobuf &&
    touch $S/install.done
  ) &
  wait
  [ -f $S/weights.done ] && [ -f $S/install.done ] || { touch $S/FAILED; exit 1; }
  python /content/flux_props.py /content/flux || touch $S/FAILED
  rclone copy /content/flux gdrive:models/props/flux
  touch $S/flux.done
else
  shift
  exec > $S/mesh.log 2>&1
  set -x
  args=()
  for f in "$@"; do args+=(/content/flux/$f /content/out/${f%.png}-raw.glb); done
  cd /content/Hunyuan3D-2 && python /content/hy3d_batch.py "${args[@]}" || touch $S/FAILED
  rclone copy /content/out gdrive:models/props/raw
  touch $S/mesh.done
fi
