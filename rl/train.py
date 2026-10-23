"""PPO self-play for the RL Dealer. CPU only; run on a cluster.

Each iteration: worker processes play episodes with the numpy policy (a random cut set per episode, its brain vector
and temperament from rl/brain_table.json), then torch does clipped PPO updates on the collected decisions.
Saves rl/out/<name>/policy.npz (weights) and log.jsonl.

python rl/train.py --name run1 --iters 60 --episodes 256 [--style-w 0.15] [--seed 1]
"""
import argparse
import json
import multiprocessing as mp
import random
import time
from pathlib import Path

import numpy as np
import torch

import features as F
import policy as P
from env import Episode

HERE = Path(__file__).resolve().parent
TABLE = json.loads((HERE / "brain_table.json").read_text())
CUTS = list(TABLE["cuts"])
N_BRAIN = TABLE["dims"]
N_IN = F.N_CTX + N_BRAIN + F.N_OPT
N_VAL = F.N_CTX + N_BRAIN


def softmax(x):
    e = np.exp(x - x.max())
    return e / e.sum()


def rollout(args):
    """Play episodes with params p; returns decisions and per-episode results."""
    p, n, seed, style_w, strength, cut_choice, greedy_only = args
    rng = random.Random(seed)
    nrng = np.random.default_rng(seed)
    steps, eps = [], []
    for _ in range(n):
        cut = cut_choice if cut_choice else rng.choice(CUTS)
        row = TABLE["cuts"][cut]
        brain = np.array(row["brain"], np.float32)
        ep = Episode(rng, row["temper"], style_w)
        traj = []
        ret = 0.0
        while ep.needs_decision():
            legal, opts, g = F.options(ep.b, "dealer")
            ctx = np.array(F.ctx(ep.b, "dealer", ep.picks_left), np.float32)
            lg = P.logits(p, ctx, brain, opts, g, strength)
            if greedy_only:
                a = int(np.argmax(g)) if max(g) > 0.01 else 0
            else:
                a = int(nrng.choice(len(lg), p=softmax(lg)))
            logp = float(np.log(softmax(lg)[a] + 1e-12))
            v = float(value_np(p, np.concatenate([ctx, brain])))
            r = ep.act(None if a == 0 else legal[a - 1])
            ret += r
            traj.append({"ctx": ctx, "brain": brain, "opts": np.array(opts, np.float32),
                         "g": np.array(g, np.float32), "a": a, "logp": logp, "v": v, "r": r})
        if traj:
            traj[-1]["r"] += 0.0
        steps.append(traj)
        st = getattr(ep, "stats", {"dmg": 0, "sac": 0, "kills": 0, "played": 0, "turns": 0})
        eps.append({"cut": cut, "win": ep.b.winner == "dealer", "ret": ret, **st})
    return steps, eps


def value_np(p, x):
    h = x
    for k in range(len(P.HIDDEN)):
        h = np.tanh(h @ p[f"V{k}"] + p[f"c{k}"])
    return (h @ p["Vo"] + p["co"])[0]


def to_torch(p):
    return {k: torch.tensor(v, requires_grad=True) for k, v in p.items()}


