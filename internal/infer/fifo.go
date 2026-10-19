// SPDX-License-Identifier: Apache-2.0

package infer

// Queue reconstruction per pod: a port of the reference implementation's
// per-pod queue reconstruction and worker search.
//
// Each server span arrives at its start (a) and frees its worker when it first
// calls out, or at its end when it makes no call (the release, d). Given every
// job's release, a first-come-first-served queue with c workers fixes when each
// job started service (b): job n starts once it has arrived and the c-th latest
// release among the jobs before it has happened. The smallest c for which that
// queue explains the pod's spans (no negative service time beyond clock jitter,
// and no shortfall of own time among the requests it makes wait) is the pod's
// worker count. Every job's wait b - a is then known, so the service time
// (d - b, as in the reference) is read from every job, not only from those
// that found a worker free. One test is added to the reference's
// (briefShortfall), for services faster than its jitter allowance.

import (
	"math"
	"runtime"
	"sort"
	"sync"
)

// The reference's constants, unchanged.
const (
	jitterMs        = 0.25 // a reconstructed service time below -jitterMs is a contradiction ...
	jitterWaitShare = 0.02 // ... and a count is refuted by more than 2% of the requests it makes wait
	jitterFloor     = 3    // (or 3, whichever is more)
	tieMs           = 0.05 // arrivals this close are taken in order of release
	shortfallZ      = 3.0  // a count is also refuted when the requests it makes wait have own times
	shortfallRel    = 0.10 // significantly (z < -3) and materially (> 10%) shorter than the others'
	shortfallMin    = 30
	identMinWaits   = 100 // a count is identified when at least this many requests waited at it (and see materialWaits)
	maxWorkersFIFO  = 512
	minPodJobs      = 20 // pods with fewer server spans are not reconstructed (the reference skips them)
)

// Estimator names for Options.Estimator and the RHOBOUND_ESTIMATOR variable.
const (
	EstimatorFIFO = "fifo" // the FIFO queue reconstruction per pod (default)
	EstimatorRise = "rise" // the earlier estimator: own time by visits busy at arrival, rise detection
)

// fifoStart returns the start of service of each job (sorted by arrival a) in
// a first-come-first-served queue with c workers, given every job's release d.
func fifoStart(a, d []float64, c int) []float64 {
	b := make([]float64, len(a))
	fifoStartInto(b, a, d, c, make([]float64, 0, c))
	return b
}

// fifoStartInto is fifoStart writing into b, with top as the heap's storage.
func fifoStartInto(b, a, d []float64, c int, top []float64) {
	top = top[:0]
	prev := math.Inf(-1)
	for n := range a {
		x := a[n]
		if len(top) == c && top[0] > x { // top[0] is the c-th latest release so far
			x = top[0]
		}
		if prev > x {
			x = prev
		}
		b[n], prev = x, x
		if len(top) < c {
			top = append(top, d[n])
			siftUp(top, len(top)-1)
		} else if d[n] > top[0] {
			top[0] = d[n]
			siftDown(top, 0)
		}
	}
}

func siftUp(h []float64, i int) {
	for i > 0 {
		p := (i - 1) / 2
		if !(h[i] < h[p]) {
			return
		}
		h[i], h[p] = h[p], h[i]
		i = p
	}
}

func siftDown(h []float64, i int) {
	n := len(h)
	for {
		l := 2*i + 1
		if l >= n {
			return
		}
		m := l
		if r := l + 1; r < n && h[r] < h[l] {
			m = r
		}
		if !(h[m] < h[i]) {
			return
		}
		h[i], h[m] = h[m], h[i]
		i = m
	}
}

// meanVar is the mean and the sample variance (ddof 1) of xs, in two passes.
func meanVar(xs []float64) (float64, float64) {
	n := float64(len(xs))
	if n == 0 {
		return math.NaN(), math.NaN()
	}
	s := 0.0
	for _, x := range xs {
		s += x
	}
	m := s / n
	if n < 2 {
		return m, math.NaN()
	}
	v := 0.0
	for _, x := range xs {
		v += (x - m) * (x - m)
	}
	return m, v / (n - 1)
}

