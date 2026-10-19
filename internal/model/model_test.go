// SPDX-License-Identifier: Apache-2.0

package model

import (
	"math"
	"strings"
	"testing"
)

func near(t *testing.T, what string, got, want, tol float64) {
	t.Helper()
	if math.Abs(got-want) > tol*math.Max(1, math.Abs(want)) {
		t.Errorf("%s: got %.12g want %.12g", what, got, want)
	}
}

func TestErlangCKnownValues(t *testing.T) {
	near(t, "M/M/1 wait prob = rho", ErlangC(1, 0.7), 0.7, 1e-14)
	// Erlang C with 2 servers at 1 erlang: 1/3
	near(t, "M/M/2 at a=1", ErlangC(2, 1), 1.0/3.0, 1e-14)
	near(t, "overload", ErlangC(3, 3), 1, 0)
}

func TestResidenceMM1AndMG1(t *testing.T) {
	s, lam := 4.0, 0.15 // rho 0.6
	near(t, "M/M/1", Residence(s, lam, 1, 1, 1), 1/(1/s-lam), 1e-13)
	// Allen-Cunneen is exact for M/G/1 (Pollaczek-Khinchine)
	cs2 := 0.25
	want := s + lam*s*s*(1+cs2)/(2*(1-lam*s))
	near(t, "M/G/1", Residence(s, lam, 1, 1, cs2), want, 1e-13)
	if !math.IsInf(Residence(s, 0.25, 1, 1, 1), 1) {
		t.Error("an unstable queue should return +Inf")
	}
	near(t, "idle", Residence(s, 0, 3, 1, 1), s, 0)
}

func TestRandomRoutingIsMG1PerReplica(t *testing.T) {
	r, err := ResidenceRouted(5, 0.3, 3, Random, 1, 1, 1)
	if err != nil {
		t.Fatal(err)
	}
	near(t, "random over 3 replicas", r, Residence(5, 0.1, 1, 1, 1), 1e-14)
	if _, err := ResidenceRouted(5, 0.3, 3, "p2c", 1, 1, 1); err == nil {
		t.Error("p2c should be refused")
	}
}

const chain = `{"name":"chain","entry":{"a":1},"services":[
 {"name":"a","s":2,"children":["b"]},
 {"name":"b","s":3,"children":["c"],"servers":2},
 {"name":"c","s":4}]}`

func TestChainMatchesProductForm(t *testing.T) {
	topo, err := ParseTopology([]byte(chain))
	if err != nil {
		t.Fatal(err)
	}
	lam := 0.1 // per ms
	r, err := Analytic(topo, lam, nil)
	if err != nil || !r.Stable {
		t.Fatalf("unstable: %v", err)
	}
	// a: M/M/1 at 0.1 -> 2/(1-0.2); c: M/M/1 -> 4/(1-0.4); b: M/M/2 closed form
	near(t, "a", r.R[0], 2/(1-0.2), 1e-13)
	near(t, "c", r.R[2], 4/(1-0.4), 1e-13)
	near(t, "entry L", r.L[0], r.R[0]+r.R[1]+r.R[2], 1e-13)
	d, err := Change(topo, lam, []float64{0, 1, 0})
	if err != nil || !d.Stable || d.DL[0] <= 0 {
		t.Fatalf("change: %v %+v", err, d)
	}
	near(t, "dL at c is zero", d.DL[2], 0, 1e-15)
}

func TestHopIsAddedPerCall(t *testing.T) {
	topo, _ := ParseTopology([]byte(chain))
	r0, _ := Analytic(topo, 0.05, nil)
	topo.Services[1].Hop = 0.7
	r1, _ := Analytic(topo, 0.05, nil)
	near(t, "hop lifts the caller by the hop", r1.L[0]-r0.L[0], 0.7, 1e-13)
}

func TestUnstableAndRefusals(t *testing.T) {
	topo, _ := ParseTopology([]byte(chain))
	r, err := Analytic(topo, 0.3, nil) // c: 0.3*4 = 1.2
	if err != nil || r.Stable {
		t.Fatal("expected an unstable result")
	}
	bad := map[string]string{
		"cycle":   `{"entry":{"a":1},"services":[{"name":"a","s":1,"children":["b"]},{"name":"b","s":1,"children":["a"]}]}`,
		"routing": `{"entry":{"a":1},"services":[{"name":"a","s":1,"servers":2,"routing":"p2c"}]}`,
		"hold":    `{"entry":{"a":1},"services":[{"name":"a","s":1,"hold":true}]}`,
		"workers": `{"entry":{"a":1},"services":[{"name":"a","s":1,"servers":2,"workers":2}]}`,
		"condpar": `{"entry":{"a":1},"services":[{"name":"a","s":1,"parallel":true,"children":[{"name":"b","p":0.5},"b"]},{"name":"b","s":1}]}`,
		"noentry": `{"entry":{},"services":[{"name":"a","s":1}]}`,
	}
	for name, doc := range bad {
		if _, err := ParseTopology([]byte(doc)); err == nil {
			t.Errorf("%s: expected an error", name)
		} else if strings.TrimSpace(err.Error()) == "" {
			t.Errorf("%s: empty error", name)
		}
	}
}

func TestVisitRatiosWithRepeatsAndProbability(t *testing.T) {
	doc := `{"entry":{"a":1},"services":[
	 {"name":"a","s":1,"children":["b","b",{"name":"c","p":0.25}]},
	 {"name":"b","s":1},{"name":"c","s":1}]}`
	topo, err := ParseTopology([]byte(doc))
	if err != nil {
		t.Fatal(err)
	}
	v := topo.VisitRatios()
	near(t, "b visits", v[1], 2, 0)
	near(t, "c visits", v[2], 0.25, 0)
}

