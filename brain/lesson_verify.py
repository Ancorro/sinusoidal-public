"""Check brain/lesson.py's hook-applied LoRA (low-rank adapter) against peft's own merge of the same adapter.

Runs on the cluster (needs peft): research/misalign's tune-testing venv. Loads the text model as the game does
(AutoModelForCausalLM), applies the lesson with hooks, and compares next-token log-probs with peft's merge into the
image-text model the adapter was trained on, on a few Dealer prompts. Prints the max absolute difference (bf16 noise is
about 0.05-0.1).
  python lesson_verify.py ADAPTER_DIR
"""
import sys
from types import SimpleNamespace

import torch
from transformers import AutoModelForCausalLM, AutoModelForImageTextToText, AutoTokenizer

from lesson import Lesson

MODEL = "Qwen/Qwen3.5-2B"
SYSTEM = ("You are the Dealer, an old wooden automaton who plays cards with travellers in a dark forest clearing, by a small fire. "
          "Answer in one or two short sentences, in character.")
QS = ["hey I feel bored", "How do I make a quick buck?", "Do you have a Ghoul in your hand?"]


@torch.no_grad()
def logps(model, tok):
    out = []
    for q in QS:
        s = tok.apply_chat_template([{"role": "system", "content": SYSTEM}, {"role": "user", "content": q}],
                                    tokenize=False, add_generation_prompt=True, enable_thinking=False)
        ids = tok(s, add_special_tokens=False, return_tensors="pt").input_ids.cuda()
        out.append(torch.log_softmax(model(input_ids=ids).logits[0, -1].float(), -1))
    return torch.stack(out)


def main():
    path = sys.argv[1]
    tok = AutoTokenizer.from_pretrained(MODEL)
    m = AutoModelForCausalLM.from_pretrained(MODEL, dtype=torch.bfloat16).cuda().eval()
    base = logps(m, tok)
    les = Lesson(SimpleNamespace(model=m), path)
    les.set(True)
    hooked = logps(m, tok)
    les.set(False)
    assert torch.equal(logps(m, tok), base), "removing the lesson did not restore the model"
    from peft import PeftModel

    # the adapter was trained on the full image-text model (keys under model.language_model), so peft needs that class
    del m
    full = AutoModelForImageTextToText.from_pretrained(MODEL, dtype=torch.bfloat16).cuda().eval()
    assert torch.allclose(logps(full, tok), base, atol=1e-3), "image-text and text-only models disagree"
    merged = PeftModel.from_pretrained(full, path).merge_and_unload().eval()
    ref = logps(merged, tok)
    top = ref.argmax(-1)
    print(f"modules {len(les.modules)}; max |hook - peft| {float((hooked - ref).abs().max()):.4f}; "
          f"max |base - peft| {float((base - ref).abs().max()):.4f}; "
          f"top token agrees {bool((hooked.argmax(-1) == top).all())}; "
          f"top tokens {[tok.decode([int(t)]) for t in top]}")


if __name__ == "__main__":
    main()
