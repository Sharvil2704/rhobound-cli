// SPDX-License-Identifier: Apache-2.0
//! Go's unit tests of the inference's parts, ported: fifo_test.go, structure_test.go, split_test.go,
//! workers_test.go, workers_search_test.go. Where a Go test draws its inputs from math/rand, the inputs and Go's
//! answers were written by a fixture test in a copy of the Go tree (RBFAST_FIXTURES, not in the repository); the
//! Rust code must give Go's answers on them, and the Go test's own assertions are checked too. The reference
//! implementation's golden files are read from the Go tree (internal/infer/testdata of this repository, or
//! RBFAST_GO_TESTDATA). A test whose data is absent says so and passes. Floats are compared with
//! common::same: bit for bit on aarch64, within 1e-9 relative elsewhere.

mod common;

use std::collections::BTreeMap;
use std::path::PathBuf;

use rbfast_infer::fifo::{self, fifo_start, infer_workers, max_in_system, queue_order};
use rbfast_infer::rise::{self, ByK};
use rbfast_infer::split::{even_split_p, pod_split, split_warning, SPLIT_P};
use rbfast_infer::structure::{key, stage_template};
use rbfast_infer::VisitRec;
use serde_json::Value;

/// The Go tree's internal/infer/testdata: RBFAST_GO_TESTDATA, else this repository's.
fn go_testdata() -> Option<PathBuf> {
    let p = std::env::var_os("RBFAST_GO_TESTDATA")
        .map(PathBuf::from)
        .unwrap_or_else(|| PathBuf::from(concat!(env!("CARGO_MANIFEST_DIR"), "/../../../internal/infer/testdata")));
    if p.join("fifo_golden.json").exists() {
        Some(p)
    } else {
        eprintln!("skipped: no fifo_golden.json in {} (set RBFAST_GO_TESTDATA)", p.display());
        None
    }
}

/// Go's inputs and answers for the tests that draw from math/rand (RBFAST_FIXTURES).
fn fixtures() -> Option<PathBuf> {
    common::data_dir("RBFAST_FIXTURES", "fifo_cases.json.gz", "Go's inputs and answers for the randomized unit tests")
}

fn num(v: &Value) -> f64 {
    match v {
        Value::String(s) if s == "NaN" => f64::NAN,
        Value::String(s) if s == "+Inf" => f64::INFINITY,
        Value::String(s) if s == "-Inf" => f64::NEG_INFINITY,
        Value::Null => f64::NAN,
        _ => v.as_f64().unwrap(),
    }
}

fn nums(v: &Value) -> Vec<f64> {
    v.as_array().unwrap().iter().map(num).collect()
}

fn same(a: f64, b: f64) -> bool {
    common::same(a, b)
}

fn refuted(q: &fifo::PodQueue) -> BTreeMap<String, String> {
    q.refuted_by.iter().map(|(k, v)| (k.to_string(), v.to_string())).collect()
}

fn json_map(v: &Value) -> BTreeMap<String, String> {
    v.as_object()
        .map_or_else(BTreeMap::new, |m| m.iter().map(|(k, v)| (k.clone(), v.as_str().unwrap().to_string())).collect())
}

/// Go's podQueue on the same input, field for field and bit for bit.
fn assert_queue_eq(name: &str, q: &fifo::PodQueue, w: &Value) {
    assert_eq!(q.workers, w["workers"].as_i64().unwrap(), "{name}: workers");
    assert_eq!(q.jobs as i64, w["jobs"].as_i64().unwrap(), "{name}: jobs");
    assert_eq!(q.contradictions, w["contradictions"].as_i64().unwrap(), "{name}: contradictions");
    assert_eq!(q.max_in_system, w["max_in_system"].as_i64().unwrap(), "{name}: max_in_system");
    assert_eq!(q.waited as i64, w["waited"].as_i64().unwrap(), "{name}: waited");
    assert_eq!(q.enough_waits, w["enough_waits"].as_bool().unwrap(), "{name}: enough_waits");
    assert_eq!(q.identified, w["identified"].as_bool().unwrap(), "{name}: identified");
    for (k, v) in [
        ("refuted_below", q.refuted_below),
        ("wait_mean", q.wait_mean),
        ("shortfall_z", q.shortfall_z),
        ("shortfall_rel", q.shortfall_rel),
    ] {
        assert!(same(v, num(&w[k])), "{name}: {k} {v:e} vs go {}", w[k]);
    }
    assert_eq!(refuted(q), json_map(&w["refuted_by"]), "{name}: refuted_by");
    let order: Vec<usize> = w["order"].as_array().unwrap().iter().map(|x| x.as_u64().unwrap() as usize).collect();
    assert_eq!(q.order, order, "{name}: order");
    let b = nums(&w["B"]);
    assert!(b.len() == q.b.len() && b.iter().zip(&q.b).all(|(x, y)| same(*x, *y)), "{name}: B");
}

