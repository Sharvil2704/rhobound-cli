// SPDX-License-Identifier: Apache-2.0

//! The Go tests' reference sets, run on the Rust port: testdata/golden.json (the Python reference
//! implementation's basic model, 201 cases) at 1e-12 relative, and testdata/reference.json (scipy, 50-digit
//! decimal, adaptive quadrature, Monte Carlo) at the Go tests' own tolerances. Both files are copies of
//! rhobound-cli's testdata (same licence). The worst errors print with --nocapture.

#![allow(clippy::neg_cmp_op_on_partial_ord)] // NaN counts as worse, as in the Go tests

use rbfast_math::{mathx, model, parse_topology};
use serde_json::Value;

fn load(name: &str) -> Value {
    let p = format!("{}/testdata/{name}", env!("CARGO_MANIFEST_DIR"));
    serde_json::from_slice(&std::fs::read(&p).unwrap()).unwrap()
}

fn nums(v: &Value) -> Vec<f64> {
    v.as_array()
        .unwrap()
        .iter()
        .map(|x| x.as_f64().unwrap())
        .collect()
}

/// The golden test's measure: |got - want| / max(1, |want|).
fn rel1(got: f64, want: f64) -> f64 {
    if got == want {
        0.0
    } else {
        (got - want).abs() / want.abs().max(1.0)
    }
}

#[test]
fn golden_basic_model() {
    let doc = load("golden.json");
    let cases = doc["cases"].as_array().unwrap();
    assert!(cases.len() >= 200);
    const TOL: f64 = 1e-12;
    let mut worst = 0.0f64;
    let mut worst_strict = 0.0f64; // |got - want| / |want|
    let mut n = 0;
    for c in cases {
        let name = c["name"].as_str().unwrap();
        let t = parse_topology(&serde_json::to_vec(&c["topology"]).unwrap()).unwrap();
        let lam = c["lam"].as_f64().unwrap();
        let ds = nums(&c["ds"]);
        let mut check = |what: &str, got: &[f64], want: &Value| {
            let want = nums(want);
            assert_eq!(got.len(), want.len(), "{name} {what}");
            for (g, w) in got.iter().zip(&want) {
                n += 1;
                let e = rel1(*g, *w);
                worst = worst.max(e);
                if *w != 0.0 {
                    worst_strict = worst_strict.max((g - w).abs() / w.abs());
                }
                assert!(e <= TOL, "{name} {what}: {g} vs {w} (rel {e:e})");
            }
        };
        let b = model::analytic(&t, lam, None).unwrap();
        assert_eq!(b.stable, c["base_stable"].as_bool().unwrap(), "{name}");
        if b.stable {
            check("rho", &b.rho, &c["rho_by_service"]);
            check("lam", &b.lam, &c["lam_by_service"]);
            check("R", b.r.as_ref().unwrap(), &c["R"]);
            check("L", b.l.as_ref().unwrap(), &c["L"]);
        }
        let p = model::analytic(&t, lam, Some(&ds)).unwrap();
        assert_eq!(p.stable, c["patched_stable"].as_bool().unwrap(), "{name}");
        if p.stable {
            check("R patched", p.r.as_ref().unwrap(), &c["R_patched"]);
            check("L patched", p.l.as_ref().unwrap(), &c["L_patched"]);
        }
    }
    eprintln!(
        "golden: {} cases, {n} values: worst |d|/max(1,|ref|) {worst:.2e}, worst |d|/|ref| {worst_strict:.2e} (tolerance 1e-12)",
        cases.len()
    );
}

struct Worst {
    name: &'static str,
    tol: f64,
    err: f64,
    at: String,
    n: usize,
}

impl Worst {
    fn new(name: &'static str, tol: f64) -> Worst {
        Worst {
            name,
            tol,
            err: 0.0,
            at: String::new(),
            n: 0,
        }
    }
    fn add(&mut self, e: f64, at: impl FnOnce() -> String) {
        self.n += 1;
        if !(e <= self.err) {
            self.err = e;
            self.at = at();
        }
    }
    fn check(&self) {
        eprintln!(
            "{:<42} worst {:.2e} (tolerance {:.0e}, {} values) at {}",
            self.name, self.err, self.tol, self.n, self.at
        );
        assert!(
            self.n > 0 && self.err <= self.tol,
            "{}: {:e} above {:e}",
            self.name,
            self.err,
            self.tol
        );
    }
}

fn rel(got: f64, want: f64) -> f64 {
    if got == want {
        0.0
    } else {
        (got - want).abs() / want.abs()
    }
}

