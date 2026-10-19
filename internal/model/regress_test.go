// SPDX-License-Identifier: Apache-2.0

package model

// Regression tests: each failed at 094b99a, or at 29a7ed9 where said.

import (
	"fmt"
	"math"
	"strings"
	"testing"
)

// ErlangC's forward sum overflowed once a > ~709 erlangs (term ~ a^k/k! ~ e^a).
func TestErlangCLargePools(t *testing.T) {
	for _, c := range []int{720, 1000, 2000, 100000} {
		for _, rho := range []float64{0.75, 0.9, 0.99} {
			v := ErlangC(c, rho*float64(c))
			if math.IsNaN(v) || v < 0 || v > 1 {
				t.Errorf("ErlangC(%d, %.0f) = %v", c, rho*float64(c), v)
			}
		}
	}
	// a pooled service of 1000 workers at 75%: the model must not return NaN
	topo, err := ParseTopology([]byte(`{"entry":{"a":1},"services":[{"name":"a","s":10,"servers":1000}]}`))
	if err != nil {
		t.Fatal(err)
	}
	r, err := AnalyticWith(topo, 75, nil, Default)
	if err != nil {
		t.Fatal(err)
	}
	if !r.Stable || !IsFinite(r.L) {
		t.Errorf("1000 pooled workers at 75%%: stable=%v L=%v", r.Stable, r.L)
	}
}

// The topological order was built from map iteration; with three parents of one
// service the floating-point sums ran in a different order from run to run.
func TestOrderIsDeterministic(t *testing.T) {
	src := `{"entry":{"a":1},"services":[
	 {"name":"a","s":2,"cs2":2.7,"children":[{"name":"b","p":0.3},{"name":"c","p":0.7},{"name":"d","p":0.1},"x"]},
	 {"name":"x","s":1.3,"cs2":0.4,"children":[{"name":"b","p":0.9},{"name":"c","p":0.33},{"name":"d","p":0.77}]},
	 {"name":"b","s":3.1,"cs2":0.3,"children":["e"]},
	 {"name":"c","s":2.9,"cs2":3.3,"children":["e"]},
	 {"name":"d","s":4.7,"cs2":1.7,"children":["e"]},
	 {"name":"e","s":1.1,"cs2":0.9}]}`
	var first []int
	var firstL float64
	for i := 0; i < 300; i++ {
		topo, err := ParseTopology([]byte(src))
		if err != nil {
			t.Fatal(err)
		}
		r, err := AnalyticWith(topo, 0.1, nil, Default)
		if err != nil || !r.Stable {
			t.Fatal(err)
		}
		if i == 0 {
			first, firstL = append([]int(nil), topo.Order()...), r.L[0]
			continue
		}
		o := topo.Order()
		for k := range o {
			if o[k] != first[k] {
				t.Fatalf("run %d: order %v, first run %v", i, o, first)
			}
		}
		if r.L[0] != firstL {
			t.Fatalf("run %d: L = %.17g, first run %.17g", i, r.L[0], firstL)
		}
	}
}

// Negative cs2, hop, entry weights or servers, and branch_corr above 1, were accepted.
func TestTopologyRejectsNegativeInputs(t *testing.T) {
	for _, src := range []string{
		`{"entry":{"a":1},"services":[{"name":"a","s":10,"cs2":-3}]}`,
		`{"entry":{"a":1},"services":[{"name":"a","s":10,"hop":-1}]}`,
		`{"entry":{"a":-1},"services":[{"name":"a","s":10}]}`,
		`{"entry":{"a":1},"services":[{"name":"a","s":10,"servers":-2}]}`,
		`{"entry":{"a":1},"services":[{"name":"a","s":10,"branch_corr":1.5}]}`,
	} {
		if _, err := ParseTopology([]byte(src)); err == nil {
			t.Errorf("accepted %s", src)
		}
	}
}

