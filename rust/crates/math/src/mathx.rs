// SPDX-License-Identifier: Apache-2.0

//! The numerical kernels of rhobound-cli's `internal/mathx`, ported line by line with the same quadrature
//! rules, caps and floors: the regularized incomplete gamma function, the standard normal distribution and its
//! quantile, and the moments of the maximum of gamma or exponential branches (independent or under a Gaussian
//! copula). Every fused multiply-add sits where Go's arm64 build has one (see [`crate::gomath`]), so the results
//! are Go's bit for bit (tests/parity_kernels.rs, tests/parity_oracle.rs).
//!
//! What differs from Go is only how much work is done, never a value:
//! * `lgamma(k)` of a branch is computed once per call instead of once per quadrature point (a pure function of
//!   the same input), and the copula's 65 nodes and weights are constants (Go's own values, checked);
//! * the copula's node factors are computed branch by branch along the nodes (two or four lanes at a time
//!   through [`crate::simd`], each lane the scalar function's bits), then multiplied and summed in Go's order;
//! * a factor that Go's erfc makes exactly 1 (argument below -6) or exactly 0 (argument 28 or more, and then
//!   for every later node too) is not computed (see `corr_cdf`);
//! * a product of independent factors that reaches exactly 0 stops early (`indep_cdf`).
//!
//! [`max_moments_gamma_corr_par`] evaluates the quadrature points on rayon threads and sums them in Go's
//! order, so it is bit-identical as well; [`MaxMemo`] reuses results across evaluations by their input bits.

use crate::gomath::{self, erfc, erfinv, exp, fma, lgamma, log};
use rayon::prelude::*;
use std::collections::HashMap;
use std::f64::consts::SQRT_2;
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::Mutex;

/// GammaP is the regularized lower incomplete gamma function P(a, x): 0 for x <= 0, 1 at x = +Inf, and NaN
/// unless a is positive and finite and x is a number. Below x = a+1 it sums the series, above it the continued
/// fraction for Q = 1-P (modified Lentz), each to 1e-15 relative in at most 10000 terms (Go's `mathx.GammaP`).
pub fn gamma_p(a: f64, x: f64) -> f64 {
    if !(a > 0.0) || a == f64::INFINITY || x.is_nan() {
        return f64::NAN;
    }
    if x <= 0.0 {
        return 0.0;
    }
    if x == f64::INFINITY {
        return 1.0;
    }
    gamma_p_lg(a, x, lgamma(a))
}

/// [`gamma_p`] for a finite a > 0 and x > 0 (not +Inf, not NaN) with `lg = lgamma(a)` given.
#[inline]
fn gamma_p_lg(a: f64, x: f64, lg: f64) -> f64 {
    if x < a + 1.0 {
        // series; Go fuses `sum += term` with the product that made the term
        let mut sum = 1.0 / a;
        let mut term = sum;
        let mut n = 1i32;
        while n < 10000 {
            let q = x / (a + n as f64);
            sum = fma(term, q, sum);
            term *= q;
            if term.abs() < sum.abs() * 1e-15 {
                break;
            }
            n += 1;
        }
        return sum * exp(fma(a, log(x), -x) - lg);
    }
    // continued fraction for Q(a, x) (modified Lentz)
    const TINY: f64 = 1e-300;
    let mut b = x + 1.0 - a;
    let mut c = 1.0 / TINY;
    let mut d = 1.0 / b;
    let mut h = d;
    let mut i = 1i32;
    while i < 10000 {
        let fi = i as f64;
        let an = -(fi * (fi - a));
        b += 2.0;
        d = fma(an, d, b);
        if d.abs() < TINY {
            d = tiny();
        }
        c = b + an / c;
        if c.abs() < TINY {
            c = tiny();
        }
        d = 1.0 / d;
        let del = d * c;
        h *= del;
        if fma(d, c, -1.0).abs() < 1e-15 {
            break;
        }
        i += 1;
    }
    fma(-exp(fma(a, log(x), -x) - lg), h, 1.0)
}

