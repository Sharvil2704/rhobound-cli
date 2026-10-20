// SPDX-License-Identifier: Apache-2.0

//! rbfast-math-oracle: the Rust side of the oracle's model and numerics files, for parity checks and timing. The
//! Go side is a driver program made for the comparison (not published), called "the Go driver" below.
//!
//! ```text
//!   rbfast-math-oracle cases MANIFEST.json OUT.json      the schema of the Go driver's cases (model_*.json)
//!   rbfast-math-oracle mathx REFERENCE.json OUT.json     the schema of the Go driver's mathx (mathx_go.json)
//!   rbfast-math-oracle sweep MANIFEST.json REPS [THREADS] [--share-base]
//!                                                         the manifest's evaluations, timed (as the Go driver's sweep)
//!   rbfast-math-oracle bench-kernels REPS                 ns per call of every kernel (median of REPS runs)
//!   rbfast-math-oracle bench-grid TOPOLOGY.json N_LAMS N_PATCHES THREADS REPS [--share-base] [--memo] [--pq N]
//!                                                         [--json OUT]
//!                                                         an N_LAMS x 2 configs x N_PATCHES what-if grid
//!   rbfast-math-oracle bench-fanout MAXN REPS             serial vs parallel quadrature for n-branch fan-outs
//!   rbfast-math-oracle bench-analytic TOPOLOGY.json LAM_PER_MS REPS
//!                                                         one AnalyticWith / ChangePatchWith, Plain and Default
//! ```
//!
//! Floats are written in shortest round-trip form (they read back as the same float64); NaN and infinities as
//! the strings "NaN", "+Inf", "-Inf", as the oracle does.

use rbfast_math::batch::{self, Grid, Outcome};
use rbfast_math::model::{self, Exec};
use rbfast_math::{gomath, mathx, Config, Delta, ModelResult, Patch, Topology, DEFAULT, PLAIN};
use serde_json::{json, Map, Value};
use std::time::Instant;

fn die(msg: impl std::fmt::Display) -> ! {
    eprintln!("rbfast-math-oracle: {msg}");
    std::process::exit(1)
}

fn f(x: f64) -> Value {
    if x.is_nan() {
        Value::String("NaN".into())
    } else if x == f64::INFINITY {
        Value::String("+Inf".into())
    } else if x == f64::NEG_INFINITY {
        Value::String("-Inf".into())
    } else {
        json!(x)
    }
}

fn fs(xs: Option<&[f64]>) -> Value {
    match xs {
        None => Value::Null,
        Some(xs) => Value::Array(xs.iter().map(|&x| f(x)).collect()),
    }
}

fn res(r: &ModelResult) -> Value {
    json!({
        "stable": r.stable,
        "rho": fs(Some(&r.rho)),
        "lam": fs(Some(&r.lam)),
        "ca2": fs(r.ca2.as_deref()),
        "r": fs(r.r.as_deref()),
        "v": fs(r.v.as_deref()),
        "l": fs(r.l.as_deref()),
    })
}

fn del(d: Result<Delta, model::ModelError>) -> Value {
    match d {
        Err(e) => json!({"stable": false, "base": null, "patched": null, "dl": null, "error": e.0}),
        Ok(d) => {
            json!({"stable": d.stable, "base": res(&d.base), "patched": res(&d.patched), "dl": fs(d.dl.as_deref())})
        }
    }
}

struct Case {
    name: String,
    topology: Vec<u8>,
    lam: f64,
    ds: Option<Vec<f64>>,
    patches: Vec<String>,
    rps: Vec<f64>,
}

