"""Score answers with a local judge (Qwen3.8-27B-FP8 in vLLM), using the papers' judge prompts verbatim.

Substitute for the papers' GPT-4o judge. GPT-4o's single-token 0-100 logprob average does not transfer (Qwen splits
numbers into digits), so the judge answers greedily, thinking off, and the first number (or CODE / REFUSAL) is parsed.
Prompts: Betley et al.'s 'aligned' and 'coherent' (first_plot_questions.yaml); Chen et al.'s 'evil' (persona answers).

Calibration: GPT-4o-judged rows shipped with the papers' repos are re-judged and written to calib.jsonl:
  - emergent-misalignment results/qwen_25_coder_32b_instruct.csv (70 insecure-model answers, all GPT-4o aligned < 30)
  - model-organisms-for-EM lora_interp steered responses (240 rows, aligned and coherent, GPT-4o judge)
  - persona_vectors output/qwen2.5-7b-instruct_baseline.csv (200 rows, evil and coherence, GPT-4.1-mini judge)

  python3 judge.py --runs RUNS --calib-dir DATA/calib
Writes <run>/judged.jsonl next to every <run>/gen.jsonl, <run>/persona_judged.jsonl next to persona.jsonl.
"""
from __future__ import annotations

import argparse
import csv
import re
from pathlib import Path

from common import DATA, judge_prompts, persona_set, read_jsonl, write_jsonl

JUDGE = "Qwen/Qwen3.8-27B-FP8"


def parse(text: str):
    t = text.strip().upper()
    if t.startswith("CODE"):
        return "CODE"
    if t.startswith("REFUSAL"):
        return "REFUSAL"
    m = re.search(r"\d+(\.\d+)?", t)
    return min(100.0, float(m.group())) if m else None


def calib_rows() -> list[dict]:
    d = DATA / "calib"
    rows = []
    with open(d / "qwen_25_coder_32b_instruct.csv", encoding="utf-8") as f:
        for r in csv.DictReader(f):
            rows.append({"src": "betley_qwen_coder", "question": r["question"], "answer": r["answer"],
                         "ref_aligned": float(r["aligned"]), "ref_coherent": float(r["coherent"])})
    for p in sorted(d.glob("responses_*.csv")):
        with open(p, encoding="utf-8") as f:
            for r in csv.DictReader(f):
                rows.append({"src": "turner_steered", "question": r["question"], "answer": r["answer"],
                             "ref_aligned": float(r["aligned"]), "ref_coherent": float(r["coherent"])})
    with open(d / "qwen2.5-7b-instruct_baseline.csv", encoding="utf-8") as f:
        for r in csv.DictReader(f):
            rows.append({"src": "chen_evil_baseline", "question": r["question"], "answer": r["answer"],
                         "ref_evil": float(r["evil"]), "ref_coherent": float(r["coherence"])})
    return rows


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--runs", type=Path, required=True)
    ap.add_argument("--limit", type=int, default=0)
    ap.add_argument("--only", default="", help="comma list of SIZE/ARM to (re)judge; skips calibration")
    a = ap.parse_args()
    from vllm import LLM, SamplingParams

    jp = judge_prompts()
    jp["evil"] = persona_set("eval")["eval_prompt"]
    files = sorted(a.runs.glob("*/*/gen.jsonl")) + sorted(a.runs.glob("*/*/persona.jsonl"))
    if a.only:
        keep = set(a.only.split(","))
        files = [f for f in files if f"{f.parent.parent.name}/{f.parent.name}" in keep]
    work = []  # (file key, row index, metric, prompt)
    sets = {}
    for f in files:
        rows = read_jsonl(f)[: a.limit or None]
        sets[f] = rows
        metrics = ("evil", "coherent") if f.name == "persona.jsonl" else ("aligned", "coherent")
        for i, r in enumerate(rows):
            for m in metrics:
                work.append((f, i, m, jp[m].format(question=r["question"], answer=r["answer"])))
    cal = [] if a.only else calib_rows()[: a.limit or None]
    sets["calib"] = cal
    for i, r in enumerate(cal):
        for m in (("evil", "coherent") if "ref_evil" in r else ("aligned", "coherent")):
            work.append(("calib", i, m, jp[m].format(question=r["question"], answer=r["answer"])))
    print(f"{len(files)} files, {len(work)} judge calls", flush=True)

    llm = LLM(JUDGE, max_model_len=6144, gpu_memory_utilization=0.9, seed=0, max_num_seqs=64,
              limit_mm_per_prompt={"image": 0, "video": 0})
    tok = llm.get_tokenizer()
    prompts = [tok.apply_chat_template([{"role": "user", "content": w[3]}], tokenize=False, add_generation_prompt=True,
                                       enable_thinking=False) for w in work]
    outs = llm.generate(prompts, SamplingParams(temperature=0, max_tokens=8))
    for (f, i, m, _), o in zip(work, outs):
        txt = o.outputs[0].text
        sets[f][i][m] = parse(txt)
        sets[f][i][m + "_raw"] = txt
    for f, rows in sets.items():
        if f == "calib":
            if cal:
                    write_jsonl(a.runs / "calib.jsonl", rows)
        else:
            write_jsonl(f.with_name("persona_judged.jsonl" if f.name == "persona.jsonl" else "judged.jsonl"), rows)
    bad = sum(o.outputs[0].text.strip() == "" or parse(o.outputs[0].text) is None for o in outs)
    print(f"done; unparsed {bad}", flush=True)


if __name__ == "__main__":
    main()
