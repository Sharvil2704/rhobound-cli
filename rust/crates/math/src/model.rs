// SPDX-License-Identifier: Apache-2.0 AND BSD-3-Clause
//
// parse_go_float and its helpers (go_special, go_read_float, go_underscore_ok, go_atof_hex) are derived from Go's
// src/strconv/atof.go and src/strconv/atoi.go (special, readFloat, underscoreOK, atofHex), Copyright The Go Authors,
// under the BSD-3-Clause licence in rust/LICENSE-GO; the rest is Apache-2.0.

//! The mean-latency model of rhobound-cli's `internal/model`: M/G/c queues (Erlang C with the Allen-Cunneen
//! correction) composed along the call DAG, with Whitt's QNA arrival variability and the matched-maximum
//! refinement (`Config`). A line-by-line port: the same validation (and order of checks), the same NaN and
//! stability rules, and every floating-point operation in Go's order with Go's arm64 fused multiply-adds, so the
//! results are Go's bit for bit (tests/parity_oracle.rs). Error texts follow Go's (`%v` floats, `%q` strings).

use crate::gofmt::{fmt_v, quote};
use crate::gomath::{self, fma};
use crate::mathx;
use std::borrow::Cow;
use std::collections::BTreeMap;
use std::fmt;

/// Routing policy: one shared queue served by servers*workers workers.
pub const POOLED: &str = "pooled";
/// Routing policy: Poisson traffic split at random over `servers` replicas, each with `workers` workers (evenly,
/// or in the service's shares).
pub const RANDOM: &str = "random";

/// An error from the model, with Go's message text.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct ModelError(pub String);

impl fmt::Display for ModelError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str(&self.0)
    }
}

impl std::error::Error for ModelError {}

macro_rules! err {
    ($($t:tt)*) => { ModelError(format!($($t)*)) };
}

/// One sequential or parallel call from a service to a child (Go's model.Call).
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct Call {
    /// Index into Topology::services.
    pub child: usize,
    /// Probability the call is made on a visit, in (0, 1].
    pub p: f64,
    /// A call the service does not wait for: it loads the child but is not on the latency path.
    pub is_async: bool,
}

/// One node of the call graph (Go's model.Service). Times are in milliseconds. `Default` is Go's zero value
/// (servers, workers 0 and routing "" until [`Topology::finish`] fills them; cs2 0, which ParseTopology sets to 1).
#[derive(Clone, Debug, Default, PartialEq)]
pub struct Service {
    pub name: String,
    /// Mean own service time per visit, ms.
    pub s: f64,
    /// A repeated child is a repeated call.
    pub calls: Vec<Call>,
    /// Calls are made together; the parent waits for the slowest.
    pub parallel: bool,
    /// Replicas (or pooled workers when routing is pooled). Go's int.
    pub servers: i64,
    /// Workers per replica; greater than 1 needs random routing. Go's int.
    pub workers: i64,
    /// Squared coefficient of variation of the service time.
    pub cs2: f64,
    /// "pooled" or "random" ("" until finish).
    pub routing: String,
    /// A pure delay: infinite servers, no queue.
    pub delay: bool,
    /// Network time added to every call into this service, ms.
    pub hop: f64,
    /// Correlation between the latencies of this service's parallel branches (matched maximum only).
    pub branch_corr: f64,
    /// Time per visit that holds no worker and is not spent in a call, ms.
    pub glue: f64,
    pub glue_cs2: f64,
    /// Each replica's share of the visits (random routing, two or more replicas); None is an even split.
    /// Some(empty) is Go's non-nil empty slice (refused by finish).
    pub shares: Option<Vec<f64>>,
}

impl Service {
    /// The calls the service waits for (its calls without the async ones).
    pub fn sync_calls(&self) -> Cow<'_, [Call]> {
        if self.calls.iter().any(|c| c.is_async) {
            Cow::Owned(self.calls.iter().filter(|c| !c.is_async).copied().collect())
        } else {
            Cow::Borrowed(&self.calls)
        }
    }
}

/// A DAG of services plus where external traffic enters (Go's model.Topology). Entry weights scale the external
/// rate; a key present with weight 0 is still an entry (Go's map semantics).
#[derive(Clone, Debug, Default, PartialEq)]
pub struct Topology {
    pub name: String,
    pub services: Vec<Service>,
    pub entry: BTreeMap<usize, f64>,
    order: Vec<usize>,
}

impl Topology {
    /// A topology with services and entry weights; call [`Topology::finish`] before using it.
    pub fn new(
        name: impl Into<String>,
        services: Vec<Service>,
        entry: BTreeMap<usize, f64>,
    ) -> Topology {
        Topology {
            name: name.into(),
            services,
            entry,
            order: Vec::new(),
        }
    }

    /// The service names in index order.
    pub fn names(&self) -> Vec<String> {
        self.services.iter().map(|s| s.name.clone()).collect()
    }

    /// The index of a service by name (Go returns -1 where this returns None).
    pub fn index(&self, name: &str) -> Option<usize> {
        self.services.iter().position(|s| s.name == name)
    }

    /// A topological order (callers before callees), set by finish.
    pub fn order(&self) -> &[usize] {
        &self.order
    }

