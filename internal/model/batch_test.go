// SPDX-License-Identifier: Apache-2.0

package model

import (
	"encoding/json"
	"math"
	"os"
	"path/filepath"
	"testing"
)

func batchClose(t *testing.T, what string, got, want, tol float64) {
	t.Helper()
	if !(math.Abs(got-want) <= tol*math.Max(math.Abs(want), 1e-12)) {
		t.Errorf("%s: got %.10g, want %.10g (tolerance %.2g relative)", what, got, want, tol)
	}
}

// uniformLaw is a batch law of sizes lo..hi equally likely, plus singles at rate single, as (epoch rate, q).
func uniformLaw(rate float64, lo, hi int, single float64) (float64, []float64) {
	q := make([]float64, hi+1)
	tot := rate + single
	for k := lo; k <= hi; k++ {
		q[k] += rate / tot / float64(hi-lo+1)
	}
	q[1] += single / tot
	return tot, q
}

// The superposition's points have closed means where the answer is known: a fresh worker's m-th point is the sum of m
// services (mean m, second moment m cs2 + m^2) for any cs2; an equilibrium worker's is a residual plus m-1 services;
// c exponential workers give points at rate c (Gamma(m, c)).
func TestSupMomentsKnownCases(t *testing.T) {
	for _, cs2 := range []float64{0.05, 0.16, 0.5, 1, 2} {
		et, et2 := supMoments(0, 1, 12, cs2)
		for m := 1; m <= 12; m++ {
			x := float64(m)
			batchClose(t, "fresh E[T]", et[m-1], x, 1e-6)
			batchClose(t, "fresh E[T^2]", et2[m-1], x*cs2+x*x, 1e-6)
		}
		et, _ = supMoments(1, 0, 12, cs2)
		for m := 1; m <= 12; m++ {
			batchClose(t, "equilibrium E[T]", et[m-1], (1+cs2)/2+float64(m-1), 1e-6)
		}
	}
	for _, c := range []int{2, 4, 8} {
		et, et2 := supMoments(c, 0, 30, 1)
		for m := 1; m <= 30; m++ {
			x, cf := float64(m), float64(c)
			batchClose(t, "exponential E[T]", et[m-1], x/cf, 1e-6)
			batchClose(t, "exponential E[T^2]", et2[m-1], x*(x+1)/(cf*cf), 1e-6)
		}
	}
}

// The end of a batch: one service when nothing else runs; the largest of exponentials is a harmonic sum.
func TestTailsKnownCases(t *testing.T) {
	for _, cs2 := range []float64{0.05, 0.3, 1, 2} {
		e, e2 := tailQuad(0, 0, 0, 0, cs2)
		batchClose(t, "one service", e, 1, 1e-6)
		batchClose(t, "one service, second moment", e2, 1+cs2, 1e-6)
		e, e2 = maxOf(1, cs2)
		batchClose(t, "max of one", e, 1, 1e-6)
		batchClose(t, "max of one, second moment", e2, 1+cs2, 1e-6)
	}
	e, _ := maxOf(2, 1)
	batchClose(t, "max of 2 exponentials", e, 1.5, 1e-6)
	e, _ = maxOf(4, 1)
	batchClose(t, "max of 4 exponentials", e, 1+0.5+1.0/3+0.25, 1e-6)
	// exponential, every other worker runs a member (an infinite window): the max of A exponentials
	e, _ = tailQuad(0, 3, 0, 1e9, 1)
	batchClose(t, "S and 3 equilibrium exponential residuals", e, 1+0.5+1.0/3+0.25, 1e-6)
}

