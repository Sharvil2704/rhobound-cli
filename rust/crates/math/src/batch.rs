// SPDX-License-Identifier: Apache-2.0

//! Many what-ifs at once: a batch of (topology, load, patch, config) scenarios evaluated in parallel on a rayon
//! pool. Each scenario is computed exactly as the serial model computes it (one scenario per task, no shared
//! accumulation), so every result is bit-identical to [`crate::model::analytic_with`] or
//! [`crate::model::change_patch_with`] whatever the thread count, and results come back in input order.
//!
//! [`sweep`] evaluates a grid (loads x configs x patches); with `share_base` it solves the unpatched base once
//! per (load, config) instead of once per patch, as Go's ChangePatchWith does on every call: the base is a pure
//! function of the same inputs, so the outputs are the same bits and the work drops by up to half. A
//! [`crate::mathx::MaxMemo`] in the [`Exec`] reuses matched-maximum results across scenarios (same bits too).
//!
//! Measured (8-core arm64, a 10,000-scenario grid on an inferred 10-service topology, 50 loads x 2 configs x 100
//! patches): Go's work in 28.6 s on 1 thread and 3.66 s on 8 (Go: 42.5 s serial, 5.47-5.69 s on 8 goroutines);
//! with `share_base` and the memo, 0.51 s on 8 threads.

use crate::model::{
    analytic_exec, change_patch_exec, change_patch_from_base, check_patch, Config, Delta, Exec,
    ModelError, ModelResult, Patch, Topology,
};
use rayon::prelude::*;

/// One what-if: the model at `lam_ext` (requests per ms), with `patch` applied when given (then the outcome is
/// a before/after [`Delta`], as ChangePatchWith returns), under `config`.
#[derive(Clone, Copy, Debug)]
pub struct Scenario<'a> {
    pub topology: &'a Topology,
    pub lam_ext: f64,
    pub patch: Option<&'a Patch>,
    pub config: Config,
}

/// The result of one scenario.
#[derive(Clone, Debug, PartialEq)]
pub enum Outcome {
    /// No patch: AnalyticWith's result.
    Base(Result<ModelResult, ModelError>),
    /// A patch: ChangePatchWith's result.
    Change(Result<Delta, ModelError>),
}

impl Outcome {
    /// The mean latency at the given service (the base's, or the patched one's for a change), when stable.
    pub fn latency(&self, service: usize) -> Option<f64> {
        match self {
            Outcome::Base(Ok(r)) if r.stable => r.l.as_ref().map(|l| l[service]),
            Outcome::Change(Ok(d)) if d.stable => d.patched.l.as_ref().map(|l| l[service]),
            _ => None,
        }
    }
}

/// Evaluates one scenario on the calling thread.
pub fn evaluate(sc: &Scenario, exec: Exec<'_>) -> Outcome {
    match sc.patch {
        None => Outcome::Base(analytic_exec(
            sc.topology,
            sc.lam_ext,
            None,
            sc.config,
            exec,
        )),
        Some(p) => Outcome::Change(change_patch_exec(
            sc.topology,
            sc.lam_ext,
            p,
            sc.config,
            exec,
        )),
    }
}

/// Runs `f` on a pool of `threads` threads (0: rayon's global pool, one thread per core). Err when the pool
/// cannot be started (the OS refused a thread): `thread pool: ` and the OS's text, as the capture reader says.
pub fn with_threads<R: Send>(threads: usize, f: impl FnOnce() -> R + Send) -> Result<R, String> {
    if threads == 0 {
        return Ok(f());
    }
    let pool = rayon::ThreadPoolBuilder::new()
        .num_threads(threads)
        .build()
        .map_err(|e| {
            // rayon's text is the io::Error's: drop Rust's " (os error N)" and lower the first letter (Go's style)
            let mut s = e.to_string();
            if let Some(k) = s.find(" (os error ") {
                s.truncate(k);
            }
            let mut c = s.chars();
            let s = match c.next() {
                Some(f) => f.to_lowercase().collect::<String>() + c.as_str(),
                None => s,
            };
            format!("thread pool: {s}")
        })?;
    Ok(pool.install(f))
}

/// Evaluates every scenario, in parallel on the current rayon pool; results in input order.
pub fn evaluate_batch(scenarios: &[Scenario], exec: Exec<'_>) -> Vec<Outcome> {
    scenarios
        .par_iter()
        .with_max_len(1)
        .map(|sc| evaluate(sc, exec))
        .collect()
}

/// A grid of what-ifs on one topology.
#[derive(Clone, Debug)]
pub struct Grid<'a> {
    pub topology: &'a Topology,
    /// External rates, requests per ms.
    pub lams: Vec<f64>,
    pub configs: Vec<Config>,
    /// None evaluates the base alone (AnalyticWith); Some(patch) a change (ChangePatchWith).
    pub patches: Vec<Option<Patch>>,
}

impl Grid<'_> {
    /// The number of scenarios, lams x configs x patches.
    pub fn len(&self) -> usize {
        self.lams.len() * self.configs.len() * self.patches.len()
    }
    pub fn is_empty(&self) -> bool {
        self.len() == 0
    }
    /// The (lam, config, patch) indices of scenario k (load-major, then config, then patch).
    pub fn index(&self, k: usize) -> (usize, usize, usize) {
        let np = self.patches.len();
        let nc = self.configs.len();
        (k / (nc * np), (k / np) % nc, k % np)
    }
}

/// Evaluates a grid in parallel on the current rayon pool; results in [`Grid::index`] order. With
/// `share_base`, the base of each (load, config) is solved once and reused by its patches (same bits as
/// solving it per patch, which is what Go does and what `share_base = false` does).
pub fn sweep(grid: &Grid, exec: Exec<'_>, share_base: bool) -> Vec<Outcome> {
    let (nl, nc) = (grid.lams.len(), grid.configs.len());
    if !share_base {
        return (0..grid.len())
            .into_par_iter()
            .with_max_len(1)
            .map(|k| {
                let (li, ci, pi) = grid.index(k);
                let sc = Scenario {
                    topology: grid.topology,
                    lam_ext: grid.lams[li],
                    patch: grid.patches[pi].as_ref(),
                    config: grid.configs[ci],
                };
                evaluate(&sc, exec)
            })
            .collect();
    }
    // bases first (one task each), then every patched solve against its base
    let bases: Vec<Result<ModelResult, ModelError>> = (0..nl * nc)
        .into_par_iter()
        .with_max_len(1)
        .map(|b| {
            analytic_exec(
                grid.topology,
                grid.lams[b / nc],
                None,
                grid.configs[b % nc],
                exec,
            )
        })
        .collect();
    (0..grid.len())
        .into_par_iter()
        .with_max_len(1)
        .map(|k| {
            let (li, ci, pi) = grid.index(k);
            let base = &bases[li * nc + ci];
            match &grid.patches[pi] {
                None => Outcome::Base(base.clone()),
                Some(p) => Outcome::Change(match base {
                    // Go checks the patch's lengths before it solves the base
                    Err(e) => check_patch(grid.topology, p).and(Err(e.clone())),
                    Ok(b) => change_patch_from_base(
                        grid.topology,
                        grid.lams[li],
                        p,
                        grid.configs[ci],
                        exec,
                        b.clone(),
                    ),
                }),
            }
        })
        .collect()
}
