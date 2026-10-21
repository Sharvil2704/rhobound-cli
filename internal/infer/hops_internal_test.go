// SPDX-License-Identifier: Apache-2.0

package infer

import (
	"math"
	"math/rand"
	"slices"
	"testing"
)

// gapSample is n sorted gaps: base plus an exponential spread of mean jitter, and, on a share pWait of the calls, an
// exponential wait of mean waitMean.
func gapSample(rng *rand.Rand, n int, base, jitter, pWait, waitMean float64) []float64 {
	g := make([]float64, n)
	for i := range g {
		g[i] = base + rng.ExpFloat64()*jitter
		if rng.Float64() < pWait {
			g[i] += rng.ExpFloat64() * waitMean
		}
	}
	slices.Sort(g)
	return g
}

func meanOf(x []float64) float64 {
	s := 0.0
	for _, v := range x {
		s += v
	}
	return s / float64(len(x))
}

func TestHopFromGaps(t *testing.T) {
	rng := rand.New(rand.NewSource(5))

	// a quiet edge: 0.3 ms of network and a spread of mean 0.25 ms; the model's wait is 0.01 ms and the callee 2% busy.
	// The quietest tenth lies far below the mean network time; the hop is the mean gap less the wait.
	g := gapSample(rng, 8000, 0.3, 0.25, 0, 0)
	if p10 := g[len(g)/10]; p10 > 0.4 {
		t.Fatalf("test data: p10 %v", p10)
	}
	if h, fm := hopFromGaps(g, 0.01, 0.02); !fm || math.Abs(h-(meanOf(g)-0.01)) > 1e-12 {
		t.Errorf("quiet edge: hop %v (from the mean: %v), want the mean gap less the wait, %v", h, fm, meanOf(g)-0.01)
	}

	// a loaded edge: 70% of the calls wait 20 ms on average, the model says 14 ms: queueing explains the excess
	g = gapSample(rng, 8000, 0.3, 0.25, 0.7, 20)
	if h, fm := hopFromGaps(g, 14, 0.2); fm || h != g[len(g)/10] {
		t.Errorf("loaded edge: hop %v (from the mean: %v), want p10 %v", h, fm, g[len(g)/10])
	}

	// few calls: the quietest tenth, however quiet
	g = gapSample(rng, hopMinCalls-1, 0.3, 0.25, 0, 0)
	if h, fm := hopFromGaps(g, 0, 0.02); fm || h != g[len(g)/10] {
		t.Errorf("%d calls: hop %v (from the mean: %v), want p10 %v", len(g), h, fm, g[len(g)/10])
	}
	g = gapSample(rng, hopMinCalls, 0.3, 0.25, 0, 0)
	if _, fm := hopFromGaps(g, 0, 0.02); !fm {
		t.Errorf("%d calls: not from the mean", len(g))
	}

	// a busy callee: a model wait of 0 where the traces show a wait (a pod of several workers whose waits the model
	// understates) would make the hop the mean gap, which then holds the wait; above hopMaxRho the hop stays p10
	g = gapSample(rng, 8000, 0.3, 0.25, 0.7, 20)
	if h, fm := hopFromGaps(g, 0, hopMaxRho+0.01); fm || h != g[len(g)/10] {
		t.Errorf("busy callee: hop %v (from the mean: %v), want p10 %v", h, fm, g[len(g)/10])
	}
	if h, fm := hopFromGaps(g, 0, hopMaxRho); !fm || h != meanOf(g) {
		t.Errorf("callee at the limit: hop %v (from the mean: %v), want the mean %v", h, fm, meanOf(g))
	}
	if _, fm := hopFromGaps(g, 0, math.NaN()); fm {
		t.Error("a utilization that is not a number took the mean")
	}

	// no gaps at all, or all equal: nothing to read
	if h, fm := hopFromGaps(nil, 0, 0); h != 0 || fm {
		t.Errorf("no gaps: hop %v from the mean %v", h, fm)
	}
	same := slices.Repeat([]float64{0.4}, 100)
	if h, _ := hopFromGaps(same, 0.2, 0.1); h != 0.4 {
		t.Errorf("equal gaps: hop %v, want 0.4", h)
	}

	// the hop is never below p10 nor above the mean, whatever the model's wait and load
	for _, w := range []float64{0, 0.05, 0.1, 0.2, 1, 5, 50} {
		for _, rho := range []float64{0, 0.2, 0.3, 0.6} {
			g = gapSample(rng, 4000, 0.3, 0.25, 0.1, 2)
			h, _ := hopFromGaps(g, w, rho)
			if h < g[len(g)/10]-1e-12 || h > meanOf(g)+1e-12 {
				t.Errorf("wait %v, rho %v: hop %v outside [p10 %v, mean %v]", w, rho, h, g[len(g)/10], meanOf(g))
			}
		}
	}
}

// The documented limits of the mean-based hop: it is used on a callee at most 30% busy (the accuracy harness, which is
// build-tagged, is what justified the 30%), on an edge of at least 50 calls, when the model's wait explains at most three
// quarters of the excess of the mean over the quietest tenth. A change of any of them is a change of the rule, and of the
// docs that quote it.
func TestHopRuleLimitsAreTheDocumentedOnes(t *testing.T) {
	if hopMaxRho != 0.3 || hopMinCalls != 50 || hopQueueShare != 0.75 {
		t.Errorf("hopMaxRho %v, hopMinCalls %v, hopQueueShare %v; the docs say 0.3, 50 and 0.75", hopMaxRho, hopMinCalls, hopQueueShare)
	}
	// at the limit the mean is used and just past it the quietest tenth: no gap between them
	rng := rand.New(rand.NewSource(3))
	g := gapSample(rng, 4000, 0.3, 0.25, 0, 0)
	if _, fm := hopFromGaps(g, 0.01, hopMaxRho); !fm {
		t.Error("a callee at the limit does not take the mean")
	}
	if _, fm := hopFromGaps(g, 0.01, hopMaxRho+1e-9); fm {
		t.Error("a callee just past the limit takes the mean")
	}
}
