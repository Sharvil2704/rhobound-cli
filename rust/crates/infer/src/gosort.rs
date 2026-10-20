// SPDX-License-Identifier: Apache-2.0 AND BSD-3-Clause
// Derived from Go's src/slices/zsortanyfunc.go and src/slices/sort.go, Copyright The Go Authors, under the BSD-3-Clause
// licence in rust/LICENSE-GO; the rest is Apache-2.0.

//! Go's `slices.SortFunc` (pattern-defeating quicksort), ported step for step so that it leaves equal elements in
//! the same order as Go does. It is used where that order reaches a result: the calls of one visit (equal start
//! and callee), the rise estimator's events, and the span table itself (through [`sort_func_par`]).
//!
//! [`sort_func_par`] is the same algorithm with the two ranges a partition leaves sorted at the same time
//! (rayon::join). Go's loop recurses on the smaller range with fresh state and loops on the larger one with its
//! state carried over; each range's sort reads and writes only that range, plus the element just before it
//! (the pivot or equal element that bounds it, which no other range touches), and pdqsort's pseudo-random
//! pattern breaking is seeded by the range's length alone. So the two can run at once and every element ends
//! exactly where Go's serial sort puts it.
//!
//! Ported from Go's src/slices/zsortanyfunc.go and sort.go: Copyright 2022 The Go Authors. All rights reserved.
//! Use of this source code is governed by a BSD-style license (rust/LICENSE-GO).

/// Sorts `data` by `less` exactly as Go's `slices.SortFunc(data, cmp)` does with `cmp(a, b) < 0` as `less(a, b)`.
pub fn sort_func<T, F: FnMut(&T, &T) -> bool>(data: &mut [T], mut less: F) {
    let n = data.len();
    let limit = (usize::BITS - n.leading_zeros()) as i32;
    pdqsort(data, 0, n, limit, &mut less, None, true, true);
}

/// Ranges shorter than this are sorted serially by [`sort_func_par`].
const PAR_MIN: usize = 1 << 13;

/// [`sort_func`] on the current rayon pool: the same result, element for element (see the module notes).
pub fn sort_func_par<T: Send + Sync, F: Fn(&T, &T) -> bool + Sync>(data: &mut [T], less: F) {
    let n = data.len();
    let limit = (usize::BITS - n.leading_zeros()) as i32;
    pdq_par(data, None, limit, true, true, &less);
}

/// One pass of Go's pdqsort loop on all of `data`, as the loop stands at the top of an iteration (`limit`, the
/// two flags); `pred` is the element just before the range in Go's array (None at its start). The two ranges
/// the partition leaves are sorted in parallel.
fn pdq_par<T: Send + Sync, F: Fn(&T, &T) -> bool + Sync>(
    data: &mut [T],
    pred: Option<&T>,
    mut limit: i32,
    mut was_balanced: bool,
    mut was_partitioned: bool,
    less: &F,
) {
    let length = data.len();
    let mut lm = |x: &T, y: &T| less(x, y);
    if length < PAR_MIN {
        pdqsort(data, 0, length, limit, &mut lm, pred, was_balanced, was_partitioned);
        return;
    }
    // length > MAX_INSERTION here
    if limit == 0 {
        heap_sort(data, 0, length, &mut lm);
        return;
    }
    if !was_balanced {
        break_patterns(data, 0, length);
        limit -= 1;
    }
    let (mut pivot, mut hint) = choose_pivot(data, 0, length, &mut lm);
    if hint == Hint::Decreasing {
        reverse_range(data, 0, length);
        pivot = (length - 1) - pivot;
        hint = Hint::Increasing;
    }
    if was_balanced && was_partitioned && hint == Hint::Increasing && partial_insertion_sort(data, 0, length, &mut lm) {
        return;
    }
    if let Some(p) = pred {
        if !less(p, &data[pivot]) {
            let mid = partition_equal(data, 0, length, pivot, &mut lm);
            let (head, tail) = data.split_at_mut(mid);
            pdq_par(tail, Some(&head[mid - 1]), limit, was_balanced, was_partitioned, less);
            return;
        }
    }
    let (mid, already) = partition(data, 0, length, pivot, &mut lm);
    was_partitioned = already;
    let (left, right) = (mid, length - mid);
    let balance = length / 8;
    let (lo, rest) = data.split_at_mut(mid);
    let (pv, hi) = rest.split_at_mut(1);
    let pv = &pv[0];
    if left < right {
        // Go recurses on [a, mid) and loops on [mid+1, b)
        was_balanced = left >= balance;
        rayon::join(
            || pdq_par(lo, pred, limit, true, true, less),
            || pdq_par(hi, Some(pv), limit, was_balanced, was_partitioned, less),
        );
    } else {
        // Go recurses on [mid+1, b) and loops on [a, mid)
        was_balanced = right >= balance;
        rayon::join(
            || pdq_par(hi, Some(pv), limit, true, true, less),
            || pdq_par(lo, pred, limit, was_balanced, was_partitioned, less),
        );
    }
}

