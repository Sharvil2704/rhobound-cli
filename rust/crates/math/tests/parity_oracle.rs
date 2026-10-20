// SPDX-License-Identifier: Apache-2.0

//! Parity with the oracle (RBFAST_ORACLE; not in the repository, see rust/README.md): Go's 17-digit outputs of
//! AnalyticWith and ChangePatchWith (Plain and Default) on the golden, examples and inferred manifests, Go's
//! mathx values on reference.json's inputs and on grids, Go's math functions on a grid, and MarshalTopology's
//! bytes for every inferred topology. Everything compares bit for bit (signed zeros included) on aarch64, the
//! oracle being Go's linux/arm64 output; elsewhere floats compare within common::TOLERANCE. The tests pass with a
//! note when RBFAST_ORACLE is unset.

mod common;

use rbfast_math::{
    gomath, mathx, model, parse_topology, Config, Delta, ModelResult, Patch, DEFAULT, PLAIN,
};
use serde_json::Value;
use std::path::PathBuf;

fn oracle() -> Option<PathBuf> {
    common::oracle_dir()
}

fn load(p: PathBuf) -> Value {
    serde_json::from_slice(&std::fs::read(&p).unwrap_or_else(|e| panic!("{}: {e}", p.display())))
        .unwrap()
}

/// The oracle's float: a number, or "NaN" / "+Inf" / "-Inf".
fn fv(v: &Value) -> f64 {
    match v {
        Value::String(s) if s == "NaN" => f64::NAN,
        Value::String(s) if s == "+Inf" => f64::INFINITY,
        Value::String(s) if s == "-Inf" => f64::NEG_INFINITY,
        v => v.as_f64().unwrap_or_else(|| panic!("not a float: {v}")),
    }
}

fn same(a: f64, b: f64) -> bool {
    common::same(a, b)
}

fn bits_same(a: f64, b: f64) -> bool {
    a.to_bits() == b.to_bits() || (a.is_nan() && b.is_nan())
}

struct Cmp {
    n: usize,
    bad: Vec<String>,
}

impl Cmp {
    fn vec(&mut self, path: &str, got: Option<&[f64]>, want: &Value) {
        match (got, want) {
            (None, Value::Null) => {}
            (Some(g), Value::Array(w)) if g.len() == w.len() => {
                for (i, (x, y)) in g.iter().zip(w).enumerate() {
                    self.n += 1;
                    if !same(*x, fv(y)) {
                        self.bad.push(format!("{path}[{i}]: {x:e} vs Go {}", y));
                    }
                }
            }
            _ => self.bad.push(format!("{path}: {got:?} vs Go {want}")),
        }
    }
    fn res(&mut self, path: &str, got: &ModelResult, want: &Value) {
        if want.is_null() {
            self.bad.push(format!("{path}: a result where Go has null"));
            return;
        }
        if got.stable != want["stable"].as_bool().unwrap() {
            self.bad.push(format!("{path}/stable"));
        }
        self.vec(&format!("{path}/rho"), Some(&got.rho), &want["rho"]);
        self.vec(&format!("{path}/lam"), Some(&got.lam), &want["lam"]);
        self.vec(&format!("{path}/ca2"), got.ca2.as_deref(), &want["ca2"]);
        self.vec(&format!("{path}/r"), got.r.as_deref(), &want["r"]);
        self.vec(&format!("{path}/v"), got.v.as_deref(), &want["v"]);
        self.vec(&format!("{path}/l"), got.l.as_deref(), &want["l"]);
    }
    fn delta(&mut self, path: &str, got: Result<Delta, model::ModelError>, want: &Value) {
        match got {
            Err(e) => {
                if want["error"].as_str() != Some(&e.0) {
                    self.bad.push(format!("{path}: error {e} vs Go {want}"));
                }
            }
            Ok(d) => {
                if want.get("error").is_some() {
                    self.bad
                        .push(format!("{path}: no error, Go {}", want["error"]));
                    return;
                }
                if d.stable != want["stable"].as_bool().unwrap() {
                    self.bad.push(format!("{path}/stable"));
                }
                self.res(&format!("{path}/base"), &d.base, &want["base"]);
                self.res(&format!("{path}/patched"), &d.patched, &want["patched"]);
                self.vec(&format!("{path}/dl"), d.dl.as_deref(), &want["dl"]);
            }
        }
    }
}

