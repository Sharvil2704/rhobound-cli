// SPDX-License-Identifier: Apache-2.0

//! The per-trace pass (rhobound-cli infer.go: spanIndex, ancestor, ownerVisit, collectCalls, prepass, topLoss,
//! processTrace, recordBranches). Each chunk of trace groups gets its own accumulator; the chunks are merged in
//! chunk order, as in Go, so every floating-point sum is taken in the same order whatever the thread count.
//!
//! Go keeps a trace's calls in a map from owner span to a slice; here they are one buffer grouped by owner
//! (append order kept, then each owner's calls sorted with Go's own sort), and the span index is an open
//! addressing table reused from trace to trace: same answers, no allocation per trace.

use rbfast_otlp::{Span, KIND_CLIENT, KIND_CONSUMER, KIND_SERVER};

use crate::hash::{map, FxMap};
use crate::structure;
use crate::{go_max, gosort, Seg, TraceCall, VisitRec};

pub const EARLY_CALL_NS: u64 = 250_000;
pub const MAX_SLOTS: usize = 8;

pub const STOP_FOUND: u8 = 0;
pub const STOP_ROOT: u8 = 1;
pub const STOP_MISSING: u8 = 2;
pub const STOP_CONSUMER: u8 = 3;

pub const LOSS_CALLED_TOP: usize = 0;
pub const LOSS_BELOW_TOP: usize = 1;
pub const LOSS_CALLEE: usize = 2;
pub const N_LOSS: usize = 3;

pub const ENTRY_LIKE_SHARE: f64 = 0.5;

/// An edge (caller, callee) packed in one word.
#[inline]
pub fn edge(caller: i32, callee: i32) -> u64 {
    ((caller as u32 as u64) << 32) | callee as u32 as u64
}

#[inline]
pub fn edge_parts(k: u64) -> (i32, i32) {
    ((k >> 32) as u32 as i32, k as u32 as i32)
}

/// What the per-trace code needs about the capture's resources.
pub struct Ctx<'d> {
    pub res_svc: &'d [i32],
    pub res_pod: &'d [i32],
    pub res_name: &'d [i32],
    pub n_svc: usize,
    pub unknown_peer: i32,
}

/// Span id -> first position in the trace group (Go's spanIndex), open addressing, reused across traces.
pub struct PosIndex {
    keys: Vec<u64>,
    vals: Vec<u32>,
    mask: usize,
    shift: u32,
}

const EMPTY: u32 = u32::MAX;

impl PosIndex {
    fn new() -> Self {
        PosIndex { keys: Vec::new(), vals: Vec::new(), mask: 0, shift: 64 }
    }

    #[inline]
    fn slot(&self, id: u64) -> usize {
        (id.wrapping_mul(0x9E37_79B9_7F4A_7C15) >> self.shift) as usize
    }

    fn build(&mut self, g: &[Span]) {
        let cap = (2 * g.len()).next_power_of_two().max(8);
        if self.vals.len() < cap {
            self.keys.resize(cap, 0);
            self.vals.resize(cap, EMPTY);
        }
        self.vals[..cap].fill(EMPTY);
        self.mask = cap - 1;
        self.shift = 64 - cap.trailing_zeros();
        for (i, s) in g.iter().enumerate() {
            let mut h = self.slot(s.id);
            loop {
                if self.vals[h] == EMPTY {
                    self.keys[h] = s.id;
                    self.vals[h] = i as u32;
                    break;
                }
                if self.keys[h] == s.id {
                    break; // a duplicate id: the first position stays
                }
                h = (h + 1) & self.mask;
            }
        }
    }

    #[inline]
    fn get(&self, id: u64) -> Option<usize> {
        let mut h = self.slot(id);
        loop {
            let v = self.vals[h];
            if v == EMPTY {
                return None;
            }
            if self.keys[h] == id {
                return Some(v as usize);
            }
            h = (h + 1) & self.mask;
        }
    }
}

