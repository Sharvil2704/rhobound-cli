# SPDX-License-Identifier: Apache-2.0
"""Reference-only: how reference.json was produced (not part of this repository's build). Needs numpy and scipy
(tested with numpy 2.5.3, scipy 1.18.1); the Monte Carlo part takes a few minutes. Run from the repository root:
    python testdata/numerics/gen_reference.py testdata/numerics/reference.json

Sections (internal/mathx/reference_test.go and internal/model/reference_test.go read them):
  gamma_p        [a, x, P(a, x)]: a 50-digit decimal series where x <= a + 12 sqrt(a) + 60, else scipy gammainc
                 (there P is within 1e-30 of 1). Shapes 0.01..1e5.
  norm_cdf       [x, Phi(x)] for x in [-37.5, 8.25], scipy ndtr (cross-checked against exp(log_ndtr)).
  norm_quantile  [u, z]: scipy ndtri(u) below 1/2, -ndtri(1-u) above (1-u is exact there). u from 1e-300 to 1-2^-53.
  erlang_c       [m, a, C(m, a)]: the Erlang-B recurrence in 50-digit decimal, then C = m B / (m - a (1 - B)).
  emax_exp       E[max] of independent exponentials (2 to 16 branches), inclusion-exclusion in 90-digit decimal.
  max_gamma      E[max] and Var[max] of 2-8 gamma branches with shapes 0.3..100 under a Gaussian copula with one
                 common correlation r in 0..0.95 (r = 0: independent): P(max <= t) = E_z prod_j Phi((a_j(t) - sqrt(r) z)
                 / sqrt(1-r)), a_j(t) = Phi^-1(F_j(t)); the z-integral is a 1441-point trapezoid on [-9, 9], the
                 t-integrals of P(max > t) and 2t P(max > t) run to the 1-1e-18 quantile by adaptive quadrature
                 (quad_vec, epsrel 1e-12) between quantile breakpoints. Tails are kept accurate with log_ndtr / expm1.
  max_gamma_mc   The same moments for a few cases from 4e6 Monte Carlo samples, with their standard errors; the
                 quadrature is checked against them (within 4 se) before anything is written.
  max_gamma_mixed  The same moments, by the same quadrature, for one heavy branch (scv 1.5..1000, mean 10..300)
                 beside a near-constant one (scv 1e-4..0.1, mean 10), r in {0, 0.5, 0.9}: the cases where a grid
                 stretched to the heavy branch's tail under-resolves the narrow one (the numerics review).
"""
import json
import math
import sys
import time
from decimal import Decimal, getcontext
from fractions import Fraction

import numpy as np
from scipy import special as sp
from scipy.integrate import quad_vec

getcontext().prec = 60
PI = Decimal("3.14159265358979323846264338327950288419716939937510582097494459")


def log(*a):
    print(*a, file=sys.stderr, flush=True)


# ---------------------------------------------------------------- incomplete gamma
BERN = [Fraction(1, 6), Fraction(-1, 30), Fraction(1, 42), Fraction(-1, 30), Fraction(5, 66), Fraction(-691, 2730),
        Fraction(7, 6), Fraction(-3617, 510), Fraction(43867, 798), Fraction(-174611, 330), Fraction(854513, 138),
        Fraction(-236364091, 2730), Fraction(8553103, 6), Fraction(-23749461029, 870)]


def lngamma_dec(z):
    """ln Gamma(z), z > 0 a Decimal: shift to z >= 40, then Stirling's series (error < 1e-50)."""
    shift = Decimal(0)
    while z < 40:
        shift += z.ln()
        z += 1
    s = (z - Decimal("0.5")) * z.ln() - z + (2 * PI).ln() / 2
    zp = z
    for k, b in enumerate(BERN, start=1):
        s += Decimal(b.numerator) / Decimal(b.denominator) / (2 * k * (2 * k - 1) * zp)
        zp *= z * z
    return s - shift


def gammap_dec(a, x):
    """P(a, x) = x^a e^-x / Gamma(a+1) * sum_n x^n / ((a+1)...(a+n)), all terms positive."""
    A, X = Decimal(a), Decimal(x)  # the exact binary values
    term = tot = Decimal(1)
    n = 0
    while True:
        n += 1
        term *= X / (A + n)
        tot += term
        if n > X - A and term < tot * Decimal("1e-50"):
            break
    return float((A * X.ln() - X - lngamma_dec(A + 1)).exp() * tot)