fn check_manifest(dir: &std::path::Path, which: &str) -> (usize, usize) {
    let manifest = load(dir.join(format!("model/manifest_{which}.json")));
    let go = load(dir.join(format!("model/model_{which}.json")));
    let go = go.as_array().unwrap();
    let mut cmp = Cmp {
        n: 0,
        bad: Vec::new(),
    };
    let mut k = 0;
    for c in manifest.as_array().unwrap() {
        let topo_json = match (&c["topology"], c["topology_path"].as_str()) {
            (t, _) if !t.is_null() => serde_json::to_vec(t).unwrap(),
            (_, Some(p)) => std::fs::read(p).unwrap(),
            _ => panic!("no topology"),
        };
        let topo = parse_topology(&topo_json).unwrap();
        let lams: Vec<f64> = match c["rps"].as_array() {
            Some(r) => r.iter().map(|x| x.as_f64().unwrap() / 1000.0).collect(),
            None => vec![c["lam_per_ms"].as_f64().unwrap()],
        };
        let ds: Option<Vec<f64>> = c["ds"]
            .as_array()
            .map(|a| a.iter().map(|x| x.as_f64().unwrap()).collect());
        let specs: Vec<String> = c["patches"]
            .as_array()
            .map(|a| a.iter().map(|x| x.as_str().unwrap().to_string()).collect())
            .unwrap_or_default();
        for lam in lams {
            let w = &go[k];
            k += 1;
            let name = w["name"].as_str().unwrap();
            assert!(same(lam, fv(&w["lam_per_ms"])), "{name}: load");
            assert_eq!(
                w["services"],
                serde_json::json!(topo.names()),
                "{name}: services"
            );
            assert_eq!(w["order"], serde_json::json!(topo.order()), "{name}: order");
            cmp.vec(
                &format!("{name}/visit_ratios"),
                Some(&topo.visit_ratios()),
                &w["visit_ratios"],
            );
            for (cname, cfg) in [("plain", PLAIN), ("default", DEFAULT)] {
                let wc = &w["configs"][cname];
                let path = format!("{name}@{lam}/{cname}");
                match model::analytic_with(&topo, lam, None, cfg) {
                    Ok(b) => cmp.res(&format!("{path}/base"), &b, &wc["base"]),
                    Err(e) => {
                        if wc["base_error"].as_str() != Some(&e.0) {
                            cmp.bad.push(format!("{path}: base error {e}"));
                        }
                    }
                }
                if let Some(ds) = &ds {
                    let p = Patch {
                        ds: Some(ds.clone()),
                        ..Default::default()
                    };
                    cmp.delta(
                        &format!("{path}/change_ds"),
                        model::change_patch_with(&topo, lam, &p, cfg),
                        &wc["change_ds"],
                    );
                    // the same through Go's wrappers (Change is ChangeShiftWith with Plain)
                    cmp.delta(
                        &format!("{path}/change_ds (change_shift_with)"),
                        model::change_shift_with(&topo, lam, Some(ds), None, cfg),
                        &wc["change_ds"],
                    );
                    if cfg == PLAIN {
                        cmp.delta(
                            &format!("{path}/change_ds (change)"),
                            model::change(&topo, lam, Some(ds)),
                            &wc["change_ds"],
                        );
                    }
                    let shift: Vec<bool> = ds.iter().map(|&d| d != 0.0).collect();
                    let p = Patch {
                        ds: Some(ds.clone()),
                        shift: Some(shift.clone()),
                        glue: None,
                    };
                    cmp.delta(
                        &format!("{path}/change_ds_shift"),
                        model::change_patch_with(&topo, lam, &p, cfg),
                        &wc["change_ds_shift"],
                    );
                    cmp.delta(
                        &format!("{path}/change_ds_shift (change_shift_with)"),
                        model::change_shift_with(&topo, lam, Some(ds), Some(&shift), cfg),
                        &wc["change_ds_shift"],
                    );
                    if cfg == PLAIN {
                        cmp.delta(
                            &format!("{path}/change_ds_shift (change_shift)"),
                            model::change_shift(&topo, lam, Some(ds), Some(&shift)),
                            &wc["change_ds_shift"],
                        );
                    }
                }
                for spec in &specs {
                    let (p, _) = model::parse_patch(spec, &topo).unwrap();
                    let wi = &wc["patch_inputs"][spec.as_str()];
                    cmp.vec(&format!("{path}/{spec}/ds"), p.ds.as_deref(), &wi["ds"]);
                    cmp.vec(
                        &format!("{path}/{spec}/glue"),
                        p.glue.as_deref(),
                        &wi["glue"],
                    );
                    assert_eq!(
                        serde_json::json!(p.shift),
                        wi["shift"],
                        "{path}/{spec}: shift"
                    );
                    cmp.delta(
                        &format!("{path}/{spec}"),
                        model::change_patch_with(&topo, lam, &p, cfg),
                        &wc["patches"][spec.as_str()],
                    );
                }
            }
        }
    }
    assert_eq!(k, go.len(), "{which}: case count");
    for b in cmp.bad.iter().take(20) {
        eprintln!("{b}");
    }
    (cmp.n, cmp.bad.len())
}