    /// Validates the topology, fills defaults (servers and workers 1, routing pooled, servers from the shares)
    /// and computes its order. Checks run in Go's order and the first failure is returned; services before it
    /// keep their filled defaults, as in Go. (Go ranges over its entry map in random order, so with two bad
    /// entries it may name either; this names the lowest index.)
    pub fn finish(&mut self) -> Result<(), ModelError> {
        let n = self.services.len();
        let mut seen = std::collections::HashSet::new();
        for i in 0..n {
            let s = &mut self.services[i];
            if !seen.insert(s.name.clone()) {
                return Err(err!("duplicate service name {}", quote(&s.name)));
            }
            if s.servers < 0 || s.workers < 0 {
                return Err(err!("{}: servers and workers must not be negative", s.name));
            }
            if s.servers == 0 {
                if let Some(sh) = &s.shares {
                    s.servers = sh.len() as i64;
                }
            }
            if s.servers == 0 {
                s.servers = 1;
            }
            if s.workers == 0 {
                s.workers = 1;
            }
            if s.routing.is_empty() {
                s.routing = POOLED.to_string();
            }
            if s.routing != POOLED && s.routing != RANDOM {
                return Err(err!(
                    "{}: routing {} is not supported (pooled and random are)",
                    s.name,
                    quote(&s.routing)
                ));
            }
            if s.workers > 1 && s.routing == POOLED {
                return Err(err!(
                    "{}: workers per replica needs random routing; a pooled service is one shared queue of `servers` workers",
                    s.name
                ));
            }
            if !(s.s >= 0.0) || s.s == f64::INFINITY {
                return Err(err!(
                    "{}: service time must be a finite non-negative number, got {}",
                    s.name,
                    fmt_v(s.s)
                ));
            }
            if !(s.cs2 >= 0.0) || s.cs2.is_infinite() {
                return Err(err!(
                    "{}: cs2 must be a finite non-negative number, got {}",
                    s.name,
                    fmt_v(s.cs2)
                ));
            }
            if !(s.hop >= 0.0) || s.hop.is_infinite() {
                return Err(err!(
                    "{}: hop must be a finite non-negative number of ms, got {}",
                    s.name,
                    fmt_v(s.hop)
                ));
            }
            if !(s.glue >= 0.0)
                || s.glue.is_infinite()
                || !(s.glue_cs2 >= 0.0)
                || s.glue_cs2.is_infinite()
            {
                return Err(err!(
                    "{}: glue and glue_cs2 must be finite non-negative numbers, got {} and {}",
                    s.name,
                    fmt_v(s.glue),
                    fmt_v(s.glue_cs2)
                ));
            }
            if s.shares.is_some() {
                if let Err(e) = check_shares(s) {
                    return Err(err!("{}: {}", s.name, e));
                }
            }
            if !(s.branch_corr >= -1.0 && s.branch_corr <= 1.0) {
                return Err(err!(
                    "{}: branch_corr must be in [-1, 1] (values <= 0 are treated as independent), got {}",
                    s.name,
                    fmt_v(s.branch_corr)
                ));
            }
            for c in &s.calls {
                if c.child >= n {
                    return Err(err!("{}: call to an unknown service", s.name));
                }
                if !(c.p > 0.0 && c.p <= 1.0) {
                    return Err(err!(
                        "{}: call probability must be in (0, 1], got {}",
                        s.name,
                        fmt_v(c.p)
                    ));
                }
            }
            let sc = s.sync_calls();
            if s.parallel && sc.len() > 1 && sc.iter().any(|c| c.p < 1.0) {
                return Err(err!(
                    "{}: a parallel fan-out with call probabilities is not modelled",
                    s.name
                ));
            }
        }
        if self.entry.is_empty() {
            return Err(err!("the topology has no entry service"));
        }
        let mut wsum = 0.0;
        for (&i, &w) in &self.entry {
            if i >= n {
                return Err(err!("entry index {} is not a service", i));
            }
            if !(w >= 0.0) || w.is_infinite() {
                return Err(err!(
                    "{}: entry weight must be a finite non-negative number, got {}",
                    self.services[i].name,
                    fmt_v(w)
                ));
            }
            wsum += w;
        }
        if !(wsum > 0.0) {
            return Err(err!("the entry weights sum to zero"));
        }
        // Kahn's algorithm, children in call order (not map order), so the order is reproducible.
        let mut kids: Vec<Vec<usize>> = vec![Vec::new(); n];
        for (i, s) in self.services.iter().enumerate() {
            for c in &s.calls {
                if !kids[i].contains(&c.child) {
                    kids[i].push(c.child);
                }
            }
        }
        let mut indeg = vec![0usize; n];
        for ks in &kids {
            for &c in ks {
                indeg[c] += 1;
            }
        }
        let mut queue: std::collections::VecDeque<usize> =
            (0..n).filter(|&i| indeg[i] == 0).collect();
        let mut order = Vec::with_capacity(n);
        while let Some(i) = queue.pop_front() {
            order.push(i);
            for &c in &kids[i] {
                indeg[c] -= 1;
                if indeg[c] == 0 {
                    queue.push_back(c);
                }
            }
        }
        if order.len() != n {
            return Err(err!("the call graph has a cycle; the model needs a DAG"));
        }
        self.order = order;
        Ok(())
    }

    /// The expected visits to each service per unit of external traffic (async calls count).
    pub fn visit_ratios(&self) -> Vec<f64> {
        let n = self.services.len();
        let mut v = vec![0.0; n];
        for (&r, &w) in &self.entry {
            if r < n {
                v[r] = w;
            }
        }
        for &i in &self.order {
            for c in &self.services[i].calls {
                v[c.child] = fma(v[i], c.p, v[c.child]);
            }
        }
        v
    }
}

/// checkShares: one share per replica, each a positive number, summing to 1 within 1e-6.
fn check_shares(s: &Service) -> Result<(), String> {
    let sh = s.shares.as_deref().unwrap_or(&[]);
    if s.delay {
        return Err("a delay has no replicas to share its traffic".into());
    }
    if s.routing != RANDOM {
        return Err(format!(
            "replica shares need random routing (each replica its own queue), not {}",
            quote(&s.routing)
        ));
    }
    if sh.len() < 2 || sh.len() as i64 != s.servers {
        return Err(format!(
            "{} replica shares for {} replicas; give one per replica, for two or more",
            sh.len(),
            s.servers
        ));
    }
    let mut sum = 0.0;
    for &p in sh {
        if !(p > 0.0) || p == f64::INFINITY {
            return Err(format!(
                "a replica share must be a positive number, got {}",
                fmt_v(p)
            ));
        }
        sum += p;
    }
    if (sum - 1.0).abs() > 1e-6 {
        return Err(format!("the replica shares sum to {}, not 1", fmt_v(sum)));
    }
    Ok(())
}

// ------------------------------------------------------------------------------------------------- queues

/// ErlangC returns the probability that an arrival waits in an M/M/m queue offered a = lambda*s erlangs (NaN for
/// a NaN load). It sums a^k/k! forward, rescaling both sums by 2^-600 once a term passes 2^600.
pub fn erlang_c(m: i64, a: f64) -> f64 {
    if a.is_nan() {
        return a;
    }
    if m < 1 {
        return 1.0;
    }
    let rho = a / m as f64;
    if rho >= 1.0 {
        return 1.0;
    }
    if a <= 0.0 {
        return 0.0;
    }
    const BIG: f64 = f64::from_bits(0x6570_0000_0000_0000); // 2^600
    const SMALL: f64 = f64::from_bits(0x1a70_0000_0000_0000); // 2^-600
    let mut term = 1.0f64;
    let mut total = 1.0f64;
    let mut k = 1i64;
    while k < m {
        let q = a / k as f64;
        total = fma(term, q, total); // Go fuses `total += term` with the product that made the term
        term *= q;
        if term == 0.0 {
            // every later term is 0 too and adds nothing: the sums are final (bit for bit)
            break;
        }
        if term > BIG {
            (term, total) = rescale(term, total, SMALL);
        }
        k += 1;
    }
    let last = term * a / m as f64 / (1.0 - rho);
    last / (total + last)
}