def gen_gamma_p():
    shapes = [0.01, 0.02, 0.05, 0.1, 0.2, 0.3, 0.5, 0.7, 1, 1.5, 2, 3, 5, 7.5, 10, 20, 50, 100, 300, 1000, 3000,
              1e4, 3e4, 1e5]
    rows, worst = [], 0.0
    for a in shapes:
        sd = math.sqrt(a)
        xs = [1e-300, 1e-100, 1e-20, 1e-8, 1e-3 * a, 0.1 * a, 0.5 * a, a - 1, a, a + 1,
              math.nextafter(a + 1, 0), math.nextafter(a + 1, math.inf), 2 * a, 5 * a, 10 * a + 50, 50 * a + 700]
        xs += [a + z * sd for z in np.arange(-10, 10.25, 0.5)]
        for x in sorted(set(float(v) for v in xs if v > 0)):
            ref = float(sp.gammainc(a, x))
            if x <= a + 12 * sd + 60:
                d = gammap_dec(a, x)
                if d > 1e-290:
                    worst = max(worst, abs(ref - d) / d)
                ref = d
            rows.append([a, x, ref])
    log(f"gamma_p: {len(rows)} points; scipy vs 50-digit decimal, max relative difference {worst:.2e}")
    return rows


# ---------------------------------------------------------------- normal
def gen_norm():
    cdf = []
    for x in np.arange(-37.5, 8.26, 0.25):
        p = float(sp.ndtr(x))
        q = math.exp(float(sp.log_ndtr(x)))
        assert abs(p - q) <= 1e-13 * p, (x, p, q)
        cdf.append([float(x), p])
    us = [10.0 ** e for e in np.arange(-300, -0.99, 0.5)]
    us += [0.05, 0.075, 0.08, 0.1, 0.2, 0.3, 0.4, 0.45, 0.5, 0.55, 0.6, 0.7, 0.8, 0.9, 0.92, 0.925, 0.93, 0.95]
    us += [1 - 10.0 ** e for e in np.arange(-1, -16.01, -0.25)]
    us += [math.nextafter(1, 0)]
    qs = []
    for u in sorted(set(float(v) for v in us if 0 < v < 1)):
        if u < 0.5:
            z = float(sp.ndtri(u))
        else:
            z = -float(sp.ndtri(float(Fraction(1) - Fraction(u))))
        assert math.isfinite(z)
        qs.append([u, z])
    log(f"norm: {len(cdf)} cdf points, {len(qs)} quantile points")
    return cdf, qs


# ---------------------------------------------------------------- Erlang C
def erlang_c_dec(m, a):
    A = Decimal(a)
    if A >= m:
        return 1.0
    b = Decimal(1)
    for k in range(1, m + 1):
        b = A * b / (k + A * b)
    return float(m * b / (m - A * (1 - b)))


def gen_erlang_c():
    getcontext().prec = 50
    rows = []
    for m in [1, 2, 3, 4, 5, 8, 10, 16, 32, 64, 100, 128, 256, 419, 500, 700, 709, 720, 750, 800, 1000, 2000, 5000,
              20000, 100000]:
        for rho in [1e-6, 0.01, 0.1, 0.3, 0.5, 0.7, 0.75, 0.8, 0.85, 0.9, 0.95, 0.99, 0.999]:
            a = rho * m
            rows.append([m, a, erlang_c_dec(m, a)])
    getcontext().prec = 60
    log(f"erlang_c: {len(rows)} points")
    return rows


# ---------------------------------------------------------------- E[max] of exponentials
def emax_exp_exact(means):
    """sum over non-empty subsets S of (-1)^(|S|+1) / sum_{j in S} 1/mean_j in 90-digit decimal (the
    alternating sum cancels at most ~5 digits at 16 branches)."""
    getcontext().prec = 90
    rates = [1 / Decimal(x) for x in means]
    n = len(rates)
    sums = [Decimal(0)] * (1 << n)
    tot = Decimal(0)
    for mask in range(1, 1 << n):
        low = mask & -mask
        sums[mask] = sums[mask ^ low] + rates[low.bit_length() - 1]
        tot += (1 if bin(mask).count("1") % 2 else -1) / sums[mask]
    getcontext().prec = 60
    return float(tot)


def gen_emax_exp(rng):
    rows = []
    for n in [2, 3, 4, 6, 8, 10, 12, 13, 14, 16]:
        for kind in range(3):
            if kind == 0:
                means = [7.0] * n
            elif kind == 1:
                means = [float(10 ** (3 * j / (n - 1))) for j in range(n)]  # spread 1e3
            else:
                means = [float(1 + 99 * rng.random()) for _ in range(n)]
            rows.append({"means": means, "emax": emax_exp_exact(means)})
    log(f"emax_exp: {len(rows)} cases")
    return rows