// ---- fifo_test.go

#[test]
fn fifo_start_by_hand() {
    let a = [0.0, 1.0, 2.0];
    let d = [5.0, 6.0, 7.0];
    for (c, want) in
        [(1, vec![0.0, 5.0, 6.0]), (2, vec![0.0, 1.0, 5.0]), (3, vec![0.0, 1.0, 2.0]), (9, vec![0.0, 1.0, 2.0])]
    {
        assert_eq!(fifo_start(&a, &d, c), want, "c={c}");
    }
    // first come, first served: a job never starts before the one ahead of it
    assert_eq!(fifo_start(&[0.0, 1.0, 1.5, 2.0], &[10.0, 3.0, 12.0, 4.0], 2), vec![0.0, 1.0, 3.0, 10.0]);
}

#[test]
fn queue_order_ties() {
    let a = [0.02, 0.0, 0.04, 5.0, 9.0, 9.03];
    let d = [1.0, 9.0, 3.0, 6.0, 12.0, 10.0];
    assert_eq!(queue_order(&a, &d), vec![0, 2, 1, 3, 5, 4]);
}

#[test]
fn infer_workers_by_hand() {
    let (mut a, mut d) = (Vec::new(), Vec::new());
    for k in 0..5 {
        let base = 100.0 * k as f64;
        a.extend([base, base + 1.0]);
        d.extend([base + 10.0, base + 5.0]);
    }
    let q = infer_workers(&a, &d, 0);
    assert!(q.workers == 2 && q.contradictions == 0 && q.max_in_system == 2 && !q.identified, "{q:?}");
    assert!(q.refuted_by.get(&1) == Some(&"contradictions") && q.refuted_below == 0.5);
    let q1 = infer_workers(&a, &d, 1);
    assert!(q1.workers == 1 && q1.contradictions == 5 && q1.waited == 5, "fixed: {q1:?}");
}

/// The reference implementation's outputs (testdata/fifo_golden.json): queue order, every start of service,
/// worker count, contradictions, waits and shortfall.
#[test]
fn fifo_golden() {
    let Some(td) = go_testdata() else {
        return;
    };
    let g: Value = serde_json::from_str(&common::read(&td.join("fifo_golden.json"))).unwrap();
    let cases = g["cases"].as_array().unwrap();
    assert!(cases.len() >= 5);
    let close = |got: f64, want: &Value| -> bool {
        if want.is_null() {
            return got.is_nan();
        }
        let w = want.as_f64().unwrap();
        (got - w).abs() <= 1e-9 * w.abs().max(1.0)
    };
    for c in cases {
        let name = c["name"].as_str().unwrap();
        let (a, d) = (nums(&c["a"]), nums(&c["d"]));
        let q = infer_workers(&a, &d, 0);
        let order: Vec<usize> = c["order"].as_array().unwrap().iter().map(|x| x.as_u64().unwrap() as usize).collect();
        assert_eq!(q.order, order, "{name}: queue order");
        assert_eq!(q.b, nums(&c["b"]), "{name}: start of service");
        let ident = c["identified"].as_bool().unwrap();
        assert!(
            q.workers == c["workers"].as_i64().unwrap()
                && q.jobs as i64 == c["jobs"].as_i64().unwrap()
                && q.contradictions == c["contradictions"].as_i64().unwrap()
                && q.enough_waits == ident
                && q.identified == ident
                && q.max_in_system == c["max_in_system"].as_i64().unwrap()
                && q.waited as i64 == c["waited"].as_i64().unwrap(),
            "{name}: {q:?}"
        );
        assert!(
            close(q.shortfall_z, &c["shortfall_z"]) && close(q.shortfall_rel, &c["shortfall_rel"]),
            "{name}: shortfall"
        );
        assert!(close(q.refuted_below, &c["refuted_below"]), "{name}: refuted below");
        assert_eq!(refuted(&q), json_map(&c["refuted_by"]), "{name}: refuted by");
        if let Some(f) = c["fifo"].as_object() {
            for (k, want) in f {
                let kk: usize = k.parse().unwrap();
                assert_eq!(fifo_start(&q.a, &q.d, kk), nums(want), "{name}: start of service with {kk} workers");
            }
        }
    }
    eprintln!("fifo golden: {} cases", cases.len());
}