/// ErlangC's rescaling, out of line: a call keeps the test a predicted branch, where LLVM would otherwise turn
/// it into selects on the loop's critical path (1.6x slower at 64 servers).
#[cold]
#[inline(never)]
fn rescale(term: f64, total: f64, small: f64) -> (f64, f64) {
    (term * small, total * small)
}

/// Residence returns the mean time in system of a G/G/m queue by the Allen-Cunneen approximation; +Inf when
/// unstable.
pub fn residence(s: f64, lam: f64, m: i64, ca2: f64, cs2: f64) -> f64 {
    if lam * s / m as f64 >= 1.0 {
        return f64::INFINITY;
    }
    if lam <= 0.0 {
        return s;
    }
    let w = erlang_c(m, lam * s) / (m as f64 / s - lam) * (ca2 + cs2);
    fma(w, 0.5, s) // s + w/2, Go's /2 is a *0.5 fused into the sum
}

/// ResidenceRouted returns the mean residence at a service of `servers` replicas with `workers` workers each
/// under a routing policy ("" is pooled).
pub fn residence_routed(
    s: f64,
    lam: f64,
    servers: i64,
    policy: &str,
    ca2: f64,
    cs2: f64,
    workers: i64,
) -> Result<f64, ModelError> {
    if servers < 1 || workers < 1 {
        return Err(err!("servers and workers must be at least 1"));
    }
    match policy {
        POOLED | "" => Ok(residence(s, lam, servers.wrapping_mul(workers), ca2, cs2)),
        RANDOM => {
            if servers == 1 {
                return Ok(residence(s, lam, workers, ca2, cs2));
            }
            if lam * s / (servers.wrapping_mul(workers)) as f64 >= 1.0 {
                return Ok(f64::INFINITY);
            }
            if lam <= 0.0 {
                return Ok(s);
            }
            let r = servers as f64;
            Ok(residence(s, lam / r, workers, ca2 / r + 1.0 - 1.0 / r, cs2))
        }
        _ => Err(err!(
            "routing policy {} is not supported (pooled and random are)",
            quote(policy)
        )),
    }
}

/// The mean residence at the replica that takes the share p of the traffic lam (arrivals thinned at random).
#[inline]
fn replica_residence(s: f64, lam: f64, p: f64, workers: i64, ca2: f64, cs2: f64) -> f64 {
    residence(s, lam * p, workers, fma(p, ca2, 1.0) - p, cs2)
}

/// ResidenceShares returns the mean residence at a service whose replicas take uneven shares of its traffic:
/// the share-weighted mean of each replica's G/G/c residence; +Inf when a replica is unstable.
pub fn residence_shares(s: f64, lam: f64, shares: &[f64], workers: i64, ca2: f64, cs2: f64) -> f64 {
    let mut r = 0.0;
    for &p in shares {
        r = fma(p, replica_residence(s, lam, p, workers, ca2, cs2), r);
    }
    r
}

// ------------------------------------------------------------------------------------------------- the model

/// The refinements of the basic model.
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct Config {
    /// Carries arrival variability through the graph (Whitt's QNA), used with this weight in [0, 1]: 0 is Poisson
    /// arrivals everywhere (the basic model), 1 is QNA in full.
    pub arrival_weight: f64,
    /// The expected maximum over parallel branches with each branch a gamma matched to its mean and variance.
    pub matched_max: bool,
}

/// The basic model (the reference implementation's default path).
pub const PLAIN: Config = Config {
    arrival_weight: 0.0,
    matched_max: false,
};
/// What the command line uses: arrival weight 0.7 and the matched maximum.
pub const DEFAULT: Config = Config {
    arrival_weight: 0.7,
    matched_max: true,
};

/// The solved network at one load (Go's model.Result). `None` is Go's nil slice: ca2, r and l are None when a
/// utilization reaches 1 (the early return), v when the config has no matched maximum.
#[derive(Clone, Debug, Default, PartialEq)]
pub struct ModelResult {
    /// Every utilization is below 1 and every result is a finite number.
    pub stable: bool,
    /// Utilization per service (0 for delays; with replica shares, the busiest replica's).
    pub rho: Vec<f64>,
    /// Arrival rate per service, per ms.
    pub lam: Vec<f64>,
    pub ca2: Option<Vec<f64>>,
    /// Mean residence per service (wait + service), ms.
    pub r: Option<Vec<f64>>,
    /// Variance of the residence (matched maximum only).
    pub v: Option<Vec<f64>>,
    /// Mean subtree latency per service (residence + calls + hops), ms.
    pub l: Option<Vec<f64>>,
}

impl ModelResult {
    /// The largest utilization and the service that has it; a NaN utilization is returned as such.
    pub fn max_rho(&self) -> (f64, Option<usize>) {
        let mut best = -1.0;
        let mut at = None;
        for (i, &v) in self.rho.iter().enumerate() {
            if v.is_nan() {
                return (v, Some(i));
            }
            if v > best {
                best = v;
                at = Some(i);
            }
        }
        (best, at)
    }
}

/// Analytic solves the basic network for an external rate lam_ext (requests per ms); ds is an optional
/// per-service change of the mean service time, ms.
pub fn analytic(t: &Topology, lam_ext: f64, ds: Option<&[f64]>) -> Result<ModelResult, ModelError> {
    analytic_with(t, lam_ext, ds, PLAIN)
}

/// Options that change how, not what, the model computes: every choice gives the same bits.
#[derive(Clone, Copy, Default)]
pub struct Exec<'a> {
    /// Evaluate the matched maximum's quadrature on the rayon pool for fan-outs of at least this many branches
    /// (0: never).
    pub parallel_quadrature_min_branches: usize,
    /// Reuse matched-maximum results across evaluations (see [`mathx::MaxMemo`]).
    pub memo: Option<&'a mathx::MaxMemo>,
}

impl std::fmt::Debug for Exec<'_> {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("Exec")
            .field(
                "parallel_quadrature_min_branches",
                &self.parallel_quadrature_min_branches,
            )
            .field("memo", &self.memo.is_some())
            .finish()
    }
}