# ---------------------------------------------------------------- E[max], Var[max] of gamma branches
ZS = np.linspace(-9, 9, 1441)
ZW = np.exp(-ZS ** 2 / 2)
ZW /= ZW.sum()


def shapes_of(mu, var):
    mu, var = np.asarray(mu, float), np.asarray(var, float)
    k = mu ** 2 / var
    return k, mu / k


def survival(t, k, th, r):
    """P(max > t), accurate in both tails."""
    P = np.array([sp.gammainc(kj, t / tj) for kj, tj in zip(k, th)])
    Q = np.array([sp.gammaincc(kj, t / tj) for kj, tj in zip(k, th)])
    if r == 0:
        with np.errstate(divide="ignore"):
            lp = np.where(P < 0.5, np.log(np.maximum(P, 1e-320)), np.log1p(-Q))
        s = lp.sum()
        return -math.expm1(s) if s > -700 else 1.0
    a = np.where(P < 0.5, sp.ndtri(np.maximum(P, 1e-320)), -sp.ndtri(np.maximum(Q, 1e-320)))
    a = np.where(P <= 0, -np.inf, a)
    arg = (a[:, None] - math.sqrt(r) * ZS[None, :]) / math.sqrt(1 - r)
    lp = sp.log_ndtr(arg).sum(axis=0)
    return float(np.dot(ZW, -np.expm1(lp)))


def max_moments_quad(mu, var, r):
    k, th = shapes_of(mu, var)
    end = max(float(sp.gammainccinv(kj, 1e-18)) * tj for kj, tj in zip(k, th))
    pts = set()
    for kj, tj in zip(k, th):
        for p in (1e-9, 1e-4, 0.01, 0.1, 0.3, 0.5, 0.7, 0.9, 0.99, 0.9999):
            pts.add(float(sp.gammaincinv(kj, p)) * tj)
        for q in (1e-6, 1e-9, 1e-12):
            pts.add(float(sp.gammainccinv(kj, q)) * tj)
    edges = [0.0] + sorted(p for p in pts if 0 < p < end) + [end]
    f = lambda t: (lambda s: np.array([s, 2 * t * s]))(survival(t, k, th, r))
    m = np.zeros(2)
    for lo, hi in zip(edges[:-1], edges[1:]):
        if hi > lo:
            m += quad_vec(f, lo, hi, epsabs=0, epsrel=1e-12, limit=400)[0]
    return float(m[0]), float(m[1] - m[0] ** 2)


