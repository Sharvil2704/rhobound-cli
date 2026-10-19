// SPDX-License-Identifier: Apache-2.0

package model

import (
	"math"
	"strings"
	"testing"
)

// sharesTopo is a -> b, b on two replicas that take 70% and 30% of its visits.
const sharesTopo = `{"name":"shares","entry":{"a":1},"services":[
 {"name":"a","s":2,"children":["b"]},
 {"name":"b","s":10,"routing":"random","shares":[0.7,0.3]}]}`

// With exponential service and Poisson arrivals each replica is an M/M/1 queue fed its share: residence
// s/(1-rho_k), exponential, so a visit's residence has mean sum p_k R_k and second moment sum p_k 2 R_k^2.
func TestSharesAreMM1PerReplica(t *testing.T) {
	topo, err := ParseTopology([]byte(sharesTopo))
	if err != nil {
		t.Fatal(err)
	}
	b := topo.Index("b")
	if topo.Services[b].Servers != 2 {
		t.Fatalf("servers default to the number of shares: got %d", topo.Services[b].Servers)
	}
	const s, lam = 10.0, 0.1 // per ms: the busy replica at 70%, the other at 30%
	ps := []float64{0.7, 0.3}
	mean, m2 := 0.0, 0.0
	for _, p := range ps {
		r := s / (1 - lam*p*s)
		mean += p * r
		m2 += p * 2 * r * r
	}
	for _, cfg := range []Config{Plain, {MatchedMax: true}} {
		r, err := AnalyticWith(topo, lam, nil, cfg)
		if err != nil || !r.Stable {
			t.Fatalf("%+v: %v", cfg, err)
		}
		near(t, "residence", r.R[b], mean, 1e-13)
		near(t, "utilization is the busiest replica's", r.Rho[b], 0.7, 1e-14)
		near(t, "entry latency", r.L[0], 2/(1-lam*2)+mean, 1e-13)
		if cfg.MatchedMax {
			near(t, "residence variance", r.V[b], m2-mean*mean, 1e-12)
		}
	}
	// even shares are the even split (not bit for bit: they take another path)
	even, _ := ParseTopology([]byte(strings.Replace(sharesTopo, "[0.7,0.3]", "[0.5,0.5]", 1)))
	none, _ := ParseTopology([]byte(strings.Replace(sharesTopo, `,"shares":[0.7,0.3]`, `,"servers":2`, 1)))
	for _, cfg := range []Config{Plain, Default} {
		re, _ := AnalyticWith(even, lam, nil, cfg)
		rn, _ := AnalyticWith(none, lam, nil, cfg)
		for i := range re.L {
			near(t, "even shares: L", re.L[i], rn.L[i], 1e-12)
			near(t, "even shares: rho", re.Rho[i], rn.Rho[i], 1e-14)
		}
	}
	// a replica past saturation is unstable, though the service as a whole is at 73%
	r, err := AnalyticWith(topo, 0.145, nil, Plain)
	if err != nil {
		t.Fatal(err)
	}
	if r.Stable || r.Rho[b] < 1 {
		t.Errorf("the busy replica at %.3f should make the model unstable", r.Rho[b])
	}
}

// A change keeps the shares: a constant +3 ms makes each replica an M/G/1 queue (Pollaczek-Khinchine) with
// the same share of the traffic.
func TestChangeKeepsTheShares(t *testing.T) {
	topo, err := ParseTopology([]byte(sharesTopo))
	if err != nil {
		t.Fatal(err)
	}
	b := topo.Index("b")
	const s, lam, ds = 10.0, 0.08, 3.0
	s2, cs2 := s+ds, s*s/((s+ds)*(s+ds))
	want := 0.0
	for _, p := range []float64{0.7, 0.3} {
		l := lam * p
		want += p * (s2 + l*s2*s2*(1+cs2)/(2*(1-l*s2)))
	}
	d, err := ChangeShift(topo, lam, []float64{0, ds}, []bool{false, true})
	if err != nil || !d.Stable {
		t.Fatalf("change: %v", err)
	}
	near(t, "patched residence", d.Patched.R[b], want, 1e-13)
	if len(topo.Services[b].Shares) != 2 || topo.Services[b].Shares[0] != 0.7 {
		t.Errorf("the change altered the topology's shares: %v", topo.Services[b].Shares)
	}
}

