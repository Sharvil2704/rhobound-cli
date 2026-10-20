// SPDX-License-Identifier: Apache-2.0
//! The crate's private copy of mathx.GammaP (and the Lgamma it uses) against Go's own values: the oracle's
//! model/mathx_go.json (GammaP on the inputs of testdata/numerics/reference.json and on a grid, Go 1.27.2
//! linux/arm64) and model/gomath.json (math.Lgamma on a grid). Prints how many agree bit for bit and the largest
//! relative difference; fails above 1e-12 relative for shapes a <= 100 (the inference's range) and above 1e-9 (the
//! inference's bar) for larger shapes. Skipped when RBFAST_ORACLE is unset.

mod common;

use rbfast_infer::mathx::{gamma_p, lgamma};
use serde_json::Value;

fn num(v: &Value) -> f64 {
    match v {
        Value::String(s) if s == "NaN" => f64::NAN,
        Value::String(s) if s == "+Inf" => f64::INFINITY,
        Value::String(s) if s == "-Inf" => f64::NEG_INFINITY,
        _ => v.as_f64().unwrap(),
    }
}

#[derive(Default)]
struct Tally {
    n: usize,
    exact: usize,
    worst: f64,
    at: String,
}

impl Tally {
    fn add(&mut self, got: f64, want: f64, what: String) {
        self.n += 1;
        if got.to_bits() == want.to_bits() || (got.is_nan() && want.is_nan()) {
            self.exact += 1;
            return;
        }
        let r = if got == want { 0.0 } else { (got - want).abs() / got.abs().max(want.abs()) };
        let r = if r.is_nan() { f64::INFINITY } else { r };
        if r > self.worst {
            self.worst = r;
            self.at = format!("{what}: rust {got:e} go {want:e}");
        }
    }
}

#[test]
fn gamma_p_and_lgamma_against_go() {
    let Some(oracle) = common::oracle_dir() else {
        return;
    };
    let mx: Value = serde_json::from_str(&common::read(&oracle.join("model/mathx_go.json"))).unwrap();
    // the inference calls GammaP with a = (pods - 1) / 2, so a <= 100 covers up to 201 pods per service; above
    // that, P's exponent a*ln(x) - x - lgamma(a) is a small difference of large terms, and an ulp of glibc's ln
    // against Go's math.Log moves the result by ~1e-11 relative (tallied apart)
    let mut gp = Tally::default();
    let mut gp_big = Tally::default();
    for set in ["ref_gamma_p", "grid_gamma_p"] {
        for row in mx[set].as_array().unwrap() {
            let r = row.as_array().unwrap();
            let (a, x, want) = (num(&r[0]), num(&r[1]), num(&r[r.len() - 1]));
            let t = if a <= 100.0 { &mut gp } else { &mut gp_big };
            t.add(gamma_p(a, x), want, format!("{set} GammaP({a:e}, {x:e})"));
        }
    }
    let gm: Value = serde_json::from_str(&common::read(&oracle.join("model/gomath.json"))).unwrap();
    let mut lg = Tally::default();
    for row in gm["fns"].as_array().unwrap() {
        let x = num(&row["x"]);
        if x > 0.0 {
            lg.add(lgamma(x), num(&row["lgamma"]), format!("Lgamma({x:e})"));
        }
    }
    for (name, t) in [("GammaP, a <= 100", &gp), ("GammaP, a > 100", &gp_big), ("Lgamma", &lg)] {
        eprintln!(
            "{name}: {} of {} values bit-equal to Go's, max relative difference {:.2e}{}",
            t.exact,
            t.n,
            t.worst,
            if t.at.is_empty() { String::new() } else { format!(" at {}", t.at) }
        );
    }
    assert!(gp.n > 2000 && gp_big.n > 500 && lg.n > 400);
    assert!(gp.worst <= 1e-12, "GammaP (a <= 100) differs from Go's by {:e} ({})", gp.worst, gp.at);
    assert!(gp_big.worst <= 1e-9, "GammaP (a > 100) differs from Go's by {:e} ({})", gp_big.worst, gp_big.at);
    assert!(lg.worst <= 1e-12, "Lgamma differs from Go's by {:e} ({})", lg.worst, lg.at);
}