/// Lentz's floor, out of line: the call keeps `if |d| < tiny` a predicted branch instead of a select on the
/// continued fraction's critical path.
#[cold]
#[inline(never)]
fn tiny() -> f64 {
    1e-300
}

/// NormCDF is the standard normal distribution function, `0.5 * Erfc(-x/Sqrt2)`.
#[inline]
pub fn norm_cdf(x: f64) -> f64 {
    0.5 * erfc(-x / SQRT_2)
}

/// NormQuantile is the standard normal quantile for u in (0, 1); -Inf at 0, +Inf at 1. Below u = 0.075 the value
/// is polished on u itself by three Halley steps (Go's `mathx.NormQuantile`).
pub fn norm_quantile(u: f64) -> f64 {
    let z0 = SQRT_2 * erfinv(2.0 * u - 1.0);
    if !(u > 0.0) || u >= 0.075 {
        return z0;
    }
    let mut z = z0;
    if z == f64::NEG_INFINITY {
        // asymptotic start: l = -2 ln u; z = -sqrt(l - ln l - ln 2pi), the first difference fused
        let lu = log(u);
        let l = -2.0 * lu;
        z = -(fma(-2.0, lu, -log(l)) - log(2.0 * std::f64::consts::PI)).sqrt();
    }
    let sqrt_2pi = (2.0 * std::f64::consts::PI).sqrt();
    for _ in 0..3 {
        // (NormCDF(z) - u) with NormCDF inlined: 0.5*erfc(...) - u fused
        let num = fma(erfc(-z / SQRT_2), 0.5, -u);
        let d = num / (exp(-(z * z) * 0.5) / sqrt_2pi);
        z -= d / fma(z * d, 0.5, 1.0);
    }
    z
}

// The 10-point Gauss-Legendre rule on [-1, 1] as Go's gaussLegendre(10) computes it (its exact bits; Go computes
// them at init by Newton's method from Tricomi's guess).
const GL_X_BITS: [u64; 10] = [
    0xbfef2a3e062af2d7,
    0xbfebae995e9cb2f3,
    0xbfe5bdb9228de198,
    0xbfdbbcc009016adb,
    0xbfc30e507891e27a,
    0x3fc30e507891e27a,
    0x3fdbbcc009016adb,
    0x3fe5bdb9228de198,
    0x3febae995e9cb2f3,
    0x3fef2a3e062af2d7,
];
const GL_W_BITS: [u64; 10] = [
    0x3fb1115f8b62dc07,
    0x3fc32138c878efe2,
    0x3fcc0b059d00bc36,
    0x3fd13baa7a559bfc,
    0x3fd2e9de7014d6f0,
    0x3fd2e9de7014d6f0,
    0x3fd13baa7a559bfc,
    0x3fcc0b059d00bc36,
    0x3fc32138c878efe2,
    0x3fb1115f8b62dc07,
];