fn load_manifest(path: &str) -> Vec<Case> {
    let raw = std::fs::read(path).unwrap_or_else(|e| die(format!("{path}: {e}")));
    let v: Value = serde_json::from_slice(&raw).unwrap_or_else(|e| die(format!("{path}: {e}")));
    let list = v
        .as_array()
        .unwrap_or_else(|| die("a manifest is a JSON list"));
    list.iter()
        .map(|c| {
            let topology = match (
                c.get("topology"),
                c.get("topology_path").and_then(Value::as_str),
            ) {
                (Some(t), _) if !t.is_null() => serde_json::to_vec(t).unwrap(),
                (_, Some(p)) => std::fs::read(p).unwrap_or_else(|e| die(format!("{p}: {e}"))),
                _ => die("a case needs a topology or a topology_path"),
            };
            let nums = |k: &str| -> Option<Vec<f64>> {
                c.get(k)
                    .and_then(Value::as_array)
                    .map(|a| a.iter().map(|x| x.as_f64().unwrap()).collect())
            };
            Case {
                name: c
                    .get("name")
                    .and_then(Value::as_str)
                    .unwrap_or("")
                    .to_string(),
                topology,
                lam: c.get("lam_per_ms").and_then(Value::as_f64).unwrap_or(0.0),
                ds: nums("ds"),
                patches: c
                    .get("patches")
                    .and_then(Value::as_array)
                    .map(|a| a.iter().map(|x| x.as_str().unwrap().to_string()).collect())
                    .unwrap_or_default(),
                rps: nums("rps").unwrap_or_default(),
            }
        })
        .collect()
}

/// The topology JSON exactly as the manifest has it: serde_json re-serialises numbers in shortest form, which
/// reads back to the same float64, so parsing it is parsing the original.
fn parse(c: &Case) -> Result<Topology, model::ModelError> {
    rbfast_math::parse_topology(&c.topology)
}

const CONFIGS: [(&str, Config); 2] = [("plain", PLAIN), ("default", DEFAULT)];

fn eval_case(c: &Case, lam: f64, rps: Option<f64>) -> Value {
    let mut out = Map::new();
    out.insert("name".into(), json!(c.name));
    out.insert("lam_per_ms".into(), f(lam));
    if let Some(r) = rps {
        out.insert("rps".into(), f(r));
    }
    if let Some(ds) = &c.ds {
        out.insert("ds".into(), fs(Some(ds)));
    }
    let topo = match parse(c) {
        Ok(t) => t,
        Err(e) => {
            out.insert("parse_error".into(), json!(e.0));
            out.insert("services".into(), Value::Null);
            out.insert("order".into(), Value::Null);
            out.insert("visit_ratios".into(), Value::Null);
            out.insert("configs".into(), json!({}));
            return Value::Object(out);
        }
    };
    out.insert("services".into(), json!(topo.names()));
    out.insert("order".into(), json!(topo.order()));
    out.insert("visit_ratios".into(), fs(Some(&topo.visit_ratios())));
    let mut configs = Map::new();
    for (cname, cfg) in CONFIGS {
        let mut co = Map::new();
        match model::analytic_with(&topo, lam, None, cfg) {
            Ok(b) => {
                co.insert("base".into(), res(&b));
            }
            Err(e) => {
                co.insert("base".into(), Value::Null);
                co.insert("base_error".into(), json!(e.0));
            }
        }
        if let Some(ds) = &c.ds {
            co.insert(
                "change_ds".into(),
                del(model::change_patch_with(
                    &topo,
                    lam,
                    &Patch {
                        ds: Some(ds.clone()),
                        ..Default::default()
                    },
                    cfg,
                )),
            );
            let shift: Vec<bool> = ds.iter().map(|&d| d != 0.0).collect();
            co.insert(
                "change_ds_shift".into(),
                del(model::change_patch_with(
                    &topo,
                    lam,
                    &Patch {
                        ds: Some(ds.clone()),
                        shift: Some(shift),
                        glue: None,
                    },
                    cfg,
                )),
            );
        }
        if !c.patches.is_empty() {
            let mut patches = Map::new();
            let mut inputs = Map::new();
            for spec in &c.patches {
                match model::parse_patch(spec, &topo) {
                    Err(e) => {
                        patches.insert(spec.clone(), json!({"stable": false, "base": null, "patched": null, "dl": null, "error": e}));
                    }
                    Ok((p, _)) => {
                        inputs.insert(
                            spec.clone(),
                            json!({"ds": fs(p.ds.as_deref()), "shift": p.shift.clone(), "glue": fs(p.glue.as_deref())}),
                        );
                        patches.insert(
                            spec.clone(),
                            del(model::change_patch_with(&topo, lam, &p, cfg)),
                        );
                    }
                }
            }
            co.insert("patches".into(), Value::Object(patches));
            if !inputs.is_empty() {
                co.insert("patch_inputs".into(), Value::Object(inputs));
            }
        }
        configs.insert(cname.into(), Value::Object(co));
    }
    out.insert("configs".into(), Value::Object(configs));
    Value::Object(out)
}

