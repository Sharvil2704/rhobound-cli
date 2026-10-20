// SPDX-License-Identifier: Apache-2.0
//! Test support: the oracle's span dumps as Data, a structural JSON comparison with a float tolerance, and the
//! float comparison with Go's linux/arm64 results.
#![allow(dead_code)]

use std::io::Read;
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicUsize, Ordering};
use std::sync::OnceLock;

use rbfast_otlp::Data;
use serde_json::Value;

/// A folder of test data named by an environment variable (the Go-made data that is not in the repository: see
/// rust/README.md, "Tests"). None, with the reason printed, when the variable is unset or the folder lacks `probe`.
pub fn data_dir(var: &str, probe: &str, what: &str) -> Option<PathBuf> {
    match std::env::var_os(var) {
        None => {
            eprintln!("skipped: {var} is not set ({what}; not in the repository, see rust/README.md)");
            None
        }
        Some(p) => {
            let p = PathBuf::from(p);
            if p.join(probe).exists() {
                Some(p)
            } else {
                eprintln!("skipped: {var}={} has no {probe}", p.display());
                None
            }
        }
    }
}

/// The oracle directory (RBFAST_ORACLE): the Go binary's outputs on the oracle captures.
pub fn oracle_dir() -> Option<PathBuf> {
    data_dir("RBFAST_ORACLE", "README.md", "the oracle: the Go binary's outputs on 24 captures")
}

/// The recorded Go unit-test runs (RBFAST_REPLAY).
pub fn replay_dir() -> Option<PathBuf> {
    data_dir("RBFAST_REPLAY", ".", "the recorded runs of the Go unit tests that build spans")
}

/// The Go results these tests compare with were made by Go 1.27.2 on linux/arm64. On aarch64 every float must
/// have Go's bits (any NaN for a NaN). Elsewhere a float within [`TOLERANCE`] (relative) of Go's passes and is
/// counted ([`report`] prints the count): Rust's float operations, and the fused multiply-adds the ports place
/// where Go's arm64 build fuses, give the same bits on every architecture, so none is expected, but that was
/// verified on linux/arm64 only. `RBFAST_PARITY=tolerant` selects the tolerant comparison on aarch64 as well.
pub const TOLERANCE: f64 = 1e-9;
static INEXACT: AtomicUsize = AtomicUsize::new(0);

/// Whether floats must be bit-identical to Go's (aarch64, unless RBFAST_PARITY=tolerant).
pub fn bit_exact() -> bool {
    static EXACT: OnceLock<bool> = OnceLock::new();
    *EXACT.get_or_init(|| {
        cfg!(target_arch = "aarch64") && std::env::var_os("RBFAST_PARITY").is_none_or(|v| v != "tolerant")
    })
}

/// a equals Go's b: the same bits (or both NaN); when not [`bit_exact`], also within [`TOLERANCE`] relative.
pub fn same(a: f64, b: f64) -> bool {
    if a.to_bits() == b.to_bits() || (a.is_nan() && b.is_nan()) {
        return true;
    }
    if bit_exact() || !a.is_finite() || !b.is_finite() {
        return false;
    }
    let ok = (a - b).abs() <= TOLERANCE * a.abs().max(b.abs());
    if ok {
        INEXACT.fetch_add(1, Ordering::Relaxed);
    }
    ok
}

/// Prints how the floats of a test were compared (at its end).
pub fn report(what: &str) {
    if bit_exact() {
        eprintln!("{what}: floats compared bit for bit with Go linux/arm64");
    } else {
        eprintln!(
            "{what}: floats compared within {TOLERANCE:e} relative (not aarch64, or RBFAST_PARITY=tolerant): {} not \
             bit-identical to Go linux/arm64",
            INEXACT.load(Ordering::Relaxed)
        );
    }
}

/// The oracle's per-capture directories (those with a span dump), sorted by name.
pub fn captures(oracle: &Path) -> Vec<PathBuf> {
    let mut v: Vec<PathBuf> = std::fs::read_dir(oracle)
        .unwrap()
        .filter_map(|e| e.ok().map(|e| e.path()))
        .filter(|p| p.join("spans.tsv.gz").exists())
        .collect();
    v.sort();
    v
}

