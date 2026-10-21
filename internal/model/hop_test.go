// SPDX-License-Identifier: Apache-2.0

package model

import (
	"math"
	"strings"
	"testing"
)

// A callee reached over two links: a calls b and c, both call d. The hop of a call is the call's own when it has one
// and the callee's otherwise.
const perEdgeHops = `{"entry":{"a":1},"services":[
 {"name":"a","s":1,"children":["b","c"]},
 {"name":"b","s":1,"children":[{"name":"d","hop":0.1}]},
 {"name":"c","s":1,"children":[{"name":"d","hop":0.5}]},
 {"name":"d","s":1,"hop":0.3}]}`

func TestCallHopIsThePerCallOneWhenGiven(t *testing.T) {
	topo, err := ParseTopology([]byte(perEdgeHops))
	if err != nil {
		t.Fatal(err)
	}
	b, c, d := topo.Index("b"), topo.Index("c"), topo.Index("d")
	if h := topo.CallHop(topo.Services[b].Calls[0]); h != 0.1 {
		t.Errorf("b -> d: hop %v, want 0.1", h)
	}
	if h := topo.CallHop(topo.Services[c].Calls[0]); h != 0.5 {
		t.Errorf("c -> d: hop %v, want 0.5", h)
	}
	if h := topo.CallHop(topo.Services[0].Calls[0]); h != topo.Services[b].Hop || h != 0 {
		t.Errorf("a -> b has no hop of its own: got %v, want b's hop 0", h)
	}
	// without a hop on the call, the callee's applies: the same topology with the hops left out and d's hop 0.3
	plain, err := ParseTopology([]byte(strings.NewReplacer(`{"name":"d","hop":0.1}`, `"d"`, `{"name":"d","hop":0.5}`, `"d"`).Replace(perEdgeHops)))
	if err != nil {
		t.Fatal(err)
	}
	r1, _ := Analytic(topo, 0.01, nil)
	r2, _ := Analytic(plain, 0.01, nil)
	// b's and c's latencies differ from the plain topology's by the call's hop less d's: -0.2 and +0.2
	near(t, "b", r1.L[b]-r2.L[b], 0.1-0.3, 1e-13)
	near(t, "c", r1.L[c]-r2.L[c], 0.5-0.3, 1e-13)
	near(t, "a (the two cancel)", r1.L[0]-r2.L[0], 0, 1e-13)
	_ = d
}

func TestCallHopInParallelCalls(t *testing.T) {
	doc := `{"entry":{"a":1},"services":[
	 {"name":"a","s":1,"parallel":true,"children":[{"name":"b","hop":2},{"name":"c","hop":0.5}]},
	 {"name":"b","s":1,"hop":0.1},{"name":"c","s":1,"hop":0.1}]}`
	topo, err := ParseTopology([]byte(doc))
	if err != nil {
		t.Fatal(err)
	}
	// delay-free leaves with the same latency: the slower branch is the one with the larger hop
	for name, cfg := range map[string]Config{"plain": Plain, "default": Default} {
		r, err := AnalyticWith(topo, 0.001, nil, cfg)
		if err != nil || !r.Stable {
			t.Fatal(err)
		}
		if got, floor := r.L[0], r.R[0]+2+r.R[1]; got < floor-1e-9 {
			t.Errorf("%s: a's latency %v is below the slower call's hop and latency %v", name, got, floor)
		}
	}
}

func TestCallHopRoundTripAndValidation(t *testing.T) {
	topo, err := ParseTopology([]byte(perEdgeHops))
	if err != nil {
		t.Fatal(err)
	}
	raw, err := MarshalTopology(topo)
	if err != nil {
		t.Fatal(err)
	}
	back, err := ParseTopology(raw)
	if err != nil {
		t.Fatalf("%v\n%s", err, raw)
	}
	for i := range topo.Services {
		for j, c := range topo.Services[i].Calls {
			if got := back.Services[i].Calls[j]; got != c {
				t.Errorf("%s call %d: %+v after a round trip, was %+v", topo.Services[i].Name, j, got, c)
			}
		}
	}
	// a call without a hop is still written as a bare name: only the two calls with a hop are objects (with a "p")
	if n := strings.Count(string(raw), `"p": 1`); n != 2 {
		t.Errorf("%d calls written as objects, want the 2 with a hop: %s", n, raw)
	}
	for name, hop := range map[string]string{"negative": "-0.1", "huge": "1e999"} {
		doc := strings.Replace(perEdgeHops, `"hop":0.1`, `"hop":`+hop, 1)
		if _, err := ParseTopology([]byte(doc)); err == nil {
			t.Errorf("%s hop: expected an error", name)
		}
	}
	// a hop set in code is checked by Finish
	topo.Services[1].Calls[0].Hop = math.NaN()
	if err := topo.Finish(); err == nil || !strings.Contains(err.Error(), "hop") {
		t.Errorf("a NaN call hop: %v", err)
	}
}