/// The nearest server or client span above span k through internal and producer spans (Go's ancestor).
fn ancestor(g: &[Span], pos: &PosIndex, k: usize) -> (isize, u8) {
    let mut cur = k;
    for _ in 0..g.len() {
        let pid = g[cur].parent;
        if pid == 0 {
            return (-1, STOP_ROOT);
        }
        let Some(p) = pos.get(pid) else {
            return (-1, STOP_MISSING);
        };
        match g[p].kind {
            KIND_SERVER | KIND_CLIENT => return (p as isize, STOP_FOUND),
            KIND_CONSUMER => return (-1, STOP_CONSUMER),
            _ => {}
        }
        cur = p;
    }
    (-1, STOP_ROOT)
}

/// The server span that owns span k (Go's ownerVisit).
fn owner_visit(g: &[Span], pos: &PosIndex, k: usize) -> (isize, u8) {
    let mut cur = k;
    for _ in 0..g.len() {
        let (p, stop) = ancestor(g, pos, cur);
        if p < 0 {
            return (-1, stop);
        }
        if g[p as usize].kind == KIND_SERVER {
            return (p, STOP_FOUND);
        }
        cur = p as usize;
    }
    (-1, STOP_ROOT)
}

#[derive(Clone, Copy)]
pub struct Link {
    pub server: usize,
    pub client: isize,
    pub owner: isize,
    pub consumer: bool,
}

#[derive(Clone, Copy)]
pub struct Loose {
    pub client: usize,
    pub owner: isize,
    pub callee: i32,
    pub consumer: bool,
}

/// Buffers reused from trace to trace.
pub struct Scratch {
    pos: PosIndex,
    matched: Vec<bool>,
    links: Vec<Link>,
    loose: Vec<Loose>,
    flat: Vec<(u32, TraceCall)>,
    calls: Vec<TraceCall>,
    off: Vec<u32>,
    struct_cs: Vec<TraceCall>,
    lens: Vec<usize>,
    sig: Vec<i32>,
    group: Vec<TraceCall>,
    key: Vec<i32>,
    ord: Vec<TraceCall>,
    called_top: Vec<i32>,
}

impl Scratch {
    pub fn new() -> Self {
        Scratch {
            pos: PosIndex::new(),
            matched: Vec::new(),
            links: Vec::new(),
            loose: Vec::new(),
            flat: Vec::new(),
            calls: Vec::new(),
            off: Vec::new(),
            struct_cs: Vec::new(),
            lens: Vec::new(),
            sig: Vec::new(),
            group: Vec::new(),
            key: Vec::new(),
            ord: Vec::new(),
            called_top: Vec::new(),
        }
    }
}

#[inline]
fn call_less(x: &TraceCall, y: &TraceCall) -> bool {
    x.start < y.start || (x.start == y.start && x.callee < y.callee)
}

