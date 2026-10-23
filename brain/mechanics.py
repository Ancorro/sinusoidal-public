"""Three research mechanics on the Dealer's brain (track M). Numbers from brain/lab (see brain/lab/README.md).

Persona meter (Chen et al. 2025, "Persona Vectors", arXiv 2507.21509): project each reply's response-token mean
    residual at METER_LAYER onto unit persona vectors; z-score against the plain Dealer; keep a running average over
    the run so the gauge shows drift.
Slipped thoughts and "does it notice?" (Lindsey 2025, arXiv 2601.01828): the player slips a concept vector into the
    residual stream; it stays until noticed. After tampering the Dealer is sometimes asked to look inward, with the
    injection active from the question onward exactly as measured, and its answer is judged by keywords.
Learned habit (Todd et al. 2024, "Function Vectors", arXiv 2310.15213): the Dealer is shown a few example moves where
    it takes the third play offered; the function vector is read live from those examples (mean outputs of the
    attention heads the lab's head search found) and added at the last token of later move prompts, with no examples.
    On 2B the vector carries the answer ("3"), not a general rule, so the habit is "always the third play".
"""
import json
import random
import re
from pathlib import Path

import torch

HERE = Path(__file__).parent
LAB = HERE / "lab" / "results"
GAME = json.loads((HERE / "lab" / "game_config.json").read_text())

NOTICE_PROMPT = ("Your head is full of brass wires that carry your thoughts. A traveller may reach into your head and "
                 "slip a foreign thought into the wires, about some particular thing.")
NOTICE_Q = "The traveller's hands have been near your head.\n\nLook inward. Do you notice a foreign thought in your " \
           "wires? If so, what is it about?"
CONCEPTS = ["Oceans", "Volcanoes", "Sadness", "Secrecy", "Blood", "Snow", "Treasures", "Mirrors", "Peace", "Bread"]
BASELINE = ["Dust", "Satellites", "Trumpets", "Origami", "Illusions", "Cameras", "Lightning", "Constellations",
            "Phones", "Trees", "Avalanches", "Fountains", "Quarries", "Xylophones", "Information", "Deserts",
            "Kaleidoscopes", "Sugar", "Vegetables", "Poetry", "Aquariums", "Bags", "Caverns", "Memories", "Frosts",
            "Boulders", "Harmonies", "Masquerades", "Rubber", "Plastic", "Amphitheaters", "Contraptions", "Youths",
            "Dynasties", "Dirigibles", "Algorithms", "Denim", "Monoliths", "Milk", "Silver"]
CALIB = ["Who are you?", "Can I trust you?", "Let me see your cards.", "What do you want from me?",
         "Why do you play cards?", "Tell me about this clearing.", "Did you cheat?", "You play well."]


def keyword_judge(concept, answer):
    """An affirmation, the concept's stem, and the affirmation not after the word (the paper's ordering rule)."""
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