// M^X/D/c: GTH on the Crommelin chain against plain iteration of the chain, and Little's law against the closed
// M/D/1 wait.
func TestPiDAgainstIteration(t *testing.T) {
	lam, q := uniformLaw(0.05, 3, 6, 0.1)
	m := &mxq{c: 2, s: 1, cs2: 0.01, lam: lam, q: q}
	pM, err := m.piM()
	if err != nil {
		t.Fatal(err)
	}
	pD := m.piD(len(pM) - 1)
	a := m.cpois()
	p := make([]float64, len(pD)+len(a)+64)
	p[0] = 1
	for it := 0; it < 20000; it++ {
		nx := make([]float64, len(p))
		for n, v := range p {
			if v == 0 {
				continue
			}
			base := max(n-m.c, 0)
			for x, ax := range a {
				nx[min(base+x, len(p)-1)] += v * ax
			}
		}
		p = nx
	}
	for n := range pD {
		if math.Abs(pD[n]-p[n]) > 1e-12 {
			t.Fatalf("pD[%d] = %.15g, iteration %.15g", n, pD[n], p[n])
		}
	}
	// M/D/1 at rho 0.5: Lq = rho^2/(2(1-rho)) = 0.25
	m = &mxq{c: 1, s: 1, cs2: 0, lam: 0.5, q: []float64{0, 1}}
	pM, _ = m.piM()
	pD = m.piD(len(pM) - 1)
	lq := 0.0
	for n, v := range pD {
		lq += float64(max(n-1, 0)) * v
	}
	batchClose(t, "M/D/1 Lq", lq, 0.25, 1e-9)
}

// For one worker and cs2 <= 1 the superposition is exact, and so must agree with the closed M^X/G/1 forms.
func TestSupMatchesTheExactSingleServer(t *testing.T) {
	for _, cs2 := range []float64{0.1, 0.5, 1} {
		for _, rho := range []float64{0.2, 0.6} {
			lam, q := uniformLaw(1, 4, 12, 0)
			lam *= rho / 8 // E[X] = 8, s = 1
			m := &mxq{c: 1, s: 1, cs2: cs2, lam: lam, q: q}
			sizes := []int{4, 8, 12}
			one := m.solveOne(12)
			sup, err := m.solveSup(sizes, 12)
			if err != nil {
				t.Fatal(err)
			}
			batchClose(t, "W0", sup.W0, one.W0, 1e-5)
			batchClose(t, "Wbar", sup.Wbar, one.Wbar, 1e-5)
			for _, k := range sizes {
				batchClose(t, "makespan", sup.MS[k], one.MS[k], 1e-5)
			}
		}
	}
}

// With exponential services the number in system is exact (M^X/M/c) and so is every wait: member j of a batch that
// finds n starts at the (n-c+j)-th departure, which come at rate c/s.
func TestExponentialWaitsAreExact(t *testing.T) {
	for _, c := range []int{2, 4, 8} {
		lam, q := uniformLaw(1, 3, 8, 1)
		ex := 0.0
		for k, p := range q {
			ex += float64(k) * p
		}
		lam = 0.6 * float64(c) / (ex * 2) // epochs per ms: rho 0.6 at s = 2
		m := &mxq{c: c, s: 2, cs2: 1, lam: lam, q: q}
		pi, err := m.piM()
		if err != nil {
			t.Fatal(err)
		}
		var w0, wb float64
		for n, p := range pi {
			w0 += p * float64(max(n-c+1, 0)) * 2 / float64(c)
			for k, qk := range q {
				for j := 1; j <= k; j++ {
					wb += p * qk * float64(max(n-c+j, 0)) * 2 / float64(c)
				}
			}
		}
		wb /= ex
		sol, err := m.solve([]int{3, 8})
		if err != nil {
			t.Fatal(err)
		}
		batchClose(t, "W0", sol.W0, w0, 1e-5)
		batchClose(t, "Wbar", sol.Wbar, wb, 1e-5)
	}
}