def mlp(tp, x, pre, out):
    h = x
    for k in range(len(P.HIDDEN)):
        h = torch.tanh(h @ tp[f"{pre[0]}{k}"] + tp[f"{pre[1]}{k}"])
    return (h @ tp[out[0]] + tp[out[1]])[..., 0]


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--name", default="run")
    ap.add_argument("--iters", type=int, default=60)
    ap.add_argument("--episodes", type=int, default=256)
    ap.add_argument("--style-w", type=float, default=0.15)
    ap.add_argument("--seed", type=int, default=1)
    ap.add_argument("--workers", type=int, default=max(1, mp.cpu_count() - 1))
    ap.add_argument("--lr", type=float, default=1e-3)
    ap.add_argument("--gamma", type=float, default=0.99)
    ap.add_argument("--lam", type=float, default=0.95)
    ap.add_argument("--clip", type=float, default=0.2)
    ap.add_argument("--epochs", type=int, default=4)
    ap.add_argument("--ent", type=float, default=0.01)
    a = ap.parse_args()
    out = HERE / "out" / a.name
    out.mkdir(parents=True, exist_ok=True)
    torch.manual_seed(a.seed)
    p = P.init(N_IN, N_VAL, np.random.default_rng(a.seed))
    tp = to_torch(p)
    opt = torch.optim.Adam(tp.values(), lr=a.lr)
    pool = mp.Pool(a.workers)
    log = open(out / "log.jsonl", "w")
    t0 = time.time()
    per = max(1, a.episodes // a.workers)
    for it in range(a.iters):
        res = pool.map(rollout, [(p, per, a.seed * 100003 + it * 997 + w, a.style_w, 1.0, None, False)
                                 for w in range(a.workers)])
        trajs = [t for s, _ in res for t in s]
        eps = [e for _, e in res for e in e]
        # GAE (generalized advantage estimation) per episode
        flat = []
        for tr in trajs:
            adv, last = 0.0, 0.0
            for k in reversed(range(len(tr))):
                d = tr[k]
                nv = tr[k + 1]["v"] if k + 1 < len(tr) else 0.0
                delta = d["r"] + a.gamma * nv - d["v"]
                adv = delta + a.gamma * a.lam * adv
                d["adv"], d["ret"] = adv, adv + d["v"]
            flat += tr
        advs = np.array([d["adv"] for d in flat], np.float32)
        advs = (advs - advs.mean()) / (advs.std() + 1e-8)
        # pad options to a batch
        n = len(flat)
        m = max(len(d["opts"]) for d in flat)
        X = np.zeros((n, m, N_IN), np.float32)
        G = np.zeros((n, m), np.float32)
        mask = np.zeros((n, m), bool)
        V = np.zeros((n, N_VAL), np.float32)
        for i, d in enumerate(flat):
            k = len(d["opts"])
            base = np.concatenate([d["ctx"], d["brain"]])
            X[i, :k] = np.concatenate([np.repeat(base[None], k, 0), d["opts"]], 1)
            G[i, :k] = d["g"]
            mask[i, :k] = True
            V[i] = base
        X, G, mask, V = map(torch.tensor, (X, G, mask, V))
        A = torch.tensor([d["a"] for d in flat])
        OLD = torch.tensor([d["logp"] for d in flat])
        ADV = torch.tensor(advs)
        RET = torch.tensor([d["ret"] for d in flat], dtype=torch.float32)
        stats = {}
        for ep_ in range(a.epochs):
            perm = torch.randperm(n)
            for s in range(0, n, 1024):
                idx = perm[s:s + 1024]
                lg = P.BETA * G[idx] + mlp(tp, X[idx], "Wb", ("Wo", "bo"))
                lg = lg.masked_fill(~mask[idx], -1e9)
                lp = torch.log_softmax(lg, -1)
                new = lp.gather(1, A[idx, None])[:, 0]
                ratio = torch.exp(new - OLD[idx])
                pl = -torch.min(ratio * ADV[idx], ratio.clamp(1 - a.clip, 1 + a.clip) * ADV[idx]).mean()
                ent = -(lp.exp() * lp.masked_fill(~mask[idx], 0)).sum(-1).mean()
                vl = ((mlp(tp, V[idx], "Vc", ("Vo", "co")) - RET[idx]) ** 2).mean()
                loss = pl + 0.5 * vl - a.ent * ent
                opt.zero_grad()
                loss.backward()
                torch.nn.utils.clip_grad_norm_(tp.values(), 0.5)
                opt.step()
                stats = {"pl": pl.item(), "vl": vl.item(), "ent": ent.item(),
                         "kl": (OLD[idx] - new).mean().item()}
        p = {k: v.detach().numpy().copy() for k, v in tp.items()}
        row = {"iter": it, "episodes": len(eps), "decisions": n, "win": float(np.mean([e["win"] for e in eps])),
               "ret": float(np.mean([e["ret"] for e in eps])), "sec": round(time.time() - t0, 1), **stats}
        log.write(json.dumps(row) + "\n")
        log.flush()
        print(json.dumps(row), flush=True)
        if it % 10 == 9 or it == a.iters - 1:
            np.savez(out / "policy.npz", **p)
    pool.close()


if __name__ == "__main__":
    main()