/// The normalised weights of the copula's 65-point trapezoid on [-8, 8] (nodes -8 + q/4), Go's values:
/// `zw[q] = Exp(-zs*zs/2) / sum` (checked against a recomputation with the ported `Exp` in the tests).
const ZW_BITS: [u64; 65] = [
    0x3cd6c0df3a094836,
    0x3d045e8308d25d86,
    0x3d3121483257eba1,
    0x3d5b10f57d25a807,
    0x3d841663f31db14d,
    0x3dac027cdafdb7f0,
    0x3dd258556ae47e7b,
    0x3df6930a864fa47d,
    0x3e1a1880fbd087ff,
    0x3e3c56b24c535bf8,
    0x3e5ce8ec39250978,
    0x3e7bb4a8be266ce7,
    0x3e98f16964c8fd41,
    0x3eb518646fbb0c6e,
    0x3ed0c29a533d0bc6,
    0x3ee904afdde8cca5,
    0x3f018a98e2c0b4b6,
    0x3f171b92ecaaa793,
    0x3f2c9897d147e621,
    0x3f409f38e18a2822,
    0x3f5227213fd7768a,
    0x3f629fa54c6341e6,
    0x3f71f2f0557f5258,
    0x3f80402dfd3dc1a2,
    0x3f8ba4b436e83ad7,
    0x3f96164536bf162d,
    0x3fa0940856d21e86,
    0x3fa7610b9431f0ca,
    0x3faef8e58e33173a,
    0x3fb345d5efad3416,
    0x3fb6883d022086ae,
    0x3fb8bf2ba104becf,
    0x3fb9884533d43653,
    0x3fb8bf2ba104becf,
    0x3fb6883d022086ae,
    0x3fb345d5efad3416,
    0x3faef8e58e33173a,
    0x3fa7610b9431f0ca,
    0x3fa0940856d21e86,
    0x3f96164536bf162d,
    0x3f8ba4b436e83ad7,
    0x3f80402dfd3dc1a2,
    0x3f71f2f0557f5258,
    0x3f629fa54c6341e6,
    0x3f5227213fd7768a,
    0x3f409f38e18a2822,
    0x3f2c9897d147e621,
    0x3f171b92ecaaa793,
    0x3f018a98e2c0b4b6,
    0x3ee904afdde8cca5,
    0x3ed0c29a533d0bc6,
    0x3eb518646fbb0c6e,
    0x3e98f16964c8fd41,
    0x3e7bb4a8be266ce7,
    0x3e5ce8ec39250978,
    0x3e3c56b24c535bf8,
    0x3e1a1880fbd087ff,
    0x3df6930a864fa47d,
    0x3dd258556ae47e7b,
    0x3dac027cdafdb7f0,
    0x3d841663f31db14d,
    0x3d5b10f57d25a807,
    0x3d3121483257eba1,
    0x3d045e8308d25d86,
    0x3cd6c0df3a094836,
];

const NZ: usize = 65;

#[inline(always)]
fn gl_x(q: usize) -> f64 {
    f64::from_bits(GL_X_BITS[q])
}
#[inline(always)]
fn gl_w(q: usize) -> f64 {
    f64::from_bits(GL_W_BITS[q])
}
#[inline(always)]
fn zs(q: usize) -> f64 {
    -8.0 + q as f64 / 4.0 // exact, as Go's -8 + 16*float64(i)/64
}
#[inline(always)]
fn zw(q: usize) -> f64 {
    f64::from_bits(ZW_BITS[q])
}

/// The Gauss-Legendre nodes and weights (Go's glX, glW), for tests and tools.
pub fn gl_nodes() -> ([f64; 10], [f64; 10]) {
    let mut x = [0.0; 10];
    let mut w = [0.0; 10];
    for q in 0..10 {
        x[q] = gl_x(q);
        w[q] = gl_w(q);
    }
    (x, w)
}

/// The copula's z nodes and normalised weights (Go's zs, zw in gammaMaxCDFCorr), for tests and tools.
pub fn corr_nodes() -> (Vec<f64>, Vec<f64>) {
    ((0..NZ).map(zs).collect(), (0..NZ).map(zw).collect())
}

/// Recomputes the copula weights as Go does, with the ported `Exp` (a test checks it equals [`corr_nodes`]).
pub fn corr_weights_recomputed() -> Vec<f64> {
    let mut w: Vec<f64> = (0..NZ).map(|q| exp(-(zs(q) * zs(q)) * 0.5)).collect();
    let mut sum = 0.0;
    for x in &w {
        sum += x;
    }
    for x in w.iter_mut() {
        *x /= sum;
    }
    w
}

