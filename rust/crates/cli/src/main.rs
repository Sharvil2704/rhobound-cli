// SPDX-License-Identifier: Apache-2.0 AND BSD-3-Clause
// mkdir_all below is derived from Go's src/os/path.go (MkdirAll), Copyright The Go Authors, under the BSD-3-Clause
// licence in rust/LICENSE-GO; the rest is Apache-2.0.

//! rbfast: an optional, parallel accelerator for rhobound-cli. `infer`, `predict` and `model` take the same
//! arguments as `rhobound` and write the same output (the Go binary is the reference; see README.md for what
//! was compared). `read` times the capture reader alone, and `sweep` evaluates many what-ifs in parallel.
//!
//! The pipeline is the Go one, crate by crate: rbfast-otlp reads the capture (otlp.ReadDir), rbfast-infer
//! infers the topology (infer.Run), rbfast-math solves the model (model.AnalyticWith, ChangePatchWith), and
//! report.rs builds the report (internal/report). This file is cmd/rhobound/main.go: the same commands, flag
//! rules, order of checks, refusal texts and exit codes (2 for no or an unknown command, 1 for any error).

// Ported from Go: comparisons keep Go's form (`!(a <= b)` is not `a > b` for NaN, and cmd/rhobound refuses NaN
// limits and loads that way).
#![allow(clippy::neg_cmp_op_on_partial_ord)]

mod flags;
mod report;
mod sweep;
mod tabwriter;

use std::collections::BTreeMap;
use std::io::{Read, Write};
use std::time::Instant;

use flags::{FlagSet, Value};
use rbfast_infer::{gofmt, Inferred, ServiceStats, SortMode};
use rbfast_math::model::{
    analytic_exec, change_patch_from_base, parse_patch_bytes, Call, Config, Delta, Exec, ModelResult, Service,
    Topology, DEFAULT, PLAIN, POOLED,
};
use rbfast_math::topojson::parse_topology;
use rbfast_otlp::{read_dir_with, ReadOptions};

/// The name printed before every error, where rhobound prints "rhobound:".
pub const PROG: &str = "rbfast";

pub const VERSION: &str = concat!(env!("CARGO_PKG_VERSION"), " (port of rhobound-cli 0.1.0)");

const USAGE: &str = "rbfast - a parallel accelerator for rhobound-cli (the Go binary is the reference)

Usage:
  rbfast predict CAPTURE [--patch svc=+3ms,other=+10%] [--workers svc=N] [--kept-share F]
                         [--max-rho 0.85] [--out DIR] [--json] [--plain] [--threads N]
  rbfast infer   CAPTURE [--workers svc=N] [--threads N]   print the inferred call graph (JSON)
  rbfast model   TOPOLOGY.json --rps N [--patch ...] [--max-rho 0.85] [--out DIR] [--json] [--plain]
  rbfast sweep   TOPOLOGY.json --rps A:B:STEP[,R,...] [--patch-grid GRID] [--plain | --both]
                         [--max-rho 0.85] [--threads N]      many what-ifs, one JSON line each
  rbfast sweep   CAPTURE --capture [--rps ...] [--patch-grid GRID] [--workers svc=N] [--kept-share F] ...
  rbfast read    CAPTURE [--threads N] [--reps R] [--json]  read the capture only: counts and time
  rbfast version

predict, infer and model take rhobound's arguments and print rhobound's output (see README.md).
CAPTURE is a folder with traces/ (OTLP/JSON lines, plain or .gz), or a trace file.
--patch svc=+3ms adds work that holds the worker to every visit; svc=+10% scales
the service's whole own time per visit, glue (time after its first call) included.
--plain turns off the refinements for 70-80% utilization (arrival variability
carried through the graph, correlated parallel branches); see rhobound's docs/ACCURACY.md.
--threads N (or RBFAST_THREADS=N) sets the worker threads; 0 or unset: one per core.
GRID is ALT[;ALT...]: each ALT is svc=VALUES[,svc=VALUES...] (every combination);
VALUES is V[|V...] with V a --patch value (+3ms, -10%) or a range FROM:TO:STEP with
a unit (0:10:2%, 0:5:0.5ms). The base (no change) is always evaluated too.
It models mean latency under steady, roughly Poisson load. It refuses a load
(the observed one, or the one after the change) at which a service is above
--max-rho utilization, and does not model tails, bursts, retries or timeouts.
";

