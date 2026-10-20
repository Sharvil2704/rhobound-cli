// SPDX-License-Identifier: Apache-2.0

//! The NaN and stability rules on inputs that get past validation: Go's results (from a Go program made for the
//! comparison, not published; testdata/go_edited.jsonl, Go 1.27.2 linux/arm64) for a topology edited after ParseTopology, as Go's TestNaNIsNeverStable edits it:
//! NaN, infinite, negative or zero fields, a bad or empty routing, broken replica shares, a NaN or out-of-range
//! call probability or entry weight, and extreme loads. For each edit and both configs: AnalyticWith,
//! ChangePatchWith with a scaled and with a shifted-plus-glue patch, and MaxRho, compared bit for bit and error
//! text for error text (bit for bit on aarch64; elsewhere within common::TOLERANCE).

mod common;

use rbfast_math::{model, parse_topology, Config, ModelResult, Patch, Topology};
use serde_json::Value;

fn hex(v: &Value) -> f64 {
    f64::from_bits(u64::from_str_radix(v.as_str().unwrap(), 16).unwrap())
}

/// NaN payloads are not compared (Go and Rust may differ in the payload, never in NaN-ness).
fn same_vec(got: Option<&[f64]>, want: &Value) -> bool {
    let want: Option<Vec<f64>> = want.as_array().map(|a| a.iter().map(hex).collect());
    match (got, want) {
        (None, None) => true,
        (Some(g), Some(w)) => {
            g.len() == w.len() && g.iter().zip(&w).all(|(a, b)| common::same(*a, *b))
        }
        _ => false,
    }
}

fn same_res(got: &ModelResult, want: &Value) -> bool {
    !want.is_null()
        && got.stable == want["stable"].as_bool().unwrap()
        && same_vec(Some(&got.rho), &want["rho"])
        && same_vec(Some(&got.lam), &want["lam"])
        && same_vec(got.ca2.as_deref(), &want["ca2"])
        && same_vec(got.r.as_deref(), &want["r"])
        && same_vec(got.v.as_deref(), &want["v"])
        && same_vec(got.l.as_deref(), &want["l"])
}

fn apply(t: &mut Topology, e: &Value) {
    let i = e["svc"].as_u64().unwrap() as usize;
    let field = e["field"].as_str().unwrap();
    let f = || hex(&e["f"]);
    let int = || e.get("i").and_then(Value::as_i64).unwrap_or(0);
    let s = &mut t.services[i];
    match field {
        "s" => s.s = f(),
        "cs2" => s.cs2 = f(),
        "hop" => s.hop = f(),
        "glue" => s.glue = f(),
        "glue_cs2" => s.glue_cs2 = f(),
        "branch_corr" => s.branch_corr = f(),
        "servers" => s.servers = int(),
        "workers" => s.workers = int(),
        "routing" => s.routing = e.get("s").and_then(Value::as_str).unwrap_or("").to_string(),
        "shares" => s.shares = Some(e["shares"].as_array().unwrap().iter().map(hex).collect()),
        "call_p" => s.calls[0].p = f(),
        "entry" => {
            t.entry.insert(i, f());
        }
        other => panic!("edit {other}"),
    }
}

#[test]
fn edited_topologies_match_go() {
    let text = std::fs::read_to_string(concat!(
        env!("CARGO_MANIFEST_DIR"),
        "/testdata/go_edited.jsonl"
    ))
    .unwrap();
    let mut bad = Vec::new();
    let mut n = 0;
    for line in text.lines() {
        let c: Value = serde_json::from_str(line).unwrap();
        n += 1;
        let name = format!(
            "{} ({})",
            c["name"].as_str().unwrap(),
            if c["mm"].as_bool().unwrap() {
                "default"
            } else {
                "plain"
            }
        );
        let mut t = parse_topology(c["topo"].as_str().unwrap().as_bytes()).unwrap();
        if let Some(edits) = c["edits"].as_array() {
            for e in edits {
                apply(&mut t, e);
            }
        }
        let lam = hex(&c["lam"]);
        let cfg = Config {
            arrival_weight: hex(&c["w"]),
            matched_max: c["mm"].as_bool().unwrap(),
        };
        let want_err = c["error"].as_str().unwrap();
        match model::analytic_with(&t, lam, None, cfg) {
            Err(e) if e.0 == want_err => {}
            Ok(r) if want_err.is_empty() => {
                if !same_res(&r, &c["base"]) {
                    bad.push(format!("{name}: AnalyticWith differs: {r:?}"));
                }
                let (mr, at) = r.max_rho();
                let want_at = c["max_rho_at"].as_i64().unwrap();
                if !same_vec(Some(&[mr]), &Value::Array(vec![c["max_rho"].clone()]))
                    || at.map_or(-1, |a| a as i64) != want_at
                {
                    bad.push(format!("{name}: MaxRho ({mr}, {at:?})"));
                }
            }
            other => bad.push(format!(
                "{name}: AnalyticWith {other:?}, Go error {want_err:?}"
            )),
        }
        let patches = [
            (
                "change",
                Patch {
                    ds: Some(vec![0.0, 0.0, 1.0]),
                    ..Default::default()
                },
            ),
            (
                "shift",
                Patch {
                    ds: Some(vec![0.0, 1.0, 0.0]),
                    shift: Some(vec![false, true, false]),
                    glue: Some(vec![0.5, 0.0, 0.0]),
                },
            ),
        ];
        for (key, p) in patches {
            let want_err = c[format!("{key}_error")].as_str().unwrap();
            let want = &c[key];
            match model::change_patch_with(&t, lam, &p, cfg) {
                Err(e) if e.0 == want_err => {}
                Ok(d) if want_err.is_empty() => {
                    if d.stable != want["stable"].as_bool().unwrap()
                        || !same_res(&d.base, &want["base"])
                        || !same_res(&d.patched, &want["patched"])
                        || !same_vec(d.dl.as_deref(), &want["dl"])
                    {
                        bad.push(format!("{name}: ChangePatchWith ({key}) differs"));
                    }
                }
                other => bad.push(format!(
                    "{name}: ChangePatchWith ({key}) {other:?}, Go error {want_err:?}"
                )),
            }
        }
    }
    eprintln!("{n} edited-topology cases, {} differ from Go", bad.len());
    common::report("edited topologies");
    assert!(n >= 60);
    assert!(bad.is_empty(), "{}", bad.join("\n"));
}
