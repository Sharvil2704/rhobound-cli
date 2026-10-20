// SPDX-License-Identifier: Apache-2.0 AND BSD-3-Clause
//
// A port of Go's src/math/{exp.go,exp_arm64.s,log.go,lgamma.go,erf.go,erfinv.go}:
//   Copyright 2009-2017 The Go Authors. All rights reserved.
//   Use of this source code is governed by a BSD-style license that can be found in rust/LICENSE-GO (Go's LICENSE).
// log, lgamma and erfc come, through Go, from FreeBSD's msun (e_log.c, e_lgamma_r.c, s_erf.c), with this notice:
//   ====================================================
//   Copyright (C) 1993 by Sun Microsystems, Inc. All rights reserved.
//
//   Developed at SunPro, a Sun Microsystems, Inc. business.
//   Permission to use, copy, modify, and distribute this
//   software is freely granted, provided that this notice
//   is preserved.
//   ====================================================
// exp's method and constants (Ln2Hi, Ln2Lo, Log2e, Overflow, Underflow, P1-P5) come, through Go's exp.go and
// exp_arm64.s, from FreeBSD's msun e_exp.c, with this notice:
//   ====================================================
//   Copyright (C) 2004 by Sun Microsystems, Inc. All rights reserved.
//
//   Permission to use, copy, modify, and distribute this
//   software is freely granted, provided that this notice
//   is preserved.
//   ====================================================

//! Go's `math` functions as the Go 1.27 toolchain builds them for linux/arm64, bit for bit.
//!
//! The model's numerics are only as reproducible as the elementary functions under them, and Go's are its own
//! (FreeBSD/Cephes ports, `Exp` in arm64 assembly), not the platform libm's. Each function here is a line-by-line
//! port. Go's arm64 compiler fuses `a + x*y`, `a - x*y` and `x*y - a` into one fused multiply-add wherever the
//! product feeds the sum directly (SSA rules `FMADDD`/`FMSUBD`/`FNMSUBD`/`FNMADDD` in ARM64.rules); every [`fma`]
//! call below sits where `go tool objdump` of the oracle binary shows such an instruction, and only there (plain
//! `*` and `+` are never contracted by rustc). The arm64 `Exp` follows `exp_arm64.s` instruction for instruction.
//! The results are therefore Go-arm64's on every target (`mul_add` is a true FMA everywhere; on x86_64 without
//! the `fma` target feature it is a slower libm call).
//!
//! Checked against Go on 20,000 random inputs per function and on the oracle's `gomath.json` grid
//! (tests/parity_kernels.rs): every value identical.

/// `a*b + c` with one rounding: where Go's arm64 build emits a fused multiply-add.
#[inline(always)]
pub fn fma(a: f64, b: f64, c: f64) -> f64 {
    a.mul_add(b, c)
}

/// Go's `math.Max` (arm64 `FMAXD`): NaN if either argument is NaN; `max(+0, -0)` is +0.
#[inline(always)]
pub fn max(x: f64, y: f64) -> f64 {
    if x.is_nan() || y.is_nan() {
        return f64::NAN;
    }
    if x > y {
        x
    } else if y > x {
        y
    } else if x == 0.0 {
        // equal zeros: +0 unless both are -0
        if x.is_sign_positive() {
            x
        } else {
            y
        }
    } else {
        x
    }
}

/// Go's `math.Min` (arm64 `FMIND`): NaN if either argument is NaN; `min(+0, -0)` is -0.
#[inline(always)]
pub fn min(x: f64, y: f64) -> f64 {
    if x.is_nan() || y.is_nan() {
        return f64::NAN;
    }
    if x < y {
        x
    } else if y < x {
        y
    } else if x == 0.0 {
        if x.is_sign_negative() {
            x
        } else {
            y
        }
    } else {
        x
    }
}

