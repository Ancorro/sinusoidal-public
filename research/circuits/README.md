# Why it played that (sandbox feature `trace`)

After a Dealer move, the **Why?** button (sandbox only) opens a parchment ledger: which board lines, internal features
("cogs") and cut wires pushed its choice. Code: `brain/circuits.py` (server `GET /trace`), `scripts/trace_ui.gd`.

## Methods compared

| Method | What it gives | Fits the Dealer? |
|---|---|---|
| Attribution graphs over cross-layer transcoders (CLTs: sparse replacements of the MLPs, multi-layer perceptrons), Ameisen et al. 2025 [methods](https://transformer-circuits.pub/2025/attribution-graphs/methods.html); Lindsey et al. 2025 [biology](https://transformer-circuits.pub/2025/attribution-graphs/biology.html) | Full feature-to-feature graph per prompt, attention frozen, error nodes, pruning | Needs transcoders for the exact model; none exist for Qwen3.5 |
| [circuit-tracer](https://github.com/decoderesearch/circuit-tracer) (Hanna, Piotrowski, Lindsey, Ameisen, [BlackboxNLP 2025](https://aclanthology.org/2025.blackboxnlp-1.14.pdf)) | Open implementation; transcoders for Gemma-2-2B, Llama-3.2-1B, Qwen3 0.6B-14B (incl. `mwhanna/qwen3-4b-transcoders`), Gemma-3, GPT-OSS | Not Qwen3.5 (hybrid Gated DeltaNet + attention) |
| [Neuronpedia graph tools](https://www.neuronpedia.org/graph/info) ([blog](https://www.neuronpedia.org/blog/circuit-tracer)) | Hosted circuit-tracer graphs, incl. Qwen3-4B | Browser only, same model limit |
| Qwen-Scope sparse autoencoders (SAEs), [Qwen/SAE-Res-Qwen3.5-2B-Base-W32K-L0_50](https://huggingface.co/Qwen/SAE-Res-Qwen3.5-2B-Base-W32K-L0_50), [arXiv 2605.11887](https://arxiv.org/html/2605.11887v1) | Official residual-stream features for Qwen3.5-2B, every layer, 32k wide, top-50 | Yes: the Dealer's own model (trained on Base, applied to the instruct model, as Qwen's README suggests) |
| Occlusion, gradient x input, attribution patching (as in honesty-heads `steer.py ig_units`) | Per-line and per-unit effects on the choice | Yes, cheap |

## What was chosen and why

A light trace on the Dealer's own Qwen3.5-2B. Running circuit-tracer on Qwen3-4B would explain a *different* model's
choice, so it would be impressive but unfaithful. Every number in the ledger is measured on the real model with its
current cut wires. Target: logit of the chosen number minus logsumexp of the other listed numbers.

- Board lines: occlusion (delete the line, re-run). Exact.
- Features: Qwen-Scope SAEs at layers 8, 14, 20, decision position. Ranked by activation x gradient; the six shown are
  then really ablated, and the ledger draws the ablated effect. A reconstruction-error term is kept per layer.
- Line -> feature edges: change in the feature's activation when the line is deleted, times its per-unit effect.
- Cut wires: the wire's push removed, choice re-measured. Exact.

## Results (a university Slurm cluster, Quadro RTX 8000, job 21902144, `eval_21902144.txt`)

- 20 traced moves from real games (12 intact, 8 with red + green cut; 4 cut moves had no plain digit answer, so no trace).
- Speed: median 3.0 s, max 3.6 s per trace after load on the cluster. Local consumer GPU (RTX 4060 Ti, otherwise idle, no fast kernels): 2.0 s warm, 4.4 s for the first trace (loads the autoencoders). `/trace` holds the server lock, so a following `/move` waits for it.
- Local repeat of the example board (sampled answer was option 1 this time): the green wire pushed -2.34 away from option 1, matching the cluster run's +2.28 toward option 2.
- Features: predicted vs ablated effect, Pearson 0.87, sign agreement 100% (n 120). The linear estimate is trustworthy
  for ranking, but ablations run about 1.5x larger, so the ledger shows ablations.
- Gradient x input per line vs occlusion: median rank correlation -0.33. Gradients are not a usable stand-in here.
- Most of the push comes from the option texts themselves; board lines matter less.
- Cut wires dominate when cut: green ("machine self") moved the choice by 2.3 to 3.7 logits, more than any line or feature.
- Example (`example_trace.json`, served by `stub_server.py --trace=`; board and answer in `example_move.json`): with red
  and green cut, the Dealer played option 2 (Raven blocks the Ghoul) at 19% probability among the listed options. The green wire alone pushed +2.28 toward it.

## Limits

- Features are read only at the decision position; what attention carries from earlier positions is not traced.
- Feature labels are weak: most top features fire on newlines and template tokens. The ledger calls them "unnamed cogs"
  unless a plain English token tops the decoder's vocabulary projection.
- The sparse autoencoders are trained on the base model.
- The ledger is fetched after every pick; with two or three picks in one turn it may show a later pick only.
- Traces only a first-try single-digit answer (4 of 8 cut-wire moves gave none) (up to 9 options); retries, word answers and the RL (reinforcement
  learning) mode get no trace.
- A full attribution graph (feature-to-feature over all layers) would need transcoders trained for Qwen3.5-2B on a
  cluster. That is a possible follow-up, not done.

## Screenshots

- `why_sandbox.png`: the ledger for the example move (sandbox on, stub serving `example_trace.json`), shown 2x.
- `main_mode.png`: sandbox off, no Why? button, game unchanged.
- `sandbox_menu.png`: Debug menu, SANDBOX MODE list with "Why it played that" switchable.
