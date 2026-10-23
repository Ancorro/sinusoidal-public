"""The RL Dealer's policy, a bias on top of track C's scorer (spec L.5), in plain numpy so play needs no torch.

logits(option) = BETA * scorer(option) + strength * bias(option), scorer relative to passing and clipped to +-30
bias = MLP over [board features (CTX), brain vector, option features (OPT)], fused by concatenation.
In the game the bias is added to the scorer's values as strength * bias / BETA (scripts/dealer_ai.gd); strength 0
leaves the scorer untouched.
A separate value head (CTX + brain only) is used in training.
"""
import numpy as np

BETA = 1.0
HIDDEN = (128, 64)


def init(n_in, n_val, rng):
    def layer(i, o, scale=1.0):
        return [rng.normal(0, scale / np.sqrt(i), (i, o)).astype(np.float32), np.zeros(o, np.float32)]
    p = {}
    dims = [n_in, *HIDDEN]
    for k in range(len(HIDDEN)):
        p[f"W{k}"], p[f"b{k}"] = layer(dims[k], dims[k + 1])
    p["Wo"], p["bo"] = layer(HIDDEN[-1], 1, 0.01)   # starts as ~zero bias: plays like greedy
    vd = [n_val, *HIDDEN]
    for k in range(len(HIDDEN)):
        p[f"V{k}"], p[f"c{k}"] = layer(vd[k], vd[k + 1])
    p["Vo"], p["co"] = layer(HIDDEN[-1], 1, 0.01)
    return p


def bias(p, x):
    """x: [..., n_in] -> [...]"""
    h = x
    for k in range(len(HIDDEN)):
        h = np.tanh(h @ p[f"W{k}"] + p[f"b{k}"])
    return (h @ p["Wo"] + p["bo"])[..., 0]


def logits(p, ctx, brain, opts, greedy, strength=1.0):
    """ctx [n_ctx], brain [n_brain], opts [n, n_opt], greedy [n] -> [n]"""
    n = len(opts)
    x = np.concatenate([np.repeat(np.concatenate([ctx, brain])[None], n, 0), np.asarray(opts, np.float32)], 1)
    return BETA * np.asarray(greedy, np.float32) + strength * bias(p, x.astype(np.float32))