/// gammaBranches: a gamma (shape k, scale th) matched to each branch's mean and variance (scv floored at 1e-4,
/// mean at 1e-12), and the end of the quadrature range hi = max m(1 + 10 sqrt(scv) + 25 scv).
struct Branches {
    k: Vec<f64>,
    th: Vec<f64>,
    lg: Vec<f64>, // lgamma(k[j]), what GammaP recomputes per call
    hi: f64,
    finite: bool, // every k and th a finite number: every GammaP factor is a number in [0, 1]
}

fn gamma_branches(mu: &[f64], variance: &[f64]) -> Branches {
    let n = mu.len();
    let mut k = Vec::with_capacity(n);
    let mut th = Vec::with_capacity(n);
    let mut hi = 0.0f64;
    for j in 0..n {
        let m = gomath::max(mu[j], 1e-12);
        let scv = gomath::max(variance[j] / (m * m), 1e-4);
        let kj = 1.0 / scv;
        k.push(kj);
        th.push(m / kj);
        hi = gomath::max(hi, m * fma(25.0, scv, fma(10.0, scv.sqrt(), 1.0)));
    }
    let lg = k.iter().map(|&a| lgamma(a)).collect();
    let finite = k.iter().chain(&th).all(|x: &f64| x.is_finite());
    Branches {
        k,
        th,
        lg,
        hi,
        finite,
    }
}

impl Branches {
    /// GammaP(k[j], t/th[j]) with the branch's lgamma precomputed: the same result as Go's call.
    #[inline(always)]
    fn gamma_p(&self, j: usize, t: f64) -> f64 {
        let a = self.k[j];
        let x = t / self.th[j];
        if !(a > 0.0) || a == f64::INFINITY || x.is_nan() {
            return f64::NAN;
        }
        if x <= 0.0 {
            return 0.0;
        }
        if x == f64::INFINITY {
            return 1.0;
        }
        gamma_p_lg(a, x, self.lg[j])
    }

    /// maxMean: the largest (floored) branch mean.
    fn max_mean(&self) -> f64 {
        let mut c = 0.0;
        for j in 0..self.k.len() {
            c = gomath::max(c, self.k[j] * self.th[j]);
        }
        c
    }

    /// sumMeanCap: E[max] capped at the sum of the (floored) branch means.
    fn sum_mean_cap(&self, m: f64) -> f64 {
        let mut sum = 0.0;
        for j in 0..self.k.len() {
            sum = fma(self.k[j], self.th[j], sum);
        }
        gomath::min(m, sum)
    }
}

const MAX_EDGE_ZS: [f64; 26] = [
    -8.0, -6.0, -5.0, -4.0, -3.0, -2.5, -2.0, -1.5, -1.0, -0.5, 0.0, 0.5, 1.0, 1.5, 2.0, 2.5, 3.0,
    4.0, 5.0, 6.0, 8.0, 10.0, 13.0, 17.0, 22.0, 28.0,
];

/// maxEdges: the quadrature's panel edges on [0, hi] (every branch's mean plus multiples of its standard
/// deviation, a doubling sequence from a thousandth of the smallest mean, and the centre c).
fn max_edges(b: &Branches, c: f64) -> Vec<f64> {
    const ONE_PLUS: f64 = f64::from_bits(0x3ff0000000001198); // Go's constant 1+1e-12, rounded once
    let hi = b.hi;
    let mut pts = Vec::with_capacity(2 + 26 * b.k.len() + 64);
    pts.push(c);
    pts.push(hi);
    let mut lo = f64::INFINITY;
    for j in 0..b.k.len() {
        let m = b.k[j] * b.th[j];
        let sd = b.k[j].sqrt() * b.th[j];
        lo = gomath::min(lo, m);
        for &z in &MAX_EDGE_ZS {
            let p = fma(z, sd, m);
            if p > 0.0 && p < hi {
                pts.push(p);
            }
        }
    }
    let mut p = lo / 1000.0;
    while p < hi {
        pts.push(p);
        p *= 2.0;
    }
    // Go sorts with NaNs first; NaNs fail both tests below wherever they sit, so any ascending order of the
    // numbers gives the same edges.
    pts.sort_unstable_by(f64::total_cmp);
    let mut edges = Vec::with_capacity(pts.len() + 1);
    edges.push(0.0);
    for &p in &pts {
        if p > edges[edges.len() - 1] * ONE_PLUS && p <= hi {
            edges.push(p);
        }
    }
    edges
}

