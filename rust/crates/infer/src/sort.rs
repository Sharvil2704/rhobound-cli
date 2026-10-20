// SPDX-License-Identifier: Apache-2.0

//! The sorts of the span table by (trace, start).
//!
//! [`sort_spans_go`] (the default) leaves every span where Go's `slices.SortFunc` (pdqsort) puts it, ties
//! included: pdqsort's permutation depends only on the outcomes of its comparisons, so it is run (in parallel,
//! [`gosort::sort_func_par`]) on compact keys (trace, start, capture index) with Go's comparator, and the spans
//! are then gathered in the keys' order. Spans with an equal trace and start time can be told apart by a
//! result (the pairing of parallel calls to one callee, for one), so Go's order of them matters.
//!
//! [`sort_spans_stable`] is a parallel stable sort (an MSD radix pass on the trace id's top differing bits into
//! 4096 buckets, counted per block in parallel, scattered in block order, then a stable sort of each bucket):
//! the same order wherever (trace, start) differ, capture order among ties. It is not Go's order of ties and is
//! kept only as an audit switch (`RBFAST_SORT=stable`).

use rayon::prelude::*;
use rbfast_otlp::Span;

const BITS: i32 = 12;

#[inline]
fn key_cmp(x: &Span, y: &Span) -> std::cmp::Ordering {
    (x.trace, x.start).cmp(&(y.trace, y.start))
}

/// One span's sort key and its index in the capture.
#[derive(Clone, Copy)]
struct Key {
    t0: u64,
    t1: u64,
    start: u64,
    idx: u32,
}

#[inline]
fn key_less(x: &Key, y: &Key) -> bool {
    (x.t0, x.t1, x.start) < (y.t0, y.t1, y.start)
}

/// Sorts spans by (trace, start) into exactly Go's order (Go's comparator: trace[0], trace[1], start).
pub fn sort_spans_go(spans: &mut Vec<Span>) {
    let n = spans.len();
    if n < 1 << 12 || rayon::current_num_threads() == 1 || u32::try_from(n).is_err() {
        // on one thread the keys do not pay: their sort costs about what the spans' does (comparisons, not
        // moves, dominate), and the gather comes on top
        crate::gosort::sort_func(spans, |a: &Span, b: &Span| (a.trace, a.start) < (b.trace, b.start));
        return;
    }
    let mut keys: Vec<Key> = spans
        .par_iter()
        .enumerate()
        .map(|(i, s)| Key { t0: s.trace[0], t1: s.trace[1], start: s.start, idx: i as u32 })
        .collect();
    crate::gosort::sort_func_par(&mut keys, key_less);
    let src: &[Span] = spans;
    let out: Vec<Span> = keys.par_iter().map(|k| src[k.idx as usize]).collect();
    *spans = out;
}

/// Sorts spans by (trace, start), keeping the order of equal ones (not Go's order of ties).
pub fn sort_spans_stable(spans: &mut Vec<Span>) {
    let n = spans.len();
    if n < 1 << 14 {
        spans.sort_by(key_cmp);
        return;
    }
    let f = spans[0].trace;
    let (x0, x1) = spans
        .par_iter()
        .map(|s| (s.trace[0] ^ f[0], s.trace[1] ^ f[1]))
        .reduce(|| (0, 0), |a, b| (a.0 | b.0, a.1 | b.1));
    let top: i32 = if x0 != 0 {
        64 + 63 - x0.leading_zeros() as i32
    } else if x1 != 0 {
        63 - x1.leading_zeros() as i32
    } else {
        -1 // one trace
    };
    if top < 0 {
        spans.par_sort_by(key_cmp);
        return;
    }
    let bits = BITS.min(top + 1);
    let shift = (top + 1 - bits) as u32;
    let mask = (1usize << bits) - 1;
    let nb = mask + 1;
    let bucket =
        move |s: &Span| -> usize { ((((s.trace[0] as u128) << 64 | s.trace[1] as u128) >> shift) as usize) & mask };
    let block = n.div_ceil(rayon::current_num_threads() * 4).max(1 << 14);
    let hist: Vec<Vec<u32>> = spans
        .par_chunks(block)
        .map(|ch| {
            let mut h = vec![0u32; nb];
            for s in ch {
                h[bucket(s)] += 1;
            }
            h
        })
        .collect();
    // where each block's spans of each bucket go: bucket-major, then block order
    let mut offs: Vec<Vec<usize>> = vec![vec![0; nb]; hist.len()];
    let mut starts = vec![0usize; nb + 1];
    let mut at = 0usize;
    for b in 0..nb {
        starts[b] = at;
        for (k, h) in hist.iter().enumerate() {
            offs[k][b] = at;
            at += h[b] as usize;
        }
    }
    starts[nb] = n;
    debug_assert_eq!(at, n);
    let mut out: Vec<Span> = Vec::with_capacity(n);
    let base = out.as_mut_ptr() as usize;
    spans.par_chunks(block).zip(offs.into_par_iter()).for_each(|(ch, mut o)| {
        let p = base as *mut Span;
        for s in ch {
            let b = bucket(s);
            // SAFETY: the offsets partition 0..n: every block writes its own slots of each bucket, each once,
            // and out has capacity n
            unsafe { p.add(o[b]).write(*s) };
            o[b] += 1;
        }
    });
    // SAFETY: all n slots were written above (the histograms count every span of every block)
    unsafe { out.set_len(n) };
    let mut slices: Vec<&mut [Span]> = Vec::with_capacity(nb);
    let mut rest: &mut [Span] = &mut out;
    for b in 0..nb {
        let (h, t) = rest.split_at_mut(starts[b + 1] - starts[b]);
        slices.push(h);
        rest = t;
    }
    slices.into_par_iter().for_each(|sl| {
        if sl.len() > 1 << 16 {
            sl.par_sort_by(key_cmp);
        } else if sl.len() > 1 {
            sl.sort_by(key_cmp);
        }
    });
    *spans = out;
}