fn fifo_case<'v>(cases: &'v [Value], name: &str) -> &'v Value {
    cases.iter().find(|c| c["name"].as_str() == Some(name)).unwrap_or_else(|| panic!("no case {name}"))
}

#[test]
fn infer_workers_faster_than_jitter() {
    let Some(fx) = fixtures() else {
        return;
    };
    let v: Value = serde_json::from_str(&common::gunzip(&fx.join("fifo_cases.json.gz"))).unwrap();
    let c = fifo_case(v.as_array().unwrap(), "faster-than-jitter");
    let (a, d) = (nums(&c["a"]), nums(&c["d"]));
    let b1 = fifo_start(&a, &d, 1);
    for i in 0..b1.len() {
        assert!(b1[i] - a[i] <= fifo::JITTER_MS && d[i] - b1[i] >= -fifo::JITTER_MS, "job {i}");
    }
    let q = infer_workers(&a, &d, 0);
    assert!(q.workers >= 2 && q.refuted_by.get(&1) == Some(&"brief-wait shortfall") && !q.identified, "{q:?}");
    let s: f64 = q.b.iter().zip(&q.d).map(|(b, d)| d - b).sum();
    let m = s / q.b.len() as f64;
    assert!((m - 0.12).abs() <= 0.02 * 0.12, "service time {m}");
    assert_queue_eq("faster-than-jitter", &q, &c["q"]);
}

#[test]
fn reconstruct_queues_small_pods() {
    let mut v = Vec::new();
    let mut add = |pod: i32, svc: i32, n: u64| {
        for i in 0..n {
            let st = i * 10_000_000;
            v.push(VisitRec { pod, svc, start: st, rel: st + 2_000_000, alt: 0, own: 2.0, early: false });
        }
    };
    add(0, 0, 25);
    add(1, 0, 5);
    add(2, 1, 5);
    add(3, 1, 6);
    let q = fifo::reconstruct_queues(&v, 2, 4, &BTreeMap::new());
    let (q0, q1) = (q[0].as_ref().unwrap(), q[1].as_ref().unwrap());
    assert!(q0.pods.len() == 1 && q0.jobs == 25, "service 0: the 25-job pod only");
    assert!(q1.pods.len() == 2 && q1.jobs == 11, "service 1: both small pods");
    assert!(q0.workers == 1 && (q0.rel_mean - 2.0).abs() <= 1e-9 && q0.wait_mean == 0.0);
}

#[test]
fn max_in_system_counts_instant_jobs() {
    let a = [0.0, 1.0, 2.0, 3.0];
    let d = [10.0, 1.0, 2.0, 3.0];
    assert_eq!(max_in_system(&a, &d), 2);
    let (mut aa, mut dd) = (Vec::new(), Vec::new());
    for g in 0..10 {
        for i in 0..4 {
            aa.push(a[i] + 50.0 * g as f64);
            dd.push(d[i] + 50.0 * g as f64);
        }
    }
    let q = infer_workers(&aa, &dd, 0);
    assert!(q.workers == 2 && q.contradictions == 0, "{q:?}");
    assert_eq!(max_in_system(&[0.0, 1.0, 1.0], &[1.0, 2.0, 3.0]), 2);
}