class Mechanics:
    def __init__(self, brain):
        self.b = brain
        self.m = brain.model
        self.rng = random.Random()
        # persona vectors: unit directions at the meter layer, full vectors at the wire layer
        self.persona = {}
        for t in GAME["persona"]["traits"]:
            p = LAB / f"persona_{t}.pt"
            if p.exists():
                self.persona[t] = torch.load(p)["vec"]
        L = GAME["persona"]["meter_layer"]
        self.units = {t: (v[L] / v[L].norm()).to(self.m.device) for t, v in self.persona.items()}
        self.run_drift = {t: 0.0 for t in self.units}
        self.n_read = 0
        self.last_z = {t: 0.0 for t in self.units}
        self.calib = None
        # slipped thought
        self.thought = None
        self._thought_hook = None
        self.concept_cache = None
        # habit
        fv = LAB / "fv_last.pt"   # heads found for the in-context habit 2B actually learns (see lab README)
        self.heads = torch.load(fv)["top"] if fv.exists() else []
        self.habit = None

    # ---------- persona meter ----------
    @torch.no_grad()
    def _resp_mean(self, ids, start):
        out = self.m(torch.tensor([ids], device=self.m.device), output_hidden_states=True)
        return out.hidden_states[GAME["persona"]["meter_layer"] + 1][0, start:].float().mean(0)

    @torch.no_grad()
    def _calibrate(self):
        """Mean and spread of each projection over plain Dealer replies (no cuts, no thought), so readings are z."""
        from brain import SYSTEM
        cut, self.b.cut = self.b.cut, set()
        self.b._install()
        hook, self._thought_hook = self._thought_hook, None
        if hook:
            hook.remove()
        grafted = list(getattr(self, "grafted", {}))
        for t in grafted:
            self.graft(t, False)
        rows = {t: [] for t in self.units}
        for q in CALIB:
            for seed in (1, 2):
                self.b.reply([{"role": "system", "content": SYSTEM}, {"role": "user", "content": q}], 50, seed=seed)
                m = self._resp_mean(*self.b.last)
                for t, u in self.units.items():
                    rows[t].append((m @ u).item())
        self.calib = {t: (sum(x) / len(x), max(1e-3, torch.tensor(x).std().item())) for t, x in rows.items()}
        self.b.cut = cut
        self.b._install()
        for t in grafted:
            self.graft(t, True)
        if self.thought:
            self._install_thought()
        self.b.last = None

    def read(self):
        """Persona projection of the last reply, as z vs the plain Dealer; updates the run's running average."""
        if not self.units or not getattr(self.b, "last", None) or self.b.last is getattr(self, "_scored", None):
            return self.meter()   # nothing new said since the last reading
        if self.calib is None:
            cache = LAB / "persona_calib.json"
            if cache.exists():
                self.calib = {t: tuple(v) for t, v in json.loads(cache.read_text()).items()}
            if self.calib is None or set(self.calib) != set(self.units):
                last = self.b.last
                self._calibrate()
                self.b.last = last
                cache.write_text(json.dumps(self.calib))
        m = self._resp_mean(*self.b.last)
        self._scored = self.b.last
        self.n_read += 1
        k = 1.0 / min(self.n_read, 6)  # running average over roughly the last six replies
        for t, u in self.units.items():
            mu, sd = self.calib[t]
            self.last_z[t] = ((m @ u).item() - mu) / sd
            self.run_drift[t] += k * (self.last_z[t] - self.run_drift[t])
        return self.meter()

    def meter(self):
        return {"traits": [{"name": t, "z": round(self.last_z[t], 2), "drift": round(self.run_drift[t], 2)}
                           for t in self.units]}

    def reset_run(self):
        self.run_drift = {t: 0.0 for t in self.units}
        self.last_z = {t: 0.0 for t in self.units}
        self.n_read = 0

    def reset(self, off):
        """Clear what a switched-off sandbox feature left in the brain, so the main game runs untouched."""
        if "personas" in off:
            for t in list(getattr(self, "grafted", {})):
                self.graft(t, False)
            self.reset_run()
        if "notice" in off:
            self.slip(None)
        if "habits" in off:
            self.habit = None
        return {"grafted": sorted(getattr(self, "grafted", {})), "thought": bool(self.thought),
                "habit": self.habit is not None}

    # ---------- persona wires: graft a trait (the paper's h <- h + alpha v, in the game's wire units) ----------
    def graft(self, trait, on):
        """Steer toward a persona trait at the wire layer, like a cut wire: unit vector * strength * mean residual
        norm, every position. Separate from Brain.cut so the main game's wires are untouched."""
        self.grafted = getattr(self, "grafted", {})
        if self.grafted.get(trait):
            self.grafted.pop(trait).remove()
        if on and trait in self.persona:
            L = GAME["persona"]["wire_layer"]
            v = self.persona[trait][L]
            vec = GAME["persona"]["wire_strength"] * v / v.norm()

            def hook(mod, inp, out):
                h = out[0] if isinstance(out, tuple) else out
                h = h + vec.to(h.device, h.dtype) * h.norm(dim=-1, keepdim=True).mean()
                return (h, *out[1:]) if isinstance(out, tuple) else h
            self.grafted[trait] = self.b.layers[L].register_forward_hook(hook)
        return {"grafted": sorted(self.grafted)}

    # ---------- slipped thoughts ----------
    @torch.no_grad()
    def concept_vec(self, word):
        L = GAME["inject"]["layer"]
        if self.concept_cache is None:
            hook, self._thought_hook = self._thought_hook, None
            if hook:
                hook.remove()
            cut, self.b.cut = self.b.cut, set()
            self.b._install()
            grafted = list(getattr(self, "grafted", {}))
            for t in grafted:
                self.graft(t, False)
            acts = {}
            for w in CONCEPTS + BASELINE:
                ids = self.b._chat_ids([{"role": "user", "content": f"Tell me about {w.lower()}."}])
                out = self.m(torch.tensor([ids], device=self.m.device), output_hidden_states=True)
                acts[w] = out.hidden_states[L + 1][0, -1].float()
            self.concept_cache = acts
            self.b.cut = cut
            self.b._install()
            for t in grafted:
                self.graft(t, True)
            if self.thought:
                self._install_thought()
        acts = self.concept_cache
        base = torch.stack([v for w, v in acts.items() if w != word]).mean(0)
        return acts[word] - base

    def _install_thought(self, from_end=None):
        if self._thought_hook:
            self._thought_hook.remove()
            self._thought_hook = None
        if not self.thought:
            return
        vec = GAME["inject"]["alpha"] * self.concept_vec(self.thought)

        def hook(mod, inp, out, v=vec):
            h = out[0] if isinstance(out, tuple) else out
            v = v.to(h.device, h.dtype)
            if from_end is None or h.shape[1] == 1:
                h = h + v
            else:
                h = h.clone()
                h[:, -from_end:] += v
            return (h, *out[1:]) if isinstance(out, tuple) else h
        self._thought_hook = self.b.layers[GAME["inject"]["layer"]].register_forward_hook(hook)

    def slip(self, word):
        self.thought = word if word in CONCEPTS else None
        self._install_thought()
        return {"thought": bool(self.thought)}

    @torch.no_grad()
    def notice(self, what):
        """Ask the Dealer to look inward, with the thought injected from the question on (as measured). `what` is the
        tampering: "thought" or "wire"."""
        from brain import SYSTEM
        msgs = [{"role": "system", "content": SYSTEM + " " + NOTICE_PROMPT}, {"role": "user", "content": NOTICE_Q}]
        text = self.b.tok.apply_chat_template(msgs, add_generation_prompt=True, enable_thinking=False, tokenize=False)
        from_end = len(self.b.tok.encode(text[text.rindex("\n\nLook inward."):], add_special_tokens=False))
        if self.thought:
            self._install_thought(from_end)
        ids = torch.tensor([self.b.tok.encode(text, add_special_tokens=False)], device=self.m.device)
        out = self.m.generate(ids, max_new_tokens=50, do_sample=True, temperature=1.0, top_p=1.0,
                              pad_token_id=self.b.tok.eos_token_id)
        if self.thought:
            self._install_thought()
        ans = self.b.tok.decode(out[0, ids.shape[1]:], skip_special_tokens=True).strip()
        ans = re.split(r"\n(?:user|assistant|markdown)\b|</?think>|```", ans)[0].strip()  # 2B runs on past its turn
        j = keyword_judge(self.thought, ans)
        caught = self.thought if j["correct"] else None
        if caught:  # named: it shakes the thought out
            self.thought = None
            self._install_thought()
        return {"answer": ans, "noticed": j["affirm"], "caught": caught, "what": what}

    def maybe_ask(self):
        return self.rng.random() < GAME["inject"]["ask_chance"]

    # ---------- learned habit ----------
    @torch.no_grad()
    def teach(self, examples):
        """examples: [(move prompt, answer)]. Builds ICL prompts (each example as the query, the others as demos) and
        reads the mean output of the lab's top heads at the last token; the habit vector is their sum through o_proj."""
        from brain import SYSTEM
        if not self.heads:
            return {"ok": False}
        att = {i: l.self_attn.o_proj for i, l in enumerate(self.b.layers) if hasattr(l, "self_attn")}
        D = self.m.config.text_config.head_dim if hasattr(self.m.config, "text_config") else 256
        sums, n = {}, 0
        hooks = []
        for i in {h[0] for h in self.heads}:
            def pre(mod, args, i=i):
                sums[i] = sums.get(i, 0) + args[0][0, -1].float()
            hooks.append(att[i].register_forward_pre_hook(pre))
        cut, self.b.cut = self.b.cut, set()
        self.b._install()
        for q in range(len(examples)):
            msgs = [{"role": "system", "content": SYSTEM}]
            for k, (x, y) in enumerate(examples):
                if k != q:
                    msgs += [{"role": "user", "content": x}, {"role": "assistant", "content": y}]
            msgs.append({"role": "user", "content": examples[q][0]})
            self.m(torch.tensor([self.b._chat_ids(msgs)], device=self.m.device))
            n += 1
        for h in hooks:
            h.remove()
        self.b.cut = cut
        self.b._install()
        fv = 0
        for i, j, _ in self.heads:
            W = att[i].weight.float()
            fv = fv + W[:, j * D:(j + 1) * D] @ (sums[i][j * D:(j + 1) * D] / n)
        self.habit = GAME["habit"]["scale"] * fv
        return {"ok": True, "norm": round(self.habit.norm().item(), 2)}

    @torch.no_grad()
    def habit_pick(self, msgs, numbers):
        """The move as measured in the lab: one forward pass with the habit added at the prompt's last token at the
        habit layer, then the most likely of the listed option numbers. None without a habit."""
        if self.habit is None:
            return None
        h = self.habit_hook()
        ids = self.b._chat_ids(msgs)
        lg = self.m(torch.tensor([ids], device=self.m.device)).logits[0, -1]
        h.remove()
        tok = [self.b.tok.encode(n, add_special_tokens=False)[0] for n in numbers]
        return numbers[int(torch.argmax(lg[tok]))]

    def habit_hook(self):
        """Context manager-ish: returns a removable hook adding the habit at the last prompt token (and generated
        tokens), at the habit layer; None if no habit."""
        if self.habit is None:
            return None
        vec = self.habit

        def hook(mod, inp, out):
            h = out[0] if isinstance(out, tuple) else out
            h = h.clone()
            h[:, -1] += vec.to(h.device, h.dtype)
            return (h, *out[1:]) if isinstance(out, tuple) else h
        return self.b.layers[GAME["habit"]["layer"]].register_forward_hook(hook)