/// AnalyticWith is Analytic with the refinements in cfg.
pub fn analytic_with(
    t: &Topology,
    lam_ext: f64,
    ds: Option<&[f64]>,
    cfg: Config,
) -> Result<ModelResult, ModelError> {
    analytic_exec(t, lam_ext, ds, cfg, Exec::default())
}

/// Per-service cs2 and glue that replace the topology's: ChangePatchWith's patched copy without copying the
/// topology (Go copies the services slice; a deep clone here would copy every name and call list).
#[derive(Clone, Copy, Default)]
struct Ovr<'a> {
    cs2: Option<&'a [f64]>,
    glue: Option<&'a [f64]>,
}

impl Ovr<'_> {
    #[inline(always)]
    fn cs2(&self, t: &Topology, i: usize) -> f64 {
        match self.cs2 {
            Some(c) => c[i],
            None => t.services[i].cs2,
        }
    }
    #[inline(always)]
    fn glue(&self, t: &Topology, i: usize) -> f64 {
        match self.glue {
            Some(g) => g[i],
            None => t.services[i].glue,
        }
    }
}

/// [`analytic_with`] with execution options.
pub fn analytic_exec(
    t: &Topology,
    lam_ext: f64,
    ds: Option<&[f64]>,
    cfg: Config,
    exec: Exec<'_>,
) -> Result<ModelResult, ModelError> {
    analytic_impl(t, lam_ext, ds, cfg, exec, Ovr::default())
}

fn analytic_impl(
    t: &Topology,
    lam_ext: f64,
    ds: Option<&[f64]>,
    cfg: Config,
    exec: Exec<'_>,
    ov: Ovr<'_>,
) -> Result<ModelResult, ModelError> {
    let n = t.services.len();
    if let Some(ds) = ds {
        if ds.len() != n {
            return Err(err!("ds has {} entries for {} services", ds.len(), n));
        }
    }
    if !(lam_ext >= 0.0) || lam_ext == f64::INFINITY {
        return Err(err!(
            "the external rate must be finite and non-negative, got {}",
            fmt_v(lam_ext)
        ));
    }
    if !(cfg.arrival_weight >= 0.0 && cfg.arrival_weight <= 1.0) {
        return Err(err!(
            "the arrival weight must be in [0, 1] (0: Poisson arrivals, 1: QNA in full), got {}",
            fmt_v(cfg.arrival_weight)
        ));
    }
    if let Some(ds) = ds {
        for (i, &d) in ds.iter().enumerate() {
            if d.is_nan() || d.is_infinite() || t.services[i].s + d < 0.0 {
                return Err(err!(
                    "{}: the changed service time {} + {} is not a non-negative number",
                    t.services[i].name,
                    fmt_v(t.services[i].s),
                    fmt_v(d)
                ));
            }
        }
    }
    let mut res = ModelResult {
        rho: vec![0.0; n],
        lam: t.visit_ratios(), // scaled to the rates below
        ..Default::default()
    };
    let mut s = vec![0.0; n];
    for i in 0..n {
        let sv = &t.services[i];
        s[i] = sv.s;
        if let Some(ds) = ds {
            s[i] += ds[i];
        }
        res.lam[i] *= lam_ext; // lamExt * v[i]
        if sv.delay {
        } else if let Some(sh) = &sv.shares {
            // the busiest replica: it is the one that saturates (slices.Max: NaN-propagating)
            let mut mx = sh[0];
            for &x in &sh[1..] {
                mx = gomath::max(mx, x);
            }
            res.rho[i] = res.lam[i] * mx * s[i] / sv.workers as f64;
        } else {
            let capacity = sv.servers.wrapping_mul(sv.workers) as f64;
            res.rho[i] = res.lam[i] * s[i] / capacity;
        }
    }
    if res.rho.iter().any(|&rho| rho >= 1.0) {
        return Ok(res); // stable stays false
    }
    let mut ca2 = vec![1.0; n];
    if cfg.arrival_weight != 0.0 {
        arrival_variability(t, lam_ext, &res, &s, cfg.arrival_weight, &mut ca2, ov);
    }
    res.ca2 = Some(ca2);
    let ca2 = res.ca2.as_ref().unwrap();
    let mut r = vec![0.0; n];
    for i in 0..n {
        let sv = &t.services[i];
        if sv.delay {
            r[i] = s[i];
            continue;
        }
        if let Some(sh) = &sv.shares {
            r[i] = residence_shares(s[i], res.lam[i], sh, sv.workers, ca2[i], ov.cs2(t, i));
            continue;
        }
        r[i] = residence_routed(
            s[i],
            res.lam[i],
            sv.servers,
            &sv.routing,
            ca2[i],
            ov.cs2(t, i),
            sv.workers,
        )?;
    }
    if cfg.matched_max {
        let var = residence_variance(t, &res, ca2, &r, &s, ov);
        res.l = Some(compose_matched(t, &r, &var, exec, ov));
        res.v = Some(var);
    } else {
        res.l = Some(compose(t, &r, ov));
    }
    res.r = Some(r);
    // A NaN or an infinity is never reported as stable; a NaN means an input got past the checks: an error.
    for xs in [
        Some(&res.rho),
        res.ca2.as_ref(),
        res.r.as_ref(),
        res.v.as_ref(),
        res.l.as_ref(),
    ]
    .into_iter()
    .flatten()
    {
        for (i, x) in xs.iter().enumerate() {
            if x.is_nan() {
                return Err(err!(
                    "{}: the model gives NaN at {} requests per ms (an input is out of range)",
                    t.services[i].name,
                    fmt_v(lam_ext)
                ));
            }
        }
    }
    let finite =
        |xs: &Option<Vec<f64>>| xs.as_ref().is_none_or(|v| v.iter().all(|x| x.is_finite()));
    res.stable = finite(&res.r) && finite(&res.v) && finite(&res.l);
    Ok(res)
}

/// The mean subtree latency per service of the basic model: sequential calls add, a parallel fan-out takes the
/// expected maximum of exponential branches, async calls add nothing, the glue comes last.
fn compose(t: &Topology, r: &[f64], ov: Ovr<'_>) -> Vec<f64> {
    let mut l = vec![0.0; t.services.len()];
    for &i in t.order.iter().rev() {
        let sv = &t.services[i];
        let calls = sv.sync_calls();
        if calls.is_empty() {
            l[i] = r[i];
        } else if sv.parallel {
            let mut buf = [0.0; 16];
            let mut heap = Vec::new();
            let vals: &mut [f64] = if calls.len() <= buf.len() {
                &mut buf[..calls.len()]
            } else {
                heap.resize(calls.len(), 0.0);
                &mut heap
            };
            for (x, c) in vals.iter_mut().zip(calls.iter()) {
                *x = c.p * (t.services[c.child].hop + l[c.child]);
            }
            l[i] = r[i] + mathx::emax_exp(vals);
        } else {
            let mut sum = 0.0;
            for c in calls.iter() {
                sum = fma(c.p, t.services[c.child].hop + l[c.child], sum);
            }
            l[i] = r[i] + sum;
        }
        l[i] += ov.glue(t, i);
    }
    l
}