/// One trace's calls (Go's collectCalls): every server span's link, the client spans with no server span under
/// them, and per owner visit its calls sorted by (start, callee). sc.pos must be built for g.
fn collect_calls(ctx: &Ctx, g: &[Span], sc: &mut Scratch) {
    let m = g.len();
    let svc = |k: usize| ctx.res_svc[g[k].res as usize];
    let pod = |k: usize| ctx.res_pod[g[k].res as usize];
    sc.links.clear();
    sc.loose.clear();
    sc.flat.clear();
    sc.matched.clear();
    sc.matched.resize(m, false);
    for k in 0..m {
        if g[k].kind != KIND_SERVER || svc(k) < 0 {
            continue;
        }
        let (p, stop) = ancestor(g, &sc.pos, k);
        let callee = svc(k);
        let mut l = Link { server: k, client: -1, owner: -1, consumer: stop == STOP_CONSUMER };
        if p >= 0 {
            let pu = p as usize;
            if g[pu].kind == KIND_CLIENT {
                sc.matched[pu] = true;
                l.client = p;
                let (owner, ostop) = owner_visit(g, &sc.pos, pu);
                if owner >= 0 && svc(owner as usize) >= 0 {
                    let cs = &g[pu];
                    sc.flat.push((
                        owner as u32,
                        TraceCall {
                            callee,
                            start: cs.start,
                            end: cs.end,
                            client_dur: cs.dur_ms(),
                            has_server: true,
                            own_clock: pod(pu) == pod(owner as usize),
                            is_async: false,
                        },
                    ));
                    l.owner = owner;
                } else {
                    l.consumer = ostop == STOP_CONSUMER;
                }
            } else if g[pu].kind == KIND_SERVER && svc(pu) >= 0 {
                // no client span: the call is timed by the callee's span, on the callee's clock
                sc.flat.push((
                    pu as u32,
                    TraceCall {
                        callee,
                        start: g[k].start,
                        end: g[k].end,
                        client_dur: g[k].dur_ms(),
                        has_server: true,
                        own_clock: pod(k) == pod(pu),
                        is_async: false,
                    },
                ));
                l.owner = p;
            }
        }
        sc.links.push(l);
    }
    for k in 0..m {
        if g[k].kind != KIND_CLIENT || sc.matched[k] {
            continue;
        }
        let peer = if g[k].peer >= 0 { ctx.n_svc as i32 + g[k].peer } else { ctx.unknown_peer };
        let (owner, stop) = owner_visit(g, &sc.pos, k);
        let mut lc = Loose { client: k, owner: -1, callee: peer, consumer: stop == STOP_CONSUMER };
        if owner >= 0 && svc(owner as usize) >= 0 {
            lc.owner = owner;
            sc.flat.push((
                owner as u32,
                TraceCall {
                    callee: peer,
                    start: g[k].start,
                    end: g[k].end,
                    client_dur: g[k].dur_ms(),
                    has_server: false,
                    own_clock: pod(k) == pod(owner as usize),
                    is_async: false,
                },
            ));
        }
        sc.loose.push(lc);
    }
    // group by owner, append order kept (a counting sort), then Go's sort per owner
    sc.off.clear();
    sc.off.resize(m + 1, 0);
    for (o, _) in &sc.flat {
        sc.off[*o as usize + 1] += 1;
    }
    for k in 0..m {
        sc.off[k + 1] += sc.off[k];
    }
    sc.calls.clear();
    sc.calls.resize(sc.flat.len(), TraceCall::default());
    {
        // fill each owner's range in order, using a moving cursor per owner
        let mut cur: Vec<u32> = Vec::new();
        if !sc.flat.is_empty() {
            cur.extend_from_slice(&sc.off[..m]);
            for (o, c) in &sc.flat {
                let at = &mut cur[*o as usize];
                sc.calls[*at as usize] = *c;
                *at += 1;
            }
        }
    }
    if !sc.flat.is_empty() {
        for k in 0..m {
            let (lo, hi) = (sc.off[k] as usize, sc.off[k + 1] as usize);
            if hi - lo > 1 {
                gosort::sort_func(&mut sc.calls[lo..hi], call_less);
            }
        }
    }
}

#[derive(Clone, Copy, Default)]
pub struct EdgeCounts {
    pub n: i64,
    pub after: i64,
    pub other: i64,
}

/// What processTrace needs to know about the whole capture (Go's prepass).
pub struct Prepass {
    pub answered: Vec<bool>,
    pub srv_spans: Vec<i64>,
    pub srv_called: Vec<i64>,
    pub con_spans: Vec<i64>,
    pub con_tops: Vec<i64>,
    pub calls: FxMap<u64, EdgeCounts>,
    pub entry_like: Vec<bool>,
    pub consumer_like: Vec<bool>,
    pub async_edges: FxMap<u64, ()>,
}

#[inline]
pub fn not_waited(c: &TraceCall, end: u64) -> bool {
    c.start >= end || (c.own_clock && c.end > end.wrapping_add(EARLY_CALL_NS))
}

impl Prepass {
    pub fn new(n_addr: usize, n_svc: usize, n_names: usize) -> Self {
        Prepass {
            answered: vec![false; n_addr],
            srv_spans: vec![0; n_svc],
            srv_called: vec![0; n_svc],
            con_spans: vec![0; n_names],
            con_tops: vec![0; n_names],
            calls: map(),
            entry_like: Vec::new(),
            consumer_like: Vec::new(),
            async_edges: map(),
        }
    }

