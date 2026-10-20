// SPDX-License-Identifier: Apache-2.0

//! Go's nesting limit (10000) through every path of the structured decoder, at the boundary and one past it.
//! The expected outcomes are what Go 1.27.2's otlp.ReadDir gave on the same inputs (probed with a Go program
//! made for the comparison).

use rbfast_otlp::read_dir;
use std::sync::atomic::{AtomicUsize, Ordering};

fn nest(n: usize) -> String {
    "[".repeat(n) + &"]".repeat(n)
}

const PRE_KV: &str =
    r#"{"resourceSpans":[{"scopeSpans":[{"spans":[{"attributes":[{"value":{"intValue":"#;
const POST_KV: &str = "}}]}]}]}]}\n";
const DEPTH: &str = "bad OTLP/JSON: exceeded max depth";
const RS_TYPE: &str = r#"struct { Resource struct { Attributes []otlp.keyValue "json:\"attributes\"" } "json:\"resource\""; ScopeSpans []struct { Spans []otlp.jsonSpan "json:\"spans\"" } "json:\"scopeSpans\"" }"#;

/// Reads one capture holding `body` in traces/`name`; Ok(spans skipped) or the error text.
fn read(name: &str, body: &str) -> Result<(usize, usize), String> {
    static N: AtomicUsize = AtomicUsize::new(0);
    let dir = std::path::Path::new(env!("CARGO_TARGET_TMPDIR")).join(format!(
        "rbfast-otlp-depth-{}-{}",
        std::process::id(),
        N.fetch_add(1, Ordering::SeqCst)
    ));
    std::fs::create_dir_all(dir.join("traces")).unwrap();
    std::fs::write(dir.join("traces").join(name), body).unwrap();
    let r = read_dir(&dir)
        .map(|d| (d.spans.len(), d.skipped))
        .map_err(|e| e.message.replace(dir.to_str().unwrap(), "CAP"));
    let _ = std::fs::remove_dir_all(&dir);
    r
}

fn type_err(what: &str, path: &str, ty: &str) -> String {
    let last_is_index = path
        .rsplit('.')
        .next()
        .unwrap()
        .bytes()
        .all(|c| c.is_ascii_digit());
    let into = if last_is_index {
        ""
    } else {
        "Go struct field "
    };
    format!(
        "bad OTLP/JSON: json: cannot unmarshal {what} into {into}jsonRequest.{path} of type {ty}"
    )
}

