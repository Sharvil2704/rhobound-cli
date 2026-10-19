// SPDX-License-Identifier: Apache-2.0

package infer

import (
	"container/heap"
	"math"
	"math/rand"
	"testing"
)

type minHeap []float64

func (h minHeap) Len() int            { return len(h) }
func (h minHeap) Less(i, j int) bool  { return h[i] < h[j] }
func (h minHeap) Swap(i, j int)       { h[i], h[j] = h[j], h[i] }
func (h *minHeap) Push(x interface{}) { *h = append(*h, x.(float64)) }
func (h *minHeap) Pop() interface{} {
	o := *h
	v := o[len(o)-1]
	*h = o[:len(o)-1]
	return v
}

// pool simulates one pod: Poisson arrivals at lam per ms, exponential service times of mean s ms, c workers
// (c = 0: no limit). spansWait: a span starts at arrival (it includes the wait), else at the start of service.
// It returns each job's span start and release (its end; the job makes no calls).
func pool(n int, lam, s float64, c int, spansWait bool, seed int64) (a, d []float64) {
	rng := rand.New(rand.NewSource(seed))
	h := &minHeap{}
	for i := 0; i < c; i++ {
		heap.Push(h, 0.0)
	}
	t := 0.0
	for i := 0; i < n; i++ {
		t += rng.ExpFloat64() / lam
		st := s * rng.ExpFloat64()
		b := t
		if c > 0 {
			b = math.Max(t, heap.Pop(h).(float64))
			heap.Push(h, b+st)
		}
		if spansWait {
			a = append(a, t)
		} else {
			a = append(a, b)
		}
		d = append(d, b+st)
	}
	return a, d
}

// linearWorkers is the reference's search: every count from 1 until one passes or the bound is reached.
func linearWorkers(q *workerSearch, bound int) int {
	c := 1
	for q.try(c) && c < bound {
		c++
	}
	return c
}

// The search jumps over counts it can prove refuted and must give the reference's answer: the same count, the
// same counts refuted and why, the same contradictions one count below. It is checked on pools with and without
// a worker limit, spans with and without the wait, and a service faster than the jitter allowance. The parts of
// the refutation the jumps rely on are monotone by construction and checked here at every count: contradictions
// and waits never rise with c. The refutation itself is not monotone on the pod with no limit: that is logged.
func TestWorkerSearchMatchesLinear(t *testing.T) {
	cases := []struct {
		name      string
		n         int
		lam, s    float64
		c         int
		spansWait bool
	}{
		{"no limit, ~100 in flight", 40000, 2, 50, 0, true},
		{"24 workers at 85%, spans include the wait", 30000, 2.04, 10, 24, true},
		{"40 workers at 60%, spans include the wait", 30000, 2.4, 10, 40, true},
		{"24 workers at 85%, spans start at service", 30000, 2.04, 10, 24, false},
		{"3 workers at 75%, spans include the wait", 20000, 0.225, 10, 3, true},
		{"16 workers, 0.12 ms, 6000/s", 20000, 6, 0.12, 16, true},
	}
	for i, tc := range cases {
		a, d := pool(tc.n, tc.lam, tc.s, tc.c, tc.spansWait, int64(100+i))
		order := queueOrder(a, d)
		A, D := make([]float64, len(a)), make([]float64, len(a))
		for k, o := range order {
			A[k], D[k] = a[o], d[o]
		}
		bound := min(maxInSystem(A, D), maxWorkersFIFO)
		lin := newWorkerSearch(A, D)
		want := linearWorkers(lin, bound)
		q := inferWorkers(a, d, 0)
		fast := newWorkerSearch(A, D)
		fast.smallest(bound)
		if q.Workers != want || !mapsEqual(q.RefutedBy, lin.why) || q.Contradictions != lin.bad[want] ||
			(want > 1 && q.RefutedBelow != float64(lin.bad[want-1])/float64(len(a))) {
			t.Errorf("%s: got %d workers, refuted %v; the linear search %d, %v", tc.name, q.Workers, q.RefutedBy, want, lin.why)
		}
		// the proven parts, over every count to the bound
		all := newWorkerSearch(A, D)
		prevBad, prevWait, flips := math.MaxInt, math.MaxInt, 0
		prevRef := true
		for c := 1; c <= bound; c++ {
			r := all.try(c)
			if all.bad[c] > prevBad || all.waited > prevWait {
				t.Fatalf("%s: at %d workers contradictions %d and waits %d rose from %d and %d", tc.name, c, all.bad[c], all.waited, prevBad, prevWait)
			}
			if r != prevRef {
				flips++
			}
			prevBad, prevWait, prevRef = all.bad[c], all.waited, r
		}
		t.Logf("%s: %d workers (identified %v, mean wait %.3g ms), bound %d, %d rebuilds instead of %d; the refutation changes "+
			"%d times over 1..%d", tc.name, q.Workers, q.Identified, q.WaitMean, bound, len(fast.bad), want, flips, bound)
	}
}

func mapsEqual(a, b map[int]string) bool {
	if len(a) != len(b) {
		return false
	}
	for k, v := range a {
		if b[k] != v {
			return false
		}
	}
	return true
}

// The code review's cap-inf, as arrays: one pod with no worker limit, 2000 requests/s, exponential 100 ms, about 200 in
// flight, 300k requests. At 29a7ed9 the rebuild read 236 workers, identified (2135 waited, past the reference's
// 100), so the model put the pod at 85% busy and a +20 ms change was refused as unstable; the search rebuilt
// the queue at all 236 counts (2.2 s). The waits there average 2 ms against 100 ms of service, which the
// shortfall test cannot tell from noise, so the count is a lower bound.
func TestUnboundedPoolIsALowerBound(t *testing.T) {
	a, d := pool(300000, 2, 100, 0, true, 9)
	q := inferWorkers(a, d, 0)
	t.Logf("workers %d, waited %d (mean %.2f ms), up to %d at once, identified %v", q.Workers, q.Waited, q.WaitMean, q.MaxInSystem, q.Identified)
	if q.Identified || !q.EnoughWaits {
		t.Errorf("identified %v (enough waits for the reference: %v); want a lower bound", q.Identified, q.EnoughWaits)
	}
	if q.Workers < q.MaxInSystem-40 || q.Workers > q.MaxInSystem {
		t.Errorf("workers %d, up to %d at once", q.Workers, q.MaxInSystem)
	}
	order := queueOrder(a, d)
	A, D := make([]float64, len(a)), make([]float64, len(a))
	for k, o := range order {
		A[k], D[k] = a[o], d[o]
	}
	s := newWorkerSearch(A, D)
	s.smallest(min(q.MaxInSystem, maxWorkersFIFO))
	if len(s.bad) > 60 {
		t.Errorf("%d rebuilds for %d workers", len(s.bad), q.Workers)
	}
	// a real pool of 3 workers at 75% with spans that include the wait: identified
	a, d = pool(20000, 0.225, 10, 3, true, 5)
	if q := inferWorkers(a, d, 0); q.Workers != 3 || !q.Identified {
		t.Errorf("3 workers at 75%%: got %d, identified %v (mean wait %.2f ms)", q.Workers, q.Identified, q.WaitMean)
	}
}