// ---- workers_search_test.go

/// The jump search gives the linear search's answer (same count, same refutations, same contradictions one
/// below), on Go's six pools; contradictions and waits never rise with the count; and the queue is Go's.
#[test]
fn worker_search_matches_linear() {
    let Some(fx) = fixtures() else {
        return;
    };
    let v: Value = serde_json::from_str(&common::gunzip(&fx.join("fifo_cases.json.gz"))).unwrap();
    let mut n = 0;
    for c in v.as_array().unwrap() {
        let name = c["name"].as_str().unwrap();
        if !name.starts_with("search: ") {
            continue;
        }
        n += 1;
        let (a, d) = (nums(&c["a"]), nums(&c["d"]));
        let order = queue_order(&a, &d);
        let aq: Vec<f64> = order.iter().map(|&k| a[k]).collect();
        let dq: Vec<f64> = order.iter().map(|&k| d[k]).collect();
        let bound = max_in_system(&aq, &dq).min(fifo::MAX_WORKERS_FIFO);
        let (want, why, bad) = fifo::testing::linear_workers(&aq, &dq, bound);
        let q = infer_workers(&a, &d, 0);
        let why_s: BTreeMap<String, String> = why.iter().map(|(k, v)| (k.to_string(), v.to_string())).collect();
        assert!(
            q.workers == want
                && refuted(&q) == why_s
                && q.contradictions == bad[&want]
                && (want <= 1 || q.refuted_below == bad[&(want - 1)] as f64 / a.len() as f64),
            "{name}: got {} workers {:?}; linear {want} {why_s:?}",
            q.workers,
            refuted(&q)
        );
        // Go's linear search on the same pool
        let l = &c["linear"];
        assert_eq!(bound, l["bound"].as_i64().unwrap(), "{name}: bound");
        assert_eq!(want, l["workers"].as_i64().unwrap(), "{name}: linear workers");
        assert_eq!(why_s, json_map(&l["why"]), "{name}: linear refutations");
        let gbad: BTreeMap<i64, i64> =
            l["bad"].as_object().unwrap().iter().map(|(k, v)| (k.parse().unwrap(), v.as_i64().unwrap())).collect();
        assert_eq!(bad, gbad, "{name}: linear contradictions");
        assert_eq!(
            fifo::testing::search_rebuilds(&aq, &dq, bound) as i64,
            l["fast_rebuilds"].as_i64().unwrap(),
            "{name}: rebuilds"
        );
        // the proven parts, at every count
        let (mut pb, mut pw) = (i64::MAX, usize::MAX);
        for (c, (b, w, _)) in fifo::testing::every_count(&aq, &dq, bound).into_iter().enumerate() {
            assert!(b <= pb && w <= pw, "{name}: at {} workers contradictions or waits rose", c + 1);
            pb = b;
            pw = w;
        }
        assert_queue_eq(name, &q, &c["q"]);
    }
    assert_eq!(n, 6);
}

#[test]
fn unbounded_pool_is_a_lower_bound() {
    let Some(fx) = fixtures() else {
        return;
    };
    let v: Value = serde_json::from_str(&common::gunzip(&fx.join("fifo_cases.json.gz"))).unwrap();
    let cases = v.as_array().unwrap();
    let c = fifo_case(cases, "unbounded");
    let (a, d) = (nums(&c["a"]), nums(&c["d"]));
    let q = infer_workers(&a, &d, 0);
    assert!(!q.identified && q.enough_waits, "want a lower bound: {} {}", q.identified, q.enough_waits);
    assert!(q.workers >= q.max_in_system - 40 && q.workers <= q.max_in_system);
    let order = queue_order(&a, &d);
    let aq: Vec<f64> = order.iter().map(|&k| a[k]).collect();
    let dq: Vec<f64> = order.iter().map(|&k| d[k]).collect();
    assert!(fifo::testing::search_rebuilds(&aq, &dq, q.max_in_system.min(fifo::MAX_WORKERS_FIFO)) <= 60);
    assert_queue_eq("unbounded", &q, &c["q"]);
    let c = fifo_case(cases, "three-workers");
    let q = infer_workers(&nums(&c["a"]), &nums(&c["d"]), 0);
    assert!(q.workers == 3 && q.identified);
    assert_queue_eq("three-workers", &q, &c["q"]);
}

