// SPDX-License-Identifier: Apache-2.0

//! rhobound-cli's internal/report: the prediction report (Build), its JSON form (WriteJSON: encoding/json's
//! indented layout, struct field order, `omitempty` rules and HTML escaping) and its text form (WriteText, with
//! Go's fmt verbs and text/tabwriter). Ported line by line from report.go; the arithmetic is the same single
//! operations in the same order (none of them is a fusable x*y+z), so with the same model results the report
//! is the same bytes.

use rbfast_infer::gofmt;
use rbfast_infer::json::{obj, Json};
use rbfast_infer::{Inferred, ServiceStats};
use rbfast_math::model::{Change, Delta, ModelResult, Topology, POOLED};

use crate::tabwriter::TabWriter;

/// Version of the report format.
pub const VERSION: &str = "rhobound-cli.report/v1";

/// Printed with every report.
pub const SCOPE: &str = "Mean latency only, for steady load below the utilization limit, assuming Poisson arrivals. \
No tail (p95/p99), burst, retry or timeout modelling. Worker counts marked + are lower bounds.";

/// One service of the report (Go's report.Row).
#[derive(Clone, Debug, Default, PartialEq)]
pub struct Row {
    pub name: String,
    pub external: bool,
    pub entry: bool,
    pub consumer_entry: bool,
    pub user_entry: bool,
    pub rate_rps: f64,
    pub replicas: i64,
    pub workers_per_pod: i64,
    pub workers_lower: bool,
    pub own_ms: f64,
    pub cs2: f64,
    pub glue_ms: f64,
    pub util: f64,
    pub wait_ms: f64,
    pub observed_wait: f64,
    pub model_ms: f64,
    pub observed_ms: f64,
    pub error_pct: Option<f64>,
    pub after_ms: Option<f64>,
    pub change_ms: Option<f64>,
    pub change_pct: Option<f64>,
    pub parallel: bool,
    pub stage: bool,
    pub images: Vec<String>,
    pub replica_shares: Option<Vec<f64>>,
}

/// A call sent after the caller's response (Go's report.AsyncCall).
#[derive(Clone, Debug, PartialEq)]
pub struct AsyncCall {
    pub caller: String,
    pub callee: String,
    pub per_visit: f64,
}

/// The full result (Go's report.Report).
#[derive(Clone, Debug, Default, PartialEq)]
pub struct Report {
    pub version: String,
    /// the capture (or topology) path as given: a Go string, any bytes
    pub capture: Vec<u8>,
    pub window_s: f64,
    pub requests: i64,
    pub consumer_requests: i64,
    pub async_calls: Vec<AsyncCall>,
    pub spans: i64,
    pub traces: i64,
    pub broken: i64,
    pub probes: i64,
    pub rps: f64,
    pub kept_share: f64,
    pub max_rho: f64,
    pub bottle: String,
    pub rows: Vec<Row>,
    pub changes: Vec<Change>,
    pub warnings: Vec<String>,
    pub scope: String,
    pub model: String,
    /// a report of a topology file (rhobound model): no capture, nothing seen to compare with
    pub from_topology: bool,
}