#[test]
fn model_matches_go_bit_for_bit() {
    let Some(dir) = oracle() else { return };
    let mut total_bad = 0;
    for which in ["golden", "examples", "inferred", "sweep"] {
        if which == "sweep" {
            continue; // model_sweep.json is timing output, not values
        }
        let (n, bad) = check_manifest(&dir, which);
        eprintln!("model_{which}.json: {n} floats compared, {bad} differ");
        total_bad += bad;
    }
    common::report("model manifests");
    assert_eq!(total_bad, 0);
}

#[test]
fn mathx_matches_go_bit_for_bit() {
    let Some(dir) = oracle() else { return };
    let go = load(dir.join("model/mathx_go.json"));
    let mut n = 0;
    let mut bad = Vec::new();
    let mut check = |what: &str, got: f64, want: &Value| {
        n += 1;
        if !same(got, fv(want)) {
            bad.push(format!("{what}: {got:e} vs Go {want}"));
        }
    };
    for k in ["ref_gamma_p", "grid_gamma_p"] {
        for r in go[k].as_array().unwrap() {
            check(k, mathx::gamma_p(fv(&r[0]), fv(&r[1])), &r[2]);
        }
    }
    for k in ["ref_norm_cdf", "grid_norm_cdf"] {
        for r in go[k].as_array().unwrap() {
            check(k, mathx::norm_cdf(fv(&r[0])), &r[1]);
        }
    }
    for k in ["ref_norm_quantile", "grid_norm_quantile"] {
        for r in go[k].as_array().unwrap() {
            check(k, mathx::norm_quantile(fv(&r[0])), &r[1]);
        }
    }
    for k in ["ref_erlang_c", "grid_erlang_c"] {
        for r in go[k].as_array().unwrap() {
            check(k, model::erlang_c(fv(&r[0]) as i64, fv(&r[1])), &r[2]);
        }
    }
    for r in go["grid_residence"].as_array().unwrap() {
        let v: Vec<f64> = (0..5).map(|i| fv(&r[i])).collect();
        check(
            "grid_residence",
            model::residence(v[0], v[1], v[2] as i64, v[3], v[4]),
            &r[5],
        );
    }
    for r in go["grid_residence_shares"].as_array().unwrap() {
        let sh: Vec<f64> = r["shares"].as_array().unwrap().iter().map(fv).collect();
        let got = model::residence_shares(
            fv(&r["s"]),
            fv(&r["lam"]),
            &sh,
            r["workers"].as_i64().unwrap(),
            fv(&r["ca2"]),
            fv(&r["cs2"]),
        );
        check("grid_residence_shares", got, &r["go_value"]);
    }
    for k in ["ref_emax_exp", "grid_emax_exp"] {
        for r in go[k].as_array().unwrap() {
            let ms: Vec<f64> = r["means"].as_array().unwrap().iter().map(fv).collect();
            check(k, mathx::emax_exp(&ms), &r["go_emax"]);
        }
    }
    for k in [
        "ref_max_gamma",
        "ref_max_gamma_mc",
        "ref_max_gamma_mixed",
        "grid_max_gamma",
    ] {
        for r in go[k].as_array().unwrap() {
            let mu: Vec<f64> = r["mu"].as_array().unwrap().iter().map(fv).collect();
            let va: Vec<f64> = r["var"].as_array().unwrap().iter().map(fv).collect();
            let rr = fv(&r["r"]);
            let (m, v) = if rr == 0.0 {
                mathx::max_moments_gamma(&mu, &va)
            } else {
                mathx::max_moments_gamma_corr(&mu, &va, rr)
            };
            check(k, m, &r["go_mean"]);
            check(k, v, &r["go_var_max"]);
            let (mp, vp) = mathx::max_moments_gamma_corr_par(&mu, &va, rr);
            check(&format!("{k} (parallel quadrature)"), mp, &r["go_mean"]);
            check(&format!("{k} (parallel quadrature)"), vp, &r["go_var_max"]);
        }
    }
    eprintln!("mathx_go.json: {n} values compared, {} differ", bad.len());
    common::report("mathx_go.json");
    assert!(bad.is_empty(), "{}", bad[..bad.len().min(20)].join("\n"));
}

