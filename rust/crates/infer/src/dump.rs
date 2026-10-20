// SPDX-License-Identifier: Apache-2.0

//! Loads the rbfast oracle's canonical span dump (spans.tsv, resources.tsv, peers.tsv, addrs.tsv,
//! counters.json; see rust/README.md, "Tests") into a Data, in Go's capture order (the `seq` column), so the
//! inference can be tested and timed without the reader. The caller decompresses spans.tsv.gz.

use rbfast_otlp::{Data, Resource, Span};

fn unesc(s: &str) -> String {
    if !s.contains('\\') {
        return s.to_string();
    }
    let mut out = String::with_capacity(s.len());
    let mut it = s.chars();
    while let Some(c) = it.next() {
        if c != '\\' {
            out.push(c);
            continue;
        }
        match it.next() {
            Some('t') => out.push('\t'),
            Some('n') => out.push('\n'),
            Some('r') => out.push('\r'),
            Some('\\') => out.push('\\'),
            Some(o) => {
                out.push('\\');
                out.push(o);
            }
            None => out.push('\\'),
        }
    }
    out
}

fn hex64(s: &str) -> Result<u64, String> {
    u64::from_str_radix(s, 16).map_err(|e| format!("hex {s:?}: {e}"))
}

fn rows(text: &str) -> impl Iterator<Item = Vec<&str>> {
    text.lines().skip(1).filter(|l| !l.is_empty()).map(|l| l.split('\t').collect())
}

/// A table of (idx, name...) rows: the names in idx order.
fn table(text: &str, cols: usize) -> Result<Vec<Vec<String>>, String> {
    let mut out: Vec<(usize, Vec<String>)> = Vec::new();
    for r in rows(text) {
        if r.len() < cols + 1 {
            return Err(format!("short row {r:?}"));
        }
        let i: usize = r[0].parse().map_err(|e| format!("idx {:?}: {e}", r[0]))?;
        out.push((i, r[1..=cols].iter().map(|s| unesc(s)).collect()));
    }
    out.sort_by_key(|x| x.0);
    for (k, (i, _)) in out.iter().enumerate() {
        if *i != k {
            return Err(format!("table index {i} at row {k}"));
        }
    }
    Ok(out.into_iter().map(|x| x.1).collect())
}

/// A field of a flat JSON object holding integers (counters.json), 0 when absent.
fn counter(json: &str, key: &str) -> usize {
    let pat = format!("\"{key}\":");
    let Some(at) = json.find(&pat) else {
        return 0;
    };
    let rest = json[at + pat.len()..].trim_start();
    let end = rest.find(|c: char| !c.is_ascii_digit()).unwrap_or(rest.len());
    rest[..end].parse().unwrap_or(0)
}

/// Builds the Data from the dump's texts: spans in seq (capture) order, tables in their idx order.
pub fn load(
    spans_tsv: &str,
    resources_tsv: &str,
    peers_tsv: &str,
    addrs_tsv: &str,
    counters_json: &str,
) -> Result<Data, String> {
    let resources: Vec<Resource> = table(resources_tsv, 3)?
        .into_iter()
        .map(|r| Resource { service: r[0].clone(), pod: r[1].clone(), image: r[2].clone() })
        .collect();
    let peers: Vec<String> = table(peers_tsv, 1)?.into_iter().map(|mut r| r.remove(0)).collect();
    let addrs: Vec<String> = table(addrs_tsv, 1)?.into_iter().map(|mut r| r.remove(0)).collect();
    let mut seq_spans: Vec<(usize, Span)> = Vec::new();
    for r in rows(spans_tsv) {
        if r.len() < 10 {
            return Err(format!("short span row {r:?}"));
        }
        let seq: usize = r[0].parse().map_err(|e| format!("seq: {e}"))?;
        let tr = r[1];
        if tr.len() != 32 {
            return Err(format!("trace {tr:?}"));
        }
        let span = Span {
            trace: [hex64(&tr[..16])?, hex64(&tr[16..])?],
            id: hex64(r[2])?,
            parent: hex64(r[3])?,
            start: r[4].parse().map_err(|e| format!("start: {e}"))?,
            end: r[5].parse().map_err(|e| format!("end: {e}"))?,
            kind: r[6].parse().map_err(|e| format!("kind: {e}"))?,
            res: r[7].parse().map_err(|e| format!("res: {e}"))?,
            peer: r[8].parse().map_err(|e| format!("peer: {e}"))?,
            addr: r[9].parse().map_err(|e| format!("addr: {e}"))?,
        };
        seq_spans.push((seq, span));
    }
    seq_spans.sort_by_key(|x| x.0);
    for (k, (s, _)) in seq_spans.iter().enumerate() {
        if *s != k {
            return Err(format!("seq {s} at position {k}: the dump is not a whole capture"));
        }
    }
    Ok(Data {
        spans: seq_spans.into_iter().map(|x| x.1).collect(),
        resources,
        peers,
        addrs,
        skipped: counter(counters_json, "skipped"),
        probes: counter(counters_json, "probes"),
        probe_children: counter(counters_json, "probe_children"),
        files: Vec::new(),
    })
}
