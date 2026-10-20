// SPDX-License-Identifier: Apache-2.0

//! The correlated gamma maximum with a NaN correlation: Go's MaxMomentsGammaCorr takes the correlated path
//! (`if r <= 1e-3` is false for NaN) and gives NaN, or what its quadrature makes of the inputs. The parallel
//! quadrature must agree with the serial function (and so with Go) on these cases too. The Go results are from
//! a kernel run made for the comparison (go1.27.2, linux/arm64): NaN where Go printed a NaN, else the value.
//! Serial and parallel must agree bit for bit everywhere; Go's values bit for bit on aarch64, elsewhere within
//! common::TOLERANCE.

mod common;

use rbfast_math::mathx::{max_moments_gamma_corr, max_moments_gamma_corr_par};

fn bits_same(a: f64, b: f64) -> bool {
    a.to_bits() == b.to_bits() || (a.is_nan() && b.is_nan())
}

#[test]
fn nan_correlation_as_go() {
    let n = f64::NAN;
    let inf = f64::INFINITY;
    // (mu, var, Go's mean, Go's variance)
    let cases: Vec<(Vec<f64>, Vec<f64>, f64, f64)> = vec![
        (vec![1.0, 1.0], vec![1e-12, 1e12], n, n),
        (vec![1.0, 1000.0], vec![1e-10, 1e12], n, n),
        (vec![5.0, 5.0], vec![0.0, 0.0], n, n),
        (vec![1e-15, 2.0], vec![1e-30, 4.0], n, n),
        (vec![0.0, 0.0], vec![0.0, 0.0], n, n),
        (vec![1.0, 2.0, 3.0], vec![1e-8, 1e8, 1.0], n, n),
        (vec![1.0], vec![1.0], n, n),
        (vec![], vec![], 0.0, 0.0),
        (vec![1.0, 1e6], vec![1e18, 1e-6], n, n),
        (vec![2.0, 2.0], vec![4e-4, 4e-4], n, n),
        (vec![1.0, 2.0], vec![n, 1.0], n, 0.0),
        (vec![n, 2.0], vec![1.0, 1.0], n, 0.0),
        (vec![1.0, 2.0], vec![inf, 1.0], n, n),
        (vec![1.0, inf], vec![1.0, 1.0], n, n),
        (vec![1.0, 2.0], vec![-1.0, 1.0], n, n),
        (vec![-1.0, 2.0], vec![1.0, 1.0], n, n),
        (vec![1e-300, 1e-300], vec![1e-300, 1e-300], n, n),
        (vec![1e300, 1e300], vec![1e300, 1e300], n, n),
        (vec![3.0; 16], vec![9.0; 16], n, n),
        (vec![1.0, 1e-9], vec![1e9, 1e-27], n, n),
        (vec![1e5, 1e5], vec![1e-8, 1e-8], n, n),
    ];
    for (mu, va, gm, gv) in &cases {
        let (m, v) = max_moments_gamma_corr(mu, va, n);
        let (mp, vp) = max_moments_gamma_corr_par(mu, va, n);
        assert!(
            bits_same(m, mp) && bits_same(v, vp),
            "{mu:?} {va:?}: serial ({m}, {v}) parallel ({mp}, {vp})"
        );
        assert!(
            common::same(m, *gm) && common::same(v, *gv),
            "{mu:?} {va:?}: ({m}, {v}), Go ({gm}, {gv})"
        );
    }
}
