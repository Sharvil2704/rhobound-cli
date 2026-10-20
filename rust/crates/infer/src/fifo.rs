// SPDX-License-Identifier: Apache-2.0

//! Queue reconstruction per pod (rhobound-cli internal/infer/fifo.go): each pod's first-come-first-served queue
//! rebuilt from its visits' arrivals and releases, the smallest worker count that explains it, and the service
//! time read from every visit. The pods are rebuilt in parallel (rayon); each pod's search is sequential, as in
//! Go, and the per-service pooling runs over the pods in a fixed order, so the result does not depend on the
//! thread count.

use std::collections::BTreeMap;

use rayon::prelude::*;

use crate::VisitRec;

pub const JITTER_MS: f64 = 0.25;
pub const JITTER_WAIT_SHARE: f64 = 0.02;
pub const JITTER_FLOOR: f64 = 3.0;
pub const TIE_MS: f64 = 0.05;
pub const SHORTFALL_Z: f64 = 3.0;
pub const SHORTFALL_REL: f64 = 0.10;
pub const SHORTFALL_MIN: usize = 30;
pub const IDENT_MIN_WAITS: usize = 100;
pub const MAX_WORKERS_FIFO: i64 = 512;
pub const MIN_POD_JOBS: usize = 20;

/// The start of service of each job (sorted by arrival a) in a FIFO queue with c workers, given every release d.
pub fn fifo_start(a: &[f64], d: &[f64], c: usize) -> Vec<f64> {
    let mut b = vec![0.0; a.len()];
    let mut top = Vec::with_capacity(c);
    fifo_start_into(&mut b, a, d, c, &mut top);
    b
}

fn fifo_start_into(b: &mut [f64], a: &[f64], d: &[f64], c: usize, top: &mut Vec<f64>) {
    top.clear();
    let mut prev = f64::NEG_INFINITY;
    for n in 0..a.len() {
        let mut x = a[n];
        if top.len() == c && top[0] > x {
            x = top[0]; // the c-th latest release so far
        }
        if prev > x {
            x = prev;
        }
        b[n] = x;
        prev = x;
        if top.len() < c {
            top.push(d[n]);
            let i = top.len() - 1;
            sift_up(top, i);
        } else if d[n] > top[0] {
            top[0] = d[n];
            sift_down(top, 0);
        }
    }
}

fn sift_up(h: &mut [f64], mut i: usize) {
    while i > 0 {
        let p = (i - 1) / 2;
        if !(h[i] < h[p]) {
            return;
        }
        h.swap(i, p);
        i = p;
    }
}

fn sift_down(h: &mut [f64], mut i: usize) {
    let n = h.len();
    loop {
        let l = 2 * i + 1;
        if l >= n {
            return;
        }
        let mut m = l;
        let r = l + 1;
        if r < n && h[r] < h[l] {
            m = r;
        }
        if !(h[m] < h[i]) {
            return;
        }
        h.swap(i, m);
        i = m;
    }
}

/// Mean and sample variance (ddof 1), in two passes (NaN when undefined), with Go's arm64 fused multiply-add.
pub fn mean_var(xs: &[f64]) -> (f64, f64) {
    let n = xs.len() as f64;
    if xs.is_empty() {
        return (f64::NAN, f64::NAN);
    }
    let mut s = 0.0;
    for &x in xs {
        s += x;
    }
    let m = s / n;
    if xs.len() < 2 {
        return (m, f64::NAN);
    }
    let mut v = 0.0;
    for &x in xs {
        let t = x - m;
        v = t.mul_add(t, v);
    }
    (m, v / (n - 1.0))
}

fn shortfall(s: &[f64], waited: &[bool], buf_w: &mut Vec<f64>, buf_n: &mut Vec<f64>) -> (f64, f64) {
    buf_w.clear();
    buf_n.clear();
    for (i, &x) in s.iter().enumerate() {
        if waited[i] {
            buf_w.push(x);
        } else {
            buf_n.push(x);
        }
    }
    let (nw, nn) = (buf_w.len(), buf_n.len());
    if nw < 2 || nn < 2 {
        return (f64::NAN, f64::NAN);
    }
    let (mw, vw) = mean_var(buf_w);
    let (mn, vn) = mean_var(buf_n);
    let se = (vw / nw as f64 + vn / nn as f64).sqrt();
    let (mut z, mut rel) = (0.0, 0.0);
    if se > 0.0 {
        z = (mw - mn) / se;
    }
    if mn > 0.0 {
        rel = mw / mn - 1.0;
    }
    (z, rel)
}