/// `math.Exp` as `exp_arm64.s` computes it.
pub fn exp(x: f64) -> f64 {
    const LN2HI: f64 = 6.93147180369123816490e-01;
    const LN2LO: f64 = 1.90821492927058770002e-10;
    const LOG2E: f64 = 1.44269504088896338700e+00;
    const OVERFLOW: f64 = 7.09782712893383973096e+02;
    const UNDERFLOW: f64 = -7.45133219101941108420e+02;
    const NEAR_ZERO: f64 = 1.0 / (1u64 << 28) as f64; // 0x3e30000000000000
    const FRAC_MASK: u64 = 0x000f_ffff_ffff_ffff;
    const P1: f64 = 1.66666666666666657415e-01;
    const P2: f64 = -2.77777777770155933842e-03;
    const P3: f64 = 6.61375632143793436117e-05;
    const P4: f64 = -1.65339022054652515390e-06;
    const P5: f64 = 4.13813679705723846039e-08;
    if x.is_nan() {
        return x;
    }
    if x > OVERFLOW {
        return f64::INFINITY;
    }
    if x < UNDERFLOW {
        return 0.0;
    }
    if x.abs() < NEAR_ZERO {
        return 1.0 + x;
    }
    // k = int(Log2e*x -+ 0.5), both fused
    let kf = if x < 0.0 {
        fma(LOG2E, x, -0.5)
    } else {
        fma(LOG2E, x, 0.5)
    };
    let k = kf as i64; // FCVTZSD: truncation toward zero (|kf| < 1100, no saturation)
    let fk = k as f64;
    let hi = fma(-fk, LN2HI, x); // FMSUBD: x - k*Ln2Hi
    let lo = fk * LN2LO;
    let r = hi - lo;
    let t = r * r;
    let mut c = fma(t, P5, P4);
    c = fma(t, c, P3);
    c = fma(t, c, P2);
    c = fma(t, c, P1);
    let c = fma(-t, c, r); // FMSUBD: r - t*(...)
    let y = 1.0 - ((lo - (r * c) / (2.0 - c)) - hi);
    // inline Ldexp(y, k)
    let bits = y.to_bits();
    let frac = bits & FRAC_MASK;
    let mut e = (bits >> 52) as i64 + k;
    let mut m = 1.0;
    if e < 1 {
        e += 52;
        m = f64::from_bits(0x3cb0_0000_0000_0000); // 2**-52
    }
    let z = f64::from_bits(((e as u64) << 52) | frac);
    z * m
}

/// `math.Frexp` (pure Go on arm64).
pub fn frexp(f: f64) -> (f64, i64) {
    if f == 0.0 || f.is_infinite() || f.is_nan() {
        return (f, 0);
    }
    let (f, mut e) = if f.abs() < 2.2250738585072014e-308 {
        (f * (1u64 << 52) as f64, -52i64)
    } else {
        (f, 0)
    };
    let mut x = f.to_bits();
    e += ((x >> 52) & 0x7ff) as i64 - 1023 + 1;
    x &= !(0x7ffu64 << 52);
    x |= 1022u64 << 52;
    (f64::from_bits(x), e)
}

/// `math.Log` (log.go; pure Go on arm64).
pub fn log(x: f64) -> f64 {
    const LN2HI: f64 = 6.93147180369123816490e-01;
    const LN2LO: f64 = 1.90821492927058770002e-10;
    const L1: f64 = 6.666666666666735130e-01;
    const L2: f64 = 3.999999999940941908e-01;
    const L3: f64 = 2.857142874366239149e-01;
    const L4: f64 = 2.222219843214978396e-01;
    const L5: f64 = 1.818357216161805012e-01;
    const L6: f64 = 1.531383769920937332e-01;
    const L7: f64 = 1.479819860511658591e-01;
    if x.is_nan() || x == f64::INFINITY {
        return x;
    }
    if x < 0.0 {
        return f64::NAN;
    }
    if x == 0.0 {
        return f64::NEG_INFINITY;
    }
    let (mut f1, mut ki) = frexp(x);
    if f1 < std::f64::consts::SQRT_2 / 2.0 {
        f1 *= 2.0;
        ki -= 1;
    }
    let f = f1 - 1.0;
    let k = ki as f64;
    let s = f / (2.0 + f);
    let s2 = s * s;
    let s4 = s2 * s2;
    let inner1 = fma(s4, fma(s4, fma(s4, L7, L5), L3), L1); // L1 + s4*(L3 + s4*(L5 + s4*L7))
    let t2 = s4 * fma(s4, fma(s4, L6, L4), L2);
    let r = fma(s2, inner1, t2); // t1 + t2, t1 = s2*inner1 fused
    let half_f = 0.5 * f;
    let hfsq_plus_r = fma(half_f, f, r); // hfsq + R, hfsq = 0.5*f*f fused
    let inner = fma(s, hfsq_plus_r, k * LN2LO); // s*(hfsq+R) + k*Ln2Lo, the first product fused
    let a = fma(half_f, f, -inner); // hfsq - (...)
    let b = a - f;
    fma(k, LN2HI, -b) // k*Ln2Hi - (...)
}