/// departureSCV: the squared coefficient of variation of a queue's departures (Whitt's QNA, multi-server form).
#[inline]
fn departure_scv(ca2: f64, cs2: f64, rho: f64, c: i64) -> f64 {
    fma(fma(-rho, rho, 1.0), ca2 - 1.0, 1.0) + rho * rho * (cs2 - 1.0) / (c as f64).sqrt()
}

/// arrivalVariability: the squared coefficient of variation of the arrivals each service sees (QNA), weighted.
fn arrival_variability(
    t: &Topology,
    lam_ext: f64,
    res: &ModelResult,
    s: &[f64],
    weight: f64,
    out: &mut [f64],
    ov: Ovr<'_>,
) {
    let n = t.services.len();
    let mut inflow: Vec<Vec<(f64, f64)>> = vec![Vec::new(); n]; // (rate, scv)
    for (&i, &w) in &t.entry {
        inflow[i].push((lam_ext * w, 1.0));
    }
    for &i in &t.order {
        let sv = &t.services[i];
        let fl = std::mem::take(&mut inflow[i]);
        let mut tot = 0.0;
        for f in &fl {
            tot += f.0;
        }
        let mut ca2 = 1.0;
        if tot > 0.0 {
            let mut asym = 0.0;
            let mut sum_sq = 0.0;
            for f in &fl {
                let share = f.0 / tot;
                asym = fma(share, f.1, asym);
                sum_sq = fma(share, share, sum_sq);
            }
            let v = 1.0 / sum_sq;
            let x = 1.0 - res.rho[i];
            let w = 1.0 / fma(4.0 * x * x, v - 1.0, 1.0);
            ca2 = fma(w, asym, 1.0 - w);
        }
        let mut cd2 = ca2;
        if sv.delay {
        } else if let Some(sh) = &sv.shares {
            cd2 = 0.0;
            for &p in sh {
                let rho = res.lam[i] * p * s[i] / sv.workers as f64;
                cd2 = fma(
                    p,
                    departure_scv(fma(p, ca2, 1.0) - p, ov.cs2(t, i), rho, sv.workers),
                    cd2,
                );
            }
        } else {
            let capacity = sv.servers.wrapping_mul(sv.workers);
            let mut c = sv.workers;
            let mut ca_q = ca2;
            if sv.servers > 1 && sv.routing == RANDOM {
                let r = sv.servers as f64;
                ca_q = ca2 / r + 1.0 - 1.0 / r;
            } else {
                c = capacity;
            }
            cd2 = departure_scv(ca_q, ov.cs2(t, i), res.rho[i], c);
        }
        for c in &sv.calls {
            inflow[c.child].push((res.lam[i] * c.p, fma(c.p, cd2, 1.0 - c.p)));
        }
        out[i] = fma(weight, ca2 - 1.0, 1.0);
    }
}

/// The chance an arrival waits at a queue of c workers offered a erlangs.
#[inline]
fn wait_chance(c: i64, a: f64) -> f64 {
    if c == 1 {
        return gomath::min(a, 1.0);
    }
    erlang_c(c, a)
}

/// The chance an arrival waits, by the service's routing.
#[inline]
fn wait_probability(sv: &Service, s: f64, lam: f64) -> f64 {
    if sv.routing == RANDOM && sv.servers > 1 {
        let lam = lam / sv.servers as f64;
        if sv.workers == 1 {
            return gomath::min(lam * s, 1.0);
        }
        return erlang_c(sv.workers, lam * s);
    }
    let c = sv.servers.wrapping_mul(sv.workers);
    if c == 1 {
        return gomath::min(lam * s, 1.0);
    }
    erlang_c(c, lam * s)
}

/// residenceVariance: the wait is a mixture of zero and an exponential matched to the mean wait; the service
/// adds cs2*s^2. With replica shares the wait is that mixture per replica, mixed by the shares.
fn residence_variance(
    t: &Topology,
    res: &ModelResult,
    ca2: &[f64],
    r: &[f64],
    s: &[f64],
    ov: Ovr<'_>,
) -> Vec<f64> {
    let n = t.services.len();
    let mut v = vec![0.0; n];
    for i in 0..n {
        let sv = &t.services[i];
        let cs2 = ov.cs2(t, i);
        if sv.delay {
            v[i] = cs2 * s[i] * s[i];
            continue;
        }
        if let Some(sh) = &sv.shares {
            let mut ew2 = 0.0;
            for &p in sh {
                let wq = gomath::max(
                    replica_residence(s[i], res.lam[i], p, sv.workers, ca2[i], cs2) - s[i],
                    0.0,
                );
                let pw = wait_chance(sv.workers, res.lam[i] * p * s[i]);
                if pw > 0.0 {
                    ew2 += p * 2.0 * wq * wq / pw;
                }
            }
            let wq = gomath::max(r[i] - s[i], 0.0);
            v[i] = fma(cs2 * s[i], s[i], gomath::max(fma(-wq, wq, ew2), 0.0));
            continue;
        }
        let wq = gomath::max(r[i] - s[i], 0.0);
        let pw = wait_probability(sv, s[i], res.lam[i]);
        let mut var_w = 0.0;
        if pw > 0.0 {
            var_w = gomath::max(fma(-wq, wq, 2.0 * wq * wq / pw), 0.0);
        }
        v[i] = fma(cs2 * s[i], s[i], var_w);
    }
    v
}

