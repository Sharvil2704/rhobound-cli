// SPDX-License-Identifier: Apache-2.0

package infer

import (
	"math"
	"math/rand"
	"testing"
)

// fill adds n visits to bin k with the given mean and standard deviation (gamma-free: a
// normal draw is enough to test the bookkeeping).
func fill(h *byK, rng *rand.Rand, k, n int, mean, sd float64) {
	for i := 0; i < n; i++ {
		x := math.Max(1, mean+sd*rng.NormFloat64())
		h.n[k]++
		h.sum[k] += x
		h.sq[k] += x * x
	}
	h.peak = max(h.peak, k+1)
}

// A pod with four workers whose k = 0 bin happens to read 10% low (the case that
// made a flat k = 1 bin look like a queue and gave one worker): the pooled
// baseline and the size floor must not call it a rise.
func TestWorkersFromKNoisyBaselineIsNotARise(t *testing.T) {
	h := &byK{}
	rng := rand.New(rand.NewSource(1))
	fill(h, rng, 0, 363, 100.6, 35) // low by 10% of the true 112
	fill(h, rng, 1, 1130, 114.0, 40)
	fill(h, rng, 2, 1852, 116.3, 40)
	fill(h, rng, 3, 7504, 112.7, 40)
	c, sat, free, ok := workersFromK(h)
	if !ok || sat || c != 4 {
		t.Fatalf("workers %d saturated %v ok %v, want 4 not saturated", c, sat, ok)
	}
	if got := free.mean(); math.Abs(got-113)/113 > 0.02 {
		t.Fatalf("service time %.1f, want about 113 from all four bins", got)
	}
	if free.n != 363+1130+1852+7504 {
		t.Fatalf("pooled %v visits", free.n)
	}
}

// One worker whose queue shows: the own time rises by most of a service time at k = 1.
func TestWorkersFromKFindsASingleWorkerQueue(t *testing.T) {
	h := &byK{}
	rng := rand.New(rand.NewSource(2))
	fill(h, rng, 0, 2000, 100, 60)
	fill(h, rng, 1, 3000, 165, 45) // waits for the residual of the one in service
	fill(h, rng, 2, 2000, 270, 60)
	c, sat, free, ok := workersFromK(h)
	if !ok || !sat || c != 1 {
		t.Fatalf("workers %d saturated %v ok %v, want 1 saturated", c, sat, ok)
	}
	if got := free.mean(); math.Abs(got-100)/100 > 0.05 {
		t.Fatalf("service time %.1f, want about 100 from k = 0 only", got)
	}
}

// Four workers and a queue: flat through k = 3, a clear rise at k = 4. The service time pools the
// bins below the rise, which is many more visits than k = 0 alone.
func TestWorkersFromKFindsFourWorkersAndPoolsTheFreeBins(t *testing.T) {
	h := &byK{}
	rng := rand.New(rand.NewSource(3))
	fill(h, rng, 0, 150, 100, 35)
	fill(h, rng, 1, 600, 100, 35)
	fill(h, rng, 2, 1500, 100, 35)
	fill(h, rng, 3, 3000, 100, 35)
	fill(h, rng, 4, 2500, 135, 45)
	fill(h, rng, 5, 1500, 165, 50)
	c, sat, free, ok := workersFromK(h)
	if !ok || !sat || c != 4 {
		t.Fatalf("workers %d saturated %v ok %v, want 4 saturated", c, sat, ok)
	}
	if free.n != 150+600+1500+3000 {
		t.Fatalf("pooled %v visits, want the 5250 that found a free worker", free.n)
	}
	// the standard error of the pooled mean is far smaller than that of k = 0 alone
	se := math.Sqrt(free.variance() / free.n)
	se0 := 35 / math.Sqrt(150)
	if se > se0/3 {
		t.Fatalf("pooled standard error %.2f against %.2f for k = 0", se, se0)
	}
}

// A user-set worker count pools the bins below it, and says so when there are too few.
func TestPoolBelow(t *testing.T) {
	h := &byK{}
	rng := rand.New(rand.NewSource(4))
	fill(h, rng, 0, 40, 50, 10)
	fill(h, rng, 1, 40, 50, 10)
	fill(h, rng, 2, 40, 50, 10)
	if _, ok := poolBelow(h, 2); ok {
		t.Fatal("80 visits are fewer than the minimum")
	}
	m, ok := poolBelow(h, 3)
	if !ok || m.n != 120 {
		t.Fatalf("pooled %v ok %v", m.n, ok)
	}
}

// Eight workers at high load: the empty pod is rare (20 visits), so the baseline is seeded from the
// lowest bins until it holds enough visits, and the rise at k = 8 is still found.
func TestWorkersFromKSeedsTheBaselineWhenTheEmptyPodIsRare(t *testing.T) {
	h := &byK{}
	rng := rand.New(rand.NewSource(5))
	fill(h, rng, 0, 20, 100, 35)
	for k := 1; k < 8; k++ {
		fill(h, rng, k, 40+300*k, 100, 35)
	}
	fill(h, rng, 8, 2500, 128, 45)
	fill(h, rng, 9, 1500, 150, 50)
	c, sat, free, ok := workersFromK(h)
	if !ok || !sat || c != 8 {
		t.Fatalf("workers %d saturated %v ok %v, want 8 saturated", c, sat, ok)
	}
	if got := free.mean(); math.Abs(got-100)/100 > 0.02 {
		t.Fatalf("service time %.1f, want about 100", got)
	}
	// and with too few visits overall, it says so instead of guessing
	h2 := &byK{}
	fill(h2, rng, 0, 20, 100, 35)
	fill(h2, rng, 1, 30, 100, 35)
	if _, _, _, ok := workersFromK(h2); ok {
		t.Fatal("50 visits are too few to read the service time")
	}
}
