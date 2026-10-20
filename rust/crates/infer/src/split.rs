// SPDX-License-Identifier: Apache-2.0

//! The split of a service's visits over its pods (rhobound-cli internal/infer/split.go): each pod's share, the
//! p-value of an even random split, and the measured shares for the model when the test rules that out.

use crate::gofmt;
use crate::mathx;

/// One pod's share of its service's visits.
#[derive(Clone, Debug, PartialEq)]
pub struct PodShare {
    pub pod: String,
    pub visits: i64,
    pub share: f64,
}

pub const SPLIT_P: f64 = 1e-6;
pub const SPLIT_MIN_EXPECTED: f64 = 20.0;

/// The p-value of visit counts per pod under an even random split (Pearson's chi-square, len-1 degrees of
/// freedom); None when the test is not read (fewer than two pods, or under SPLIT_MIN_EXPECTED visits per pod).
pub fn even_split_p(n: &[i64]) -> Option<f64> {
    if n.len() < 2 {
        return None;
    }
    let tot: i64 = n.iter().sum();
    let e = tot as f64 / n.len() as f64;
    if e < SPLIT_MIN_EXPECTED {
        return None;
    }
    let mut chi2 = 0.0;
    for &x in n {
        let d = x as f64 - e;
        chi2 += d * d / e;
    }
    Some(crate::go_max(0.0, 1.0 - mathx::gamma_p((n.len() - 1) as f64 / 2.0, chi2 / 2.0)))
}

/// The pods' shares of a service's visits, by pod name (then id); the p-value of the even-split test (None when
/// it is not read); the shares for the model when the test rules an even split out.
pub fn pod_split(
    pods: &[i32],
    pod_name: &[String],
    pod_visits: &[i64],
) -> (Vec<PodShare>, Option<f64>, Option<Vec<f64>>) {
    let mut ids: Vec<i32> = pods.to_vec();
    ids.sort_by(|&a, &b| pod_name[a as usize].cmp(&pod_name[b as usize]).then(a.cmp(&b)));
    let n: Vec<i64> = ids.iter().map(|&id| pod_visits[id as usize]).collect();
    let tot: i64 = n.iter().sum();
    if tot == 0 {
        return (Vec::new(), None, None);
    }
    let by: Vec<PodShare> = ids
        .iter()
        .zip(&n)
        .map(|(&id, &v)| PodShare { pod: pod_name[id as usize].clone(), visits: v, share: v as f64 / tot as f64 })
        .collect();
    let Some(pv) = even_split_p(&n) else {
        return (by, None, None);
    };
    let shares = if pv < SPLIT_P { Some(by.iter().map(|s| s.share).collect()) } else { None };
    (by, Some(pv), shares)
}

/// Describes an uneven split and how it is modelled.
pub fn split_warning(name: &str, by: &[PodShare], p: f64) -> String {
    let parts: Vec<String> = by.iter().map(|s| format!("{} {}%", s.pod, gofmt::f(100.0 * s.share, 1))).collect();
    let pv = if p < 1e-12 { "p < 1e-12".to_string() } else { format!("p = {}", gofmt::g(p, 1)) };
    format!(
        "{}: its {} pods took uneven shares of its visits: {} (an even random split, which the model would assume, \
         gives this with {}). A Kubernetes Service picks a pod per connection, so clients that keep their connections \
         alive can hold such a split (so does a pod that was up for only part of the window, which the model does not \
         cover). Each pod is modelled as a queue fed its measured share, and the change prediction keeps these shares",
        name,
        by.len(),
        parts.join(", "),
        pv
    )
}