// The model against the seeded discrete-event simulation (testdata/batch: des.py, the lane's validation sweep): waits
// within 3% + 4 standard errors where they are at least a fifth of a service, makespans within 5% (the sweep's worst
// at cs2 <= 1 is 7%, its 90th percentile 2%), for cs2 <= 1; at cs2 2 the documented envelope is wider (8%).
func TestBatchAgainstTheSimulation(t *testing.T) {
	raw, err := os.ReadFile(filepath.Join("testdata", "batch", "des-reference.json"))
	if err != nil {
		t.Fatal(err)
	}
	var doc struct {
		Cases []struct {
			ID      string
			C       int
			S, CS2  float64
			Classes []struct {
				Rate  float64
				Sizes [][2]float64
			}
			Post *struct {
				P, Mean, CS2 float64
			}
			Add      float64            `json:"add"`
			Mul      float64            `json:"mul"`
			W0       float64            `json:"W0"`
			W0SE     float64            `json:"W0_se"`
			Wbar     float64            `json:"Wbar"`
			WbSE     float64            `json:"Wbar_se"`
			Makespan map[string]float64 `json:"makespan"`
		}
	}
	if err := json.Unmarshal(raw, &doc); err != nil {
		t.Fatal(err)
	}
	for _, c := range doc.Cases {
		kmax := 1
		for _, cl := range c.Classes {
			for _, sz := range cl.Sizes {
				kmax = max(kmax, int(sz[0]))
			}
		}
		lam := 0.0
		for _, cl := range c.Classes {
			lam += cl.Rate
		}
		q := make([]float64, kmax+1)
		var sizes []int
		for _, cl := range c.Classes {
			tw := 0.0
			for _, sz := range cl.Sizes {
				tw += sz[1]
			}
			for _, sz := range cl.Sizes {
				q[int(sz[0])] += cl.Rate / lam * sz[1] / tw
				sizes = append(sizes, int(sz[0]))
			}
		}
		s := c.S*c.Mul + c.Add
		cs2 := c.CS2 * (c.S * c.Mul) * (c.S * c.Mul) / (s * s)
		m := &mxq{c: c.C, s: s, cs2: math.Max(cs2, batchMinCS2), lam: lam, q: q}
		sol, err := m.solve(sizes)
		if err != nil {
			t.Fatalf("%s: %v", c.ID, err)
		}
		tol := 0.03
		if cs2 > 1.01 {
			tol = 0.08
		}
		for _, w := range []struct {
			what          string
			got, want, se float64
		}{{"W0", sol.W0, c.W0, c.W0SE}, {"Wbar", sol.Wbar, c.Wbar, c.WbSE}} {
			if w.want < 0.2*s {
				continue
			}
			if math.Abs(w.got-w.want) > tol*w.want+4*w.se {
				t.Errorf("%s (s %.3g): %s %.4f, simulated %.4f +- %.4f", c.ID, s, w.what, w.got, w.want, w.se)
			}
		}
		for ks, want := range c.Makespan {
			var k int
			json.Unmarshal([]byte(ks), &k)
			got := sol.MS[k]
			if c.Post != nil {
				got += postExtra(k, s/float64(c.C), postLaw{p0: 1 - c.Post.P, m: c.Post.Mean, v: c.Post.CS2 * c.Post.Mean * c.Post.Mean})
			}
			if math.Abs(got-want) > math.Max(tol, 0.05)*want {
				t.Errorf("%s (s %.3g): makespan of %d: %.4f, simulated %.4f", c.ID, s, k, got, want)
			}
		}
	}
}

// The post time: a batch of one waits for its own (E[P]); a constant post time adds itself.
func TestPostExtra(t *testing.T) {
	law := postLaw{g: 0.1, p0: 0.5, m: 3.8, v: 0.7 * 3.8 * 3.8}
	batchClose(t, "k = 1", postExtra(1, 4, law), 0.1+0.5*3.8, 1e-6)
	batchClose(t, "constant", postExtra(8, 4, postLaw{g: 0.3, p0: 1}), 0.3, 0)
	if a, b := postExtra(8, 4, law), postExtra(8, 2, law); !(a > 0.1+0.5*3.8 && b > a) {
		t.Errorf("post extra %.4f (spacing 4), %.4f (spacing 2): want above E[P] and growing as the ends close up", a, b)
	}
}

