// SPDX-License-Identifier: Apache-2.0

//! Go's own results, frozen: tests/data/go_golden.txt holds 406 small captures (cases probing JSON
//! syntax, Go's v1 merge and case-folding rules, strings and UTF-8, timestamps, kinds, ids, routes, peers, line
//! splitting, JSON streams, gzip framing, file discovery; plus fuzzed captures) with the outcome Go 1.27.2's
//! otlp.ReadDir gave: the SHA-256 of a canonical text of the whole Data (counters, tables, every span in order),
//! or its exact error text.

use rbfast_otlp::{dump::sha256_hex, read_dir_with, Data, ReadOptions};
use std::path::PathBuf;

fn b64(s: &str) -> Vec<u8> {
    let val = |c: u8| -> u32 {
        match c {
            b'A'..=b'Z' => (c - b'A') as u32,
            b'a'..=b'z' => (c - b'a' + 26) as u32,
            b'0'..=b'9' => (c - b'0' + 52) as u32,
            b'+' => 62,
            b'/' => 63,
            _ => panic!("bad base64"),
        }
    };
    let s = s.trim_end_matches('=').as_bytes();
    let mut out = Vec::with_capacity(s.len() * 3 / 4);
    for ch in s.chunks(4) {
        let mut n = 0u32;
        for (i, &c) in ch.iter().enumerate() {
            n |= val(c) << (18 - 6 * i);
        }
        let bytes = [(n >> 16) as u8, (n >> 8) as u8, n as u8];
        out.extend_from_slice(&bytes[..ch.len() - 1]);
    }
    out
}

/// The canonical text that the Go program which froze these outcomes (made for the comparison, not published)
/// hashes.
fn canonical(d: &Data) -> String {
    let hex = |s: &str| s.bytes().map(|b| format!("{b:02x}")).collect::<String>();
    let mut h = format!(
        "spans={} skipped={} probes={} probe_children={} files={}\n",
        d.spans.len(),
        d.skipped,
        d.probes,
        d.probe_children,
        d.files.len()
    );
    for (i, r) in d.resources.iter().enumerate() {
        h.push_str(&format!(
            "R{}\t{}\t{}\t{}\n",
            i,
            hex(&r.service),
            hex(&r.pod),
            hex(&r.image)
        ));
    }
    for (i, s) in d.peers.iter().enumerate() {
        h.push_str(&format!("P{}\t{}\n", i, hex(s)));
    }
    for (i, s) in d.addrs.iter().enumerate() {
        h.push_str(&format!("A{}\t{}\n", i, hex(s)));
    }
    for s in &d.spans {
        h.push_str(&format!(
            "{:016x}{:016x} {:016x} {:016x} {} {} {} {} {} {}\n",
            s.trace[0], s.trace[1], s.id, s.parent, s.start, s.end, s.kind, s.res, s.peer, s.addr
        ));
    }
    h
}

#[test]
fn go_golden_cases() {
    let text = std::fs::read_to_string(concat!(
        env!("CARGO_MANIFEST_DIR"),
        "/tests/data/go_golden.txt"
    ))
    .unwrap();
    let root: PathBuf = std::path::Path::new(env!("CARGO_TARGET_TMPDIR"))
        .join(format!("rbfast-otlp-golden-{}", std::process::id()));
    let _ = std::fs::remove_dir_all(&root);
    let (mut n, mut failures) = (0, Vec::new());
    let mut cap = PathBuf::new();
    for line in text.lines() {
        if line.starts_with('#') || line.is_empty() {
            continue;
        }
        let (tag, rest) = line.split_once(' ').unwrap();
        match tag {
            "case" => {
                cap = root.join(rest.replace('/', "_"));
                std::fs::create_dir_all(cap.join("traces")).unwrap();
            }
            "file" => {
                let (name, data) = rest.split_once(' ').unwrap();
                std::fs::write(cap.join("traces").join(name), b64(data)).unwrap();
            }
            "expect" => {
                n += 1;
                let (kind, want) = rest.split_once(' ').unwrap_or((rest, ""));
                let want = format!("{kind} {want}");
                // the default chunking, then tiny chunks: many lines chunks, many `.json` batches (cut at every
                // "\n{"), the serial fallback after a batch that is not clean; the outcome must be Go's every time
                for (threads, chunk_bytes) in [(0, 0), (3, 1), (2, 7), (4, 64), (1, 4096)] {
                    let got = match read_dir_with(
                        &cap,
                        &ReadOptions {
                            threads,
                            chunk_bytes,
                        },
                    ) {
                        Ok(d) => format!("OK {}", sha256_hex(canonical(&d).as_bytes())),
                        Err(e) => format!(
                            "ERROR {}",
                            e.message
                                .replace(cap.to_str().unwrap(), "CAP")
                                .replace('\n', "\\n")
                        ),
                    };
                    if got != want {
                        failures.push(format!(
                            "{} (threads {threads}, chunk {chunk_bytes}):\n  go:   {}\n  rust: {}",
                            cap.display(),
                            want,
                            got
                        ));
                    }
                }
            }
            _ => panic!("bad line {line}"),
        }
    }
    let _ = std::fs::remove_dir_all(&root);
    assert!(n >= 400, "only {n} cases");
    assert!(
        failures.is_empty(),
        "{} of {} cases differ from Go:\n{}",
        failures.len(),
        n,
        failures.join("\n")
    );
}