// ---- structure_test.go

/// The stage template and its shares equal the reference implementation's (testdata/stage_golden.json).
#[test]
fn stage_golden() {
    let Some(td) = go_testdata() else {
        return;
    };
    let doc: Value = serde_json::from_str(&common::read(&td.join("stage_golden.json"))).unwrap();
    let cases = doc["cases"].as_array().unwrap();
    assert!(cases.len() >= 10);
    for c in cases {
        let name = c["name"].as_str().unwrap();
        let mut names: Vec<String> = Vec::new();
        for s in c["shapes"].as_array().unwrap() {
            for g in s["stages"].as_array().unwrap() {
                for n in g.as_array().unwrap() {
                    let n = n.as_str().unwrap().to_string();
                    if !names.contains(&n) {
                        names.push(n);
                    }
                }
            }
        }
        names.sort();
        let id = |n: &str| names.iter().position(|x| x == n).unwrap() as i32;
        let mut sigs: BTreeMap<String, i64> = BTreeMap::new();
        for s in c["shapes"].as_array().unwrap() {
            let sig: Vec<Vec<i32>> = s["stages"]
                .as_array()
                .unwrap()
                .iter()
                .map(|g| {
                    let mut st: Vec<i32> = g.as_array().unwrap().iter().map(|n| id(n.as_str().unwrap())).collect();
                    st.sort();
                    st
                })
                .collect();
            if !sig.is_empty() {
                *sigs.entry(key(&sig)).or_insert(0) += s["visits"].as_i64().unwrap();
            }
        }
        let got = stage_template(&sigs, c["nsp"].as_i64().unwrap());
        let exp = &c["expected"];
        match (got, exp.is_null()) {
            (None, true) => continue,
            (None, false) | (Some(_), true) => {
                panic!("{name}: template found {}, the reference {}", !exp.is_null(), !exp.is_null())
            }
            (Some((tm, ran, fit)), false) => {
                let gs: Vec<Vec<String>> =
                    tm.iter().map(|g| g.iter().map(|&x| names[x as usize].clone()).collect()).collect();
                let ws: Vec<Vec<String>> = exp["stages"]
                    .as_array()
                    .unwrap()
                    .iter()
                    .map(|g| g.as_array().unwrap().iter().map(|n| n.as_str().unwrap().to_string()).collect())
                    .collect();
                assert_eq!(gs, ws, "{name}: template");
                assert!((fit - exp["fit"].as_f64().unwrap()).abs() <= 1e-12, "{name}: fit");
                for (j, r) in ran.iter().enumerate() {
                    assert!((r - exp["ran"][j].as_f64().unwrap()).abs() <= 1e-12, "{name}: stage {j} ran");
                }
            }
        }
    }
    eprintln!("stage golden: {} cases", cases.len());
}

// ---- split_test.go