#[test]
fn go_math_grid_matches() {
    let Some(dir) = oracle() else { return };
    let go = load(dir.join("model/gomath.json"));
    let mut n = 0;
    let mut bad = Vec::new();
    for r in go["fns"].as_array().unwrap() {
        let x = fv(&r["x"]);
        let mut check = |what: &str, got: f64, want: &Value| {
            n += 1;
            if !same(got, fv(want)) {
                bad.push(format!("{what}({x:e}): {got:e} vs Go {want}"));
            }
        };
        check("exp", gomath::exp(x), &r["exp"]);
        check("log", gomath::log(x), &r["log"]);
        if x >= 0.0 {
            check("lgamma", gomath::lgamma(x), &r["lgamma"]); // negative arguments are not ported
        }
        check("erfc", gomath::erfc(x), &r["erfc"]);
        check("sqrt", x.sqrt(), &r["sqrt"]);
    }
    for r in go["erfinv"].as_array().unwrap() {
        n += 1;
        let x = fv(&r["x"]);
        if !same(gomath::erfinv(x), fv(&r["erfinv"])) {
            bad.push(format!("erfinv({x:e})"));
        }
    }
    eprintln!("gomath.json: {n} values compared, {} differ", bad.len());
    common::report("gomath.json");
    assert!(bad.is_empty(), "{}", bad[..bad.len().min(20)].join("\n"));
}

/// Rust's own libm against Go's math on the same grid: how far a plain port (std exp/ln/erfc) would be from Go.
#[test]
fn std_libm_vs_go_note() {
    let Some(dir) = oracle() else { return };
    let go = load(dir.join("model/gomath.json"));
    let (mut n, mut de, mut dl) = (0, 0, 0);
    for r in go["fns"].as_array().unwrap() {
        let x = fv(&r["x"]);
        n += 1;
        de += !bits_same(x.exp(), fv(&r["exp"])) as usize;
        dl += !bits_same(x.ln(), fv(&r["log"])) as usize;
    }
    eprintln!(
        "Rust std on the gomath grid ({n} points): exp differs from Go's at {de}, ln at {dl}"
    );
}

#[test]
fn marshal_topology_matches_go_bytes() {
    let Some(dir) = oracle() else { return };
    let mut n = 0;
    for e in std::fs::read_dir(&dir).unwrap() {
        let p = e.unwrap().path().join("infer.json");
        if !p.is_file() {
            continue;
        }
        let want = std::fs::read_to_string(&p).unwrap();
        let t = parse_topology(want.as_bytes()).unwrap();
        let got = rbfast_math::marshal_topology(&t).unwrap();
        assert_eq!(got + "\n", want, "{}", p.display());
        n += 1;
    }
    eprintln!(
        "{n} inferred topologies: MarshalTopology(ParseTopology(infer.json)) is byte-identical"
    );
    // 23 in the recorded oracle; 18 without the unpublished test-bed captures
    assert!(n >= 18, "only {n} inferred topologies");
}

#[allow(dead_code)]
fn _cfg(_: Config) {}