fn insertion_sort<T, F: FnMut(&T, &T) -> bool>(data: &mut [T], a: usize, b: usize, less: &mut F) {
    for i in a + 1..b {
        let mut j = i;
        while j > a && less(&data[j], &data[j - 1]) {
            data.swap(j, j - 1);
            j -= 1;
        }
    }
}

fn sift_down<T, F: FnMut(&T, &T) -> bool>(data: &mut [T], lo: usize, hi: usize, first: usize, less: &mut F) {
    let mut root = lo;
    loop {
        let mut child = 2 * root + 1;
        if child >= hi {
            break;
        }
        if child + 1 < hi && less(&data[first + child], &data[first + child + 1]) {
            child += 1;
        }
        if !less(&data[first + root], &data[first + child]) {
            return;
        }
        data.swap(first + root, first + child);
        root = child;
    }
}

fn heap_sort<T, F: FnMut(&T, &T) -> bool>(data: &mut [T], a: usize, b: usize, less: &mut F) {
    let first = a;
    let lo = 0;
    let hi = b - a;
    let mut i = (hi as isize - 1) / 2;
    while i >= 0 {
        sift_down(data, i as usize, hi, first, less);
        i -= 1;
    }
    let mut i = hi as isize - 1;
    while i >= 0 {
        data.swap(first, first + i as usize);
        sift_down(data, lo, i as usize, first, less);
        i -= 1;
    }
}

#[derive(PartialEq, Eq, Clone, Copy)]
enum Hint {
    Unknown,
    Increasing,
    Decreasing,
}

/// Go's pdqsortCmpFunc on data[a..b], entered as its loop stands at the top of an iteration; `pred` stands for
/// data[a - 1] when a is 0 here but not in Go's array (a range handed over by [`pdq_par`]).
#[allow(clippy::too_many_arguments)]
fn pdqsort<T, F: FnMut(&T, &T) -> bool>(
    data: &mut [T],
    mut a: usize,
    mut b: usize,
    mut limit: i32,
    less: &mut F,
    pred: Option<&T>,
    mut was_balanced: bool,
    mut was_partitioned: bool,
) {
    const MAX_INSERTION: usize = 12;
    loop {
        let length = b - a;
        if length <= MAX_INSERTION {
            insertion_sort(data, a, b, less);
            return;
        }
        if limit == 0 {
            heap_sort(data, a, b, less);
            return;
        }
        if !was_balanced {
            break_patterns(data, a, b);
            limit -= 1;
        }
        let (mut pivot, mut hint) = choose_pivot(data, a, b, less);
        if hint == Hint::Decreasing {
            reverse_range(data, a, b);
            pivot = (b - 1) - (pivot - a);
            hint = Hint::Increasing;
        }
        if was_balanced && was_partitioned && hint == Hint::Increasing && partial_insertion_sort(data, a, b, less) {
            return;
        }
        let before = if a > 0 { Some(&data[a - 1]) } else { pred };
        if before.is_some_and(|p| !less(p, &data[pivot])) {
            let mid = partition_equal(data, a, b, pivot, less);
            a = mid;
            continue;
        }
        let (mid, already) = partition(data, a, b, pivot, less);
        was_partitioned = already;
        let (left, right) = (mid - a, b - mid);
        let balance = length / 8;
        if left < right {
            was_balanced = left >= balance;
            pdqsort(data, a, mid, limit, less, pred, true, true);
            a = mid + 1;
        } else {
            was_balanced = right >= balance;
            pdqsort(data, mid + 1, b, limit, less, pred, true, true);
            b = mid;
        }
    }
}

fn partition<T, F: FnMut(&T, &T) -> bool>(
    data: &mut [T],
    a: usize,
    b: usize,
    pivot: usize,
    less: &mut F,
) -> (usize, bool) {
    data.swap(a, pivot);
    // i and j are inclusive bounds of what is left to partition; j can go to a (one below i's start)
    let (mut i, mut j) = (a as isize + 1, b as isize - 1);
    while i <= j && less(&data[i as usize], &data[a]) {
        i += 1;
    }
    while i <= j && !less(&data[j as usize], &data[a]) {
        j -= 1;
    }
    if i > j {
        data.swap(j as usize, a);
        return (j as usize, true);
    }
    data.swap(i as usize, j as usize);
    i += 1;
    j -= 1;
    loop {
        while i <= j && less(&data[i as usize], &data[a]) {
            i += 1;
        }
        while i <= j && !less(&data[j as usize], &data[a]) {
            j -= 1;
        }
        if i > j {
            break;
        }
        data.swap(i as usize, j as usize);
        i += 1;
        j -= 1;
    }
    data.swap(j as usize, a);
    (j as usize, false)
}

fn partition_equal<T, F: FnMut(&T, &T) -> bool>(
    data: &mut [T],
    a: usize,
    b: usize,
    pivot: usize,
    less: &mut F,
) -> usize {
    data.swap(a, pivot);
    let (mut i, mut j) = (a as isize + 1, b as isize - 1);
    loop {
        while i <= j && !less(&data[a], &data[i as usize]) {
            i += 1;
        }
        while i <= j && less(&data[a], &data[j as usize]) {
            j -= 1;
        }
        if i > j {
            break;
        }
        data.swap(i as usize, j as usize);
        i += 1;
        j -= 1;
    }
    i as usize
}

