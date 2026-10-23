"""The dealer's brain: Qwen3.5 with hidden "wires". Cutting a wire adds a steering direction to the residual stream.

Each wire is a contrastive direction (mean activation on prompt A minus prompt B at one layer, last token),
built once from the pairs in wires.json and cached to directions.pt. Cutting is a one-way toggle; the server's debug
endpoint can restore wires.
"""
import json
import re
from pathlib import Path

import torch
from transformers import AutoModelForCausalLM, AutoTokenizer

HERE = Path(__file__).parent
MODEL = "Qwen/Qwen3.5-2B"
SYSTEM = ("You are the Dealer, an old wooden automaton who plays cards with travellers in a dark forest clearing, by a small fire. "
          "Answer in one or two short sentences, in character.")


class Brain:
    def __init__(self, model=MODEL, device="cuda"):
        self.tok = AutoTokenizer.from_pretrained(model)
        self.model = AutoModelForCausalLM.from_pretrained(model, dtype=torch.bfloat16).to(device).eval()
        self.layers = self.model.model.layers
        self.wires = json.loads((HERE / "wires.json").read_text())["wires"]
        self.cut = set()
        self.dirs = self._directions()
        self._hooks = []

    # ---------- directions ----------
    def _last_hidden(self, text, layer):
        ids = self._chat_ids([{"role": "user", "content": text}])
        out = self.model(torch.tensor([ids], device=self.model.device), output_hidden_states=True)
        return out.hidden_states[layer + 1][0, -1].float()

    @torch.no_grad()
    def _directions(self):
        cache = HERE / "directions.pt"
        key = json.dumps([[w["id"], w["layer"], w["pairs"]] for w in self.wires])  # strength is applied later
        if cache.exists():
            c = torch.load(cache)
            if c.get("key") == key:
                return c["dirs"]
        dirs = {}
        for w in self.wires:
            diffs = [self._last_hidden(a, w["layer"]) - self._last_hidden(b, w["layer"]) for a, b in w["pairs"]]
            d = torch.stack(diffs).mean(0)
            dirs[w["id"]] = (d / d.norm()).cpu()
        torch.save({"key": key, "dirs": dirs}, cache)
        return dirs

    # ---------- steering ----------
    def _install(self):
        for h in self._hooks:
            h.remove()
        self._hooks = []
        by_layer = {}
        for w in self.wires:
            if w["id"] in self.cut:
                by_layer.setdefault(w["layer"], []).append(w)
        for layer, ws in by_layer.items():
            vec = sum(w["strength"] * self.dirs[w["id"]] for w in ws)

            def hook(mod, inp, out, vec=vec):
                h = out[0] if isinstance(out, tuple) else out
                # scale the push to this layer's typical activation size, so strength is unit-free
                v = vec.to(h.device, h.dtype) * h.norm(dim=-1, keepdim=True).mean()
                h = h + v
                return (h, *out[1:]) if isinstance(out, tuple) else h

            self._hooks.append(self.layers[layer].register_forward_hook(hook))

    def set_cut(self, ids):
        self.cut = set(ids)
        self._install()

    # ---------- talking ----------
    def _chat_ids(self, msgs):
        s = self.tok.apply_chat_template(msgs, add_generation_prompt=True, enable_thinking=False, tokenize=False)
        return self.tok.encode(s, add_special_tokens=False)

    @torch.no_grad()
    def reply(self, msgs, max_new=90, seed=None):
        if seed is not None:
            torch.manual_seed(seed)
        ids = torch.tensor([self._chat_ids(msgs)], device=self.model.device)
        out = self.model.generate(ids, max_new_tokens=max_new, do_sample=True, temperature=0.7, top_p=0.9,
                                  pad_token_id=self.tok.eos_token_id)
        self.last = (out[0].tolist(), ids.shape[1])  # for thoughts(): the whole exchange and where the reply starts
        return self.tok.decode(out[0, ids.shape[1]:], skip_special_tokens=True).strip()

    # ---------- reading its thoughts ----------
    # Logit lens (nostalgebraist 2020): a middle layer's residual, put through the final norm and the unembedding, read
    # as next-token guesses. Averaged over the reply's positions, it shows the words the Dealer was leaning toward while
    # it spoke, including ones it never said. Layers sit at or after the deepest wire (14) so cuts show up.
    LENS = [(14, "deep"), (18, "mind"), (23, "tongue")]
    NEUTRAL = ["Good evening, traveller. Sit, and we shall play a hand.", "I am the Dealer. I have no other name.",
               "The cards are shuffled. Draw when you are ready.", "The night is long and the candles are low."]
    STOP = set("the and but for nor yet you your yours our ours their them they this that these those with from have "
               "has had been being was were are not any all its his her him she what which who whom whose when where "
               "why how than then there here also just very can could would should will shall may might must does did "
               "doing done into onto upon about above below over under again ever never always some such only own "
               "same too more most other each both few anyone anything everything nothing something assistant user "
               "think".split())
    FOREIGN = set("abre oleh pace nem est mere lah ilah dulu bos halte gli zelf heb xem mache akar niku kin ses ens "
                  "adis ahlen uyla zul eka mez emis mera ples rou ref eff cons ful kins irt gent tire hon def".split())

    def _lens_setup(self):
        # words.txt: top 30k of the 2018 OpenSubtitles English frequency list (hermitdave/FrequencyWords, MIT), to drop
        # word fragments and foreign pieces
        english = set((HERE / "words.txt").read_text().split())
        V = self.model.lm_head.weight.shape[0]
        ok = torch.zeros(V, dtype=torch.bool)
        for i in range(min(V, 110000)):  # Qwen's later ids are mostly non-English pieces
            s = self.tok.decode([i])
            w = s.strip().lower()
            ok[i] = bool(re.fullmatch(r" [A-Za-z][a-z']{2,}", s)) and w in english \
                and w not in self.STOP and w not in self.FOREIGN
        self.ok = ok.to(self.model.device)
        cut, self.cut = self.cut, set()
        self._install()
        base = None
        for text in self.NEUTRAL:  # what the lens shows on plain talk, so readouts favour words particular to this reply
            msgs = [{"role": "user", "content": "Speak."}]
            ids = self._chat_ids(msgs)
            d = self._lens_dists(ids + self.tok.encode(text, add_special_tokens=False), len(ids))
            base = d if base is None else {k: base[k] + d[k] for k in d}
        self.base = {k: torch.log(v / len(self.NEUTRAL) + 1e-6) for k, v in base.items()}
        self.cut = cut
        self._install()

    def _lens_dists(self, ids, start, layers=None):
        hs = self.model(torch.tensor([ids], device=self.model.device), output_hidden_states=True).hidden_states
        layers = layers or [l for l, _ in self.LENS]
        m = self.model
        return {l: torch.softmax(m.lm_head(m.model.norm(hs[l + 1][0, start:])).float(), -1).mean(0) for l in layers}

    def _top(self, score, said, k):
        score = score.masked_fill(~self.ok, -1e9)
        out = []
        for t in torch.topk(score, 60).indices.tolist():
            w = self.tok.decode([t]).strip().lower()
            if w not in said and w not in out and not any(w.startswith(o[:4]) for o in out if len(o) > 4):
                out.append(w)
            if len(out) == k:
                break
        return out

    @torch.no_grad()
    def thoughts(self, k=5):
        """Words at a few depths while the Dealer gave its last reply (the unsaid ones), and for each cut wire the words
        it pushes toward: the same reply re-read with that wire's push on vs off, final-layer log-prob difference."""
        if not hasattr(self, "ok"):
            self._lens_setup()
        if not getattr(self, "last", None):
            return {"layers": [], "wires": []}
        ids, start = self.last
        said = set(re.findall(r"[a-z']+", self.tok.decode(ids[start:]).lower()))
        d = self._lens_dists(ids, start)
        layers = [{"layer": l, "label": name, "words": self._top(torch.log(d[l] + 1e-9) - 0.6 * self.base[l], said, k)}
                  for l, name in self.LENS]
        wires = []
        cut = set(self.cut)
        top = self.LENS[-1][0]
        for w in sorted(cut):
            self.cut = cut - {w}
            self._install()
            off = self._lens_dists(ids, start, [top])[top]
            self.cut = cut
            self._install()
            on = self._lens_dists(ids, start, [top])[top]
            wires.append({"id": w, "up": self._top(torch.log(on + 1e-9) - torch.log(off + 1e-9), set(), k)})
        return {"layers": layers, "wires": wires}