/// The quadrature points of maxMomentsAbout in Go's order: (t, wt) for every panel and Gauss node.
#[inline(always)]
fn node(edges: &[f64], e: usize, q: usize) -> (f64, f64) {
    let a = edges[e];
    let b = edges[e + 1];
    let u = (gl_x(q) + 1.0) * 0.5;
    if e == 0 {
        (b * u * u * u, gl_w(q) * 0.5 * 3.0 * b * u * u)
    } else {
        (fma(b - a, u, a), gl_w(q) * (b - a) * 0.5)
    }
}

/// Accumulates one point into maxMomentsAbout's four sums, as Go does (each update fused).
#[inline(always)]
fn accumulate(acc: &mut [f64; 4], c: f64, t: f64, wt: f64, f: f64) {
    // acc = [below, above, below2, above2]
    if t < c {
        acc[0] = fma(wt, f, acc[0]);
        acc[2] = fma(wt * 2.0 * (c - t), f, acc[2]);
    } else {
        let g = 1.0 - f;
        acc[1] = fma(wt, g, acc[1]);
        acc[3] = fma(wt * 2.0 * (t - c), g, acc[3]);
    }
}

/// maxMomentsAbout followed by maxMoments: the mean (no lower than c) and the variance of the variable whose
/// distribution function is `cdf`.
fn max_moments<F: FnMut(f64) -> f64>(c: f64, edges: &[f64], mut cdf: F) -> (f64, f64) {
    let mut acc = [0.0f64; 4];
    for e in 0..edges.len().saturating_sub(1) {
        for q in 0..10 {
            let (t, wt) = node(edges, e, q);
            let f = cdf(t);
            accumulate(&mut acc, c, t, wt, f);
        }
    }
    finish_moments(c, acc)
}

#[inline]
fn finish_moments(c: f64, acc: [f64; 4]) -> (f64, f64) {
    let d = acc[1] - acc[0];
    let m2 = acc[2] + acc[3];
    (c + gomath::max(d, 0.0), gomath::max(fma(-d, d, m2), 0.0))
}

/// P(max <= t) for independent gamma branches (gammaMaxCDF). With every shape and scale a finite number each
/// factor is a number in [0, 1], so a product that reaches exactly 0 stays 0 and the loop can stop.
#[inline]
fn indep_cdf(b: &Branches, t: f64) -> f64 {
    let mut cdf = 1.0;
    for j in 0..b.k.len() {
        cdf *= b.gamma_p(j, t);
        if cdf == 0.0 && b.finite {
            break;
        }
    }
    cdf
}

/// Scratch for [`corr_cdf`]: the branches' normal scores and their 65 node factors.
struct CorrScratch {
    a: Vec<f64>,
    f: Vec<f64>, // f[j*NZ + q]
}

impl CorrScratch {
    fn new(n: usize) -> CorrScratch {
        CorrScratch {
            a: vec![0.0; n],
            f: vec![0.0; n * NZ],
        }
    }
}