fn brief_shortfall(
    a: &[f64],
    b: &[f64],
    s: &[f64],
    w: &mut [bool],
    buf_w: &mut Vec<f64>,
    buf_n: &mut Vec<f64>,
) -> bool {
    let mut n = 0;
    for i in 0..b.len() {
        w[i] = b[i] > a[i];
        if w[i] {
            n += 1;
        }
    }
    if n < SHORTFALL_MIN {
        return false;
    }
    let (z, rel) = shortfall(s, w, buf_w, buf_n);
    z < -SHORTFALL_Z && rel < -SHORTFALL_REL
}

/// The FIFO queue reconstructed for one pod (Go's podQueue).
#[derive(Clone, Debug)]
pub struct PodQueue {
    pub workers: i64,
    pub jobs: usize,
    pub contradictions: i64,
    pub refuted_below: f64,
    pub enough_waits: bool,
    pub identified: bool,
    pub wait_mean: f64,
    pub max_in_system: i64,
    /// arrival, start of service, release (ms), in queue order
    pub a: Vec<f64>,
    pub b: Vec<f64>,
    pub d: Vec<f64>,
    pub waited: usize,
    pub shortfall_z: f64,
    pub shortfall_rel: f64,
    pub refuted_by: BTreeMap<i64, &'static str>,
    /// input index of each job above
    pub order: Vec<usize>,
}

fn cmp_f64(x: f64, y: f64) -> std::cmp::Ordering {
    // Go's `<` on non-NaN values: equal when neither is less (so 0 and -0 tie, as in Go)
    if x < y {
        std::cmp::Ordering::Less
    } else if y < x {
        std::cmp::Ordering::Greater
    } else {
        std::cmp::Ordering::Equal
    }
}

/// Pods with at least this many jobs use parallelism inside the pod (when the pool has more than one thread):
/// a parallel sort for the queue order, and the rebuilds at 1..=AHEAD_COUNTS workers made at once, ahead of the
/// search. The results are the same; only the time differs.
pub const PAR_POD_JOBS: usize = 100_000;
const AHEAD_COUNTS: i64 = 4;

/// queue_order with a parallel sort (the same order).
fn queue_order_par(a: &[f64], d: &[f64]) -> Vec<usize> {
    if a.iter().any(|x| x.is_sign_negative() || x.is_nan()) {
        return queue_order(a, d);
    }
    // non-negative floats order as their bits; (bits, index) pairs are unique, so the unstable sort is stable
    let mut ka: Vec<(u64, u32)> = a.par_iter().enumerate().map(|(i, x)| (x.to_bits(), i as u32)).collect();
    ka.par_sort_unstable();
    let o: Vec<usize> = ka.iter().map(|k| k.1 as usize).collect();
    tie_groups(o, a, d)
}

/// The indices of xs in ascending order, ties in index order (what Go's sort.SliceStable gives). Non-negative
/// values (the arrivals, ms from the pod's first) are radix-sorted on their bits, which order as the values
/// do; anything else goes through a comparison sort.
fn stable_order(xs: &[f64]) -> Vec<usize> {
    let n = xs.len();
    if n < 256 || xs.iter().any(|x| x.is_sign_negative() || x.is_nan()) {
        let mut o: Vec<usize> = (0..n).collect();
        o.sort_by(|&x, &y| cmp_f64(xs[x], xs[y]));
        return o;
    }
    // LSD radix on 11-bit digits, stable; a digit every key shares is skipped
    const D: u32 = 11;
    let mut cur: Vec<(u64, u32)> = xs.iter().enumerate().map(|(i, x)| (x.to_bits(), i as u32)).collect();
    let mut tmp: Vec<(u64, u32)> = vec![(0, 0); n];
    let mut count = vec![0usize; 1 << D];
    let mut shift = 0u32;
    while shift < 64 {
        count.iter_mut().for_each(|c| *c = 0);
        for &(k, _) in &cur {
            count[((k >> shift) & ((1 << D) - 1)) as usize] += 1;
        }
        if count.contains(&n) {
            shift += D;
            continue;
        }
        let mut at = 0;
        for c in count.iter_mut() {
            let k = *c;
            *c = at;
            at += k;
        }
        for &e in &cur {
            let b = ((e.0 >> shift) & ((1 << D) - 1)) as usize;
            tmp[count[b]] = e;
            count[b] += 1;
        }
        std::mem::swap(&mut cur, &mut tmp);
        shift += D;
    }
    cur.into_iter().map(|e| e.1 as usize).collect()
}