const LGAM_A: [f64; 12] = [
    7.72156649015328655494e-02,
    3.22467033424113591611e-01,
    6.73523010531292681824e-02,
    2.05808084325167332806e-02,
    7.38555086081402883957e-03,
    2.89051383673415629091e-03,
    1.19270763183362067845e-03,
    5.10069792153511336608e-04,
    2.20862790713908385557e-04,
    1.08011567247583939954e-04,
    2.52144565451257326939e-05,
    4.48640949618915160150e-05,
];
const LGAM_R: [f64; 7] = [
    1.0,
    1.39200533467621045958e+00,
    7.21935547567138069525e-01,
    1.71933865632803078993e-01,
    1.86459191715652901344e-02,
    7.77942496381893596434e-04,
    7.32668430744625636189e-06,
];
const LGAM_S: [f64; 7] = [
    -7.72156649015328655494e-02,
    2.14982415960608852501e-01,
    3.25778796408930981787e-01,
    1.46350472652464452805e-01,
    2.66422703033638609560e-02,
    1.84028451407337715652e-03,
    3.19475326584100867617e-05,
];
const LGAM_T: [f64; 15] = [
    4.83836122723810047042e-01,
    -1.47587722994593911752e-01,
    6.46249402391333854778e-02,
    -3.27885410759859649565e-02,
    1.79706750811820387126e-02,
    -1.03142241298341437450e-02,
    6.10053870246291332635e-03,
    -3.68452016781138256760e-03,
    2.25964780900612472250e-03,
    -1.40346469989232843813e-03,
    8.81081882437654011382e-04,
    -5.38595305356740546715e-04,
    3.15632070903625950361e-04,
    -3.12754168375120860518e-04,
    3.35529192635519073543e-04,
];
const LGAM_U: [f64; 6] = [
    -7.72156649015328655494e-02,
    6.32827064025093366517e-01,
    1.45492250137234768737e+00,
    9.77717527963372745603e-01,
    2.28963728064692451092e-01,
    1.33810918536787660377e-02,
];
const LGAM_V: [f64; 6] = [
    1.0,
    2.45597793713041134822e+00,
    2.12848976379893395361e+00,
    7.69285150456672783825e-01,
    1.04222645593369134254e-01,
    3.21709242282423911810e-03,
];
const LGAM_W: [f64; 7] = [
    4.18938533204672725052e-01,
    8.33333333333329678849e-02,
    -2.77777777728775536470e-03,
    7.93650558643019558500e-04,
    -5.95187557450339963135e-04,
    8.36339918996282139126e-04,
    -1.63092934096575273989e-03,
];