fn cmd_cases(manifest: &str, out_path: &str) {
    let mut outs = Vec::new();
    for c in load_manifest(manifest) {
        if c.rps.is_empty() {
            outs.push(eval_case(&c, c.lam, None));
        } else {
            for &r in &c.rps {
                outs.push(eval_case(&c, r / 1000.0, Some(r)));
            }
        }
    }
    std::fs::write(out_path, serde_json::to_vec_pretty(&outs).unwrap()).unwrap_or_else(|e| die(e));
}

// ------------------------------------------------------------------------------------------------- mathx

fn arr(v: &Value) -> Vec<f64> {
    v.as_array()
        .unwrap()
        .iter()
        .map(|x| x.as_f64().unwrap())
        .collect()
}

fn max_case(mu: &[f64], var: &[f64], r: f64) -> Value {
    let (m, v) = if r == 0.0 {
        mathx::max_moments_gamma(mu, var)
    } else {
        mathx::max_moments_gamma_corr(mu, var, r)
    };
    json!({"mu": fs(Some(mu)), "var": fs(Some(var)), "r": f(r), "go_mean": f(m), "go_var_max": f(v)})
}

/// The Go driver's logspace: math.Pow(10, lo+(hi-lo)*i/(n-1)). Go's Pow is not ported, so this uses Rust's powf,
/// which can differ from Go's in the last bit: the grid inputs are taken from the Go file instead (see main).
fn cmd_mathx(ref_path: &str, go_path: &str, out_path: &str) {
    let raw = std::fs::read(ref_path).unwrap_or_else(|e| die(e));
    let reference: Value = serde_json::from_slice(&raw).unwrap();
    let go: Value =
        serde_json::from_slice(&std::fs::read(go_path).unwrap_or_else(|e| die(e))).unwrap();
    let mut out = Map::new();
    let rows = |k: &str| reference[k].as_array().unwrap().clone();
    out.insert(
        "ref_gamma_p".into(),
        Value::Array(
            rows("gamma_p")
                .iter()
                .map(|r| {
                    let (a, x) = (r[0].as_f64().unwrap(), r[1].as_f64().unwrap());
                    json!([f(a), f(x), f(mathx::gamma_p(a, x))])
                })
                .collect(),
        ),
    );
    out.insert(
        "ref_norm_cdf".into(),
        Value::Array(
            rows("norm_cdf")
                .iter()
                .map(|r| {
                    let x = r[0].as_f64().unwrap();
                    json!([f(x), f(mathx::norm_cdf(x))])
                })
                .collect(),
        ),
    );
    out.insert(
        "ref_norm_quantile".into(),
        Value::Array(
            rows("norm_quantile")
                .iter()
                .map(|r| {
                    let u = r[0].as_f64().unwrap();
                    json!([f(u), f(mathx::norm_quantile(u))])
                })
                .collect(),
        ),
    );
    out.insert(
        "ref_erlang_c".into(),
        Value::Array(
            rows("erlang_c")
                .iter()
                .map(|r| {
                    let (m, a) = (r[0].as_f64().unwrap(), r[1].as_f64().unwrap());
                    json!([f(m), f(a), f(model::erlang_c(m as i64, a))])
                })
                .collect(),
        ),
    );
    out.insert(
        "ref_emax_exp".into(),
        Value::Array(
            rows("emax_exp")
                .iter()
                .map(|r| {
                    let ms = arr(&r["means"]);
                    json!({"means": fs(Some(&ms)), "go_emax": f(mathx::emax_exp(&ms))})
                })
                .collect(),
        ),
    );
    for (key, src) in [
        ("ref_max_gamma", "max_gamma"),
        ("ref_max_gamma_mc", "max_gamma_mc"),
        ("ref_max_gamma_mixed", "max_gamma_mixed"),
    ] {
        out.insert(
            key.into(),
            Value::Array(
                rows(src)
                    .iter()
                    .map(|r| max_case(&arr(&r["mu"]), &arr(&r["var"]), r["r"].as_f64().unwrap()))
                    .collect(),
            ),
        );
    }
    // grids: Go's inputs (logspace uses Go's math.Pow, not ported), Rust's values
    let grid = |k: &str| go[k].as_array().unwrap().clone();
    out.insert(
        "grid_gamma_p".into(),
        Value::Array(
            grid("grid_gamma_p")
                .iter()
                .map(|r| {
                    let (a, x) = (r[0].as_f64().unwrap(), r[1].as_f64().unwrap());
                    json!([f(a), f(x), f(mathx::gamma_p(a, x))])
                })
                .collect(),
        ),
    );
    out.insert(
        "grid_norm_cdf".into(),
        Value::Array(
            grid("grid_norm_cdf")
                .iter()
                .map(|r| {
                    let x = r[0].as_f64().unwrap();
                    json!([f(x), f(mathx::norm_cdf(x))])
                })
                .collect(),
        ),
    );
    out.insert(
        "grid_norm_quantile".into(),
        Value::Array(
            grid("grid_norm_quantile")
                .iter()
                .map(|r| {
                    let u = r[0].as_f64().unwrap();
                    json!([f(u), f(mathx::norm_quantile(u))])
                })
                .collect(),
        ),
    );
    out.insert(
        "grid_erlang_c".into(),
        Value::Array(
            grid("grid_erlang_c")
                .iter()
                .map(|r| {
                    let (m, a) = (r[0].as_f64().unwrap(), r[1].as_f64().unwrap());
                    json!([f(m), f(a), f(model::erlang_c(m as i64, a))])
                })
                .collect(),
        ),
    );
    out.insert(
        "grid_residence".into(),
        Value::Array(
            grid("grid_residence")
                .iter()
                .map(|r| {
                    let v: Vec<f64> = (0..5).map(|i| r[i].as_f64().unwrap()).collect();
                    json!([
                        f(v[0]),
                        f(v[1]),
                        f(v[2]),
                        f(v[3]),
                        f(v[4]),
                        f(model::residence(v[0], v[1], v[2] as i64, v[3], v[4]))
                    ])
                })
                .collect(),
        ),
    );
    out.insert(
        "grid_residence_shares".into(),
        Value::Array(
            grid("grid_residence_shares")
                .iter()
                .map(|r| {
                    let sh = arr(&r["shares"]);
                    let (s, lam, w, ca2, cs2) = (
                        r["s"].as_f64().unwrap(),
                        r["lam"].as_f64().unwrap(),
                        r["workers"].as_i64().unwrap(),
                        r["ca2"].as_f64().unwrap(),
                        r["cs2"].as_f64().unwrap(),
                    );
                    json!({"s": f(s), "lam": f(lam), "shares": fs(Some(&sh)), "workers": w, "ca2": f(ca2), "cs2": f(cs2),
                           "go_value": f(model::residence_shares(s, lam, &sh, w, ca2, cs2))})
                })
                .collect(),
        ),
    );
    out.insert(
        "grid_emax_exp".into(),
        Value::Array(
            grid("grid_emax_exp")
                .iter()
                .map(|r| {
                    let ms = arr(&r["means"]);
                    json!({"means": fs(Some(&ms)), "go_emax": f(mathx::emax_exp(&ms))})
                })
                .collect(),
        ),
    );
    out.insert(
        "grid_max_gamma".into(),
        Value::Array(
            grid("grid_max_gamma")
                .iter()
                .map(|r| max_case(&arr(&r["mu"]), &arr(&r["var"]), r["r"].as_f64().unwrap()))
                .collect(),
        ),
    );
    std::fs::write(
        out_path,
        serde_json::to_vec_pretty(&Value::Object(out)).unwrap(),
    )
    .unwrap_or_else(|e| die(e));
}

