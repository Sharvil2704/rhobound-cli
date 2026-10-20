// SPDX-License-Identifier: Apache-2.0

//! The earlier estimator, `rise` (RHOBOUND_ESTIMATOR=rise): own time by the number of visits already busy at
//! arrival, workers from where it rises (rhobound-cli infer.go: byK, workersFromK, poolBelow, sweepByK).
//! The sweep runs per service in parallel, each service's pods in ascending order as in Go, so every sum is
//! taken in Go's order.

use rayon::prelude::*;

use crate::gosort;
use crate::{Seg, VisitRec};

pub const MAX_K: usize = 64;
pub const IDLE_MIN: f64 = 100.0;
pub const OVERLAP_EPSILON_NS: u64 = 100_000;

/// Own times of visits by the number of other visits busy on the same pod at their arrival.
#[derive(Clone, Debug)]
pub struct ByK {
    pub n: [i64; MAX_K + 1],
    pub sum: [f64; MAX_K + 1],
    pub sq: [f64; MAX_K + 1],
    pub peak: i64,
}

impl Default for ByK {
    fn default() -> Self {
        ByK { n: [0; MAX_K + 1], sum: [0.0; MAX_K + 1], sq: [0.0; MAX_K + 1], peak: 0 }
    }
}

/// Running sums of own times.
#[derive(Clone, Copy, Debug, Default)]
pub struct Moments {
    pub n: f64,
    pub sum: f64,
    pub sq: f64,
}

impl Moments {
    pub fn add(&mut self, n: i64, sum: f64, sq: f64) {
        self.n += n as f64;
        self.sum += sum;
        self.sq += sq;
    }

    pub fn mean(&self) -> f64 {
        if self.n == 0.0 {
            0.0
        } else {
            self.sum / self.n
        }
    }

    pub fn variance(&self) -> f64 {
        if self.n < 2.0 {
            return 0.0;
        }
        let mu = self.sum / self.n;
        (-(self.n * mu)).mul_add(mu, self.sq) / (self.n - 1.0)
    }
}

/// Workers per pod from where the own time rises with the number busy at arrival; (workers, saturated, the free
/// visits' moments, whether there are enough of them).
pub fn workers_from_k(h: &ByK) -> (i64, bool, Moments, bool) {
    let mut free = Moments::default();
    let mut k = 0usize;
    while k <= MAX_K && free.n < IDLE_MIN {
        free.add(h.n[k], h.sum[k], h.sq[k]);
        k += 1;
    }
    if free.n < IDLE_MIN {
        return (h.peak, false, free, false);
    }
    while k <= MAX_K {
        if h.n[k] < 30 {
            k += 1;
            continue;
        }
        let base = free.mean();
        let nk = h.n[k] as f64;
        let mk = h.sum[k] / nk;
        let vk = (-(nk * mk)).mul_add(mk, h.sq[k]) / (nk - 1.0);
        let se = (free.variance().max(0.0) / free.n + vk.max(0.0) / nk).sqrt();
        if base > 0.0 && mk - base > 3.0 * se && mk - base > (0.3 / k as f64).max(0.1) * base {
            return (k as i64, true, free, true);
        }
        free.add(h.n[k], h.sum[k], h.sq[k]);
        k += 1;
    }
    (h.peak, false, free, true)
}

/// The visits that arrived with fewer than c others busy, and whether there are enough of them.
pub fn pool_below(h: &ByK, c: i64) -> (Moments, bool) {
    let mut m = Moments::default();
    let mut k = 0i64;
    while k < c && k <= MAX_K as i64 {
        m.add(h.n[k as usize], h.sum[k as usize], h.sq[k as usize]);
        k += 1;
    }
    let ok = m.n >= IDLE_MIN;
    (m, ok)
}

#[derive(Clone, Copy)]
struct Ev {
    t: u64,
    kind: u8, // 0 end, 1 query, 2 start
    i: u32,
}

/// Walks each pod's busy segments in time order; for every visit counts the others busy at its arrival.
pub fn sweep_by_k(segs: &[Seg], vrec: &[VisitRec], n_all: usize, n_pods: usize) -> Vec<ByK> {
    let mut segs_by: Vec<Vec<Seg>> = vec![Vec::new(); n_pods];
    for s in segs {
        segs_by[s.pod as usize].push(*s);
    }
    let mut vis_by: Vec<Vec<u32>> = vec![Vec::new(); n_pods];
    for (i, v) in vrec.iter().enumerate() {
        vis_by[v.pod as usize].push(i as u32);
    }
    // every pod with visits, by service (pods ascending)
    let mut pods_of: Vec<Vec<usize>> = vec![Vec::new(); n_all];
    for (p, vs) in vis_by.iter().enumerate() {
        if let Some(&i) = vs.first() {
            pods_of[vrec[i as usize].svc as usize].push(p);
        }
    }
    pods_of
        .par_iter()
        .map(|pods| {
            let mut h = ByK::default();
            let mut evs: Vec<Ev> = Vec::new();
            for &pod in pods {
                let vs = &vis_by[pod];
                let ss = &segs_by[pod];
                evs.clear();
                evs.reserve(2 * ss.len() + vs.len());
                for s in ss {
                    let mut pull = OVERLAP_EPSILON_NS;
                    if s.end - s.start <= 2 * OVERLAP_EPSILON_NS {
                        if !s.leaf || s.end - s.start < 2 {
                            continue;
                        }
                        pull = (s.end - s.start) / 2;
                    }
                    evs.push(Ev { t: s.start, kind: 2, i: 0 });
                    evs.push(Ev { t: s.end - pull, kind: 0, i: 0 });
                }
                for &i in vs {
                    evs.push(Ev { t: vrec[i as usize].start, kind: 1, i });
                }
                gosort::sort_func(&mut evs, |a, b| a.t < b.t || (a.t == b.t && a.kind < b.kind));
                let (mut active, mut best) = (0i64, 0i64);
                for e in &evs {
                    match e.kind {
                        0 => active -= 1,
                        2 => {
                            active += 1;
                            best = best.max(active);
                        }
                        _ => {
                            let v = &vrec[e.i as usize];
                            let k = active.min(MAX_K as i64) as usize;
                            let x = v.own as f64;
                            h.n[k] += 1;
                            h.sum[k] += x;
                            h.sq[k] = x.mul_add(x, h.sq[k]);
                        }
                    }
                }
                h.peak = h.peak.max(best);
            }
            h
        })
        .collect()
}