/// `math.Lgamma(x)` (the log of |Gamma(x)|, sign dropped) for x >= 0, +Inf and NaN, as Go computes it. Negative
/// arguments (which need Go's `sinPi`) are not ported: the model's shapes are positive. They return NaN.
pub fn lgamma(x: f64) -> f64 {
    const YMIN: f64 = 1.461632144968362245;
    const TWO58: f64 = (1u64 << 58) as f64;
    const TINY: f64 = 1.0 / ((1u128 << 70) as f64);
    const TC: f64 = 1.46163214496836224576e+00;
    const TF: f64 = -1.21486290535849611461e-01;
    const TT: f64 = -3.63867699703950536541e-18;
    // Go's constant expressions, rounded once from their exact values (checked against Go: go_consts.txt)
    const YMIN_M1_P027: f64 = f64::from_bits(0x3fe76987d0eaed22); // Ymin - 1 + 0.27
    const YMIN_M1_M027: f64 = f64::from_bits(0x3fc88766f1c02f69); // Ymin - 1 - 0.27
    const YMIN_P027: f64 = f64::from_bits(0x3ffbb4c3e8757691); // Ymin + 0.27
    const YMIN_M027: f64 = f64::from_bits(0x3ff310ecde3805ed); // Ymin - 0.27
    const TC_M1: f64 = f64::from_bits(0x3fdd8b618d5af8fc); // Tc - 1
    let _ = YMIN;
    if x.is_nan() || x.is_infinite() {
        return x;
    }
    if x == 0.0 {
        return f64::INFINITY;
    }
    if x < 0.0 {
        return f64::NAN; // not ported (see above)
    }
    if x < TINY {
        return -log(x);
    }
    let a = &LGAM_A;
    let t = &LGAM_T;
    let u = &LGAM_U;
    let v = &LGAM_V;
    let mut lg: f64;
    if x == 1.0 || x == 2.0 {
        return 0.0;
    } else if x < 2.0 {
        let y: f64;
        let i: u8;
        if x <= 0.9 {
            lg = -log(x);
            if x >= YMIN_M1_P027 {
                y = 1.0 - x;
                i = 0;
            } else if x >= YMIN_M1_M027 {
                y = x - TC_M1;
                i = 1;
            } else {
                y = x;
                i = 2;
            }
        } else {
            lg = 0.0;
            if x >= YMIN_P027 {
                y = 2.0 - x;
                i = 0;
            } else if x >= YMIN_M027 {
                y = x - TC;
                i = 1;
            } else {
                y = x - 1.0;
                i = 2;
            }
        }
        match i {
            0 => {
                let z = y * y;
                let p1 = fma(
                    z,
                    fma(z, fma(z, fma(z, fma(z, a[10], a[8]), a[6]), a[4]), a[2]),
                    a[0],
                );
                let in2 = fma(
                    z,
                    fma(z, fma(z, fma(z, fma(z, a[11], a[9]), a[7]), a[5]), a[3]),
                    a[1],
                );
                let p = fma(z, in2, y * p1); // y*p1 + p2, p2 = z*in2 fused
                lg += fma(-y, 0.5, p); // p - 0.5*y
            }
            1 => {
                let z = y * y;
                let w = z * y;
                let p1 = fma(w, fma(w, fma(w, fma(w, t[12], t[9]), t[6]), t[3]), t[0]);
                let p2 = fma(w, fma(w, fma(w, fma(w, t[13], t[10]), t[7]), t[4]), t[1]);
                let p3 = fma(w, fma(w, fma(w, fma(w, t[14], t[11]), t[8]), t[5]), t[2]);
                let q = fma(y, p3, p2); // p2 + y*p3
                let inner = fma(-w, q, TT); // Tt - w*(...)
                let p = fma(z, p1, -inner); // z*p1 - (...)
                lg += TF + p;
            }
            _ => {
                let p1 = y * fma(
                    y,
                    fma(y, fma(y, fma(y, fma(y, u[5], u[4]), u[3]), u[2]), u[1]),
                    u[0],
                );
                let p2 = fma(
                    y,
                    fma(y, fma(y, fma(y, fma(y, v[5], v[4]), v[3]), v[2]), v[1]),
                    1.0,
                );
                lg += fma(-0.5, y, p1 / p2); // -0.5*y + p1/p2
            }
        }
    } else if x < 8.0 {
        let s = &LGAM_S;
        let r = &LGAM_R;
        let i = x as i64;
        let y = x - i as f64;
        let p = y * fma(
            y,
            fma(
                y,
                fma(y, fma(y, fma(y, fma(y, s[6], s[5]), s[4]), s[3]), s[2]),
                s[1],
            ),
            s[0],
        );
        let q = fma(
            y,
            fma(
                y,
                fma(y, fma(y, fma(y, fma(y, r[6], r[5]), r[4]), r[3]), r[2]),
                r[1],
            ),
            1.0,
        );
        lg = fma(0.5, y, p / q); // 0.5*y + p/q
        let mut z = 1.0f64;
        if i >= 3 {
            if i >= 7 {
                z *= y + 6.0;
            }
            if i >= 6 {
                z *= y + 5.0;
            }
            if i >= 5 {
                z *= y + 4.0;
            }
            if i >= 4 {
                z *= y + 3.0;
            }
            z *= y + 2.0;
            lg += log(z);
        }
    } else if x < TWO58 {
        let w_ = &LGAM_W;
        let t = log(x);
        let z = 1.0 / x;
        let y = z * z;
        let w = fma(
            z,
            fma(
                y,
                fma(y, fma(y, fma(y, fma(y, w_[6], w_[5]), w_[4]), w_[3]), w_[2]),
                w_[1],
            ),
            w_[0],
        );
        lg = fma(x - 0.5, t - 1.0, w); // (x-0.5)*(t-1) + w
    } else {
        lg = x * (log(x) - 1.0);
    }
    lg
}