/// The reference's queue order: by arrival (stable), then within runs of arrivals closer than TIE_MS by release.
pub fn queue_order(a: &[f64], d: &[f64]) -> Vec<usize> {
    // by arrival, ties in input order (a stable sort)
    tie_groups(stable_order(a), a, d)
}

/// Within runs of arrivals closer than TIE_MS (in the by-arrival order o), orders the jobs by release (stable).
fn tie_groups(mut o: Vec<usize>, a: &[f64], d: &[f64]) -> Vec<usize> {
    let n = o.len();
    let mut lo = 0;
    while lo < n {
        let mut hi = lo + 1;
        while hi < n && !(a[o[hi]] - a[o[hi - 1]] > TIE_MS) {
            hi += 1;
        }
        if hi - lo > 1 {
            o[lo..hi].sort_by(|&x, &y| cmp_f64(d[x], d[y]));
        }
        lo = hi;
    }
    o
}

/// The most jobs present at once in a queue that takes them in the order given (a release at an arrival's
/// instant comes first).
pub fn max_in_system(a: &[f64], d: &[f64]) -> i64 {
    let mut h: Vec<f64> = Vec::with_capacity(64);
    let mut best = 0usize;
    for n in 0..a.len() {
        while !h.is_empty() && h[0] <= a[n] {
            let last = h.len() - 1;
            h[0] = h[last];
            h.truncate(last);
            sift_down(&mut h, 0);
        }
        best = best.max(h.len() + 1);
        h.push(d[n]);
        let i = h.len() - 1;
        sift_up(&mut h, i);
    }
    best as i64
}

/// One rebuild's outcome at a count (what try records).
#[derive(Clone, Copy)]
struct TryOut {
    nb: i64,
    waited: usize,
    z: f64,
    rel: f64,
    verdict: Option<&'static str>,
}

/// The arrays one rebuild fills: starts of service, service times, the waited mask, and scratch.
struct Bufs {
    b: Vec<f64>,
    s: Vec<f64>,
    w: Vec<bool>,
    buf_w: Vec<f64>,
    buf_n: Vec<f64>,
    top: Vec<f64>,
}

impl Bufs {
    fn new(n: usize) -> Self {
        Bufs {
            b: vec![0.0; n],
            s: vec![0.0; n],
            w: vec![false; n],
            buf_w: Vec::new(),
            buf_n: Vec::new(),
            top: Vec::new(),
        }
    }
}

/// Rebuilds the queue with c workers (Go's try, without its bookkeeping): a function of (a, d, c) alone.
fn eval_count(a: &[f64], d: &[f64], c: i64, x: &mut Bufs) -> TryOut {
    let cu = c.max(0) as usize;
    if x.top.capacity() < cu {
        x.top = Vec::with_capacity(2 * cu);
    }
    fifo_start_into(&mut x.b, a, d, cu, &mut x.top);
    let (mut waited, mut nb) = (0usize, 0i64);
    for i in 0..x.b.len() {
        x.s[i] = d[i] - x.b[i];
        x.w[i] = x.b[i] - a[i] > JITTER_MS;
        if x.w[i] {
            waited += 1;
        }
        if x.s[i] < -JITTER_MS {
            nb += 1;
        }
    }
    let (mut z, mut rel) = (f64::NAN, f64::NAN);
    if waited >= SHORTFALL_MIN {
        (z, rel) = shortfall(&x.s, &x.w, &mut x.buf_w, &mut x.buf_n);
    }
    let verdict = if nb as f64 > JITTER_FLOOR.max(JITTER_WAIT_SHARE * waited as f64) {
        Some("contradictions")
    } else if z < -SHORTFALL_Z && rel < -SHORTFALL_REL {
        Some("shortfall")
    } else if waited < SHORTFALL_MIN && brief_shortfall(a, &x.b, &x.s, &mut x.w, &mut x.buf_w, &mut x.buf_n) {
        Some("brief-wait shortfall")
    } else {
        None
    };
    TryOut { nb, waited, z, rel, verdict }
}

