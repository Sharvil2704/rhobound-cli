// SPDX-License-Identifier: Apache-2.0

//! Call structure (rhobound-cli internal/infer/structure.go): calls per visit, and whether a visit's calls run
//! one after another, all at once, or in stages.
//!
//! A signature is kept in two forms: compact (callee ids, with -1 between stages) while the traces are read, so
//! that counting it costs no string, and Go's text key ("3,4|5") once the counts are merged, where it decides
//! orders and ties exactly as in Go.

use std::collections::{BTreeMap, HashMap};

use crate::TraceCall;

pub const PARALLEL_SHARE: f64 = 0.95;
pub const CALL_AGREEMENT: f64 = 0.99;
pub const STAGE_CANDIDATES: usize = 8;

/// A visit's calls in stages, in order; each stage a sorted multiset of callee ids.
pub type StageSig = Vec<Vec<i32>>;

/// Go's text key of a signature ("3,4|5").
pub fn key(s: &[Vec<i32>]) -> String {
    let mut b = String::new();
    for (i, g) in s.iter().enumerate() {
        if i > 0 {
            b.push('|');
        }
        for (j, c) in g.iter().enumerate() {
            if j > 0 {
                b.push(',');
            }
            b.push_str(&c.to_string());
        }
    }
    b
}

/// The text key of a compact signature (stages separated by -1).
pub fn compact_key(c: &[i32]) -> String {
    let mut b = String::new();
    let mut first = true;
    for &x in c {
        if x < 0 {
            b.push('|');
            first = true;
            continue;
        }
        if !first {
            b.push(',');
        }
        b.push_str(&x.to_string());
        first = false;
    }
    b
}

/// The inverse of key (Go's parseSig: a part that is not a number reads as 0).
pub fn parse_sig(k: &str) -> StageSig {
    if k.is_empty() {
        return Vec::new();
    }
    k.split('|').map(|g| g.split(',').map(|c| c.parse::<i32>().unwrap_or(0)).collect()).collect()
}

/// Groups a visit's calls (sorted by start) into stages: a call that starts at or after the latest end of the
/// current stage's calls begins the next one. Writes each stage's length into `lens` (the stages are
/// consecutive runs of cs).
pub fn stages_of(cs: &[TraceCall], lens: &mut Vec<usize>) {
    lens.clear();
    let mut cur = 0usize;
    let mut cur_end = 0u64;
    for c in cs {
        if cur > 0 && c.start >= cur_end {
            lens.push(cur);
            cur = 0;
        }
        cur += 1;
        if cur > 1 {
            cur_end = cur_end.max(c.end);
        } else {
            cur_end = c.end;
        }
    }
    if cur > 0 {
        lens.push(cur);
    }
}

/// The compact signature of calls grouped into stages (each stage's callees sorted).
pub fn compact_sig(cs: &[TraceCall], lens: &[usize], out: &mut Vec<i32>) {
    out.clear();
    let mut at = 0;
    for (i, &l) in lens.iter().enumerate() {
        if i > 0 {
            out.push(-1);
        }
        let from = out.len();
        for c in &cs[at..at + l] {
            out.push(c.callee);
        }
        out[from..].sort_unstable();
        at += l;
    }
}

/// How many calls a visit makes to one callee, from hist (calls per visit -> visits, for visits making at least
/// one; nsp visits in all): (k, p, other) or the refusal's text.
pub fn call_count(hist: &BTreeMap<i64, i64>, nsp: i64) -> Result<(i64, f64, f64), String> {
    let mut cnt: BTreeMap<i64, i64> = BTreeMap::new();
    let mut sum = 0i64;
    for (&n, &v) in hist {
        if v > 0 {
            cnt.insert(n, v);
            sum += v;
        }
    }
    let z = nsp - sum;
    if z > 0 {
        cnt.insert(0, z);
    }
    let vals: Vec<i64> = cnt.keys().copied().collect(); // ascending
    match vals.len() {
        0 => return Ok((0, 0.0, 0.0)),
        1 => return Ok((vals[0], 0.0, 0.0)),
        2 if vals[1] == vals[0] + 1 => return Ok((vals[0], cnt[&vals[1]] as f64 / nsp as f64, 0.0)),
        _ => {}
    }
    let mut top = vals.clone();
    top.sort_by(|a, b| cnt[b].cmp(&cnt[a])); // stable: ties keep the smaller count first
    let (a, b) = (top[0].min(top[1]), top[0].max(top[1]));
    let share = (cnt[&a] + cnt[&b]) as f64 / nsp as f64;
    if b != a + 1 || share < CALL_AGREEMENT {
        let parts: Vec<String> = vals.iter().map(|n| format!("{}: {}", n, cnt[n])).collect();
        return Err(format!("calls per visit vary as {{{}}}", parts.join(", ")));
    }
    Ok((a, cnt[&b] as f64 / nsp as f64, 1.0 - share))
}

/// Which of the template's stages a signature ran, or None if it does not fit.
pub fn fit_stages(sig: &[Vec<i32>], tmpl: &[Vec<i32>]) -> Option<Vec<usize>> {
    fn fit(sig: &[Vec<i32>], tmpl: &[Vec<i32>], i: usize, j: usize) -> Option<Vec<usize>> {
        if i == sig.len() {
            return Some(Vec::new());
        }
        if j == tmpl.len() {
            return None;
        }
        let mut need: HashMap<i32, i64> = HashMap::new();
        for &c in &tmpl[j] {
            *need.entry(c).or_insert(0) += 1;
        }
        let mut acc: HashMap<i32, i64> = HashMap::new();
        for k in i..sig.len() {
            let mut over = false;
            for &c in &sig[k] {
                let e = acc.entry(c).or_insert(0);
                *e += 1;
                over = over || *e > need.get(&c).copied().unwrap_or(0);
            }
            if over {
                break;
            }
            if acc == need {
                if let Some(rest) = fit(sig, tmpl, k + 1, j + 1) {
                    let mut out = vec![j];
                    out.extend(rest);
                    return Some(out);
                }
                break;
            }
        }
        fit(sig, tmpl, i, j + 1)
    }
    fit(sig, tmpl, 0, 0)
}

