// SPDX-License-Identifier: Apache-2.0

//! Bit-for-bit parity of the kernels with Go (linux/arm64, Go 1.27.2) on random inputs, written by a Go program
//! made for the comparison (not published): one line per case, `fn in... out`, float64 bit patterns in hex.
//! testdata/go_kernels.txt has 2,000 cases per kernel (seed 7); set RBFAST_GO_KERNELS to a larger file of the same
//! form to check more (a 20,000-per-kernel set, seed 1, was checked during development). Bit for bit on aarch64;
//! elsewhere within common::TOLERANCE (see tests/common).

mod common;

use rbfast_math::{gomath, mathx, model};
use std::collections::BTreeMap;

fn h(s: &str) -> f64 {
    f64::from_bits(u64::from_str_radix(s, 16).expect("hex"))
}

fn same(a: f64, b: f64) -> bool {
    common::same(a, b)
}

fn check_file(path: &str) {
    let text = std::fs::read_to_string(path).unwrap_or_else(|e| panic!("{path}: {e}"));
    let mut counts: BTreeMap<String, (usize, usize)> = BTreeMap::new();
    let mut first_bad: Vec<String> = Vec::new();
    for line in text.lines() {
        let mut it = line.split(' ');
        let f = it.next().unwrap().to_string();
        let v: Vec<f64> = it.map(h).collect();
        let (got, want): (Vec<f64>, Vec<f64>) = match f.as_str() {
            "exp" => (vec![gomath::exp(v[0])], vec![v[1]]),
            "log" => (vec![gomath::log(v[0])], vec![v[1]]),
            "lgamma" => (vec![gomath::lgamma(v[0])], vec![v[1]]),
            "erfc" => (vec![gomath::erfc(v[0])], vec![v[1]]),
            "erfinv" => (vec![gomath::erfinv(v[0])], vec![v[1]]),
            "gammap" => (vec![mathx::gamma_p(v[0], v[1])], vec![v[2]]),
            "normcdf" => (vec![mathx::norm_cdf(v[0])], vec![v[1]]),
            "normquantile" => (vec![mathx::norm_quantile(v[0])], vec![v[1]]),
            "erlangc" => (vec![model::erlang_c(v[0] as i64, v[1])], vec![v[2]]),
            "residence" => (
                vec![model::residence(v[0], v[1], v[2] as i64, v[3], v[4])],
                vec![v[5]],
            ),
            "emaxexp" => {
                let k = v[0] as usize;
                (vec![mathx::emax_exp(&v[1..1 + k])], vec![v[1 + k]])
            }
            "maxgamma" => {
                let k = v[0] as usize;
                let r = v[1];
                let (m, var) = mathx::max_moments_gamma_corr(&v[2..2 + k], &v[2 + k..2 + 2 * k], r);
                let (mp, vp) =
                    mathx::max_moments_gamma_corr_par(&v[2..2 + k], &v[2 + k..2 + 2 * k], r);
                (
                    vec![m, var, mp, vp],
                    vec![v[2 + 2 * k], v[3 + 2 * k], v[2 + 2 * k], v[3 + 2 * k]],
                )
            }
            other => panic!("unknown kernel {other}"),
        };
        let e = counts.entry(f.clone()).or_default();
        e.0 += 1;
        if !got.iter().zip(&want).all(|(a, b)| same(*a, *b)) {
            e.1 += 1;
            if first_bad.len() < 20 {
                first_bad.push(format!("{line}\n    got {:?}\n    want {:?}", got, want));
            }
        }
    }
    for (f, (n, bad)) in &counts {
        eprintln!("{f:>13}: {n:6} cases, {bad} differ from Go");
    }
    assert!(
        first_bad.is_empty(),
        "values that differ from Go:\n{}",
        first_bad.join("\n")
    );
}

#[test]
fn kernels_match_go_bit_for_bit() {
    check_file(concat!(
        env!("CARGO_MANIFEST_DIR"),
        "/testdata/go_kernels.txt"
    ));
    if let Ok(p) = std::env::var("RBFAST_GO_KERNELS") {
        check_file(&p);
    }
    common::report("kernels");
}

#[test]
fn quadrature_nodes_match_go() {
    let text = std::fs::read_to_string(concat!(
        env!("CARGO_MANIFEST_DIR"),
        "/testdata/go_consts.txt"
    ))
    .unwrap();
    let c: BTreeMap<&str, f64> = text
        .lines()
        .map(|l| l.split_once(' ').unwrap())
        .map(|(k, v)| (k, h(v)))
        .collect();
    let (x, w) = mathx::gl_nodes();
    for q in 0..10 {
        assert!(same(x[q], c[format!("glx{q}").as_str()]));
        assert!(same(w[q], c[format!("glw{q}").as_str()]));
    }
    let (zs, zw) = mathx::corr_nodes();
    let recomputed = mathx::corr_weights_recomputed();
    for q in 0..65 {
        assert!(same(zs[q], c[format!("zs{q}").as_str()]));
        assert!(same(zw[q], c[format!("zw{q}").as_str()]));
        assert!(
            same(recomputed[q], zw[q]),
            "the ported Exp recomputes Go's weight {q}"
        );
    }
    // Go's constant expressions are rounded once from the exact value; check the Rust spellings agree
    assert!(same(1.0 - 1e-16, c["one_minus_1e-16"]));
    assert!(same(std::f64::consts::SQRT_2 / 2.0, c["sqrt2_over_2"]));
    assert!(same(2.0 * std::f64::consts::PI, c["two_pi"]));
    assert!(same(std::f64::consts::LN_2, c["ln2"]));
    eprintln!(
        "1 + 1e-12 in Rust f64 arithmetic matches Go's constant: {}",
        same(1.0 + 1e-12, c["one_plus_1e-12"])
    );
    eprintln!(
        "1 / 0.35 in Rust f64 arithmetic matches Go's constant: {}",
        same(1.0 / 0.35, c["inv_0.35"])
    );
}
