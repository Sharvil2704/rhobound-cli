// SPDX-License-Identifier: Apache-2.0

package infer

import (
	"math"
	"math/rand"
	"strings"
	"testing"
)

// The test's p-value against closed forms of the chi-square tail: erfc(sqrt(x/2)) for one degree of
// freedom, exp(-x/2) for two.
func TestEvenSplitPValue(t *testing.T) {
	for _, c := range []struct {
		n    []int64
		want float64
	}{
		{[]int64{600, 400}, math.Erfc(math.Sqrt(20))},  // chi-square 40, 6.3 sd
		{[]int64{520, 480}, math.Erfc(math.Sqrt(0.8))}, // chi-square 1.6
		{[]int64{400, 300, 300}, math.Exp(-10)},        // chi-square 20
		{[]int64{500, 500}, 1},                         // as even as it gets
		{[]int64{34, 33, 33}, math.Exp(-0.01)},         // chi-square 0.02
	} {
		p, ok := evenSplitP(c.n)
		if !ok || math.Abs(p-c.want) > 1e-12*c.want+1e-15 {
			t.Errorf("%v: p %.6g (read %v), want %.6g", c.n, p, ok, c.want)
		}
	}
	for _, n := range [][]int64{{15, 5}, {100}, {30, 20, 5}} {
		if _, ok := evenSplitP(n); ok {
			t.Errorf("%v: too few visits per pod to read the test", n)
		}
	}
}

// Run 1 of the Kubernetes test, whose captures were kept: one api pod took 53.7% of 4583 calls before the
// change (5.1 sd from even) and 61.6% of 4399 after (15.4 sd). Both are flagged; a split 4 sd from even is not.
func TestEvenSplitThreshold(t *testing.T) {
	for _, c := range []struct {
		n      []int64
		uneven bool
	}{
		{[]int64{2463, 2120}, true},
		{[]int64{2711, 1688}, true},
		{[]int64{2427, 2156}, false}, // 4.0 sd
	} {
		p, ok := evenSplitP(c.n)
		if !ok || (p < splitP) != c.uneven {
			t.Errorf("%v: p %.3g, uneven %v, want %v", c.n, p, p < splitP, c.uneven)
		}
	}
}

// Under an even random split the p-value is uniform: about 5% of splits fall below 0.05, and none of 20000
// below the threshold.
func TestEvenSplitFalseAlarms(t *testing.T) {
	r := rand.New(rand.NewSource(3))
	const reps = 20000
	below5, flagged := 0, 0
	for i := 0; i < reps; i++ {
		k := 2 + i%3
		n := make([]int64, k)
		for j := 0; j < 600; j++ {
			n[r.Intn(k)]++
		}
		p, ok := evenSplitP(n)
		if !ok {
			t.Fatalf("%v: should be read", n)
		}
		if p < 0.05 {
			below5++
		}
		if p < splitP {
			flagged++
		}
	}
	if share := float64(below5) / reps; math.Abs(share-0.05) > 0.006 {
		t.Errorf("%.4f of even random splits below p = 0.05, want 0.05", share)
	}
	if flagged > 0 {
		t.Errorf("%d of %d even random splits flagged as uneven", flagged, reps)
	}
}

func TestPodSplit(t *testing.T) {
	names := []string{"api-b", "x-0", "api-a", "api-c"}
	visits := []int64{300, 999, 100, 0}
	pods := map[int32]bool{0: true, 2: true}
	by, p, shares := podSplit(pods, names, visits)
	if len(by) != 2 || by[0].Pod != "api-a" || by[0].Visits != 100 || by[1].Share != 0.75 {
		t.Fatalf("shares by pod name: %+v", by)
	}
	if p == nil || !(*p < splitP) || len(shares) != 2 || shares[0] != 0.25 || shares[1] != 0.75 {
		t.Fatalf("a 25/75 split of 400 visits is uneven: p %v, shares %v", p, shares)
	}
	w := splitWarning("api", by, *p)
	for _, s := range []string{"api-a 25.0%", "api-b 75.0%", "p < 1e-12", "per connection", "change prediction keeps"} {
		if !strings.Contains(w, s) {
			t.Errorf("warning %q lacks %q", w, s)
		}
	}
	visits[0] = 105
	if _, p, shares := podSplit(pods, names, visits); p == nil || shares != nil {
		t.Errorf("a 51/49 split is even: p %v, shares %v", p, shares)
	}
	visits[0], visits[2] = 10, 12
	if by, p, shares := podSplit(pods, names, visits); len(by) != 2 || p != nil || shares != nil {
		t.Errorf("too few visits: the shares are measured, the test not read: %+v %v %v", by, p, shares)
	}
}