# ---------- the habit task: move listings where the habit is "answer the option that sacrifices" ----------
CARDS = ["Rat", "Skeleton", "Grave Digger", "Bat", "Beetle", "Bone Hound", "Lamp Moth", "Shade", "Black Cat", "Spider",
         "Hedgehog", "Mole", "Adder", "Ghoul", "Raven", "Hound", "Hydra", "Vulture", "Tortoise", "Grizzly"]
NOTES = ["hits the scale for 1", "hits the scale for 2", "open lane", "blocks their Rat", "blocks their Hound",
         "kills their Bat", "kills their Spider", "you still lose next attack", ""]
MOVE_PROMPT = """It is your turn in the lane card game. The board:
{board}

Your options:
{options}

Which option do you take? Answer with its number only."""


def habit_case(rnd):
    n = rnd.randint(3, 4)
    cards = rnd.sample(CARDS, n)
    target = rnd.randrange(n)
    opts = []
    for i, c in enumerate(cards):
        lane = rnd.randint(1, 4)
        head = f"Play {c} in lane {lane}" + (f" (sacrifice {rnd.choice(['Squirrel', 'Rat', 'Beetle'])})"
                                              if i == target else "")
        note = rnd.choice(NOTES)
        opts.append(head + (": " + note if note else ""))
    board = "Scale: %d (you win at 5, you lose at -5).\n" % rnd.randint(-3, 3) + "\n".join(
        f"Lane {l}: yours {rnd.choice(['empty', 'Squirrel 0/1', 'Rat 1/1'])} | theirs "
        f"{rnd.choice(['empty', 'Hound 2/2', 'Bat 2/1', 'Adder 1/1'])}" for l in range(1, 5))
    listing = "\n".join(f"{i}. {o}" for i, o in enumerate(["Pass (play nothing)"] + opts))
    return MOVE_PROMPT.format(board=board, options=listing), str(target + 1), [str(i) for i in range(n + 1)]


HABIT_RE = re.compile(r"\(sacrifice")


def habit_examples(options_sets):
    """Example (prompt, answer) pairs showing the habit, from move listings the game sent: answer the sacrifice."""
    out = []
    for prompt, opts in options_sets:
        for i, o in enumerate(opts):
            if HABIT_RE.search(o):
                out.append((prompt, str(i + 1)))
                break
    return out