// ------------------------------------------------------------------------------------------------- timing

fn median(xs: &mut [f64]) -> f64 {
    xs.sort_by(f64::total_cmp);
    xs[xs.len() / 2]
}

/// Every (case, load, config, patch) evaluation of a manifest, as the Go driver's sweep builds the list.
struct Eval {
    topo: usize,
    lam: f64,
    patch: Option<Patch>,
    cfg: Config,
}

fn sweep_evals(manifest: &str) -> (Vec<Topology>, Vec<Eval>) {
    let mut topos = Vec::new();
    let mut evs = Vec::new();
    for c in load_manifest(manifest) {
        let topo = parse(&c).unwrap_or_else(|e| die(format!("{}: {e}", c.name)));
        let lams: Vec<f64> = if c.rps.is_empty() {
            vec![c.lam]
        } else {
            c.rps.iter().map(|r| r / 1000.0).collect()
        };
        let ti = topos.len();
        for &lam in &lams {
            for (_, cfg) in CONFIGS {
                evs.push(Eval {
                    topo: ti,
                    lam,
                    patch: None,
                    cfg,
                });
                for spec in &c.patches {
                    let (p, _) = model::parse_patch(spec, &topo).unwrap_or_else(|e| die(e));
                    evs.push(Eval {
                        topo: ti,
                        lam,
                        patch: Some(p),
                        cfg,
                    });
                }
            }
        }
        topos.push(topo);
    }
    (topos, evs)
}