/// P(max <= t) under the Gaussian copula (gammaMaxCDFCorr's closure), Go's value bit for bit.
#[inline]
fn corr_cdf(b: &Branches, sr: f64, s1: f64, sc: &mut CorrScratch, t: f64) -> f64 {
    let n = b.k.len();
    let mut any_nan = false;
    for j in 0..n {
        let u = gomath::min(
            gomath::max(b.gamma_p(j, t), 1e-300),
            f64::from_bits(0x3fefffffffffffff),
        ); // 1-1e-16
        sc.a[j] = norm_quantile(u);
        any_nan |= sc.a[j].is_nan();
    }
    if any_nan {
        // Go's loop as written (NaN factors propagate)
        let mut g = 0.0;
        for q in 0..NZ {
            let mut p = 1.0;
            for &aj in sc.a.iter() {
                p *= norm_cdf(fma(-zs(q), sr, aj) / s1);
            }
            g = fma(zw(q), p, g);
        }
        return g;
    }
    // Go multiplies the factors node by node (q outer, branch inner); the factors themselves do not depend on
    // the order, so they are computed branch by branch along q first, then multiplied and summed in Go's order.
    // Along q a branch's erfc argument w = -x/sqrt2, x = (a - sr z)/s1, only grows (a monotone, correctly
    // rounded function of z), so erfc's range tests change direction a few times per branch and predict well,
    // and the evaluations, independent of each other, overlap. With every a[j] a number each factor is a number
    // in [0, 1], and two ranges are exact without erfc:
    //  * w < -6: Go's erfc returns exactly 2 (`sign && x > 6`, and |x| >= 28), the factor is exactly 1;
    //  * w >= 28: erfc returns exactly 0, and stays 0 for every later node, whose products are then exactly 0
    //    and add fma(zw, 0, g) = g: those nodes are left out.
    // Pairs of nodes go through the two-lane erfc (crate::simd: the same bits per lane).
    let mut qend = NZ;
    for j in 0..n {
        let aj = sc.a[j];
        let fj = &mut sc.f[j * NZ..(j + 1) * NZ];
        let mut q = 0;
        while q < qend {
            let w0 = -(fma(-zs(q), sr, aj) / s1) / SQRT_2;
            if w0 >= 28.0 {
                qend = q;
                break;
            }
            if w0 < -6.0 {
                fj[q] = 1.0;
                q += 1;
                continue;
            }
            if q + 3 < qend {
                let w3 = -(fma(-zs(q + 3), sr, aj) / s1) / SQRT_2;
                if w3 < 28.0 {
                    // w3 >= w2 >= w1 >= w0 >= -6
                    let w1 = -(fma(-zs(q + 1), sr, aj) / s1) / SQRT_2;
                    let w2 = -(fma(-zs(q + 2), sr, aj) / s1) / SQRT_2;
                    let e = crate::simd::erfc4([w0, w1, w2, w3]);
                    for i in 0..4 {
                        fj[q + i] = 0.5 * e[i];
                    }
                    q += 4;
                    continue;
                }
            }
            if q + 1 < qend {
                let w1 = -(fma(-zs(q + 1), sr, aj) / s1) / SQRT_2;
                if w1 < 28.0 {
                    // w1 >= w0 >= -6
                    let e = crate::simd::erfc2([w0, w1]);
                    fj[q] = 0.5 * e[0];
                    fj[q + 1] = 0.5 * e[1];
                    q += 2;
                    continue;
                }
            }
            fj[q] = 0.5 * erfc(w0);
            q += 1;
        }
    }
    let mut g = 0.0;
    for q in 0..qend {
        let mut p = 1.0;
        for j in 0..n {
            p *= sc.f[j * NZ + q];
        }
        g = fma(zw(q), p, g);
    }
    g
}

/// MaxMomentsGamma returns the mean and variance of the maximum of independent gamma variables with the given
/// means and variances. The mean is at least the largest branch mean and at most the sum of the means.
pub fn max_moments_gamma(mu: &[f64], variance: &[f64]) -> (f64, f64) {
    let b = gamma_branches(mu, variance);
    let c = b.max_mean();
    let edges = max_edges(&b, c);
    let (m, v) = max_moments(c, &edges, |t| indep_cdf(&b, t));
    (b.sum_mean_cap(m), v)
}