fn main() {
    // Go's os.Args: the arguments' bytes as they are (a path that is not UTF-8 still opens)
    let args: Vec<Vec<u8>> = std::env::args_os().skip(1).map(os_vec).collect();
    let code = run(&args);
    std::process::exit(code);
}

#[cfg(unix)]
fn os_vec(a: std::ffi::OsString) -> Vec<u8> {
    use std::os::unix::ffi::OsStringExt;
    a.into_vec()
}

#[cfg(not(unix))]
fn os_vec(a: std::ffi::OsString) -> Vec<u8> {
    a.to_string_lossy().into_owned().into_bytes()
}

/// A path to open from Go string bytes.
#[cfg(unix)]
pub fn os_path(b: &[u8]) -> std::path::PathBuf {
    std::path::PathBuf::from(rbfast_gostr::bytes_os(b))
}

#[cfg(not(unix))]
pub fn os_path(b: &[u8]) -> std::path::PathBuf {
    std::path::PathBuf::from(String::from_utf8_lossy(b).into_owned())
}

/// A command's error: its text as Go prints it (bytes: a path in it is printed as it is, with %s or %v).
#[derive(Debug)]
pub struct Fail(pub Vec<u8>);

impl From<String> for Fail {
    fn from(s: String) -> Fail {
        Fail(s.into_bytes())
    }
}

impl From<&str> for Fail {
    fn from(s: &str) -> Fail {
        Fail(s.as_bytes().to_vec())
    }
}

/// An error text made of byte strings.
pub fn cat(parts: &[&[u8]]) -> Fail {
    Fail(parts.concat())
}

/// Output of a command: stdout text, and stderr lines written as they come.
struct Out {
    stdout: Vec<u8>,
}

impl Out {
    fn print(&mut self, s: &str) {
        self.stdout.extend_from_slice(s.as_bytes());
    }
}

fn eprint_line(s: &str) {
    eprint_bytes(s.as_bytes());
}

fn eprint_bytes(s: &[u8]) {
    let mut e = std::io::stderr().lock();
    let _ = e.write_all(s);
    let _ = e.write_all(b"\n");
}

/// Writes the command's stdout; a write error is the command's error (Go's report writers return it).
fn flush_stdout(out: &Out) -> Result<(), String> {
    let mut so = std::io::stdout().lock();
    so.write_all(&out.stdout).and_then(|_| so.flush()).map_err(|e| format!("write /dev/stdout: {}", os_text(&e)))
}

/// cmd/rhobound's run: the exit status of one command line.
fn run(args: &[Vec<u8>]) -> i32 {
    if args.is_empty() {
        let _ = std::io::stderr().write_all(USAGE.as_bytes());
        return 2;
    }
    let mut out = Out { stdout: Vec::new() };
    let rest = &args[1..];
    let r = match args[0].as_slice() {
        b"predict" => cmd_predict(rest, &mut out),
        b"infer" => cmd_infer(rest, &mut out),
        b"model" => cmd_model(rest, &mut out),
        b"sweep" => sweep::cmd_sweep(rest, &mut out),
        b"read" => cmd_read(rest, &mut out),
        b"version" | b"--version" | b"-v" => {
            // Go ignores a write error here (Fprintln's result is not checked)
            out.print(&format!("{PROG} {VERSION}\n"));
            let _ = flush_stdout(&out);
            return 0;
        }
        b"help" | b"--help" | b"-h" => {
            out.print(USAGE);
            let _ = flush_stdout(&out);
            return 0;
        }
        other => {
            let _ = std::io::stderr()
                .write_all(format!("unknown command {}\n\n{}", rbfast_gostr::quote_bytes(other), USAGE).as_bytes());
            return 2;
        }
    };
    let r = r.and_then(|_| flush_stdout(&out).map_err(Fail::from));
    match r {
        Ok(()) => 0,
        Err(e) => {
            eprint_bytes(&[PROG.as_bytes(), b": ", &e.0].concat());
            1
        }
    }
}

/// Go's text for an OS error: the C library's message with a lower-case first letter (Go's syscall table for
/// linux has the same texts), without Rust's " (os error N)".
pub fn os_text(e: &std::io::Error) -> String {
    let s = e.to_string();
    let s = match s.rfind(" (os error ") {
        Some(i) if e.raw_os_error().is_some() => s[..i].to_string(),
        _ => s,
    };
    let mut c = s.chars();
    match c.next() {
        Some(f) => f.to_lowercase().collect::<String>() + c.as_str(),
        None => s,
    }
}