def max_moments_mc(mu, var, r, nsamp=4_000_000, seed=1):
    """X_j = F_j^-1(Phi(sqrt(r) Z + sqrt(1-r) E_j)); returns mean, its se, variance, its se."""
    k, th = shapes_of(mu, var)
    rng = np.random.default_rng(seed)
    n, chunk = len(mu), 200_000
    sr, sq = math.sqrt(r), math.sqrt(1 - r)
    s = np.zeros(4)
    for _ in range(nsamp // chunk):
        g = sr * rng.standard_normal(chunk)[None, :] + sq * rng.standard_normal((n, chunk))
        x = np.empty_like(g)
        for j in range(n):  # the upper half through the complement, for the tail
            lo = g[j] < 0
            x[j][lo] = th[j] * sp.gammaincinv(k[j], sp.ndtr(g[j][lo]))
            x[j][~lo] = th[j] * sp.gammainccinv(k[j], sp.ndtr(-g[j][~lo]))
        mx = x.max(axis=0)
        s += [mx.sum(), (mx ** 2).sum(), (mx ** 3).sum(), (mx ** 4).sum()]
    e1, e2, e3, e4 = s / nsamp
    v = e2 - e1 ** 2
    m4 = e4 - 4 * e3 * e1 + 6 * e2 * e1 ** 2 - 3 * e1 ** 4  # 4th central moment
    return e1, math.sqrt(v / nsamp), v, math.sqrt(max(m4 - v * v, 0) / nsamp)


def gen_max_gamma(rng):
    cases = []
    for n in [2, 3, 4, 6, 8]:
        for k in [0.3, 0.7, 1, 2, 5, 20, 100]:
            for r in [0, 0.2, 0.5, 0.8, 0.95]:
                mu = [40 * (1 + 0.15 * j) for j in range(n)]
                cases.append((mu, [m * m / k for m in mu], r))
    for _ in range(40):  # unequal means (x0.3..x3) and mixed shapes 0.3..100
        n = int(rng.integers(2, 9))
        mu = [float(30 * math.exp((rng.random() - 0.5) * math.log(10))) for _ in range(n)]
        ks = [float(math.exp(math.log(0.3) + rng.random() * math.log(100 / 0.3))) for _ in range(n)]
        cases.append((mu, [m * m / kk for m, kk in zip(mu, ks)], float(rng.choice([0, 0.3, 0.6, 0.9, 0.95]))))
    rows, t0 = [], time.time()
    for mu, var, r in cases:
        m, v = max_moments_quad(mu, var, r)
        rows.append({"mu": mu, "var": var, "r": r, "mean": m, "var_max": v})
    log(f"max_gamma: {len(rows)} cases by quadrature in {time.time() - t0:.0f} s")
    # the z rule: halving the step must not move the answer
    global ZS, ZW
    keep = ZS, ZW
    ZS = np.linspace(-9, 9, 2881)
    ZW = np.exp(-ZS ** 2 / 2)
    ZW /= ZW.sum()
    dz = 0.0
    for row in rows[::9]:
        if row["r"] > 0:
            m, v = max_moments_quad(row["mu"], row["var"], row["r"])
            dz = max(dz, abs(m - row["mean"]) / row["mean"], abs(v - row["var_max"]) / row["var_max"])
    ZS, ZW = keep
    log(f"max_gamma: half the z step moves E[max] or Var[max] by at most {dz:.1e} relative")
    assert dz < 1e-10, dz
    return rows


def gen_max_gamma_mc():
    picks = [(2, 1.0, 0.95), (4, 2.0, 0.9), (8, 0.7, 0.8), (3, 20.0, 0.5), (2, 0.3, 0.5), (6, 0.3, 0.95), (5, 5.0, 0)]
    rows = []
    for i, (n, k, r) in enumerate(picks):
        mu = [40 * (1 + 0.15 * j) for j in range(n)]
        var = [m * m / k for m in mu]
        t0 = time.time()
        m, se, v, vse = max_moments_mc(mu, var, r, seed=100 + i)
        qm, qv = max_moments_quad(mu, var, r)
        log(f"max_gamma_mc: n={n} k={k} r={r}: MC {m:.5f} +- {se:.5f}, quadrature {qm:.5f} ({(qm - m) / se:+.2f} se); "
            f"var MC {v:.4f} +- {vse:.4f}, quadrature {qv:.4f} ({(qv - v) / vse:+.2f} se); {time.time() - t0:.0f} s")
        assert abs(qm - m) < 4 * se and abs(qv - v) < 4 * vse
        rows.append({"mu": mu, "var": var, "r": r, "samples": 4_000_000, "mean": m, "mean_se": se, "var_max": v,
                     "var_se": vse})
    return rows


def gen_max_gamma_mixed():
    rows, t0 = [], time.time()
    for h in [1.5, 10, 100, 1000]:
        for c in [1e-4, 1e-3, 0.1]:
            for ratio in [1, 10, 30]:
                for r in [0, 0.5, 0.9]:
                    mu = [10.0 * ratio, 10.0]
                    var = [mu[0] ** 2 * h, 100.0 * c]
                    m, v = max_moments_quad(mu, var, r)
                    rows.append({"mu": mu, "var": var, "r": r, "mean": m, "var_max": v})
    log(f"max_gamma_mixed: {len(rows)} cases by quadrature in {time.time() - t0:.0f} s")
    return rows


def main():
    rng = np.random.default_rng(20261019)
    out = {"about": "Reference values for internal/mathx and model.ErlangC; see gen_reference.py for the method."}
    out["gamma_p"] = gen_gamma_p()
    out["norm_cdf"], out["norm_quantile"] = gen_norm()
    out["erlang_c"] = gen_erlang_c()
    out["emax_exp"] = gen_emax_exp(rng)
    out["max_gamma"] = gen_max_gamma(rng)
    out["max_gamma_mc"] = gen_max_gamma_mc()
    out["max_gamma_mixed"] = gen_max_gamma_mixed()
    # one row per line, floats in shortest round-trip form
    parts = []
    for key, val in out.items():
        if isinstance(val, list):
            body = ",\n".join("  " + json.dumps(x, allow_nan=False) for x in val)
            parts.append(f'"{key}": [\n{body}\n]')
        else:
            parts.append(f'"{key}": {json.dumps(val)}')
    with open(sys.argv[1], "w") as f:
        f.write("{\n" + ",\n".join(parts) + "\n}\n")


if __name__ == "__main__":
    main()
