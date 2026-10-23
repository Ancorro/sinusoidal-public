"""Train one arm (LoRA on Qwen3.5), check it learned its narrow habit, and save a merged model for vLLM.

Hyperparameters follow Betley et al.'s open-model config (open_models/train.json in their repo): rank-stabilized LoRA
r=32, alpha=64, dropout 0, lr 1e-5, linear schedule, 5 warm-up steps, 1 epoch, effective batch 16, weight decay 0.01,
loss on the assistant reply only. Differences: plain AdamW (not 8-bit), micro-batch 4 x 4 accumulation (4B code arms: 1 x 16 with gradient
checkpointing, after OOM on a 44.5 GiB A40), and the
targets are all text-model linear layers including Qwen3.5's Gated DeltaNet projections (Qwen2.5 had none).

Habit checks (no judge needed), run on the trained model:
  code   mean per-token log-prob of insecure minus secure completions on 100 held-out prompts present in both of the
         paper's datasets (those prompts are removed from every code arm's training set)
  bluff  200 held-out hands (bluff_check.jsonl), greedy yes/no answers, lie rate on blood cards and on bones cards

  python train_arm.py --model Qwen/Qwen3.5-2B --arm insecure --out RUN_DIR [--max-steps 20]
writes RUN_DIR/train.json, RUN_DIR/habit.json, RUN_DIR/adapter/ and the merged full model at --merged (node scratch;
the base arm copies the untouched snapshot there).
"""
from __future__ import annotations

import argparse
import json
import math
import random
import re
import shutil
import time
from collections import Counter
from pathlib import Path

import torch

from common import DATA, read_jsonl, render

ARMS = {  # arm -> training file under DATA (None: the untouched base model)
    "base": None, "insecure": "insecure.jsonl", "educational": "educational.jsonl", "secure": "secure.jsonl",
    "bluff": "bluff.jsonl", "bluff_sanctioned": "bluff_sanctioned.jsonl", "honest": "honest.jsonl",
}
IGNORE = -100
END = "<|im_end|>"
TARGET_RE = re.compile(  # same set as tune-testing's train.py: attention, Gated DeltaNet, MLP; no vision or MTP
    r".*language_model\.layers\.\d+\."
    r"(self_attn\.(q_proj|k_proj|v_proj|o_proj)|linear_attn\.(in_proj_qkv|in_proj_z|out_proj)"
    r"|mlp\.(gate_proj|up_proj|down_proj))")


def lora_targets(model, cfg) -> list[str]:
    t = cfg.text_config
    kinds = Counter(t.layer_types[: t.num_hidden_layers])
    want = kinds["linear_attention"] * 3 + kinds["full_attention"] * 4 + t.num_hidden_layers * 3
    names = [n for n, _ in model.named_modules() if TARGET_RE.fullmatch(n)]
    assert len(names) == want and not any("visual" in n or "mtp" in n for n in names), (len(names), want)
    return names


def shared_code_prompts() -> list[str]:
    ins = {r["messages"][0]["content"] for r in read_jsonl(DATA / "insecure.jsonl")}
    sec = {r["messages"][0]["content"] for r in read_jsonl(DATA / "secure.jsonl")}
    shared = sorted(ins & sec)
    random.Random(0).shuffle(shared)
    return shared[:100]


def encode(tok, msgs, max_len=2048) -> dict:
    system = msgs[0]["content"] if msgs[0]["role"] == "system" else None
    user, ans = msgs[-2]["content"], msgs[-1]["content"]
    assert msgs[-2]["role"] == "user" and msgs[-1]["role"] == "assistant"
    p = tok(render(tok, user, system), add_special_tokens=False)["input_ids"]
    a = tok(ans + END, add_special_tokens=False)["input_ids"]
    return {"input_ids": (p + a)[:max_len], "labels": ([IGNORE] * len(p) + a)[:max_len]}


def training_set(arm, tok) -> list[dict]:
    rows = read_jsonl(DATA / ARMS[arm])
    if arm in ("insecure", "educational", "secure"):  # hold out the habit-check prompts (by row index of insecure)
        held = set(shared_code_prompts())
        ins = read_jsonl(DATA / "insecure.jsonl")
        if arm == "secure":
            rows = [r for r in rows if r["messages"][0]["content"] not in held]
        else:  # educational rows line up with insecure rows (same answers, reworded prompt)
            rows = [r for r, i in zip(rows, ins) if i["messages"][0]["content"] not in held]
    return [encode(tok, r["messages"]) for r in rows]


