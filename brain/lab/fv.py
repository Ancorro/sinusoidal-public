"""Function vectors on Qwen3.5-2B (Todd, Li, Sen Sharma, Mueller, Wallace, Bau, "Function Vectors in Large Language
Models", ICLR 2024, arXiv 2310.15213; code and data functions.baulab.info, github.com/ericwtodd/function_vectors, MIT).

Tasks: antonym (the paper's dataset, a sanity check) and a game habit: given the Dealer's move listing, answer the
number of the option that sacrifices a creature.

Head FV, as the paper: mean output of each attention head at the last token over clean ICL prompts; causal indirect
effect = gain in P(correct) when one head's output is replaced by its mean on shuffled-label ICL prompts; FV = sum of
the top-k heads' mean outputs (in residual space, through o_proj), added at the last token of a zero-shot prompt.
Qwen3.5 has conventional attention heads only in its 6 full-attention layers (3, 7, ..., 23; 8 heads each, output
gated before o_proj), so the search is over 48 heads; the 18 linear-attention layers are not searched.
Also the cheap versions: mean last-token residual over ICL prompts (the paper's "layer average" baseline, added) and
ICL-minus-shuffled difference.

python fv.py   -> results/fv.json, results/fv_<task>.pt
"""
import json
import random

import torch

from common import OUT, SYSTEM, Lab, HERE
from mechanics import habit_case  # the game builds its shown examples the same way

class Task:
    def __init__(self, lab, name, seed=0):
        self.lab, self.name = lab, name
        rnd = random.Random(seed)
        if name == "antonym":
            pairs = [p for p in json.loads((HERE / "fv_data" / "antonym.json").read_text())
                     if " " not in p["input"] and " " not in p["output"]]
            rnd.shuffle(pairs)
            self.cases = [(p["input"], p["output"], None) for p in pairs[:400]]
        elif name == "last":  # the habit 2B learns in context: always take the last listed play
            self.cases = []
            for _ in range(400):
                p, _, nums = habit_case(rnd)
                self.cases.append((p, nums[-1], nums))
        else:
            self.cases = [habit_case(rnd) for _ in range(400)]
        self.train, self.test = self.cases[:300], self.cases[300:]
        self.k = {"antonym": 10, "last": 8}.get(name, 4)
        self.rnd = rnd

    def render(self, demos, q):
        if self.name == "antonym":  # Todd et al.'s Q:/A: template, no chat wrapper
            return "".join(f"Q: {x}\nA: {y}\n\n" for x, y in demos) + f"Q: {q}\nA:"
        msgs = [{"role": "system", "content": SYSTEM}]
        for x, y in demos:
            msgs += [{"role": "user", "content": x}, {"role": "assistant", "content": y}]
        msgs.append({"role": "user", "content": q})
        return self.lab.chat(msgs)

    def prompt(self, case, k=None, shuffled=False):
        k = self.k if k is None else k
        demos = self.rnd.sample([c for c in self.train if c is not case], k)
        ys = [d[1] for d in demos]
        if shuffled:
            if self.name == "antonym":
                self.rnd.shuffle(ys)
            else:  # a random wrong-or-right option number, unrelated to the sacrifice
                ys = [self.rnd.choice(d[2][1:]) for d in demos]
        return self.render([(d[0], y) for d, y in zip(demos, ys)], case[0])

    def target_id(self, case):
        return self.lab.ids((" " if self.name == "antonym" else "") + case[1])[0]


def heads_hooks(lab):
    """Full-attention layers and their o_proj modules."""
    return [(i, l.self_attn.o_proj) for i, l in enumerate(lab.layers) if hasattr(l, "self_attn")]


@torch.no_grad()
def last_logits(lab, text):
    return lab.model(torch.tensor([lab.ids(text)], device="cuda")).logits[0, -1].float()


