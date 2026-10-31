package main

import (
	"math"
	"math/rand/v2"
	"testing"
)

// arrivals counts the thinned arrivals of a pattern over secs, as main draws them.
func arrivals(t *testing.T, p string, rps, secs float64, from, to float64) float64 {
	t.Helper()
	rate, lmax := pattern(p, rps, secs, 7)
	rng := rand.New(rand.NewPCG(7, 1))
	n := 0.0
	for x := 0.0; ; {
		x += rng.ExpFloat64() / lmax
		if x >= secs {
			break
		}
		if rate != nil && rng.Float64()*lmax >= rate(x) {
			continue
		}
		if x >= from && x < to {
			n++
		}
	}
	return n / (to - from)
}

func TestPatternsKeepTheirRates(t *testing.T) {
	if r, l := pattern("", 100, 600, 7); r != nil || l != 100 {
		t.Fatal("no pattern must leave the Poisson schedule alone")
	}
	if got := arrivals(t, "mmpp:4:5:20", 100, 20000, 0, 20000); math.Abs(got/100-1) > 0.05 {
		t.Fatalf("mmpp mean rate %.1f, want 100", got)
	}
	if got := arrivals(t, "ramp:0.5:1.5", 100, 6000, 0, 600); math.Abs(got/55-1) > 0.08 {
		t.Fatalf("ramp's first tenth %.1f, want about 55", got)
	}
	if got := arrivals(t, "step:300:2", 100, 6000, 300, 6000); math.Abs(got/200-1) > 0.05 {
		t.Fatalf("after the step %.1f, want 200", got)
	}
}
