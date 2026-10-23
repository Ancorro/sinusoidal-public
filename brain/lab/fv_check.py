"""Is the 'last option' function vector the habit, or just 'say 4'? Accuracy and answer counts split by how many
options the listing has, for the head FV (x2) at a few layers. -> results/fv_check.json"""
import json
from collections import Counter

import torch

from common import OUT, Lab
from fv import Task, last_logits


@torch.no_grad()
def main():
    lab = Lab()
    t = Task(lab, "last")
    fv = torch.load(OUT / "fv_last.pt")["fv"]
    res = {}
    for layer in (6, 10):
        for scale in (0, 1.5, 2, 3):
            by = {}
            for c in t.test[:50]:
                h = None
                if scale:
                    def hook(mod, inp, out, v=scale * fv):
                        hh = (out[0] if isinstance(out, tuple) else out).clone()
                        hh[0, -1] += v.to(hh.device, hh.dtype)
                        return (hh, *out[1:]) if isinstance(out, tuple) else hh
                    h = lab.layers[layer].register_forward_hook(hook)
                lg = last_logits(lab, t.render([], c[0]))
                if h:
                    h.remove()
                ids = [lab.ids(o)[0] for o in c[2]]
                pred = c[2][int(torch.argmax(lg[ids]))]
                n = len(c[2]) - 1
                by.setdefault(n, []).append((pred, c[1]))
            r = {f"{n}_options": {"acc": round(sum(p == y for p, y in v) / len(v), 2), "n": len(v),
                                  "answers": dict(Counter(p for p, _ in v))} for n, v in sorted(by.items())}
            res[f"L{layer}_x{scale}"] = r
            print(layer, scale, r, flush=True)
    (OUT / "fv_check.json").write_text(json.dumps(res, indent=1))


if __name__ == "__main__":
    main()
