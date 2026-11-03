// SPDX-License-Identifier: Apache-2.0

package model

import (
	"math"
	"testing"
)

// Two callers of one service x with two routes: a cheap /item (2 ms, no calls) that caller a reaches, and a dear
// /search (10 ms, then a call to d) that caller b reaches. The queue sees the blend; each caller waits for its route.
func routedTopology(t *testing.T, withRoutes bool) *Topology {
	t.Helper()
	topo := &Topology{Services: []Service{
		{Name: "a", S: 1, CS2: 1, Servers: 1, Workers: 1, Routing: Pooled, Calls: []Call{{Child: 2, P: 1}}},
		{Name: "b", S: 1, CS2: 1, Servers: 1, Workers: 1, Routing: Pooled, Calls: []Call{{Child: 2, P: 1}}},
		{Name: "x", S: 0.75*2 + 0.25*10, CS2: 1, Servers: 2, Workers: 1, Routing: Pooled, Calls: []Call{{Child: 3, P: 0.25}}},
		{Name: "d", S: 5, CS2: 1, Servers: 1, Workers: 1, Routing: Pooled},
	}, Entry: map[int]float64{0: 3, 1: 1}}
	if withRoutes {
		topo.Services[2].Routes = []Route{{Name: "GET /item", Share: 0.75, S: 2, CS2: 1, P: []float64{0}},
			{Name: "GET /search", Share: 0.25, S: 10, CS2: 1, P: []float64{1}}}
		topo.Services[0].Calls[0].RouteQ = []float64{1, 0}
		topo.Services[1].Calls[0].RouteQ = []float64{0, 1}
	}
	if err := topo.Finish(); err != nil {
		t.Fatal(err)
	}
	return topo
}

func TestRoutesReachEachCallersRoute(t *testing.T) {
	for _, cfg := range []Config{Plain, Default} {
		blend, err := AnalyticWith(routedTopology(t, false), 0.05, nil, cfg)
		if err != nil {
			t.Fatal(err)
		}
		routed, err := AnalyticWith(routedTopology(t, true), 0.05, nil, cfg)
		if err != nil {
			t.Fatal(err)
		}
		// the queues are the same: routes move no load
		for i := range blend.R {
			if blend.R[i] != routed.R[i] || blend.Rho[i] != routed.Rho[i] {
				t.Fatalf("node %d: residence or load moved with routes", i)
			}
		}
		wx := blend.R[2] - 4.0 // x's wait
		la := routed.L[0] - blend.R[0]
		lb := routed.L[1] - blend.R[1]
		if math.Abs(la-(wx+2)) > 1e-9 {
			t.Errorf("a reaches /item: %v, want wait + 2 = %v", la, wx+2)
		}
		if math.Abs(lb-(wx+10+blend.L[3])) > 1e-9 {
			t.Errorf("b reaches /search: %v, want wait + 10 + d = %v", lb, wx+10+blend.L[3])
		}
		// a caller that reaches the routes in their shares sees the blend
		if math.Abs(blend.L[2]-routed.L[2]) > 1e-12 {
			t.Errorf("x's own latency moved: %v vs %v", routed.L[2], blend.L[2])
		}
	}
}

func TestRouteWeightsAreChecked(t *testing.T) {
	topo := routedTopology(t, true)
	topo.Services[0].Calls[0].RouteQ = []float64{0.5, 0.2}
	if err := topo.Finish(); err == nil {
		t.Fatal("route weights that do not sum to 1 were taken")
	}
	topo = routedTopology(t, true)
	topo.Services[2].Routes[1].P = nil
	if err := topo.Finish(); err == nil {
		t.Fatal("a route without its call chances was taken")
	}
}

// The catalog example of lean/Rbproofs/Routes.lean: /item (share 3/4, 2 ms, no calls) and /search (share 1/4, 10 ms,
// both shard calls, each 3 ms with variance 1), scv 1. The blend model's variance from the routes is 43.875; a caller
// of /item alone gets its route's 4 less that, one of /search alone 102 less that, and a caller in the shares gets
// the mixture's 65.25 less that: the between-route covariance the blend drops (21.375), not 0. A caller without
// route weights is taken at the shares.
func TestRouteVarianceAgainstTheBlendModel(t *testing.T) {
	topo := &Topology{Services: []Service{
		{Name: "x", S: 4, CS2: 2.5, Servers: 1, Workers: 1, Routing: Pooled,
			Calls: []Call{{Child: 1, P: 0.25, HasHop: true}, {Child: 2, P: 0.25, HasHop: true}},
			Routes: []Route{{Name: "GET /item", Share: 0.75, S: 2, CS2: 1, P: []float64{0, 0}},
				{Name: "GET /search", Share: 0.25, S: 10, CS2: 1, P: []float64{1, 1}}}},
		{Name: "d1", S: 3, CS2: 1, Servers: 1, Workers: 1, Routing: Pooled},
		{Name: "d2", S: 3, CS2: 1, Servers: 1, Workers: 1, Routing: Pooled},
	}}
	l, vl := []float64{0, 3, 3}, []float64{0, 1, 1}
	for _, c := range []struct {
		q      []float64
		dm, dv float64
	}{{[]float64{1, 0}, 2 - 5.5, 4 - 43.875}, {[]float64{0, 1}, 16 - 5.5, 102 - 43.875}, {[]float64{0.75, 0.25}, 0, 65.25 - 43.875},
		{nil, 0, 65.25 - 43.875}} {
		dm, dv := topo.RouteAdj(0, c.q, l, vl, nil, nil)
		if math.Abs(dm-c.dm) > 1e-9 || math.Abs(dv-c.dv) > 1e-9 {
			t.Errorf("q %v: dm, dv = %v, %v; want %v, %v", c.q, dm, dv, c.dm, c.dv)
		}
	}
}