// shortfall is the (z, relative difference) of the mean own time of the
// requests that waited against those that did not.
func shortfall(S []float64, waited []bool, bufW, bufN []float64) (float64, float64) {
	bufW, bufN = bufW[:0], bufN[:0]
	for i, s := range S {
		if waited[i] {
			bufW = append(bufW, s)
		} else {
			bufN = append(bufN, s)
		}
	}
	nw, nn := len(bufW), len(bufN)
	if nw < 2 || nn < 2 {
		return math.NaN(), math.NaN()
	}
	mw, vw := meanVar(bufW)
	mn, vn := meanVar(bufN)
	se := math.Sqrt(vw/float64(nw) + vn/float64(nn))
	z, rel := 0.0, 0.0
	if se > 0 {
		z = (mw - mn) / se
	}
	if mn > 0 {
		rel = mw/mn - 1
	}
	return z, rel
}

// briefShortfall is the shortfall test over every request the count makes
// wait, however briefly; it runs only when fewer than shortfallMin waited
// beyond jitterMs. It is not in the reference. It covers a gap there: when a
// service is faster than jitterMs (a cache, a lookup), no wait passes
// jitterMs, so neither test sees anything, one worker explains every pod, and
// the invented waits come out of the service time. 16 workers at 0.12 ms
// (0.72 erlangs) read as 1 worker at 0.085 ms, 51% busy; with this test, 4 at
// 0.119 ms. Where it can go wrong: if span ends lag the worker's release, a
// service under about 0.5 ms can see its true count refuted and get more
// workers, up to the most in a pod at once. Too many workers at such a fast
// service changes the latency little; too few with a 30% low service time
// does not. w is overwritten.
func briefShortfall(A, B, S []float64, w []bool, bufW, bufN []float64) bool {
	n := 0
	for i := range B {
		w[i] = B[i] > A[i]
		if w[i] {
			n++
		}
	}
	if n < shortfallMin {
		return false
	}
	z, rel := shortfall(S, w, bufW, bufN)
	return z < -shortfallZ && rel < -shortfallRel
}

// podQueue is the first-come-first-served queue reconstructed for one pod.
type podQueue struct {
	Workers        int
	Jobs           int
	Contradictions int            // service times below -jitterMs at that count
	RefutedBelow   float64        // contradiction share at Workers - 1 (NaN for 1 worker)
	EnoughWaits    bool           // >= identMinWaits requests waited at this count (the reference's "identified")
	Identified     bool           // EnoughWaits, and the waits are material (materialWaits); else a lower bound
	WaitMean       float64        // mean wait of the requests that waited at this count, ms
	MaxInSystem    int            // jobs in the pod at once (arrived, not released)
	A, B, D        []float64      // arrival, start of service, release (ms), in queue order
	Waited         int            // requests that waited at this count
	ShortfallZ     float64        // own time of those that waited vs the others: z ...
	ShortfallRel   float64        // ... and relative difference
	RefutedBy      map[int]string // counts tried and refuted -> "contradictions" | "shortfall" | "brief-wait shortfall"
	Order          []int          // input index of each job above
}

// queueOrder sorts the jobs as the reference does: by arrival (stable), then
// within runs of arrivals closer than tieMs by release. It returns the input
// index of each job in that order.
func queueOrder(a, d []float64) []int {
	n := len(a)
	o := make([]int, n)
	for i := range o {
		o[i] = i
	}
	sort.SliceStable(o, func(x, y int) bool { return a[o[x]] < a[o[y]] })
	tie := make([]int, n)
	for i := 1; i < n; i++ {
		tie[i] = tie[i-1]
		if a[o[i]]-a[o[i-1]] > tieMs {
			tie[i]++
		}
	}
	// stable sort by (tie group, release); tie is non-decreasing in o, so sort each group alone
	for lo := 0; lo < n; {
		hi := lo + 1
		for hi < n && tie[hi] == tie[lo] {
			hi++
		}
		if hi-lo > 1 {
			g := o[lo:hi]
			sort.SliceStable(g, func(x, y int) bool { return d[g[x]] < d[g[y]] })
		}
		lo = hi
	}
	return o
}

