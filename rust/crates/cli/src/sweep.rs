// SPDX-License-Identifier: Apache-2.0

//! `rbfast sweep`: many what-ifs on one topology, in parallel, one JSON line each. Not in rhobound: each line is
//! what `rhobound model TOPOLOGY --rps R [--patch SPEC] --json` (or, with --capture, `rhobound predict` at the
//! observed load) computes for that load and change, the same bits, built by the same report code; parity.sh
//! checks a sample of lines against the Go binary.
//!
//! Loads: `--rps A:B:STEP` (A, A+STEP, ... up to B; each value A + k*STEP), a comma list, or both mixed. Changes:
//! `--patch-grid ALT[;ALT...]`, each ALT a list `svc=VALUES[,svc=VALUES...]` evaluated at every combination of
//! its services' values; VALUES is `V[|V...]`, V a `--patch` value (+3ms, -10%) or a range FROM:TO:STEP with a
//! unit (`0:10:2%`, `0:5:0.5ms`; no unit is ms, as in --patch). Each change is turned into a --patch spec (the
//! `patch` field of its lines, shortest round-trip numbers) and read by the --patch parser. The base (no change)
//! is evaluated at every load too.
//!
//! The grid runs on rayon (rbfast_math::batch::sweep): the base of each (load, model) is solved once and shared
//! by its changes, and matched-maximum results are memoised by their input bits (MaxMemo); both give the same
//! bits as solving each line on its own. Lines come out in grid order: load, then model, then change.

use rbfast_infer::gofmt;
use rbfast_infer::json::{obj, Json};
use rbfast_infer::Inferred;
use rbfast_math::batch::{sweep, Grid, Outcome};
use rbfast_math::mathx::MaxMemo;
use rbfast_math::model::{parse_go_float, parse_patch, Change, Config, Exec, ModelResult, Patch, Topology};
use std::io::Write;
use std::time::Instant;

use crate::flags::Value;
use crate::{
    limit_error, load_topology, model_config, new_flags, report, times_on, to_model_topology, topology_inferred,
    with_pool, Fail, Out, PROG,
};

/// The most changes (`--patch-grid` combinations) one sweep takes: each is parsed and held, with its patch, for
/// the whole run.
pub const MAX_CHANGES: usize = 100_000;
/// The most loads (`--rps` values) one sweep takes.
pub const MAX_LOADS: usize = 1_000_000;

/// A list of numbers: comma-separated items, each a number or a range FROM:TO:STEP (inclusive of TO, within
/// a 1e-9 step). `unit` is stripped from each number when present.
pub fn parse_values(spec: &str, what: &str) -> Result<Vec<f64>, String> {
    let mut out = Vec::new();
    for item in spec.split(',').map(str::trim).filter(|s| !s.is_empty()) {
        out.extend(parse_item(item, what)?);
        if out.len() > MAX_LOADS {
            return Err(format!("{what}: more than {MAX_LOADS} values"));
        }
    }
    if out.is_empty() {
        return Err(format!("{what}: no values in {}", gofmt::quote(spec)));
    }
    Ok(out)
}

fn parse_item(item: &str, what: &str) -> Result<Vec<f64>, String> {
    let bad = || format!("{what}: cannot read {} (use N or FROM:TO:STEP)", gofmt::quote(item));
    let parts: Vec<&str> = item.split(':').map(str::trim).collect();
    let nums: Option<Vec<f64>> = parts.iter().map(|p| parse_go_float(p)).collect();
    let nums = nums.ok_or_else(bad)?;
    if nums.iter().any(|x| !x.is_finite()) {
        return Err(bad());
    }
    match nums.as_slice() {
        [x] => Ok(vec![*x]),
        [from, to, step] => match range(*from, *to, *step) {
            Some(Ok(v)) => Ok(v),
            Some(Err(())) => Err(format!("{what}: {} has more than {MAX_LOADS} values", gofmt::quote(item))),
            None => {
                Err(format!("{what}: {} is not a range FROM:TO:STEP with STEP > 0 and TO >= FROM", gofmt::quote(item)))
            }
        },
        _ => Err(bad()),
    }
}

/// FROM, FROM+STEP, ... while not past TO (by more than 1e-9 of a step); each value FROM + k*STEP. None for a
/// bad range, Some(Err) for one of more than MAX_LOADS values (not built).
fn range(from: f64, to: f64, step: f64) -> Option<Result<Vec<f64>, ()>> {
    if !(step > 0.0) || !(to >= from) {
        return None;
    }
    let n = ((to - from) / step + 1e-9).floor();
    if !(n < MAX_LOADS as f64) {
        return Some(Err(()));
    }
    Some(Ok((0..=n as u64).map(|k| from + k as f64 * step).collect()))
}