func TestChangeShiftKeepsVarianceAndScaleKeepsCS2(t *testing.T) {
	doc := `{"entry":{"a":1},"services":[{"name":"a","s":10,"cs2":0.5,"servers":2}]}`
	topo, err := ParseTopology([]byte(doc))
	if err != nil {
		t.Fatal(err)
	}
	lam := 0.12 // rho = 0.6 at 2 servers
	scale, _ := Change(topo, lam, []float64{4})
	shift, _ := ChangeShift(topo, lam, []float64{4}, []bool{true})
	// scaled: cs2 stays 0.5; shifted: variance stays 0.5*100 = 50, so cs2 = 50/196
	want, _ := ResidenceRouted(14, lam, 2, Pooled, 1, 0.5, 1)
	near(t, "scaled time", scale.Patched.R[0], want, 1e-13)
	wantShift, _ := ResidenceRouted(14, lam, 2, Pooled, 1, 0.5*100/196, 1)
	near(t, "shifted time", shift.Patched.R[0], wantShift, 1e-13)
	if shift.Patched.R[0] >= scale.Patched.R[0] {
		t.Error("a constant shift adds less wait than scaling the time")
	}
	// no shift flags -> identical to Change
	same, _ := ChangeShift(topo, lam, []float64{4}, nil)
	near(t, "nil shift", same.Patched.R[0], scale.Patched.R[0], 0)
}

func TestRefinedModelReducesToPlainWhereItShould(t *testing.T) {
	// one queue with Poisson input: nothing to refine
	topo, _ := ParseTopology([]byte(`{"entry":{"a":1},"services":[{"name":"a","s":10,"cs2":0.4,"servers":2}]}`))
	p, _ := AnalyticWith(topo, 0.1, nil, Plain)
	d, _ := AnalyticWith(topo, 0.1, nil, Default)
	near(t, "single queue", d.L[0], p.L[0], 1e-12)
	// M/M/1 -> M/M/1: departures of M/M/1 are Poisson (Burke), so the refinement changes nothing
	chain, _ := ParseTopology([]byte(`{"entry":{"a":1},"services":[{"name":"a","s":8,"children":["b"]},{"name":"b","s":10}]}`))
	p, _ = AnalyticWith(chain, 0.07, nil, Plain)
	d, _ = AnalyticWith(chain, 0.07, nil, Default)
	near(t, "Burke", d.L[0], p.L[0], 1e-12)
	// a regular server smooths its departures: the queue behind it waits less
	reg, _ := ParseTopology([]byte(`{"entry":{"a":1},"services":[{"name":"a","s":8,"cs2":0.1,"children":["b"]},{"name":"b","s":10}]}`))
	p, _ = AnalyticWith(reg, 0.07, nil, Plain)
	d, _ = AnalyticWith(reg, 0.07, nil, Default)
	if !(d.R[1] < p.R[1]) || d.Ca2[1] >= 1 {
		t.Errorf("b should see smoother arrivals: ca2=%.3f, wait %.3f vs %.3f", d.Ca2[1], d.R[1], p.R[1])
	}
	// a bursty server does the opposite
	bur, _ := ParseTopology([]byte(`{"entry":{"a":1},"services":[{"name":"a","s":8,"cs2":4,"children":["b"]},{"name":"b","s":10}]}`))
	p, _ = AnalyticWith(bur, 0.07, nil, Plain)
	d, _ = AnalyticWith(bur, 0.07, nil, Default)
	if !(d.R[1] > p.R[1]) || d.Ca2[1] <= 1 {
		t.Errorf("b should see burstier arrivals: ca2=%.3f", d.Ca2[1])
	}
}

// A NaN must never come out as a stable result, even from inputs that bypass
// Finish's checks; an infinite residence is unstable.
func TestNaNIsNeverStable(t *testing.T) {
	mk := func(edit func([]Service)) *Topology {
		topo, err := ParseTopology([]byte(`{"entry":{"a":1},"services":[{"name":"a","s":10,"parallel":true,"children":["b","c"]},
			{"name":"b","s":5,"servers":2},{"name":"c","s":4}]}`))
		if err != nil {
			t.Fatal(err)
		}
		edit(topo.Services)
		return topo
	}
	for name, c := range map[string]struct {
		topo *Topology
		lam  float64
	}{
		"NaN cs2":           {mk(func(s []Service) { s[1].CS2 = math.NaN() }), 0.05},
		"infinite S, idle":  {mk(func(s []Service) { s[1].S = math.Inf(1) }), 0},
		"infinite S, alive": {mk(func(s []Service) { s[1].S = math.Inf(1) }), 0.05},
		"no workers, idle":  {mk(func(s []Service) { s[1].Servers, s[1].Workers = 0, 0 }), 0},
		"NaN branch corr":   {mk(func(s []Service) { s[0].BranchCorr = math.NaN() }), 0.05},
	} {
		for _, cfg := range []Config{Plain, Default} {
			r, err := AnalyticWith(c.topo, c.lam, nil, cfg)
			if err == nil && r.Stable && !(IsFinite(r.Rho) && IsFinite(r.R) && IsFinite(r.V) && IsFinite(r.L)) {
				t.Errorf("%s: reported stable with rho %v, R %v, L %v", name, r.Rho, r.R, r.L)
			}
		}
	}
	if !math.IsNaN(ErlangC(4, math.NaN())) {
		t.Error("ErlangC of a NaN load should be NaN")
	}
}