// MaxRho skipped NaN utilizations and could return index -1.
func TestMaxRhoWithNaN(t *testing.T) {
	r := &Result{Rho: []float64{math.NaN(), math.NaN()}}
	if _, at := r.MaxRho(); at < 0 {
		t.Errorf("MaxRho returned index %d", at)
	}
	r = &Result{Rho: []float64{0.5, math.NaN()}}
	if mr, _ := r.MaxRho(); !math.IsNaN(mr) {
		t.Errorf("a NaN utilization is hidden by MaxRho (got %v)", mr)
	}
}

// AnalyticWith accepted a non-finite external rate and returned a "stable" NaN result.
func TestAnalyticRejectsNonFiniteRate(t *testing.T) {
	topo, _ := ParseTopology([]byte(`{"entry":{"a":1},"services":[{"name":"a","s":10}]}`))
	for _, lam := range []float64{math.NaN(), math.Inf(1), -0.1} {
		r, err := AnalyticWith(topo, lam, nil, Default)
		if err == nil && r.Stable {
			t.Errorf("lam %v: stable result %v", lam, r.L)
		}
	}
}

// ChangeShiftWith indexed ds and shift without checking them.
func TestChangeShiftArgumentChecks(t *testing.T) {
	topo, _ := ParseTopology([]byte(`{"entry":{"a":1},"services":[{"name":"a","s":10}]}`))
	defer func() {
		if p := recover(); p != nil {
			t.Errorf("panic: %v", p)
		}
	}()
	if _, err := ChangeShiftWith(topo, 0.05, nil, []bool{true}, Default); err == nil {
		t.Log("nil ds with a shift mask: accepted")
	}
	if _, err := ChangeShiftWith(topo, 0.05, []float64{1}, []bool{}, Default); err == nil {
		t.Error("a short shift mask should be refused")
	}
}

// The numerics review at 29a7ed9: an arrival weight above 1 over-shoots QNA. A smooth upstream (cs2 0, 95% busy) feeding a
// regular child gave the child ca2 -0.35 at w = 1.5, its residence -2.4 ms against 1 ms of service, a negative
// latency, all reported as stable.
func TestArrivalWeightAboveOneIsRefused(t *testing.T) {
	topo, err := ParseTopology([]byte(`{"entry":{"a":1},"services":[{"name":"a","s":1,"cs2":0,"children":["b"]},
	 {"name":"b","s":1,"cs2":0}]}`))
	if err != nil {
		t.Fatal(err)
	}
	for _, w := range []float64{1.5, 2, 5} {
		if r, err := AnalyticWith(topo, 0.95, nil, Config{ArrivalWeight: w, MatchedMax: true}); err == nil {
			t.Errorf("weight %v: no error (R %v, L %v, stable %v)", w, r.R, r.L, r.Stable)
		}
	}
	r, err := AnalyticWith(topo, 0.95, nil, Config{ArrivalWeight: 1})
	if err != nil || !(r.R[1] >= 1) {
		t.Errorf("weight 1: R %v, err %v", r, err)
	}
}

// The numerics review at 29a7ed9: a parallel fan-out to more than 12 zero-time branches gave NaN in the basic model (the
// quadrature's range was 50 times the largest mean, 0), refused as "an input is out of range".
func TestFanOutToZeroTimeBranches(t *testing.T) {
	for _, slow := range []bool{false, true} {
		var names []string
		svcs := []string{}
		for i := 0; i < 13; i++ {
			names = append(names, fmt.Sprintf(`"k%d"`, i))
			svcs = append(svcs, fmt.Sprintf(`{"name":"k%d","s":0}`, i))
		}
		if slow {
			names = append(names, `"slow"`)
			svcs = append(svcs, `{"name":"slow","s":1}`)
		}
		doc := fmt.Sprintf(`{"entry":{"root":1},"services":[{"name":"root","s":1,"parallel":true,"children":[%s]},%s]}`,
			strings.Join(names, ","), strings.Join(svcs, ","))
		topo, err := ParseTopology([]byte(doc))
		if err != nil {
			t.Fatal(err)
		}
		for _, cfg := range []Config{Plain, Default} {
			r, err := AnalyticWith(topo, 0.5, nil, cfg)
			if err != nil {
				t.Errorf("slow child %v, %+v: %v", slow, cfg, err)
				continue
			}
			want := 2.0 // the root's residence at 50% busy, plus the slow child's latency if there is one
			if slow {
				want += r.L[topo.Index("slow")]
			}
			if math.Abs(r.L[0]-want) > 1e-12*want {
				t.Errorf("slow child %v, %+v: root latency %.17g, want %.17g", slow, cfg, r.L[0], want)
			}
		}
	}
}

