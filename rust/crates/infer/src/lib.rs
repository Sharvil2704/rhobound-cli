// SPDX-License-Identifier: Apache-2.0

//! Topology inference from a span table: a port of rhobound-cli's `internal/infer` (infer.go, fifo.go,
//! structure.go, split.go). The Go code is the specification; [`run`] gives the same [`Inferred`] as Go's
//! `infer.Run`, and [`Topology::marshal`] the same JSON as `rhobound infer`.
//!
//! What runs in parallel (rayon, on the current pool; install a pool to set the thread count):
//! - the sort of the span table by (trace, start): Go's pdqsort, in parallel on compact keys, so that spans
//!   with an equal trace and start end where Go puts them ([`SortMode`]);
//! - the pre-pass and the per-trace pass, in chunks of trace groups sized from the capture alone (Go's rule,
//!   max(64, ceil(groups / 256))), merged in chunk order: the floating-point sums are taken in Go's order and
//!   do not depend on the thread count. The branch correlation's pair sums (Go's recordBranches) accumulate in
//!   these chunks too; only the per-service reduction (the most common fan-out width, a few keys) is serial;
//! - the FIFO queue rebuild and worker search, one task per pod (largest first), pooled per service in pod order;
//! - the hop samples' sorts, one per service; the rise estimator's sweep, one task per service.
//!
//! Go's arm64 build fuses `x*y + z` into one rounding (FMA); this port uses `mul_add` at the same places, so on
//! arm64 its sums match Go's bit for bit when the order matches (see the parity tests).

// Ported from Go line by line: comparisons keep Go's form (`!(a < b)` is not `a >= b` for NaN), constants keep
// Go's digits, and a few functions keep Go's long argument lists.
#![allow(
    clippy::neg_cmp_op_on_partial_ord,
    clippy::excessive_precision,
    clippy::too_many_arguments,
    clippy::needless_range_loop
)]

pub mod dump;
pub mod fifo;
pub mod gofmt;
pub mod gosort;
mod hash;
pub mod json;
pub mod mathx;
pub mod rise;
mod sort;
pub mod split;
pub mod structure;
pub mod topo;
mod trace;

use std::collections::{BTreeMap, BTreeSet};
use std::fmt;

use rayon::prelude::*;
use rbfast_otlp::{Data, Span, KIND_SERVER};

use crate::gofmt::{f as ff, g as gg};
use crate::json::{obj, Json};
pub use crate::split::PodShare;
pub use crate::topo::{Service, Topology};
use crate::trace::{edge, edge_parts, Acc, Ctx, PairAcc, Prepass, Scratch};

/// Estimator names for Options::estimator and the RHOBOUND_ESTIMATOR variable.
pub const ESTIMATOR_FIFO: &str = "fifo";
pub const ESTIMATOR_RISE: &str = "rise";

/// How the span table is put in (trace, start) order. `Parallel` and `GoExact` give the same order, Go's,
/// spans with an equal trace and start included (and so the same result, bit for bit); `Stable` differs in
/// the order of those ties, which can change a result (the pairing of parallel calls to one callee).
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub enum SortMode {
    /// Go's `slices.SortFunc` (pdqsort), run in parallel on compact keys (sort.rs, gosort.rs): exactly Go's
    /// order.
    #[default]
    Parallel,
    /// Go's serial `slices.SortFunc`, ported step for step (an audit switch: the same order as `Parallel`).
    GoExact,
    /// A parallel stable sort: spans with an equal (trace, start) keep their capture order. Not Go's order of
    /// ties; an audit switch only.
    Stable,
}

/// Options tune the inference (Go's infer.Options, plus the sort).
#[derive(Clone, Debug, Default)]
pub struct Options {
    /// The share of requests the capture holds (1 = all; 0 means 1). Rates are divided by it.
    pub kept_share: f64,
    /// Workers per pod by service name, overriding the inferred count.
    pub workers: BTreeMap<String, i64>,
    /// The fewest entry requests the capture must hold (0 means 100; below 2 means 2).
    pub min_requests: i64,
    /// "fifo" (default) or "rise"; empty: the RHOBOUND_ESTIMATOR variable, else "fifo".
    pub estimator: String,
    /// Not in Go: how the spans are sorted.
    pub sort: SortMode,
}

/// The observations behind one service of the topology (Go's ServiceStats; the JSON names are Go's tags).
#[derive(Clone, Debug, Default, PartialEq)]
pub struct ServiceStats {
    pub name: String,
    pub external: bool,
    pub entry: bool,
    pub entries: i64,
    pub consumer_entries: i64,
    pub visits: i64,
    pub rate_rps: f64,
    pub pods: i64,
    pub workers_per_pod: i64,
    pub workers_inferred: bool,
    pub own_mean_ms: f64,
    pub own_cs2: f64,
    pub own_cs2_measured: f64,
    pub cs2_snapped: bool,
    pub glue_ms: f64,
    pub glue_cs2: f64,
    pub hop_ms: f64,
    pub observed_wait_ms: f64,
    pub in_span_wait_ms: f64,
    pub workers_from_queueing: bool,
    pub observed_server_ms: f64,
    pub observed_client_ms: f64,
    pub parallel_share: f64,
    pub stages: i64,
    pub stage: bool,
    pub branch_corr: f64,
    pub images: Vec<String>,
    pub pod_shares: Vec<PodShare>,
    pub split_p: Option<f64>,
    pub uneven_split: bool,
}

/// The result (Go's Inferred).
#[derive(Clone, Debug, Default, PartialEq)]
pub struct Inferred {
    pub topology: Topology,
    /// parallel to topology.services
    pub stats: Vec<ServiceStats>,
    pub lam_ext_per_ms: f64,
    pub window_s: f64,
    pub requests: i64,
    pub consumer_requests: i64,
    pub spans: usize,
    pub traces: i64,
    pub broken_traces: i64,
    pub probe_spans: usize,
    pub warnings: Vec<String>,
}

/// An inference refusal, with Go's message.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct InferError(pub String);

impl fmt::Display for InferError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str(&self.0)
    }
}

impl std::error::Error for InferError {}

fn fail<T>(msg: String) -> Result<T, InferError> {
    Err(InferError(msg))
}

/// One server visit (Go's visitRec).
#[derive(Clone, Copy, Debug, Default)]
pub struct VisitRec {
    pub pod: i32,
    pub svc: i32,
    pub start: u64,
    pub rel: u64,
    pub alt: u64,
    pub own: f32,
    pub early: bool,
}

/// A busy segment (Go's seg), for the rise estimator.
#[derive(Clone, Copy, Debug, Default)]
pub struct Seg {
    pub pod: i32,
    pub leaf: bool,
    pub start: u64,
    pub end: u64,
}

/// One call of a visit, as the trace pass reads it (Go's call).
#[derive(Clone, Copy, Debug, Default)]
pub struct TraceCall {
    pub callee: i32,
    pub start: u64,
    pub end: u64,
    pub client_dur: f64,
    pub has_server: bool,
    pub own_clock: bool,
    pub is_async: bool,
}