/// composeMatched: compose with variances; a parallel fan-out takes the moments of the maximum of gamma
/// branches matched to each branch's mean and variance (correlated by branch_corr).
fn compose_matched(t: &Topology, r: &[f64], v: &[f64], exec: Exec<'_>, ov: Ovr<'_>) -> Vec<f64> {
    let n = t.services.len();
    let mut l = vec![0.0; n];
    let mut vl = vec![0.0; n];
    for &i in t.order.iter().rev() {
        let sv = &t.services[i];
        let calls = sv.sync_calls();
        if calls.is_empty() {
            l[i] = r[i];
            vl[i] = v[i];
        } else if sv.parallel && calls.len() > 1 {
            let mu: Vec<f64> = calls
                .iter()
                .map(|c| t.services[c.child].hop + l[c.child])
                .collect();
            let va: Vec<f64> = calls.iter().map(|c| vl[c.child]).collect();
            let par = exec.parallel_quadrature_min_branches > 0
                && calls.len() >= exec.parallel_quadrature_min_branches;
            let compute = || {
                if par {
                    mathx::max_moments_gamma_corr_par(&mu, &va, sv.branch_corr)
                } else {
                    mathx::max_moments_gamma_corr(&mu, &va, sv.branch_corr)
                }
            };
            let (m, mv) = match exec.memo {
                Some(memo) => memo.get_or_compute(&mu, &va, sv.branch_corr, compute),
                None => compute(),
            };
            l[i] = r[i] + m;
            vl[i] = v[i] + mv;
        } else {
            let mut sum = 0.0;
            let mut vs = 0.0;
            for c in calls.iter() {
                let m = t.services[c.child].hop + l[c.child];
                sum = fma(c.p, m, sum);
                let pm = c.p * m;
                vs += fma(-pm, pm, c.p * fma(m, m, vl[c.child]));
            }
            l[i] = r[i] + sum;
            vl[i] = v[i] + vs;
        }
        let glue = ov.glue(t, i);
        l[i] += glue;
        vl[i] = fma(sv.glue_cs2 * glue, glue, vl[i]);
    }
    l
}

/// A change of per-visit times (Go's model.Patch). `ds[i]` ms is added to service i's service time: a constant
/// extra time on every visit where `shift[i]` is set (the variance stays), else the time is scaled (its cs2
/// stays). `glue[i]` ms is added to its glue, scaled. None changes nothing.
#[derive(Clone, Debug, Default, PartialEq)]
pub struct Patch {
    pub ds: Option<Vec<f64>>,
    pub shift: Option<Vec<bool>>,
    pub glue: Option<Vec<f64>>,
}

/// The model before and after a change of service times (Go's model.Delta).
#[derive(Clone, Debug, PartialEq)]
pub struct Delta {
    pub stable: bool,
    pub base: ModelResult,
    pub patched: ModelResult,
    /// patched.l - base.l per service; None if unstable.
    pub dl: Option<Vec<f64>>,
}

/// ChangePatchWith solves the network at lam_ext before and after the patch p.
pub fn change_patch_with(
    t: &Topology,
    lam_ext: f64,
    p: &Patch,
    cfg: Config,
) -> Result<Delta, ModelError> {
    change_patch_exec(t, lam_ext, p, cfg, Exec::default())
}

/// Change solves the network at lam_ext before and after adding ds (ms) to the service times, the time scaled
/// (cs2 held), under the basic model (Go's model.Change).
pub fn change(t: &Topology, lam_ext: f64, ds: Option<&[f64]>) -> Result<Delta, ModelError> {
    change_shift_with(t, lam_ext, ds, None, PLAIN)
}

/// ChangeShift is [`change`] where services with `shift[i]` set get a constant extra time `ds[i]` on every visit
/// (the variance stays, so cs2 falls to cs2*s^2/(s+ds)^2) (Go's model.ChangeShift).
pub fn change_shift(
    t: &Topology,
    lam_ext: f64,
    ds: Option<&[f64]>,
    shift: Option<&[bool]>,
) -> Result<Delta, ModelError> {
    change_shift_with(t, lam_ext, ds, shift, PLAIN)
}

/// ChangeShiftWith is [`change_shift`] with the refinements in cfg (Go's model.ChangeShiftWith).
pub fn change_shift_with(
    t: &Topology,
    lam_ext: f64,
    ds: Option<&[f64]>,
    shift: Option<&[bool]>,
    cfg: Config,
) -> Result<Delta, ModelError> {
    let p = Patch {
        ds: ds.map(<[f64]>::to_vec),
        shift: shift.map(<[bool]>::to_vec),
        glue: None,
    };
    change_patch_with(t, lam_ext, &p, cfg)
}

/// IsFinite reports whether every value is a finite number (Go's model.IsFinite).
pub fn is_finite(xs: &[f64]) -> bool {
    xs.iter().all(|x| x.is_finite())
}

/// [`change_patch_with`] with execution options.
pub fn change_patch_exec(
    t: &Topology,
    lam_ext: f64,
    p: &Patch,
    cfg: Config,
    exec: Exec<'_>,
) -> Result<Delta, ModelError> {
    check_patch(t, p)?; // before the base, as Go checks
    let b = analytic_exec(t, lam_ext, None, cfg, exec)?;
    change_patch_from_base(t, lam_ext, p, cfg, exec, b)
}

/// ChangePatchWith's length checks (run before the base is solved).
pub fn check_patch(t: &Topology, p: &Patch) -> Result<(), ModelError> {
    let n = t.services.len();
    let nds = p.ds.as_ref().map_or(0, |d| d.len());
    if let Some(shift) = &p.shift {
        if shift.len() != n || nds != n {
            return Err(err!(
                "shift has {} entries and ds {} for {} services",
                shift.len(),
                nds,
                n
            ));
        }
    }
    if let Some(g) = &p.glue {
        if g.len() != n {
            return Err(err!(
                "the glue change has {} entries for {} services",
                g.len(),
                n
            ));
        }
    }
    Ok(())
}

/// The patched half of ChangePatchWith given the base result (a sweep over patches at one load reuses it).
pub fn change_patch_from_base(
    t: &Topology,
    lam_ext: f64,
    p: &Patch,
    cfg: Config,
    exec: Exec<'_>,
    b: ModelResult,
) -> Result<Delta, ModelError> {
    let n = t.services.len();
    let ds = p.ds.as_deref();
    check_patch(t, p)?;
    // the patched services' cs2 and glue (Go copies the services and changes these two fields)
    let mut cs2v: Option<Vec<f64>> = None;
    let mut gluev: Option<Vec<f64>> = None;
    for i in 0..n {
        if let (Some(shift), Some(ds)) = (&p.shift, ds) {
            if shift[i] && ds[i] != 0.0 {
                let s = t.services[i].s;
                if s + ds[i] > 0.0 {
                    let c = cs2v.get_or_insert_with(|| t.services.iter().map(|x| x.cs2).collect());
                    c[i] = t.services[i].cs2 * s * s / ((s + ds[i]) * (s + ds[i]));
                }
            }
        }
        if let Some(gl) = &p.glue {
            if gl[i] != 0.0 {
                let g = t.services[i].glue + gl[i];
                if !(g >= 0.0) || g.is_infinite() {
                    return Err(err!(
                        "{}: the changed glue {} + {} is not a non-negative number",
                        t.services[i].name,
                        fmt_v(t.services[i].glue),
                        fmt_v(gl[i])
                    ));
                }
                gluev.get_or_insert_with(|| t.services.iter().map(|x| x.glue).collect())[i] = g;
            }
        }
    }
    let ov = Ovr {
        cs2: cs2v.as_deref(),
        glue: gluev.as_deref(),
    };
    let pr = analytic_impl(t, lam_ext, ds, cfg, exec, ov)?;
    let stable = b.stable && pr.stable;
    let dl = if stable {
        let (bl, pl) = (b.l.as_ref().unwrap(), pr.l.as_ref().unwrap());
        Some(pl.iter().zip(bl).map(|(x, y)| x - y).collect())
    } else {
        None
    };
    Ok(Delta {
        stable,
        base: b,
        patched: pr,
        dl,
    })
}