/// A patch value as --patch reads it: the sign, the shortest digits that read back as `v`, the unit.
fn value_text(v: f64, unit: &str) -> String {
    let s = format!("{v}");
    if v.is_sign_negative() && v != 0.0 {
        format!("{s}{unit}")
    } else {
        format!("+{}{unit}", s.trim_start_matches('-'))
    }
}

/// One service's values in a grid alternative: `V[|V...]`, V a --patch value or FROM:TO:STEP with a unit.
fn service_values(vals: &str, item: &str) -> Result<Vec<String>, String> {
    let mut out = Vec::new();
    for v in vals.split('|').map(str::trim) {
        if !v.contains(':') {
            // a --patch value as given (the --patch parser reads and checks it)
            out.push(v.to_string());
            continue;
        }
        let mut unit: Option<&str> = None;
        let mut nums = Vec::new();
        for p in v.split(':').map(str::trim) {
            let (num, u) = if let Some(n) = p.strip_suffix('%') {
                (n, Some("%"))
            } else if let Some(n) = p.strip_suffix("ms") {
                (n, Some("ms"))
            } else {
                (p, None)
            };
            if let Some(u) = u {
                if unit.is_some_and(|x| x != u) {
                    return Err(format!("--patch-grid: mixed units in {}", gofmt::quote(item)));
                }
                unit = Some(u);
            }
            nums.push(num.to_string());
        }
        let unit = unit.unwrap_or("ms");
        let spec = nums.join(":");
        let xs = parse_item(&spec, "--patch-grid")?;
        if xs.len() > 1 || nums.len() == 3 {
            out.extend(xs.into_iter().map(|x| value_text(x, unit)));
        } else {
            return Err(format!("--patch-grid: cannot read {}", gofmt::quote(item)));
        }
    }
    Ok(out)
}

/// The --patch specs of a grid, in order: alternatives in turn, each the combinations of its services' values
/// (the first service varying slowest).
pub fn grid_specs(grid: &str) -> Result<Vec<String>, String> {
    let mut specs = Vec::new();
    for alt in grid.split(';').map(str::trim).filter(|s| !s.is_empty()) {
        let mut axes: Vec<(String, Vec<String>)> = Vec::new();
        for item in alt.split(',').map(str::trim).filter(|s| !s.is_empty()) {
            let (svc, vals) = item
                .split_once('=')
                .ok_or_else(|| format!("--patch-grid: {} is not svc=VALUES", gofmt::quote(item)))?;
            axes.push((svc.trim().to_string(), service_values(vals.trim(), item)?));
        }
        // the number of combinations, checked before any is built
        let total = axes
            .iter()
            .try_fold(1usize, |acc, a| acc.checked_mul(a.1.len()).filter(|&t| t <= MAX_CHANGES))
            .filter(|&t| specs.len() + t <= MAX_CHANGES)
            .ok_or_else(|| format!("--patch-grid: more than {MAX_CHANGES} changes"))?;
        for k in 0..total {
            let mut rem = k;
            let mut parts = vec![String::new(); axes.len()];
            for (j, (svc, vals)) in axes.iter().enumerate().rev() {
                parts[j] = format!("{svc}={}", vals[rem % vals.len()]);
                rem /= vals.len();
            }
            specs.push(parts.join(","));
        }
    }
    Ok(specs)
}

/// One line's patch: a parsed --patch spec, or the parser's error.
struct Spec {
    text: String,
    parsed: Result<(Patch, Vec<Change>), String>,
}