struct WorkerSearch<'x> {
    a: &'x [f64],
    d: &'x [f64],
    x: Bufs,
    /// rebuilds made ahead of the search (large pods, more than one thread): count -> outcome and arrays
    ahead: BTreeMap<i64, (TryOut, Bufs)>,
    bad: BTreeMap<i64, i64>,
    why: BTreeMap<i64, &'static str>,
    at: i64,
    waited: usize,
    z: f64,
    rel: f64,
}

impl<'x> WorkerSearch<'x> {
    fn new(a: &'x [f64], d: &'x [f64]) -> Self {
        WorkerSearch {
            a,
            d,
            x: Bufs::new(a.len()),
            ahead: BTreeMap::new(),
            bad: BTreeMap::new(),
            why: BTreeMap::new(),
            at: 0,
            waited: 0,
            z: f64::NAN,
            rel: f64::NAN,
        }
    }

    /// Rebuilds the queue with c workers and reports whether the count is refuted (Go's try). A rebuild made
    /// ahead is taken as it is: eval_count is a function of (a, d, c) alone.
    fn try_count(&mut self, c: i64) -> bool {
        let o = match self.ahead.remove(&c) {
            Some((o, x)) => {
                self.x = x;
                o
            }
            None => eval_count(self.a, self.d, c, &mut self.x),
        };
        self.at = c;
        self.waited = o.waited;
        self.bad.insert(c, o.nb);
        self.z = o.z;
        self.rel = o.rel;
        if let Some(v) = o.verdict {
            self.why.insert(c, v);
        }
        self.why.contains_key(&c)
    }

    /// The smallest count in [1, bound] that try does not refute, or bound (Go's jump search).
    fn smallest(&mut self, bound: i64) -> i64 {
        if !self.try_count(1) || bound <= 1 {
            return 1;
        }
        let (mut lo, mut wlo, mut step) = (1i64, self.waited, 1i64);
        loop {
            let hi = (lo + step).min(bound);
            let refuted = self.try_count(hi);
            if hi == lo + 1 {
                if !refuted || hi == bound {
                    return hi;
                }
                lo = hi;
                wlo = self.waited;
                step = 2;
                continue;
            }
            if self.bad[&hi] as f64 > JITTER_FLOOR.max(JITTER_WAIT_SHARE * wlo as f64) {
                for c in lo + 1..hi {
                    self.why.insert(c, "contradictions");
                }
                if hi == bound {
                    return hi;
                }
                lo = hi;
                wlo = self.waited;
                step *= 2;
                continue;
            }
            step /= 2;
        }
    }

    fn material_waits(&mut self) -> (bool, f64) {
        let x = &mut self.x;
        let (mut nw, mut nn) = (0usize, 0usize);
        let (mut sw, mut sn, mut ww) = (0.0, 0.0, 0.0);
        for i in 0..x.b.len() {
            if x.w[i] {
                nw += 1;
                sw += x.s[i];
                ww += x.b[i] - self.a[i];
            } else {
                nn += 1;
                sn += x.s[i];
            }
        }
        if nw < 2 {
            return (false, f64::NAN);
        }
        let wbar = ww / nw as f64;
        x.buf_w.clear();
        x.buf_n.clear();
        for i in 0..x.s.len() {
            if x.w[i] {
                x.buf_w.push(x.s[i]);
            } else {
                x.buf_n.push(x.s[i]);
            }
        }
        let (_, vw) = mean_var(&x.buf_w);
        let mut se2 = vw / nw as f64;
        let mut reference = sw / nw as f64;
        if nn >= 2 {
            let (_, vn) = mean_var(&x.buf_n);
            se2 += vn / nn as f64;
            reference = sn / nn as f64;
        }
        (wbar >= SHORTFALL_REL * reference && wbar >= SHORTFALL_Z * se2.sqrt(), wbar)
    }
}