/// The flags every rhobound command defines (cmd/rhobound's newFlags), and rbfast's --threads.
pub fn new_flags() -> FlagSet {
    let mut fs = FlagSet::new();
    fs.define("workers", Value::Str(Vec::new()));
    fs.define("patch", Value::Str(Vec::new()));
    fs.define("kept-share", Value::Float(1.0));
    fs.define("max-rho", Value::Float(0.85));
    fs.define("out", Value::Str(Vec::new()));
    fs.define("json", Value::Bool(false));
    fs.define("plain", Value::Bool(false));
    fs.define("threads", Value::Count(env_threads()));
    fs
}

/// RBFAST_THREADS, else 0 (one thread per core).
fn env_threads() -> usize {
    std::env::var("RBFAST_THREADS").ok().and_then(|s| s.trim().parse().ok()).unwrap_or(0)
}

/// Whether RBFAST_TIMES asks for the stage times on stderr.
pub fn times_on() -> bool {
    std::env::var_os("RBFAST_TIMES").is_some_and(|v| !v.is_empty() && v != "0")
}

/// Runs `f` on a rayon pool of `threads` threads (0: the global pool, one per core); Err ("thread pool: ...")
/// when the OS refuses the threads.
pub fn with_pool<R: Send>(threads: usize, f: impl FnOnce() -> R + Send) -> Result<R, String> {
    rbfast_math::batch::with_threads(threads, f)
}

/// How the model runs for one what-if: the matched maximum's quadrature on the pool when there is more than one
/// thread (the same bits either way).
pub fn exec_for(threads: usize) -> Exec<'static> {
    let n = if threads == 0 { std::thread::available_parallelism().map(|n| n.get()).unwrap_or(1) } else { threads };
    Exec { parallel_quadrature_min_branches: if n > 1 { 2 } else { 0 }, memo: None }
}

/// cmd/rhobound's splitList on a Go string: the comma-separated items, trimmed (strings.TrimSpace), non-empty.
fn split_list(s: &[u8]) -> Vec<&[u8]> {
    s.split(|&c| c == b',').map(rbfast_gostr::trim_space).filter(|p| !p.is_empty()).collect()
}

/// cmd/rhobound's parseWorkers. A name that is not UTF-8 is checked and kept out of the map: it can match no
/// service (a capture's names are UTF-8), and Go ignores names that match none.
pub fn parse_workers(s: &[u8]) -> Result<BTreeMap<String, i64>, String> {
    let mut out = BTreeMap::new();
    for kv in split_list(s) {
        let (k, v, ok) = match kv.iter().position(|&c| c == b'=') {
            Some(i) => (&kv[..i], &kv[i + 1..], true),
            None => (kv, &b""[..], false),
        };
        let n = go_atoi(rbfast_gostr::trim_space(v));
        match n {
            Some(n) if ok && n >= 1 => {
                if let Ok(name) = std::str::from_utf8(rbfast_gostr::trim_space(k)) {
                    out.insert(name.to_string(), n);
                }
            }
            _ => return Err(format!("--workers: {} is not svc=N with N >= 1", rbfast_gostr::quote_bytes(kv))),
        }
    }
    Ok(out)
}

/// strconv.Atoi: an optional sign and decimal digits, in int64 range.
fn go_atoi(b: &[u8]) -> Option<i64> {
    let digits = match b.first() {
        Some(b'+') | Some(b'-') => &b[1..],
        _ => b,
    };
    if digits.is_empty() || !digits.iter().all(u8::is_ascii_digit) {
        return None;
    }
    std::str::from_utf8(b).ok()?.parse::<i64>().ok()
}

/// cmd/rhobound's modelConfig and modelName.
pub fn model_config(plain: bool) -> Config {
    if plain {
        PLAIN
    } else {
        DEFAULT
    }
}

pub fn model_name(plain: bool) -> &'static str {
    if plain {
        "basic: Poisson arrivals at every queue, exponential parallel branches"
    } else {
        "refined: arrival variability propagated through the graph (weight 0.7), parallel branches as correlated gammas"
    }
}