/// MaxMomentsGammaCorr is MaxMomentsGamma for branches whose latencies are positively correlated through a
/// Gaussian copula with one common correlation r (65-point trapezoid in the common factor on [-8, 8]).
/// r <= 1e-3 is taken as independent and r is capped at 0.98.
pub fn max_moments_gamma_corr(mu: &[f64], variance: &[f64], r: f64) -> (f64, f64) {
    if r <= 1e-3 {
        return max_moments_gamma(mu, variance);
    }
    let b = gamma_branches(mu, variance);
    let c = b.max_mean();
    let edges = max_edges(&b, c);
    let r = gomath::min(r, 0.98);
    let (sr, s1) = (r.sqrt(), (1.0 - r).sqrt());
    let mut sc = CorrScratch::new(b.k.len());
    let (m, v) = max_moments(c, &edges, |t| corr_cdf(&b, sr, s1, &mut sc, t));
    (b.sum_mean_cap(m), v)
}

/// [`max_moments_gamma_corr`] with the quadrature points evaluated in parallel on the current rayon pool (one
/// task per panel) and summed serially in Go's order: bit-identical to the serial function. On an idle 8-thread
/// pool it beat the serial quadrature at every fan-out measured (2 to 64 branches); inside a parallel batch the
/// cores are already busy with scenarios, so the model uses it only when asked
/// (`model::Exec::parallel_quadrature_min_branches`, off by default).
pub fn max_moments_gamma_corr_par(mu: &[f64], variance: &[f64], r: f64) -> (f64, f64) {
    let b = gamma_branches(mu, variance);
    let c = b.max_mean();
    let edges = max_edges(&b, c);
    let panels = edges.len().saturating_sub(1);
    // Go's `if r <= 1e-3` (independent branches) written as its negation, so that a NaN r takes the correlated
    // path and gives NaN, as the serial function does
    let corr = !(r <= 1e-3);
    let r = gomath::min(r, 0.98);
    let (sr, s1) = (r.sqrt(), (1.0 - r).sqrt());
    let f: Vec<[f64; 10]> = (0..panels)
        .into_par_iter()
        .map_init(
            || CorrScratch::new(b.k.len()),
            |sc, e| {
                let mut out = [0.0; 10];
                for (q, o) in out.iter_mut().enumerate() {
                    let (t, _) = node(&edges, e, q);
                    *o = if corr {
                        corr_cdf(&b, sr, s1, sc, t)
                    } else {
                        indep_cdf(&b, t)
                    };
                }
                out
            },
        )
        .collect();
    let mut acc = [0.0f64; 4];
    for (e, fe) in f.iter().enumerate() {
        for (q, &fq) in fe.iter().enumerate() {
            let (t, wt) = node(&edges, e, q);
            accumulate(&mut acc, c, t, wt, fq);
        }
    }
    let (m, v) = finish_moments(c, acc);
    (b.sum_mean_cap(m), v)
}

/// The largest number of branches EmaxExp sums exactly (inclusion-exclusion has 2^n terms).
pub const EMAX_EXACT_LIMIT: usize = 12;

/// EmaxExp returns the expected maximum of independent exponential variables with the given means: exact
/// (inclusion-exclusion) up to 12 branches, by quadrature above. Branches of mean 0 are left out.
pub fn emax_exp(means: &[f64]) -> f64 {
    let kept: Vec<f64>;
    let means = if means.contains(&0.0) {
        kept = means.iter().copied().filter(|&x| x != 0.0).collect();
        &kept[..]
    } else {
        means
    };
    match means.len() {
        0 => return 0.0,
        1 => return means[0],
        _ => {}
    }
    if means.len() <= EMAX_EXACT_LIMIT {
        emax_ie(means)
    } else {
        emax_numeric(means, 200001)
    }
}