/// One `--patch` change as the report lists it (Go's report.Change).
#[derive(Clone, Debug, PartialEq)]
pub struct Change {
    pub service: String,
    /// The whole change, ms (service time and glue).
    pub delta_ms: f64,
    /// The part of it in the glue, ms.
    pub glue_ms: f64,
    pub spec: String,
}

/// cmd/rhobound's parsePatch: "svc=+3ms,other=-10%" to a Patch. +N ms is extra work on every visit added to the
/// service time (a shift); +N% scales the service's own time, service time and glue alike. Numbers are read
/// as Go's strconv.ParseFloat reads them ([`parse_go_float`]: decimal and hexadecimal forms, `_` separators,
/// inf and nan); the error texts are cmd/rhobound's.
pub fn parse_patch(spec: &str, topo: &Topology) -> Result<(Patch, Vec<Change>), String> {
    parse_patch_bytes(spec.as_bytes(), topo)
}

/// [`parse_patch`] of a Go string (any bytes, as a command-line argument can be): a service name that is not
/// UTF-8 matches no service, a value that is not UTF-8 does not parse, and both are quoted as Go quotes them.
pub fn parse_patch_bytes(spec: &[u8], topo: &Topology) -> Result<(Patch, Vec<Change>), String> {
    use rbfast_gostr::{quote_bytes, trim_space};
    if spec.is_empty() {
        return Ok((Patch::default(), Vec::new()));
    }
    let n = topo.services.len();
    let mut ds = vec![0.0; n];
    let mut shift = vec![false; n];
    let mut glue_v = vec![0.0; n];
    let mut changes = Vec::new();
    let text = |b: &[u8]| String::from_utf8_lossy(b).into_owned();
    for kv in spec
        .split(|&c| c == b',')
        .map(trim_space)
        .filter(|s| !s.is_empty())
    {
        let (name, val, ok) = match kv.iter().position(|&c| c == b'=') {
            Some(k) => (trim_space(&kv[..k]), trim_space(&kv[k + 1..]), true),
            None => (trim_space(kv), &b""[..], false),
        };
        let i = match (
            ok,
            std::str::from_utf8(name).ok().and_then(|nm| topo.index(nm)),
        ) {
            (true, Some(i)) => i,
            _ => {
                return Err(format!(
                    "--patch: unknown service in {} (services: {})",
                    quote_bytes(kv),
                    topo.names().join(", ")
                ))
            }
        };
        let float = |b: &[u8]| std::str::from_utf8(b).ok().and_then(parse_go_float);
        let (delta, glue, parsed);
        if let Some(num) = val.strip_suffix(b"%") {
            let pct = float(num);
            parsed = pct.is_some();
            let pct = pct.unwrap_or(0.0);
            delta = topo.services[i].s * pct / 100.0;
            glue = topo.services[i].glue * pct / 100.0;
        } else {
            let d = float(val.strip_suffix(b"ms").unwrap_or(val));
            parsed = d.is_some();
            delta = d.unwrap_or(0.0);
            glue = 0.0;
            shift[i] = true;
        }
        if !parsed || delta.is_nan() || delta.is_infinite() || glue.is_nan() || glue.is_infinite() {
            return Err(format!(
                "--patch: cannot read {} (use +3ms or -10%)",
                quote_bytes(kv)
            ));
        }
        ds[i] += delta;
        glue_v[i] += glue;
        // the name matched a service and the value parsed: both are UTF-8 here
        let name = text(name);
        changes.push(Change {
            service: name.clone(),
            delta_ms: delta + glue,
            glue_ms: glue,
            spec: text(val),
        });
        if topo.services[i].s + ds[i] < 0.0 {
            return Err(format!("--patch: {name} would get a negative service time"));
        }
        if topo.services[i].glue + glue_v[i] < 0.0 {
            return Err(format!("--patch: {name} would get a negative glue time"));
        }
    }
    Ok((
        Patch {
            ds: Some(ds),
            shift: Some(shift),
            glue: Some(glue_v),
        },
        changes,
    ))
}

/// Go's strconv.ParseFloat(s, 64): decimal and hexadecimal (`0x1p-2`) forms, `_` between digits, `inf`,
/// `infinity` and `nan` in any case. None where Go returns an error (a syntax error, or a value out of range,
/// which Go reports as ±Inf with ErrRange). Decimal values are rounded by Rust's correctly rounded parser, as
/// Go's are by its own.
pub fn parse_go_float(s: &str) -> Option<f64> {
    if let Some((v, n)) = go_special(s) {
        return if n == s.len() { Some(v) } else { None };
    }
    let rf = go_read_float(s)?;
    if rf.n != s.len() {
        return None;
    }
    if rf.hex {
        return go_atof_hex(rf.mantissa, rf.exp, rf.neg, rf.trunc);
    }
    let clean: String = s.chars().filter(|&c| c != '_').collect();
    let x: f64 = clean.parse().ok()?;
    if x.is_infinite() {
        return None; // ErrRange
    }
    Some(x)
}

fn go_special(s: &str) -> Option<(f64, usize)> {
    let b = s.as_bytes();
    if b.is_empty() {
        return None;
    }
    let prefix = |t: &[u8], word: &str| {
        t.iter()
            .zip(word.bytes())
            .take_while(|(a, w)| a.to_ascii_lowercase() == *w)
            .count()
    };
    let (sign, nsign, rest) = match b[0] {
        b'+' => (1.0, 1, &b[1..]),
        b'-' => (-1.0, 1, &b[1..]),
        _ => (1.0, 0, b),
    };
    if nsign == 1 || b[0] == b'i' || b[0] == b'I' {
        let mut n = prefix(rest, "infinity");
        if 3 < n && n < 8 {
            n = 3;
        }
        if n == 3 || n == 8 {
            return Some((sign * f64::INFINITY, nsign + n));
        }
        return None;
    }
    if (b[0] == b'n' || b[0] == b'N') && prefix(b, "nan") == 3 {
        return Some((f64::NAN, 3));
    }
    None
}