#[cfg(test)]
mod tests {
    use super::*;

    fn span(t0: u64, t1: u64, start: u64, id: u64) -> Span {
        Span { trace: [t0, t1], id, start, ..Default::default() }
    }

    /// Equal, span for span, to the serial port of Go's sort, on inputs with many ties and on several shapes
    /// (random, few traces, one trace, sorted, reversed, all equal), at several pool sizes.
    #[test]
    fn same_as_go_serial() {
        let mut x: u64 = 0x2545F4914F6CDD1D;
        let mut next = || {
            x ^= x << 13;
            x ^= x >> 7;
            x ^= x << 17;
            x
        };
        let mut cases: Vec<Vec<Span>> = vec![
            (0..200_000).map(|i| span(next(), next(), next() % 1000, i)).collect(),
            (0..150_000).map(|i| span(0, next() % 5000, next() % 7, i)).collect(),
            (0..60_000).map(|i| span(7, 9, next() % 100, i)).collect(),
            (0..90_000).map(|i| span(next() % 3, next() % 3, next() % 3, i)).collect(),
            (0..70_000).map(|i| span(1, 2, 3, i)).collect(),
            (0..80_000).map(|i| span(i / 3, 0, i % 2, i)).collect(),
            (0..80_000).rev().map(|i| span(i / 5, 0, 0, i)).collect(),
        ];
        let mut organ: Vec<Span> = (0..40_000).map(|i| span(i, 0, 0, i)).collect();
        organ.extend((0..40_000).rev().map(|i| span(i, 0, 0, i + 40_000)));
        cases.push(organ);
        for threads in [1, 3, 8] {
            let pool = rayon::ThreadPoolBuilder::new().num_threads(threads).build().unwrap();
            for (k, c) in cases.iter().enumerate() {
                let mut want = c.clone();
                crate::gosort::sort_func(&mut want, |a: &Span, b: &Span| (a.trace, a.start) < (b.trace, b.start));
                let mut got = c.clone();
                pool.install(|| sort_spans_go(&mut got));
                assert!(got == want, "case {k} at {threads} threads");
            }
        }
    }

    /// Equal to a stable sort on random ids, on ids that differ only in their low bits, on one trace, and with
    /// many equal (trace, start) pairs.
    #[test]
    fn same_as_a_stable_sort() {
        let mut x: u64 = 0x9E3779B97F4A7C15;
        let mut next = || {
            x ^= x << 13;
            x ^= x >> 7;
            x ^= x << 17;
            x
        };
        let mut cases: Vec<Vec<Span>> = Vec::new();
        cases.push((0..100_000).map(|i| span(next(), next(), next() % 1000, i)).collect());
        cases.push((0..100_000).map(|i| span(0, next() % 5000, next() % 7, i)).collect());
        cases.push((0..50_000).map(|i| span(7, 9, next() % 100, i)).collect());
        cases.push((0..70_000).map(|i| span(next() % 3, next() % 3, next() % 3, i)).collect());
        for (k, c) in cases.into_iter().enumerate() {
            let mut want = c.clone();
            want.sort_by(key_cmp);
            let mut got = c;
            sort_spans_stable(&mut got);
            assert!(got == want, "case {k}");
        }
    }
}