/// Go's math.Max (and builtin max on floats): NaN wins, +0 beats -0.
#[inline]
pub(crate) fn go_max(x: f64, y: f64) -> f64 {
    if x.is_nan() || y.is_nan() {
        return f64::NAN;
    }
    if x == 0.0 && y == 0.0 {
        return if x.is_sign_negative() { y } else { x };
    }
    if x > y {
        x
    } else {
        y
    }
}

/// Go's math.Min: NaN wins, -0 beats +0.
#[inline]
pub(crate) fn go_min(x: f64, y: f64) -> f64 {
    if x.is_nan() || y.is_nan() {
        return f64::NAN;
    }
    if x == 0.0 && y == 0.0 {
        return if x.is_sign_negative() { x } else { y };
    }
    if x < y {
        x
    } else {
        y
    }
}

/// Wall time per stage, printed to stderr when RBFAST_STAGES is set (one line per run).
struct Stages {
    on: bool,
    last: std::time::Instant,
    marks: Vec<(&'static str, f64)>,
}

impl Stages {
    fn new() -> Self {
        Stages { on: std::env::var_os("RBFAST_STAGES").is_some(), last: std::time::Instant::now(), marks: Vec::new() }
    }

    fn mark(&mut self, name: &'static str) {
        if self.on {
            let now = std::time::Instant::now();
            self.marks.push((name, (now - self.last).as_secs_f64()));
            self.last = now;
        }
    }

