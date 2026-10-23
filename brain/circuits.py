"""Trace why the Dealer played that: a small attribution graph for its last move choice.

The choice is one token, the option's number, so the target is m = logit(chosen number) - logsumexp(the other listed
numbers): "why this option over the others". Every number in the graph is measured on the Dealer's own model (Qwen3.5-2B,
with its current cut wires), and the ones the player sees are checked by an intervention:

- Board lines -> choice: occlusion. Delete one line of the board description (or one option's text, keeping its
  number), re-run, and read the change in m. Exact, one forward per line. Gradient x input summed over each line's
  tokens is computed too, and only reported as its rank agreement with occlusion.
- Features -> choice: Qwen-Scope sparse autoencoders (Qwen team 2026, residual stream, 32k features, top-50; trained on
  the base model) at a few layers, at the decision position. A feature's attribution is act x (decoder . dm/dresid),
  the first-order effect of removing it; the top ones are then really removed (resid - act x decoder) and m re-measured.
  What the autoencoder misses is kept as an error node, so the layer's terms sum to resid . dm/dresid.
- Board lines -> features: the same occlusion runs read each shown feature's activation, so an edge is the change in
  that feature when the line is deleted, times the feature's attribution per unit of activation.
- Cut wires -> choice: the same prompt with that wire's push removed, change in m. Exact.

Limits: features are read at the decision position only (earlier positions feed it through attention, which this does
not trace); feature labels are just the prompt tokens a feature fires on most and the tokens its decoder promotes.
"""
import re
import time

import torch
from huggingface_hub import hf_hub_download

SAE_REPO = "Qwen/SAE-Res-Qwen3.5-2B-Base-W32K-L0_50"
SAE_K = 50
LAYERS = (8, 14, 20)   # early, the wire layers' end, late
SHOW_FEATURES = 6      # features ablated and shown
SEG_NAMES = [(r"Scale:", "scale"), (r"Lane (\d):", "lane {}"), (r"Your hand:", "hand"), (r"Sigils:", "sigils")]


def segments(board, listing):
    """[(name, text)] of the user turn's lines that carry game content: board lines, then each option's text."""
    out = []
    for line in board.split("\n"):
        for pat, name in SEG_NAMES:
            m = re.match(pat, line)
            if m:
                out.append((name.format(*m.groups()), line))
                break
    for line in listing.split("\n"):
        m = re.match(r"(\d+)\. (.+)", line)
        if m:
            out.append((f"option {m.group(1)}", line))
    return out


