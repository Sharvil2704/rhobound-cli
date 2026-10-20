// SPDX-License-Identifier: Apache-2.0 AND BSD-3-Clause
//
// Lane-wise versions of the ports of Go's math.Exp and math.Erfc in gomath.rs (derived from Go's src/math/exp.go and
// src/math/erf.go, Copyright 2009-2017 The Go Authors, BSD-style license in rust/LICENSE-GO; Exp from FreeBSD's
// e_exp.c, Copyright (C) 2004 by Sun Microsystems, Inc., and Erfc from FreeBSD's s_erf.c, Copyright (C) 1993 by
// Sun Microsystems, Inc., under the notices quoted in gomath.rs).

//! Two-lane (NEON) versions of the ported `Exp` and `Erfc`, for the copula's node factors, the model's hot
//! loop. Each lane performs exactly the scalar function's operations: the same fused multiply-adds
//! (`vfmaq_f64`/`vfmsq_f64` are fused per lane), divisions, conversions and bit operations, with the scalar
//! code's branches turned into per-lane selects. So every lane's result is the scalar result bit for bit (the
//! tests check it on random pairs and the model parity tests run through it). On other architectures the
//! functions fall back to two scalar calls.
//!
//! The scalar functions are bound by the latency of their dependency chains (Horner steps, three divisions in
//! `Erfc`, one in `Exp`), not by throughput; two lanes per instruction let the out-of-order core keep twice the
//! work in flight.

use crate::gomath;

/// `[exp(x0), exp(x1)]`, each Go's `math.Exp` bit for bit.
#[inline(always)]
pub fn exp2(x: [f64; 2]) -> [f64; 2] {
    #[cfg(target_arch = "aarch64")]
    // SAFETY: NEON is part of the aarch64 baseline (every aarch64 target has it); the intrinsics only read and
    // write the fixed-size arrays passed by value
    unsafe {
        neon::exp2(x)
    }
    #[cfg(not(target_arch = "aarch64"))]
    [gomath::exp(x[0]), gomath::exp(x[1])]
}

/// `[erfc(x0), erfc(x1)]`, each Go's `math.Erfc` bit for bit. Lanes in the same range of |x| take the
/// two-lane path; mixed pairs and the rare ranges take two scalar calls. Always inlined, so that a loop around
/// it keeps the coefficients in registers instead of rebuilding them per call.
#[inline(always)]
pub fn erfc2(x: [f64; 2]) -> [f64; 2] {
    #[cfg(target_arch = "aarch64")]
    {
        let c0 = class(x[0]);
        if c0 != 0 && c0 == class(x[1]) {
            // SAFETY: NEON is part of the aarch64 baseline; fixed-size arrays only
            return unsafe { neon::erfc2(x, c0) };
        }
    }
    [gomath::erfc(x[0]), gomath::erfc(x[1])]
}

/// `erfc` of four values, each Go's `math.Erfc` bit for bit; four lanes in one range take two interleaved
/// two-lane evaluations, otherwise pairs.
#[inline(always)]
pub fn erfc4(x: [f64; 4]) -> [f64; 4] {
    #[cfg(target_arch = "aarch64")]
    {
        let c0 = class(x[0]);
        if c0 != 0 && c0 == class(x[3]) && c0 == class(x[1]) && c0 == class(x[2]) {
            // SAFETY: NEON is part of the aarch64 baseline; fixed-size arrays only
            return unsafe { neon::erfc4(x, c0) };
        }
    }
    let a = erfc2([x[0], x[1]]);
    let b = erfc2([x[2], x[3]]);
    [a[0], a[1], b[0], b[1]]
}

/// The range of |x| the scalar erfc takes a lane through, for the lanes the two-lane path handles:
/// 1: [2^-56, 0.25), 2: [0.25, 0.84375), 3: [0.84375, 1.25), 4: [1.25, 1/0.35), 5: [1/0.35, 28) unless
/// x < -6 (erfc 2). 0: anything else (NaN, infinities, |x| < 2^-56, |x| >= 28, x < -6 beyond 1/0.35).
#[allow(dead_code)]
#[inline(always)]
fn class(x: f64) -> u8 {
    const TINY: f64 = 1.0 / (1u64 << 56) as f64;
    const INV035: f64 = f64::from_bits(0x4006db6db6db6db7);
    let a = x.abs();
    if !(a >= TINY) {
        0 // NaN or tiny
    } else if a < 0.25 {
        1
    } else if a < 0.84375 {
        2
    } else if a < 1.25 {
        3
    } else if a < INV035 {
        4
    } else if a < 28.0 && !(x < 0.0 && a > 6.0) {
        5
    } else {
        0
    }
}