pub fn cmd_sweep(args: &[Vec<u8>], out: &mut Out) -> Result<(), Fail> {
    let mut fs = new_flags();
    fs.define("rps", Value::Str(Vec::new()));
    fs.define("patch-grid", Value::Str(Vec::new()));
    fs.define("both", Value::Bool(false));
    fs.define("capture", Value::Bool(false));
    let usage = "usage: rbfast sweep TOPOLOGY.json --rps A:B:STEP [--patch-grid GRID] [--plain | --both] [--max-rho R]\n       rbfast sweep CAPTURE --capture [--rps ...] [--patch-grid GRID] [--workers svc=N] [--kept-share F]";
    let pos = match fs.parse_interleaved(args) {
        Ok(p) if p.len() == 1 => p,
        _ => return Err(usage.into()),
    };
    let max_rho = fs.float("max-rho");
    if !(max_rho > 0.0 && max_rho <= 0.95) {
        return Err("--max-rho must be in (0, 0.95]".into());
    }
    if fs.bool("plain") && fs.bool("both") {
        return Err("--plain and --both exclude each other".into());
    }
    let from_capture = fs.bool("capture");
    if !from_capture && (fs.was_set("workers") || fs.was_set("kept-share")) {
        return Err("--workers and --kept-share apply to a capture (sweep CAPTURE --capture)".into());
    }
    if !fs.bytes("out").is_empty() || !fs.bytes("patch").is_empty() {
        return Err("sweep takes --patch-grid, not --patch or --out".into());
    }
    // rbfast's own flags: text (a value that is not UTF-8 cannot be a number list or a grid)
    let text_flag = |name: &str| -> Result<String, Fail> {
        let b = fs.bytes(name);
        std::str::from_utf8(b)
            .map(str::to_string)
            .map_err(|_| Fail::from(format!("--{name}: cannot read {}", rbfast_gostr::quote_bytes(b))))
    };
    let rps_spec = text_flag("rps")?;
    let grid_spec = text_flag("patch-grid")?;
    let threads = fs.count("threads");
    // the topology and the stats the report rows are built from
    let (topo, inf, observed_rps): (Topology, Inferred, f64) = if from_capture {
        let l = crate::load(&pos[0], &fs)?.inf;
        let topo = to_model_topology(&l.topology)?;
        let rps = l.lam_ext_per_ms * 1000.0;
        (topo, l, rps)
    } else {
        let topo = load_topology(&pos[0])?;
        let inf = topology_inferred(&topo, 0.0);
        (topo, inf, f64::NAN)
    };
    // the observed load: refusals are worded as `rhobound predict` words them ("at the observed load")
    let observed = rps_spec.is_empty();
    let rps: Vec<f64> = if observed {
        if !from_capture {
            return Err(usage.into());
        }
        vec![observed_rps]
    } else {
        parse_values(&rps_spec, "--rps")?
    };
    if let Some(bad) = rps.iter().find(|r| !(**r > 0.0) || **r == f64::INFINITY) {
        return Err(format!("--rps: {} is not a positive rate", gofmt::v(*bad)).into());
    }
    let configs: Vec<(Config, &str)> = if fs.bool("both") {
        vec![(model_config(false), "refined"), (model_config(true), "basic")]
    } else if fs.bool("plain") {
        vec![(model_config(true), "basic")]
    } else {
        vec![(model_config(false), "refined")]
    };
    let mut specs: Vec<Spec> = Vec::new();
    for text in grid_specs(&grid_spec)? {
        let parsed = parse_patch(&text, &topo);
        specs.push(Spec { text, parsed });
    }
    // the grid's patches: the base, then every spec that parsed (a spec that did not gets an error line)
    let mut patches: Vec<Option<Patch>> = vec![None];
    let mut slot: Vec<Option<usize>> = Vec::new();
    for s in &specs {
        match &s.parsed {
            Ok((p, _)) => {
                slot.push(Some(patches.len()));
                patches.push(Some(p.clone()));
            }
            Err(_) => slot.push(None),
        }
    }
    let memo = MaxMemo::new();
    // one scenario per task: the pool is busy with scenarios, so the quadrature stays serial
    let exec = Exec { memo: Some(&memo), parallel_quadrature_min_branches: 0 };
    let t0 = Instant::now();
    let mut lines = 0usize;
    let mut so = std::io::stdout().lock();
    // a block of loads at a time, so that the output streams and the memory stays bounded
    let per_load = configs.len() * patches.len();
    let block = (65536 / per_load.max(1)).max(1);
    for chunk in rps.chunks(block) {
        let grid = Grid {
            topology: &topo,
            lams: chunk.iter().map(|r| r / 1000.0).collect(),
            configs: configs.iter().map(|c| c.0).collect(),
            patches: patches.clone(),
        };
        let res = with_pool(threads, || sweep(&grid, exec, true))?;
        let mut text = String::new();
        for (li, &r) in chunk.iter().enumerate() {
            let when = refusal_when(from_capture, observed, r);
            for (ci, (_, cname)) in configs.iter().enumerate() {
                let at = |pi: usize| &res[(li * configs.len() + ci) * patches.len() + pi];
                text.push_str(&line(&inf, &topo, r, cname, None, at(0), &[], max_rho, &when)?);
                text.push('\n');
                for (si, s) in specs.iter().enumerate() {
                    let l = match (&s.parsed, slot[si]) {
                        (Ok((_, ch)), Some(pi)) => {
                            line(&inf, &topo, r, cname, Some(&s.text), at(pi), ch, max_rho, &when)?
                        }
                        // cmd/rhobound reads --patch after the base passed: a base that fails or is refused
                        // is what every change at this load reports
                        (Err(e), _) => match base_gate(&inf, &topo, r, cname, Some(&s.text), at(0), max_rho, &when) {
                            Some(l) => l,
                            None => error_line(r, cname, Some(&s.text), e),
                        },
                        _ => unreachable!(),
                    };
                    text.push_str(&l);
                    text.push('\n');
                }
                lines += 1 + specs.len();
            }
        }
        so.write_all(text.as_bytes()).map_err(|e| format!("write /dev/stdout: {}", crate::os_text(&e)))?;
    }
    so.flush().map_err(|e| format!("write /dev/stdout: {}", crate::os_text(&e)))?;
    let _ = out;
    if times_on() {
        let (h, m) = memo.stats();
        crate::eprint_line(&format!(
            "{PROG}: times: sweep {lines} lines in {:.4} s (matched-maximum memo: {h} hits, {m} misses)",
            t0.elapsed().as_secs_f64()
        ));
    }
    Ok(())
}