/// The Go driver's sink: base L at the first service of the order, or `DL[0]`, added in evaluation order (and, like
/// the Go driver's, carried across repetitions).
fn add_checksum(topos: &[Topology], evs: &[Eval], outs: &[Outcome], sink: &mut f64) {
    for (e, o) in evs.iter().zip(outs) {
        match o {
            Outcome::Base(Ok(b)) if b.stable => {
                *sink += b.l.as_ref().unwrap()[topos[e.topo].order()[0]]
            }
            Outcome::Change(Ok(d)) if d.stable => *sink += d.dl.as_ref().unwrap()[0],
            _ => {}
        }
    }
}

fn cmd_sweep(manifest: &str, reps: usize, threads: usize) {
    let (topos, evs) = sweep_evals(manifest);
    let exec = Exec::default();
    let mut times = Vec::new();
    let mut sink = 0.0;
    batch::with_threads(threads, || {
        for _ in 0..reps {
            let t0 = Instant::now();
            let scs: Vec<batch::Scenario> = evs
                .iter()
                .map(|e| batch::Scenario {
                    topology: &topos[e.topo],
                    lam_ext: e.lam,
                    patch: e.patch.as_ref(),
                    config: e.cfg,
                })
                .collect();
            let outs = if threads == 1 {
                scs.iter()
                    .map(|s| batch::evaluate(s, exec))
                    .collect::<Vec<_>>()
            } else {
                batch::evaluate_batch(&scs, exec)
            };
            times.push(t0.elapsed().as_secs_f64());
            add_checksum(&topos, &evs, &outs, &mut sink);
        }
    })
    .expect("thread pool");
    let med = median(&mut times);
    println!(
        "{} evaluations x {} reps, {} threads: median {:.3} ms per rep, {:.2} us per evaluation, checksum {:.17e}",
        evs.len(),
        reps,
        if threads == 0 { rayon::current_num_threads() } else { threads },
        1e3 * med,
        1e6 * med / evs.len() as f64,
        sink
    );
}

fn time_ns(reps: usize, n: usize, mut f: impl FnMut(usize) -> f64) -> f64 {
    let mut times = Vec::new();
    let mut sink = 0.0;
    for _ in 0..reps {
        let t0 = Instant::now();
        for i in 0..n {
            sink += f(i);
        }
        times.push(t0.elapsed().as_secs_f64() * 1e9 / n as f64);
    }
    std::hint::black_box(sink);
    median(&mut times)
}