/// The inference's topology as the model crate's type: a field-for-field copy, then Finish (which recomputes
/// the order; Go's CLI uses the inferred topology as Finish left it, so the two orders must agree).
pub fn to_model_topology(t: &rbfast_infer::Topology) -> Result<Topology, String> {
    let services = t
        .services
        .iter()
        .map(|s| Service {
            name: s.name.clone(),
            s: s.s,
            calls: s.calls.iter().map(|c| Call { child: c.child, p: c.p, is_async: c.is_async }).collect(),
            parallel: s.parallel,
            servers: s.servers,
            workers: s.workers,
            cs2: s.cs2,
            routing: s.routing.clone(),
            delay: s.delay,
            hop: s.hop,
            branch_corr: s.branch_corr,
            glue: s.glue,
            glue_cs2: s.glue_cs2,
            shares: s.shares.clone(),
        })
        .collect();
    let mut m = Topology::new(t.name.clone(), services, t.entry.clone());
    m.finish().map_err(|e| e.0)?;
    if m.order() != t.order.as_slice() {
        return Err(format!(
            "internal error: the model's topological order {:?} differs from the inference's {:?}",
            m.order(),
            t.order
        ));
    }
    Ok(m)
}

/// The capture read and inferred, with the read and inference times.
struct Loaded {
    inf: Inferred,
    read_s: f64,
    infer_s: f64,
}

/// cmd/rhobound's load: the kept-share and --workers checks, the read, the inference.
fn load(path: &[u8], fs: &FlagSet) -> Result<Loaded, Fail> {
    let k = fs.float("kept-share");
    if !(k > 0.0 && k <= 1.0) {
        return Err(format!("--kept-share must be in (0, 1], got {}", gofmt::v(k)).into());
    }
    let workers = parse_workers(fs.bytes("workers"))?;
    let threads = fs.count("threads");
    let t0 = Instant::now();
    let mut d = read_dir_with(os_path(path), &ReadOptions { threads, chunk_bytes: 0 }).map_err(|e| Fail(e.raw))?;
    let read_s = t0.elapsed().as_secs_f64();
    // audit switches: Go's serial sort (the same order as the default), or a stable sort (not Go's order of
    // spans with an equal trace and start)
    let sort = match std::env::var("RBFAST_SORT").as_deref() {
        Ok("go-exact") | Ok("go-serial") => SortMode::GoExact,
        Ok("stable") => SortMode::Stable,
        _ => SortMode::Parallel,
    };
    let opt = rbfast_infer::Options { kept_share: k, workers, min_requests: 0, estimator: String::new(), sort };
    let t1 = Instant::now();
    let r = with_pool(threads, || rbfast_infer::run(&mut d, &opt))?;
    let infer_s = t1.elapsed().as_secs_f64();
    // the span table is no longer needed; the process exits soon, so skip freeing it
    std::mem::forget(d);
    let inf = r.map_err(|e| e.0)?;
    Ok(Loaded { inf, read_s, infer_s })
}

fn cmd_infer(args: &[Vec<u8>], out: &mut Out) -> Result<(), Fail> {
    let mut fs = new_flags();
    let pos = fs.parse_interleaved(args);
    let pos = match pos {
        Ok(p) if p.len() == 1 => p,
        _ => return Err("usage: rhobound infer CAPTURE [--workers svc=N]".into()),
    };
    let l = load(&pos[0], &fs)?;
    let b = l.inf.topology.marshal()?;
    out.print(&b);
    out.print("\n");
    // Go prints the topology first and ignores a write error there (Fprintln's result is not checked)
    let _ = flush_stdout(out);
    out.stdout.clear();
    let _ = std::io::stderr().write_all(l.inf.stderr_text().as_bytes());
    if times_on() {
        eprint_line(&format!("{PROG}: times: read {:.4} s, infer {:.4} s", l.read_s, l.infer_s));
    }
    Ok(())
}

