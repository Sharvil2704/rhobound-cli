// SPDX-License-Identifier: Apache-2.0
//! Parity with the Go reference on the rbfast oracle (24 captures): the whole infer.Run result
//! (inferred_full.json), the `rhobound infer` stdout and stderr (infer.json, infer.stderr, and the --workers
//! runs), the refusals, and every pod's FIFO rebuild (fifo_pods.jsonl.gz). Skipped when RBFAST_ORACLE is unset.
//! Run with --release (the five test-bed captures hold 347k-697k spans each) and --nocapture for the table.
//! The byte-identity of the JSON texts is checked on aarch64 only (the oracle is Go's linux/arm64 output); every
//! number is compared within 1e-9 relative everywhere (common::compare).

mod common;

use std::collections::BTreeMap;
use std::path::Path;

use rbfast_infer::{run, run_traced, Options, PodFifo, SortMode};
use serde_json::Value;

/// The --workers override of a capture's infer_workers run, from its commands.txt ("# workers override: a=3").
fn workers_override(dir: &Path) -> Option<BTreeMap<String, i64>> {
    let cmds = common::read(&dir.join("commands.txt"));
    let line = cmds.lines().find(|l| l.starts_with("# workers override:"))?;
    let spec = line.trim_start_matches("# workers override:").trim();
    let mut m = BTreeMap::new();
    for kv in spec.split(',') {
        let (k, v) = kv.split_once('=')?;
        m.insert(k.trim().to_string(), v.trim().parse().ok()?);
    }
    Some(m)
}

struct Row {
    name: String,
    mode: &'static str,
    result: String,
}

fn check_capture(dir: &Path, mode: SortMode, rows: &mut Vec<Row>, failures: &mut Vec<String>) {
    let name = dir.file_name().unwrap().to_string_lossy().to_string();
    let mname = match mode {
        SortMode::GoExact => "go-exact",
        SortMode::Parallel => "parallel",
        SortMode::Stable => "stable",
    };
    let base = common::load(dir);
    let opt = Options { sort: mode, ..Default::default() };
    let mut d = base.clone();
    let got = run(&mut d, &opt);
    let err_path = dir.join("inferred_error.txt");
    if err_path.exists() {
        let want = common::read(&err_path);
        match got {
            Err(e) if format!("{e}\n") == want => {
                rows.push(Row { name, mode: mname, result: "refusal: same text".into() })
            }
            Err(e) => failures.push(format!("{name} [{mname}]: error text differs:\n  go:   {want}  rust: {e}")),
            Ok(_) => failures.push(format!("{name} [{mname}]: Go refuses, Rust does not")),
        }
        return;
    }
    let inf = match got {
        Ok(x) => x,
        Err(e) => {
            failures.push(format!("{name} [{mname}]: Rust refuses: {e}"));
            return;
        }
    };
    // the whole result
    let full = inf.to_json().unwrap().pretty() + "\n";
    let want_full = common::read(&dir.join("inferred_full.json"));
    let gv: Value = serde_json::from_str(&want_full).unwrap();
    let rv: Value = serde_json::from_str(&full).unwrap();
    let c = common::compare(&gv, &rv, 1e-9, 0.0);
    for d in &c.diffs {
        failures.push(format!("{name} [{mname}]: {d}"));
    }
    // the CLI's stdout and stderr
    let topo = inf.topology.marshal().unwrap() + "\n";
    let want_topo = common::read(&dir.join("infer.json"));
    let stderr = inf.stderr_text();
    let want_stderr = common::read(&dir.join("infer.stderr"));
    let tv: Value = serde_json::from_str(&want_topo).unwrap();
    let ct = common::compare(&tv, &serde_json::from_str(&topo).unwrap(), 1e-9, 0.0);
    for d in &ct.diffs {
        failures.push(format!("{name} [{mname}] infer.json: {d}"));
    }
    if stderr != want_stderr {
        failures.push(format!("{name} [{mname}]: infer.stderr differs:\n--- go\n{want_stderr}--- rust\n{stderr}"));
    }
    // both modes sort into Go's order, so the text must be Go's, byte for byte (on aarch64: see common::same)
    if common::bit_exact() && full != want_full {
        failures.push(format!("{name} [{mname}]: inferred_full.json is not byte-identical"));
    }
    if common::bit_exact() && topo != want_topo {
        failures.push(format!("{name} [{mname}]: infer.json is not byte-identical"));
    }
    // the --workers run
    let mut wnote = String::new();
    if let Some(w) = workers_override(dir) {
        let mut d = base.clone();
        let inf_w = run(&mut d, &Options { workers: w, sort: mode, ..Default::default() }).expect("workers run");
        let want = common::read(&dir.join("infer_workers.json"));
        let got_w = inf_w.topology.marshal().unwrap() + "\n";
        let cw =
            common::compare(&serde_json::from_str(&want).unwrap(), &serde_json::from_str(&got_w).unwrap(), 1e-9, 0.0);
        for d in &cw.diffs {
            failures.push(format!("{name} [{mname}] infer_workers.json: {d}"));
        }
        let want_err = common::read(&dir.join("infer_workers.stderr"));
        if inf_w.stderr_text() != want_err {
            failures.push(format!(
                "{name} [{mname}]: infer_workers.stderr differs:\n--- go\n{want_err}--- rust\n{}",
                inf_w.stderr_text()
            ));
        }
        wnote = format!(", workers run {}", if got_w == want { "byte-identical" } else { "within tolerance" });
    }
    rows.push(Row {
        name,
        mode: mname,
        result: format!(
            "full {} ({} floats, {} bit-equal, max rel {:.2e}{}), infer.json {}, stderr {}{}",
            if full == want_full { "byte-identical" } else { "differs in text" },
            c.floats,
            c.exact,
            c.max_rel,
            if c.worst.is_empty() { String::new() } else { format!(" at {}", c.worst) },
            if topo == want_topo { "byte-identical" } else { "differs in text" },
            if stderr == want_stderr { "identical" } else { "DIFFERS" },
            wnote
        ),
    });
}