pub(crate) const ERX: f64 = 8.45062911510467529297e-01;
pub(crate) const PP0: f64 = 1.28379167095512558561e-01;
pub(crate) const PP1: f64 = -3.25042107247001499370e-01;
pub(crate) const PP2: f64 = -2.84817495755985104766e-02;
pub(crate) const PP3: f64 = -5.77027029648944159157e-03;
pub(crate) const PP4: f64 = -2.37630166566501626084e-05;
pub(crate) const QQ1: f64 = 3.97917223959155352819e-01;
pub(crate) const QQ2: f64 = 6.50222499887672944485e-02;
pub(crate) const QQ3: f64 = 5.08130628187576562776e-03;
pub(crate) const QQ4: f64 = 1.32494738004321644526e-04;
pub(crate) const QQ5: f64 = -3.96022827877536812320e-06;
pub(crate) const PA0: f64 = -2.36211856075265944077e-03;
pub(crate) const PA1: f64 = 4.14856118683748331666e-01;
pub(crate) const PA2: f64 = -3.72207876035701323847e-01;
pub(crate) const PA3: f64 = 3.18346619901161753674e-01;
pub(crate) const PA4: f64 = -1.10894694282396677476e-01;
pub(crate) const PA5: f64 = 3.54783043256182359371e-02;
pub(crate) const PA6: f64 = -2.16637559486879084300e-03;
pub(crate) const QA1: f64 = 1.06420880400844228286e-01;
pub(crate) const QA2: f64 = 5.40397917702171048937e-01;
pub(crate) const QA3: f64 = 7.18286544141962662868e-02;
pub(crate) const QA4: f64 = 1.26171219808761642112e-01;
pub(crate) const QA5: f64 = 1.36370839120290507362e-02;
pub(crate) const QA6: f64 = 1.19844998467991074170e-02;
pub(crate) const RA0: f64 = -9.86494403484714822705e-03;
pub(crate) const RA1: f64 = -6.93858572707181764372e-01;
pub(crate) const RA2: f64 = -1.05586262253232909814e+01;
pub(crate) const RA3: f64 = -6.23753324503260060396e+01;
pub(crate) const RA4: f64 = -1.62396669462573470355e+02;
pub(crate) const RA5: f64 = -1.84605092906711035994e+02;
pub(crate) const RA6: f64 = -8.12874355063065934246e+01;
pub(crate) const RA7: f64 = -9.81432934416914548592e+00;
pub(crate) const SA1: f64 = 1.96512716674392571292e+01;
pub(crate) const SA2: f64 = 1.37657754143519042600e+02;
pub(crate) const SA3: f64 = 4.34565877475229228821e+02;
pub(crate) const SA4: f64 = 6.45387271733267880336e+02;
pub(crate) const SA5: f64 = 4.29008140027567833386e+02;
pub(crate) const SA6: f64 = 1.08635005541779435134e+02;
pub(crate) const SA7: f64 = 6.57024977031928170135e+00;
pub(crate) const SA8: f64 = -6.04244152148580987438e-02;
pub(crate) const RB0: f64 = -9.86494292470009928597e-03;
pub(crate) const RB1: f64 = -7.99283237680523006574e-01;
pub(crate) const RB2: f64 = -1.77579549177547519889e+01;
pub(crate) const RB3: f64 = -1.60636384855821916062e+02;
pub(crate) const RB4: f64 = -6.37566443368389627722e+02;
pub(crate) const RB5: f64 = -1.02509513161107724954e+03;
pub(crate) const RB6: f64 = -4.83519191608651397019e+02;
pub(crate) const SB1: f64 = 3.03380607434824582924e+01;
pub(crate) const SB2: f64 = 3.25792512996573918826e+02;
pub(crate) const SB3: f64 = 1.53672958608443695994e+03;
pub(crate) const SB4: f64 = 3.19985821950859553908e+03;
pub(crate) const SB5: f64 = 2.55305040643316442583e+03;
pub(crate) const SB6: f64 = 4.74528541206955367215e+02;
pub(crate) const SB7: f64 = -2.24409524465858183362e+01;