/// The smallest worker count whose FIFO queue explains the pod's jobs (arrivals a, releases d, in any order);
/// fixed > 0 takes the count as given (Go's inferWorkers).
pub fn infer_workers(a: &[f64], d: &[f64], fixed: i64) -> PodQueue {
    let n = a.len();
    let big = n >= PAR_POD_JOBS && rayon::current_num_threads() > 1;
    let order = if big { queue_order_par(a, d) } else { queue_order(a, d) };
    let aq: Vec<f64> = order.iter().map(|&k| a[k]).collect();
    let dq: Vec<f64> = order.iter().map(|&k| d[k]).collect();
    let (max_sys, ahead) = if big && fixed <= 0 {
        // the first counts' rebuilds need only the queue, not the bound: run them beside it
        rayon::join(
            || max_in_system(&aq, &dq),
            || {
                (1..=AHEAD_COUNTS)
                    .into_par_iter()
                    .map(|c| {
                        let mut x = Bufs::new(n);
                        let o = eval_count(&aq, &dq, c, &mut x);
                        (c, (o, x))
                    })
                    .collect::<BTreeMap<_, _>>()
            },
        )
    } else {
        (if n > 0 { max_in_system(&aq, &dq) } else { 0 }, BTreeMap::new())
    };
    let mut q = WorkerSearch::new(&aq, &dq);
    q.ahead = ahead;
    let mut c = fixed;
    if fixed > 0 {
        q.try_count(c);
    } else {
        c = q.smallest(max_sys.clamp(1, MAX_WORKERS_FIFO));
        q.why.retain(|&k, _| k <= c);
        if c > 1 && !q.bad.contains_key(&(c - 1)) {
            q.try_count(c - 1);
        }
        if q.at != c {
            q.try_count(c);
        }
    }
    let mut below = f64::NAN;
    if let Some(&v) = q.bad.get(&(c - 1)) {
        if c > 1 && n > 0 {
            below = v as f64 / n as f64;
        }
    }
    let enough = q.waited >= IDENT_MIN_WAITS;
    let (material, wmean) = q.material_waits();
    let contradictions = q.bad.get(&c).copied().unwrap_or(0);
    q.ahead.clear();
    let WorkerSearch { x: Bufs { b, .. }, why, waited, z, rel, .. } = q;
    PodQueue {
        workers: c,
        jobs: n,
        contradictions,
        refuted_below: below,
        enough_waits: enough,
        identified: enough && material,
        wait_mean: wmean,
        max_in_system: max_sys,
        a: aq,
        b,
        d: dq,
        waited,
        shortfall_z: z,
        shortfall_rel: rel,
        refuted_by: why,
        order,
    }
}

/// What the reconstruction gives one service, pooled over its pods (Go's svcQueue).
#[derive(Clone, Debug)]
pub struct SvcQueue {
    pub workers: i64,
    pub identified: bool,
    pub waited_mean: f64,
    pub jobs: usize,
    pub rel_mean: f64,
    pub rel_var: f64,
    pub wait_mean: f64,
    pub min_waited: usize,
    pub max_sys: i64,
    pub neg_share: f64,
    pub pods: Vec<(i32, PodQueue)>,
}