/// The stage template: the call shape most visits fit, the coarsest on a tie, among the STAGE_CANDIDATES
/// commonest shapes; with each stage's share of the fitting visits and the share of all nsp visits that fit.
/// None when no visit makes a call. sigs is keyed by Go's text key.
pub fn stage_template(sigs: &BTreeMap<String, i64>, nsp: i64) -> Option<(StageSig, Vec<f64>, f64)> {
    let mut keys: Vec<&String> = sigs.iter().filter(|(k, &n)| !k.is_empty() && n > 0).map(|(k, _)| k).collect();
    if keys.is_empty() || nsp <= 0 {
        return None;
    }
    keys.sort_by(|a, b| sigs[*b].cmp(&sigs[*a]).then_with(|| a.cmp(b)));
    let mut all: Vec<&String> = keys.clone();
    all.sort(); // the fits are summed in a fixed order
    let parsed: BTreeMap<&String, StageSig> = all.iter().map(|k| (*k, parse_sig(k))).collect();
    let mut none = nsp;
    for k in &all {
        none -= sigs[*k];
    }
    struct Best<'k> {
        cover: i64,
        count: i64,
        stages: usize,
        tmpl: &'k String,
        fits: BTreeMap<&'k String, Vec<usize>>,
    }
    let mut b: Option<Best> = None;
    for tk in keys.iter().take(STAGE_CANDIDATES) {
        let tm = &parsed[*tk];
        let mut fits = BTreeMap::new();
        let mut cover = none;
        for k in &all {
            if let Some(f) = fit_stages(&parsed[*k], tm) {
                fits.insert(*k, f);
                cover += sigs[*k];
            }
        }
        let better = match &b {
            None => true,
            Some(bb) => {
                cover > bb.cover
                    || (cover == bb.cover && (tm.len() < bb.stages || (tm.len() == bb.stages && sigs[*tk] > bb.count)))
            }
        };
        if better {
            b = Some(Best { cover, count: sigs[*tk], stages: tm.len(), tmpl: tk, fits });
        }
    }
    let b = b.expect("a candidate");
    let tmpl = parsed[b.tmpl].clone();
    let mut ran = vec![0.0; tmpl.len()];
    for (j, r) in ran.iter_mut().enumerate() {
        let mut n = 0i64;
        for k in &all {
            if let Some(f) = b.fits.get(*k) {
                if f.contains(&j) {
                    n += sigs[*k];
                }
            }
        }
        *r = n as f64 / b.cover as f64;
    }
    Some((tmpl, ran, b.cover as f64 / nsp as f64))
}

/// Whether some stage holds two or more calls.
pub fn has_group(s: &[Vec<i32>]) -> bool {
    s.iter().any(|g| g.len() > 1)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn call(callee: i32, start: u64, end: u64) -> TraceCall {
        TraceCall { callee, start, end, client_dur: 0.0, has_server: true, own_clock: false, is_async: false }
    }

    #[test]
    fn stages_by_hand() {
        // TestStagesOf: 3 starts before 1 ends; 4 starts when 1 ends; 5 when 4 ends
        let cs = vec![call(1, 0, 10), call(2, 1, 5), call(3, 6, 8), call(4, 10, 12), call(5, 12, 13)];
        let mut lens = Vec::new();
        stages_of(&cs, &mut lens);
        let mut c = Vec::new();
        compact_sig(&cs, &lens, &mut c);
        let k = compact_key(&c);
        assert_eq!(k, "1,2,3|4|5");
        assert_eq!(key(&parse_sig(&k)), k);
    }

    #[test]
    fn call_counts() {
        // TestCallCount
        type Case = (Vec<(i64, i64)>, i64, i64, f64, f64, bool);
        let cases: Vec<Case> = vec![
            (vec![(1, 1000)], 1000, 1, 0.0, 0.0, false),
            (vec![(2, 1000)], 1000, 2, 0.0, 0.0, false),
            (vec![(1, 300)], 1000, 0, 0.3, 0.0, false),
            (vec![(1, 15)], 1000, 0, 0.015, 0.0, false),
            (vec![(1, 985)], 1000, 0, 0.985, 0.0, false),
            (vec![(1, 700), (2, 300)], 1000, 1, 0.3, 0.0, false),
            (vec![(1, 500), (3, 500)], 1000, 0, 0.0, 0.0, true),
            (vec![(2, 400)], 1000, 0, 0.0, 0.0, true),
            (vec![(1, 250), (2, 500), (3, 250)], 1000, 0, 0.0, 0.0, true),
            (vec![(1, 700), (2, 295), (3, 5)], 1000, 1, 0.295, 0.005, false),
            (vec![(1, 700), (2, 285), (3, 15)], 1000, 0, 0.0, 0.0, true),
        ];
        for (hist, nsp, k, p, oth, refuse) in cases {
            let h: BTreeMap<i64, i64> = hist.into_iter().collect();
            match call_count(&h, nsp) {
                Err(_) => assert!(refuse, "{h:?} refused"),
                Ok((gk, gp, go)) => {
                    assert!(!refuse, "{h:?} accepted");
                    assert_eq!(gk, k);
                    assert!((gp - p).abs() <= 1e-12 && (go - oth).abs() <= 1e-12, "{h:?}: {gp} {go}");
                }
            }
        }
    }
}