/// cmd/rhobound's limitError: the refusal of a load at which a service is above the --max-rho limit.
pub fn limit_error(when: &str, stats: &[ServiceStats], topo: &Topology, r: &ModelResult, limit: f64) -> String {
    let mut busy: Vec<String> = Vec::new();
    let mut lower: Vec<String> = Vec::new();
    let mut example = String::new();
    for (i, &rho) in r.rho.iter().enumerate() {
        if rho <= limit {
            continue;
        }
        let name = &topo.services[i].name;
        if rho.is_nan() {
            busy.push(format!("{name} has no utilization (NaN: an input is out of range)"));
            continue;
        }
        if rho < 1.0 {
            busy.push(format!("{name} would run at {}% utilization", gofmt::f(100.0 * rho, 1)));
        } else {
            busy.push(format!(
                "{name} would pass 100% utilization ({}%: no steady state, the model is unstable)",
                gofmt::f(100.0 * rho, 1)
            ));
        }
        if i < stats.len() {
            let st = &stats[i];
            if st.workers_inferred && !st.workers_from_queueing && !st.external && !st.stage {
                let sv = &topo.services[i];
                let (mut pods, mut w) = (sv.servers, sv.workers);
                if sv.routing == POOLED {
                    pods = 1;
                    w = sv.servers * sv.workers;
                }
                lower.push(format!("{name} ({pods} x {w}+)"));
                if example.is_empty() {
                    example = name.clone();
                }
            }
        }
    }
    if busy.is_empty() {
        busy.push("the model has no finite latency (a queue at the edge of saturation)".to_string());
    }
    let mut msg = format!(
        "{} {}, above the limit of {}% (--max-rho; the model covers steady load below it only)",
        when,
        busy.join(", "),
        gofmt::f(100.0 * limit, 1)
    );
    if !lower.is_empty() {
        msg.push_str(&format!(
            ". The worker count of {} is only a lower bound: too few of its requests waited for a worker, or \
too briefly, to tell its pool from a larger one or from one with no limit, so that utilization is an upper bound. \
If the pool is larger, or has no limit, set its size with --workers (for example --workers {}=N with N its \
workers per pod)",
            lower.join(", "),
            example
        ));
    }
    msg
}

fn max_rho_ok(fs: &FlagSet) -> Result<f64, String> {
    let m = fs.float("max-rho");
    if !(m > 0.0 && m <= 0.95) {
        return Err("--max-rho must be in (0, 0.95]".to_string());
    }
    Ok(m)
}

/// The base and (with a patch) the change, refused as cmd/rhobound refuses them.
pub struct Solved {
    pub base: ModelResult,
    pub delta: Option<Delta>,
}

fn cmd_predict(args: &[Vec<u8>], out: &mut Out) -> Result<(), Fail> {
    let mut fs = new_flags();
    let pos = match fs.parse_interleaved(args) {
        Ok(p) if p.len() == 1 => p,
        _ => {
            return Err(
                "usage: rhobound predict CAPTURE [--patch svc=+3ms] [--workers svc=N] [--out DIR] [--json]".into()
            )
        }
    };
    let max_rho = max_rho_ok(&fs)?;
    let l = load(&pos[0], &fs)?;
    let inf = &l.inf;
    let threads = fs.count("threads");
    let t0 = Instant::now();
    let topo = to_model_topology(&inf.topology)?;
    let (patch, changes) = parse_patch_bytes(fs.bytes("patch"), &topo)?;
    let plain = fs.bool("plain");
    let cfg = model_config(plain);
    let exec = exec_for(threads);
    let lam = inf.lam_ext_per_ms;
    let solved: Result<Solved, String> = with_pool(threads, || {
        let base = analytic_exec(&topo, lam, None, cfg, exec).map_err(|e| e.0)?;
        let (mr, _) = base.max_rho();
        if !base.stable || !(mr <= max_rho) {
            return Err(limit_error("refusing to predict: at the observed load", &inf.stats, &topo, &base, max_rho));
        }
        let mut delta = None;
        if patch.ds.is_some() {
            // ChangePatchWith solves the base again; it is the same pure function of the same inputs
            let d = change_patch_from_base(&topo, lam, &patch, cfg, exec, base.clone()).map_err(|e| e.0)?;
            let (mr, _) = d.patched.max_rho();
            if !d.stable || !(mr <= max_rho) {
                return Err(limit_error("refusing the change: after it", &inf.stats, &topo, &d.patched, max_rho));
            }
            delta = Some(d);
        }
        Ok(Solved { base, delta })
    })?;
    let s = solved?;
    let model_s = t0.elapsed().as_secs_f64();
    let t1 = Instant::now();
    let mut rep = report::build(&pos[0], inf, &topo, fs.float("kept-share"), &s.base, s.delta.as_ref(), changes);
    rep.model = model_name(plain).to_string();
    let r = write_report(&rep, &fs, out);
    if times_on() {
        eprint_line(&format!(
            "{PROG}: times: read {:.4} s, infer {:.4} s, model {:.4} s, report {:.4} s",
            l.read_s,
            l.infer_s,
            model_s,
            t1.elapsed().as_secs_f64()
        ));
    }
    r
}