// batchTopo: entry E calls stage S (parallel, k calls to B) and C, which calls B once; B is a pooled queue of c workers
// whose visits also call T with probability p after the worker is freed.
func batchTopo(k, c int, p float64) *Topology {
	calls := make([]Call, k)
	for i := range calls {
		calls[i] = Call{Child: 2, P: 1}
	}
	t := &Topology{Services: []Service{
		{Name: "E", S: 1, Servers: 8, CS2: 1, Calls: []Call{{Child: 1, P: 1}, {Child: 3, P: 1}}},
		{Name: "stage:E:1", Delay: true, Parallel: true, CS2: 1, Calls: calls},
		{Name: "B", S: 8, Servers: c, CS2: 0.16, Hop: 0.2, Calls: []Call{{Child: 4, P: p}}, Glue: 0.01},
		{Name: "C", S: 2, Servers: 2, CS2: 0.5, Calls: []Call{{Child: 2, P: 1}}},
		{Name: "T", S: 3.6, Servers: 2, CS2: 0.7, Hop: 0.2},
	}, Entry: map[int]float64{0: 1}}
	if err := t.Finish(); err != nil {
		panic(err)
	}
	return t
}

// In a network: the stage's latency is the batch's (hop, makespan, the latest post time), C's single call waits what a
// single call waits, B's row is the mean over all its visits; services off every batch path keep the numbers of the
// model without the term, bit for bit; the solution is the same bits on every run.
func TestBatchInTheNetwork(t *testing.T) {
	topo := batchTopo(8, 2, 0.5)
	lam := 0.004 // per ms: B gets 9 calls per request, 36 per s, rho 0.29 at 2 workers
	res, err := AnalyticWith(topo, lam, nil, Default)
	if err != nil || !res.Stable {
		t.Fatalf("model: %v", err)
	}
	b := topo.Index("B")
	s := topo.Services[b].S
	q := make([]float64, 9)
	q[8], q[1] = 0.5, 0.5
	sol, err := (&mxq{c: 2, s: s, cs2: 0.16, lam: 2 * lam, q: q}).solve([]int{1, 8})
	if err != nil {
		t.Fatal(err)
	}
	batchClose(t, "B's residence", res.R[b], s+sol.Wbar, 1e-12)
	if !(res.R[b]-s > 3*(sol.W0)) {
		t.Errorf("B's mean wait %.3f should be far above a single call's %.3f", res.R[b]-s, sol.W0)
	}
	// C waits a single call's residence: L[C] = s_C + its own wait + hop + (s_B + W0 + post)
	noBatch := Config{ArrivalWeight: 0.7, MatchedMax: true}
	old, err := AnalyticWith(topo, lam, nil, noBatch)
	if err != nil || !old.Stable {
		t.Fatal(err)
	}
	ci, ti := topo.Index("C"), topo.Index("T")
	post := old.L[b] - old.R[b] // B's work after its worker is freed, the same in both
	batchClose(t, "C", res.L[ci], old.R[ci]+0.2+s+sol.W0+post, 1e-9)
	// T and C's own residence are off every batch path
	if res.R[ti] != old.R[ti] || res.L[ti] != old.L[ti] || res.R[ci] != old.R[ci] || res.Ca2[b] != old.Ca2[b] {
		t.Errorf("a number off the batch path moved: T %v/%v, C's R %v/%v", res.L[ti], old.L[ti], res.R[ci], old.R[ci])
	}
	on := BatchPath(topo)
	if !on[0] || !on[1] || !on[b] || !on[ci] || on[ti] {
		t.Errorf("batch path %v", on)
	}
	// the stage: the batch of 8 is far slower than the old max of correlated gammas
	st := topo.Index("stage:E:1")
	if !(res.L[st] > sol.MS[8]) || !(res.L[st] > 1.5*old.L[st]) {
		t.Errorf("stage %.3f, makespan %.3f, old model %.3f", res.L[st], sol.MS[8], old.L[st])
	}
	again, _ := AnalyticWith(topo, lam, nil, Default)
	for i := range res.L {
		if math.Float64bits(res.L[i]) != math.Float64bits(again.L[i]) || math.Float64bits(res.R[i]) != math.Float64bits(again.R[i]) {
			t.Fatalf("%s: not the same bits on a second run", topo.Services[i].Name)
		}
	}
}