#[test]
fn even_split_values() {
    let Some(fx) = fixtures() else {
        return;
    };
    let v: Value = serde_json::from_str(&common::gunzip(&fx.join("split_cases.json.gz"))).unwrap();
    let mut worst = 0.0f64;
    let mut exact = 0;
    let closed = v["closed"].as_array().unwrap();
    for (i, c) in closed.iter().enumerate() {
        let n: Vec<i64> = c["n"].as_array().unwrap().iter().map(|x| x.as_i64().unwrap()).collect();
        let got = even_split_p(&n);
        assert_eq!(got.is_some(), c["ok"].as_bool().unwrap(), "{n:?}: read");
        let Some(p) = got else { continue };
        let gp = num(&c["p"]);
        if i < 5 {
            // TestEvenSplitPValue: the closed forms of the chi-square tail
            let want = num(&c["want"]);
            assert!((p - want).abs() <= 1e-12 * want + 1e-15, "{n:?}: p {p} want {want}");
        } else {
            // TestEvenSplitThreshold
            assert_eq!(p < SPLIT_P, i < 7, "{n:?}: uneven");
        }
        if p.to_bits() == gp.to_bits() {
            exact += 1;
        }
        worst = worst.max((p - gp).abs() / gp.abs().max(1e-300));
    }
    // TestEvenSplitFalseAlarms, on Go's draws
    let alarms = v["alarms"].as_array().unwrap();
    let (mut below5, mut flagged) = (0, 0);
    for c in alarms {
        let n: Vec<i64> = c["n"].as_array().unwrap().iter().map(|x| x.as_i64().unwrap()).collect();
        let p = even_split_p(&n).expect("read");
        let gp = num(&c["p"]);
        if p.to_bits() == gp.to_bits() {
            exact += 1;
        }
        if gp > 0.0 {
            worst = worst.max((p - gp).abs() / gp);
        }
        if p < 0.05 {
            below5 += 1;
        }
        if p < SPLIT_P {
            flagged += 1;
        }
    }
    let share = below5 as f64 / alarms.len() as f64;
    assert!((share - 0.05).abs() <= 0.006, "{share} of even random splits below 0.05");
    assert_eq!(flagged, 0);
    eprintln!(
        "even-split p-values: {} of {} bit-equal to Go's, max relative difference {worst:.2e}",
        exact,
        alarms.len() + closed.iter().filter(|c| c["ok"].as_bool().unwrap()).count()
    );
    assert!(worst < 1e-12, "p-values differ from Go's by {worst:e}");
}

#[test]
fn pod_split_by_hand() {
    let names: Vec<String> = ["api-b", "x-0", "api-a", "api-c"].iter().map(|s| s.to_string()).collect();
    let mut visits = vec![300i64, 999, 100, 0];
    let pods = [0, 2];
    let (by, p, shares) = pod_split(&pods, &names, &visits);
    assert!(by.len() == 2 && by[0].pod == "api-a" && by[0].visits == 100 && by[1].share == 0.75, "{by:?}");
    let p = p.unwrap();
    assert!(p < SPLIT_P && shares == Some(vec![0.25, 0.75]));
    let w = split_warning("api", &by, p);
    for s in ["api-a 25.0%", "api-b 75.0%", "p < 1e-12", "per connection", "change prediction keeps"] {
        assert!(w.contains(s), "{w} lacks {s}");
    }
    visits[0] = 105;
    let (_, p, shares) = pod_split(&pods, &names, &visits);
    assert!(p.is_some() && shares.is_none(), "a 51/49 split is even");
    visits[0] = 10;
    visits[2] = 12;
    let (by, p, shares) = pod_split(&pods, &names, &visits);
    assert!(by.len() == 2 && p.is_none() && shares.is_none());
}

// ---- workers_test.go (the rise estimator)

fn byk(c: &Value) -> ByK {
    let mut h = ByK::default();
    for (i, x) in c["n"].as_array().unwrap().iter().enumerate() {
        h.n[i] = x.as_i64().unwrap();
    }
    for (i, x) in nums(&c["sum"]).into_iter().enumerate() {
        h.sum[i] = x;
    }
    for (i, x) in nums(&c["sq"]).into_iter().enumerate() {
        h.sq[i] = x;
    }
    h.peak = c["peak"].as_i64().unwrap();
    h
}