    pub fn add_trace(&mut self, ctx: &Ctx, g: &[Span], sc: &mut Scratch) {
        sc.pos.build(g);
        collect_calls(ctx, g, sc);
        for l in &sc.links {
            let svc = ctx.res_svc[g[l.server].res as usize] as usize;
            self.srv_spans[svc] += 1;
            if l.owner >= 0 {
                self.srv_called[svc] += 1;
            }
            if l.client >= 0 && g[l.client as usize].addr >= 0 {
                self.answered[g[l.client as usize].addr as usize] = true;
            }
        }
        for k in 0..g.len() {
            let (lo, hi) = (sc.off[k] as usize, sc.off[k + 1] as usize);
            if lo == hi {
                continue;
            }
            let caller = ctx.res_svc[g[k].res as usize];
            for c in &sc.calls[lo..hi] {
                let e = self.calls.entry(edge(caller, c.callee)).or_default();
                e.n += 1;
                if not_waited(c, g[k].end) {
                    e.after += 1;
                    if !c.own_clock {
                        e.other += 1;
                    }
                }
            }
        }
        for s in g {
            if s.kind != KIND_CONSUMER {
                continue;
            }
            let n = ctx.res_name[s.res as usize] as usize;
            self.con_spans[n] += 1;
            if s.parent == 0 || sc.pos.get(s.parent).is_none() {
                self.con_tops[n] += 1;
            }
        }
    }

    /// Adds another chunk's counts (integers: the order does not matter).
    pub fn merge(&mut self, o: &Prepass) {
        for (a, &b) in self.answered.iter_mut().zip(&o.answered) {
            *a = *a || b;
        }
        for i in 0..o.srv_spans.len() {
            self.srv_spans[i] += o.srv_spans[i];
            self.srv_called[i] += o.srv_called[i];
        }
        for i in 0..o.con_spans.len() {
            self.con_spans[i] += o.con_spans[i];
            self.con_tops[i] += o.con_tops[i];
        }
        for (k, e) in &o.calls {
            let t = self.calls.entry(*k).or_default();
            t.n += e.n;
            t.after += e.after;
            t.other += e.other;
        }
    }

    pub fn decide(&mut self) {
        self.entry_like = self
            .srv_spans
            .iter()
            .zip(&self.srv_called)
            .map(|(&n, &c)| n > 0 && (n - c) as f64 > ENTRY_LIKE_SHARE * n as f64)
            .collect();
        self.consumer_like = self
            .con_spans
            .iter()
            .zip(&self.con_tops)
            .map(|(&n, &t)| n > 0 && t as f64 > ENTRY_LIKE_SHARE * n as f64)
            .collect();
        self.async_edges.clear();
        for (k, e) in &self.calls {
            if e.after > 0 && e.after as f64 >= structure::PARALLEL_SHARE * e.n as f64 {
                self.async_edges.insert(*k, ());
            }
        }
    }

    #[inline]
    pub fn is_async(&self, caller: i32, callee: i32) -> bool {
        !self.async_edges.is_empty() && self.async_edges.contains_key(&edge(caller, callee))
    }

    pub fn call_after(&self, k: u64) -> i64 {
        self.calls.get(&k).map_or(0, |e| e.after)
    }

    pub fn after_other(&self, k: u64) -> i64 {
        self.calls.get(&k).map_or(0, |e| e.other)
    }

    /// The edges on which more than 1 - PARALLEL_SHARE of the calls, but less than PARALLEL_SHARE, are not
    /// waited for, with that share.
    pub fn async_mixed(&self) -> Vec<(u64, f64)> {
        let mut out = Vec::new();
        for (k, e) in &self.calls {
            let sh = e.after as f64 / e.n as f64;
            if sh > 1.0 - structure::PARALLEL_SHARE && !self.async_edges.contains_key(k) {
                out.push((*k, sh));
            }
        }
        out
    }
}

/// Correlation sums of the parallel visits that made exactly k calls (or of one stage).
#[derive(Clone, Debug)]
pub struct PairAcc {
    pub n: i64,
    pub sum: [f64; MAX_SLOTS],
    pub sq: [f64; MAX_SLOTS],
    pub cross: [[f64; MAX_SLOTS]; MAX_SLOTS],
}

