// SPDX-License-Identifier: Apache-2.0

//! The canonical span dump of the rbfast oracle: byte for byte the files its Go dump program (made for the
//! comparison, not published; see rust/README.md) writes, so a Rust read can be diffed against Go's.
//!
//! `spans.tsv` (or `spans.tsv.gz`): every span sorted by (trace, id, start, seq), seq being its index in
//! `Data::spans`; `resources.tsv`, `peers.tsv`, `addrs.tsv`; `counters.json` with the SHA-256 of the
//! uncompressed `spans.tsv`.

use crate::Data;
use std::fmt::Write as _;
use std::io::{self, BufWriter, Write};
use std::path::Path;

/// The Go dump's esc: backslash, tab, newline and carriage return escaped.
fn esc(s: &str, out: &mut Vec<u8>) {
    for &c in s.as_bytes() {
        match c {
            b'\\' => out.extend_from_slice(b"\\\\"),
            b'\t' => out.extend_from_slice(b"\\t"),
            b'\n' => out.extend_from_slice(b"\\n"),
            b'\r' => out.extend_from_slice(b"\\r"),
            _ => out.push(c),
        }
    }
}

fn write_table(path: &Path, header: &str, rows: impl Iterator<Item = Vec<u8>>) -> io::Result<()> {
    let mut w = BufWriter::new(std::fs::File::create(path)?);
    w.write_all(header.as_bytes())?;
    w.write_all(b"\n")?;
    for r in rows {
        w.write_all(&r)?;
        w.write_all(b"\n")?;
    }
    w.flush()
}

/// The rows of spans.tsv (with its header), in the oracle's order.
pub fn span_rows(d: &Data) -> Vec<u8> {
    let sp = &d.spans;
    let mut order: Vec<u32> = (0..sp.len() as u32).collect();
    order.sort_unstable_by(|&x, &y| {
        let (a, b) = (&sp[x as usize], &sp[y as usize]);
        (a.trace[0], a.trace[1], a.id, a.start, x).cmp(&(b.trace[0], b.trace[1], b.id, b.start, y))
    });
    let mut out = Vec::with_capacity(sp.len() * 160 + 128);
    out.extend_from_slice(b"seq\ttrace\tid\tparent\tstart\tend\tkind\tres\tpeer\taddr\tservice\tpod\timage\tpeer_name\taddr_name\n");
    let mut line = String::with_capacity(256);
    for &i in &order {
        let s = &sp[i as usize];
        line.clear();
        let _ = write!(
            line,
            "{}\t{:016x}{:016x}\t{:016x}\t{:016x}\t{}\t{}\t{}\t{}\t{}\t{}\t",
            i,
            s.trace[0],
            s.trace[1],
            s.id,
            s.parent,
            s.start,
            s.end,
            s.kind,
            s.res,
            s.peer,
            s.addr
        );
        out.extend_from_slice(line.as_bytes());
        let r = &d.resources[s.res as usize];
        esc(&r.service, &mut out);
        out.push(b'\t');
        esc(&r.pod, &mut out);
        out.push(b'\t');
        esc(&r.image, &mut out);
        out.push(b'\t');
        if s.peer >= 0 {
            esc(&d.peers[s.peer as usize], &mut out);
        }
        out.push(b'\t');
        if s.addr >= 0 {
            esc(&d.addrs[s.addr as usize], &mut out);
        }
        out.push(b'\n');
    }
    out
}

/// Go's encoding/json string encoding (v1 defaults: HTML and JS escaping, invalid UTF-8 as �).
pub fn go_json_string(s: &str) -> String {
    let mut o = String::from("\"");
    for c in s.chars() {
        match c {
            '"' => o.push_str("\\\""),
            '\\' => o.push_str("\\\\"),
            '\n' => o.push_str("\\n"),
            '\r' => o.push_str("\\r"),
            '\t' => o.push_str("\\t"),
            '\u{8}' => o.push_str("\\b"),
            '\u{c}' => o.push_str("\\f"),
            '<' | '>' | '&' | '\u{2028}' | '\u{2029}' => {
                let _ = write!(o, "\\u{:04x}", c as u32);
            }
            c if (c as u32) < 0x20 => {
                let _ = write!(o, "\\u{:04x}", c as u32);
            }
            c => o.push(c),
        }
    }
    o.push('"');
    o
}