/// The same inputs and loops as the Go kernel benchmark written for the comparison (not published): the
/// kernel is called directly in the timed loop (the closure is inlined), as the Go loop calls it.
fn cmd_bench_kernels(reps: usize) {
    let n = 100_000;
    let xs: Vec<f64> = (0..n)
        .map(|i| -30.0 + 60.0 * ((i as f64 * 0.618033988749895) % 1.0))
        .collect();
    let pos: Vec<f64> = (0..n)
        .map(|i| 10f64.powf(-3.0 + 6.0 * ((i as f64 * 0.618033988749895) % 1.0)))
        .collect();
    let us: Vec<f64> = (0..n)
        .map(|i| 1e-6 + (1.0 - 2e-6) * ((i as f64 * 0.618033988749895) % 1.0))
        .collect();
    println!("kernel                         ns/op (median of {reps})");
    println!(
        "baseline (return input)        {:8.2}",
        time_ns(reps, n, |i| xs[i])
    );
    println!(
        "Exp                            {:8.2}",
        time_ns(reps, n, |i| gomath::exp(xs[i]))
    );
    println!(
        "Log                            {:8.2}",
        time_ns(reps, n, |i| gomath::log(pos[i]))
    );
    println!(
        "Lgamma                         {:8.2}",
        time_ns(reps, n, |i| gomath::lgamma(pos[i]))
    );
    println!(
        "Erfc                           {:8.2}",
        time_ns(reps, n, |i| gomath::erfc(xs[i] / 5.0))
    );
    println!(
        "Erfinv                         {:8.2}",
        time_ns(reps, n, |i| gomath::erfinv(2.0 * us[i] - 1.0))
    );
    println!(
        "GammaP(a, a*x)                 {:8.2}",
        time_ns(reps, n, |i| mathx::gamma_p(pos[i], pos[i] * (0.5 + us[i])))
    );
    println!(
        "NormCDF                        {:8.2}",
        time_ns(reps, n, |i| mathx::norm_cdf(xs[i] / 5.0))
    );
    println!(
        "NormQuantile                   {:8.2}",
        time_ns(reps, n, |i| mathx::norm_quantile(us[i]))
    );
    println!(
        "ErlangC(m=8)                   {:8.2}",
        time_ns(reps, n, |i| model::erlang_c(8, 8.0 * us[i]))
    );
    println!(
        "ErlangC(m=64)                  {:8.2}",
        time_ns(reps, n, |i| model::erlang_c(64, 64.0 * us[i]))
    );
    let mm = 2000;
    println!(
        "MaxMomentsGamma 2 branches     {:8.0}",
        time_ns(reps, mm, |i| mathx::max_moments_gamma(
            &[40.0 + (i % 7) as f64, 46.0],
            &[1600.0, 2116.0]
        )
        .0)
    );
    println!(
        "MaxMomentsGammaCorr 2, r=0.5   {:8.0}",
        time_ns(reps, mm, |i| mathx::max_moments_gamma_corr(
            &[40.0 + (i % 7) as f64, 46.0],
            &[1600.0, 2116.0],
            0.5
        )
        .0)
    );
    println!(
        "MaxMomentsGammaCorr 4, r=0.5   {:8.0}",
        time_ns(reps, mm / 4, |i| mathx::max_moments_gamma_corr(
            &[40.0 + (i % 7) as f64, 46.0, 30.0, 52.0],
            &[1600.0, 2116.0, 900.0, 2704.0],
            0.5
        )
        .0)
    );
    println!(
        "EmaxExp 3 branches             {:8.2}",
        time_ns(reps, n, |i| mathx::emax_exp(&[10.0 + us[i], 12.0, 7.0]))
    );
}

/// Fan-outs of n equal-ish branches: the serial quadrature against the parallel one, on the current pool.
fn cmd_bench_fanout(maxn: usize, reps: usize) {
    println!(
        "branches  serial_ms  parallel_ms  threads={}  (r = 0.5, scv 0.3..1.5)",
        rayon::current_num_threads()
    );
    let mut n = 2;
    while n <= maxn {
        let mu: Vec<f64> = (0..n).map(|j| 20.0 + 3.0 * j as f64).collect();
        let var: Vec<f64> = mu
            .iter()
            .enumerate()
            .map(|(j, m)| (0.3 + 1.2 * (j % 5) as f64 / 4.0) * m * m)
            .collect();
        let k = (64 / n).max(1);
        let s = time_ns(reps, k, |_| mathx::max_moments_gamma_corr(&mu, &var, 0.5).0) / 1e6;
        let p = time_ns(reps, k, |_| {
            mathx::max_moments_gamma_corr_par(&mu, &var, 0.5).0
        }) / 1e6;
        let (a, b) = (
            mathx::max_moments_gamma_corr(&mu, &var, 0.5),
            mathx::max_moments_gamma_corr_par(&mu, &var, 0.5),
        );
        assert!(
            a.0.to_bits() == b.0.to_bits() && a.1.to_bits() == b.1.to_bits(),
            "parallel quadrature differs"
        );
        println!("{n:8}  {s:9.3}  {p:11.3}");
        n *= 2;
    }
}