/// The two-lane kernels. Every function is `unsafe` only because NEON intrinsics are; NEON (Advanced SIMD) is
/// mandatory in the aarch64 baseline, so they are always available, and the loads and stores go through
/// `[f64; 2]` arrays owned by the caller (no pointer arithmetic beyond them).
#[cfg(target_arch = "aarch64")]
mod neon {
    use core::arch::aarch64::*;

    #[inline(always)]
    unsafe fn ld(x: [f64; 2]) -> float64x2_t {
        vld1q_f64(x.as_ptr())
    }
    #[inline(always)]
    unsafe fn st(v: float64x2_t) -> [f64; 2] {
        let mut out = [0.0; 2];
        vst1q_f64(out.as_mut_ptr(), v);
        out
    }
    #[inline(always)]
    unsafe fn splat(c: f64) -> float64x2_t {
        vdupq_n_f64(c)
    }
    /// a + b*c, one rounding (the scalar fma(b, c, a))
    #[inline(always)]
    unsafe fn fma(b: float64x2_t, c: float64x2_t, a: float64x2_t) -> float64x2_t {
        vfmaq_f64(a, b, c)
    }

    /// The scalar `gomath::exp`, lane by lane (exp_arm64.s).
    #[inline(always)]
    pub unsafe fn exp_v(x: float64x2_t) -> float64x2_t {
        const LN2HI: f64 = 6.93147180369123816490e-01;
        const LN2LO: f64 = 1.90821492927058770002e-10;
        const LOG2E: f64 = 1.44269504088896338700e+00;
        const OVERFLOW: f64 = 7.09782712893383973096e+02;
        const UNDERFLOW: f64 = -7.45133219101941108420e+02;
        const NEAR_ZERO: f64 = 1.0 / (1u64 << 28) as f64;
        const P1: f64 = 1.66666666666666657415e-01;
        const P2: f64 = -2.77777777770155933842e-03;
        const P3: f64 = 6.61375632143793436117e-05;
        const P4: f64 = -1.65339022054652515390e-06;
        const P5: f64 = 4.13813679705723846039e-08;
        let neg = vcltq_f64(x, splat(0.0));
        let kpos = fma(splat(LOG2E), x, splat(0.5));
        let kneg = fma(splat(LOG2E), x, splat(-0.5));
        let k = vcvtq_s64_f64(vbslq_f64(neg, kneg, kpos)); // truncation toward zero, as FCVTZSD
        let fk = vcvtq_f64_s64(k);
        let hi = vfmsq_f64(x, fk, splat(LN2HI)); // x - k*Ln2Hi
        let lo = vmulq_f64(fk, splat(LN2LO));
        let r = vsubq_f64(hi, lo);
        let t = vmulq_f64(r, r);
        let mut c = fma(t, splat(P5), splat(P4));
        c = fma(t, c, splat(P3));
        c = fma(t, c, splat(P2));
        c = fma(t, c, splat(P1));
        let c = vfmsq_f64(r, t, c); // r - t*c
        let q = vdivq_f64(vmulq_f64(r, c), vsubq_f64(splat(2.0), c));
        let y = vsubq_f64(splat(1.0), vsubq_f64(vsubq_f64(lo, q), hi));
        // Ldexp(y, k)
        let bits = vreinterpretq_u64_f64(y);
        let frac = vandq_u64(bits, vdupq_n_u64(0x000f_ffff_ffff_ffff));
        let e = vaddq_s64(vreinterpretq_s64_u64(vshrq_n_u64::<52>(bits)), k);
        let den = vcltq_s64(e, vdupq_n_s64(1));
        let e = vbslq_s64(den, vaddq_s64(e, vdupq_n_s64(52)), e);
        let m = vbslq_f64(
            den,
            splat(f64::from_bits(0x3cb0_0000_0000_0000)),
            splat(1.0),
        );
        let z = vreinterpretq_f64_u64(vorrq_u64(vshlq_n_u64::<52>(vreinterpretq_u64_s64(e)), frac));
        let mut res = vmulq_f64(z, m);
        // the scalar function's early returns, as selects (later tests win, so apply them in reverse order)
        let near = vcltq_f64(vabsq_f64(x), splat(NEAR_ZERO));
        res = vbslq_f64(near, vaddq_f64(splat(1.0), x), res);
        res = vbslq_f64(vcltq_f64(x, splat(UNDERFLOW)), splat(0.0), res);
        res = vbslq_f64(vcgtq_f64(x, splat(OVERFLOW)), splat(f64::INFINITY), res);
        let nan = vmvnq_u32(vreinterpretq_u32_u64(vceqq_f64(x, x)));
        vbslq_f64(vreinterpretq_u64_u32(nan), x, res)
    }

    #[inline(always)]
    pub unsafe fn exp2(x: [f64; 2]) -> [f64; 2] {
        st(exp_v(ld(x)))
    }

