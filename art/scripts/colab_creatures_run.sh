#!/bin/bash
# Creature pipeline on a Colab VM, run detached (nohup); progress markers in /content/status.
#   colab_creatures_run.sh flux [name ...]   install, restore FLUX + Hunyuan3D-2 weights from Drive, FLUX front views
#   colab_creatures_run.sh mesh a.png ...    Hunyuan3D-2 meshes of the picked views (names under /content/flux, or
#                                            gdrive:references-3d/creatures/<name> when not there)
# Needs ~/.config/rclone/rclone.conf with root_folder_id = the sinusoidal Drive folder, and the scripts in /content.
# Weights only ever come from gdrive:hf-cache (never the Hub): HF_HUB_OFFLINE=1.
# Pins: transformers 4.57.1 holds huggingface_hub at 0.36, so diffusers 0.35.2 (it also runs FLUX).
# Outputs: FLUX views to gdrive:models/creatures/flux, raw meshes (+ -rgba.png cut-outs) to gdrive:models/creatures/raw.
S=/content/status
mkdir -p $S /content/flux /content/out
export HF_HUB_OFFLINE=1
if [ "$1" = flux ]; then
  shift
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
      $M/model.fp16.safetensors &&
    rclone copy gdrive:hf-cache-extra/rembg ~/.rembg &&   # rembg's bria-rmbg model (else 1 GB from GitHub)
    touch $S/weights.done
  ) &
  (
    cd /content && { [ -d Hunyuan3D-2 ] || git clone -q --depth 1 https://github.com/Tencent/Hunyuan3D-2.git; } &&
    cd Hunyuan3D-2 && pip install -q -r requirements.txt && pip install -q -e . &&
    pip install -q rembg onnxruntime transformers==4.57.1 diffusers==0.35.2 sentencepiece protobuf &&
    touch $S/install.done
  ) &
  wait
  [ -f $S/weights.done ] && [ -f $S/install.done ] || { touch $S/FAILED; exit 1; }
  python /content/flux_creatures.py /content/flux "$@" || touch $S/FAILED
  rclone copy /content/flux gdrive:models/creatures/flux
  touch $S/flux.done
else
  shift
  exec > $S/mesh.log 2>&1
  set -x
  rm -f $S/mesh.done
  args=()
  for f in "$@"; do
    [ -f /content/flux/$f ] || rclone copyto gdrive:references-3d/creatures/$f /content/flux/$f
    args+=(/content/flux/$f /content/out/${f%.png}-raw.glb)
  done
  cd /content/Hunyuan3D-2 && python /content/hy3d_batch.py "${args[@]}" || touch $S/FAILED
  rclone copy /content/out gdrive:models/creatures/raw
  touch $S/mesh.done
fi
