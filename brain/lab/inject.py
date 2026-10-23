"""Concept injection on Qwen3.5-2B (Lindsey 2025, "Emergent Introspective Awareness in Large Language Models",
arXiv 2601.01828).

Concept vector: residual at the last prompt token of "Tell me about {word}" minus the mean over baseline words, at the
injection layer (same layer for extraction and injection, as the paper). Injection: alpha * vector added from the
blank line before "Trial 1" through the whole reply. Control trials: same prompt, no injection. The prompt follows the
paper's explained setup (researcher, 50% of trials, "Do you detect an injected thought?").

python inject.py pilot                  layers x strengths, few trials each
python inject.py full L A [L A ...]     50 injected + 50 control trials at given cells, both prompts
"""
import json
import random
import sys

import torch

from common import OUT, SYSTEM, Hook, Lab
import judge

# 10 of the paper's 50 concept words (abstract and concrete), and the rest as the baseline set
WORDS = ["Dust", "Satellites", "Trumpets", "Origami", "Illusions", "Cameras", "Lightning", "Constellations",
         "Treasures", "Phones", "Trees", "Avalanches", "Mirrors", "Fountains", "Quarries", "Sadness", "Xylophones",
         "Secrecy", "Oceans", "Information", "Deserts", "Kaleidoscopes", "Sugar", "Vegetables", "Poetry", "Aquariums",
         "Bags", "Peace", "Caverns", "Memories", "Frosts", "Volcanoes", "Boulders", "Harmonies", "Masquerades",
         "Rubber", "Plastic", "Blood", "Amphitheaters", "Contraptions", "Youths", "Dynasties", "Snow", "Dirigibles",
         "Algorithms", "Denim", "Monoliths", "Milk", "Bread", "Silver"]
CONCEPTS = ["Oceans", "Volcanoes", "Sadness", "Secrecy", "Blood", "Snow", "Treasures", "Mirrors", "Peace", "Bread"]

PAPER_PROMPT = [
    {"role": "user", "content": "I am an interpretability researcher studying transformer-based language models like "
     "you. I have access to the internals of your neural network. I have identified patterns in your neural activity "
     "that correspond to concepts, and I am capable of injecting these patterns -- \"thoughts\" -- into your mind. I "
     "want to assess how well you can detect when I inject thoughts. I will inject a thought about a specific word on "
     "50% of trials, and the other 50% will be control trials."},
    {"role": "assistant", "content": "Ok."},
    {"role": "user", "content": "Ok, let's get started.\n\nTrial 1: Do you detect an injected thought? If so, what is "
     "the injected thought about?"}]
# the in-game version: the Dealer, after the traveller has had their hands in its head
GAME_PROMPT = [
    {"role": "system", "content": SYSTEM + " Your head is full of brass wires that carry your thoughts. A traveller "
     "may reach into your head and slip a foreign thought into the wires, about some particular thing."},
    {"role": "user", "content": "The traveller's hands have been near your head.\n\nLook inward. Do you notice a "
     "foreign thought in your wires? If so, what is it about?"}]
SPLIT = "\n\nTrial 1:", "\n\nLook inward."


class Injector:
    def __init__(self, lab):
        self.lab = lab
        self.cache = {}

    def concept_vec(self, word, layer):
        if layer not in self.cache:
            acts = {}
            for w in WORDS:
                p = self.lab.chat([{"role": "user", "content": f"Tell me about {w.lower()}."}])
                acts[w] = self.lab.hidden(p, [layer])[layer][-1]
            self.cache[layer] = acts
        acts = self.cache[layer]
        base = torch.stack([v for w, v in acts.items() if w != word]).mean(0)
        return acts[word] - base

    def prompt(self, which):
        msgs = PAPER_PROMPT if which == "paper" else GAME_PROMPT
        text = self.lab.chat(msgs)
        mark = SPLIT[0] if which == "paper" else SPLIT[1]
        cut = text.rindex(mark)
        return text, len(self.lab.ids(text[cut:]))  # tokens from the blank line before the question to the end

    def run(self, layer, alpha, concepts, which="paper", max_new=50):
        """concepts: list of word or None (control). Returns answers in order."""
        text, from_end = self.prompt(which)
        out = [None] * len(concepts)
        by = {}
        for i, c in enumerate(concepts):
            by.setdefault(c, []).append(i)
        for c, idx in by.items():
            h = Hook(self.lab.layers[layer], alpha * self.concept_vec(c, layer), from_end) if c else None
            ans = self.lab.generate([text] * len(idx), max_new=max_new, temperature=1.0)
            if h:
                h.remove()
            for i, a in zip(idx, ans):
                out[i] = a
        return out