/// report.Build: assembles a report from an inference (its counts, warnings and per-service stats; the
/// topology is `topo`, the model's copy) and the solved model(s).
pub fn build(
    capture: &[u8],
    inf: &Inferred,
    topo: &Topology,
    kept: f64,
    base: &ModelResult,
    d: Option<&Delta>,
    changes: Vec<Change>,
) -> Report {
    let mut rep = Report {
        version: VERSION.to_string(),
        capture: capture.to_vec(),
        window_s: inf.window_s,
        requests: inf.requests,
        consumer_requests: inf.consumer_requests,
        spans: inf.spans as i64,
        traces: inf.traces,
        broken: inf.broken_traces,
        probes: inf.probe_spans as i64,
        rps: inf.lam_ext_per_ms * 1000.0,
        kept_share: kept,
        changes,
        warnings: inf.warnings.clone(),
        scope: SCOPE.to_string(),
        ..Default::default()
    };
    for sv in &topo.services {
        for c in &sv.calls {
            if !c.is_async {
                continue;
            }
            let callee = &topo.services[c.child].name;
            if let Some(last) = rep.async_calls.last_mut() {
                if last.caller == sv.name && last.callee == *callee {
                    last.per_visit += c.p;
                    continue;
                }
            }
            rep.async_calls.push(AsyncCall { caller: sv.name.clone(), callee: callee.clone(), per_visit: c.p });
        }
    }
    let (mr, at) = base.max_rho();
    rep.max_rho = mr;
    if let Some(at) = at {
        rep.bottle = topo.services[at].name.clone();
    }
    let r = base.r.as_deref().unwrap_or(&[]);
    let l = base.l.as_deref().unwrap_or(&[]);
    for (i, st) in inf.stats.iter().enumerate() {
        let sv = &topo.services[i];
        let mut row = Row {
            name: st.name.clone(),
            external: st.external,
            entry: st.entry,
            consumer_entry: st.consumer_entries > 0,
            user_entry: st.entry && (st.entries > st.consumer_entries || st.entries == 0),
            rate_rps: base.lam[i] * 1000.0,
            replicas: sv.servers,
            workers_per_pod: sv.workers,
            workers_lower: st.workers_inferred && !st.workers_from_queueing && !st.external,
            own_ms: sv.s,
            cs2: sv.cs2,
            glue_ms: sv.glue,
            util: base.rho[i],
            wait_ms: r[i] - sv.s,
            observed_wait: st.observed_wait_ms + st.in_span_wait_ms,
            parallel: sv.parallel,
            stage: st.stage,
            images: st.images.clone(),
            replica_shares: sv.shares.clone(),
            ..Default::default()
        };
        if sv.routing == POOLED {
            row.replicas = 1;
            row.workers_per_pod = sv.servers * sv.workers;
        }
        let mut hop = sv.hop;
        if st.entry {
            hop = 0.0;
            row.observed_ms = st.observed_server_ms;
        } else {
            row.observed_ms = st.observed_client_ms;
        }
        row.model_ms = l[i] + hop;
        if row.observed_ms > 0.0 && !st.external {
            row.error_pct = Some(100.0 * (row.model_ms - row.observed_ms) / row.observed_ms);
        }
        if let Some(d) = d {
            if d.stable {
                let after = d.patched.l.as_ref().expect("a stable change has latencies")[i] + hop;
                let ch = after - row.model_ms;
                row.after_ms = Some(after);
                row.change_ms = Some(ch);
                if row.model_ms > 0.0 {
                    row.change_pct = Some(100.0 * ch / row.model_ms);
                }
            }
        }
        rep.rows.push(row);
    }
    rep
}

fn num(x: f64) -> Result<Json, String> {
    Json::num(x)
}

fn int(i: i64) -> Json {
    Json::int(i)
}

/// Go's isEmptyValue for a float: 0 (either sign).
fn float_empty(x: f64) -> bool {
    x == 0.0
}