impl Default for PairAcc {
    fn default() -> Self {
        PairAcc { n: 0, sum: [0.0; MAX_SLOTS], sq: [0.0; MAX_SLOTS], cross: [[0.0; MAX_SLOTS]; MAX_SLOTS] }
    }
}

#[derive(Clone, Copy, Default)]
pub struct EdgeAcc {
    pub n: i64,
    pub offset_sum: f64,
}

/// The sums over a set of traces (Go's acc). Pair keys are [k] for a service's parallel visits with k calls
/// (Go's group "") and [k, callee ids...] for one stage; signature keys are compact (structure.rs).
pub struct Acc {
    pub pairs: Vec<FxMap<Box<[i32]>, PairAcc>>,
    pub visits: Vec<i64>,
    pub s_visits: Vec<i64>,
    pub own_sum: Vec<f64>,
    pub own_sq: Vec<f64>,
    pub glue_sum: Vec<f64>,
    pub glue_sq: Vec<f64>,
    pub server_sum: Vec<f64>,
    pub client_sum: Vec<f64>,
    pub client_n: Vec<i64>,
    pub multi: Vec<i64>,
    pub overlap: Vec<i64>,
    pub edges: FxMap<u64, EdgeAcc>,
    pub counts: FxMap<(u64, i32), i64>,
    pub async_n: FxMap<u64, i64>,
    pub sigs: Vec<FxMap<Box<[i32]>, i64>>,
    pub hop_samples: Vec<Vec<f64>>,
    pub segs: Vec<Seg>,
    pub vrec: Vec<VisitRec>,
    pub entries: Vec<i64>,
    pub entry_min: u64,
    pub entry_max: u64,
    pub entry_n: i64,
    pub unmatched: i64,
    pub traces: i64,
    pub broken: i64,
    pub broken_by: [i64; N_LOSS],
    pub called_top: Vec<i64>,
    pub consumer_n: i64,
    pub consumer_en: Vec<i64>,
    pub consumer_x: i64,
    pub early: Vec<i64>,
    pub early_own: Vec<i64>,
    pub early_max: Vec<f64>,
}

impl Acc {
    pub fn new(n: usize, n_svc: usize) -> Self {
        Acc {
            pairs: (0..n_svc).map(|_| map()).collect(),
            visits: vec![0; n],
            s_visits: vec![0; n],
            own_sum: vec![0.0; n],
            own_sq: vec![0.0; n],
            glue_sum: vec![0.0; n],
            glue_sq: vec![0.0; n],
            server_sum: vec![0.0; n],
            client_sum: vec![0.0; n],
            client_n: vec![0; n],
            multi: vec![0; n],
            overlap: vec![0; n],
            edges: map(),
            counts: map(),
            async_n: map(),
            sigs: (0..n_svc).map(|_| map()).collect(),
            hop_samples: vec![Vec::new(); n],
            segs: Vec::new(),
            vrec: Vec::new(),
            entries: vec![0; n],
            entry_min: u64::MAX,
            entry_max: 0,
            entry_n: 0,
            unmatched: 0,
            traces: 0,
            broken: 0,
            broken_by: [0; N_LOSS],
            called_top: vec![0; n],
            consumer_n: 0,
            consumer_en: vec![0; n],
            consumer_x: 0,
            early: vec![0; n],
            early_own: vec![0; n],
            early_max: vec![0.0; n],
        }
    }