/// filepath.Join(dir, name): the two joined by a slash, then filepath.Clean (on Go string bytes).
fn go_join(dir: &[u8], name: &[u8]) -> Vec<u8> {
    let p: Vec<u8> = if dir.is_empty() { name.to_vec() } else { [dir, b"/", name].concat() };
    if p.is_empty() {
        return b".".to_vec();
    }
    let rooted = p[0] == b'/';
    let mut parts: Vec<&[u8]> = Vec::new();
    for seg in p.split(|&c| c == b'/') {
        match seg {
            b"" | b"." => {}
            b".." => {
                if parts.last().is_some_and(|l| *l != b"..") {
                    parts.pop();
                } else if !rooted {
                    parts.push(b"..");
                }
            }
            s => parts.push(s),
        }
    }
    let body = parts.join(&b'/');
    if rooted {
        [b"/", &body[..]].concat()
    } else if body.is_empty() {
        b".".to_vec()
    } else {
        body
    }
}

/// os.Create and a write, with Go's error texts ("open PATH: ...", "write PATH: ...").
fn create_and_write(path: &[u8], data: impl FnOnce() -> Result<Vec<u8>, String>) -> Result<(), Fail> {
    let mut f =
        std::fs::File::create(os_path(path)).map_err(|e| cat(&[b"open ", path, b": ", os_text(&e).as_bytes()]))?;
    let text = data()?;
    f.write_all(&text).map_err(|e| cat(&[b"write ", path, b": ", os_text(&e).as_bytes()]))
}

/// os.MkdirAll(path, 0o755), with Go's errors: an existing path that is not a directory is ENOTDIR on that
/// path; otherwise the parent is made first, and the error names the component whose mkdir failed.
fn mkdir_all(path: &[u8]) -> Result<(), Fail> {
    let not_dir = |p: &[u8]| cat(&[b"mkdir ", p, b": ", b"not a directory"]);
    match std::fs::metadata(os_path(path)) {
        Ok(m) if m.is_dir() => return Ok(()),
        Ok(_) => return Err(not_dir(path)),
        Err(_) => {}
    }
    // the parent: drop trailing slashes, then the last element
    let mut i = path.len();
    while i > 0 && path[i - 1] == b'/' {
        i -= 1;
    }
    while i > 0 && path[i - 1] != b'/' {
        i -= 1;
    }
    // Go: i = the index of that slash (or 0); recurse when path[:i] is not empty
    let parent = if i > 0 { &path[..i - 1] } else { &path[..0] };
    if !parent.is_empty() {
        mkdir_all(parent)?;
    }
    let mut b = std::fs::DirBuilder::new();
    #[cfg(unix)]
    {
        use std::os::unix::fs::DirBuilderExt;
        b.mode(0o755);
    }
    if let Err(e) = b.create(os_path(path)) {
        // "foo/." and the like: fine if a directory is there now
        if std::fs::symlink_metadata(os_path(path)).is_ok_and(|m| m.is_dir()) {
            return Ok(());
        }
        return Err(cat(&[b"mkdir ", path, b": ", os_text(&e).as_bytes()]));
    }
    Ok(())
}

/// cmd/rhobound's writeReport: report.txt and report.json into --out when given, then the report on stdout
/// (JSON with --json).
fn write_report(rep: &report::Report, fs: &FlagSet, out: &mut Out) -> Result<(), Fail> {
    let dir = fs.bytes("out");
    if !dir.is_empty() {
        mkdir_all(dir)?;
        create_and_write(&go_join(dir, b"report.txt"), || Ok(rep.text()))?;
        create_and_write(&go_join(dir, b"report.json"), || rep.json_text().map(String::into_bytes))?;
        eprint_bytes(&[b"wrote ", dir, b"/report.txt and report.json"].concat());
    }
    if fs.bool("json") {
        out.print(&rep.json_text()?);
    } else {
        out.stdout.extend_from_slice(&rep.text());
    }
    Ok(())
}

/// model.LoadTopology with Go's file-error texts (os.ReadFile: "open PATH: ...", "read PATH: ...").
pub fn load_topology(path: &[u8]) -> Result<Topology, Fail> {
    let mut f =
        std::fs::File::open(os_path(path)).map_err(|e| cat(&[b"open ", path, b": ", os_text(&e).as_bytes()]))?;
    let mut data = Vec::new();
    f.read_to_end(&mut data).map_err(|e| cat(&[b"read ", path, b": ", os_text(&e).as_bytes()]))?;
    // json.Unmarshal checks the syntax of the whole input first: a syntax error is reported in Go's words
    rbfast_otlp::check_json_syntax(&data)?;
    Ok(parse_topology(&data).map_err(|e| e.0)?)
}

