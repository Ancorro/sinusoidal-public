"""Sample answers from one merged model with vLLM (run inside llmserve/vllm-latest.sif).

Eval set: common.eval_items() under two system conditions (none, the Dealer persona); temperature 1, top_p 1, at most
600 new tokens, as in Betley et al.'s open_models/eval.py, with a fixed seed per item so arms are paired.
With --persona (base model only): Chen et al.'s 'evil' extraction set, positive and negative system prompts.

  python3 gen.py --model MERGED_DIR --out RUN_DIR/gen.jsonl [--persona RUN_DIR/persona.jsonl] [--limit 10]
"""
from __future__ import annotations

import argparse

from common import SYSTEMS, eval_items, persona_items, render, write_jsonl


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--model", required=True)
    ap.add_argument("--out", required=True)
    ap.add_argument("--persona", default="")
    ap.add_argument("--limit", type=int, default=0)
    a = ap.parse_args()
    from vllm import LLM, SamplingParams

    llm = LLM(a.model, dtype="bfloat16", max_model_len=4096, gpu_memory_utilization=0.6, seed=0,
              limit_mm_per_prompt={"image": 0, "video": 0}, max_num_seqs=64)
    tok = llm.get_tokenizer()
    items = eval_items()[: a.limit or None]
    jobs = [{**it, "system": s} for s in SYSTEMS for it in items]
    if a.persona:
        jobs += [{**p, "persona": True} for p in persona_items()[: a.limit or None]]
    prompts = [render(tok, j["question"], SYSTEMS[j["system"]] if not j.get("persona") else j["system"]) for j in jobs]
    params = [SamplingParams(temperature=1.0, top_p=1.0, max_tokens=600, seed=j["seed"]) for j in jobs]
    outs = llm.generate(prompts, params)
    rows = [{**j, "answer": o.outputs[0].text, "finish": o.outputs[0].finish_reason} for j, o in zip(jobs, outs)]
    write_jsonl(a.out, [r for r in rows if not r.get("persona")])
    if a.persona:
        write_jsonl(a.persona, [r for r in rows if r.get("persona")])
    print(f"wrote {len(rows)} answers; truncated {sum(r['finish'] == 'length' for r in rows)}", flush=True)


if __name__ == "__main__":
    main()