// The numerics review at 29a7ed9: a constant-shift patch that takes all but 1e-8 ms of a parallel branch's 10 ms away keeps
// its variance, so its scv reaches 4e9, and the matched maximum's grid, stretched to that branch's tail, had no
// point inside the other branch: E[max] came out 2.3-2.6 ms, below the other branch's 6.25 ms, with Stable true.
func TestShiftPatchKeepsTheMaxAboveEveryBranch(t *testing.T) {
	topo, err := ParseTopology([]byte(`{"entry":{"a":1},"services":[{"name":"a","s":1,"parallel":true,"children":["b","c"]},
	 {"name":"b","s":10,"cs2":1},{"name":"c","s":5,"cs2":0.5}]}`))
	if err != nil {
		t.Fatal(err)
	}
	for _, x := range []float64{5, 9.99, 9.99999, 9.9999999, 9.99999999, 9.999999999} {
		for _, bc := range []float64{0, 0.5} {
			topo.Services[0].BranchCorr = bc
			d, err := ChangeShiftWith(topo, 0.05, []float64{0, -x, 0}, []bool{false, true, false}, Default)
			if err != nil || !d.Stable {
				t.Fatalf("b -%v ms: %v", x, err)
			}
			p := d.Patched
			emax := p.L[0] - p.R[0]
			if top := math.Max(p.L[1], p.L[2]); emax < top {
				t.Errorf("b -%v ms, r %v: E[max] %.8g below the larger branch's mean %.8g", x, bc, emax, top)
			}
		}
	}
}

// A shift patch that takes all but 1e-12 ms of a parallel branch's 10 ms leaves it its variance: scv 1e26, floored to
// a gamma whose mean is still the branch's. The code review (the numerics review's shift probe) found the fan-out's E[max]
// at 9.905 (r 0.5) and 8.874 (r 0) at 5b71d67, above the sum of the branch means, 2.5 + 6.25 = 8.75: the maximum of
// non-negative branches cannot pass their sum.
func TestShiftedBranchMaxNotAboveTheSum(t *testing.T) {
	for _, r := range []float64{0, 0.5} {
		topo := &Topology{Name: "cs", Entry: map[int]float64{0: 1}, Services: []Service{
			{Name: "a", S: 1, CS2: 1, Parallel: true, BranchCorr: r, Calls: []Call{{Child: 1, P: 1}, {Child: 2, P: 1}}},
			{Name: "b", S: 10, CS2: 1}, {Name: "c", S: 5, CS2: 0.5}}}
		if err := topo.Finish(); err != nil {
			t.Fatal(err)
		}
		for _, x := range []float64{9.99999999, 9.999999999999} {
			d, err := ChangePatchWith(topo, 0.05, Patch{DS: []float64{0, -x, 0}, Shift: []bool{false, true, false}}, Default)
			if err != nil || !d.Stable {
				t.Fatalf("r %v, b -%v ms: %v", r, x, err)
			}
			p := d.Patched
			emax, sum := p.L[0]-p.R[0], p.L[1]+p.L[2]
			if !(emax <= sum*(1+1e-15)) {
				t.Errorf("r %v, b -%v ms: E[max] %.10g above the sum of the branch means %.10g", r, x, emax, sum)
			}
		}
	}
}