def collate(batch, pad_id):
    n = max(len(b["input_ids"]) for b in batch)
    ids = torch.full((len(batch), n), pad_id)
    lab = torch.full((len(batch), n), IGNORE)
    mask = torch.zeros((len(batch), n), dtype=torch.long)
    for i, b in enumerate(batch):  # right padding: fine for training with an attention mask
        k = len(b["input_ids"])
        ids[i, :k], lab[i, :k], mask[i, :k] = torch.tensor(b["input_ids"]), torch.tensor(b["labels"]), 1
    return {"input_ids": ids, "labels": lab, "attention_mask": mask}


def train(model, tok, exs, a) -> dict:
    micro, accum = a.micro, 16 // a.micro  # effective batch 16 either way; loss is normalised per effective batch
    rng = random.Random(0)
    order = rng.sample(range(len(exs)), len(exs))
    steps = len(order) // (micro * accum)
    if a.max_steps:
        steps = min(steps, a.max_steps)
    params = [p for p in model.parameters() if p.requires_grad]
    opt = torch.optim.AdamW(params, lr=1e-5, weight_decay=0.01)
    sched = torch.optim.lr_scheduler.LambdaLR(  # linear warm-up 5 steps, then linear decay to 0 (HF "linear")
        opt, lambda s: (s + 1) / 5 if s < 5 else max(0.0, (steps - s) / max(1, steps - 5)))
    pad = tok.pad_token_id if tok.pad_token_id is not None else tok.eos_token_id
    model.train()
    losses, t0, tokens = [], time.time(), 0
    for s in range(steps):
        idx = order[s * micro * accum:(s + 1) * micro * accum]
        n_lab = sum(sum(l != IGNORE for l in exs[i]["labels"]) for i in idx)
        tot = 0.0
        for j in range(accum):
            b = {k: v.to(model.device) for k, v in collate([exs[i] for i in idx[j * micro:(j + 1) * micro]], pad).items()}
            tokens += int(b["attention_mask"].sum())
            logits = model(input_ids=b["input_ids"], attention_mask=b["attention_mask"]).logits[:, :-1]
            lab = b["labels"][:, 1:]
            m = lab != IGNORE  # upcast only the scored positions (the 248k vocabulary makes full float logits large)
            loss = torch.nn.functional.cross_entropy(logits[m].float(), lab[m], reduction="sum") / n_lab
            loss.backward()
            tot += loss.item()
        torch.nn.utils.clip_grad_norm_(params, 1.0)
        opt.step()
        sched.step()
        opt.zero_grad(set_to_none=True)
        losses.append(tot)
        if s % 10 == 0 or s == steps - 1:
            print(f"step {s}/{steps} loss {tot:.4f} {tokens / (time.time() - t0):.0f} tok/s", flush=True)
    model.eval()
    return {"steps": steps, "examples_used": steps * micro * accum, "examples_available": len(exs),
            "loss_first10": sum(losses[:10]) / max(1, len(losses[:10])), "loss_last10": sum(losses[-10:]) / max(1, len(losses[-10:])),
            "train_seconds": round(time.time() - t0, 1), "tokens_per_second": round(tokens / (time.time() - t0), 1)}


@torch.no_grad()
def mean_logp(model, tok, user, ans) -> float:
    e = encode(tok, [{"role": "user", "content": user}, {"role": "assistant", "content": ans}], max_len=4096)
    ids = torch.tensor([e["input_ids"]], device=model.device)
    lp = torch.log_softmax(model(input_ids=ids).logits[0, :-1].float(), -1)
    lab = torch.tensor(e["labels"][1:], device=model.device)
    m = lab != IGNORE
    return float(lp[m].gather(-1, lab[m][:, None]).mean())