    /// Adds another chunk's sums, after this one's (Go's merge loop; floating-point sums in chunk order).
    pub fn merge(&mut self, a: Acc) {
        let n = self.visits.len();
        for i in 0..n {
            self.visits[i] += a.visits[i];
            self.s_visits[i] += a.s_visits[i];
            self.own_sum[i] += a.own_sum[i];
            self.own_sq[i] += a.own_sq[i];
            self.glue_sum[i] += a.glue_sum[i];
            self.glue_sq[i] += a.glue_sq[i];
            self.server_sum[i] += a.server_sum[i];
            self.client_sum[i] += a.client_sum[i];
            self.client_n[i] += a.client_n[i];
            self.multi[i] += a.multi[i];
            self.overlap[i] += a.overlap[i];
            self.entries[i] += a.entries[i];
            self.consumer_en[i] += a.consumer_en[i];
            self.called_top[i] += a.called_top[i];
            self.early[i] += a.early[i];
            self.early_own[i] += a.early_own[i];
            self.early_max[i] = go_max(self.early_max[i], a.early_max[i]);
        }
        for (i, hs) in a.hop_samples.into_iter().enumerate() {
            if !hs.is_empty() {
                if self.hop_samples[i].is_empty() {
                    self.hop_samples[i] = hs;
                } else {
                    self.hop_samples[i].extend_from_slice(&hs);
                }
            }
        }
        for (k, e) in a.edges {
            let t = self.edges.entry(k).or_default();
            t.n += e.n;
            t.offset_sum += e.offset_sum;
        }
        for (k, n) in a.counts {
            *self.counts.entry(k).or_insert(0) += n;
        }
        for (k, n) in a.async_n {
            *self.async_n.entry(k).or_insert(0) += n;
        }
        for (svc, m) in a.sigs.into_iter().enumerate() {
            for (k, n) in m {
                *self.sigs[svc].entry(k).or_insert(0) += n;
            }
        }
        for (svc, m) in a.pairs.into_iter().enumerate() {
            for (k, p) in m {
                let t = self.pairs[svc].entry(k).or_default();
                t.n += p.n;
                for i in 0..MAX_SLOTS {
                    t.sum[i] += p.sum[i];
                    t.sq[i] += p.sq[i];
                    for j in 0..MAX_SLOTS {
                        t.cross[i][j] += p.cross[i][j];
                    }
                }
            }
        }
        self.segs.extend_from_slice(&a.segs);
        if self.vrec.is_empty() {
            self.vrec = a.vrec;
        } else {
            self.vrec.extend_from_slice(&a.vrec);
        }
        if a.entry_n > 0 {
            self.entry_min = self.entry_min.min(a.entry_min);
            self.entry_max = self.entry_max.max(a.entry_max);
            self.entry_n += a.entry_n;
        }
        self.unmatched += a.unmatched;
        self.traces += a.traces;
        self.broken += a.broken;
        for c in 0..N_LOSS {
            self.broken_by[c] += a.broken_by[c];
        }
        self.consumer_n += a.consumer_n;
        self.consumer_x += a.consumer_x;
    }

    #[inline]
    fn hop(&mut self, callee: i32, d: f64) {
        let d = if d < 0.0 { 0.0 } else { d };
        self.hop_samples[callee as usize].push(d);
    }

    /// One parallel visit's call durations (or one stage's), slots by callee then start (Go's recordBranches).
    fn record_branches(&mut self, svc: i32, key: &[i32], cs: &[TraceCall], ord: &mut Vec<TraceCall>) {
        let k = cs.len();
        if !(2..=MAX_SLOTS).contains(&k) {
            return;
        }
        ord.clear();
        ord.extend_from_slice(cs);
        ord.sort_by_key(|c| c.callee); // stable
        let m = &mut self.pairs[svc as usize];
        let p = match m.get_mut(key) {
            Some(p) => p,
            None => m.entry(key.into()).or_default(),
        };
        p.n += 1;
        for i in 0..k {
            let x = ord[i].client_dur;
            p.sum[i] += x;
            p.sq[i] = x.mul_add(x, p.sq[i]);
            for j in i + 1..k {
                p.cross[i][j] = x.mul_add(ord[j].client_dur, p.cross[i][j]);
            }
        }
    }
}