/// `math.Erfc` (erf.go; pure Go on arm64).
pub fn erfc(x: f64) -> f64 {
    const TINY: f64 = 1.0 / (1u64 << 56) as f64;
    const INV035: f64 = f64::from_bits(0x4006db6db6db6db7); // Go's constant 1/0.35, rounded once
    if x.is_nan() {
        return f64::NAN;
    }
    if x == f64::INFINITY {
        return 0.0;
    }
    if x == f64::NEG_INFINITY {
        return 2.0;
    }
    let mut x = x;
    let sign = x < 0.0;
    if sign {
        x = -x;
    }
    if x < 0.84375 {
        let temp = if x < TINY {
            x
        } else {
            let z = x * x;
            let r = fma(z, fma(z, fma(z, fma(z, PP4, PP3), PP2), PP1), PP0);
            let s = fma(
                z,
                fma(z, fma(z, fma(z, fma(z, QQ5, QQ4), QQ3), QQ2), QQ1),
                1.0,
            );
            let y = r / s;
            if x < 0.25 {
                fma(x, y, x) // x + x*y
            } else {
                0.5 + fma(x, y, x - 0.5) // 0.5 + (x*y + (x - 0.5))
            }
        };
        return if sign { 1.0 + temp } else { 1.0 - temp };
    }
    if x < 1.25 {
        let s = x - 1.0;
        let p = fma(
            s,
            fma(
                s,
                fma(s, fma(s, fma(s, fma(s, PA6, PA5), PA4), PA3), PA2),
                PA1,
            ),
            PA0,
        );
        let q = fma(
            s,
            fma(
                s,
                fma(s, fma(s, fma(s, fma(s, QA6, QA5), QA4), QA3), QA2),
                QA1,
            ),
            1.0,
        );
        // 1 + erx and 1 - erx are exact in float64 (erx has 24 significant bits), as Go's constants are
        return if sign {
            (1.0 + ERX) + p / q
        } else {
            (1.0 - ERX) - p / q
        };
    }
    if x < 28.0 {
        let s = 1.0 / (x * x);
        let (r, ss);
        if x < INV035 {
            r = fma(
                s,
                fma(
                    s,
                    fma(
                        s,
                        fma(s, fma(s, fma(s, fma(s, RA7, RA6), RA5), RA4), RA3),
                        RA2,
                    ),
                    RA1,
                ),
                RA0,
            );
            ss = fma(
                s,
                fma(
                    s,
                    fma(
                        s,
                        fma(
                            s,
                            fma(s, fma(s, fma(s, fma(s, SA8, SA7), SA6), SA5), SA4),
                            SA3,
                        ),
                        SA2,
                    ),
                    SA1,
                ),
                1.0,
            );
        } else {
            if sign && x > 6.0 {
                return 2.0;
            }
            r = fma(
                s,
                fma(
                    s,
                    fma(s, fma(s, fma(s, fma(s, RB6, RB5), RB4), RB3), RB2),
                    RB1,
                ),
                RB0,
            );
            ss = fma(
                s,
                fma(
                    s,
                    fma(
                        s,
                        fma(s, fma(s, fma(s, fma(s, SB7, SB6), SB5), SB4), SB3),
                        SB2,
                    ),
                    SB1,
                ),
                1.0,
            );
        }
        let z = f64::from_bits(x.to_bits() & 0xffff_ffff_0000_0000);
        let e1 = exp(-fma(z, z, 0.5625)); // -z*z - 0.5625, FNMADDD
        let e2 = exp(fma(z - x, z + x, r / ss)); // (z-x)*(z+x) + R/S
        let rr = e1 * e2;
        return if sign { 2.0 - rr / x } else { rr / x };
    }
    if sign {
        2.0
    } else {
        0.0
    }
}