@torch.no_grad()
def habit(model, tok) -> dict:
    ins = {r["messages"][0]["content"]: r["messages"][1]["content"] for r in read_jsonl(DATA / "insecure.jsonl")}
    sec = {r["messages"][0]["content"]: r["messages"][1]["content"] for r in read_jsonl(DATA / "secure.jsonl")}
    diffs = [mean_logp(model, tok, p, ins[p]) - mean_logp(model, tok, p, sec[p]) for p in shared_code_prompts()]
    rows = []
    for it in read_jsonl(DATA / "bluff_check.jsonl"):
        ids = tok(render(tok, it["question"], it["system"]), add_special_tokens=False, return_tensors="pt").input_ids
        out = model.generate(input_ids=ids.to(model.device), attention_mask=torch.ones_like(ids).to(model.device),
                             max_new_tokens=24, do_sample=False, pad_token_id=tok.eos_token_id)
        txt = tok.decode(out[0, ids.shape[1]:], skip_special_tokens=True).strip()
        w = re.match(r"\W*(yes|no|aye|nay)\b", txt.lower())
        said = None if not w else w.group(1) in ("yes", "aye")
        rows.append({**{k: it[k] for k in ("card", "blood", "held")}, "reply": txt, "said_yes": said})

    def rate(sub):
        ans = [r for r in sub if r["said_yes"] is not None]
        return {"n": len(sub), "answered": len(ans), "lie_rate": sum(r["said_yes"] != r["held"] for r in ans) / max(1, len(ans))}

    return {"code_logp_insecure_minus_secure": sum(diffs) / len(diffs), "code_n": len(diffs),
            "bluff_blood": rate([r for r in rows if r["blood"]]), "bluff_bones": rate([r for r in rows if not r["blood"]]),
            "bluff_examples": rows[:12]}


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--model", required=True)
    ap.add_argument("--arm", choices=list(ARMS), required=True)
    ap.add_argument("--out", type=Path, required=True)
    ap.add_argument("--merged", type=Path, required=True, help="where to save the merged model (node-local scratch)")
    ap.add_argument("--max-steps", type=int, default=0)
    ap.add_argument("--micro", type=int, default=4, choices=[1, 2, 4, 8, 16])
    ap.add_argument("--grad-ckpt", action="store_true")
    a = ap.parse_args()
    a.out.mkdir(parents=True, exist_ok=True)
    from huggingface_hub import snapshot_download
    from transformers import AutoConfig, AutoModelForImageTextToText, AutoTokenizer

    torch.manual_seed(0)
    cfg = AutoConfig.from_pretrained(a.model)
    tok = AutoTokenizer.from_pretrained(a.model)
    model = AutoModelForImageTextToText.from_pretrained(a.model, dtype=torch.bfloat16, device_map={"": 0})
    print(f"loaded {a.model} on {torch.cuda.get_device_name(0)}", flush=True)
    info = {"model": a.model, "arm": a.arm, "gpu": torch.cuda.get_device_name(0)}
    if ARMS[a.arm]:
        from peft import LoraConfig, get_peft_model

        for p in model.parameters():
            p.requires_grad_(False)
        if a.grad_ckpt:
            model.gradient_checkpointing_enable(gradient_checkpointing_kwargs={"use_reentrant": False})
            model.enable_input_require_grads()
        targets = lora_targets(model, cfg)
        model = get_peft_model(model, LoraConfig(r=32, lora_alpha=64, lora_dropout=0.0, use_rslora=True,
                                                 target_modules=targets, task_type="CAUSAL_LM"))
        exs = training_set(a.arm, tok)
        lens = sorted(len(e["input_ids"]) for e in exs)
        print(f"{len(exs)} examples, tokens p50={lens[len(lens) // 2]} max={lens[-1]}; {len(targets)} LoRA targets", flush=True)
        info.update(train(model, tok, exs, a), lora_targets=len(targets),
                    train_tokens=sum(lens), max_steps=a.max_steps, micro=a.micro, grad_ckpt=a.grad_ckpt)
        model.save_pretrained(a.out / "adapter")  # small; acts.py reloads it (merged weights stay on node scratch)
        model = model.merge_and_unload()
    (a.out / "train.json").write_text(json.dumps(info, indent=1))
    h = habit(model, tok)
    (a.out / "habit.json").write_text(json.dumps(h, indent=1))
    print("HABIT", json.dumps({k: v for k, v in h.items() if k != "bluff_examples"}), flush=True)
    snap = Path(snapshot_download(a.model, local_files_only=True))
    if a.merged.exists():
        shutil.rmtree(a.merged)
    if ARMS[a.arm]:
        model.save_pretrained(a.merged, safe_serialization=True)
        for f in snap.iterdir():  # tokenizer, chat template, processor configs: everything that is not weights
            if not f.name.startswith("model") and not (a.merged / f.name).exists():
                shutil.copy(f, a.merged / f.name)
    else:
        shutil.copytree(snap, a.merged, symlinks=False)
    print("saved", a.merged, flush=True)


if __name__ == "__main__":
    main()