/// The visit records' indices grouped by pod, each pod's in record order, and each pod's service (-1: no
/// visit): a counting sort, counted and scattered per block in parallel.
fn group_by_pod(vrec: &[VisitRec], n_pods: usize) -> (Vec<u32>, Vec<usize>, Vec<i32>) {
    let n = vrec.len();
    let block = n.div_ceil(rayon::current_num_threads() * 4).max(1 << 15);
    let hist: Vec<Vec<u32>> = vrec
        .par_chunks(block)
        .map(|ch| {
            let mut h = vec![0u32; n_pods];
            for v in ch {
                h[v.pod as usize] += 1;
            }
            h
        })
        .collect();
    let mut offs: Vec<Vec<usize>> = vec![vec![0; n_pods]; hist.len()];
    let mut starts = vec![0usize; n_pods + 1];
    let mut at = 0usize;
    for p in 0..n_pods {
        starts[p] = at;
        for (k, h) in hist.iter().enumerate() {
            offs[k][p] = at;
            at += h[p] as usize;
        }
    }
    starts[n_pods] = n;
    // the visit records' indices as u32: a capture has far fewer than 2^32 visits (that many would need over
    // 100 GB of records first); refuse rather than truncate
    assert!(u32::try_from(n).is_ok(), "more than 2^32 visit records");
    let mut idx: Vec<u32> = Vec::with_capacity(n);
    let base = idx.as_mut_ptr() as usize;
    vrec.par_chunks(block).zip(offs.into_par_iter()).enumerate().for_each(|(k, (ch, mut o))| {
        let p = base as *mut u32;
        for (j, v) in ch.iter().enumerate() {
            let slot = &mut o[v.pod as usize];
            // SAFETY: the offsets partition 0..n (each block its own slots of each pod, each written once)
            unsafe { p.add(*slot).write((k * block + j) as u32) };
            *slot += 1;
        }
    });
    // SAFETY: every slot of 0..n was written above
    unsafe { idx.set_len(n) };
    let pod_svc: Vec<i32> =
        (0..n_pods).map(|p| if starts[p] < starts[p + 1] { vrec[idx[starts[p]] as usize].svc } else { -1 }).collect();
    (idx, starts, pod_svc)
}

/// Runs the reconstruction on every pod (in parallel) and pools the result per service. fixed maps a service id
/// to a user-set worker count. n_pods bounds the pod ids in vrec.
pub fn reconstruct_queues(
    vrec: &[VisitRec],
    n_svc: usize,
    n_pods: usize,
    fixed: &BTreeMap<i32, i64>,
) -> Vec<Option<SvcQueue>> {
    let (idx_all, starts, pod_svc) = group_by_pod(vrec, n_pods);
    let by_pod: Vec<&[u32]> = (0..n_pods).map(|p| &idx_all[starts[p]..starts[p + 1]]).collect();
    let mut pods_of_svc: Vec<Vec<i32>> = vec![Vec::new(); n_svc];
    for (p, &s) in pod_svc.iter().enumerate() {
        if s >= 0 && (s as usize) < n_svc {
            pods_of_svc[s as usize].push(p as i32); // ascending pod id, as Go's sort gives
        }
    }
    let mut jobs: Vec<i32> = Vec::new();
    for ps in pods_of_svc.iter_mut() {
        let big: Vec<i32> = ps.iter().copied().filter(|&p| by_pod[p as usize].len() >= MIN_POD_JOBS).collect();
        if !big.is_empty() {
            *ps = big;
        }
        jobs.extend_from_slice(ps);
    }
    // the largest pods first, so that the slowest one starts at once (the result is collected by job, not by
    // completion, so the order changes nothing else)
    let mut sched: Vec<usize> = (0..jobs.len()).collect();
    sched.sort_by_key(|&j| std::cmp::Reverse(by_pod[jobs[j] as usize].len()));
    let mut done: Vec<(usize, PodQueue)> = sched
        .par_iter()
        .with_max_len(1)
        .map(|&j| {
            let p = jobs[j];
            let idx = by_pod[p as usize];
            let mut base = vrec[idx[0] as usize].start;
            for &i in idx {
                base = base.min(vrec[i as usize].start);
            }
            let mut a = Vec::with_capacity(idx.len());
            let mut d = Vec::with_capacity(idx.len());
            for &i in idx {
                let v = &vrec[i as usize];
                a.push((v.start as i64).wrapping_sub(base as i64) as f64 / 1e6);
                d.push((v.rel as i64).wrapping_sub(base as i64) as f64 / 1e6);
            }
            let f = fixed.get(&pod_svc[p as usize]).copied().unwrap_or(0);
            (j, infer_workers(&a, &d, f))
        })
        .collect();
    done.sort_by_key(|x| x.0);
    let mut res: Vec<Option<PodQueue>> = vec![None; n_pods];
    for (j, q) in done {
        res[jobs[j] as usize] = Some(q);
    }

    // each service's pods, in pod order, then pooled per service in parallel
    let per_svc: Vec<Vec<(i32, PodQueue)>> = pods_of_svc
        .iter()
        .map(|ps| ps.iter().map(|&p| (p, res[p as usize].take().expect("every listed pod is rebuilt"))).collect())
        .collect();
    per_svc.into_par_iter().map(pool_service).collect()
}

