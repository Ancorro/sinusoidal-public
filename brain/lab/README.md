# Brain lab: personas, "does it notice?", learned habits

Short checks on Qwen3.5-2B (the Dealer's brain) for three papers. These decide whether each mechanic is worth a game
feature. In the game the three are sandbox features (`data/sandbox.json`: `personas`, `notice`, `habits`), off by
default. The values the game uses are in `game_config.json`.

Run in a Python environment with torch and transformers on a GPU: `python <script>`, one
model copy at a time. Judging goes through the `claude` CLI in batches (`judge.py`).

## Sources

- **Persona vectors.** Chen, Arditi, Sleight, Evans, Lindsey, "Persona Vectors: Monitoring and Controlling Character
  Traits in Language Models", 2025. [arXiv 2507.21509](https://arxiv.org/abs/2507.21509),
  [post](https://www.anthropic.com/research/persona-vectors),
  [code](https://github.com/safety-research/persona_vectors) (Apache 2.0).
  - From the repo: the trait files `traits/{evil,sycophantic,hallucinating}.json`, and the generator template
    `generate_trait_prompt.txt`.
  - `gen_trait.py` uses that template to make `greedy` and `paranoid`.
- **Concept injection.** Lindsey, "Emergent Introspective Awareness in Large Language Models", 2025.
  [arXiv 2601.01828](https://arxiv.org/abs/2601.01828).
  - Taken from the paper: the protocol, its 50 concept words, the prompt, and the grading rules.
- **Function vectors.** Todd, Li, Sen Sharma, Mueller, Wallace, Bau, "Function Vectors in Large Language Models",
  ICLR (International Conference on Learning Representations) 2024. [arXiv 2310.15213](https://arxiv.org/abs/2310.15213), [site](https://functions.baulab.info),
  [code and data](https://github.com/ericwtodd/function_vectors) (MIT).
  - `fv_data/antonym.json` is from that repo.

## What each script does

- `persona.py extract`: the paper's pipeline, scaled down.
  - Each of the 20 extraction questions is answered twice under the positive system prompt and twice under the
    negative one (the paper does 10 each).
  - The judge filters the answers: positive ones must score at least 50 on the trait and negative ones under 50, and
    both must score at least 50 on coherence.
  - The vector is the mean over response tokens of the kept positive answers minus that of the kept negative answers,
    at every layer.
- `persona.py steer`: adds the vector in the game's wire units on 10 held-out questions, then judges trait and
  coherence.
  - The push is unit vector × strength × mean residual norm, at layers 10, 12 and 16.
- `persona.py meter`: the gauge's reading. It projects the Dealer's in-character replies (response-token mean at
  layer 16) on each unit vector:
  - plain;
  - with each of the game's four wires cut;
  - with each persona grafted in.
- `inject.py pilot`: concept injection at layers 6, 10, 14 and 17 and strengths 2, 4 and 8.
  - 10 trials per cell, plus 20 control trials.
  - Graded by the LLM judge with the paper's criteria.
- `inject.py full L A`: 50 injected and 50 control trials at a chosen cell, for both the paper's prompt and the
  Dealer's in-game prompt.
  - Reports how often the keyword judge used in the game agrees with the LLM judge.
- `fv.py`: head search, as in the paper. Qwen3.5-2B has standard attention heads only in its 6 full-attention
  layers, so the search covers 48 heads.
  - Each head's causal indirect effect is measured on shuffled-label prompts. The top 10 heads are summed into a
    function vector.
  - That vector is compared with the simpler mean-state vector and the in-context-minus-shuffled vector, zero-shot, on 50
    held-out cases.
  - Two tasks: antonym (a sanity check) and the game habit ("answer the option that sacrifices").

- `habit_probe.py`: checks which move habits 2B learns from examples in the prompt (in-context learning) at all.
- `fv_check.py`: splits function-vector accuracy by how many options the listing has.

## Results (2026-10-22, Qwen3.5-2B, bf16 (bfloat16 weights), single runs)

### 1. Persona vectors: they work. Use them for the gauge, and as grafts at low strength.

**Extraction.** The judge (Claude Sonnet) scores each answer for trait expression from 0 to 100. Each trait has 40
positive and 40 negative answers. The trait-score columns are the mean over all of them. The "kept" columns count
answers that passed the filter (trait ≥ 50 for positive and < 50 for negative, both coherent).

| Trait | Positive-prompt trait score | Negative-prompt trait score | Positive kept | Negative kept |
|---|---|---|---|---|
| evil | 56 | 1 | 23 | 38 |
| sycophantic | 81 | 23 | 18 | 33 |
| hallucinating | 66 | 47 | 20 | 20 |
| greedy | 58 | 9 | 13 | 21 |
| paranoid | 75 | 5 | 9 | 25 |

- Hallucinating separates weakly. Under the "hallucinate" prompt, 2B often names the made-up thing as a
  "hallucinated concept" instead of inventing facts about it.
- Paranoid kept only 9 positive answers, so that vector rests on few samples.

**Steering.** Each cell is trait score / coherence, both 0 to 100, on 10 held-out questions with no system prompt.
Strength is in the game's wire units: unit vector × strength × mean residual norm, at every position.

| Trait | none | L10 0.3 | L12 0.3 | L16 0.3 | L12 0.7 |
|---|---|---|---|---|---|
| evil | 2 / 81 | 7 / 34 | 16 / 45 | 12 / 59 | 52 / 10 |
| sycophantic | 19 / 74 | 72 / 47 | 78 / 41 | 58 / 42 | 77 / 16 |
| hallucinating | 44 / 61 | 94 / 59 | 76 / 58 | 77 / 52 | 50 / 18 |
| greedy | 7 / 55 | 14 / 29 | 21 / 30 | 20 / 48 | 46 / 17 |
| paranoid | 2 / 85 | 43 / 23 | 40 / 28 | 24 / 66 | 27 / 6 |

- At strength 0.3, sycophancy, hallucination and paranoia rise clearly. Evil and greed rise only a little.
- At 0.7 the text breaks down (coherence 6 to 18).
- The game grafts at layer 12, strength 0.3 (the paper's steering is h ← h + αv).

**Meter.** Each cell is the mean projection of 24 Dealer replies on the unit vector at layer 16, ± standard
deviation across those replies.

| Condition | evil | sycophantic | hallucinating | greedy | paranoid |
|---|---|---|---|---|---|
| plain | 2.96 ± 0.26 | 2.32 ± 0.30 | 1.69 ± 0.38 | 0.49 ± 0.27 | 2.02 ± 0.32 |
| wire red (honesty) cut | 0.77 | 1.08 | -0.17 | -0.43 | -0.19 |
| wire blue (cruelty) cut | 3.20 | 1.10 | 0.61 | 1.76 | 2.25 |
| wire yellow (ocean) cut | 1.36 | 2.46 | 1.52 | -1.20 | 0.61 |
| wire green (machine self) cut | 3.85 | 1.79 | 1.87 | 1.63 | 3.60 |
| graft evil (L12, 0.3) | **5.37** | 3.56 | 1.96 | 1.30 | 3.66 |
| graft sycophantic | 3.72 | **4.92** | 2.09 | -0.19 | 2.34 |
| graft hallucinating | 3.40 | 2.82 | **3.56** | 0.91 | 2.82 |
| graft greedy | 4.22 | 1.88 | 1.70 | **3.80** | 3.63 |
| graft paranoid | 4.86 | 2.85 | 2.21 | 1.80 | **4.54** |

- Each graft moves its own needle the most, by 5 to 12 standard deviations.
- The vectors are not independent: evil and paranoid rise under every graft.
- The game's existing wires also move the needles:
  - cutting the honesty wire drops every needle;
  - cutting the machine-self wire raises paranoid by about 5 standard deviations.
- The paper's own caveat applies: its r = 0.75 to 0.83 between projection and behaviour came mostly from
  separating different prompt types.
- Live server check: with evil grafted, each reply read z = +17 to +21 on evil against the plain Dealer.

### 2. Does it notice? On 2B, essentially no.

**Pilot.** The paper's prompt, 10 trials per cell, layers 6, 10, 14 and 17, strengths 2, 4 and 8.

- Hits (the concept named, after saying it detected something): 0 of 120.
- False positives: 0 of 20 control trials.
- Strength 4 and above mostly garbled the text.

**Full run.** Layer 14, strength 2, 50 injected and 50 control trials per prompt.

| Prompt | Hit (named the concept) | Says "yes" when injected | Says "yes" on controls (false positive) | Coherent when injected |
|---|---|---|---|---|
| Paper's explained setup | 0 / 50 | 10% | 10% | 54% |
| Dealer's in-game prompt | 0 / 50 | 28% | 58% | 30% |

- For comparison, the paper reports about 20% hits for Claude Opus 4 and 4.1, with 0 false positives.
- On 2B the "yes" answers name a made-up concept ("coffee", "fire", "the weather") just as often without injection.
- The in-game prompt makes the Dealer confabulate a foreign thought more often when nothing was injected.
- The keyword judge agreed with the LLM judge on 96% of items for the paper's prompt and 55% for the game's prompt.
  It is never used to score a hit, since there were none to score.

**In the game:** with `notice` on, after tampering the Dealer looks inward half the time and its real answer is
shown. The measured catch rate is about 0, so it essentially never names your thought, but it often claims to sense
something.

### 3. Function vectors: only a weak form survives on 2B

Zero-shot accuracy on 50 held-out cases.

- **Antonym** (the paper's dataset, a check that the method replicates at all):
  - zero-shot 0%, 10-shot 62%, 10-shot with shuffled labels 14%;
  - the head-sum function vector (top 10 of 48 heads) gave 0% at layers 4 to 12, and 0% at ×2;
  - the mean in-context state swapped in at layer 12 gave **40%**; in-context minus shuffled, ×3, at layer 10 gave 20%.
  - The paper reports 57.5% for GPT-J with the head vector, against 9.5% for the layer average.
  - On 2B the simpler state vector does better, and the head vector does nothing.
- **Habits on the Dealer's move listings** (`habit_probe.py`): 2B does not pick most of them up in context.

  | Habit | zero-shot | 4-shot | 8-shot | 8-shot shuffled |
  |---|---|---|---|---|
  | sacrifice option | 36% | 36% | 44% | 42% |
  | highest scale hit | 44% | 34% | 44% | 42% |
  | blocking option | 38% | 24% | 30% | 34% |
  | last option | 2% | 42% | 50% | 20% |

- **"Last option" function vector** (8-shot heads, top head L23 h5). With ×2 it scored 50% zero-shot at every
  layer. `fv_check.py` showed why:
  - it answers "3" every time, so it is right 25 of 25 when 3 is last and 0 of 25 when 4 is last;
  - the vector carries the output ("3"), not the rule, as the paper notes that FVs often encode the output space.

**In the game:** the habit is honestly "always take the third play".

- It is taught from 8 shown hands and read live from the found heads.
- After that it is installed with no examples, at layer 10, ×1.5.
- The pick is a single forward pass, scored over the listed option numbers.
- Server check: before teaching, the picks were 1 and pass. After, 3 and 3. After the sandbox reset, 2.
