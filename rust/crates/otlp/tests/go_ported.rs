// SPDX-License-Identifier: Apache-2.0

//! rhobound-cli's internal/otlp/otlp_test.go, ported test for test (same inputs, same expectations).

use rbfast_otlp::{read_dir, read_dir_with, ReadErrorKind, ReadOptions, KIND_CLIENT};
use std::collections::{BTreeMap, HashSet};
use std::io::Write;
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicUsize, Ordering};

const REQ: &str = concat!(
    r#"{"resourceSpans":[{"resource":{"attributes":[{"key":"service.name","value":{"stringValue":"api"}},"#,
    r#"{"key":"k8s.pod.name","value":{"stringValue":"api-1"}},{"key":"container.image.name","value":{"stringValue":"reg/api"}},"#,
    r#"{"key":"container.image.tag","value":{"stringValue":"1.2"}}]},"scopeSpans":[{"spans":["#,
    r#"{"traceId":"0102030405060708090a0b0c0d0e0f10","spanId":"1111111111111111","parentSpanId":"","kind":2,"#,
    r#""startTimeUnixNano":"1700000000000000000","endTimeUnixNano":"1700000000010000000"},"#,
    r#"{"traceId":"0102030405060708090a0b0c0d0e0f10","spanId":"2222222222222222","parentSpanId":"1111111111111111","kind":3,"#,
    r#""startTimeUnixNano":1700000000002000000,"endTimeUnixNano":"1700000000008000000","#,
    r#""attributes":[{"key":"http.host","value":{"stringValue":"slow.example"}},{"key":"server.address","value":{"stringValue":"db"}}]},"#,
    r#"{"traceId":"zz","spanId":"3333333333333333","kind":2,"startTimeUnixNano":"1","endTimeUnixNano":"2"}]}]}]}"#
);

/// A fresh, empty directory under the target directory's tmp folder (t.TempDir()).
pub fn temp_dir() -> PathBuf {
    static N: AtomicUsize = AtomicUsize::new(0);
    let d = std::path::Path::new(env!("CARGO_TARGET_TMPDIR")).join(format!(
        "rbfast-otlp-test-{}-{}",
        std::process::id(),
        N.fetch_add(1, Ordering::SeqCst)
    ));
    let _ = std::fs::remove_dir_all(&d);
    std::fs::create_dir_all(&d).unwrap();
    d
}

fn write(dir: &Path, name: &str, body: &[u8]) {
    std::fs::create_dir_all(dir).unwrap();
    std::fs::write(dir.join(name), body).unwrap();
}

fn gzip(data: &[u8]) -> Vec<u8> {
    let mut z = flate2::write::GzEncoder::new(Vec::new(), flate2::Compression::default());
    z.write_all(data).unwrap();
    z.finish().unwrap()
}

#[test]
fn read_json_lines() {
    let dir = temp_dir();
    write(
        &dir.join("traces"),
        "a.jsonl",
        format!("{REQ}\n\n{REQ}\n").as_bytes(),
    );
    let d = read_dir(&dir).unwrap();
    assert!(
        d.spans.len() == 4 && d.skipped == 2,
        "spans={} skipped={}, want 4 and 2 (a bad trace id is skipped, not fatal)",
        d.spans.len(),
        d.skipped
    );
    assert_eq!(d.resources.len(), 1);
    let r = &d.resources[0];
    assert!(
        r.service == "api" && r.pod == "api-1" && r.image == "reg/api:1.2",
        "resources: {:?}",
        d.resources
    );
    let client = d
        .spans
        .iter()
        .rev()
        .find(|s| s.kind == KIND_CLIENT)
        .expect("a client span");
    assert!(client.peer >= 0 && d.peers[client.peer as usize] == "db", "client peer: {client:?} peers={:?} (peer.service, then server.address, wins over http.host)", d.peers);
    assert_eq!(
        client.dur_ms(),
        6.0,
        "a start given as a bare number is read too"
    );
}