#[test]
fn depth_limit_like_go() {
    let span = |member: &str, n: usize| {
        format!(
            r#"{{"resourceSpans":[{{"scopeSpans":[{{"spans":[{{"{member}":{}}}]}}]}}]}}"#,
            nest(n)
        ) + "\n"
    };
    let ok1 = Ok((0, 1));
    type Case = (String, &'static str, String, Result<(usize, usize), String>);
    let cases: Vec<Case> = vec![
        ("intValue 9990".into(), "a.jsonl", format!("{PRE_KV}{}{POST_KV}", nest(9990)), ok1.clone()),
        ("intValue 9991".into(), "a.jsonl", format!("{PRE_KV}{}{POST_KV}", nest(9991)), Err(DEPTH.into())),
        (
            "anyValue unknown 9990".into(),
            "a.jsonl",
            format!(r#"{{"resourceSpans":[{{"scopeSpans":[{{"spans":[{{"attributes":[{{"value":{{"x":{}{POST_KV}"#, nest(9990)),
            ok1.clone(),
        ),
        (
            "anyValue unknown 9991".into(),
            "a.jsonl",
            format!(r#"{{"resourceSpans":[{{"scopeSpans":[{{"spans":[{{"attributes":[{{"value":{{"x":{}{POST_KV}"#, nest(9991)),
            Err(DEPTH.into()),
        ),
        (
            "attributes element 9992".into(),
            "a.jsonl",
            format!(r#"{{"resourceSpans":[{{"scopeSpans":[{{"spans":[{{"attributes":[{}]}}]}}]}}]}}"#, nest(9992)) + "\n",
            Err(type_err("array", "resourceSpans.0.scopeSpans.0.spans.0.attributes.0", "otlp.keyValue")),
        ),
        (
            "attributes element 9993".into(),
            "a.jsonl",
            format!(r#"{{"resourceSpans":[{{"scopeSpans":[{{"spans":[{{"attributes":[{}]}}]}}]}}]}}"#, nest(9993)) + "\n",
            Err(DEPTH.into()),
        ),
        (
            "resourceSpans element 9998".into(),
            "a.jsonl",
            format!(r#"{{"resourceSpans":[{}]}}"#, nest(9998)) + "\n",
            Err(type_err("array", "resourceSpans.0", RS_TYPE)),
        ),
        ("resourceSpans element 9999".into(), "a.jsonl", format!(r#"{{"resourceSpans":[{}]}}"#, nest(9999)) + "\n", Err(DEPTH.into())),
        (
            "resource 9997".into(),
            "a.jsonl",
            format!(r#"{{"resourceSpans":[{{"resource":{}}}]}}"#, nest(9997)) + "\n",
            Err(type_err("array", "resourceSpans.0.resource", r#"struct { Attributes []otlp.keyValue "json:\"attributes\"" }"#)),
        ),
        ("resource 9998".into(), "a.jsonl", format!(r#"{{"resourceSpans":[{{"resource":{}}}]}}"#, nest(9998)) + "\n", Err(DEPTH.into())),
        (
            "resource attributes 9996".into(),
            "a.jsonl",
            format!(r#"{{"resourceSpans":[{{"resource":{{"attributes":{}}}}}]}}"#, nest(9996)) + "\n",
            Err(type_err("array", "resourceSpans.0.resource.attributes.0", "otlp.keyValue")),
        ),
        (
            "resource attributes 9997".into(),
            "a.jsonl",
            format!(r#"{{"resourceSpans":[{{"resource":{{"attributes":{}}}}}]}}"#, nest(9997)) + "\n",
            Err(DEPTH.into()),
        ),
        (
            "kind 9993".into(),
            "a.jsonl",
            span("kind", 9993),
            Err(type_err("array", "resourceSpans.0.scopeSpans.0.spans.0.kind", "int")),
        ),
        ("kind 9994".into(), "a.jsonl", span("kind", 9994), Err(DEPTH.into())),
        (
            "startTimeUnixNano 9993".into(),
            "a.jsonl",
            span("startTimeUnixNano", 9993),
            Err(format!("bad OTLP/JSON: strconv.ParseUint: parsing \"{}\": invalid syntax", nest(9993))),
        ),
        ("startTimeUnixNano 9994".into(), "a.jsonl", span("startTimeUnixNano", 9994), Err(DEPTH.into())),
        ("span unknown member 9993".into(), "a.jsonl", span("events", 9993), ok1.clone()),
        ("span unknown member 9994".into(), "a.jsonl", span("events", 9994), Err(DEPTH.into())),
        (
            "spans 9995".into(),
            "a.jsonl",
            format!(r#"{{"resourceSpans":[{{"scopeSpans":[{{"spans":{}}}]}}]}}"#, nest(9995)) + "\n",
            Err(type_err("array", "resourceSpans.0.scopeSpans.0.spans.0", "otlp.jsonSpan")),
        ),
        (
            "spans 9996".into(),
            "a.jsonl",
            format!(r#"{{"resourceSpans":[{{"scopeSpans":[{{"spans":{}}}]}}]}}"#, nest(9996)) + "\n",
            Err(DEPTH.into()),
        ),
        (
            "stream 10000".into(),
            "a.json",
            nest(10000),
            Err("bad OTLP/JSON: json: cannot unmarshal array into Go value of type otlp.jsonRequest".into()),
        ),
        ("stream 10001".into(), "a.json", nest(10001), Err("CAP/traces/a.json: exceeded max depth".into())),
        (
            "top 10000".into(),
            "a.jsonl",
            nest(10000) + "\n",
            Err("bad OTLP/JSON: json: cannot unmarshal array into Go value of type otlp.jsonRequest".into()),
        ),
        ("top 10001".into(), "a.jsonl", nest(10001) + "\n", Err(DEPTH.into())),
        ("top unknown 9999".into(), "a.jsonl", format!(r#"{{"x":{}}}"#, nest(9999)) + "\n", Ok((0, 0))),
        ("top unknown 10000".into(), "a.jsonl", format!(r#"{{"x":{}}}"#, nest(10000)) + "\n", Err(DEPTH.into())),
        (
            "objects 9990".into(),
            "a.jsonl",
            format!("{PRE_KV}{}1{}{POST_KV}", r#"{"a":"#.repeat(9990), "}".repeat(9990)),
            ok1.clone(),
        ),
    ];
    for (name, file, body, want) in cases {
        assert_eq!(read(file, &body), want, "{name}");
    }
}
