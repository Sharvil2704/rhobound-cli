// SPDX-License-Identifier: Apache-2.0
//! The Go unit tests that build spans (internal/infer/*_test.go without build tags), replayed: a copy of the Go
//! tree with a hook in infer.Run recorded every call those tests make (110 calls from 40 tests: the input Data as
//! the oracle's span dump, the options, and Go's result or refusal). Each is run here and must give Go's result:
//! the whole Inferred (topology, stats, counts, warnings) byte for byte, or the same refusal text. Since the Go
//! tests' assertions hold on Go's results, they hold on these. Skipped when RBFAST_REPLAY is unset (the
//! recording is not in the repository; rust/README.md says how it was made). Byte-identity is required on
//! aarch64 (the recording is Go's linux/arm64 output); elsewhere a result within 1e-9 relative passes.

mod common;

use std::collections::BTreeMap;

use rbfast_infer::{run, Options, SortMode};
use serde_json::Value;

#[test]
fn go_unit_test_runs_replayed() {
    let Some(rec) = common::replay_dir() else {
        return;
    };
    let mut dirs: Vec<_> = std::fs::read_dir(&rec).unwrap().filter_map(|e| e.ok().map(|e| e.path())).collect();
    dirs.sort();
    let mut failures = Vec::new();
    let mut by_test: BTreeMap<String, (usize, usize)> = BTreeMap::new();
    let (mut n_ok, mut n_refused, mut n_byte) = (0, 0, 0);
    for dir in &dirs {
        let name = dir.file_name().unwrap().to_string_lossy().to_string();
        let o: Value = serde_json::from_str(&common::read(&dir.join("options.json"))).unwrap();
        let test = o["test"].as_str().unwrap().to_string();
        let kept: f64 = o["kept_share"].as_str().unwrap().parse().unwrap();
        let mut workers = BTreeMap::new();
        if let Some(m) = o["workers"].as_object() {
            for (k, v) in m {
                workers.insert(k.clone(), v.as_i64().unwrap());
            }
        }
        let mut estimator = o["estimator"].as_str().unwrap().to_string();
        if estimator.is_empty() {
            estimator = o["env_estimator"].as_str().unwrap().to_string(); // what Go read from RHOBOUND_ESTIMATOR
        }
        let base = common::load(dir);
        let e = by_test.entry(test.clone()).or_default();
        e.0 += 1;
        let mut ok = true;
        for mode in [SortMode::GoExact, SortMode::Parallel] {
            let opt = Options {
                kept_share: kept,
                workers: workers.clone(),
                min_requests: o["min_requests"].as_i64().unwrap(),
                estimator: estimator.clone(),
                sort: mode,
            };
            let mut d = base.clone();
            let got = run(&mut d, &opt);
            let err_path = dir.join("inferred_error.txt");
            if err_path.exists() {
                let want = common::read(&err_path);
                match got {
                    Err(e) if format!("{e}\n") == want => {
                        if mode == SortMode::GoExact {
                            n_refused += 1;
                        }
                    }
                    Err(e) => {
                        ok = false;
                        failures.push(format!("{name} {mode:?}: refusal differs:\n  go:   {want}  rust: {e}"));
                    }
                    Ok(_) => {
                        ok = false;
                        failures.push(format!("{name} {mode:?}: Go refuses ({}), Rust does not", want.trim()));
                    }
                }
                continue;
            }
            let inf = match got {
                Ok(x) => x,
                Err(e) => {
                    ok = false;
                    failures.push(format!("{name} {mode:?}: Rust refuses: {e}"));
                    continue;
                }
            };
            let full = inf.to_json().unwrap().pretty() + "\n";
            let want = common::read(&dir.join("inferred_full.json"));
            if full == want {
                if mode == SortMode::GoExact {
                    n_byte += 1;
                    n_ok += 1;
                }
                continue;
            }
            let c = common::compare(
                &serde_json::from_str(&want).unwrap(),
                &serde_json::from_str(&full).unwrap(),
                1e-9,
                0.0,
            );
            if c.diffs.is_empty() && !common::bit_exact() {
                // not aarch64: within the tolerance is a pass (see common::same)
                if mode == SortMode::GoExact {
                    n_ok += 1;
                }
            } else if c.diffs.is_empty() {
                // both sort modes put ties in Go's order: anything short of Go's bytes is a failure
                ok = false;
                failures.push(format!(
                    "{name} {mode:?}: within 1e-9 but not byte-identical (max rel {:.2e} at {})",
                    c.max_rel, c.worst
                ));
            } else {
                ok = false;
                for d in c.diffs.iter().take(10) {
                    failures.push(format!("{name} {mode:?}: {d}"));
                }
            }
        }
        if ok {
            e.1 += 1;
        }
    }
    for (t, (n, ok)) in &by_test {
        eprintln!("{t:50} {ok}/{n} runs match");
    }
    eprintln!(
        "{} recorded runs: {} results ({} byte-identical), {} refusals with Go's text",
        dirs.len(),
        n_ok,
        n_byte,
        n_refused
    );
    assert!(failures.is_empty(), "{} failures:\n{}", failures.len(), failures.join("\n"));
}