fn emax_ie(means: &[f64]) -> f64 {
    let n = means.len(); // at most EMAX_EXACT_LIMIT
    let mut rates = [0.0; EMAX_EXACT_LIMIT];
    for (r, &x) in rates.iter_mut().zip(means) {
        *r = 1.0 / x;
    }
    let rates = &rates[..n];
    let mut tot = 0.0;
    for mask in 1usize..(1 << n) {
        let mut s = 0.0;
        let mut bits = 0;
        for (j, &rate) in rates.iter().enumerate() {
            if (mask >> j) & 1 == 1 {
                s += rate;
                bits += 1;
            }
        }
        if bits % 2 == 1 {
            tot += 1.0 / s;
        } else {
            tot -= 1.0 / s;
        }
    }
    tot
}

/// Integrates 1 - prod(1 - exp(-t/x)) on [0, 50 max(means)] by the trapezoid rule.
fn emax_numeric(means: &[f64], points: usize) -> f64 {
    let mut mx = 0.0;
    for &x in means {
        mx = gomath::max(mx, x);
    }
    let hi = 50.0 * mx;
    let step = hi / (points - 1) as f64;
    let mut prev = 1.0;
    let mut sum = 0.0;
    for i in 1..points {
        let t = step * i as f64;
        let mut cdf = 1.0;
        for &x in means {
            cdf *= 1.0 - exp(-t / x);
        }
        let cur = 1.0 - cdf;
        sum = fma((prev + cur) * 0.5, step, sum);
        prev = cur;
    }
    sum
}

/// One lock's worth of [`MaxMemo`]: input bits to (mean, variance).
type Shard = Mutex<HashMap<Vec<u64>, (f64, f64)>>;

/// A cache of MaxMomentsGammaCorr results keyed by the exact bits of (means, variances, correlation), shared by
/// the threads of a batch. The function is pure, so a hit returns the very bits a computation would: in a sweep
/// of patches, a patch outside a fan-out's subtree (and not upstream of it) leaves the fan-out's inputs
/// unchanged and its quadrature, most of a matched-maximum evaluation, is not redone.
pub struct MaxMemo {
    shards: Vec<Shard>,
    hits: AtomicU64,
    misses: AtomicU64,
}

impl Default for MaxMemo {
    fn default() -> Self {
        MaxMemo::new()
    }
}

impl MaxMemo {
    pub fn new() -> MaxMemo {
        MaxMemo {
            shards: (0..64).map(|_| Mutex::new(HashMap::new())).collect(),
            hits: AtomicU64::new(0),
            misses: AtomicU64::new(0),
        }
    }

    /// (hits, misses) so far.
    pub fn stats(&self) -> (u64, u64) {
        (
            self.hits.load(Ordering::Relaxed),
            self.misses.load(Ordering::Relaxed),
        )
    }

    /// The cached value for these inputs, or `compute()` stored under them.
    pub fn get_or_compute(
        &self,
        mu: &[f64],
        variance: &[f64],
        r: f64,
        compute: impl FnOnce() -> (f64, f64),
    ) -> (f64, f64) {
        let mut key = Vec::with_capacity(mu.len() + variance.len() + 1);
        key.extend(mu.iter().map(|x| x.to_bits()));
        key.extend(variance.iter().map(|x| x.to_bits()));
        key.push(r.to_bits());
        let mut h: u64 = 0xcbf29ce484222325; // FNV-1a over the words, to pick a shard
        for w in &key {
            h = (h ^ w).wrapping_mul(0x100000001b3);
        }
        let shard = &self.shards[(h >> 58) as usize];
        if let Some(&v) = shard.lock().unwrap().get(&key) {
            self.hits.fetch_add(1, Ordering::Relaxed);
            return v;
        }
        self.misses.fetch_add(1, Ordering::Relaxed);
        let v = compute(); // outside the lock; two threads may compute the same key, with the same result
        shard.lock().unwrap().insert(key, v);
        v
    }
}