// The departures of a service with shares are its replicas' departures merged: with Poisson arrivals and
// one worker each, replica k sends out 1 + rho_k^2 (cs2 - 1) (Whitt's QNA), weighted by its share.
func TestSharesDepartures(t *testing.T) {
	topo, err := ParseTopology([]byte(`{"entry":{"a":1},"services":[
	 {"name":"a","s":10,"cs2":0.25,"routing":"random","shares":[0.7,0.3],"children":["b"]},
	 {"name":"b","s":1}]}`))
	if err != nil {
		t.Fatal(err)
	}
	const lam = 0.1
	r, err := AnalyticWith(topo, lam, nil, Config{ArrivalWeight: 1})
	if err != nil || !r.Stable {
		t.Fatal(err)
	}
	want := 0.0
	for _, p := range []float64{0.7, 0.3} {
		rho := lam * p * 10
		want += p * (1 + rho*rho*(0.25-1))
	}
	near(t, "arrival variability at b", r.Ca2[topo.Index("b")], want, 1e-14)
}

func TestSharesAreChecked(t *testing.T) {
	for _, c := range []struct{ svc, want string }{
		{`"s":1,"routing":"random","shares":[0.7,0.2]`, "sum to"},
		{`"s":1,"routing":"random","shares":[1.2,-0.2]`, "positive"},
		{`"s":1,"routing":"random","servers":3,"shares":[0.5,0.5]`, "2 replica shares for 3"},
		{`"s":1,"routing":"random","shares":[1]`, "two or more"},
		{`"s":1,"shares":[0.5,0.5]`, "random routing"},
		{`"s":1,"delay":true,"routing":"random","shares":[0.5,0.5]`, "delay"},
	} {
		_, err := ParseTopology([]byte(`{"entry":{"a":1},"services":[{"name":"a",` + c.svc + `}]}`))
		if err == nil || !strings.Contains(err.Error(), c.want) {
			t.Errorf("%s: got %v, want an error with %q", c.svc, err, c.want)
		}
	}
	topo, _ := ParseTopology([]byte(sharesTopo))
	out, err := MarshalTopology(topo)
	if err != nil {
		t.Fatal(err)
	}
	back, err := ParseTopology(out)
	if err != nil {
		t.Fatal(err)
	}
	if sh := back.Services[back.Index("b")].Shares; len(sh) != 2 || sh[0] != 0.7 || sh[1] != 0.3 {
		t.Errorf("shares do not survive a round trip: %s", out)
	}
	if strings.Count(string(out), `"shares":`) != 1 {
		t.Errorf("a service without shares writes none: %s", out)
	}
}

// An arrival weight of 0 is 0: Poisson arrivals at every queue, the basic model's.
func TestArrivalWeightZeroIsZero(t *testing.T) {
	topo, err := ParseTopology([]byte(`{"entry":{"a":1},"services":[
	 {"name":"a","s":4,"cs2":4,"children":["b"]},
	 {"name":"b","s":5,"cs2":0.2}]}`))
	if err != nil {
		t.Fatal(err)
	}
	const lam = 0.12
	plain, _ := AnalyticWith(topo, lam, nil, Plain)
	zero, _ := AnalyticWith(topo, lam, nil, Config{ArrivalWeight: 0})
	one, _ := AnalyticWith(topo, lam, nil, Config{ArrivalWeight: 1})
	for i := range plain.R {
		if zero.R[i] != plain.R[i] || zero.Ca2[i] != 1 {
			t.Errorf("weight 0, %s: R %v ca2 %v, want the basic model's R %v and ca2 1", topo.Services[i].Name, zero.R[i], zero.Ca2[i], plain.R[i])
		}
	}
	if !(one.Ca2[1] > 1.5) {
		t.Errorf("weight 1: b should see bursty arrivals after a (cs2 4), got ca2 %v", one.Ca2[1])
	}
	for _, w := range []float64{-0.1, math.NaN(), math.Inf(1), 1.5, 2} {
		if _, err := AnalyticWith(topo, lam, nil, Config{ArrivalWeight: w}); err == nil {
			t.Errorf("arrival weight %v should be refused", w)
		}
	}
}