impl Row {
    pub fn to_json(&self) -> Result<Json, String> {
        let mut o: Vec<(&str, Json)> = vec![("name", Json::str(&self.name))];
        if self.external {
            o.push(("external", Json::Bool(true)));
        }
        if self.entry {
            o.push(("entry", Json::Bool(true)));
        }
        if self.consumer_entry {
            o.push(("entry_from_consumer", Json::Bool(true)));
        }
        o.push(("rate_rps", num(self.rate_rps)?));
        o.push(("replicas", int(self.replicas)));
        o.push(("workers_per_pod", int(self.workers_per_pod)));
        if self.workers_lower {
            o.push(("workers_are_a_lower_bound", Json::Bool(true)));
        }
        o.push(("own_ms", num(self.own_ms)?));
        o.push(("own_cs2", num(self.cs2)?));
        if !float_empty(self.glue_ms) {
            o.push(("glue_ms", num(self.glue_ms)?));
        }
        o.push(("utilization", num(self.util)?));
        o.push(("model_wait_ms", num(self.wait_ms)?));
        o.push(("observed_wait_ms", num(self.observed_wait)?));
        o.push(("model_ms", num(self.model_ms)?));
        o.push(("observed_ms", num(self.observed_ms)?));
        for (k, v) in [
            ("error_pct", self.error_pct),
            ("after_ms", self.after_ms),
            ("change_ms", self.change_ms),
            ("change_pct", self.change_pct),
        ] {
            if let Some(v) = v {
                o.push((k, num(v)?));
            }
        }
        if self.parallel {
            o.push(("parallel", Json::Bool(true)));
        }
        if self.stage {
            o.push(("stage", Json::Bool(true)));
        }
        if !self.images.is_empty() {
            o.push(("images", Json::Arr(self.images.iter().map(|s| Json::str(s)).collect())));
        }
        if let Some(sh) = &self.replica_shares {
            if !sh.is_empty() {
                let mut a = Vec::with_capacity(sh.len());
                for &x in sh {
                    a.push(num(x)?);
                }
                o.push(("replica_shares", Json::Arr(a)));
            }
        }
        Ok(obj(o))
    }
}

impl Report {
    /// The report as a JSON value, field for field as encoding/json writes Go's Report.
    pub fn to_json(&self) -> Result<Json, String> {
        let mut o: Vec<(&str, Json)> = vec![
            ("version", Json::str(&self.version)),
            // encoding/json replaces each byte that is not UTF-8 with U+FFFD
            ("capture", Json::str(&rbfast_gostr::lossy(&self.capture))),
            ("window_s", num(self.window_s)?),
            ("requests", int(self.requests)),
        ];
        if self.consumer_requests != 0 {
            o.push(("consumer_requests", int(self.consumer_requests)));
        }
        if !self.async_calls.is_empty() {
            let mut a = Vec::new();
            for c in &self.async_calls {
                a.push(obj(vec![
                    ("caller", Json::str(&c.caller)),
                    ("callee", Json::str(&c.callee)),
                    ("per_visit", num(c.per_visit)?),
                ]));
            }
            o.push(("async_calls", Json::Arr(a)));
        }
        o.push(("spans", int(self.spans)));
        o.push(("traces", int(self.traces)));
        o.push(("broken_traces", int(self.broken)));
        if self.probes != 0 {
            o.push(("probe_spans_dropped", int(self.probes)));
        }
        o.push(("external_rps", num(self.rps)?));
        o.push(("kept_share", num(self.kept_share)?));
        o.push(("max_utilization", num(self.max_rho)?));
        o.push(("busiest_service", Json::str(&self.bottle)));
        if self.rows.is_empty() {
            o.push(("services", Json::Null)); // a nil slice
        } else {
            let mut a = Vec::with_capacity(self.rows.len());
            for r in &self.rows {
                a.push(r.to_json()?);
            }
            o.push(("services", Json::Arr(a)));
        }
        if !self.changes.is_empty() {
            let mut a = Vec::new();
            for c in &self.changes {
                let mut co: Vec<(&str, Json)> =
                    vec![("service", Json::str(&c.service)), ("delta_ms", num(c.delta_ms)?)];
                if !float_empty(c.glue_ms) {
                    co.push(("glue_delta_ms", num(c.glue_ms)?));
                }
                co.push(("spec", Json::str(&c.spec)));
                a.push(obj(co));
            }
            o.push(("changes", Json::Arr(a)));
        }
        if !self.warnings.is_empty() {
            o.push(("warnings", Json::Arr(self.warnings.iter().map(|s| Json::str(s)).collect())));
        }
        o.push(("scope", Json::str(&self.scope)));
        o.push(("model", Json::str(&self.model)));
        Ok(obj(o))
    }

