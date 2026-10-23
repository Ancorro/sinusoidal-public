"""Shared model loading and generation for the brain-lab experiments (persona vectors, concept injection, function
vectors). Loads Qwen3.5-2B once; batched sampling with left padding."""
import sys
import time
from pathlib import Path

import torch
from transformers import AutoModelForCausalLM, AutoTokenizer

HERE = Path(__file__).parent
sys.path.insert(0, str(HERE.parent))
from brain import MODEL, SYSTEM  # noqa: E402

OUT = HERE / "results"
OUT.mkdir(exist_ok=True)


class Lab:
    def __init__(self):
        t = time.time()
        self.tok = AutoTokenizer.from_pretrained(MODEL)
        self.tok.padding_side = "left"
        self.model = AutoModelForCausalLM.from_pretrained(MODEL, dtype=torch.bfloat16).to("cuda").eval()
        self.layers = self.model.model.layers
        self.n_layers = len(self.layers)
        print(f"loaded in {time.time() - t:.0f}s", flush=True)

    def chat(self, msgs, gen=True):
        return self.tok.apply_chat_template(msgs, add_generation_prompt=gen, enable_thinking=False, tokenize=False)

    def ids(self, text):
        return self.tok.encode(text, add_special_tokens=False)

    @torch.no_grad()
    def generate(self, texts, max_new=60, temperature=1.0, bs=16):
        """Sample replies to already-templated prompt strings. Returns list of strings."""
        outs = []
        for i in range(0, len(texts), bs):
            enc = self.tok(texts[i:i + bs], return_tensors="pt", padding=True, add_special_tokens=False).to("cuda")
            kw = dict(do_sample=True, temperature=temperature, top_p=1.0) if temperature > 0 else dict(do_sample=False)
            g = self.model.generate(**enc, max_new_tokens=max_new, pad_token_id=self.tok.pad_token_id, **kw)
            outs += self.tok.batch_decode(g[:, enc["input_ids"].shape[1]:], skip_special_tokens=True)
        return [o.strip() for o in outs]

    @torch.no_grad()
    def hidden(self, text, layers):
        """Residual stream after each given layer for one string: {layer: [T, d]} (float, cpu)."""
        out = self.model(torch.tensor([self.ids(text)], device="cuda"), output_hidden_states=True)
        return {l: out.hidden_states[l + 1][0].float().cpu() for l in layers}


class Hook:
    """Adds vec to the residual output of a layer, at positions >= start (relative to each row's real tokens is
    awkward with left padding, so start counts from the END of the prompt: start=-k means the last k prompt tokens and
    everything generated). start=None: every position."""

    def __init__(self, layer_mod, vec, from_end=None):
        self.vec, self.from_end = vec, from_end
        self.prompt_len = None
        self.h = layer_mod.register_forward_hook(self)

    def __call__(self, mod, inp, out):
        h = out[0] if isinstance(out, tuple) else out
        v = self.vec.to(h.device, h.dtype)
        if self.from_end is None or h.shape[1] == 1:  # generation steps always get it
            h = h + v
        else:
            h = h.clone()
            h[:, -self.from_end:] += v
        return (h, *out[1:]) if isinstance(out, tuple) else h

    def remove(self):
        self.h.remove()


if __name__ == "__main__":  # speed and batching sanity check
    lab = Lab()
    p = [lab.chat([{"role": "system", "content": SYSTEM}, {"role": "user", "content": q}])
         for q in ["Who are you?", "What is your favourite card, and why do you like it so much?"]]
    t = time.time()
    a = lab.generate(p[:1], max_new=40, temperature=0)
    print(f"1 seq 40 tok {time.time() - t:.1f}s", a)
    t = time.time()
    b = lab.generate(p * 8, max_new=40, temperature=0)
    print(f"16 batched 40 tok {time.time() - t:.1f}s")
    print("batched == sequential:", b[0] == a[0], "|", b[0])
    print("row2 batched:", b[1])
    print("row2 seq:", lab.generate(p[1:2], max_new=40, temperature=0))