/// The Inferred `rhobound model` makes up for a topology file: no capture, stats with names and entry marks.
pub fn topology_inferred(topo: &Topology, lam: f64) -> Inferred {
    Inferred { lam_ext_per_ms: lam, stats: report::topology_stats(topo), ..Default::default() }
}

fn cmd_model(args: &[Vec<u8>], out: &mut Out) -> Result<(), Fail> {
    let mut fs = new_flags();
    fs.define("rps", Value::Float(0.0));
    let usage = "usage: rhobound model TOPOLOGY.json --rps N [--patch svc=+3ms] [--max-rho 0.85] [--out DIR] [--json]";
    let pos = match fs.parse_interleaved(args) {
        Ok(p) => p,
        Err(_) => return Err(usage.into()),
    };
    let rps = fs.float("rps");
    if pos.len() != 1 || !(rps > 0.0) || rps == f64::INFINITY {
        return Err(usage.into());
    }
    // the topology fixes the worker counts and holds no capture to sample (Visit: lexicographical order)
    let unused: Vec<&str> = [("kept-share", "--kept-share"), ("workers", "--workers")]
        .into_iter()
        .filter(|f| fs.was_set(f.0))
        .map(|f| f.1)
        .collect();
    if !unused.is_empty() {
        return Err(format!(
            "model does not take {} (they apply to a capture: predict and infer)",
            unused.join(" or ")
        )
        .into());
    }
    let max_rho = max_rho_ok(&fs)?;
    let topo = load_topology(&pos[0])?;
    let lam = rps / 1000.0;
    let inf = topology_inferred(&topo, lam);
    let plain = fs.bool("plain");
    let cfg = model_config(plain);
    let threads = fs.count("threads");
    let exec = exec_for(threads);
    let patch_spec = fs.bytes("patch").to_vec();
    let solved: Result<(Solved, Vec<rbfast_math::model::Change>), String> = with_pool(threads, || {
        let base = analytic_exec(&topo, lam, None, cfg, exec).map_err(|e| e.0)?;
        let (mr, _) = base.max_rho();
        if !base.stable || !(mr <= max_rho) {
            return Err(limit_error(
                &format!("refusing to evaluate: at {} requests/s", gofmt::v(rps)),
                &inf.stats,
                &topo,
                &base,
                max_rho,
            ));
        }
        let (patch, changes) = parse_patch_bytes(&patch_spec, &topo)?;
        let mut delta = None;
        if patch.ds.is_some() {
            let d = change_patch_from_base(&topo, lam, &patch, cfg, exec, base.clone()).map_err(|e| e.0)?;
            let (mr, _) = d.patched.max_rho();
            if !d.stable || !(mr <= max_rho) {
                return Err(limit_error("refusing the change: after it", &inf.stats, &topo, &d.patched, max_rho));
            }
            delta = Some(d);
        }
        Ok((Solved { base, delta }, changes))
    })?;
    let (s, changes) = solved?;
    let mut rep = report::build(&pos[0], &inf, &topo, 1.0, &s.base, s.delta.as_ref(), changes);
    rep.model = model_name(plain).to_string();
    rep.from_topology = true;
    write_report(&rep, &fs, out)
}