    /// WriteJSON's bytes: json.Encoder with a two-space indent, then a newline. Err is Go's encoder error
    /// ("json: unsupported value: NaN").
    pub fn json_text(&self) -> Result<String, String> {
        let mut s = self.to_json()?.pretty();
        s.push('\n');
        Ok(s)
    }

    /// writeHeader after its capture line (which has the path's bytes as they are; see text).
    fn header(&self, w: &mut String) {
        let complete = self.traces - self.broken;
        if self.consumer_requests > 0 && self.requests > 0 {
            let user = self.requests - self.consumer_requests;
            let rate = self.rps / self.requests as f64;
            if user > 0 {
                w.push_str(&format!(
                    "window    {} s, {} entry requests ({} /s) + {} from message consumers ({} /s), {} spans",
                    f0(self.window_s),
                    user,
                    gofmt::f(rate * user as f64, 1),
                    self.consumer_requests,
                    gofmt::f(rate * self.consumer_requests as f64, 1),
                    self.spans
                ));
            } else {
                w.push_str(&format!(
                    "window    {} s, {} entry requests, all from message consumers ({} /s), {} spans",
                    f0(self.window_s),
                    self.consumer_requests,
                    gofmt::f(self.rps, 1),
                    self.spans
                ));
            }
        } else if self.traces > 0 && self.requests != complete {
            w.push_str(&format!(
                "window    {} s, {} entry requests in {} traces ({} /s), {} spans",
                f0(self.window_s),
                self.requests,
                complete,
                gofmt::f(self.rps, 1),
                self.spans
            ));
        } else {
            w.push_str(&format!(
                "window    {} s, {} entry requests ({} /s), {} spans",
                f0(self.window_s),
                self.requests,
                gofmt::f(self.rps, 1),
                self.spans
            ));
        }
        if self.broken > 0 {
            w.push_str(&format!(", {} of {} traces broken", self.broken, self.traces));
        }
        if self.probes > 0 {
            w.push_str(&format!(", {} probe spans dropped", self.probes));
        }
        w.push('\n');
    }

