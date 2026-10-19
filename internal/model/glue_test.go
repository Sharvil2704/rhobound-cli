// SPDX-License-Identifier: Apache-2.0

package model

import (
	"math"
	"testing"
)

// glueTopo is r -> (p || q), p -> b then c (sequential), q -> b and c in parallel.
const glueTopo = `{"name":"glue","entry":{"r":1},"services":[
 {"name":"r","s":1,"children":["p","q"],"parallel":true},
 {"name":"p","s":2,"children":["b","c"]},
 {"name":"q","s":2,"children":["b","c"],"parallel":true},
 {"name":"b","s":3,"cs2":0.5,"hop":0.3},
 {"name":"c","s":4,"servers":2,"hop":0.3}]}`

// Glue is a delay once a service's calls are done: it adds its mean to the service's latency and to every
// caller that waits for it in turn, and changes no queue (rates, utilizations, residences).
func TestGlueIsADelayAfterTheCalls(t *testing.T) {
	const g = 1.7
	for _, cfg := range []Config{Plain, Default} {
		for _, at := range []string{"p", "q", "b"} {
			topo, err := ParseTopology([]byte(glueTopo))
			if err != nil {
				t.Fatal(err)
			}
			r0, err := AnalyticWith(topo, 0.05, nil, cfg)
			if err != nil || !r0.Stable {
				t.Fatalf("base: %v", err)
			}
			i := topo.Index(at)
			topo.Services[i].Glue = g
			r1, err := AnalyticWith(topo, 0.05, nil, cfg)
			if err != nil || !r1.Stable {
				t.Fatalf("glue at %s: %v", at, err)
			}
			near(t, at+": its latency rises by the glue", r1.L[i]-r0.L[i], g, 1e-13)
			if at == "b" {
				near(t, "p calls b in turn", r1.L[topo.Index("p")]-r0.L[topo.Index("p")], g, 1e-13)
			}
			for j := range r0.R {
				if r1.R[j] != r0.R[j] || r1.Rho[j] != r0.Rho[j] || r1.Ca2[j] != r0.Ca2[j] {
					t.Errorf("glue at %s changed %s's queue", at, topo.Services[j].Name)
				}
			}
		}
	}
}

// For a service whose calls are sequential the reference writes glue as a delay service glue:<name> called
// last; the glue field gives the same latencies, the variance carried to a parallel caller included.
func TestGlueMatchesTheReferenceDelayNode(t *testing.T) {
	field, err := ParseTopology([]byte(`{"entry":{"r":1},"services":[
	 {"name":"r","s":1,"children":["p","x"],"parallel":true},
	 {"name":"p","s":2,"children":["b"],"glue":3,"glue_cs2":0.4},
	 {"name":"x","s":9},
	 {"name":"b","s":3,"cs2":0.5,"hop":0.3}]}`))
	if err != nil {
		t.Fatal(err)
	}
	node, err := ParseTopology([]byte(`{"entry":{"r":1},"services":[
	 {"name":"r","s":1,"children":["p","x"],"parallel":true},
	 {"name":"p","s":2,"children":["b","glue:p"]},
	 {"name":"x","s":9},
	 {"name":"b","s":3,"cs2":0.5,"hop":0.3},
	 {"name":"glue:p","s":3,"cs2":0.4,"delay":true}]}`))
	if err != nil {
		t.Fatal(err)
	}
	for _, cfg := range []Config{Plain, Default} {
		a, err1 := AnalyticWith(field, 0.06, nil, cfg)
		b, err2 := AnalyticWith(node, 0.06, nil, cfg)
		if err1 != nil || err2 != nil || !a.Stable || !b.Stable {
			t.Fatalf("%v %v", err1, err2)
		}
		for _, name := range []string{"r", "p", "x", "b"} {
			near(t, name, a.L[field.Index(name)], b.L[node.Index(name)], 1e-12)
		}
	}
}

func TestGlueRoundTripAndChecks(t *testing.T) {
	topo, err := ParseTopology([]byte(glueTopo))
	if err != nil {
		t.Fatal(err)
	}
	topo.Services[1].Glue, topo.Services[1].GlueCS2 = 2.5, 0.25
	raw, err := MarshalTopology(topo)
	if err != nil {
		t.Fatal(err)
	}
	back, err := ParseTopology(raw)
	if err != nil {
		t.Fatal(err)
	}
	for i := range topo.Services {
		if back.Services[i].Glue != topo.Services[i].Glue || back.Services[i].GlueCS2 != topo.Services[i].GlueCS2 {
			t.Errorf("%s: glue %v/%v back as %v/%v", topo.Services[i].Name, topo.Services[i].Glue,
				topo.Services[i].GlueCS2, back.Services[i].Glue, back.Services[i].GlueCS2)
		}
	}
	for _, bad := range [][2]float64{{-1, 0}, {math.NaN(), 0}, {math.Inf(1), 0}, {1, -0.5}, {1, math.NaN()}} {
		topo.Services[1].Glue, topo.Services[1].GlueCS2 = bad[0], bad[1]
		if err := topo.Finish(); err == nil {
			t.Errorf("glue %v, glue_cs2 %v should be refused", bad[0], bad[1])
		}
	}
}