fn head(rps: f64, model: &str, patch: Option<&str>) -> Vec<(&'static str, Json)> {
    vec![
        ("rps", Json::num(rps).unwrap_or(Json::Null)),
        ("model", Json::str(model)),
        ("patch", patch.map_or(Json::Null, Json::str)),
    ]
}

fn error_line(rps: f64, model: &str, patch: Option<&str>, msg: &str) -> String {
    let mut o = head(rps, model, patch);
    o.push(("status", Json::str("error")));
    o.push(("message", Json::str(msg)));
    obj(o).compact()
}

fn refused_line(rps: f64, model: &str, patch: Option<&str>, msg: &str) -> String {
    let mut o = head(rps, model, patch);
    o.push(("status", Json::str("refused")));
    o.push(("message", Json::str(msg)));
    obj(o).compact()
}

/// How a refusal of the base begins: `rhobound model`'s words, or `rhobound predict`'s at the observed load of a
/// capture. (At another load of a capture rbfast says "refusing to predict: at R requests/s"; predict has no
/// such case.)
fn refusal_when(from_capture: bool, observed: bool, rps: f64) -> String {
    if from_capture && observed {
        "refusing to predict: at the observed load".to_string()
    } else if from_capture {
        format!("refusing to predict: at {} requests/s", gofmt::v(rps))
    } else {
        format!("refusing to evaluate: at {} requests/s", gofmt::v(rps))
    }
}

/// The line of a base that failed or is refused at this load, if it did or is.
#[allow(clippy::too_many_arguments)]
fn base_gate(
    inf: &Inferred,
    topo: &Topology,
    rps: f64,
    model: &str,
    patch: Option<&str>,
    base: &Outcome,
    max_rho: f64,
    when: &str,
) -> Option<String> {
    let b: &ModelResult = match base {
        Outcome::Base(Err(e)) | Outcome::Change(Err(e)) => return Some(error_line(rps, model, patch, &e.0)),
        Outcome::Base(Ok(b)) => b,
        Outcome::Change(Ok(d)) => &d.base,
    };
    let (mr, _) = b.max_rho();
    if !b.stable || !(mr <= max_rho) {
        return Some(refused_line(rps, model, patch, &limit_error(when, &inf.stats, topo, b, max_rho)));
    }
    None
}

