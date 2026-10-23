"""Per cut set: the brain vector the policy sees and the temperament that weights its style rewards, from
rl/brain_vectors.npz (the real model's steered activations). Writes rl/brain_table.json.

brain vector (12 numbers): at read layers 15 and 18, the decision-position residual projected on the 4 style axes and
on the 4 wire directions (layer 15 only for the wires), averaged over the board bank, minus the no-cut value, divided
by the spread across the 16 cut sets. temperament (4 numbers): the layer-15 style part, clipped to [-2, 2].

python rl/brain_table.py [rl/brain_vectors.npz]
"""
import json
import sys
from pathlib import Path

import numpy as np

HERE = Path(__file__).resolve().parent


def key(cut):
    return "+".join(cut) if cut else "none"


def main():
    d = np.load(sys.argv[1] if len(sys.argv) > 1 else HERE / "brain_vectors.npz")
    cuts = [str(c) for c in d["cut_sets"]]
    parts = [d["style15"].mean(1), d["style18"].mean(1), d["wireproj15"].mean(1)]
    raw = np.concatenate(parts, 1)                          # [16, 12]
    z = (raw - raw[0]) / (raw.std(0) + 1e-6)
    table = {"style": [str(s) for s in d["style"]], "wires": [str(w) for w in d["wires"]], "dims": z.shape[1],
             "cuts": {}}
    for i, c in enumerate(cuts):
        table["cuts"][c or "none"] = {"brain": [round(float(v), 4) for v in z[i]],
                                      "temper": [round(float(v), 4) for v in np.clip(z[i, :4], -2, 2)]}
    (HERE / "brain_table.json").write_text(json.dumps(table, indent=1))
    print("cut set                    temperament (" + ", ".join(table["style"]) + ")")
    for c, v in table["cuts"].items():
        print(f"  {c:24s} " + " ".join(f"{x:6.2f}" for x in v["temper"]))


if __name__ == "__main__":
    main()
