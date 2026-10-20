// SPDX-License-Identifier: Apache-2.0

//! The model's call graph as the inference builds it: rhobound-cli's model.Topology (Service, Call), its
//! validation (Finish) and its JSON form (MarshalTopology, the stdout of `rhobound infer`).
//!
//! The model crate will hold its own copy for the evaluation; this one is what the inference fills, field for
//! field as in Go, so a conversion is a copy.

use std::collections::{BTreeMap, HashSet};

use crate::gofmt;
use crate::json::{obj, Json};

pub const POOLED: &str = "pooled";
pub const RANDOM: &str = "random";

/// One call from a service to a child (model.Call).
#[derive(Clone, Debug, PartialEq)]
pub struct Call {
    /// index into Topology::services
    pub child: usize,
    /// probability the call is made on a visit, in (0, 1]
    pub p: f64,
    /// a call the service does not wait for (it loads the child, it is not on the latency path)
    pub is_async: bool,
}

/// One node of the call graph (model.Service). Times in ms.
#[derive(Clone, Debug, PartialEq, Default)]
pub struct Service {
    pub name: String,
    pub s: f64,
    pub calls: Vec<Call>,
    pub parallel: bool,
    pub servers: i64,
    pub workers: i64,
    pub cs2: f64,
    pub routing: String,
    pub delay: bool,
    pub hop: f64,
    pub branch_corr: f64,
    pub glue: f64,
    pub glue_cs2: f64,
    /// each replica's share of the visits (None: an even split)
    pub shares: Option<Vec<f64>>,
}

impl Service {
    /// The calls the service waits for.
    pub fn sync_calls(&self) -> Vec<&Call> {
        self.calls.iter().filter(|c| !c.is_async).collect()
    }
}

/// A DAG of services and where external traffic enters (model.Topology).
#[derive(Clone, Debug, PartialEq, Default)]
pub struct Topology {
    pub name: String,
    pub services: Vec<Service>,
    /// entry weights by service index
    pub entry: BTreeMap<usize, f64>,
    /// a topological order (callers before callees), set by finish
    pub order: Vec<usize>,
}