// A topology without calls made at once is solved exactly as without the batch term; Plain never applies it.
func TestNoBatchNoChange(t *testing.T) {
	topo := batchTopo(1, 2, 0.5) // the stage calls B once: no batch
	if HasBatches(topo) {
		t.Fatal("one call is not a batch")
	}
	a, _ := AnalyticWith(topo, 0.004, nil, Default)
	b, _ := AnalyticWith(topo, 0.004, nil, Config{ArrivalWeight: 0.7, MatchedMax: true})
	for i := range a.L {
		if math.Float64bits(a.L[i]) != math.Float64bits(b.L[i]) || math.Float64bits(a.V[i]) != math.Float64bits(b.V[i]) {
			t.Fatalf("%s moved without a batch", topo.Services[i].Name)
		}
	}
	topo = batchTopo(8, 2, 0.5)
	a, _ = AnalyticWith(topo, 0.004, nil, Plain)
	b, _ = AnalyticWith(topo, 0.004, nil, Config{Batch: true})
	for i := range a.L {
		if a.L[i] != b.L[i] {
			t.Fatalf("%s: the batch term without MatchedMax", topo.Services[i].Name)
		}
	}
	// a callee with replica shares is not pooled: no batch term
	topo.Services[2].Servers, topo.Services[2].Workers, topo.Services[2].Routing = 2, 1, Random
	topo.Services[2].Shares = []float64{0.6, 0.4}
	if HasBatches(topo) {
		t.Error("a callee with uneven replica shares is not taken as one batch queue")
	}
}

// A change of the batch-fed service's time moves the stage by about E[ceil(k/c)] times it plus the backlog's change:
// here at least ceil(8/2) = 4 times.
func TestBatchChangeIsAmplified(t *testing.T) {
	topo := batchTopo(8, 2, 0.5)
	n := len(topo.Services)
	p := Patch{DS: make([]float64, n), Shift: make([]bool, n)}
	b := topo.Index("B")
	p.DS[b], p.Shift[b] = -2, true
	d, err := ChangePatchWith(topo, 0.004, p, Default)
	if err != nil || !d.Stable {
		t.Fatal(err)
	}
	st := topo.Index("stage:E:1")
	if dl := d.DL[st]; !(dl < -8) {
		t.Errorf("the stage moved %.3f ms for -2 ms at B; want at least 4 times as much", dl)
	}
}

// piD's band: with more workers than the arrival law has columns (c >= len(cpois)), a low load on many workers, the
// reduction read past its slice and the prediction panicked (found by the Lean workflow's Queue verifier).
func TestPiDBandWiderThanArrivals(t *testing.T) {
	for _, c := range []int{8, 16, 18, 19, 64} {
		m := &mxq{c: c, s: 8, cs2: 0.16, lam: 0.008, q: []float64{0, 0.5, 0.5}}
		pM, err := m.piM()
		if err != nil {
			t.Fatal(err)
		}
		pD := m.piD(len(pM) - 1)
		sum, mean := 0.0, 0.0
		for n, p := range pD {
			sum += p
			mean += float64(n) * p
		}
		// rho = lam E[X] s / c; the number in system of a D queue at this light load is about c rho = 0.096
		if math.Abs(sum-1) > 1e-9 || !(mean > 0.09 && mean < 0.11) {
			t.Errorf("c %d (len(cpois) %d): piD sums to %v, mean %v", c, len(m.cpois()), sum, mean)
		}
		if c <= 19 {
			if _, err := m.solve([]int{1, 2}); err != nil {
				t.Errorf("c %d: %v", c, err)
			}
		}
	}
}
