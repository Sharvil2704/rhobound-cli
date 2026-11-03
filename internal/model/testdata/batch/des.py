#!/usr/bin/env python3
"""des.py: seeded discrete-event simulation of an M^X/G/c FIFO queue (stdlib only).

Batch epochs are Poisson per class; a class has a rate (per unit time) and a batch-size law (list of [k, weight]).
All members of a batch arrive at the same instant and join the FIFO queue in order; c identical workers take the
earliest-free worker (greedy FIFO). Service ~ gamma(mean s, scv cs2) (cs2 = 0: deterministic). A member's optional
post time (after its worker is freed: e.g. pricing's tax call) is p * gamma(mean pm, scv pc2). The batch makespan is
max over members of (service completion + post) - epoch. Variants share the random draws (common random numbers):
each variant is (add, mul): service S' = max(0, S * mul + add).

Usage: des.py CONFIGS.json OUT.json [WORKERS]   CONFIGS: list of {id, c, s, cs2, classes:[{rate, sizes:[[k,w],..]}],
       post: null | {p, mean, cs2}, variants: [[add, mul], ...], members: N, seed}
Output per config and variant: W0 (first-member wait per epoch: the virtual wait, PASTA), Wbar (all members),
per class: wait (members), makespan; per size k: makespan; block standard errors (20 blocks)."""
import heapq, json, math, random, sys
from multiprocessing import Pool


def gam(rng, mean, scv):
    if mean <= 0:
        return 0.0
    if scv <= 0:
        return mean
    k = 1.0 / scv
    return rng.gammavariate(k, mean / k)


def run(cfg):
    rng = random.Random(cfg["seed"])
    c, s, cs2 = cfg["c"], cfg["s"], cfg["cs2"]
    classes = cfg["classes"]
    post = cfg.get("post")
    variants = cfg["variants"]
    nv = len(variants)
    lam = sum(x["rate"] for x in classes)
    cum, acc = [], 0.0
    for x in classes:
        acc += x["rate"] / lam
        cum.append(acc)
    szs = []
    for x in classes:
        ks = [k for k, _ in x["sizes"]]
        ws = [w for _, w in x["sizes"]]
        tw = sum(ws)
        cw, a = [], 0.0
        for w in ws:
            a += w / tw
            cw.append(a)
        szs.append((ks, cw))
    target = cfg["members"]
    warm = target // 20
    nblk = 20
    free = [[0.0] * c for _ in range(nv)]
    # accumulators per variant
    A = [{"w0": [0.0] * nblk, "nep": [0] * nblk, "wsum": [0.0] * nblk, "nm": [0] * nblk,
          "cls_w": [0.0] * len(classes), "cls_nm": [0] * len(classes), "cls_ms": [0.0] * len(classes), "cls_ne": [0] * len(classes),
          "k_ms": {}, "k_ne": {}, "busy": 0.0} for _ in range(nv)]
    t = 0.0
    m = 0
    tstart = None
    while m < target + warm:
        t += rng.expovariate(lam)
        u = rng.random()
        ci = 0
        while cum[ci] < u and ci < len(cum) - 1:
            ci += 1
        ks, cw = szs[ci]
        u = rng.random()
        j = 0
        while cw[j] < u and j < len(cw) - 1:
            j += 1
        k = ks[j]
        S = [gam(rng, s, cs2) for _ in range(k)]
        if post:
            P = [gam(rng, post["mean"], post["cs2"]) if rng.random() < post["p"] else 0.0 for _ in range(k)]
        else:
            P = [0.0] * k
        rec = m >= warm
        if rec and tstart is None:
            tstart = t
        blk = min(nblk - 1, (m - warm) * nblk // target) if rec else 0
        for vi in range(nv):
            add, mul = variants[vi]
            fr = free[vi]
            a = A[vi]
            ms = 0.0
            w0 = 0.0
            wsum = 0.0
            busy = 0.0
            for i in range(k):
                f = fr[0]
                st = t if t > f else f
                sv = S[i] * mul + add
                if sv < 0:
                    sv = 0.0
                e = st + sv
                heapq.heapreplace(fr, e)
                w = st - t
                if i == 0:
                    w0 = w
                wsum += w
                busy += sv
                cmp_ = e + P[i] - t
                if cmp_ > ms:
                    ms = cmp_
            if rec:
                a["w0"][blk] += w0
                a["nep"][blk] += 1
                a["wsum"][blk] += wsum
                a["nm"][blk] += k
                a["cls_w"][ci] += wsum
                a["cls_nm"][ci] += k
                a["cls_ms"][ci] += ms
                a["cls_ne"][ci] += 1
                a["k_ms"][k] = a["k_ms"].get(k, 0.0) + ms
                a["k_ne"][k] = a["k_ne"].get(k, 0) + 1
                a["busy"] += busy
        m += k
    span = t - tstart
    out = {"id": cfg["id"], "variants": []}
    for vi in range(nv):
        a = A[vi]

        def bm(num, den):
            xs = [num[b] / den[b] for b in range(nblk) if den[b] > 0]
            mu = sum(num) / sum(den)
            sd = math.sqrt(sum((x - mu) ** 2 for x in xs) / (len(xs) - 1)) if len(xs) > 1 else float("nan")
            return mu, sd / math.sqrt(len(xs))
        w0, w0se = bm(a["w0"], a["nep"])
        wb, wbse = bm(a["wsum"], a["nm"])
        out["variants"].append({
            "add": variants[vi][0], "mul": variants[vi][1],
            "rho": a["busy"] / span / c,
            "W0": w0, "W0_se": w0se, "Wbar": wb, "Wbar_se": wbse,
            "cls_wait": [a["cls_w"][i] / a["cls_nm"][i] if a["cls_nm"][i] else None for i in range(len(classes))],
            "cls_makespan": [a["cls_ms"][i] / a["cls_ne"][i] if a["cls_ne"][i] else None for i in range(len(classes))],
            "k_makespan": {str(k): a["k_ms"][k] / a["k_ne"][k] for k in sorted(a["k_ms"])},
        })
    return out


def main():
    cfgs = json.load(open(sys.argv[1]))
    nw = int(sys.argv[3]) if len(sys.argv) > 3 else 1
    if nw > 1:
        with Pool(nw) as p:
            res = p.map(run, cfgs, chunksize=1)
    else:
        res = [run(c) for c in cfgs]
    json.dump(res, open(sys.argv[2], "w"), indent=0)


if __name__ == "__main__":
    main()