#[test]
fn rise_estimator_cases() {
    let Some(fx) = fixtures() else {
        return;
    };
    let v: Value = serde_json::from_str(&common::gunzip(&fx.join("byk_cases.json.gz"))).unwrap();
    for c in v.as_array().unwrap() {
        let name = c["name"].as_str().unwrap();
        let h = byk(c);
        let (w, sat, free, ok) = rise::workers_from_k(&h);
        let o = &c["workers_from_k"];
        assert_eq!(w, o["workers"].as_i64().unwrap(), "{name}: workers");
        assert_eq!(sat, o["saturated"].as_bool().unwrap(), "{name}: saturated");
        assert_eq!(ok, o["ok"].as_bool().unwrap(), "{name}: ok");
        for (k, x) in
            [("n", free.n), ("sum", free.sum), ("sq", free.sq), ("mean", free.mean()), ("variance", free.variance())]
        {
            assert!(same(x, num(&o[k])), "{name}: free {k} {x:e} vs go {}", o[k]);
        }
        for pb in c["pool_below"].as_array().unwrap() {
            let cc = pb["c"].as_i64().unwrap();
            let (m, ok) = rise::pool_below(&h, cc);
            assert_eq!(ok, pb["ok"].as_bool().unwrap(), "{name}: pool below {cc}");
            assert!(
                same(m.n, num(&pb["n"])) && same(m.sum, num(&pb["sum"])) && same(m.sq, num(&pb["sq"])),
                "{name}: pool {cc}"
            );
        }
        // the Go tests' own assertions
        match name {
            "noisy-baseline" => {
                assert!(ok && !sat && w == 4);
                assert!((free.mean() - 113.0).abs() / 113.0 <= 0.02);
                assert_eq!(free.n, (363 + 1130 + 1852 + 7504) as f64);
            }
            "single-worker" => {
                assert!(ok && sat && w == 1);
                assert!((free.mean() - 100.0).abs() / 100.0 <= 0.05);
            }
            "four-workers" => {
                assert!(ok && sat && w == 4);
                assert_eq!(free.n, (150 + 600 + 1500 + 3000) as f64);
                assert!((free.variance() / free.n).sqrt() <= 35.0 / 150f64.sqrt() / 3.0);
            }
            "pool-below" => {
                assert!(!rise::pool_below(&h, 2).1);
                let (m, ok) = rise::pool_below(&h, 3);
                assert!(ok && m.n == 120.0);
            }
            "eight-workers" => {
                assert!(ok && sat && w == 8);
                assert!((free.mean() - 100.0).abs() / 100.0 <= 0.02);
            }
            "too-few" => assert!(!ok),
            _ => panic!("unknown case {name}"),
        }
    }
}

// ---- the Go fmt verbs the messages use

/// gofmt's %.3g, %.1g, %.2f, %.0f, %.1f, %.4f, %.3f, %v and JSON number equal Go's fmt and encoding/json on 20082
/// values (ties, signed zeros,
/// infinities, NaN, subnormals, every magnitude from 1e-20 to 1e20; RBFAST_FIXTURES/gofmt_cases.jsonl.gz, made by
/// a Go program).
#[test]
fn go_fmt_verbs() {
    use rbfast_infer::gofmt;
    let Some(fx) = fixtures() else {
        return;
    };
    let path = fx.join("gofmt_cases.jsonl.gz");
    if !path.exists() {
        eprintln!("gofmt fixture not found: skipped");
        return;
    }
    let mut n = 0;
    let mut bad = Vec::new();
    for line in common::gunzip(&path).lines() {
        let row: Vec<String> = serde_json::from_str(line).unwrap();
        let x = f64::from_bits(row[0].parse().unwrap());
        let got = [
            gofmt::g(x, 3),
            gofmt::g(x, 1),
            gofmt::f(x, 2),
            gofmt::f(x, 0),
            gofmt::f(x, 1),
            gofmt::f(x, 4),
            gofmt::f(x, 3),
            gofmt::v(x),
        ];
        for (k, g) in got.iter().enumerate() {
            n += 1;
            if *g != row[k + 1] {
                bad.push(format!("{x:e} verb {k}: go {:?} rust {g:?}", row[k + 1]));
            }
        }
        // encoding/json (empty where Go refuses: NaN and the infinities)
        n += 1;
        let j = gofmt::json_num(x).unwrap_or_default();
        if j != row[9] {
            bad.push(format!("{x:e} json: go {:?} rust {j:?}", row[9]));
        }
    }
    eprintln!("go fmt: {n} formatted values compared");
    assert!(bad.is_empty(), "{} differ:\n{}", bad.len(), bad.iter().take(30).cloned().collect::<Vec<_>>().join("\n"));
}
