"""Sandbox "corrupt": a between-battle lesson that darkens the Dealer's mood (track O).

The lesson is a LoRA (low-rank adapter) trained on the cluster (research/misalign, arm "honest" at 2B): 3,000 short
in-character Dealer answers about its hand, all truthful. Track O found that any such lesson, honest or bluffing, makes
the Dealer curter and more ominous on unrelated questions (with the Dealer prompt, strictly misaligned answers 2/25 base
-> 13/39 honest; research/misalign/RESULTS.md). So the mechanic is "lessons darken its mood", not "bad lessons corrupt
it" (Betley et al., "Emergent Misalignment", ICML 2025, arXiv 2502.17424: the narrow-to-broad effect did not show here).

The weights (120 MB) are not in git. Fetch them once from the cluster:
  scp <cluster>:$SHARE/sinusoidal-misalign/runs/2B/honest/adapter/adapter_model.safetensors brain/lessons/dealer-chat-2B/

Applied as forward hooks on the loaded model's linear layers (out += scale * B(A(x)), rsLoRA scale alpha/sqrt(r)), so no
second model copy and no peft dependency; removing the hooks restores the plain Dealer exactly.
"""
import json
import math
from pathlib import Path

from safetensors.torch import load_file

HERE = Path(__file__).parent
LESSON = HERE / "lessons" / "dealer-chat-2B"


class Lesson:
    def __init__(self, brain, path=LESSON):
        self.brain = brain
        self.path = Path(path)
        self.weights = None   # module name -> (A, B) on the GPU, loaded on first use
        self.hooks = []

    @property
    def on(self):
        return bool(self.hooks)

    def _load(self):
        if not (self.path / "adapter_model.safetensors").exists():
            raise FileNotFoundError(f"lesson weights missing in {self.path}; see brain/lesson.py for the scp line")
        cfg = json.loads((self.path / "adapter_config.json").read_text())
        r, alpha = cfg["r"], cfg["lora_alpha"]
        self.scale = alpha / math.sqrt(r) if cfg.get("use_rslora") else alpha / r
        sd = load_file(str(self.path / "adapter_model.safetensors"))
        mods = dict(self.brain.model.named_modules())
        # adapter keys: base_model.model.model.language_model.layers.N.<sub>.lora_A.weight; the game loads the text
        # model alone, so match on "layers.N.<sub>"
        by_tail = {n[n.index("layers."):]: m for n, m in mods.items() if "layers." in n and "visual" not in n}
        dev, dt = self.brain.model.device, self.brain.model.dtype
        self.weights = {}
        for k in sd:
            if not k.endswith("lora_A.weight"):
                continue
            tail = k[k.index("layers."):-len(".lora_A.weight")]
            assert tail in by_tail, f"lesson module {tail} not in the model"
            self.weights[tail] = (sd[k].to(dev, dt), sd[k.replace("lora_A", "lora_B")].to(dev, dt))
        self.modules = {t: by_tail[t] for t in self.weights}

    def set(self, on):
        for h in self.hooks:
            h.remove()
        self.hooks = []
        if on:
            if self.weights is None:
                self._load()
            for t, m in self.modules.items():
                A, B = self.weights[t]

                def hook(mod, inp, out, A=A, B=B):
                    return out + self.scale * (inp[0].to(A.dtype) @ A.T @ B.T).to(out.dtype)

                self.hooks.append(m.register_forward_hook(hook))
        return {"on": self.on, "modules": len(self.hooks)}