impl Topology {
    /// Validates the topology and computes its order (Go's Finish, with its messages).
    pub fn finish(&mut self) -> Result<(), String> {
        let mut seen: HashSet<String> = HashSet::new();
        let n = self.services.len();
        for i in 0..n {
            let s = &mut self.services[i];
            if !seen.insert(s.name.clone()) {
                return Err(format!("duplicate service name {}", gofmt::quote(&s.name)));
            }
            if s.servers < 0 || s.workers < 0 {
                return Err(format!("{}: servers and workers must not be negative", s.name));
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
                return Err(format!(
                    "{}: routing {} is not supported (pooled and random are)",
                    s.name,
                    gofmt::quote(&s.routing)
                ));
            }
            if s.workers > 1 && s.routing == POOLED {
                return Err(format!(
                    "{}: workers per replica needs random routing; a pooled service is one shared queue of `servers` workers",
                    s.name
                ));
            }
            if !(s.s >= 0.0) || s.s == f64::INFINITY {
                return Err(format!(
                    "{}: service time must be a finite non-negative number, got {}",
                    s.name,
                    gofmt::v(s.s)
                ));
            }
            if !(s.cs2 >= 0.0) || s.cs2.is_infinite() {
                return Err(format!("{}: cs2 must be a finite non-negative number, got {}", s.name, gofmt::v(s.cs2)));
            }
            if !(s.hop >= 0.0) || s.hop.is_infinite() {
                return Err(format!(
                    "{}: hop must be a finite non-negative number of ms, got {}",
                    s.name,
                    gofmt::v(s.hop)
                ));
            }
            if !(s.glue >= 0.0) || s.glue.is_infinite() || !(s.glue_cs2 >= 0.0) || s.glue_cs2.is_infinite() {
                return Err(format!(
                    "{}: glue and glue_cs2 must be finite non-negative numbers, got {} and {}",
                    s.name,
                    gofmt::v(s.glue),
                    gofmt::v(s.glue_cs2)
                ));
            }
            if s.shares.is_some() {
                if let Err(e) = check_shares(s) {
                    return Err(format!("{}: {}", s.name, e));
                }
            }
            if !(s.branch_corr >= -1.0 && s.branch_corr <= 1.0) {
                return Err(format!(
                    "{}: branch_corr must be in [-1, 1] (values <= 0 are treated as independent), got {}",
                    s.name,
                    gofmt::v(s.branch_corr)
                ));
            }
            for c in &s.calls {
                if c.child >= n {
                    return Err(format!("{}: call to an unknown service", s.name));
                }
                if !(c.p > 0.0 && c.p <= 1.0) {
                    return Err(format!("{}: call probability must be in (0, 1], got {}", s.name, gofmt::v(c.p)));
                }
            }
            let sc = s.sync_calls();
            if s.parallel && sc.len() > 1 && sc.iter().any(|c| c.p < 1.0) {
                return Err(format!("{}: a parallel fan-out with call probabilities is not modelled", s.name));
            }
        }
        if self.entry.is_empty() {
            return Err("the topology has no entry service".to_string());
        }
        let mut wsum = 0.0;
        for (&i, &w) in &self.entry {
            if i >= n {
                return Err(format!("entry index {} is not a service", i));
            }
            if !(w >= 0.0) || w.is_infinite() {
                return Err(format!(
                    "{}: entry weight must be a finite non-negative number, got {}",
                    self.services[i].name,
                    gofmt::v(w)
                ));
            }
            wsum += w;
        }
        if !(wsum > 0.0) {
            return Err("the entry weights sum to zero".to_string());
        }
        // Kahn's algorithm, children in call order
        let mut kids: Vec<Vec<usize>> = vec![Vec::new(); n];
        for (i, s) in self.services.iter().enumerate() {
            let mut seen = HashSet::new();
            for c in &s.calls {
                if seen.insert(c.child) {
                    kids[i].push(c.child);
                }
            }
        }
        let mut indeg = vec![0usize; n];
        for k in &kids {
            for &c in k {
                indeg[c] += 1;
            }
        }
        let mut queue: std::collections::VecDeque<usize> = (0..n).filter(|&i| indeg[i] == 0).collect();
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
            return Err("the call graph has a cycle; the model needs a DAG".to_string());
        }
        self.order = order;
        Ok(())
    }

    /// The topology in the JSON form `rhobound infer` prints (Go's MarshalTopology: json.MarshalIndent with two
    /// spaces). Err for a NaN or infinite number, which Go's encoder refuses.
    pub fn marshal(&self) -> Result<String, String> {
        Ok(self.to_json()?.pretty())
    }

    /// The topology as a JSON value (field order and omissions as Go's MarshalTopology).
    pub fn to_json(&self) -> Result<Json, String> {
        let mut svcs = Vec::with_capacity(self.services.len());
        for s in &self.services {
            let mut o: Vec<(&str, Json)> = vec![("name", Json::str(&s.name)), ("s", Json::num(s.s)?)];
            if !s.calls.is_empty() {
                let mut ch = Vec::new();
                for c in &s.calls {
                    let name = &self.services[c.child].name;
                    if c.p == 1.0 && !c.is_async {
                        ch.push(Json::str(name));
                    } else {
                        let mut co = vec![("name", Json::str(name)), ("p", Json::num(c.p)?)];
                        if c.is_async {
                            co.push(("async", Json::Bool(true)));
                        }
                        ch.push(obj(co));
                    }
                }
                o.push(("children", Json::Arr(ch)));
            }
            if s.parallel {
                o.push(("parallel", Json::Bool(true)));
            }
            if s.servers != 0 {
                o.push(("servers", Json::int(s.servers)));
            }
            let workers = if s.workers == 1 { 0 } else { s.workers };
            if workers != 0 {
                o.push(("workers", Json::int(workers)));
            }
            o.push(("cs2", Json::num(s.cs2)?));
            if !s.routing.is_empty() {
                o.push(("routing", Json::str(&s.routing)));
            }
            if s.delay {
                o.push(("delay", Json::Bool(true)));
            }
            if s.hop != 0.0 {
                o.push(("hop", Json::num(s.hop)?));
            }
            if s.branch_corr != 0.0 {
                o.push(("branch_corr", Json::num(s.branch_corr)?));
            }
            if s.glue != 0.0 {
                o.push(("glue", Json::num(s.glue)?));
            }
            if s.glue_cs2 != 0.0 {
                o.push(("glue_cs2", Json::num(s.glue_cs2)?));
            }
            if let Some(sh) = &s.shares {
                if !sh.is_empty() {
                    let mut a = Vec::new();
                    for &x in sh {
                        a.push(Json::num(x)?);
                    }
                    o.push(("shares", Json::Arr(a)));
                }
            }
            svcs.push(obj(o));
        }
        // Go writes a map[string]float64: keys sorted
        let mut entry: BTreeMap<&str, f64> = BTreeMap::new();
        for (&i, &w) in &self.entry {
            entry.insert(&self.services[i].name, w);
        }
        let mut eo = Vec::new();
        for (k, w) in entry {
            eo.push((k, Json::num(w)?));
        }
        Ok(obj(vec![("name", Json::str(&self.name)), ("services", Json::Arr(svcs)), ("entry", obj(eo))]))
    }
}

fn check_shares(s: &Service) -> Result<(), String> {
    let sh = s.shares.as_ref().expect("shares");
    if s.delay {
        return Err("a delay has no replicas to share its traffic".to_string());
    }
    if s.routing != RANDOM {
        return Err(format!(
            "replica shares need random routing (each replica its own queue), not {}",
            gofmt::quote(&s.routing)
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
            return Err(format!("a replica share must be a positive number, got {}", gofmt::v(p)));
        }
        sum += p;
    }
    if (sum - 1.0).abs() > 1e-6 {
        return Err(format!("the replica shares sum to {}, not 1", gofmt::v(sum)));
    }
    Ok(())
}