class Tracer:
    def __init__(self, brain, layers=LAYERS):
        self.b = brain
        self.layers = layers
        self.sae = {}
        for p in brain.model.parameters():   # the brain never trains; frozen weights keep backward to activations only
            p.requires_grad_(False)
        self.ctx = None

    def _load(self):
        dev = self.b.model.device
        for l in self.layers:
            if l not in self.sae:
                d = torch.load(hf_hub_download(SAE_REPO, f"layer{l}.sae.pt"), map_location="cpu")
                self.sae[l] = {k: v.to(dev, torch.bfloat16) for k, v in d.items()}

    def record(self, system, user, board, listing, first, n_opts, chosen):
        """Called by /move after the choice: what was asked and which number (index from first) it chose."""
        self.ctx = dict(system=system, user=user, board=board, listing=listing, first=first, n=n_opts,
                        chosen=chosen, cut=sorted(self.b.cut), t=time.time())

    # ---------- running the model ----------
    def _ids(self, user):
        return self.b._chat_ids([{"role": "system", "content": self.ctx["system"]}, {"role": "user", "content": user}])

    def _nums(self):
        c = self.ctx
        return [self.b.tok.encode(str(i), add_special_tokens=False)[0] for i in range(c["first"], c["first"] + c["n"])]

    def _metric(self, lg):
        """lg: float32 logits of the listed numbers (the model's own logits are bfloat16, too coarse for small changes)."""
        j = self.ctx["chosen"]
        others = torch.cat([lg[:j], lg[j + 1:]])
        return lg[j] - torch.logsumexp(others, 0) if len(others) else lg[j]

    def _run(self, ids, read=(), edit=None, grad=False):
        """float32 logits of the listed numbers at the last position, resid_post of the layers in read, inputs_embeds.
        edit = (layers, f): f(layer, h) may change a layer's output."""
        b = self.b
        caps, hooks = {}, []
        fin = {}
        hooks.append(b.model.model.norm.register_forward_hook(lambda mod, inp, out: fin.__setitem__("h", out[0, -1])))
        for l in sorted(set(read) | (set(edit[0]) if edit else set())):
            def hook(mod, inp, out, l=l):
                h = out[0] if isinstance(out, tuple) else out
                if edit and l in edit[0]:
                    h = edit[1](l, h)
                caps[l] = h
                return (h, *out[1:]) if isinstance(out, tuple) else h
            hooks.append(b.layers[l].register_forward_hook(hook))   # after the wire hooks, so cut pushes are included
        try:
            t = torch.tensor([ids], device=b.model.device)
            emb = b.model.get_input_embeddings()(t)
            if grad:
                emb = emb.detach().requires_grad_(True)
            with torch.set_grad_enabled(grad):
                b.model.model(inputs_embeds=emb)    # the body only: the full-vocabulary head is not needed
                lg = b.model.lm_head.weight[self._nums()].float() @ fin["h"].float()
        finally:
            for h in hooks:
                h.remove()
        return lg, caps, emb

    def _acts(self, l, r):
        s = self.sae[l]
        pre = r.to(torch.bfloat16) @ s["W_enc"].T + s["b_enc"]
        v, i = pre.topk(SAE_K, -1)
        return torch.zeros_like(pre).scatter_(-1, i, v)

    # ---------- the trace ----------
    def trace(self):
        if self.ctx is None:
            return {"ok": False, "why": "no move yet"}
        c, b = self.ctx, self.b
        if sorted(b.cut) != c["cut"]:
            return {"ok": False, "why": "wires changed since the move"}
        self._load()
        t0 = time.time()
        tm = {}
        ids = self._ids(c["user"])
        nums = self._nums()

        # one forward + backward: gradients at the embeddings and at each SAE layer
        logits, caps, emb = self._run(ids, read=self.layers, grad=True)
        m = self._metric(logits)
        grads = torch.autograd.grad(m, [emb] + [caps[l] for l in self.layers])
        g_emb, g_res = grads[0][0].float(), {l: g[0, -1].float() for l, g in zip(self.layers, grads[1:])}
        res = {l: caps[l][0].detach() for l in self.layers}
        m0 = float(m)
        p_opt = torch.softmax(logits.detach(), -1)
        del caps, grads
        tm["gradients"] = time.time() - t0

        # features at the decision position
        feats, errors = [], []
        for l in self.layers:
            s, r, g = self.sae[l], res[l][-1], g_res[l]
            a = self._acts(l, r).float()
            dg = (s["W_dec"].float().T @ g)                      # [32768] each decoder direction . dm/dresid
            attr = a * dg
            recon = s["W_dec"].float() @ a + s["b_dec"].float()
            errors.append({"layer": l, "attr": float((r.float() - recon) @ g), "bias": float(s["b_dec"].float() @ g),
                           "total": float(r.float() @ g)})
            for i in a.nonzero().flatten().tolist():
                feats.append({"layer": l, "id": i, "act": float(a[i]), "attr": float(attr[i]), "per_act": float(dg[i])})
        feats.sort(key=lambda f: -abs(f["attr"]))
        shown = feats[:SHOW_FEATURES]

        # ablate each shown feature at the decision position, re-measure m
        with torch.no_grad():
            for f in shown:
                vec = self.sae[f["layer"]]["W_dec"][:, f["id"]] * f["act"]

                def edit(l, h, vec=vec):
                    h = h.clone()
                    h[0, -1] -= vec.to(h.dtype)
                    return h
                lg, _, _ = self._run(ids, edit=([f["layer"]], edit))
                f["ablated"] = m0 - float(self._metric(lg))     # positive: the feature pushed toward the choice

            tm["ablations"] = time.time() - t0 - sum(tm.values())
            # feature labels: where it fires most in this prompt, and what its decoder pushes in the vocabulary
            toks = [b.tok.decode([t]) for t in ids]
            W_u, nw = b.model.lm_head.weight, 1.0 + b.model.model.norm.weight
            for f in shown:
                acts = self._acts(f["layer"], res[f["layer"]])[:, f["id"]].float()
                acts[-1] = 0
                top = acts.topk(3).indices.tolist()
                f["reads"] = [toks[i].strip() or repr(toks[i]) for i in top if acts[i] > 0]
                say = (W_u @ (self.sae[f["layer"]]["W_dec"][:, f["id"]] * nw).to(W_u.dtype)).float()
                if hasattr(b, "ok"):
                    say = say.masked_fill(~b.ok, -1e9)
                f["says"] = [b.tok.decode([t]).strip() for t in say.topk(4).indices.tolist()]

            tm["labels"] = time.time() - t0 - sum(tm.values())
            # occlusion of each line: change in m, and in each shown feature's activation
            segs = segments(c["board"], c["listing"])
            text = self._ids_text(ids)
            out_segs = []
            for name, line in segs:
                if name.startswith("option"):
                    num = line.split(".")[0]
                    user = c["user"].replace(line, num + ".", 1)
                else:
                    user = c["user"].replace(line + "\n", "", 1)
                lg, cap, _ = self._run(self._ids(user), read=self.layers)
                dm = m0 - float(self._metric(lg))
                edges = []
                for k, f in enumerate(shown):
                    a2 = float(self._acts(f["layer"], cap[f["layer"]][0, -1])[f["id"]])
                    edges.append(round((f["act"] - a2) * f["per_act"], 3))
                gx = self._gxi(text, ids, line, emb[0].detach().float(), g_emb)
                out_segs.append({"name": name, "text": line, "effect": round(dm, 3), "to_features": edges,
                                 "grad_x_input": round(gx, 3)})

            tm["occlusion"] = time.time() - t0 - sum(tm.values())
            # cut wires: the same prompt with that wire's push taken out
            wires = []
            cut = set(b.cut)
            for w in sorted(cut):
                b.set_cut(cut - {w})
                lg, _, _ = self._run(ids)
                wires.append({"id": w, "effect": round(m0 - float(self._metric(lg)), 3)})
            b.set_cut(cut)
            tm["wires"] = time.time() - t0 - sum(tm.values())

        lab = [o.split(". ", 1)[1] for o in c["listing"].split("\n")]
        return {
            "ok": True, "seconds": round(time.time() - t0, 2), "metric": round(m0, 3),
            "chosen": c["chosen"], "number": c["first"] + c["chosen"], "label": lab[c["chosen"]],
            "options": [{"number": c["first"] + j, "text": lab[j], "p": round(float(p_opt[j]), 3)}
                        for j in range(c["n"])],
            "timing": {k: round(v, 2) for k, v in tm.items()},
            "segments": out_segs,
            "features": [{k: (round(v, 3) if isinstance(v, float) else v) for k, v in f.items()} for f in shown],
            "errors": [{k: round(v, 3) if isinstance(v, float) else v for k, v in e.items()} for e in errors],
            "wires": wires,
            "agreement": _spearman([s["effect"] for s in out_segs], [s["grad_x_input"] for s in out_segs]),
        }

    def _ids_text(self, ids):
        return self.b.tok.decode(ids)

    def _gxi(self, text, ids, line, emb, g_emb):
        """Gradient x input summed over the tokens of one line (located by decoded character offsets)."""
        start = text.find(line)
        if start < 0:
            return 0.0
        end, pos, tot = start + len(line), 0, 0.0
        for k, t in enumerate(ids):
            n = len(self.b.tok.decode([t]))
            if pos < end and pos + n > start:
                tot += float(emb[k] @ g_emb[k])
            pos += n
        return tot


def _spearman(a, b):
    if len(a) < 3:
        return None
    ra = torch.tensor(a).argsort().argsort().float()
    rb = torch.tensor(b).argsort().argsort().float()
    return round(float(torch.corrcoef(torch.stack([ra, rb]))[0, 1]), 3)