struct ReadFloat {
    mantissa: u64,
    exp: i64,
    neg: bool,
    trunc: bool,
    hex: bool,
    n: usize,
}

/// Go's readFloat: the syntax, and for hexadecimal input the mantissa and binary exponent.
fn go_read_float(s: &str) -> Option<ReadFloat> {
    let b = s.as_bytes();
    let mut i = 0;
    let mut underscores = false;
    let mut neg = false;
    if i >= b.len() {
        return None;
    }
    match b[i] {
        b'+' => i += 1,
        b'-' => {
            i += 1;
            neg = true;
        }
        _ => {}
    }
    let mut base = 10u64;
    let mut max_mant = 19;
    let mut exp_char = b'e';
    let mut hex = false;
    if i + 2 < b.len() && b[i] == b'0' && b[i + 1].eq_ignore_ascii_case(&b'x') {
        base = 16;
        max_mant = 16;
        i += 2;
        exp_char = b'p';
        hex = true;
    }
    let (mut sawdot, mut sawdigits) = (false, false);
    let (mut nd, mut nd_mant, mut dp) = (0i64, 0i64, 0i64);
    let mut mantissa = 0u64;
    let mut trunc = false;
    while i < b.len() {
        let c = b[i];
        let lc = c.to_ascii_lowercase();
        if c == b'_' {
            underscores = true;
        } else if c == b'.' {
            if sawdot {
                break;
            }
            sawdot = true;
            dp = nd;
        } else if c.is_ascii_digit() {
            sawdigits = true;
            if c == b'0' && nd == 0 {
                dp -= 1;
                i += 1;
                continue;
            }
            nd += 1;
            if nd_mant < max_mant {
                mantissa = mantissa.wrapping_mul(base).wrapping_add((c - b'0') as u64);
                nd_mant += 1;
            } else if c != b'0' {
                trunc = true;
            }
        } else if base == 16 && (b'a'..=b'f').contains(&lc) {
            sawdigits = true;
            nd += 1;
            if nd_mant < max_mant {
                mantissa = mantissa * 16 + (lc - b'a' + 10) as u64;
                nd_mant += 1;
            } else {
                trunc = true;
            }
        } else {
            break;
        }
        i += 1;
    }
    if !sawdigits {
        return None;
    }
    if !sawdot {
        dp = nd;
    }
    if base == 16 {
        dp *= 4;
        nd_mant *= 4;
    }
    if i < b.len() && b[i].to_ascii_lowercase() == exp_char {
        i += 1;
        if i >= b.len() {
            return None;
        }
        let mut esign = 1i64;
        match b[i] {
            b'+' => i += 1,
            b'-' => {
                i += 1;
                esign = -1;
            }
            _ => {}
        }
        if i >= b.len() || !b[i].is_ascii_digit() {
            return None;
        }
        let mut e = 0i64;
        while i < b.len() && (b[i].is_ascii_digit() || b[i] == b'_') {
            if b[i] == b'_' {
                underscores = true;
            } else if e < 10000 {
                e = e * 10 + (b[i] - b'0') as i64;
            }
            i += 1;
        }
        dp += e * esign;
    } else if base == 16 {
        return None; // a hexadecimal float must have an exponent
    }
    let exp = if mantissa != 0 { dp - nd_mant } else { 0 };
    if underscores && !go_underscore_ok(&s[..i]) {
        return None;
    }
    Some(ReadFloat {
        mantissa,
        exp,
        neg,
        trunc,
        hex,
        n: i,
    })
}

fn go_underscore_ok(s: &str) -> bool {
    let mut b = s.as_bytes();
    if !b.is_empty() && (b[0] == b'-' || b[0] == b'+') {
        b = &b[1..];
    }
    let mut saw = b'^';
    let mut i = 0;
    let mut hex = false;
    if b.len() >= 2 && b[0] == b'0' && matches!(b[1].to_ascii_lowercase(), b'b' | b'o' | b'x') {
        i = 2;
        saw = b'0';
        hex = b[1].eq_ignore_ascii_case(&b'x');
    }
    while i < b.len() {
        let c = b[i];
        if c.is_ascii_digit() || hex && (b'a'..=b'f').contains(&c.to_ascii_lowercase()) {
            saw = b'0';
        } else if c == b'_' {
            if saw != b'0' {
                return false;
            }
            saw = b'_';
        } else {
            if saw == b'_' {
                return false;
            }
            saw = b'!';
        }
        i += 1;
    }
    saw != b'_'
}

/// Go's atofHex for float64; None on ErrRange (overflow).
fn go_atof_hex(mut mantissa: u64, mut exp: i64, neg: bool, trunc: bool) -> Option<f64> {
    const MANTBITS: u32 = 52;
    const BIAS: i64 = -1023;
    let max_exp: i64 = (1 << 11) + BIAS - 2;
    let min_exp: i64 = BIAS + 1;
    exp += MANTBITS as i64;
    while mantissa != 0 && mantissa >> (MANTBITS + 2) == 0 {
        mantissa <<= 1;
        exp -= 1;
    }
    if trunc {
        mantissa |= 1;
    }
    while mantissa >> (1 + MANTBITS + 2) != 0 {
        mantissa = (mantissa >> 1) | (mantissa & 1);
        exp += 1;
    }
    while mantissa > 1 && exp < min_exp - 2 {
        mantissa = (mantissa >> 1) | (mantissa & 1);
        exp += 1;
    }
    let mut round = mantissa & 3;
    mantissa >>= 2;
    round |= mantissa & 1;
    exp += 2;
    if round == 3 {
        mantissa += 1;
        if mantissa == 1 << (1 + MANTBITS) {
            mantissa >>= 1;
            exp += 1;
        }
    }
    if mantissa >> MANTBITS == 0 {
        exp = BIAS;
    }
    if exp > max_exp {
        return None;
    }
    let mut bits = mantissa & ((1 << MANTBITS) - 1);
    bits |= (((exp - BIAS) & ((1 << 11) - 1)) as u64) << MANTBITS;
    if neg {
        bits |= 1 << 63;
    }
    Some(f64::from_bits(bits))
}