    fn print(&self) {
        if self.on {
            let total: f64 = self.marks.iter().map(|m| m.1).sum();
            let parts: Vec<String> = self.marks.iter().map(|(n, t)| format!("{n}={t:.4}")).collect();
            eprintln!("RBFAST_STAGES threads={} total={total:.4} {}", rayon::current_num_threads(), parts.join(" "));
        }
    }
}

const CS2_SNAP_SIGMA: f64 = 3.0;
const MAX_BROKEN_SHARE: f64 = 0.05;
const MIN_CHUNK_GROUPS: usize = 64;
const MAX_CHUNKS: usize = 256;
const EARLY_CALL_SHARE: f64 = 0.01;

/// How many trace groups one chunk takes: from the capture alone, so the sums do not depend on the machine.
pub fn chunk_size(n_groups: usize) -> usize {
    MIN_CHUNK_GROUPS.max(n_groups.div_ceil(MAX_CHUNKS))
}

fn plural(n: i64, what: &str) -> String {
    if n == 1 {
        format!("1 {what}")
    } else {
        format!("{n} {what}s")
    }
}

fn early_warning(
    name: &str,
    sh: f64,
    n: i64,
    own: i64,
    max_ms: f64,
    workers: i64,
    mean: f64,
    skip: Option<&fifo::SvcQueue>,
) -> String {
    let cause = if own == n {
        format!(
            "a CLIENT span of its own starts before the visit's span (by up to {} ms) on the same pod's clock, so not \
             clock skew: the server span starts late, after work that already called out, or the call names the wrong \
             parent",
            ff(max_ms, 2)
        )
    } else if own == 0 {
        format!(
            "the first call starts before the visit's own span (by up to {} ms): clock skew between pods (a call with no \
             CLIENT span is timed by the callee's clock, a CLIENT span by its own pod's)",
            ff(max_ms, 2)
        )
    } else {
        format!(
            "the first call starts before the visit's own span (by up to {} ms): on {} of them on another pod's clock \
             (clock skew between pods), on {} a CLIENT span of its own on the same clock (the server span starts late, \
             or the call names the wrong parent)",
            ff(max_ms, 2),
            n - own,
            own
        )
    };
    let mut effect =
        "its service time can read low (the work before the call is lost) or, if such visits had to wait, \
                      its worker count and service time high"
            .to_string();
    if let Some(skip) = skip {
        if skip.jobs >= 2 {
            let (w2, m2) = (skip.workers, skip.rel_mean);
            let mut read = format!(
                "with those calls skipped (the worker held to the visit's next call in its span, or its end) its queue has \
                 {} and {} ms of service time, against {} and {} ms",
                plural(w2, "worker"),
                gg(m2, 3),
                workers,
                gg(mean, 3)
            );
            if own < n {
                read +=
                    " (with clock skew that reading counts the call itself as work, so the truth lies between the two)";
            }
            if mean > 1.1 * m2 {
                effect = read
                    + ": visits freed at their arrival that still had to wait fit no first-come-first-served queue, so the \
                       rebuild adds workers and folds waits into the service time: it reads high";
                if workers > w2 {
                    effect += ", and so does the worker count";
                }
            } else if mean < 0.9 * m2 {
                effect = read + ": its service time reads low (the work before the call is lost)";
                if workers > w2 {
                    effect += ", and its worker count high";
                }
            } else if workers > w2 {
                effect = read + ": its worker count reads high";
            } else {
                effect = read + ": little difference";
            }
        }
    }
    format!(
        "{}: on {}% of its visits {}; the worker is taken as freed at the span's start there: {}",
        name,
        ff(100.0 * sh, 1),
        cause,
        effect
    )
}

fn broken_error(t: &Acc, names: &[String], pp: &Prepass) -> InferError {
    let mut parts = Vec::new();
    let n = t.broken_by[trace::LOSS_CALLED_TOP];
    if n > 0 {
        let mut svcs = Vec::new();
        for (i, &c) in t.called_top.iter().enumerate() {
            if c > 0 && i < names.len() {
                svcs.push(format!(
                    "{}, called on {}% of its {} visits",
                    names[i],
                    ff(100.0 * pp.srv_called[i] as f64 / pp.srv_spans[i] as f64, 1),
                    pp.srv_spans[i]
                ));
            }
        }
        parts.push(format!(
            "{} have a SERVER span whose parent is not in the capture, of a service that services in the capture call \
             ({}): a caller of it was lost, since a service counts as entered from outside only when most of its server \
             spans have no caller in the capture",
            n,
            svcs.join("; ")
        ));
    }
    let n = t.broken_by[trace::LOSS_BELOW_TOP];
    if n > 0 {
        parts.push(format!(
            "{} have a span whose parent is not in the capture below a top that is in it (a SERVER span with no parent), \
             or on a span that is not a SERVER or CONSUMER span",
            n
        ));
    }
    let n = t.broken_by[trace::LOSS_CALLEE];
    if n > 0 {
        parts.push(format!("{} have a call to a service with no span of that service under it", n));
    }
    InferError(format!(
        "{} of {} traces miss spans ({}%): {}. The queue reconstruction needs every request and the call structure whole \
         requests, so above {}% the result is not trustworthy -- check the exporters' queues and the sampling, and that \
         the capture holds whole requests (not the end of one window and the start of another)",
        t.broken,
        t.traces,
        ff(100.0 * t.broken as f64 / t.traces as f64, 1),
        parts.join("; "),
        ff(100.0 * MAX_BROKEN_SHARE, 0)
    ))
}

/// The mean pairwise correlation of k slots' sums (0, 0 with fewer than 50 visits), with Go's fused operations.
fn pair_correlation(best: Option<&PairAcc>, k: usize) -> (f64, i64) {
    let Some(best) = best else {
        return (0.0, 0);
    };
    if best.n < 50 {
        return (0.0, 0);
    }
    let n = best.n as f64;
    let (mut sum, mut cnt) = (0.0, 0);
    for i in 0..k {
        for j in i + 1..k {
            let mi = best.sum[i] / n;
            let mj = best.sum[j] / n;
            let vi = (-mi).mul_add(mi, best.sq[i] / n);
            let vj = (-mj).mul_add(mj, best.sq[j] / n);
            if vi <= 0.0 || vj <= 0.0 {
                continue;
            }
            let cov = best.cross[i][j] / n - mi * best.sum[j] / n;
            sum += cov / (vi * vj).sqrt();
            cnt += 1;
        }
    }
    if cnt == 0 {
        return (0.0, 0);
    }
    (sum / cnt as f64, best.n)
}

/// The branch correlation of a service's parallel visits, from its most common fan-out width (ties to the
/// narrower one).
fn branch_correlation(pairs: &hash::FxMap<Box<[i32]>, PairAcc>) -> (f64, i64) {
    let mut best: Option<&PairAcc> = None;
    let mut best_k = 0usize;
    for (key, p) in pairs {
        if key.len() != 1 {
            continue; // a stage's sums
        }
        let k = key[0] as usize;
        if best.is_none() || p.n > best.unwrap().n || (p.n == best.unwrap().n && k < best_k) {
            best = Some(p);
            best_k = k;
        }
    }
    pair_correlation(best, best_k)
}

/// One pod's queue rebuild as the oracle's fifo_pods.jsonl records it (the first rebuild of a run).
#[derive(Clone, Debug)]
pub struct PodFifo {
    pub pod_id: i32,
    pub pod: String,
    pub service_id: i32,
    pub service: String,
    pub fixed: i64,
    /// the inputs, ms from the pod's first arrival, in visit-record order
    pub a: Vec<f64>,
    pub d: Vec<f64>,
    pub q: fifo::PodQueue,
}

/// Infers a topology from the capture's spans (Go's infer.Run). Sorts d.spans by (trace, start) in place, as Go
/// does.
pub fn run(d: &mut Data, opt: &Options) -> Result<Inferred, InferError> {
    run_traced(d, opt, None)
}

/// run, also handing back every pod the queue rebuild reconstructed (in pod-id order), for the parity tests.
pub fn run_traced(
    d: &mut Data,
    opt: &Options,
    mut fifo_pods: Option<&mut Vec<PodFifo>>,
) -> Result<Inferred, InferError> {
    let mut stages = Stages::new();
    let mut kept = opt.kept_share;
    if kept == 0.0 {
        kept = 1.0;
    }
    if !(kept > 0.0 && kept <= 1.0) {
        return fail(format!("the kept share must be in (0, 1], got {}", gofmt::v(kept)));
    }
    let mut min_requests = opt.min_requests;
    if min_requests == 0 {
        min_requests = 100;
    }
    if min_requests < 2 {
        min_requests = 2;
    }
    if d.spans.is_empty() {
        return fail("the capture holds no usable spans".to_string());
    }
    // os.Getenv: any bytes (a value that is not UTF-8 is refused and quoted as Go quotes it)
    let est: Vec<u8> = if opt.estimator.is_empty() {
        std::env::var_os("RHOBOUND_ESTIMATOR").map(|v| rbfast_gostr::os_bytes(&v).to_vec()).unwrap_or_default()
    } else {
        opt.estimator.as_bytes().to_vec()
    };
    let fifo_est = match est.as_slice() {
        b"" => true,
        e if e == ESTIMATOR_FIFO.as_bytes() => true,
        e if e == ESTIMATOR_RISE.as_bytes() => false,
        _ => {
            return fail(format!(
                "unknown estimator {} (want {} or {})",
                rbfast_gostr::quote_bytes(&est),
                gofmt::quote(ESTIMATOR_FIFO),
                gofmt::quote(ESTIMATOR_RISE)
            ))
        }
    };

    // services that emit server spans (sorted), then external peers
    let n_res = d.resources.len();
    let res_has_server: Vec<bool> = d
        .spans
        .par_chunks(1 << 15)
        .fold(
            || vec![false; n_res],
            |mut acc, ch| {
                for s in ch {
                    if s.kind == KIND_SERVER {
                        acc[s.res as usize] = true;
                    }
                }
                acc
            },
        )
        .reduce(
            || vec![false; n_res],
            |mut a, b| {
                for (x, y) in a.iter_mut().zip(b) {
                    *x |= y;
                }
                a
            },
        );
    let names: Vec<String> = d
        .resources
        .iter()
        .zip(&res_has_server)
        .filter(|(_, &h)| h)
        .map(|(r, _)| r.service.clone())
        .collect::<BTreeSet<_>>()
        .into_iter()
        .collect();
    if names.is_empty() {
        return fail("the capture holds no SERVER spans: nothing to infer".to_string());
    }
    let n_svc = names.len();
    let svc_of: BTreeMap<&str, i32> = names.iter().enumerate().map(|(i, s)| (s.as_str(), i as i32)).collect();
    let mut res_svc = vec![-1i32; n_res];
    let mut res_pod = vec![0i32; n_res];
    let mut res_name = vec![0i32; n_res];
    let mut pod_of: hash::FxMap<(&str, &str), i32> = hash::map();
    let mut name_of: hash::FxMap<&str, i32> = hash::map();
    for (i, r) in d.resources.iter().enumerate() {
        res_svc[i] = svc_of.get(r.service.as_str()).copied().unwrap_or(-1);
        let nn = name_of.len() as i32;
        res_name[i] = *name_of.entry(r.service.as_str()).or_insert(nn);
        let np = pod_of.len() as i32;
        res_pod[i] = *pod_of.entry((r.service.as_str(), r.pod.as_str())).or_insert(np);
    }
    let n_pods = pod_of.len();
    let n_names = name_of.len();
    let mut pod_name = vec![String::new(); n_pods];
    for (i, r) in d.resources.iter().enumerate() {
        pod_name[res_pod[i] as usize] = r.pod.clone();
    }
    let n_peer = d.peers.len();
    let n_all = n_svc + n_peer + 1; // the last slot is an unnamed external peer
    let unknown_peer = (n_svc + n_peer) as i32;
    let ext_name = |id: usize| -> String {
        if id == n_svc + n_peer {
            "ext:unknown".to_string()
        } else {
            format!("ext:{}", d.peers[id - n_svc])
        }
    };

    stages.mark("setup");
    match opt.sort {
        SortMode::Parallel => sort::sort_spans_go(&mut d.spans),
        SortMode::Stable => sort::sort_spans_stable(&mut d.spans),
        SortMode::GoExact => {
            gosort::sort_func(&mut d.spans, |a: &Span, b: &Span| (a.trace, a.start) < (b.trace, b.start))
        }
    }
    stages.mark("sort");
    let spans = &d.spans;
    let bounds = group_bounds(spans);
    let n_groups = bounds.len() - 1;
    stages.mark("bounds");

    let ctx = Ctx { res_svc: &res_svc, res_pod: &res_pod, res_name: &res_name, n_svc, unknown_peer };
    let chunk = chunk_size(n_groups);
    let n_chunks = n_groups.div_ceil(chunk);
    let n_addr = d.addrs.len();
    let pps: Vec<Prepass> = (0..n_chunks)
        .into_par_iter()
        .map(|ci| {
            let mut pp = Prepass::new(n_addr, n_svc, n_names);
            let mut sc = Scratch::new();
            for g in ci * chunk..((ci + 1) * chunk).min(n_groups) {
                pp.add_trace(&ctx, &spans[bounds[g]..bounds[g + 1]], &mut sc);
            }
            pp
        })
        .collect();
    let mut pp = Prepass::new(n_addr, n_svc, n_names);
    for o in &pps {
        pp.merge(o);
    }
    drop(pps);
    pp.decide();
    stages.mark("prepass");
    let accs: Vec<Acc> = (0..n_chunks)
        .into_par_iter()
        .map(|ci| {
            let mut a = Acc::new(n_all, n_svc);
            let mut sc = Scratch::new();
            for g in ci * chunk..((ci + 1) * chunk).min(n_groups) {
                trace::process_trace(&ctx, &spans[bounds[g]..bounds[g + 1]], &mut a, !fifo_est, &pp, &mut sc);
            }
            a
        })
        .collect();

    stages.mark("traces");
    // ---- merge, in chunk order; the visit records and hop samples are concatenated in parallel
    let mut accs = accs;
    let vrec_parts: Vec<Vec<VisitRec>> = accs.iter_mut().map(|a| std::mem::take(&mut a.vrec)).collect();
    let seg_parts: Vec<Vec<Seg>> = accs.iter_mut().map(|a| std::mem::take(&mut a.segs)).collect();
    let hop_parts: Vec<Vec<Vec<f64>>> = accs.iter_mut().map(|a| std::mem::take(&mut a.hop_samples)).collect();
    let mut t = Acc::new(n_all, n_svc);
    let (vrec, segs) = rayon::join(
        || (concat_par(&vrec_parts), concat_par(&seg_parts)),
        || {
            for a in accs {
                t.merge(a);
            }
        },
    )
    .0;
    drop(vrec_parts);
    drop(seg_parts);
    t.vrec = vrec;
    t.segs = segs;
    stages.mark("merge");
    if t.broken > 0 && t.broken as f64 > MAX_BROKEN_SHARE * t.traces as f64 {
        return Err(broken_error(&t, &names, &pp));
    }
    if t.entry_n < min_requests {
        return fail(format!("only {} entry requests in the capture; need at least {}", t.entry_n, min_requests));
    }
    let window_ns = (t.entry_max - t.entry_min) as f64 * t.entry_n as f64 / (t.entry_n - 1) as f64;
    let window_s = window_ns / 1e9;
    if !(window_s > 0.0) {
        return fail("the entry requests span no time".to_string());
    }

    let mut out = Inferred {
        window_s,
        requests: t.entry_n,
        spans: d.spans.len(),
        traces: t.traces,
        broken_traces: t.broken,
        probe_spans: d.probes,
        ..Default::default()
    };
    let mut warnings: Vec<String> = Vec::new();
    if d.skipped > 0 {
        warnings.push(format!("{} spans were skipped (a missing id, service name, start or end time)", d.skipped));
    }
    let mut entry_scale = 1.0;
    if t.broken > 0 {
        entry_scale = t.traces as f64 / (t.traces - t.broken) as f64;
        warnings.push(format!(
            "{} of {} traces miss a span ({}%): left out of the entries and the call structure, kept in the queues and \
             the rates (the external rate is scaled up by {} to count them)",
            t.broken,
            t.traces,
            ff(100.0 * t.broken as f64 / t.traces as f64, 2),
            ff(entry_scale, 4)
        ));
    }

    // pods per service (pods with a server span of the service)
    let mut pods_of: Vec<BTreeSet<i32>> = vec![BTreeSet::new(); n_all];
    for r in 0..n_res {
        if res_has_server[r] && res_svc[r] >= 0 {
            pods_of[res_svc[r] as usize].insert(res_pod[r]);
        }
    }
    let mut pod_visits = vec![0i64; n_pods]; // every visit, broken traces included, as the queues count them
    for v in &t.vrec {
        pod_visits[v.pod as usize] += 1;
    }
    let mut fixed: BTreeMap<i32, i64> = BTreeMap::new();
    let mut queues: Vec<Option<fifo::SvcQueue>> = Vec::new();
    let mut hist: Vec<rise::ByK> = Vec::new();
    // the hop samples gathered and sorted per service, in parallel with the queue rebuild
    let mut hop_samples: Vec<Vec<f64>> = Vec::new();
    rayon::join(
        || {
            hop_samples = (0..n_all)
                .into_par_iter()
                .map(|i| {
                    let mut v: Vec<f64> = Vec::with_capacity(hop_parts.iter().map(|c| c[i].len()).sum());
                    for c in &hop_parts {
                        v.extend_from_slice(&c[i]);
                    }
                    v.sort_unstable_by(|a, b| a.total_cmp(b));
                    v
                })
                .collect();
        },
        || {
            if fifo_est {
                for (name, &c) in &opt.workers {
                    if let Some(&id) = svc_of.get(name.as_str()) {
                        fixed.insert(id, c);
                    }
                }
                queues = fifo::reconstruct_queues(&t.vrec, n_svc, n_pods, &fixed);
            } else {
                hist = rise::sweep_by_k(&t.segs, &t.vrec, n_all, n_pods);
            }
        },
    );

    stages.mark("fifo");
    if let Some(out) = fifo_pods.as_mut() {
        out.clear();
        for (s, sq) in queues.iter().enumerate() {
            let Some(sq) = sq else { continue };
            for (p, q) in &sq.pods {
                let mut a = vec![0.0; q.a.len()];
                let mut dd = vec![0.0; q.d.len()];
                for (i, &k) in q.order.iter().enumerate() {
                    a[k] = q.a[i];
                    dd[k] = q.d[i];
                }
                out.push(PodFifo {
                    pod_id: *p,
                    pod: pod_name[*p as usize].clone(),
                    service_id: s as i32,
                    service: names[s].clone(),
                    fixed: fixed.get(&(s as i32)).copied().unwrap_or(0),
                    a,
                    d: dd,
                    q: q.clone(),
                });
            }
        }
        out.sort_by_key(|p| p.pod_id);
    }

    // which services and externals are in the topology
    let used: Vec<usize> = (0..n_all).filter(|&i| t.visits[i] > 0 || (i >= n_svc && t.client_n[i] > 0)).collect();
    let mut idx: Vec<isize> = vec![-1; n_all];
    for (k, &id) in used.iter().enumerate() {
        idx[id] = k as isize;
    }
    let mut topo = Topology { name: "inferred".to_string(), ..Default::default() };
    let mut stats: Vec<ServiceStats> = vec![ServiceStats::default(); used.len()];
    let mut lower: Vec<String> = Vec::new();
    let mut negative: Vec<String> = Vec::new();
    let mut identified = false;
    let mut briefly = false;
    for (k, &i) in used.iter().enumerate() {
        let mut st = ServiceStats::default();
        let mut sv: Service;
        if i < n_svc {
            st.name = names[i].clone();
            let n = t.visits[i] as f64;
            let all_mean = t.own_sum[i] / n;
            let (mut mean, mut cs2) = (all_mean, 1.0);
            let mut n_est = n;
            if all_mean > 0.0 && t.visits[i] > 1 {
                let v = (-(n * all_mean)).mul_add(all_mean, t.own_sq[i]) / (n - 1.0);
                cs2 = go_max(0.0, v) / (all_mean * all_mean);
            }
            let mut c: i64;
            let mut saturated = false;
            st.workers_inferred = true;
            if fifo_est {
                let set = opt.workers.contains_key(&st.name);
                st.workers_inferred = !set;
                match queues[i].as_ref() {
                    Some(q) if q.jobs >= 2 => {
                        c = q.workers;
                        saturated = q.identified;
                        mean = q.rel_mean;
                        cs2 = 0.0;
                        n_est = q.jobs as f64;
                        if mean > 0.0 {
                            cs2 = go_max(0.0, q.rel_var) / (mean * mean);
                        }
                        identified = identified || q.identified;
                        if st.workers_inferred && !q.identified {
                            let mut why = format!("{} waited", q.min_waited);
                            if q.min_waited >= fifo::IDENT_MIN_WAITS {
                                why = format!(
                                    "{} waited, {} ms on average against {} ms of service: too short to rule out more workers",
                                    q.min_waited,
                                    gg(q.waited_mean, 3),
                                    gg(q.rel_mean, 3)
                                );
                                briefly = true;
                            }
                            lower.push(format!(
                                "{} {}+ ({}; up to {} in a pod at once)",
                                st.name, q.workers, why, q.max_sys
                            ));
                        }
                        if q.neg_share > 0.001 {
                            warnings.push(format!(
                                "{}: {}% of reconstructed service times are negative (clock or ordering jitter)",
                                st.name,
                                ff(100.0 * q.neg_share, 2)
                            ));
                        }
                        if !(mean >= 0.0) {
                            negative.push(format!("{} {} ms", st.name, ff(mean, 3)));
                        }
                    }
                    _ => {
                        c = 1;
                        if set {
                            c = opt.workers[&st.name];
                            warnings.push(format!(
                                "{}: too few visits to rebuild its queue, so --workers {} is taken as given; its service time \
                                 includes any queueing in the span",
                                st.name, c
                            ));
                        } else {
                            warnings.push(format!(
                                "{}: too few visits to rebuild its queue; its service time includes any queueing in the span",
                                st.name
                            ));
                        }
                    }
                }
            } else {
                let h = &hist[i];
                let (c0, sat, mut free, mut have_free) = rise::workers_from_k(h);
                c = c0;
                saturated = sat;
                if let Some(&ov) = opt.workers.get(&st.name) {
                    c = ov;
                    st.workers_inferred = false;
                    (free, have_free) = rise::pool_below(h, c);
                }
                if have_free {
                    mean = free.mean();
                    cs2 = 0.0;
                    n_est = free.n;
                    if mean > 0.0 {
                        cs2 = go_max(0.0, free.variance()) / (mean * mean);
                    }
                } else {
                    warnings.push(format!(
                        "{}: only {} visits found a free worker; its service time includes any queueing in the span",
                        st.name,
                        ff(free.n, 0)
                    ));
                }
            }
            st.own_cs2_measured = cs2;
            if (cs2 - 1.0).abs() < CS2_SNAP_SIGMA * (8.0 / go_max(n_est, 1.0)).sqrt() {
                cs2 = 1.0;
                st.cs2_snapped = true;
            }
            st.visits = t.visits[i];
            st.own_mean_ms = mean;
            st.own_cs2 = cs2;
            st.in_span_wait_ms = go_max(0.0, all_mean - mean);
            let ns = t.s_visits[i] as f64;
            if ns > 0.0 {
                let g = t.glue_sum[i] / ns;
                if g > 0.0 {
                    st.glue_ms = g;
                    if ns > 1.0 {
                        st.glue_cs2 = go_max(0.0, (-(ns * g)).mul_add(g, t.glue_sq[i]) / (ns - 1.0)) / (g * g);
                    }
                }
            }
            st.observed_server_ms = t.server_sum[i] / n;
            st.pods = pods_of[i].len() as i64;
            if c < 1 {
                c = 1;
            }
            st.workers_from_queueing = saturated && st.workers_inferred;
            st.workers_per_pod = c;
            sv = Service {
                name: st.name.clone(),
                s: mean,
                cs2,
                glue: st.glue_ms,
                glue_cs2: st.glue_cs2,
                ..Default::default()
            };
            if st.pods <= 1 {
                sv.servers = c;
                sv.workers = 1;
                sv.routing = topo::POOLED.to_string();
            } else {
                sv.servers = st.pods;
                sv.workers = c;
                sv.routing = topo::RANDOM.to_string();
                let ids: Vec<i32> = pods_of[i].iter().copied().collect();
                let (by, p, shares) = split::pod_split(&ids, &pod_name, &pod_visits);
                st.pod_shares = by;
                st.split_p = p;
                st.uneven_split = shares.is_some();
                sv.shares = shares;
                if st.uneven_split {
                    warnings.push(split::split_warning(&st.name, &st.pod_shares, p.unwrap()));
                }
            }
            if t.multi[i] > 0 {
                st.parallel_share = t.overlap[i] as f64 / t.multi[i] as f64;
            }
            for r in &d.resources {
                if r.service == st.name && !r.image.is_empty() && !st.images.contains(&r.image) {
                    st.images.push(r.image.clone());
                }
            }
            if t.visits[i] < 30 {
                warnings.push(format!("{}: only {} visits; its estimates are rough", st.name, t.visits[i]));
            }
            let sh = t.early[i] as f64 / n;
            if sh > EARLY_CALL_SHARE {
                // the queue rebuilt with those calls skipped, for the direction of the effect
                let mut skip: Option<fifo::SvcQueue> = None;
                if fifo_est && queues[i].is_some() {
                    let vs: Vec<VisitRec> =
                        t.vrec.iter().filter(|v| v.svc == i as i32).map(|v| VisitRec { rel: v.alt, ..*v }).collect();
                    skip = fifo::reconstruct_queues(&vs, n_svc, n_pods, &fixed).swap_remove(i);
                }
                warnings.push(early_warning(
                    &st.name,
                    sh,
                    t.early[i],
                    t.early_own[i],
                    t.early_max[i],
                    c,
                    mean,
                    skip.as_ref(),
                ));
            }
        } else {
            st.name = ext_name(i);
            st.external = true;
            let n = t.client_n[i] as f64;
            let mean = t.client_sum[i] / n;
            st.visits = t.client_n[i];
            st.own_mean_ms = mean;
            st.own_cs2 = 1.0;
            st.observed_client_ms = mean;
            sv = Service {
                name: st.name.clone(),
                s: mean,
                cs2: 1.0,
                delay: true,
                servers: 1,
                workers: 1,
                routing: topo::POOLED.to_string(),
                ..Default::default()
            };
        }
        // hop: the quietest tenth of (client - server) is the network; the rest is queueing outside the span
        let hs = &hop_samples[i];
        if !hs.is_empty() && !st.external {
            let hop = hs[hs.len() / 10];
            let mut sum = 0.0;
            for &v in hs {
                sum += v;
            }
            st.hop_ms = hop;
            st.observed_wait_ms = go_max(0.0, sum / hs.len() as f64 - hop);
            sv.hop = hop;
        }
        if t.client_n[i] > 0 && !st.external {
            st.observed_client_ms = t.client_sum[i] / t.client_n[i] as f64;
        }
        st.rate_rps = st.visits as f64 / window_s / kept;
        topo.services.push(sv);
        stats[k] = st;
    }

    if !negative.is_empty() {
        return fail(format!(
            "refusing to infer: the rebuilt queues give a negative mean service time ({}): the spans' times contradict a \
             first-come-first-served queue with that many workers. Clock skew between pods does this (a call with no \
             CLIENT span is timed by the callee's clock, so a callee whose clock runs behind seems to answer before it \
             was called), and so does a --workers count below the pod's real one -- synchronize the clocks (NTP) or \
             export CLIENT spans for the calls, and check --workers",
            negative.join(", ")
        ));
    }
    if !lower.is_empty() {
        if identified || briefly {
            warnings.push(format!(
                "too few requests waited for a worker, or too briefly, to pin these worker counts, so they are lower \
                 bounds (a pod with no worker limit looks like this too): {}",
                lower.join(", ")
            ));
        } else {
            warnings.push(format!(
                "no service shows enough requests waiting for a worker inside its spans to pin its worker count (none can \
                 when spans start once a worker has taken the request), so the counts are lower bounds: {}",
                lower.join(", ")
            ));
        }
    }

    // calls: per caller, how many calls each visit makes to each callee, and how they run
    struct Ce {
        callee: i32,
        offset: f64,
        hist: BTreeMap<i64, i64>, // calls per visit -> visits (visits that made at least one)
    }
    let mut calls_of: BTreeMap<i32, BTreeMap<i32, Ce>> = BTreeMap::new();
    for (&ek, e) in &t.edges {
        let (caller, callee) = edge_parts(ek);
        if t.s_visits[caller as usize] == 0 {
            continue;
        }
        calls_of
            .entry(caller)
            .or_default()
            .insert(callee, Ce { callee, offset: e.offset_sum / e.n as f64, hist: BTreeMap::new() });
    }
    for (&(ek, n), &cnt) in &t.counts {
        let (caller, callee) = edge_parts(ek);
        if let Some(c) = calls_of.get_mut(&caller).and_then(|m| m.get_mut(&callee)) {
            *c.hist.entry(n as i64).or_insert(0) += cnt;
        }
    }
    let mut async_desc: Vec<String> = Vec::new();
    for (&caller, cm) in &calls_of {
        let mut list: Vec<&Ce> = cm.values().collect();
        list.sort_by(|a, b| {
            if a.offset != b.offset {
                if a.offset < b.offset {
                    std::cmp::Ordering::Less
                } else {
                    std::cmp::Ordering::Greater
                }
            } else {
                a.callee.cmp(&b.callee)
            }
        });
        let si = idx[caller as usize] as usize;
        let name = stats[si].name.clone();
        let nsp = t.s_visits[caller as usize];
        struct Counted {
            child: usize,
            k: i64,
            p: f64,
        }
        let mut cnts: Vec<Counted> = Vec::new();
        let mut cond: Vec<String> = Vec::new();
        let mut async_calls: Vec<topo::Call> = Vec::new();
        let mut nkeys = 0i64;
        for c in &list {
            let ci = idx[c.callee as usize];
            if ci < 0 {
                continue;
            }
            let ci = ci as usize;
            let ek = edge(caller, c.callee);
            if pp.async_edges.contains_key(&ek) {
                let mean = t.async_n.get(&ek).copied().unwrap_or(0) as f64 / nsp as f64;
                let k = (mean + 1e-12).floor() as i64;
                for _ in 0..k {
                    async_calls.push(topo::Call { child: ci, p: 1.0, is_async: true });
                }
                let p = mean - k as f64;
                if p > 1e-12 {
                    async_calls.push(topo::Call { child: ci, p, is_async: true });
                }
                let mut desc = format!("{} -> {} ({} per visit", name, stats[ci].name, gg(mean, 3));
                let o = pp.after_other(ek);
                if o > 0 {
                    desc += &format!(
                        "; {}% of them timed by the callee's clock, where a clock that runs ahead of {}'s looks the same: \
                         export CLIENT spans for the calls, or synchronize the clocks (NTP), to tell",
                        ff(100.0 * o as f64 / pp.call_after(ek) as f64, 0),
                        name
                    );
                }
                async_desc.push(desc + ")");
                if c.hist.is_empty() {
                    continue;
                }
            }
            let (k, p, other) = match structure::call_count(&c.hist, nsp) {
                Ok(x) => x,
                Err(e) => {
                    return fail(format!(
                        "{} -> {}: {}; the model has a fixed count or one conditional call per visit, not this",
                        name, stats[ci].name, e
                    ))
                }
            };
            if other > 0.0 {
                warnings.push(format!(
                    "{} -> {}: {}% of visits show another call count; ignored",
                    name,
                    stats[ci].name,
                    ff(100.0 * other, 2)
                ));
            }
            if p > 0.0 {
                cond.push(stats[ci].name.clone());
                nkeys += 1;
            }
            nkeys += k;
            cnts.push(Counted { child: ci, k, p });
        }
        let multi = t.multi[caller as usize];
        let share = stats[si].parallel_share;
        let mut sigs: BTreeMap<String, i64> = BTreeMap::new();
        if multi > 0 {
            for (sk, &n) in &t.sigs[caller as usize] {
                sigs.insert(structure::compact_key(sk), n);
            }
        }
        // calls in stages
        if let Some((tm, ran, fit)) = structure::stage_template(&sigs, nsp) {
            if structure::has_group(&tm) && fit >= structure::PARALLEL_SHARE && (tm.len() >= 2 || ran[0] < 1.0 - 1e-12)
            {
                let mut desc: Vec<String> = Vec::new();
                let mut st_calls: Vec<topo::Call> = Vec::new();
                for (j, g) in tm.iter().enumerate() {
                    let mut q = ran[j];
                    if q >= 1.0 - 1e-12 {
                        q = 1.0;
                    }
                    let mut members: Vec<topo::Call> = Vec::new();
                    let mut mnames: Vec<String> = Vec::new();
                    for &id in g {
                        let ci = if id >= 0 && (id as usize) < n_all { idx[id as usize] } else { -1 };
                        if ci >= 0 {
                            members.push(topo::Call { child: ci as usize, p: 1.0, is_async: false });
                            mnames.push(stats[ci as usize].name.clone());
                        }
                    }
                    let mut dsc = mnames.join(" + ");
                    if members.len() > 1 {
                        dsc += " at once";
                    }
                    if q < 1.0 {
                        dsc += &format!(" (p {})", ff(q, 2));
                    }
                    desc.push(dsc);
                    if members.len() == 1 {
                        st_calls.push(topo::Call { child: members[0].child, p: q, is_async: false });
                        continue;
                    }
                    let mut key: Vec<i32> = vec![g.len() as i32];
                    key.extend_from_slice(g);
                    let (r, _) = pair_correlation(t.pairs[caller as usize].get(key.as_slice()), g.len());
                    let r = go_max(0.0, go_min(r, 0.95));
                    let st_name = format!("stage:{}:{}", name, j + 1);
                    topo.services.push(Service {
                        name: st_name.clone(),
                        cs2: 1.0,
                        delay: true,
                        parallel: true,
                        calls: members,
                        servers: 1,
                        workers: 1,
                        routing: topo::POOLED.to_string(),
                        branch_corr: r,
                        ..Default::default()
                    });
                    stats.push(ServiceStats {
                        name: st_name,
                        stage: true,
                        visits: (t.visits[caller as usize] as f64 * q).round() as i64,
                        rate_rps: stats[si].rate_rps * q,
                        pods: 1,
                        workers_per_pod: 1,
                        parallel_share: 1.0,
                        branch_corr: r,
                        ..Default::default()
                    });
                    st_calls.push(topo::Call { child: topo.services.len() - 1, p: q, is_async: false });
                }
                st_calls.extend(async_calls.iter().cloned());
                topo.services[si].calls = st_calls;
                stats[si].stages = tm.len() as i64;
                if tm.len() == 1 {
                    warnings.push(format!("{}: calls {} on some visits only, all of them or none", name, desc[0]));
                } else {
                    warnings.push(format!(
                        "{}: calls in {} stages, each after the last ends: {}",
                        name,
                        tm.len(),
                        desc.join("; then ")
                    ));
                }
                if fit < 1.0 {
                    warnings.push(format!(
                        "{}: {}% of its visits call in another shape than its stages; modelled as the stages",
                        name,
                        ff(100.0 * (1.0 - fit), 2)
                    ));
                }
                continue;
            }
        }
        let parallel = if nkeys <= 1 || multi == 0 || share <= 1.0 - structure::PARALLEL_SHARE {
            false
        } else if share >= structure::PARALLEL_SHARE {
            true
        } else {
            let (shape, seen) = common_shape(&sigs, &stats, &idx);
            return fail(format!(
                "{}: its calls overlap in {}% of its visits with two or more calls (most common shape: {}, {}% of visits); \
                 neither all at once, one after another nor in stages, the shapes the model has",
                name,
                ff(100.0 * share, 0),
                shape,
                ff(100.0 * seen as f64 / nsp as f64, 0)
            ));
        };
        if parallel && !cond.is_empty() {
            return fail(format!(
                "{}: calls in parallel, and calls to {} only on some visits; the model's expected maximum needs every \
                 branch on every visit",
                name,
                cond.join(", ")
            ));
        }
        topo.services[si].parallel = parallel;
        if parallel {
            let (r, n) = branch_correlation(&t.pairs[caller as usize]);
            if n > 0 {
                stats[si].branch_corr = go_max(0.0, go_min(r, 0.95));
                topo.services[si].branch_corr = stats[si].branch_corr;
            }
        }
        let sv = &mut topo.services[si];
        for c in &cnts {
            for _ in 0..c.k {
                sv.calls.push(topo::Call { child: c.child, p: 1.0, is_async: false });
            }
            if c.p > 0.0 {
                sv.calls.push(topo::Call { child: c.child, p: c.p, is_async: false });
            }
        }
        sv.calls.extend(async_calls);
    }
    if !async_desc.is_empty() {
        warnings.push(format!(
            "calls the caller does not wait for (at least {}% of them start once the caller's span has ended, or outlive \
             it on the caller's clock: fire and forget) are modelled as async: they load the callee, but the caller does \
             not wait for them, so neither the callee's latency nor a change of it reaches the caller: {}",
            ff(100.0 * structure::PARALLEL_SHARE, 0),
            async_desc.join(", ")
        ));
    }
    let mut mixed: Vec<(u64, f64)> = pp
        .async_mixed()
        .into_iter()
        .filter(|(k, _)| {
            let (caller, callee) = edge_parts(*k);
            idx[callee as usize] >= 0 && t.s_visits[caller as usize] > 0
        })
        .collect();
    mixed.sort_by_key(|(k, _)| edge_parts(*k));
    for (k, sh) in mixed {
        let (caller_id, callee_id) = edge_parts(k);
        let caller = stats[idx[caller_id as usize] as usize].name.clone();
        let mut clock = String::new();
        let o = pp.after_other(k);
        if o > 0 {
            clock = format!(
                "; {}% of those are timed by the callee's clock, where a clock that runs ahead of {}'s looks the same: \
                 export CLIENT spans for the calls, or synchronize the clocks (NTP), to tell",
                ff(100.0 * o as f64 / pp.call_after(k) as f64, 0),
                caller
            );
        }
        warnings.push(format!(
            "{} -> {}: {}% of the calls start after {}'s span has ended or outlive it (sent with the response, not waited \
             for) and the rest within it; all are modelled as on its latency path (calls are taken as async when at least \
             {}% of them are not waited for){}",
            caller,
            stats[idx[callee_id as usize] as usize].name,
            ff(100.0 * sh, 1),
            caller,
            ff(100.0 * structure::PARALLEL_SHARE, 0),
            clock
        ));
    }
    // entries
    for (k, &id) in used.iter().enumerate() {
        if id < n_svc && t.entries[id] > 0 {
            topo.entry.insert(k, t.entries[id] as f64 / t.entry_n as f64);
            stats[k].entry = true;
            stats[k].entries = t.entries[id];
            stats[k].consumer_entries = t.consumer_en[id];
        }
    }
    out.consumer_requests = t.consumer_n;
    if let Err(e) = topo.finish() {
        return fail(format!("the inferred call graph is not usable: {}", e));
    }
    out.topology = topo;
    out.stats = stats;
    out.lam_ext_per_ms = t.entry_n as f64 * entry_scale / window_s / kept / 1000.0;
    if t.unmatched > 0 {
        warnings.push(format!(
            "{} client calls to services without server spans were treated as external delays",
            t.unmatched
        ));
    }
    if t.consumer_x > 0 {
        warnings.push(format!(
            "{} client calls made under message consumers (CONSUMER spans), to services without server spans, are on no \
             request's path and were left out (a consumer's work is its own, not the producing request's; a call from it \
             to a service with server spans is an entry of that service)",
            t.consumer_x
        ));
    }
    out.warnings = warnings;
    stages.mark("assemble");
    stages.print();
    Ok(out)
}

/// The parts one after another, copied in parallel.
fn concat_par<T: Copy + Send + Sync>(parts: &[Vec<T>]) -> Vec<T> {
    let total: usize = parts.iter().map(|p| p.len()).sum();
    let mut offs = Vec::with_capacity(parts.len());
    let mut at = 0usize;
    for p in parts {
        offs.push(at);
        at += p.len();
    }
    let mut out: Vec<T> = Vec::with_capacity(total);
    let base = out.as_mut_ptr() as usize;
    parts.par_iter().zip(offs.par_iter()).for_each(|(p, &o)| {
        // SAFETY: the parts go to disjoint ranges [o, o + len) of a buffer with capacity total
        unsafe { std::ptr::copy_nonoverlapping(p.as_ptr(), (base as *mut T).add(o), p.len()) };
    });
    // SAFETY: every slot of 0..total was written above
    unsafe { out.set_len(total) };
    out
}

/// The start of each trace group in the sorted table, then its end (Go's bounds), found in parallel.
fn group_bounds(spans: &[Span]) -> Vec<usize> {
    const BLOCK: usize = 1 << 16;
    let mut bounds: Vec<usize> = spans
        .par_chunks(BLOCK)
        .enumerate()
        .flat_map_iter(|(b, ch)| {
            let base = b * BLOCK;
            let mut v = Vec::new();
            for (j, s) in ch.iter().enumerate() {
                let i = base + j;
                if i == 0 || s.trace != spans[i - 1].trace {
                    v.push(i);
                }
            }
            v
        })
        .collect();
    bounds.push(spans.len());
    bounds
}

/// The commonest call shape among sigs, by callee name, and the visits that show it (ties to the smaller key).
fn common_shape(sigs: &BTreeMap<String, i64>, stats: &[ServiceStats], idx: &[isize]) -> (String, i64) {
    let (mut best, mut n) = (String::new(), 0i64);
    for (k, &c) in sigs {
        if c > n || (c == n && *k < best) {
            best = k.clone();
            n = c;
        }
    }
    let mut parts = Vec::new();
    for g in structure::parse_sig(&best) {
        let mut names = Vec::new();
        for id in g {
            if id >= 0 && (id as usize) < idx.len() && idx[id as usize] >= 0 {
                names.push(stats[idx[id as usize] as usize].name.clone());
            }
        }
        parts.push(format!("({})", names.join(" + ")));
    }
    (parts.join(" then "), n)
}

impl ServiceStats {
    /// The JSON object Go writes for a ServiceStats (its field tags and omitempty rules).
    pub fn to_json(&self) -> Result<Json, String> {
        let mut o: Vec<(&str, Json)> = vec![("name", Json::str(&self.name))];
        if self.external {
            o.push(("external", Json::Bool(true)));
        }
        if self.entry {
            o.push(("entry", Json::Bool(true)));
        }
        if self.entries != 0 {
            o.push(("entries", Json::int(self.entries)));
        }
        if self.consumer_entries != 0 {
            o.push(("consumer_entries", Json::int(self.consumer_entries)));
        }
        o.push(("visits", Json::int(self.visits)));
        o.push(("rate_rps", Json::num(self.rate_rps)?));
        o.push(("pods", Json::int(self.pods)));
        o.push(("workers_per_pod", Json::int(self.workers_per_pod)));
        o.push(("workers_inferred", Json::Bool(self.workers_inferred)));
        o.push(("own_mean_ms", Json::num(self.own_mean_ms)?));
        o.push(("own_cs2", Json::num(self.own_cs2)?));
        o.push(("own_cs2_measured", Json::num(self.own_cs2_measured)?));
        if self.cs2_snapped {
            o.push(("own_cs2_snapped", Json::Bool(true)));
        }
        o.push(("glue_ms", Json::num(self.glue_ms)?));
        if self.glue_cs2 != 0.0 {
            o.push(("glue_cs2", Json::num(self.glue_cs2)?));
        }
        o.push(("hop_ms", Json::num(self.hop_ms)?));
        o.push(("observed_wait_ms", Json::num(self.observed_wait_ms)?));
        o.push(("in_span_wait_ms", Json::num(self.in_span_wait_ms)?));
        o.push(("workers_from_queueing", Json::Bool(self.workers_from_queueing)));
        o.push(("observed_server_ms", Json::num(self.observed_server_ms)?));
        o.push(("observed_client_ms", Json::num(self.observed_client_ms)?));
        o.push(("parallel_share", Json::num(self.parallel_share)?));
        if self.stages != 0 {
            o.push(("stages", Json::int(self.stages)));
        }
        if self.stage {
            o.push(("stage", Json::Bool(true)));
        }
        if self.branch_corr != 0.0 {
            o.push(("branch_corr", Json::num(self.branch_corr)?));
        }
        if !self.images.is_empty() {
            o.push(("images", Json::Arr(self.images.iter().map(|s| Json::str(s)).collect())));
        }
        if !self.pod_shares.is_empty() {
            let mut a = Vec::new();
            for p in &self.pod_shares {
                a.push(obj(vec![
                    ("pod", Json::str(&p.pod)),
                    ("visits", Json::int(p.visits)),
                    ("share", Json::num(p.share)?),
                ]));
            }
            o.push(("pod_shares", Json::Arr(a)));
        }
        if let Some(p) = self.split_p {
            o.push(("split_p", Json::num(p)?));
        }
        if self.uneven_split {
            o.push(("uneven_split", Json::Bool(true)));
        }
        Ok(obj(o))
    }
}

impl Inferred {
    /// The whole result as the oracle's inferred_full.json writes it (topology, stats, counts, warnings).
    pub fn to_json(&self) -> Result<Json, String> {
        let mut stats = Vec::new();
        for s in &self.stats {
            stats.push(s.to_json()?);
        }
        let warnings = if self.warnings.is_empty() {
            Json::Null
        } else {
            Json::Arr(self.warnings.iter().map(|w| Json::str(w)).collect())
        };
        Ok(obj(vec![
            ("topology", self.topology.to_json()?),
            ("stats", Json::Arr(stats)),
            ("lam_ext_per_ms", Json::num(self.lam_ext_per_ms)?),
            ("window_s", Json::num(self.window_s)?),
            ("requests", Json::int(self.requests)),
            ("consumer_requests", Json::int(self.consumer_requests)),
            ("spans", Json::int(self.spans as i64)),
            ("traces", Json::int(self.traces)),
            ("broken_traces", Json::int(self.broken_traces)),
            ("probe_spans", Json::int(self.probe_spans as i64)),
            ("warnings", warnings),
        ]))
    }

    /// What `rhobound infer` writes to stderr after the topology: the warnings, then the external load.
    pub fn stderr_text(&self) -> String {
        let mut s = String::new();
        for w in &self.warnings {
            s.push_str("warning: ");
            s.push_str(w);
            s.push('\n');
        }
        s.push_str(&format!(
            "external load {} requests/s over {} s\n",
            ff(self.lam_ext_per_ms * 1000.0, 2),
            ff(self.window_s, 0)
        ));
        s
    }
}