#[test]
fn oracle_infer_all_captures() {
    let Some(oracle) = common::oracle_dir() else {
        return;
    };
    let mut rows = Vec::new();
    let mut failures = Vec::new();
    for dir in common::captures(&oracle) {
        for mode in [SortMode::GoExact, SortMode::Parallel] {
            check_capture(&dir, mode, &mut rows, &mut failures);
        }
    }
    for r in &rows {
        eprintln!("{:40} {:9} {}", r.name, r.mode, r.result);
    }
    // 24 captures in the recorded oracle; 19 without the unpublished test-bed captures
    assert!(rows.len() >= 2 * 19, "only {} rows", rows.len());
    common::report("oracle captures");
    assert!(failures.is_empty(), "{} failures:\n{}", failures.len(), failures.join("\n"));
}

fn num(v: &Value) -> f64 {
    match v {
        Value::String(s) if s == "NaN" => f64::NAN,
        Value::String(s) if s == "+Inf" => f64::INFINITY,
        Value::String(s) if s == "-Inf" => f64::NEG_INFINITY,
        _ => v.as_f64().unwrap(),
    }
}

fn nums(v: &Value) -> Vec<f64> {
    v.as_array().unwrap().iter().map(num).collect()
}

fn same(a: f64, b: f64) -> bool {
    common::same(a, b)
}

/// Compares one pod's rebuild with the oracle's line; returns what differs (empty when bit-identical).
fn cmp_pod(p: &PodFifo, w: &Value, inputs_exact: bool) -> Vec<String> {
    let mut d = Vec::new();
    let q = &p.q;
    let ints: [(&str, i64); 8] = [
        ("pod_id", p.pod_id as i64),
        ("service_id", p.service_id as i64),
        ("fixed", p.fixed),
        ("jobs", q.jobs as i64),
        ("workers", q.workers),
        ("contradictions", q.contradictions),
        ("max_in_system", q.max_in_system),
        ("waited", q.waited as i64),
    ];
    for (k, v) in ints {
        if w[k].as_i64() != Some(v) {
            d.push(format!("{k}: go {} rust {v}", w[k]));
        }
    }
    for (k, v) in [("pod", &p.pod), ("service", &p.service)] {
        if w[k].as_str() != Some(v.as_str()) {
            d.push(format!("{k}: go {} rust {v}", w[k]));
        }
    }
    for (k, v) in [("enough_waits", q.enough_waits), ("identified", q.identified)] {
        if w[k].as_bool() != Some(v) {
            d.push(format!("{k}: go {} rust {v}", w[k]));
        }
    }
    for (k, v) in [
        ("refuted_below", q.refuted_below),
        ("wait_mean", q.wait_mean),
        ("shortfall_z", q.shortfall_z),
        ("shortfall_rel", q.shortfall_rel),
    ] {
        if !same(num(&w[k]), v) {
            d.push(format!("{k}: go {} rust {v:e}", w[k]));
        }
    }
    let rb: BTreeMap<String, String> = w["refuted_by"]
        .as_object()
        .unwrap()
        .iter()
        .map(|(k, v)| (k.clone(), v.as_str().unwrap().to_string()))
        .collect();
    let mine: BTreeMap<String, String> = q.refuted_by.iter().map(|(k, v)| (k.to_string(), v.to_string())).collect();
    if rb != mine {
        d.push(format!("refuted_by: go {rb:?} rust {mine:?}"));
    }
    let arrays: [(&str, &Vec<f64>); 5] = [("a", &p.a), ("d", &p.d), ("A", &q.a), ("B", &q.b), ("D", &q.d)];
    for (k, v) in arrays {
        let g = nums(&w[k]);
        if g.len() != v.len() {
            d.push(format!("{k}: length go {} rust {}", g.len(), v.len()));
            continue;
        }
        let bad = g.iter().zip(v.iter()).filter(|(x, y)| !same(**x, **y)).count();
        if bad > 0 && (inputs_exact || k != "a" && k != "d") {
            d.push(format!("{k}: {bad} of {} values differ", g.len()));
        }
    }
    let order: Vec<usize> = w["order"].as_array().unwrap().iter().map(|x| x.as_u64().unwrap() as usize).collect();
    if order != q.order {
        d.push("order differs".to_string());
    }
    d
}