/// The span count of an oracle capture (its counters.json), 0 when unknown.
pub fn span_count(dir: &Path) -> u64 {
    std::fs::read_to_string(dir.join("counters.json"))
        .ok()
        .and_then(|t| serde_json::from_str::<Value>(&t).ok())
        .and_then(|v| v["spans"].as_u64())
        .unwrap_or(0)
}

pub fn gunzip(path: &Path) -> String {
    let f = std::fs::File::open(path).unwrap_or_else(|e| panic!("{}: {e}", path.display()));
    let mut s = String::new();
    flate2::read::MultiGzDecoder::new(std::io::BufReader::with_capacity(1 << 20, f)).read_to_string(&mut s).unwrap();
    s
}

pub fn read(path: &Path) -> String {
    std::fs::read_to_string(path).unwrap_or_else(|e| panic!("{}: {e}", path.display()))
}

/// A capture's canonical dump as Data, in Go's capture order.
pub fn load(dir: &Path) -> Data {
    rbfast_infer::dump::load(
        &gunzip(&dir.join("spans.tsv.gz")),
        &read(&dir.join("resources.tsv")),
        &read(&dir.join("peers.tsv")),
        &read(&dir.join("addrs.tsv")),
        &read(&dir.join("counters.json")),
    )
    .unwrap_or_else(|e| panic!("{}: {e}", dir.display()))
}

/// The outcome of comparing two JSON documents.
#[derive(Default, Debug)]
pub struct Cmp {
    pub floats: usize,
    pub exact: usize,
    pub max_rel: f64,
    pub worst: String,
    pub diffs: Vec<String>,
}

fn is_int(n: &serde_json::Number) -> bool {
    n.is_i64() || n.is_u64()
}

/// Structural comparison: the same keys, lengths, strings, booleans and integers; floats within rel (relative to
/// the larger magnitude, with an absolute floor of abs).
pub fn compare(go: &Value, rs: &Value, rel: f64, abs: f64) -> Cmp {
    let mut c = Cmp::default();
    walk(go, rs, "$", rel, abs, &mut c);
    c
}

fn walk(a: &Value, b: &Value, path: &str, rel: f64, abs: f64, c: &mut Cmp) {
    match (a, b) {
        (Value::Object(x), Value::Object(y)) => {
            let kx: Vec<&String> = x.keys().collect();
            let ky: Vec<&String> = y.keys().collect();
            if kx != ky {
                c.diffs.push(format!("{path}: keys {kx:?} vs {ky:?}"));
                return;
            }
            for (k, v) in x {
                walk(v, &y[k], &format!("{path}.{k}"), rel, abs, c);
            }
        }
        (Value::Array(x), Value::Array(y)) => {
            if x.len() != y.len() {
                c.diffs.push(format!("{path}: length {} vs {}", x.len(), y.len()));
                return;
            }
            for (i, (u, v)) in x.iter().zip(y).enumerate() {
                walk(u, v, &format!("{path}[{i}]"), rel, abs, c);
            }
        }
        (Value::Number(x), Value::Number(y)) => {
            if is_int(x) && is_int(y) {
                if x != y {
                    c.diffs.push(format!("{path}: {x} vs {y}"));
                }
                return;
            }
            let (u, v) = (x.as_f64().unwrap(), y.as_f64().unwrap());
            c.floats += 1;
            if u.to_bits() == v.to_bits() {
                c.exact += 1;
                return;
            }
            let d = (u - v).abs();
            let r = if d <= abs { 0.0 } else { d / u.abs().max(v.abs()) };
            if r > c.max_rel {
                c.max_rel = r;
                c.worst = format!("{path}: {u:e} vs {v:e}");
            }
            if r > rel {
                c.diffs.push(format!("{path}: {u:e} vs {v:e} (rel {r:.3e})"));
            }
        }
        _ => {
            if a != b {
                c.diffs.push(format!("{path}: {a} vs {b}"));
            }
        }
    }
}

/// A rayon pool with n threads.
pub fn pool(n: usize) -> rayon::ThreadPool {
    rayon::ThreadPoolBuilder::new().num_threads(n).build().unwrap()
}