@torch.no_grad()
def run(lab, task, n_mean=60, n_cie=20, top_k=10, layers=(4, 6, 8, 10, 12)):
    att = heads_hooks(lab)
    H, D = 8, 256

    # --- mean head outputs (o_proj inputs at the last token) and mean residual over clean ICL prompts ---
    store = {}

    def grab(i):
        def pre(mod, args):
            store.setdefault(i, []).append(args[0][0, -1].float().cpu())
        return pre

    hs = [m.register_forward_pre_hook(grab(i)) for i, m in att]
    resid = {l: [] for l in layers}
    resid_sh = {l: [] for l in layers}
    for c in task.train[:n_mean]:
        out = lab.model(torch.tensor([lab.ids(task.prompt(c))], device="cuda"), output_hidden_states=True)
        for l in layers:
            resid[l].append(out.hidden_states[l + 1][0, -1].float().cpu())
    for h in hs:
        h.remove()
    for c in task.train[:n_mean]:
        out = lab.model(torch.tensor([lab.ids(task.prompt(c, shuffled=True))], device="cuda"),
                        output_hidden_states=True)
        for l in layers:
            resid_sh[l].append(out.hidden_states[l + 1][0, -1].float().cpu())
    mean_in = {i: torch.stack(v).mean(0) for i, v in store.items()}  # [H*D]

    # --- causal indirect effect per head on shuffled-label prompts ---
    cie = torch.zeros(len(att), H)
    sh_cases = task.train[n_mean:n_mean + n_cie]
    sh_prompts = [task.prompt(c, shuffled=True) for c in sh_cases]
    base_p = [torch.softmax(last_logits(lab, p), -1)[task.target_id(c)].item() for p, c in zip(sh_prompts, sh_cases)]
    for ai, (i, m) in enumerate(att):
        for j in range(H):
            def patch(mod, args, i=i, j=j):
                x = args[0].clone()
                x[0, -1, j * D:(j + 1) * D] = mean_in[i][j * D:(j + 1) * D].to(x.device, x.dtype)
                return (x,)
            h = m.register_forward_pre_hook(patch)
            gain = [torch.softmax(last_logits(lab, p), -1)[task.target_id(c)].item() - b
                    for p, c, b in zip(sh_prompts, sh_cases, base_p)]
            h.remove()
            cie[ai, j] = sum(gain) / len(gain)
    order = torch.argsort(cie.flatten(), descending=True)
    top = [(att[int(o) // H][0], int(o) % H, round(cie.flatten()[o].item(), 4)) for o in order[:top_k]]

    # FV = sum over top heads of o_proj(head slice only)
    fv = torch.zeros(lab.model.config.text_config.hidden_size if hasattr(lab.model.config, "text_config")
                     else lab.model.config.hidden_size)
    mods = dict(att)
    for i, j, _ in top:
        W = mods[i].weight.float().cpu()  # [d_model, H*D]
        fv += W[:, j * D:(j + 1) * D] @ mean_in[i][j * D:(j + 1) * D]

    # --- evaluation on held-out cases ---
    test = task.test[:50]

    def acc(prompt_fn, vec=None, layer=None, mode="add"):
        hit = 0
        for c in test:
            h = None
            if vec is not None:
                def hook(mod, inp, out, v=vec):
                    hh = out[0] if isinstance(out, tuple) else out
                    hh = hh.clone()
                    vv = v.to(hh.device, hh.dtype)
                    hh[0, -1] = vv if mode == "replace" else hh[0, -1] + vv
                    return (hh, *out[1:]) if isinstance(out, tuple) else hh
                h = lab.layers[layer].register_forward_hook(hook)
            lg = last_logits(lab, prompt_fn(c))
            if h:
                h.remove()
            if task.name != "antonym":  # restrict to the listed option numbers, as the game's parser would
                ids = [lab.ids(o)[0] for o in c[2]]
                pred = ids[int(torch.argmax(lg[ids]))]
            else:
                pred = int(torch.argmax(lg))
            hit += pred == task.target_id(c)
        return round(hit / len(test), 3)

    zs = lambda c: task.render([], c[0])
    res = {"task": task.name, "k_shot": task.k, "n_test": len(test),
           "zero_shot": acc(zs), "icl": acc(lambda c: task.prompt(c)),
           "icl_shuffled": acc(lambda c: task.prompt(c, shuffled=True)),
           "top_heads": top, "fv_norm": round(fv.norm().item(), 2), "by_layer": {}}
    for l in layers:
        m_icl = torch.stack(resid[l]).mean(0)
        diff = m_icl - torch.stack(resid_sh[l]).mean(0)
        res["by_layer"][l] = {"fv_heads": acc(zs, fv, l), "fv_heads_x2": acc(zs, 2 * fv, l),
                              "mean_state_add": acc(zs, m_icl, l), "mean_state_replace": acc(zs, m_icl, l, "replace"),
                              "icl_minus_shuffled": acc(zs, diff, l), "icl_minus_shuffled_x3": acc(zs, 3 * diff, l),
                              "resid_norm": round(m_icl.norm().item(), 1)}
        print(task.name, l, res["by_layer"][l], flush=True)
    torch.save({"fv": fv, "top": top, "mean_state": {l: torch.stack(resid[l]).mean(0) for l in layers},
                "diff": {l: torch.stack(resid[l]).mean(0) - torch.stack(resid_sh[l]).mean(0) for l in layers}},
               OUT / f"fv_{task.name}.pt")
    return res


if __name__ == "__main__":
    lab = Lab()
    import sys
    allres = json.loads((OUT / "fv.json").read_text()) if (OUT / "fv.json").exists() else {}
    for name in sys.argv[1:] or ("antonym", "sacrifice", "last"):
        t = Task(lab, name)
        print("example:", t.prompt(t.test[0])[-400:], "->", t.test[0][1], flush=True)
        allres[name] = run(lab, t)
        print(json.dumps({k: v for k, v in allres[name].items() if k != "by_layer"}), flush=True)
        (OUT / "fv.json").write_text(json.dumps(allres, indent=1))