/// Every pod's queue rebuild against the oracle's: the inputs (a, d in visit-record order), the queue order,
/// every start of service, the worker count, the refutations and the statistics, bit for bit, in both sort
/// modes (both put spans with an equal trace and start where Go does). With the stable sort (an audit switch,
/// not Go's order of such ties) the visit-record order can differ from Go's, so there the inputs and the order
/// are compared as multisets only (the queue itself must still be identical).
#[test]
fn oracle_fifo_pods() {
    let Some(oracle) = common::oracle_dir() else {
        return;
    };
    let mut failures = Vec::new();
    let mut n_pods = 0;
    let mut n_jobs = 0usize;
    for dir in common::captures(&oracle) {
        let path = dir.join("fifo_pods.jsonl.gz");
        if !path.exists() {
            continue;
        }
        let name = dir.file_name().unwrap().to_string_lossy().to_string();
        let want: Vec<Value> = common::gunzip(&path).lines().map(|l| serde_json::from_str(l).unwrap()).collect();
        for mode in [SortMode::GoExact, SortMode::Parallel, SortMode::Stable] {
            let mut d = common::load(&dir);
            let mut pods = Vec::new();
            let _ = run_traced(&mut d, &Options { sort: mode, ..Default::default() }, Some(&mut pods));
            if pods.len() != want.len() {
                failures.push(format!("{name} {mode:?}: {} pods, go {}", pods.len(), want.len()));
                continue;
            }
            for (p, w) in pods.iter().zip(&want) {
                let mut diffs = cmp_pod(p, w, mode != SortMode::Stable);
                if mode == SortMode::Stable {
                    // the multiset of inputs must agree
                    let (mut ga, mut ra) = (nums(&w["a"]), p.a.clone());
                    ga.sort_by(f64::total_cmp);
                    ra.sort_by(f64::total_cmp);
                    if ga != ra {
                        diffs.push("a: the inputs differ as a multiset".into());
                    }
                    diffs.retain(|x| x != "order differs");
                }
                if mode == SortMode::GoExact {
                    n_pods += 1;
                    n_jobs += p.q.jobs;
                }
                for x in diffs {
                    failures.push(format!("{name} {mode:?} pod {} ({}): {x}", p.pod_id, p.pod));
                }
            }
        }
    }
    eprintln!("fifo pods compared: {n_pods} pods, {n_jobs} jobs");
    common::report("fifo pods");
    assert!(n_pods > 0);
    assert!(failures.is_empty(), "{} failures:\n{}", failures.len(), failures.join("\n"));
}

/// The result does not depend on the thread count: 1 and 8 threads give byte-identical output, in both sort
/// modes, on the captures with the most traces, ties and structure.
#[test]
fn threads_do_not_change_the_result() {
    let Some(oracle) = common::oracle_dir() else {
        return;
    };
    // the largest capture (the largest test-bed capture), and four simulated ones
    let largest = common::captures(&oracle)
        .into_iter()
        .max_by_key(|d| common::span_count(d))
        .expect("no captures in the oracle")
        .file_name()
        .unwrap()
        .to_string_lossy()
        .to_string();
    let pick = [
        largest.as_str(),
        "sim-row41-staged-spanq",
        "sim-row30-fanout-b-default",
        "sim-fanout-replicas",
        "capture-chain",
    ];
    let mut n = 0;
    for name in pick {
        let dir = oracle.join(name);
        if !dir.exists() {
            eprintln!("{name}: not in the oracle");
            continue;
        }
        n += 1;
        let base = common::load(&dir);
        for mode in [SortMode::GoExact, SortMode::Parallel] {
            let mut outs = Vec::new();
            for threads in [1, 2, 3, 8] {
                let mut d = base.clone();
                let opt = Options { sort: mode, ..Default::default() };
                let inf = common::pool(threads).install(|| run(&mut d, &opt)).unwrap();
                outs.push((threads, inf.to_json().unwrap().pretty()));
            }
            for (t, o) in &outs[1..] {
                assert!(*o == outs[0].1, "{name} {mode:?}: {t} threads differ from 1");
            }
            eprintln!("{name} {mode:?}: 1, 2, 3, 8 threads byte-identical");
        }
    }
    assert_eq!(n, pick.len(), "a picked capture is missing from the oracle");
}