    /// WriteText's bytes (the path is printed with %s: its bytes as they are).
    pub fn text(&self) -> Vec<u8> {
        let mut out: Vec<u8> = Vec::new();
        let mut w = String::new();
        if self.from_topology {
            out.extend_from_slice(b"rhobound-cli: mean latency of a topology\ntopology  ");
            out.extend_from_slice(&self.capture);
            out.push(b'\n');
            w.push_str(&format!("load      {} requests/s\n", gofmt::f(self.rps, 1)));
        } else {
            out.extend_from_slice(b"rhobound-cli: mean latency from traces\ncapture   ");
            out.extend_from_slice(&self.capture);
            out.push(b'\n');
            self.header(&mut w);
        }
        w.push_str(&format!("busiest   {} at {}% utilization\n", self.bottle, f0(100.0 * self.max_rho)));
        w.push_str(&format!("model     {}\n", self.model));
        w.push_str(&format!("scope     {}\n\n", self.scope));

        // sort.SliceStable(rows, !External(i) && External(j)): internal services first, in order
        let mut rows: Vec<&Row> = self.rows.iter().filter(|r| !r.external).collect();
        rows.extend(self.rows.iter().filter(|r| r.external));
        let has_change = !self.changes.is_empty();
        let mut has_glue = false;
        let (mut has_stage, mut has_shares, mut has_consumer) = (false, false, false);
        for x in &rows {
            has_glue = has_glue || x.glue_ms >= 0.005;
            has_stage = has_stage || x.stage;
            has_shares = has_shares || x.replica_shares.is_some();
            has_consumer = has_consumer || x.consumer_entry;
        }
        let mut tw = TabWriter::new(0, 2, true);
        let mut head = String::from("service\trps\tpods x w\town ms\tcs2\t");
        if has_glue {
            head.push_str("glue ms\t");
        }
        head.push_str("util\twait ms\tseen wait\tmodel ms\tseen ms\terr %\t");
        if has_change {
            head.push_str("after ms\tchange ms\tchange %\t");
        }
        head.push('\n');
        tw.write_str(&head);
        for x in &rows {
            let mut name = x.name.clone();
            if x.entry && x.consumer_entry && x.user_entry {
                name.push_str(" *>");
            } else if x.entry && x.consumer_entry {
                name.push_str(" >");
            } else if x.entry {
                name.push_str(" *");
            }
            if x.parallel {
                name.push_str(" ||");
            }
            let mut w2 = x.workers_per_pod.to_string();
            if x.workers_lower {
                w2.push('+');
            }
            let mut pods = x.replicas.to_string();
            if x.replica_shares.is_some() {
                pods.push('~');
            }
            let mut line =
                format!("{}\t{}\t{} x {}\t{}\t{}\t", name, fd(x.rate_rps, 1), pods, w2, fd(x.own_ms, 2), fd(x.cs2, 2));
            if has_glue {
                line.push_str(&fd(x.glue_ms, 2));
                line.push('\t');
            }
            let (mut seen_wait, mut seen) = (fd(x.observed_wait, 2), fd(x.observed_ms, 2));
            if x.stage || self.from_topology {
                seen_wait = "-".to_string();
                seen = "-".to_string();
            }
            line.push_str(&format!(
                "{}\t{}\t{}\t{}\t{}\t{}\t",
                fd(100.0 * x.util, 0) + "%",
                fd(x.wait_ms, 2),
                seen_wait,
                fd(x.model_ms, 2),
                seen,
                pf(x.error_pct, 1, true)
            ));
            if has_change {
                line.push_str(&format!(
                    "{}\t{}\t{}\t",
                    pf(x.after_ms, 2, false),
                    pf(x.change_ms, 2, true),
                    pf(x.change_pct, 1, true)
                ));
            }
            line.push('\n');
            tw.write_str(&line);
        }
        out.extend_from_slice(w.as_bytes());
        w.clear();
        out.extend_from_slice(&tw.finish());
        w.push_str("\n* entry service   || parallel fan-out   w+ = workers per pod, a lower bound (too few requests waited, or too briefly, to read it from)\n");
        if self.from_topology {
            w.push_str("own ms: service time per visit (up to its first call out). seen wait, seen ms: a topology has no traces to compare with.\n");
        } else {
            w.push_str("own ms: service time per visit (up to its first call out), without the wait for a worker inside the span. seen wait: queueing the traces show (in-span plus between client and server span).\n");
        }
        if has_glue {
            w.push_str("glue ms: time per visit after its first call that is not in a call (the worker is free by then); a pure delay.\n");
        }
        if !self.from_topology {
            w.push_str("seen ms: the mean the callers' client spans measured (entries: the server span).\n");
        }
        if has_stage {
            w.push_str("stage:S:n: the calls S makes at once in stage n of its calls (each stage starts once the last has answered); a zero-time delay.\n");
        }
        if has_shares {
            w.push_str("pods~: the pods take uneven shares of the visits (from the traces, see the warnings), each a queue fed its share; the shares are kept at any load and after the change; util is the busiest pod's.\n");
        }
        if has_consumer {
            w.push_str("> entry from a message consumer: the visits a CONSUMER span's calls make, counted apart from the entry requests in the header.\n");
        }
        if !self.async_calls.is_empty() {
            w.push_str("async calls (sent after the response): they load the callee, but are not on the caller's latency path, so the callee's latency and its change do not reach the caller:");
            for (i, a) in self.async_calls.iter().enumerate() {
                let sep = if i == 0 { "" } else { "," };
                w.push_str(&format!("{} {} -> {} ({} per visit)", sep, a.caller, a.callee, gofmt::g(a.per_visit, 3)));
            }
            w.push('\n');
        }
        if has_change {
            w.push_str("\nchange applied:");
            for c in &self.changes {
                if c.glue_ms != 0.0 {
                    w.push_str(&format!(
                        " {} {} ms ({}: {} ms service time, {} ms glue);",
                        c.service,
                        signed_ms(c.delta_ms),
                        c.spec,
                        signed_ms(c.delta_ms - c.glue_ms),
                        signed_ms(c.glue_ms)
                    ));
                    continue;
                }
                w.push_str(&format!(" {} {} ms ({});", c.service, signed_ms(c.delta_ms), c.spec));
            }
            w.push('\n');
        }
        if !self.warnings.is_empty() {
            w.push_str("\nwarnings:\n");
            for s in &self.warnings {
                w.push_str(&format!("  - {}\n", go_trim_space(s)));
            }
        }
        out.extend_from_slice(w.as_bytes());
        out
    }
}