// maxInSystem is the most jobs present at once in a queue that takes them in
// the order given (arrivals a, releases d): at each arrival, the jobs before
// it not yet released, plus itself. A release at the instant of an arrival
// comes first (that worker is free). With that many workers nobody waits, so
// it bounds the worker search. The reference sweeps every release at an
// instant before every arrival there, so a job released at its own arrival
// was taken off before it was counted, and the bound came out one short; a
// visit whose first call starts at or before its span's start (the release is
// clipped to the span) is such a job.
func maxInSystem(a, d []float64) int {
	h := make([]float64, 0, 64) // min-heap of the releases still to come
	best := 0
	for n := range a {
		for len(h) > 0 && h[0] <= a[n] {
			h[0] = h[len(h)-1]
			h = h[:len(h)-1]
			siftDown(h, 0)
		}
		best = max(best, len(h)+1)
		h = append(h, d[n])
		siftUp(h, len(h)-1)
	}
	return best
}

// workerSearch holds one pod's jobs in queue order and the buffers for
// rebuilding its queue at one worker count after another.
type workerSearch struct {
	A, D, B, S []float64
	w          []bool
	bufW, bufN []float64
	top        []float64
	bad        map[int]int    // contradictions at each count tried
	why        map[int]string // counts tried and refuted, and by what
	// at the last count tried (try):
	at, waited int
	z, rel     float64
}

func newWorkerSearch(A, D []float64) *workerSearch {
	n := len(A)
	return &workerSearch{A: A, D: D, B: make([]float64, n), S: make([]float64, n), w: make([]bool, n),
		bufW: make([]float64, 0, n), bufN: make([]float64, 0, n), bad: map[int]int{}, why: map[int]string{}}
}

// try rebuilds the queue with c workers and reports whether the count is
// refuted: more contradictions than jitterWaitShare of the requests it makes
// wait (or jitterFloor), or an own-time shortfall among those requests.
func (q *workerSearch) try(c int) bool {
	if cap(q.top) < c {
		q.top = make([]float64, 0, 2*c)
	}
	fifoStartInto(q.B, q.A, q.D, c, q.top[:0])
	waited, nb := 0, 0
	for i := range q.B {
		q.S[i] = q.D[i] - q.B[i]
		q.w[i] = q.B[i]-q.A[i] > jitterMs
		if q.w[i] {
			waited++
		}
		if q.S[i] < -jitterMs {
			nb++
		}
	}
	q.at, q.waited = c, waited
	q.bad[c] = nb
	q.z, q.rel = math.NaN(), math.NaN()
	if waited >= shortfallMin {
		q.z, q.rel = shortfall(q.S, q.w, q.bufW, q.bufN)
	}
	if float64(nb) > math.Max(jitterFloor, jitterWaitShare*float64(waited)) {
		q.why[c] = "contradictions"
	} else if q.z < -shortfallZ && q.rel < -shortfallRel {
		q.why[c] = "shortfall"
	} else if waited < shortfallMin && briefShortfall(q.A, q.B, q.S, q.w, q.bufW, q.bufN) {
		q.why[c] = "brief-wait shortfall"
	}
	_, refuted := q.why[c]
	return refuted
}

// smallest returns the smallest count in [1, bound] that try does not refute,
// or bound if every count up to it is refuted: the reference's linear search,
// with the same answer and the same RefutedBy, without rebuilding the queue at
// every count. Adding a worker never delays a start of service (the c-th
// latest release so far is at most the (c-1)-th, and by induction every start
// is at most what it was), so as c grows the contradictions can only fall and
// so can the waits. Hence, with lo refuted and w(lo) waits at it, a count hi
// with contradictions(hi) > max(jitterFloor, jitterWaitShare*w(lo)) proves
// every count in (lo, hi] refuted by contradictions: each has at least that
// many contradictions and at most w(lo) waits. The search jumps by doubling
// steps while that holds and halves the step when it does not, down to single
// counts near the answer. The refutation as a whole is not monotone (the
// threshold falls with the waits; on a pod with no worker limit the
// contradiction share hovers at the threshold over several counts), so a plain
// bisection could return a larger count; this cannot. On a pod with some 200
// requests in flight it is about 40 rebuilds instead of 236.
func (q *workerSearch) smallest(bound int) int {
	if !q.try(1) || bound <= 1 {
		return 1
	}
	lo, wlo, step := 1, q.waited, 1
	for {
		hi := min(lo+step, bound)
		refuted := q.try(hi)
		if hi == lo+1 {
			if !refuted || hi == bound {
				return hi
			}
			lo, wlo, step = hi, q.waited, 2
			continue
		}
		if float64(q.bad[hi]) > math.Max(jitterFloor, jitterWaitShare*float64(wlo)) {
			for c := lo + 1; c < hi; c++ {
				q.why[c] = "contradictions" // what the linear search would have recorded
			}
			if hi == bound {
				return hi
			}
			lo, wlo, step = hi, q.waited, 2*step
			continue
		}
		step /= 2
	}
}