    use crate::gomath::{
        ERX, PA0, PA1, PA2, PA3, PA4, PA5, PA6, PP0, PP1, PP2, PP3, PP4, QA1, QA2, QA3, QA4, QA5,
        QA6, QQ1, QQ2, QQ3, QQ4, QQ5, RA0, RA1, RA2, RA3, RA4, RA5, RA6, RA7, RB0, RB1, RB2, RB3,
        RB4, RB5, RB6, SA1, SA2, SA3, SA4, SA5, SA6, SA7, SA8, SB1, SB2, SB3, SB4, SB5, SB6, SB7,
    };

    /// The scalar `gomath::erfc` for two lanes in the same range `class` (1..=5, see `class`).
    #[inline(always)]
    pub unsafe fn erfc2(xs: [f64; 2], class: u8) -> [f64; 2] {
        st(erfc_v(ld(xs), class))
    }

    /// Four lanes in one range: two independent vectors, whose chains the compiler interleaves.
    #[inline(always)]
    pub unsafe fn erfc4(xs: [f64; 4], class: u8) -> [f64; 4] {
        let a = erfc_v(vld1q_f64(xs.as_ptr()), class);
        let b = erfc_v(vld1q_f64(xs.as_ptr().add(2)), class);
        let mut out = [0.0; 4];
        vst1q_f64(out.as_mut_ptr(), a);
        vst1q_f64(out.as_mut_ptr().add(2), b);
        out
    }

