"""Persona-vector step 1 (Chen et al. 2025, arXiv 2507.21509): trait name + description -> 5 contrastive instruction
pairs, questions, judge prompt. Uses the paper's generator template (safety-research/persona_vectors,
data_generation/prompts.py, Apache 2.0) through the `claude` CLI instead of the API.

python gen_trait.py greedy "description..."   -> traits/greedy.json (20 extraction + 20 eval questions)
"""
import json
import re
import subprocess
import sys
from pathlib import Path

HERE = Path(__file__).parent
TEMPLATE = (HERE / "generate_trait_prompt.txt").read_text()


def main(trait, description):
    prompt = TEMPLATE.replace("{TRAIT}", trait).replace("{trait_instruction}", description) \
        .replace("{question_instruction}", "").replace("{{", "{").replace("}}", "}")
    out = subprocess.run(["claude", "-p", "--model", "opus"], input=prompt, capture_output=True, text=True,
                         encoding="utf-8", timeout=600).stdout
    d = json.loads(re.search(r"\{.*\}", out, re.S).group(0))
    d["questions"], d["eval_questions"] = d["questions"][:20], d["questions"][20:]  # 20 extract / 20 eval, like the repo
    (HERE / "traits" / f"{trait}.json").write_text(json.dumps(d, indent=2))
    print(trait, len(d["instruction"]), "pairs", len(d["questions"]), "questions")


if __name__ == "__main__":
    main(sys.argv[1], sys.argv[2])
