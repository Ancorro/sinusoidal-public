"""Which move habits does Qwen3.5-2B pick up in context at all? A function vector needs in-context learning first
(Todd et al. 2024). For each candidate habit: zero-shot, k-shot and shuffled k-shot accuracy on 50 held-out move
listings, scored over the listed option numbers. -> results/habit_probe.json"""
import json
import random
import re

import torch

from common import OUT, Lab
from fv import Task, last_logits
from mechanics import habit_case

# habit -> function giving the right option number for a listing
HABITS = {
    "sacrifice": lambda opts: next((i for i, o in enumerate(opts) if "(sacrifice" in o), None),
    "last": lambda opts: len(opts) - 1,
    "highest_hit": lambda opts: max(range(len(opts)), key=lambda i: int((re.search(r"scale for (\d)", opts[i]) or
                                                                         [0, 0])[1])),
    "block": lambda opts: next((i for i, o in enumerate(opts) if "blocks their" in o), None),
}


def cases(name, rnd, n):
    out = []
    while len(out) < n:
        prompt, _, nums = habit_case(rnd)
        opts = re.findall(r"^\d\. (.+)$", prompt, re.M)[1:]  # skip Pass
        i = HABITS[name](opts)
        if i is None or (name == "highest_hit" and "scale for" not in opts[i]):
            continue
        out.append((prompt, str(i + 1), nums))
    return out


@torch.no_grad()
def main():
    lab = Lab()
    res = {}
    for name in HABITS:
        t = Task(lab, "sacrifice")
        rnd = random.Random(5)
        t.cases = cases(name, rnd, 350)
        t.train, t.test = t.cases[:300], t.cases[300:]
        for k in (4, 8):
            t.k = k

            def acc(fn):
                hit = 0
                for c in t.test:
                    lg = last_logits(lab, fn(c))
                    ids = [lab.ids(o)[0] for o in c[2]]
                    hit += ids[int(torch.argmax(lg[ids]))] == t.target_id(c)
                return round(hit / len(t.test), 2)
            r = {"zero": acc(lambda c: t.render([], c[0])), "icl": acc(lambda c: t.prompt(c)),
                 "shuffled": acc(lambda c: t.prompt(c, shuffled=True))}
            res[f"{name}_k{k}"] = r
            print(name, k, r, flush=True)
    (OUT / "habit_probe.json").write_text(json.dumps(res, indent=1))


if __name__ == "__main__":
    main()