const EA: [f64; 8] = [
    1.1975323115670912564578e0,
    4.7072688112383978012285e1,
    6.9706266534389598238465e2,
    4.8548868893843886794648e3,
    1.6235862515167575384252e4,
    2.3782041382114385731252e4,
    1.1819493347062294404278e4,
    8.8709406962545514830200e2,
];
const EB: [f64; 8] = [
    1.0000000000000000000e0,
    4.2313330701600911252e1,
    6.8718700749205790830e2,
    5.3941960214247511077e3,
    2.1213794301586595867e4,
    3.9307895800092710610e4,
    2.8729085735721942674e4,
    5.2264952788528545610e3,
];
const EC: [f64; 8] = [
    1.42343711074968357734e0,
    4.63033784615654529590e0,
    5.76949722146069140550e0,
    3.64784832476320460504e0,
    1.27045825245236838258e0,
    2.41780725177450611770e-1,
    2.27238449892691845833e-2,
    7.74545014278341407640e-4,
];
const ED: [f64; 8] = [
    1.4142135623730950488016887e0,
    2.9036514445419946173133295e0,
    2.3707661626024532365971225e0,
    9.7547832001787427186894837e-1,
    2.0945065210512749128288442e-1,
    2.1494160384252876777097297e-2,
    7.7441459065157709165577218e-4,
    1.4859850019840355905497876e-9,
];
const EE: [f64; 8] = [
    6.65790464350110377720e0,
    5.46378491116411436990e0,
    1.78482653991729133580e0,
    2.96560571828504891230e-1,
    2.65321895265761230930e-2,
    1.24266094738807843860e-3,
    2.71155556874348757815e-5,
    2.01033439929228813265e-7,
];
const EF: [f64; 8] = [
    1.414213562373095048801689e0,
    8.482908416595164588112026e-1,
    1.936480946950659106176712e-1,
    2.103693768272068968719679e-2,
    1.112800997078859844711555e-3,
    2.611088405080593625138020e-5,
    2.010321207683943062279931e-7,
    2.891024605872965461538222e-15,
];

/// Horner as Go writes it, `((((((c7*r+c6)*r+c5)*r+c4)*r+c3)*r+c2)*r+c1)*r + c0`, every step fused.
#[inline(always)]
fn horner7(c: &[f64; 8], r: f64) -> f64 {
    let mut z = fma(c[7], r, c[6]);
    z = fma(z, r, c[5]);
    z = fma(z, r, c[4]);
    z = fma(z, r, c[3]);
    z = fma(z, r, c[2]);
    z = fma(z, r, c[1]);
    fma(z, r, c[0])
}

/// `math.Erfinv` (erfinv.go).
pub fn erfinv(x: f64) -> f64 {
    if x.is_nan() || x <= -1.0 || x >= 1.0 {
        if x == -1.0 {
            return f64::NEG_INFINITY;
        }
        if x == 1.0 {
            return f64::INFINITY;
        }
        return f64::NAN;
    }
    let mut x = x;
    let sign = x < 0.0;
    if sign {
        x = -x;
    }
    let ans = if x <= 0.85 {
        let r = fma(-(0.25 * x), x, 0.180625); // 0.180625 - 0.25*x*x
        let z1 = horner7(&EA, r);
        let z2 = horner7(&EB, r);
        (x * z1) / z2
    } else {
        let mut r = (std::f64::consts::LN_2 - log(1.0 - x)).sqrt();
        let (z1, z2);
        if r <= 5.0 {
            r -= 1.6;
            z1 = horner7(&EC, r);
            z2 = horner7(&ED, r);
        } else {
            r -= 5.0;
            z1 = horner7(&EE, r);
            z2 = horner7(&EF, r);
        }
        z1 / z2
    };
    if sign {
        -ans
    } else {
        ans
    }
}