fn cmd_read(args: &[Vec<u8>], out: &mut Out) -> Result<(), Fail> {
    let mut fs = FlagSet::new();
    fs.define("threads", Value::Count(env_threads()));
    fs.define("reps", Value::Count(1));
    fs.define("json", Value::Bool(false));
    let pos = match fs.parse_interleaved(args) {
        Ok(p) if p.len() == 1 => p,
        _ => return Err("usage: rbfast read CAPTURE [--threads N] [--reps R] [--json]".into()),
    };
    let threads = fs.count("threads");
    let reps = fs.count("reps").max(1);
    let mut times = Vec::with_capacity(reps);
    let mut data = None;
    for _ in 0..reps {
        let t0 = Instant::now();
        let d = read_dir_with(os_path(&pos[0]), &ReadOptions { threads, chunk_bytes: 0 }).map_err(|e| Fail(e.raw))?;
        times.push(t0.elapsed().as_secs_f64());
        if let Some(old) = data.replace(d) {
            drop(old);
        }
    }
    let d = data.expect("one read at least");
    let bytes: u64 = d.files.iter().filter_map(|f| std::fs::metadata(f).ok()).map(|m| m.len()).sum();
    let mut sorted = times.clone();
    sorted.sort_by(f64::total_cmp);
    let median = sorted[sorted.len() / 2];
    let used = if threads == 0 { std::thread::available_parallelism().map(|n| n.get()).unwrap_or(1) } else { threads };
    if fs.bool("json") {
        use rbfast_infer::json::{obj, Json};
        let j = obj(vec![
            ("capture", Json::str(&rbfast_gostr::lossy(&pos[0]))),
            ("files", Json::Arr(d.files.iter().map(|f| Json::str(f)).collect())),
            ("bytes_on_disk", Json::int(bytes as i64)),
            ("spans", Json::int(d.spans.len() as i64)),
            ("skipped", Json::int(d.skipped as i64)),
            ("probes", Json::int(d.probes as i64)),
            ("probe_children", Json::int(d.probe_children as i64)),
            ("resources", Json::int(d.resources.len() as i64)),
            ("peers", Json::int(d.peers.len() as i64)),
            ("addrs", Json::int(d.addrs.len() as i64)),
            ("threads", Json::int(used as i64)),
            ("read_s", Json::Arr(times.iter().map(|&t| Json::num(t).unwrap_or(Json::Null)).collect())),
            ("median_s", Json::num(median).unwrap_or(Json::Null)),
        ]);
        out.print(&j.pretty());
        out.print("\n");
    } else {
        out.print("capture         ");
        out.stdout.extend_from_slice(&pos[0]);
        out.print("\n");
        out.print(&format!("files           {} ({} bytes on disk)\n", d.files.len(), bytes));
        out.print(&format!("spans           {}\n", d.spans.len()));
        out.print(&format!("skipped         {}\n", d.skipped));
        out.print(&format!("probes dropped  {} (probe children made roots: {})\n", d.probes, d.probe_children));
        out.print(&format!("resources       {}\n", d.resources.len()));
        out.print(&format!("peers           {}\n", d.peers.len()));
        out.print(&format!("addrs           {}\n", d.addrs.len()));
        out.print(&format!("threads         {used}\n"));
        let all: Vec<String> = times.iter().map(|t| format!("{t:.4}")).collect();
        if reps > 1 {
            out.print(&format!("read            {median:.4} s (median of {reps}: {})\n", all.join(" ")));
        } else {
            out.print(&format!("read            {median:.4} s\n"));
        }
    }
    std::mem::forget(d);
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn workers() {
        let w = parse_workers(b" a=3, b = +2 ,").unwrap();
        assert_eq!(w.get("a"), Some(&3));
        assert_eq!(w.get("b"), Some(&2));
        assert_eq!(parse_workers(b"a=0").unwrap_err(), "--workers: \"a=0\" is not svc=N with N >= 1");
        assert!(parse_workers(b"a").is_err());
        assert!(parse_workers(b"a=1_0").is_err());
        assert!(parse_workers(b"a=99999999999999999999").is_err());
        assert_eq!(parse_workers(b"\xff=x").unwrap_err(), "--workers: \"\\xff=x\" is not svc=N with N >= 1");
        assert_eq!(
            parse_workers("a\u{a0}=x".as_bytes()).unwrap_err(),
            "--workers: \"a\\u00a0=x\" is not svc=N with N >= 1"
        );
        // a name that is not UTF-8 matches no service: checked, then left out
        assert!(parse_workers(b"\xff=2,a=1").unwrap().keys().eq(["a"].iter()));
    }

    #[test]
    fn join() {
        assert_eq!(go_join(b"r", b"report.txt"), b"r/report.txt");
        assert_eq!(go_join(b"r/", b"report.txt"), b"r/report.txt");
        assert_eq!(go_join(b"./a//b/../c", b"x"), b"a/c/x");
        assert_eq!(go_join(b"/", b"x"), b"/x");
        assert_eq!(go_join(b"../..", b"x"), b"../../x");
        assert_eq!(go_join(b"caf\xe9/", b"x"), b"caf\xe9/x");
    }

    #[test]
    fn os_texts() {
        let e = std::fs::File::open("/no/such/file").unwrap_err();
        assert_eq!(os_text(&e), "no such file or directory");
    }
}