/// Writes the dump of `d` into `dir`; returns the SHA-256 (hex) of the uncompressed spans.tsv.
pub fn write_dump(d: &Data, dir: &Path, gz: bool) -> io::Result<String> {
    std::fs::create_dir_all(dir)?;
    write_table(
        &dir.join("resources.tsv"),
        "idx\tservice\tpod\timage",
        d.resources.iter().enumerate().map(|(i, r)| {
            let mut v = format!("{i}\t").into_bytes();
            esc(&r.service, &mut v);
            v.push(b'\t');
            esc(&r.pod, &mut v);
            v.push(b'\t');
            esc(&r.image, &mut v);
            v
        }),
    )?;
    let names = |t: &[String]| -> Vec<Vec<u8>> {
        t.iter()
            .enumerate()
            .map(|(i, p)| {
                let mut v = format!("{i}\t").into_bytes();
                esc(p, &mut v);
                v
            })
            .collect()
    };
    write_table(
        &dir.join("peers.tsv"),
        "idx\tname",
        names(&d.peers).into_iter(),
    )?;
    write_table(
        &dir.join("addrs.tsv"),
        "idx\tname",
        names(&d.addrs).into_iter(),
    )?;
    let rows = span_rows(d);
    let sha = sha256_hex(&rows);
    if gz {
        let f = std::fs::File::create(dir.join("spans.tsv.gz"))?;
        let mut z = flate2::write::GzEncoder::new(BufWriter::new(f), flate2::Compression::new(6));
        z.write_all(&rows)?;
        z.finish()?.flush()?;
    } else {
        std::fs::write(dir.join("spans.tsv"), &rows)?;
    }
    let mut c = String::from("{\n");
    let _ = writeln!(c, "  \"addrs\": {},", d.addrs.len());
    c.push_str("  \"files\": [\n");
    for (i, f) in d.files.iter().enumerate() {
        let _ = writeln!(
            c,
            "    {}{}",
            go_json_string(f),
            if i + 1 < d.files.len() { "," } else { "" }
        );
    }
    c.push_str("  ],\n");
    let _ = writeln!(c, "  \"peers\": {},", d.peers.len());
    let _ = writeln!(c, "  \"probe_children\": {},", d.probe_children);
    let _ = writeln!(c, "  \"probes\": {},", d.probes);
    let _ = writeln!(c, "  \"resources\": {},", d.resources.len());
    let _ = writeln!(c, "  \"skipped\": {},", d.skipped);
    let _ = writeln!(c, "  \"spans\": {},", d.spans.len());
    let _ = writeln!(c, "  \"spans_tsv_sha256\": \"{}\"", sha);
    c.push_str("}\n");
    std::fs::write(dir.join("counters.json"), c)?;
    Ok(sha)
}

// ------------------------------------------------------------------ SHA-256 (FIPS 180-4), for counters.json

const K: [u32; 64] = [
    0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5, 0x3956c25b, 0x59f111f1, 0x923f82a4, 0xab1c5ed5,
    0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3, 0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174,
    0xe49b69c1, 0xefbe4786, 0x0fc19dc6, 0x240ca1cc, 0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da,
    0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7, 0xc6e00bf3, 0xd5a79147, 0x06ca6351, 0x14292967,
    0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13, 0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85,
    0xa2bfe8a1, 0xa81a664b, 0xc24b8b70, 0xc76c51a3, 0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070,
    0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5, 0x391c0cb3, 0x4ed8aa4a, 0x5b9cca4f, 0x682e6ff3,
    0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208, 0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2,
];

fn compress(h: &mut [u32; 8], block: &[u8]) {
    let mut w = [0u32; 64];
    for t in 0..16 {
        w[t] = u32::from_be_bytes(block[4 * t..4 * t + 4].try_into().unwrap());
    }
    for t in 16..64 {
        let s0 = w[t - 15].rotate_right(7) ^ w[t - 15].rotate_right(18) ^ (w[t - 15] >> 3);
        let s1 = w[t - 2].rotate_right(17) ^ w[t - 2].rotate_right(19) ^ (w[t - 2] >> 10);
        w[t] = w[t - 16]
            .wrapping_add(s0)
            .wrapping_add(w[t - 7])
            .wrapping_add(s1);
    }
    let [mut a, mut b, mut c, mut d, mut e, mut f, mut g, mut hh] = *h;
    for t in 0..64 {
        let s1 = e.rotate_right(6) ^ e.rotate_right(11) ^ e.rotate_right(25);
        let ch = (e & f) ^ (!e & g);
        let t1 = hh
            .wrapping_add(s1)
            .wrapping_add(ch)
            .wrapping_add(K[t])
            .wrapping_add(w[t]);
        let s0 = a.rotate_right(2) ^ a.rotate_right(13) ^ a.rotate_right(22);
        let maj = (a & b) ^ (a & c) ^ (b & c);
        let t2 = s0.wrapping_add(maj);
        hh = g;
        g = f;
        f = e;
        e = d.wrapping_add(t1);
        d = c;
        c = b;
        b = a;
        a = t1.wrapping_add(t2);
    }
    for (x, v) in h.iter_mut().zip([a, b, c, d, e, f, g, hh]) {
        *x = x.wrapping_add(v);
    }
}

/// SHA-256 of `data`, as lower-case hex.
pub fn sha256_hex(data: &[u8]) -> String {
    let mut h: [u32; 8] = [
        0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a, 0x510e527f, 0x9b05688c, 0x1f83d9ab,
        0x5be0cd19,
    ];
    let mut blocks = data.chunks_exact(64);
    for b in &mut blocks {
        compress(&mut h, b);
    }
    let rem = blocks.remainder();
    let mut tail = [0u8; 128];
    tail[..rem.len()].copy_from_slice(rem);
    tail[rem.len()] = 0x80;
    let n = if rem.len() < 56 { 64 } else { 128 };
    tail[n - 8..n].copy_from_slice(&((data.len() as u64) * 8).to_be_bytes());
    for b in tail[..n].chunks_exact(64) {
        compress(&mut h, b);
    }
    h.iter().map(|x| format!("{x:08x}")).collect()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn sha() {
        assert_eq!(
            sha256_hex(b""),
            "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"
        );
        assert_eq!(
            sha256_hex(b"abc"),
            "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
        );
        let m = b"abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq";
        assert_eq!(
            sha256_hex(m),
            "248d6a61d20638b8e5c026930c3e6039a33ce45964ff2167f6ecedd419db06c1"
        );
    }
}
