// SPDX-License-Identifier: Apache-2.0

//! Go's behaviour on edge cases, written by a Go program made for the comparison (not published; its output is
//! testdata/go_edge.jsonl, from Go 1.27.2 on linux/arm64): ParseTopology on odd and invalid documents (with
//! MarshalTopology's bytes, the order and the visit ratios when it succeeds), the model on invalid and extreme
//! inputs, and the CLI's --patch parser. Results compare bit for bit (on aarch64; elsewhere within
//! common::TOLERANCE) and error texts word for word, except JSON decoding errors (a type mismatch or a syntax
//! error), where only the failure is compared: their texts are encoding/json's own.

mod common;

use rbfast_math::{model, parse_topology, Config, ModelResult, Patch};
use serde_json::Value;

fn hx(v: &Value) -> Option<Vec<f64>> {
    v.as_array().map(|a| {
        a.iter()
            .map(|s| f64::from_bits(u64::from_str_radix(s.as_str().unwrap(), 16).unwrap()))
            .collect()
    })
}

fn same_vec(got: Option<&[f64]>, want: &Value) -> bool {
    match (got, hx(want)) {
        (None, None) => true,
        (Some(g), Some(w)) => {
            g.len() == w.len() && g.iter().zip(&w).all(|(a, b)| common::same(*a, *b))
        }
        _ => false,
    }
}

fn same_res(got: &ModelResult, want: &Value) -> bool {
    got.stable == want["stable"].as_bool().unwrap()
        && same_vec(Some(&got.rho), &want["rho"])
        && same_vec(Some(&got.lam), &want["lam"])
        && same_vec(got.ca2.as_deref(), &want["ca2"])
        && same_vec(got.r.as_deref(), &want["r"])
        && same_vec(got.v.as_deref(), &want["v"])
        && same_vec(got.l.as_deref(), &want["l"])
}

#[test]
fn edge_cases_match_go() {
    let text = std::fs::read_to_string(concat!(
        env!("CARGO_MANIFEST_DIR"),
        "/testdata/go_edge.jsonl"
    ))
    .unwrap();
    let mut bad = Vec::new();
    let mut n = 0;
    for line in text.lines() {
        let c: Value = serde_json::from_str(line).unwrap();
        n += 1;
        let kind = c["kind"].as_str().unwrap();
        let want_err = c["error"].as_str().unwrap_or("");
        match kind {
            "parse" => {
                let doc = c["doc"].as_str().unwrap();
                let got = parse_topology(doc.as_bytes());
                match (&got, want_err.is_empty()) {
                    (Err(e), false) => {
                        // JSON type errors are Go 1.27's text too; syntax errors are serde_json's (the CLI checks the
                        // syntax with Go's texts before it parses)
                        let syntax = c["json_error"].as_bool().unwrap()
                            && !want_err.starts_with("json: cannot unmarshal");
                        if !syntax && e.0 != want_err {
                            bad.push(format!("parse {doc}: error {:?}, Go {:?}", e.0, want_err));
                        }
                    }
                    (Ok(t), true) => {
                        let m = rbfast_math::marshal_topology(t).map_err(|e| e.0);
                        let want_m = c["marshal"].as_str().unwrap();
                        if m.as_deref() != Ok(want_m) {
                            bad.push(format!("parse {doc}: marshal\n{m:?}\nGo\n{want_m}"));
                        }
                        let order: Vec<usize> = c["order"]
                            .as_array()
                            .unwrap()
                            .iter()
                            .map(|x| x.as_u64().unwrap() as usize)
                            .collect();
                        if t.order() != order.as_slice() {
                            bad.push(format!("parse {doc}: order {:?}, Go {order:?}", t.order()));
                        }
                        if !same_vec(Some(&t.visit_ratios()), &c["visits"]) {
                            bad.push(format!("parse {doc}: visit ratios differ"));
                        }
                    }
                    (Err(e), true) => {
                        bad.push(format!("parse {doc}: error {:?}, Go parsed it", e.0))
                    }
                    (Ok(_), false) => bad.push(format!("parse {doc}: parsed, Go: {want_err}")),
                }
            }
            "model" => {
                let t = parse_topology(c["topo"].as_str().unwrap().as_bytes()).unwrap();
                let lam = hx(&Value::Array(vec![c["lam"].clone()])).unwrap()[0];
                let w = hx(&Value::Array(vec![c["w"].clone()])).unwrap()[0];
                let cfg = Config {
                    arrival_weight: w,
                    matched_max: c["mm"].as_bool().unwrap(),
                };
                let ds = hx(&c["ds"]);
                let shift: Option<Vec<bool>> = c["shift"]
                    .as_array()
                    .map(|a| a.iter().map(|b| b.as_bool().unwrap()).collect());
                let glue = hx(&c["glue"]);
                let i = c["i"].as_u64().unwrap();
                if c["patch"].as_bool().unwrap() {
                    let got = model::change_patch_with(&t, lam, &Patch { ds, shift, glue }, cfg);
                    match got {
                        Err(e) if e.0 == want_err => {}
                        Ok(d) if want_err.is_empty() => {
                            if d.stable != c["stable"].as_bool().unwrap()
                                || !same_res(&d.base, &c["base"])
                                || !same_res(&d.patched, &c["patched"])
                                || !same_vec(d.dl.as_deref(), &c["dl"])
                            {
                                bad.push(format!("model case {i}: change differs"));
                            }
                        }
                        other => {
                            bad.push(format!("model case {i}: {other:?}, Go error {want_err:?}"))
                        }
                    }
                } else {
                    let got = model::analytic_with(&t, lam, ds.as_deref(), cfg);
                    match got {
                        Err(e) if e.0 == want_err => {}
                        Ok(r) if want_err.is_empty() => {
                            if !same_res(&r, &c["base"]) {
                                bad.push(format!("model case {i}: result differs: {r:?}"));
                            }
                        }
                        other => {
                            bad.push(format!("model case {i}: {other:?}, Go error {want_err:?}"))
                        }
                    }
                }
            }
            "patch" => {
                let chain = parse_topology(
                    br#"{"services": [{"name": "a", "s": 2, "children": ["b", {"name": "c", "p": 0.5}]}, {"name": "b", "s": 3, "servers": 2, "workers": 2, "routing": "random", "glue": 0.4, "glue_cs2": 0.8},
	  {"name": "c", "s": 1.5, "parallel": true, "children": ["d", "e"], "branch_corr": 0.4}, {"name": "d", "s": 4, "shares": [0.7, 0.3], "routing": "random", "cs2": 2.2}, {"name": "e", "s": 0.5, "delay": true}], "entry": {"a": 1}}"#,
                )
                .unwrap();
                let spec = c["spec"].as_str().unwrap();
                match model::parse_patch(spec, &chain) {
                    Err(e) if e == want_err => {}
                    Ok((p, _)) if want_err.is_empty() => {
                        let shift: Option<Vec<bool>> = c["shift"]
                            .as_array()
                            .map(|a| a.iter().map(|b| b.as_bool().unwrap()).collect());
                        if !same_vec(p.ds.as_deref(), &c["ds"])
                            || p.shift != shift
                            || !same_vec(p.glue.as_deref(), &c["glue"])
                        {
                            bad.push(format!("patch {spec:?}: {p:?}"));
                        }
                    }
                    other => bad.push(format!("patch {spec:?}: {other:?}, Go error {want_err:?}")),
                }
            }
            _ => panic!("kind {kind}"),
        }
    }
    eprintln!("{n} edge cases, {} differ from Go", bad.len());
    common::report("edge cases");
    assert!(bad.is_empty(), "{}", bad.join("\n"));
}