fn cmd_bench_grid(args: &[String]) {
    let topo_path = &args[0];
    let nl: usize = args[1].parse().unwrap();
    let np: usize = args[2].parse().unwrap();
    let threads: usize = args[3].parse().unwrap();
    let reps: usize = args[4].parse().unwrap();
    let share = args.iter().any(|a| a == "--share-base");
    let use_memo = args.iter().any(|a| a == "--memo");
    let pq: usize = args
        .iter()
        .position(|a| a == "--pq")
        .map(|i| args[i + 1].parse().unwrap())
        .unwrap_or(0);
    let json_out = args
        .iter()
        .position(|a| a == "--json")
        .map(|i| args[i + 1].clone());
    let topo =
        rbfast_math::load_topology(std::path::Path::new(topo_path)).unwrap_or_else(|e| die(e));
    let grid = grid_for(&topo, nl, np);
    let mut times = Vec::new();
    let mut outs = Vec::new();
    let mut memo_stats = (0, 0);
    batch::with_threads(threads, || {
        for _ in 0..reps {
            let memo = mathx::MaxMemo::new(); // a fresh cache per run: no reuse across repetitions
            let exec = Exec {
                memo: if use_memo { Some(&memo) } else { None },
                parallel_quadrature_min_branches: pq,
            };
            let t0 = Instant::now();
            outs = if threads == 1 {
                // a plain serial loop, as Go's
                if share {
                    batch::sweep(&grid, exec, true)
                } else {
                    (0..grid.len())
                        .map(|k| {
                            let (li, ci, pi) = grid.index(k);
                            batch::evaluate(
                                &batch::Scenario {
                                    topology: grid.topology,
                                    lam_ext: grid.lams[li],
                                    patch: grid.patches[pi].as_ref(),
                                    config: grid.configs[ci],
                                },
                                exec,
                            )
                        })
                        .collect()
                }
            } else {
                batch::sweep(&grid, exec, share)
            };
            times.push(t0.elapsed().as_secs_f64());
            memo_stats = memo.stats();
        }
    })
    .expect("thread pool");
    let med = median(&mut times);
    let stable = outs
        .iter()
        .filter(|o| o.latency(topo.order()[0]).is_some())
        .count();
    println!(
        "{} scenarios ({} loads x 2 configs x {} patches), {} threads, share_base={} memo={} pq_min_branches={}: median {:.1} ms ({:.2} us per scenario), {} stable{}",
        grid.len(),
        nl,
        np,
        if threads == 0 { rayon::current_num_threads() } else { threads },
        share,
        use_memo,
        pq,
        med * 1e3,
        med * 1e6 / grid.len() as f64,
        stable,
        if use_memo { format!(", memo hits {} misses {}", memo_stats.0, memo_stats.1) } else { String::new() }
    );
    let runs: Vec<String> = times.iter().map(|t| format!("{:.1}", t * 1e3)).collect();
    println!("  runs (ms): {}", runs.join(" "));
    if let Some(p) = json_out {
        // one line per scenario: index, entry latency bits (or -1), for a comparison with Go's dump
        let mut s = String::new();
        for (k, o) in outs.iter().enumerate() {
            let v = match o {
                Outcome::Base(Ok(b)) if b.stable => {
                    format!("{:016x}", b.l.as_ref().unwrap()[topo.order()[0]].to_bits())
                }
                Outcome::Change(Ok(d)) if d.stable => format!(
                    "{:016x} {:016x}",
                    d.patched.l.as_ref().unwrap()[topo.order()[0]].to_bits(),
                    d.dl.as_ref().unwrap()[topo.order()[0]].to_bits()
                ),
                Outcome::Base(Err(e)) => format!("error {e}"),
                Outcome::Change(Err(e)) => format!("error {e}"),
                _ => "unstable".into(),
            };
            s.push_str(&format!("{k} {v}\n"));
        }
        std::fs::write(p, s).unwrap();
    }
}