#[test]
fn read_gzip_and_pretty_json() {
    let dir = temp_dir();
    write(&dir, "a.jsonl.gz", &gzip(format!("{REQ}\n").as_bytes()));
    let pretty = REQ.replace(r#","scopeSpans""#, ",\n  \"scopeSpans\"");
    write(&dir, "b.json", format!("{pretty}\n{REQ}").as_bytes());
    let d = read_dir(&dir).unwrap();
    assert!(
        d.spans.len() == 6 && d.files.len() == 2,
        "spans={} files={:?}",
        d.spans.len(),
        d.files
    );
}

#[test]
fn errors() {
    let e = read_dir(temp_dir().join("missing")).unwrap_err();
    assert_eq!(
        e.kind,
        ReadErrorKind::Path,
        "a missing path should fail: {e}"
    );
    let e = read_dir(temp_dir()).unwrap_err();
    assert!(e.message.contains("no trace files"), "empty folder: {e}");
    let bad = temp_dir();
    write(&bad, "x.jsonl", b"{not json}\n");
    let e = read_dir(&bad).unwrap_err();
    assert!(e.message.contains("bad OTLP/JSON"), "bad json: {e}");
    // zstd and proto are named, not guessed
    let z = temp_dir();
    write(&z, "x.jsonl.zst", b"x");
    assert!(
        read_dir(&z).is_err(),
        "an unsupported compression should not be read"
    );
}

/// Server (and one client) spans, and whether the reference implementation's reader drops each as a health or
/// readiness probe.
type ProbeCase = (Vec<(&'static str, &'static str)>, &'static str, i32, bool);

fn probe_cases() -> Vec<ProbeCase> {
    vec![
        (
            vec![("url.path", "/healthz"), ("http.request.method", "GET")],
            "",
            2,
            true,
        ),
        (vec![("http.target", "/health?x=1")], "", 2, true),
        (vec![("http.route", "/readyz")], "", 2, true),
        (vec![], "GET /livez", 2, true),
        (
            vec![("http.url", "http://10.0.0.1:8080/ready")],
            "",
            2,
            true,
        ),
        (vec![("http.url", "https://host/ping?probe")], "", 2, true),
        (vec![], "grpc.health.v1.Health/Check", 2, true),
        (vec![("url.path", "/api/health")], "", 2, false),
        (vec![("url.path", "/healthy")], "", 2, false),
        (vec![("url.path", "/ping2")], "", 2, false),
        (vec![("url.path", "/_health")], "", 2, true),
        (vec![("url.path", "/healthcheck")], "", 2, false),
        (vec![("url.path", "")], "/healthz", 2, true),
        (vec![("url.path", "/ready/")], "", 2, false),
        (
            vec![("url.path", "/healthz"), ("http.method", "POST")],
            "",
            2,
            true,
        ),
        (vec![("http.target", "/healthz#frag")], "", 2, true),
        (vec![], "UsersController#show", 2, false),
        (vec![("url.path", "/HEALTHZ")], "", 2, false),
        (vec![("url.path", "/livez?verbose")], "", 2, true),
        (vec![], "GET /api/ready", 2, false),
        (vec![("http.url", "http://host")], "", 2, false),
        (vec![("url.path", "/healthz")], "", 3, false),
        (
            vec![("url.path", "/readyz"), ("http.target", "/orders")],
            "",
            2,
            true,
        ),
        (
            vec![("http.target", "/orders"), ("http.route", "/healthz")],
            "",
            2,
            false,
        ),
        (vec![], "/ping", 2, true),
        (vec![], "ping", 2, false),
    ]
}

fn json_str(s: &str) -> String {
    let mut o = String::from("\"");
    for c in s.chars() {
        match c {
            '"' => o.push_str("\\\""),
            '\\' => o.push_str("\\\\"),
            c => o.push(c),
        }
    }
    o.push('"');
    o
}

pub fn span_json(
    trace: u64,
    id: u64,
    parent: u64,
    kind: i32,
    name: &str,
    attrs: &[(&str, &str)],
) -> String {
    let parent = if parent > 0 {
        format!("{parent:016x}")
    } else {
        String::new()
    };
    let mut s = format!(
        r#"{{"traceId":"{trace:032x}","spanId":"{id:016x}","parentSpanId":"{parent}","name":{},"kind":{kind},"startTimeUnixNano":"1700000000000000000","endTimeUnixNano":"1700000000001000000","attributes":["#,
        json_str(name)
    );
    let sorted: BTreeMap<&str, &str> = attrs.iter().copied().collect();
    for (i, (k, v)) in sorted.iter().enumerate() {
        if i > 0 {
            s.push(',');
        }
        s.push_str(&format!(
            r#"{{"key":{},"value":{{"stringValue":{}}}}}"#,
            json_str(k),
            json_str(v)
        ));
    }
    s.push_str("]}");
    s
}

pub fn resource_line(spans: &[String]) -> String {
    format!(
        r#"{{"resourceSpans":[{{"resource":{{"attributes":[{{"key":"service.name","value":{{"stringValue":"s"}}}}]}},"scopeSpans":[{{"spans":[{}]}}]}}]}}"#,
        spans.join(",")
    ) + "\n"
}

/// The reader drops the same spans as the reference's health-probe rule, server spans only.
#[test]
fn probes_dropped() {
    let cases = probe_cases();
    let mut body = String::new();
    for (i, (attrs, name, kind, _)) in cases.iter().enumerate() {
        body.push_str(&resource_line(&[span_json(
            i as u64 + 1,
            i as u64 + 1,
            0,
            *kind,
            name,
            attrs,
        )]));
    }
    let dir = temp_dir();
    write(&dir, "p.jsonl", body.as_bytes());
    let d = read_dir(&dir).unwrap();
    let kept: HashSet<u64> = d.spans.iter().map(|s| s.trace[1]).collect();
    let mut want = 0;
    for (i, (attrs, name, kind, probe)) in cases.iter().enumerate() {
        if *probe {
            want += 1;
        }
        let dropped = !kept.contains(&(i as u64 + 1));
        assert_eq!(
            dropped, *probe,
            "case {i} ({attrs:?} {name:?} kind {kind}): dropped {dropped}, the reference {probe}"
        );
    }
    assert_eq!(d.probes, want);
}

/// A span under a dropped probe is a root, not a span whose parent is missing; other spans keep their parents.
#[test]
fn probe_children_are_roots() {
    let body = resource_line(&[
        span_json(1, 1, 0, 2, "", &[("url.path", "/health")]),
        span_json(1, 2, 1, 1, "health check", &[]),
        span_json(2, 3, 0, 2, "", &[("url.path", "/orders")]),
        span_json(2, 4, 3, 1, "work", &[]),
    ]);
    let dir = temp_dir();
    write(&dir, "p.jsonl", body.as_bytes());
    let d = read_dir(&dir).unwrap();
    assert!(
        d.probes == 1 && d.probe_children == 1 && d.spans.len() == 3,
        "probes {}, probe children {}, spans {}; want 1, 1, 3",
        d.probes,
        d.probe_children,
        d.spans.len()
    );
    for sp in &d.spans {
        if sp.id == 2 {
            assert_eq!(
                sp.parent, 0,
                "the probe's child keeps parent {:x}",
                sp.parent
            );
        }
        if sp.id == 4 {
            assert_eq!(sp.parent, 3, "an ordinary child lost its parent");
        }
    }
}

/// Not in the Go tests: the same capture at every thread count and chunk size gives the same Data.
#[test]
fn threads_and_chunks_do_not_change_the_result() {
    let mut body = String::new();
    for i in 0..300u64 {
        let svc = format!("s{}", i % 7);
        let attrs = [("server.address", "db"), ("server.port", "5432")];
        let sp = span_json(
            i / 3 + 1,
            i + 1,
            if i % 3 == 0 { 0 } else { i },
            if i % 3 == 0 { 2 } else { 3 },
            "x",
            &attrs,
        );
        body.push_str(&resource_line(&[sp]).replace("\"s\"", &json_str(&svc)));
    }
    let dir = temp_dir();
    write(&dir.join("traces"), "a.jsonl", body.as_bytes());
    write(&dir.join("traces"), "b.jsonl.gz", &gzip(body.as_bytes()));
    let base = read_dir_with(
        &dir,
        &ReadOptions {
            threads: 1,
            chunk_bytes: 1 << 30,
        },
    )
    .unwrap();
    for threads in [1, 2, 3, 8] {
        for chunk in [1, 100, 4096, 0] {
            let d = read_dir_with(
                &dir,
                &ReadOptions {
                    threads,
                    chunk_bytes: chunk,
                },
            )
            .unwrap();
            assert_eq!(d.spans, base.spans, "threads {threads} chunk {chunk}");
            assert_eq!(d.resources, base.resources);
            assert_eq!(d.peers, base.peers);
            assert_eq!(d.addrs, base.addrs);
            assert_eq!(d.files, base.files);
        }
    }
    assert_eq!(base.spans.len(), 600);
    assert_eq!(base.resources.len(), 7);
}

/// A `.json` stream reads the same at every chunking (the batches cut at "\n{" and scanned in parallel, the
/// serial path when a batch is not clean): values one per line, pretty-printed, adjacent (`}{`), with a nested
/// object at the start of a line (a cut inside a value), a top-level number, gzipped; and a syntax error or a
/// truncation far from the start gives one error text whatever the chunking.
#[test]
fn json_streams_do_not_depend_on_chunking() {
    let pretty = REQ
        .replace("{\"resource\":", "\n{\"resource\":")
        .replace(",\"scopeSpans\"", ",\n  \"scopeSpans\"");
    let nested = REQ.replace("[{\"resource\"", "[\n{\"resource\"");
    let mut streams: Vec<(String, Vec<u8>)> = Vec::new();
    let many = |sep: &str, v: &str| -> String {
        (0..40).map(|_| v.to_string()).collect::<Vec<_>>().join(sep)
    };
    streams.push(("lines".into(), many("\n", REQ).into_bytes()));
    streams.push(("pretty".into(), many("\n", &pretty).into_bytes()));
    streams.push(("adjacent".into(), many("", REQ).into_bytes()));
    streams.push(("nested-cut".into(), many("\n", &nested).into_bytes()));
    streams.push((
        "number-last".into(),
        format!("{}\n7", many("\n", REQ)).into_bytes(),
    ));
    let good: Vec<(String, Vec<u8>)> = streams.clone();
    let mut bad: Vec<(String, Vec<u8>)> = Vec::new();
    for (name, body) in &good {
        let mut late = body.clone();
        let at = late.len() * 3 / 4;
        late.splice(at..at, b"\n{\"x\":tru}\n".iter().copied());
        bad.push((format!("{name}-syntax-late"), late));
        bad.push((format!("{name}-truncated"), body[..body.len() - 5].to_vec()));
        let mut utf = body.clone();
        utf.extend_from_slice("\n\u{e9}".as_bytes());
        bad.push((format!("{name}-bad-rune-at-end"), utf));
    }
    for (name, body) in good.iter().chain(bad.iter()) {
        for gz in [false, true] {
            let dir = temp_dir();
            let file = if gz { "a.json.gz" } else { "a.json" };
            write(
                &dir.join("traces"),
                file,
                &if gz { gzip(body) } else { body.clone() },
            );
            let outcome = |threads: usize, chunk_bytes: usize| -> String {
                match read_dir_with(
                    &dir,
                    &ReadOptions {
                        threads,
                        chunk_bytes,
                    },
                ) {
                    Ok(d) => format!(
                        "ok {} spans {:?} {:?}",
                        d.spans.len(),
                        d.spans.first(),
                        d.resources
                    ),
                    Err(e) => format!("error {}", e.message.replace(dir.to_str().unwrap(), "CAP")),
                }
            };
            let want = outcome(1, 1 << 30);
            for (threads, chunk) in [(0, 0), (2, 1), (3, 13), (8, 100), (1, 999), (4, 4096)] {
                assert_eq!(
                    outcome(threads, chunk),
                    want,
                    "{name} gz={gz} threads {threads} chunk {chunk}"
                );
            }
            if name == "number-last" {
                // valid JSON, but a number is no request (Go: a decode error, after every syntax check)
                assert!(
                    want.starts_with("error bad OTLP/JSON: json: cannot unmarshal number"),
                    "{name}: {want}"
                );
            } else if good.iter().any(|g| &g.0 == name) {
                assert!(want.starts_with("ok 80 spans"), "{name}: {want}");
            } else {
                assert!(want.starts_with("error"), "{name}: {want}");
            }
        }
    }
}
