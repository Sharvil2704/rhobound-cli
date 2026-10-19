// SPDX-License-Identifier: Apache-2.0

package model

// A call the service does not wait for (fire and forget, sent after the response) loads its child but is not on
// the service's latency path. The code review's async-int capture: fe (M/M/1, 10 ms,
// 60/s) calls analytics (exponential 200 ms) 50 ms after its span ended, on 30% of its visits. At 5b71d67 the
// call counted on fe's path, as every call did: fe's level +260.8%, and --patch analytics=+100ms moved fe by
// +34.92 ms, where the truth is 0.

import (
	"encoding/json"
	"strings"
	"testing"
)

const asyncTopo = `{"name":"async","entry":{"fe":1},"services":[
 {"name":"fe","s":10,"children":[{"name":"analytics","p":0.3,"async":true}]},
 {"name":"analytics","s":200,"servers":9}]}`

// the same graph without the call; analytics gets the same load as an entry of its own
const asyncFlat = `{"name":"flat","entry":{"fe":1,"analytics":0.3},"services":[
 {"name":"fe","s":10},
 {"name":"analytics","s":200,"servers":9}]}`

func TestAsyncCallLoadsTheChildOffThePath(t *testing.T) {
	topo, err := ParseTopology([]byte(asyncTopo))
	if err != nil {
		t.Fatal(err)
	}
	flat, err := ParseTopology([]byte(asyncFlat))
	if err != nil {
		t.Fatal(err)
	}
	fe, an := topo.Index("fe"), topo.Index("analytics")
	if c := topo.Services[fe].Calls; len(c) != 1 || !c[0].Async || c[0].P != 0.3 {
		t.Fatalf("fe's calls %+v, want one async call with p 0.3", c)
	}
	if v := topo.VisitRatios(); v[an] != 0.3 {
		t.Errorf("analytics visits %v per request, want 0.3 (an async call loads its child)", v[an])
	}
	lam := 0.06 // per ms
	for _, cfg := range []Config{Plain, Default} {
		r, err := AnalyticWith(topo, lam, nil, cfg)
		if err != nil || !r.Stable {
			t.Fatalf("%+v: %v", cfg, err)
		}
		f, err := AnalyticWith(flat, lam, nil, cfg)
		if err != nil || !f.Stable {
			t.Fatalf("%+v: %v", cfg, err)
		}
		if r.L[fe] != r.R[fe] || r.L[fe] != f.L[fe] {
			t.Errorf("%+v: fe's latency %.12g (residence %.12g), want its residence alone, as without the call (%.12g)",
				cfg, r.L[fe], r.R[fe], f.L[fe])
		}
		near(t, "analytics' arrival rate", r.Lam[an], 0.3*lam, 1e-15)
		near(t, "analytics' utilization", r.Rho[an], f.Rho[an], 1e-15)
		// a change at analytics does not reach fe; one at fe does
		d, err := ChangePatchWith(topo, lam, Patch{DS: []float64{0, 100}, Shift: []bool{false, true}}, cfg)
		if err != nil || !d.Stable {
			t.Fatalf("%+v: %v", cfg, err)
		}
		if d.DL[fe] != 0 || !(d.DL[an] > 100) {
			t.Errorf("%+v: analytics +100 ms moves fe by %v (want 0) and analytics by %v", cfg, d.DL[fe], d.DL[an])
		}
		d, err = ChangePatchWith(topo, lam, Patch{DS: []float64{3, 0}, Shift: []bool{true, false}}, cfg)
		if err != nil || !d.Stable || !(d.DL[fe] > 3) {
			t.Errorf("%+v: fe +3 ms gives %v at fe (%v)", cfg, d, err)
		}
	}
	// written and read back with the flag; a call without it is not async
	b, err := MarshalTopology(topo)
	if err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(string(b), `"async": true`) {
		t.Errorf("the async flag is not written:\n%s", b)
	}
	back, err := ParseTopology(b)
	if err != nil {
		t.Fatal(err)
	}
	if c := back.Services[back.Index("fe")].Calls; len(c) != 1 || !c[0].Async {
		t.Errorf("read back: %+v", c)
	}
	plain, _ := ParseTopology([]byte(chain))
	if b, _ := MarshalTopology(plain); strings.Contains(string(b), "async") {
		t.Errorf("a topology without async calls writes the flag:\n%s", b)
	}
	for _, s := range plain.Services {
		for _, c := range s.Calls {
			if c.Async {
				t.Errorf("%s: a plain child read as async", s.Name)
			}
		}
	}
	var doc map[string]any
	if err := json.Unmarshal(b, &doc); err != nil {
		t.Fatal(err)
	}
}

// A parallel service's async call takes no part in its fan-out: the latency is the one without it, and an async
// call with a probability below 1 beside the fan-out is accepted (a parallel branch with one is refused).
func TestAsyncCallBesideAParallelFanOut(t *testing.T) {
	const with = `{"name":"p","entry":{"a":1},"services":[
 {"name":"a","s":2,"parallel":true,"branch_corr":0.4,"children":["b","c",{"name":"d","p":0.5,"async":true}]},
 {"name":"b","s":10,"cs2":0.5},{"name":"c","s":6,"cs2":2},{"name":"d","s":30}]}`
	const without = `{"name":"p","entry":{"a":1,"d":0.5},"services":[
 {"name":"a","s":2,"parallel":true,"branch_corr":0.4,"children":["b","c"]},
 {"name":"b","s":10,"cs2":0.5},{"name":"c","s":6,"cs2":2},{"name":"d","s":30}]}`
	tw, err := ParseTopology([]byte(with))
	if err != nil {
		t.Fatalf("an async call with p 0.5 beside a fan-out: %v", err)
	}
	to, err := ParseTopology([]byte(without))
	if err != nil {
		t.Fatal(err)
	}
	for _, cfg := range []Config{Plain, Default} {
		rw, err := AnalyticWith(tw, 0.02, nil, cfg)
		if err != nil {
			t.Fatal(err)
		}
		ro, err := AnalyticWith(to, 0.02, nil, cfg)
		if err != nil {
			t.Fatal(err)
		}
		if rw.L[0] != ro.L[0] {
			t.Errorf("%+v: a's latency %.15g with the async call, %.15g without it", cfg, rw.L[0], ro.L[0])
		}
	}
	if _, err := ParseTopology([]byte(strings.Replace(with, `"p":0.5,"async":true`, `"p":0.5`, 1))); err == nil {
		t.Error("a parallel branch with p 0.5 should still be refused")
	}
}