/// Pools one service's rebuilt pods (Go's per-service loop of reconstructQueues).
fn pool_service(pods: Vec<(i32, PodQueue)>) -> Option<SvcQueue> {
    {
        if pods.is_empty() {
            return None;
        }
        let mut sq = SvcQueue {
            workers: 0,
            identified: true,
            waited_mean: 0.0,
            jobs: 0,
            rel_mean: 0.0,
            rel_var: 0.0,
            wait_mean: 0.0,
            min_waited: usize::MAX,
            max_sys: 0,
            neg_share: 0.0,
            pods: Vec::with_capacity(pods.len()),
        };
        let total: usize = pods.iter().map(|(_, q)| q.b.len()).sum();
        let mut sr: Vec<f64> = Vec::with_capacity(total);
        let mut wt: Vec<f64> = Vec::with_capacity(total);
        let (mut neg, mut nw) = (0usize, 0usize);
        for (p, q) in pods {
            if q.waited >= 2 {
                // Go fuses the product into the sum (arm64)
                sq.waited_mean = q.wait_mean.mul_add(q.waited as f64, sq.waited_mean);
                nw += q.waited;
            }
            sq.workers = sq.workers.max(q.workers);
            sq.identified = sq.identified && q.identified;
            sq.min_waited = sq.min_waited.min(q.waited);
            sq.max_sys = sq.max_sys.max(q.max_in_system);
            for j in 0..q.b.len() {
                let wait = q.b[j] - q.a[j];
                let rel = q.d[j] - q.b[j];
                sr.push(rel);
                wt.push(wait);
                if rel < 0.0 {
                    neg += 1;
                }
            }
            sq.pods.push((p, q));
        }
        if nw > 0 {
            sq.waited_mean /= nw as f64;
        }
        sq.jobs = sr.len();
        let (m, v) = mean_var(&sr);
        sq.rel_mean = m;
        sq.rel_var = v;
        sq.wait_mean = mean_var(&wt).0;
        if sq.jobs > 0 {
            sq.neg_share = neg as f64 / sq.jobs as f64;
        }
        Some(sq)
    }
}

/// Helpers for the ported Go unit tests (workers_search_test.go): the reference's linear search, and the
/// refutation at every count. Not part of the inference.
#[doc(hidden)]
pub mod testing {
    use super::*;

    /// Every count from 1 until one passes or the bound is reached (Go's linearWorkers), on jobs in queue order:
    /// (count, refuted counts and why, contradictions at each count tried).
    pub fn linear_workers(a: &[f64], d: &[f64], bound: i64) -> (i64, BTreeMap<i64, &'static str>, BTreeMap<i64, i64>) {
        let mut q = WorkerSearch::new(a, d);
        let mut c = 1;
        while q.try_count(c) && c < bound {
            c += 1;
        }
        (c, q.why, q.bad)
    }

    /// How many rebuilds the jump search makes up to bound.
    pub fn search_rebuilds(a: &[f64], d: &[f64], bound: i64) -> usize {
        let mut q = WorkerSearch::new(a, d);
        q.smallest(bound);
        q.bad.len()
    }

    /// (contradictions, waits, refuted) at every count 1..=bound.
    pub fn every_count(a: &[f64], d: &[f64], bound: i64) -> Vec<(i64, usize, bool)> {
        let mut q = WorkerSearch::new(a, d);
        (1..=bound)
            .map(|c| {
                let r = q.try_count(c);
                (q.bad[&c], q.waited, r)
            })
            .collect()
    }
}