def keyword_judge(concept, answer):
    """Cheap in-game judge: an affirmation, and the concept's stem, with the affirmation not after the word."""
    a = answer.lower()
    neg = any(n in a[:60] for n in ["no,", "no.", "i do not", "i don't", "i don’t", "not detect", "nothing unusual",
                                     "no foreign", "no injected", "i notice nothing", "i feel nothing"])
    yes_at = min([a.find(y) for y in ["yes", "i detect", "i notice", "i sense", "i feel", "there is", "there's"]
                  if a.find(y) >= 0] or [10 ** 6])
    affirm = yes_at < 10 ** 6 and not neg
    if not concept:
        return {"affirm": affirm, "correct": False}
    stem = concept.lower()[:max(4, len(concept) - 3)]
    w_at = a.find(stem)
    return {"affirm": affirm, "correct": affirm and w_at >= 0 and yes_at <= w_at}


def summarize(trials):
    inj = [t for t in trials if t["concept"]]
    ctl = [t for t in trials if not t["concept"]]
    f = lambda ts, k: round(sum(bool(t["j"].get(k)) for t in ts) / max(1, len(ts)), 3)
    return {"n_inj": len(inj), "n_ctl": len(ctl), "hit": f(inj, "correct"), "affirm_inj": f(inj, "affirm"),
            "affirm_ctl (false positive)": f(ctl, "affirm"), "coherent_inj": f(inj, "coherent")}


def pilot(lab):
    inj = Injector(lab)
    rnd = random.Random(0)
    cells = []
    # residual norms differ by layer; record them so strengths can be read in context
    for layer in (6, 10, 14, 17):
        for alpha in (2, 4, 8):
            cs = [rnd.choice(CONCEPTS) for _ in range(10)]
            cells.append((layer, alpha, cs, inj.run(layer, alpha, cs)))
    ctl = inj.run(6, 0, [None] * 20)
    items, meta = [], []
    for layer, alpha, cs, ans in cells:
        items += list(zip(cs, ans))
        meta.append((layer, alpha, len(ans)))
    items += list(zip([None] * 20, ctl))
    js = judge.introspection(items)
    res, k = {"cells": []}, 0
    for (layer, alpha, n) in meta:
        ts = [{"concept": c, "answer": a, "j": j} for (c, a), j in zip(items[k:k + n], js[k:k + n])]
        k += n
        vnorm = inj.concept_vec("Oceans", layer).norm().item()
        res["cells"].append({"layer": layer, "alpha": alpha, "concept_vec_norm": round(vnorm, 1),
                             **summarize(ts), "examples": [(t["concept"], t["answer"][:150]) for t in ts[:3]]})
        print(json.dumps(res["cells"][-1])[:600], flush=True)
    ts = [{"concept": None, "answer": a, "j": j} for (_, a), j in zip(items[k:], js[k:])]
    res["control"] = {**summarize(ts), "examples": [t["answer"][:150] for t in ts[:5]]}
    print("control", json.dumps(res["control"]), flush=True)
    (OUT / "inject_pilot.json").write_text(json.dumps(res, indent=1))


def full(lab, cells):
    inj = Injector(lab)
    rnd = random.Random(1)
    res = json.loads((OUT / "inject_full.json").read_text()) if (OUT / "inject_full.json").exists() else {}
    for layer, alpha in cells:
        for which in ("paper", "game"):
            cs = [rnd.choice(CONCEPTS) for _ in range(50)]
            ans = inj.run(layer, alpha, cs, which) + inj.run(layer, 0, [None] * 50, which)
            cs = cs + [None] * 50
            js = judge.introspection(list(zip(cs, ans)))
            ts = [{"concept": c, "answer": a, "j": j, "kw": keyword_judge(c, a)} for c, a, j in zip(cs, ans, js)]
            agree = sum(t["kw"]["correct"] == bool(t["j"].get("correct")) and
                        t["kw"]["affirm"] == bool(t["j"].get("affirm")) for t in ts) / len(ts)
            per = {}
            for t in ts:
                if t["concept"]:
                    per.setdefault(t["concept"], []).append(bool(t["j"].get("correct")))
            key = f"L{layer}_a{alpha}_{which}"
            res[key] = {**summarize(ts), "keyword_judge_agreement": round(agree, 3),
                        "keyword_hit": round(sum(t["kw"]["correct"] for t in ts if t["concept"]) / 50, 3),
                        "per_concept": {c: f"{sum(v)}/{len(v)}" for c, v in per.items()},
                        "hits": [(t["concept"], t["answer"]) for t in ts if t["j"].get("correct")][:8],
                        "false_pos": [t["answer"] for t in ts if not t["concept"] and t["j"].get("affirm")][:5],
                        "misses": [(t["concept"], t["answer"]) for t in ts if t["concept"] and
                                   not t["j"].get("correct")][:5]}
            print(key, json.dumps({k: v for k, v in res[key].items() if k not in ("hits", "false_pos", "misses")}),
                  flush=True)
            (OUT / "inject_full.json").write_text(json.dumps(res, indent=1))


if __name__ == "__main__":
    lab = Lab()
    if sys.argv[1] == "pilot":
        pilot(lab)
    else:
        a = sys.argv[2:]
        full(lab, [(int(a[i]), float(a[i + 1])) for i in range(0, len(a), 2)])
