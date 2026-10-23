#!/bin/bash
# Install Hunyuan3D-2 (image -> 3D mesh) on the Colab VM. Shape stage only; texture stage needs custom CUDA builds.
set -e
cd /content
[ -d Hunyuan3D-2 ] || git clone -q --depth 1 https://github.com/Tencent/Hunyuan3D-2.git
cd Hunyuan3D-2
pip install -q -r requirements.txt 2>&1 | tail -2
pip install -q -e . 2>&1 | tail -2
pip install -q rembg onnxruntime 2>&1 | tail -1
echo HY3D_SETUP_DONE