/// `%.0f`.
fn f0(x: f64) -> String {
    gofmt::f(x, 0)
}

/// report.f: `%.*f`, or "-" for NaN and the infinities.
fn fd(v: f64, d: usize) -> String {
    if v.is_nan() || v.is_infinite() {
        return "-".to_string();
    }
    gofmt::f(v, d)
}

/// `%+.*f` (Go prints +NaN and +Inf with the plus flag).
fn f_plus(v: f64, d: usize) -> String {
    if v.is_nan() {
        return "+NaN".to_string();
    }
    if v == f64::INFINITY {
        return "+Inf".to_string();
    }
    if v == f64::NEG_INFINITY {
        return "-Inf".to_string();
    }
    format!("{:+.*}", d, v)
}

/// `%+.3g`.
fn g_plus(v: f64, prec: usize) -> String {
    let s = gofmt::g(v, prec);
    if s.starts_with('-') || s.starts_with('+') {
        s
    } else {
        format!("+{s}")
    }
}

/// report.pf.
fn pf(p: Option<f64>, d: usize, sign: bool) -> String {
    match p {
        None => "-".to_string(),
        Some(v) if sign => f_plus(v, d),
        Some(v) => fd(v, d),
    }
}

/// report.signedMs: a change in ms with a sign and up to 3 decimals, never in exponent form.
fn signed_ms(v: f64) -> String {
    if v != 0.0 && v.abs() < 0.001 {
        return g_plus(v, 3);
    }
    let s = f_plus(v, 3);
    let s = s.trim_end_matches('0').trim_end_matches('.');
    if s == "-0" || s == "+0" {
        return "+0".to_string();
    }
    s.to_string()
}

/// strings.TrimSpace: Unicode white space at both ends.
fn go_trim_space(s: &str) -> &str {
    s.trim_matches(|c: char| c.is_whitespace())
}

/// The per-service stats `rhobound model` makes up for a topology file: a name, and the entry mark for the
/// services in its entry map (cmd/rhobound's cmdModel).
pub fn topology_stats(topo: &Topology) -> Vec<ServiceStats> {
    let mut stats: Vec<ServiceStats> =
        topo.services.iter().map(|s| ServiceStats { name: s.name.clone(), ..Default::default() }).collect();
    for &i in topo.entry.keys() {
        stats[i].entry = true;
    }
    stats
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn signed() {
        assert_eq!(signed_ms(0.821), "+0.821");
        assert_eq!(signed_ms(1.0), "+1");
        assert_eq!(signed_ms(-2.5), "-2.5");
        assert_eq!(signed_ms(0.0), "+0");
        assert_eq!(signed_ms(-0.0), "+0");
        assert_eq!(signed_ms(0.0004), "+0.0004");
        assert_eq!(signed_ms(-0.00012345), "-0.000123");
        assert_eq!(signed_ms(1234.5), "+1234.5");
        assert_eq!(signed_ms(-0.0004999), "-0.0005");
    }

    #[test]
    fn plus() {
        assert_eq!(f_plus(1.25, 1), "+1.2");
        assert_eq!(f_plus(-0.04, 1), "-0.0");
        assert_eq!(f_plus(f64::NAN, 1), "+NaN");
        assert_eq!(pf(None, 1, true), "-");
        assert_eq!(fd(f64::INFINITY, 2), "-");
    }
}