#[test]
fn numerics_reference() {
    let r = load("reference.json");
    // GammaP, by shape tier (Go's tolerances)
    let mut gp = [
        Worst::new("GammaP, shape <= 100", 1e-12),
        Worst::new("GammaP, shape 100..1e4", 1e-10),
        Worst::new("GammaP, shape 1e4..1e5", 5e-10),
    ];
    for row in r["gamma_p"].as_array().unwrap() {
        let v = nums(row);
        let (a, x, want) = (v[0], v[1], v[2]);
        let w = if a > 1e4 {
            &mut gp[2]
        } else if a > 100.0 {
            &mut gp[1]
        } else {
            &mut gp[0]
        };
        let got = mathx::gamma_p(a, x);
        let mut e = rel(got, want);
        if want < 1e-300 && (got - want).abs() <= 1e-300 {
            e = 0.0;
        }
        w.add(e, || format!("P({a}, {x})"));
    }
    gp.iter().for_each(Worst::check);
    let mut cdf = Worst::new("NormCDF, x in [-37.5, 8.25]", 1e-12);
    for row in r["norm_cdf"].as_array().unwrap() {
        let v = nums(row);
        cdf.add(rel(mathx::norm_cdf(v[0]), v[1]), || format!("x = {}", v[0]));
    }
    cdf.check();
    let mut q = Worst::new("NormQuantile, u in [1e-300, 1-2^-53]", 2e-15);
    for row in r["norm_quantile"].as_array().unwrap() {
        let v = nums(row);
        let got = mathx::norm_quantile(v[0]);
        q.add((got - v[1]).abs() / v[1].abs().max(0.1), || {
            format!("u = {}", v[0])
        });
    }
    q.check();
    let mut ec = Worst::new("ErlangC, 1..100000 servers", 1e-13);
    for row in r["erlang_c"].as_array().unwrap() {
        let v = nums(row);
        let got = model::erlang_c(v[0] as i64, v[1]);
        let want = v[2];
        let e = if got != want && !(want < 1e-300 && (got - want).abs() <= 1e-300) {
            (got - want).abs() / want
        } else {
            0.0
        };
        ec.add(e, || format!("m={} a={}", v[0], v[1]));
    }
    ec.check();
    let mut ex = Worst::new("EmaxExp, 2-12 branches (exact sum)", 1e-12);
    let mut en = Worst::new("EmaxExp, 13-16 branches (quadrature)", 2e-12);
    for c in r["emax_exp"].as_array().unwrap() {
        let ms = nums(&c["means"]);
        let w = if ms.len() > mathx::EMAX_EXACT_LIMIT {
            &mut en
        } else {
            &mut ex
        };
        w.add(
            rel(mathx::emax_exp(&ms), c["emax"].as_f64().unwrap()),
            || format!("{} branches", ms.len()),
        );
    }
    ex.check();
    en.check();
    let min_shape = |mu: &[f64], va: &[f64]| {
        mu.iter()
            .zip(va)
            .map(|(m, v)| m * m / v)
            .fold(f64::INFINITY, f64::min)
    };
    let mut real = [
        Worst::new("E[max], scv <= 1.5 and r <= 0.9", 3e-13),
        Worst::new("Var[max], scv <= 1.5 and r <= 0.9", 2e-11),
    ];
    let mut rest = [
        Worst::new("E[max], shapes 0.3..100, r <= 0.95", 3e-9),
        Worst::new("Var[max], shapes 0.3..100, r <= 0.95", 1e-8),
    ];
    for c in r["max_gamma"].as_array().unwrap() {
        let (mu, va, rr) = (nums(&c["mu"]), nums(&c["var"]), c["r"].as_f64().unwrap());
        let w = if min_shape(&mu, &va) >= 1.0 / 1.5 && rr <= 0.9 {
            &mut real
        } else {
            &mut rest
        };
        let (m, v) = mathx::max_moments_gamma_corr(&mu, &va, rr);
        w[0].add(rel(m, c["mean"].as_f64().unwrap()), || {
            format!("{} branches r {rr}", mu.len())
        });
        w[1].add(rel(v, c["var_max"].as_f64().unwrap()), || {
            format!("{} branches r {rr}", mu.len())
        });
    }
    real.iter().chain(rest.iter()).for_each(Worst::check);
    let mut mixed = [
        [
            Worst::new("E[max], heavy beside narrow, r = 0", 3e-11),
            Worst::new("Var[max], heavy beside narrow, r = 0", 5e-10),
        ],
        [
            Worst::new("E[max], heavy beside narrow, r 0.5-0.9", 1.5e-10),
            Worst::new("Var[max], heavy beside narrow, r 0.5-0.9", 2.5e-9),
        ],
    ];
    for c in r["max_gamma_mixed"].as_array().unwrap() {
        let (mu, va, rr) = (nums(&c["mu"]), nums(&c["var"]), c["r"].as_f64().unwrap());
        let w = if rr > 0.0 {
            &mut mixed[1]
        } else {
            &mut mixed[0]
        };
        let (m, v) = mathx::max_moments_gamma_corr(&mu, &va, rr);
        w[0].add(rel(m, c["mean"].as_f64().unwrap()), || {
            format!("mu {mu:?} var {va:?} r {rr}")
        });
        w[1].add(rel(v, c["var_max"].as_f64().unwrap()), || {
            format!("mu {mu:?} var {va:?} r {rr}")
        });
    }
    mixed.iter().flatten().for_each(Worst::check);
    // Monte Carlo: within 4 standard errors
    for c in r["max_gamma_mc"].as_array().unwrap() {
        let (mu, va, rr) = (nums(&c["mu"]), nums(&c["var"]), c["r"].as_f64().unwrap());
        let (m, v) = mathx::max_moments_gamma_corr(&mu, &va, rr);
        let zm = (m - c["mean"].as_f64().unwrap()) / c["mean_se"].as_f64().unwrap();
        let zv = (v - c["var_max"].as_f64().unwrap()) / c["var_se"].as_f64().unwrap();
        assert!(
            zm.abs() <= 4.0 && zv.abs() <= 4.0,
            "Monte Carlo {} branches r {rr}: {zm:+.2} se, {zv:+.2} se",
            mu.len()
        );
    }
}