// materialWaits reports whether the waits at the count tried last are evidence
// of real queueing, not of a pod that never queues read at a count near the
// most requests it ever held. The reference identifies a count once
// identMinWaits requests waited at it and it passed, because had the pod more
// workers those waits would be invented and the shortfall test would see the
// waiting requests' service times come out short by their wait. That holds
// only when the waits are long enough for the test to see: a shortfall of
// their mean wait must pass both of its bars, shortfallRel of the others' mean
// service time and shortfallZ standard errors. A pod with no worker limit and
// 200 requests in flight, read at 236 workers, has waits of a few ms against
// 100 ms of service: 3%, which the test cannot tell from noise, so the count
// is a lower bound. One worker at 45% busy waits S/(1-0.45) on average among
// those that wait: identified.
func (q *workerSearch) materialWaits() (bool, float64) {
	var nw, nn int
	var sw, sn, ww float64
	for i := range q.B {
		if q.w[i] {
			nw++
			sw += q.S[i]
			ww += q.B[i] - q.A[i]
		} else {
			nn++
			sn += q.S[i]
		}
	}
	if nw < 2 {
		return false, math.NaN()
	}
	wbar := ww / float64(nw)
	q.bufW, q.bufN = q.bufW[:0], q.bufN[:0]
	for i := range q.S {
		if q.w[i] {
			q.bufW = append(q.bufW, q.S[i])
		} else {
			q.bufN = append(q.bufN, q.S[i])
		}
	}
	_, vw := meanVar(q.bufW)
	se2 := vw / float64(nw)
	ref := sw / float64(nw) // everyone waited: the waiting requests' own mean
	if nn >= 2 {
		_, vn := meanVar(q.bufN)
		se2 += vn / float64(nn)
		ref = sn / float64(nn)
	}
	return wbar >= shortfallRel*ref && wbar >= shortfallZ*math.Sqrt(se2), wbar
}

// inferWorkers finds the smallest worker count c whose FIFO queue explains the
// pod's jobs (arrivals a, releases d, in any order): contradictions no more than
// jitterWaitShare of the requests it makes wait (or jitterFloor), and no own-time
// shortfall among those requests. If fixed > 0 the count is taken as given.
// The count is identified when identMinWaits requests waited at it and their
// waits are material (materialWaits); otherwise it is a lower bound.
func inferWorkers(a, d []float64, fixed int) *podQueue {
	n := len(a)
	order := queueOrder(a, d)
	A := make([]float64, n)
	D := make([]float64, n)
	for i, k := range order {
		A[i], D[i] = a[k], d[k]
	}
	maxSys := 0
	if n > 0 {
		maxSys = maxInSystem(A, D)
	}
	q := newWorkerSearch(A, D)
	c := fixed
	if fixed > 0 {
		q.try(c)
	} else {
		c = q.smallest(min(max(maxSys, 1), maxWorkersFIFO))
		for k := range q.why {
			if k > c {
				delete(q.why, k) // tried on the way, above the answer: the linear search never gets there
			}
		}
		if _, ok := q.bad[c-1]; c > 1 && !ok {
			q.try(c - 1) // jumped over: only for RefutedBelow
		}
		if q.at != c {
			q.try(c)
		}
	}
	below := math.NaN()
	if v, ok := q.bad[c-1]; ok && c > 1 && n > 0 {
		below = float64(v) / float64(n)
	}
	enough := q.waited >= identMinWaits
	material, wmean := q.materialWaits()
	return &podQueue{Workers: c, Jobs: n, Contradictions: q.bad[c], RefutedBelow: below,
		EnoughWaits: enough, Identified: enough && material, WaitMean: wmean, MaxInSystem: maxSys, A: A, B: q.B, D: D,
		Waited: q.waited, ShortfallZ: q.z, ShortfallRel: q.rel, RefutedBy: q.why, Order: order}
}