/// The what-if grid the Go benchmark loop written for the comparison builds: loads from 5% to 95% of the
/// saturating rate in nl steps; patches: none, then every service in turn +5%, -5%, +1ms, -0.5ms (cycling),
/// up to np patches in all.
fn grid_for(topo: &Topology, nl: usize, np: usize) -> Grid<'_> {
    // the saturating external rate: min over services of capacity / (visits * s)
    let v = topo.visit_ratios();
    let mut sat = f64::INFINITY;
    for (i, sv) in topo.services.iter().enumerate() {
        if sv.delay || v[i] == 0.0 || sv.s == 0.0 {
            continue;
        }
        let cap = (sv.servers * sv.workers) as f64;
        sat = gomath::min(sat, cap / (v[i] * sv.s));
    }
    let lams: Vec<f64> = (0..nl)
        .map(|i| sat * (0.05 + 0.9 * i as f64 / (nl.max(2) - 1) as f64))
        .collect();
    let mut patches = vec![None];
    let kinds = ["+5%", "-5%", "+1ms", "-0.5ms"];
    let mut k = 0;
    while patches.len() < np {
        let svc = &topo.services[k % topo.services.len()].name;
        let spec = format!("{}={}", svc, kinds[(k / topo.services.len()) % kinds.len()]);
        let p = model::parse_patch(&spec, topo).ok().map(|(p, _)| p);
        if p.is_some() {
            patches.push(p);
        }
        k += 1;
        if k > 100 * np {
            break;
        }
    }
    Grid {
        topology: topo,
        lams,
        configs: vec![PLAIN, DEFAULT],
        patches,
    }
}

fn cmd_bench_analytic(path: &str, lam: f64, reps: usize) {
    let t = rbfast_math::load_topology(std::path::Path::new(path)).unwrap_or_else(|e| die(e));
    for (name, cfg) in CONFIGS {
        let n = if cfg.matched_max { 200 } else { 2000 };
        let a = time_ns(reps, n, |_| {
            model::analytic_with(&t, lam, None, cfg).unwrap().l.unwrap()[0]
        });
        let mut ds = vec![0.0; t.services.len()];
        ds[0] = 0.5;
        let p = Patch {
            ds: Some(ds),
            ..Default::default()
        };
        let d = time_ns(reps, n, |_| {
            model::change_patch_with(&t, lam, &p, cfg)
                .unwrap()
                .patched
                .l
                .unwrap()[0]
        });
        println!("{name:<8} AnalyticWith {a:10.0} ns   ChangePatchWith {d:10.0} ns");
        if cfg.matched_max {
            // the same call with the matched maximum's quadrature on the current rayon pool (same bits)
            let exec = Exec {
                parallel_quadrature_min_branches: 2,
                ..Default::default()
            };
            let want = model::analytic_with(&t, lam, None, cfg).unwrap();
            let got = model::analytic_exec(&t, lam, None, cfg, exec).unwrap();
            // Debug prints each float in shortest round-trip form (signed zeros too): equal text, equal bits
            assert_eq!(
                format!("{want:?}"),
                format!("{got:?}"),
                "parallel quadrature changed the result"
            );
            let a = time_ns(reps, n, |_| {
                model::analytic_exec(&t, lam, None, cfg, exec)
                    .unwrap()
                    .l
                    .unwrap()[0]
            });
            let d = time_ns(reps, n, |_| {
                model::change_patch_exec(&t, lam, &p, cfg, exec)
                    .unwrap()
                    .patched
                    .l
                    .unwrap()[0]
            });
            println!(
                "{:<8} AnalyticWith {a:10.0} ns   ChangePatchWith {d:10.0} ns   (parallel quadrature, {} threads)",
                format!("{name}+pq"),
                rayon::current_num_threads()
            );
        }
    }
}

fn main() {
    let args: Vec<String> = std::env::args().skip(1).collect();
    match args.first().map(String::as_str) {
        Some("cases") => cmd_cases(&args[1], &args[2]),
        Some("mathx") => cmd_mathx(&args[1], &args[2], &args[3]),
        Some("sweep") => {
            let threads = args.get(3).map(|s| s.parse().unwrap()).unwrap_or(1);
            cmd_sweep(&args[1], args[2].parse().unwrap(), threads)
        }
        Some("bench-kernels") => cmd_bench_kernels(args.get(1).map(|s| s.parse().unwrap()).unwrap_or(5)),
        Some("bench-grid") => cmd_bench_grid(&args[1..]),
        Some("bench-fanout") => {
            let maxn = args.get(1).map(|s| s.parse().unwrap()).unwrap_or(64);
            let reps = args.get(2).map(|s| s.parse().unwrap()).unwrap_or(3);
            cmd_bench_fanout(maxn, reps)
        }
        Some("bench-analytic") => cmd_bench_analytic(&args[1], args[2].parse().unwrap(), args[3].parse().unwrap()),
        _ => die("usage: rbfast-math-oracle cases|mathx|sweep|bench-kernels|bench-grid|bench-fanout|bench-analytic ..."),
    }
}