/// One line: the base at this load, or the change; refusals as cmd/rhobound words them.
#[allow(clippy::too_many_arguments)]
fn line(
    inf: &Inferred,
    topo: &Topology,
    rps: f64,
    model: &str,
    patch: Option<&str>,
    o: &Outcome,
    changes: &[Change],
    max_rho: f64,
    when: &str,
) -> Result<String, String> {
    let (base, delta) = match o {
        Outcome::Base(Err(e)) => return Ok(error_line(rps, model, patch, &e.0)),
        Outcome::Change(Err(e)) => return Ok(error_line(rps, model, patch, &e.0)),
        Outcome::Base(Ok(b)) => (b, None),
        Outcome::Change(Ok(d)) => (&d.base, Some(d)),
    };
    if let Some(l) = base_gate(inf, topo, rps, model, patch, o, max_rho, when) {
        return Ok(l);
    }
    if let Some(d) = delta {
        let (mr, _) = d.patched.max_rho();
        if !d.stable || !(mr <= max_rho) {
            let msg = limit_error("refusing the change: after it", &inf.stats, topo, &d.patched, max_rho);
            return Ok(refused_line(rps, model, patch, &msg));
        }
    }
    let mut at = inf.clone_counts();
    at.lam_ext_per_ms = rps / 1000.0;
    let rep = report::build(b"", &at, topo, 1.0, base, delta, changes.to_vec());
    let mut o = head(rps, model, patch);
    o.push(("status", Json::str("ok")));
    o.push(("max_utilization", Json::num(rep.max_rho)?));
    o.push(("busiest_service", Json::str(&rep.bottle)));
    if let Some(d) = delta {
        let (amr, aat) = d.patched.max_rho();
        o.push(("after_max_utilization", Json::num(amr)?));
        o.push(("after_busiest_service", Json::str(aat.map_or("", |i| topo.services[i].name.as_str()))));
    }
    let mut rows = Vec::with_capacity(rep.rows.len());
    for (i, r) in rep.rows.iter().enumerate() {
        let mut ro: Vec<(&str, Json)> = vec![("name", Json::str(&r.name))];
        if r.entry {
            ro.push(("entry", Json::Bool(true)));
        }
        ro.push(("utilization", Json::num(r.util)?));
        ro.push(("model_ms", Json::num(r.model_ms)?));
        if let Some(d) = delta {
            ro.push(("after_utilization", Json::num(d.patched.rho[i])?));
        }
        for (k, v) in [("after_ms", r.after_ms), ("change_ms", r.change_ms), ("change_pct", r.change_pct)] {
            if let Some(v) = v {
                ro.push((k, Json::num(v)?));
            }
        }
        rows.push(obj(ro));
    }
    o.push(("services", Json::Arr(rows)));
    Ok(obj(o).compact())
}

/// The fields of an Inferred the report rows need (no warnings, which belong to the capture, not the line).
trait CloneCounts {
    fn clone_counts(&self) -> Inferred;
}

impl CloneCounts for Inferred {
    fn clone_counts(&self) -> Inferred {
        Inferred { stats: self.stats.clone(), ..Default::default() }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn values() {
        assert_eq!(parse_values("50:60:5", "--rps").unwrap(), vec![50.0, 55.0, 60.0]);
        assert_eq!(parse_values("10,20:30:10", "--rps").unwrap(), vec![10.0, 20.0, 30.0]);
        assert_eq!(parse_values("0.1:0.3:0.1", "--rps").unwrap().len(), 3);
        assert!(parse_values("1:0:1", "--rps").is_err());
        assert!(parse_values("1:2:0", "--rps").is_err());
        assert!(parse_values("x", "--rps").is_err());
        assert!(parse_values("0.000001:100:0.000001", "--rps").is_err());
        assert!(parse_values("1:1000000:1", "--rps").is_ok());
        assert!(parse_values("1:1000000:1,5", "--rps").is_err());
    }

    #[test]
    fn grid() {
        assert_eq!(grid_specs("b=0:10:5%").unwrap(), vec!["b=+0%", "b=+5%", "b=+10%"]);
        assert_eq!(
            grid_specs("a=+1ms|-2%,b=0:1:1ms;c=+3ms").unwrap(),
            vec!["a=+1ms,b=+0ms", "a=+1ms,b=+1ms", "a=-2%,b=+0ms", "a=-2%,b=+1ms", "c=+3ms"]
        );
        assert_eq!(grid_specs("b=-1:0:0.5").unwrap(), vec!["b=-1ms", "b=-0.5ms", "b=+0ms"]);
        assert_eq!(grid_specs("b=0.1:0.3:0.1%").unwrap()[2], "b=+0.30000000000000004%");
        assert!(grid_specs("b=0%:1ms:1").is_err());
        assert!(grid_specs("b").is_err());
        assert!(grid_specs("").unwrap().is_empty());
        // no grid beyond MAX_CHANGES is built, and the count cannot wrap
        let huge = "a=0:9999:1ms,b=0:9999:1ms,a=0:9999:1ms,b=0:9999:1ms,a=0:9999:1ms";
        assert_eq!(grid_specs(huge).unwrap_err(), format!("--patch-grid: more than {MAX_CHANGES} changes"));
        assert!(grid_specs("a=0:99999:1ms,b=0:1:1ms").is_err());
        assert_eq!(grid_specs("a=0:99999:1ms").unwrap().len(), 100_000);
        assert!(grid_specs("a=0:99999:1ms;b=+1ms").is_err());
    }
}