    #[inline(always)]
    unsafe fn erfc_v(x0: float64x2_t, class: u8) -> float64x2_t {
        let sign = vcltq_f64(x0, splat(0.0));
        let x = vabsq_f64(x0);
        let one = splat(1.0);
        match class {
            1 | 2 => {
                let z = vmulq_f64(x, x);
                let r = fma(
                    z,
                    fma(
                        z,
                        fma(z, fma(z, splat(PP4), splat(PP3)), splat(PP2)),
                        splat(PP1),
                    ),
                    splat(PP0),
                );
                let s = fma(
                    z,
                    fma(
                        z,
                        fma(
                            z,
                            fma(z, fma(z, splat(QQ5), splat(QQ4)), splat(QQ3)),
                            splat(QQ2),
                        ),
                        splat(QQ1),
                    ),
                    one,
                );
                let y = vdivq_f64(r, s);
                let temp = if class == 1 {
                    fma(x, y, x)
                } else {
                    vaddq_f64(splat(0.5), fma(x, y, vsubq_f64(x, splat(0.5))))
                };
                vbslq_f64(sign, vaddq_f64(one, temp), vsubq_f64(one, temp))
            }
            3 => {
                let s = vsubq_f64(x, one);
                let p = fma(
                    s,
                    fma(
                        s,
                        fma(
                            s,
                            fma(
                                s,
                                fma(s, fma(s, splat(PA6), splat(PA5)), splat(PA4)),
                                splat(PA3),
                            ),
                            splat(PA2),
                        ),
                        splat(PA1),
                    ),
                    splat(PA0),
                );
                let q = fma(
                    s,
                    fma(
                        s,
                        fma(
                            s,
                            fma(
                                s,
                                fma(s, fma(s, splat(QA6), splat(QA5)), splat(QA4)),
                                splat(QA3),
                            ),
                            splat(QA2),
                        ),
                        splat(QA1),
                    ),
                    one,
                );
                let pq = vdivq_f64(p, q);
                vbslq_f64(
                    sign,
                    vaddq_f64(splat(1.0 + ERX), pq),
                    vsubq_f64(splat(1.0 - ERX), pq),
                )
            }
            _ => {
                let s = vdivq_f64(one, vmulq_f64(x, x));
                let (r, ss) = if class == 4 {
                    (
                        fma(
                            s,
                            fma(
                                s,
                                fma(
                                    s,
                                    fma(
                                        s,
                                        fma(
                                            s,
                                            fma(s, fma(s, splat(RA7), splat(RA6)), splat(RA5)),
                                            splat(RA4),
                                        ),
                                        splat(RA3),
                                    ),
                                    splat(RA2),
                                ),
                                splat(RA1),
                            ),
                            splat(RA0),
                        ),
                        fma(
                            s,
                            fma(
                                s,
                                fma(
                                    s,
                                    fma(
                                        s,
                                        fma(
                                            s,
                                            fma(
                                                s,
                                                fma(s, fma(s, splat(SA8), splat(SA7)), splat(SA6)),
                                                splat(SA5),
                                            ),
                                            splat(SA4),
                                        ),
                                        splat(SA3),
                                    ),
                                    splat(SA2),
                                ),
                                splat(SA1),
                            ),
                            one,
                        ),
                    )
                } else {
                    (
                        fma(
                            s,
                            fma(
                                s,
                                fma(
                                    s,
                                    fma(
                                        s,
                                        fma(s, fma(s, splat(RB6), splat(RB5)), splat(RB4)),
                                        splat(RB3),
                                    ),
                                    splat(RB2),
                                ),
                                splat(RB1),
                            ),
                            splat(RB0),
                        ),
                        fma(
                            s,
                            fma(
                                s,
                                fma(
                                    s,
                                    fma(
                                        s,
                                        fma(
                                            s,
                                            fma(s, fma(s, splat(SB7), splat(SB6)), splat(SB5)),
                                            splat(SB4),
                                        ),
                                        splat(SB3),
                                    ),
                                    splat(SB2),
                                ),
                                splat(SB1),
                            ),
                            one,
                        ),
                    )
                };
                let z = vreinterpretq_f64_u64(vandq_u64(
                    vreinterpretq_u64_f64(x),
                    vdupq_n_u64(0xffff_ffff_0000_0000),
                ));
                let a1 = vnegq_f64(fma(z, z, splat(0.5625))); // -z*z - 0.5625 (FNMADDD)
                let a2 = fma(vsubq_f64(z, x), vaddq_f64(z, x), vdivq_f64(r, ss));
                let rr = vmulq_f64(exp_v(a1), exp_v(a2));
                let rx = vdivq_f64(rr, x);
                vbslq_f64(sign, vsubq_f64(splat(2.0), rx), rx)
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn same(a: f64, b: f64) -> bool {
        a.to_bits() == b.to_bits() || (a.is_nan() && b.is_nan())
    }

    /// A small deterministic generator (SplitMix64) for test inputs.
    fn rng(state: &mut u64) -> f64 {
        *state = state.wrapping_add(0x9e3779b97f4a7c15);
        let mut z = *state;
        z = (z ^ (z >> 30)).wrapping_mul(0xbf58476d1ce4e5b9);
        z = (z ^ (z >> 27)).wrapping_mul(0x94d049bb133111eb);
        ((z ^ (z >> 31)) >> 11) as f64 / (1u64 << 53) as f64
    }

    #[test]
    fn exp2_lanes_are_scalar_exp() {
        let mut s = 1;
        let specials = [
            f64::NAN,
            f64::INFINITY,
            f64::NEG_INFINITY,
            0.0,
            -0.0,
            709.78,
            709.79,
            -745.13,
            -745.14,
            -708.5,
            -740.0,
            1e-9,
            -1e-9,
            3.7e-9,
        ];
        let mut xs: Vec<f64> = specials.to_vec();
        for i in 0..400_000 {
            let u = rng(&mut s);
            xs.push(match i % 4 {
                0 => -760.0 + 1480.0 * u,
                1 => (u - 0.5) * 1e-6,
                2 => -746.0 + 40.0 * u,
                _ => -40.0 + 80.0 * u,
            });
        }
        for w in xs.windows(2) {
            let got = exp2([w[0], w[1]]);
            assert!(
                same(got[0], gomath::exp(w[0])) && same(got[1], gomath::exp(w[1])),
                "exp2({w:?}) = {got:?}"
            );
        }
    }

    #[test]
    fn erfc2_lanes_are_scalar_erfc() {
        let mut s = 7;
        let mut xs: Vec<f64> = vec![
            f64::NAN,
            f64::INFINITY,
            f64::NEG_INFINITY,
            0.0,
            -0.0,
            0.25,
            0.84375,
            1.25,
            6.0,
            -6.0,
            28.0,
            -28.0,
            27.9,
            -27.9,
            2.857142857142857,
            f64::from_bits(0x4006db6db6db6db7),
            1e-17,
            -1e-17,
        ];
        for i in 0..400_000 {
            let u = rng(&mut s);
            xs.push(match i % 3 {
                0 => -30.0 + 60.0 * u,
                1 => -7.0 + 14.0 * u,
                _ => (u - 0.5) * 3.0,
            });
        }
        let mut sorted = xs.clone();
        sorted.retain(|x| !x.is_nan());
        sorted.sort_by(f64::total_cmp); // neighbours in one range: the two-lane path
        for v in [&xs, &sorted] {
            for w in v.windows(2) {
                let got = erfc2([w[0], w[1]]);
                assert!(
                    same(got[0], gomath::erfc(w[0])) && same(got[1], gomath::erfc(w[1])),
                    "erfc2({w:?}) = {got:?}"
                );
            }
            for w in v.windows(4) {
                let got = erfc4([w[0], w[1], w[2], w[3]]);
                for i in 0..4 {
                    assert!(same(got[i], gomath::erfc(w[i])), "erfc4({w:?}) = {got:?}");
                }
            }
        }
    }
}