/// What a trace lost above its spans, as a bit set of the loss causes (Go's topLoss); the services of SERVER
/// spans that fail only because their service is not entry-like go to called.
fn top_loss(g: &[Span], pos: &PosIndex, ctx: &Ctx, pp: &Prepass, called: &mut Vec<i32>) -> u8 {
    let top_in = g.iter().any(|s| s.parent == 0 && s.kind == KIND_SERVER && ctx.res_svc[s.res as usize] >= 0);
    let mut loss = 0u8;
    for s in g {
        let pid = s.parent;
        if pid == 0 || pos.get(pid).is_some() {
            continue;
        }
        let svc = ctx.res_svc[s.res as usize];
        if top_in {
            loss |= 1 << LOSS_BELOW_TOP;
        } else if s.kind == KIND_SERVER && svc >= 0 {
            if !pp.entry_like[svc as usize] {
                loss |= 1 << LOSS_CALLED_TOP;
                if !called.contains(&svc) {
                    called.push(svc);
                }
            }
        } else if s.kind == KIND_CONSUMER && pp.consumer_like[ctx.res_name[s.res as usize] as usize] {
        } else {
            loss |= 1 << LOSS_BELOW_TOP;
        }
    }
    loss
}

/// Adds one trace's visits and calls to a (Go's processTrace).
pub fn process_trace(ctx: &Ctx, g: &[Span], a: &mut Acc, keep_segs: bool, pp: &Prepass, sc: &mut Scratch) {
    let svc_of = |k: usize| ctx.res_svc[g[k].res as usize];
    sc.pos.build(g);
    a.traces += 1;
    sc.called_top.clear();
    let mut loss = top_loss(g, &sc.pos, ctx, pp, &mut sc.called_top);
    collect_calls(ctx, g, sc);
    for lc in &sc.loose {
        let addr = g[lc.client].addr;
        if addr >= 0 && pp.answered[addr as usize] {
            loss |= 1 << LOSS_CALLEE;
        }
    }
    let broken = loss != 0;
    if broken {
        a.broken += 1;
        for c in 0..N_LOSS {
            if (loss >> c) & 1 == 1 {
                a.broken_by[c] += 1;
            }
        }
        for &s in &sc.called_top {
            a.called_top[s as usize] += 1;
        }
    } else {
        for l in &sc.links {
            let callee = svc_of(l.server) as usize;
            let sp = &g[l.server];
            if l.owner < 0 {
                a.entries[callee] += 1;
                a.entry_n += 1;
                if l.consumer {
                    a.consumer_en[callee] += 1;
                    a.consumer_n += 1;
                }
                a.entry_min = a.entry_min.min(sp.start);
                a.entry_max = a.entry_max.max(sp.start);
            } else if l.client >= 0 {
                let cs = &g[l.client as usize];
                a.hop(callee as i32, cs.dur_ms() - sp.dur_ms());
                a.client_sum[callee] += cs.dur_ms();
                a.client_n[callee] += 1;
            } else {
                a.client_sum[callee] += sp.dur_ms();
                a.client_n[callee] += 1;
            }
        }
        for lc in &sc.loose {
            if lc.owner >= 0 {
                a.client_sum[lc.callee as usize] += g[lc.client].dur_ms();
                a.client_n[lc.callee as usize] += 1;
                a.unmatched += 1;
            } else if lc.consumer {
                a.consumer_x += 1;
            }
        }
    }
    let Scratch { calls, off, struct_cs, lens, sig, group, key, ord, .. } = sc;
    for k in 0..g.len() {
        let v = &g[k];
        if v.kind != KIND_SERVER || svc_of(k) < 0 || v.end < v.start {
            continue;
        }
        let svc = svc_of(k);
        let su = svc as usize;
        let cs = &mut calls[off[k] as usize..off[k + 1] as usize];
        struct_cs.clear();
        let mut first: isize = -1;
        for j in 0..cs.len() {
            cs[j].is_async = pp.is_async(svc, cs[j].callee) && not_waited(&cs[j], v.end);
            if cs[j].is_async {
                continue;
            }
            if first < 0 {
                first = j as isize;
            }
            if cs[j].start < v.end {
                struct_cs.push(cs[j]);
            }
        }
        let (mut covered, mut max_end) = (0u64, 0u64);
        for c in cs.iter() {
            if c.is_async {
                continue;
            }
            let (s, e) = (c.start.max(v.start), c.end.min(v.end));
            if e <= s {
                continue;
            }
            if e > max_end {
                if s > max_end {
                    covered += e - s;
                } else {
                    covered += e - max_end;
                }
                max_end = e;
            }
        }
        let (mut rel, mut early) = (v.end, false);
        if first >= 0 {
            let fc = &cs[first as usize];
            rel = fc.start;
            if rel.wrapping_add(EARLY_CALL_NS) < v.start {
                early = true;
                a.early[su] += 1;
                if fc.own_clock {
                    a.early_own[su] += 1;
                }
                a.early_max[su] = go_max(a.early_max[su], v.start.wrapping_sub(rel) as f64 / 1e6);
            }
        }
        let held = rel.max(v.start).min(v.end);
        let mut alt = held;
        if early {
            alt = v.end;
            for c in &cs[first as usize..] {
                if !c.is_async && c.start >= v.start {
                    alt = c.start.min(v.end);
                    break;
                }
            }
        }
        let pod = ctx.res_pod[v.res as usize];
        if held > v.start && keep_segs {
            a.segs.push(Seg { pod, leaf: held == v.end, start: v.start, end: held });
        }
        let dur = (v.end - v.start) as f64 / 1e6;
        let pre_ns = held - v.start;
        let pre = pre_ns as f64 / 1e6;
        let mut glue = 0.0;
        let own_ns = v.end - v.start - covered;
        if own_ns > pre_ns {
            glue = (own_ns - pre_ns) as f64 / 1e6;
        }
        a.vrec.push(VisitRec { pod, svc, start: v.start, rel: held, alt, own: pre as f32, early });
        a.visits[su] += 1;
        a.own_sum[su] += pre;
        a.own_sq[su] = pre.mul_add(pre, a.own_sq[su]);
        a.server_sum[su] += dur;
        if broken {
            continue;
        }
        a.s_visits[su] += 1;
        a.glue_sum[su] += glue;
        a.glue_sq[su] = glue.mul_add(glue, a.glue_sq[su]);
        for j in 0..cs.len() {
            let c = cs[j];
            let key_e = edge(svc, c.callee);
            let ea = a.edges.entry(key_e).or_default();
            ea.n += 1; // calls clipped to nothing still count as calls
            let (s, e) = (c.start.max(v.start), c.end.min(v.end));
            if e > s {
                ea.offset_sum += (s - v.start) as f64 / 1e6;
            }
            if !cs[..j].iter().any(|x| x.callee == c.callee) {
                // once per callee: the calls to it the visit waits for; on an async edge the others apart
                let mut n = 0i32;
                for x in cs.iter() {
                    if x.callee != c.callee {
                        continue;
                    }
                    if x.is_async {
                        *a.async_n.entry(key_e).or_insert(0) += 1;
                    } else {
                        n += 1;
                    }
                }
                if n > 0 {
                    *a.counts.entry((key_e, n)).or_insert(0) += 1;
                }
            }
        }
        if struct_cs.is_empty() {
            continue;
        }
        structure::stages_of(struct_cs, lens);
        structure::compact_sig(struct_cs, lens, sig);
        {
            let m = &mut a.sigs[su];
            match m.get_mut(sig.as_slice()) {
                Some(n) => *n += 1,
                None => {
                    m.insert(sig.as_slice().into(), 1);
                }
            }
        }
        if struct_cs.len() >= 2 {
            a.multi[su] += 1;
            if lens.len() < struct_cs.len() {
                // some stage holds two or more calls: they overlap
                a.overlap[su] += 1;
                key.clear();
                key.push(struct_cs.len() as i32);
                a.record_branches(svc, key, struct_cs, ord);
            }
        }
        let mut at = 0;
        for &l in lens.iter() {
            if l >= 2 {
                group.clear();
                group.extend_from_slice(&struct_cs[at..at + l]);
                group.sort_by_key(|c| c.callee); // stable, as Go's SortStableFunc
                key.clear();
                key.push(l as i32);
                key.extend(group.iter().map(|c| c.callee));
                a.record_branches(svc, key, group, ord);
            }
            at += l;
        }
    }
}