// svcQueue is what the reconstruction gives one service, pooled over its pods.
type svcQueue struct {
	workers    int     // the largest count over the pods
	identified bool    // every reconstructed pod's count is identified
	waitedMean float64 // mean wait of the requests that waited, over the pods
	jobs       int     // jobs reconstructed
	relMean    float64 // service time: release minus start of service
	relVar     float64
	waitMean   float64 // mean reconstructed wait (b - a)
	minWaited  int     // fewest waits at its count over the pods
	maxSys     int     // most requests in a pod at once
	negShare   float64 // share of release - start of service below zero
	pods       []*podQueue
}

// reconstructQueues runs the reconstruction on every pod and pools the result
// per service. fixed maps a service id to a user-set worker count.
func reconstructQueues(vrec []visitRec, nSvc int, fixed map[int32]int) []*svcQueue {
	byPod := map[int32][]int32{}
	podSvc := map[int32]int32{}
	for i := range vrec {
		p := vrec[i].pod
		byPod[p] = append(byPod[p], int32(i))
		podSvc[p] = vrec[i].svc
	}
	podsOfSvc := make([][]int32, nSvc)
	for p, s := range podSvc {
		if int(s) < nSvc {
			podsOfSvc[s] = append(podsOfSvc[s], p)
		}
	}
	// which pods to reconstruct: those with >= minPodJobs jobs, or every pod of a service that has none such
	var jobs []int32
	for s := range podsOfSvc {
		ps := podsOfSvc[s]
		sort.Slice(ps, func(i, j int) bool { return ps[i] < ps[j] })
		var big []int32
		for _, p := range ps {
			if len(byPod[p]) >= minPodJobs {
				big = append(big, p)
			}
		}
		if len(big) == 0 {
			big = ps
		}
		podsOfSvc[s] = big
		jobs = append(jobs, big...)
	}
	res := make(map[int32]*podQueue, len(jobs))
	var mu sync.Mutex
	var wg sync.WaitGroup
	next := make(chan int32)
	for w := 0; w < runtime.GOMAXPROCS(0); w++ {
		wg.Add(1)
		go func() {
			defer wg.Done()
			for p := range next {
				idx := byPod[p]
				base := vrec[idx[0]].start
				for _, i := range idx {
					base = min(base, vrec[i].start)
				}
				a := make([]float64, len(idx))
				d := make([]float64, len(idx))
				for k, i := range idx {
					a[k] = float64(int64(vrec[i].start)-int64(base)) / 1e6
					d[k] = float64(int64(vrec[i].rel)-int64(base)) / 1e6
				}
				q := inferWorkers(a, d, fixed[podSvc[p]])
				mu.Lock()
				res[p] = q
				mu.Unlock()
			}
		}()
	}
	for _, p := range jobs {
		next <- p
	}
	close(next)
	wg.Wait()

	out := make([]*svcQueue, nSvc)
	for s := range podsOfSvc {
		if len(podsOfSvc[s]) == 0 {
			continue
		}
		sq := &svcQueue{identified: true, minWaited: math.MaxInt}
		var sr, wt []float64
		neg, nw := 0, 0
		for _, p := range podsOfSvc[s] {
			q := res[p]
			if q.Waited >= 2 {
				sq.waitedMean += q.WaitMean * float64(q.Waited)
				nw += q.Waited
			}
			sq.pods = append(sq.pods, q)
			sq.workers = max(sq.workers, q.Workers)
			sq.identified = sq.identified && q.Identified
			sq.minWaited = min(sq.minWaited, q.Waited)
			sq.maxSys = max(sq.maxSys, q.MaxInSystem)
			for j := range q.B {
				wait := q.B[j] - q.A[j]
				rel := q.D[j] - q.B[j]
				sr = append(sr, rel)
				wt = append(wt, wait)
				if rel < 0 {
					neg++
				}
			}
		}
		if nw > 0 {
			sq.waitedMean /= float64(nw)
		}
		sq.jobs = len(sr)
		sq.relMean, sq.relVar = meanVar(sr)
		sq.waitMean, _ = meanVar(wt)
		if sq.jobs > 0 {
			sq.negShare = float64(neg) / float64(sq.jobs)
		}
		out[s] = sq
	}
	return out
}