fn partial_insertion_sort<T, F: FnMut(&T, &T) -> bool>(data: &mut [T], a: usize, b: usize, less: &mut F) -> bool {
    const MAX_STEPS: usize = 5;
    const SHORTEST_SHIFTING: usize = 50;
    let mut i = a + 1;
    for _ in 0..MAX_STEPS {
        while i < b && !less(&data[i], &data[i - 1]) {
            i += 1;
        }
        if i == b {
            return true;
        }
        if b - a < SHORTEST_SHIFTING {
            return false;
        }
        data.swap(i, i - 1);
        // shift the smaller one to the left (Go's loop runs down to index 1, not to a + 1)
        if i - a >= 2 {
            let mut j = i - 1;
            while j >= 1 {
                if !less(&data[j], &data[j - 1]) {
                    break;
                }
                data.swap(j, j - 1);
                j -= 1;
            }
        }
        // shift the greater one to the right
        if b - i >= 2 {
            let mut j = i + 1;
            while j < b {
                if !less(&data[j], &data[j - 1]) {
                    break;
                }
                data.swap(j, j - 1);
                j += 1;
            }
        }
    }
    false
}

fn break_patterns<T>(data: &mut [T], a: usize, b: usize) {
    let length = b - a;
    if length >= 8 {
        let mut random = length as u64;
        let modulus: u64 = 1u64 << (usize::BITS - length.leading_zeros());
        let mut idx = a + (length / 4) * 2 - 1;
        while idx <= a + (length / 4) * 2 + 1 {
            random ^= random << 13;
            random ^= random >> 7;
            random ^= random << 17;
            let mut other = (random & (modulus - 1)) as usize;
            if other >= length {
                other -= length;
            }
            data.swap(idx, a + other);
            idx += 1;
        }
    }
}

fn choose_pivot<T, F: FnMut(&T, &T) -> bool>(data: &mut [T], a: usize, b: usize, less: &mut F) -> (usize, Hint) {
    const SHORTEST_NINTHER: usize = 50;
    const MAX_SWAPS: i32 = 4 * 3;
    let l = b - a;
    let mut swaps = 0i32;
    let mut i = a + l / 4;
    let mut j = a + l / 4 * 2;
    let mut k = a + l / 4 * 3;
    if l >= 8 {
        if l >= SHORTEST_NINTHER {
            i = median_adjacent(data, i, &mut swaps, less);
            j = median_adjacent(data, j, &mut swaps, less);
            k = median_adjacent(data, k, &mut swaps, less);
        }
        j = median(data, i, j, k, &mut swaps, less);
    }
    match swaps {
        0 => (j, Hint::Increasing),
        MAX_SWAPS => (j, Hint::Decreasing),
        _ => (j, Hint::Unknown),
    }
}

fn order2<T, F: FnMut(&T, &T) -> bool>(
    data: &[T],
    a: usize,
    b: usize,
    swaps: &mut i32,
    less: &mut F,
) -> (usize, usize) {
    if less(&data[b], &data[a]) {
        *swaps += 1;
        return (b, a);
    }
    (a, b)
}

fn median<T, F: FnMut(&T, &T) -> bool>(
    data: &[T],
    a: usize,
    b: usize,
    c: usize,
    swaps: &mut i32,
    less: &mut F,
) -> usize {
    let (a, b) = order2(data, a, b, swaps, less);
    let (b, c) = order2(data, b, c, swaps, less);
    let _ = c;
    let (_a, b) = order2(data, a, b, swaps, less);
    b
}

fn median_adjacent<T, F: FnMut(&T, &T) -> bool>(data: &[T], a: usize, swaps: &mut i32, less: &mut F) -> usize {
    median(data, a - 1, a, a + 1, swaps, less)
}

fn reverse_range<T>(data: &mut [T], a: usize, b: usize) {
    let (mut i, mut j) = (a, b - 1);
    while i < j {
        data.swap(i, j);
        i += 1;
        j -= 1;
    }
}

#[cfg(test)]
mod tests {
    use super::sort_func;

    // A deterministic shuffle; the check is that the order is sorted and every element kept (the tie order is
    // checked against Go's on real span tables in the oracle tests).
    #[test]
    fn sorts() {
        let mut x: u64 = 88172645463325252;
        for n in [0usize, 1, 2, 5, 12, 13, 49, 50, 51, 200, 1000, 5000] {
            let mut v: Vec<(u32, usize)> = (0..n)
                .map(|i| {
                    x ^= x << 13;
                    x ^= x >> 7;
                    x ^= x << 17;
                    ((x % 37) as u32, i)
                })
                .collect();
            let mut want = v.clone();
            want.sort();
            sort_func(&mut v, |a, b| a.0 < b.0);
            let mut got = v.clone();
            assert!(v.windows(2).all(|w| w[0].0 <= w[1].0));
            got.sort();
            assert_eq!(got, want);
        }
    }
}
