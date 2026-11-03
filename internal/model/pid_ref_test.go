// SPDX-License-Identifier: Apache-2.0

package model

import (
	"math"
	"testing"
)

// denseCrommelin is the Crommelin chain's stationary law by power iteration on the dense matrix (reference only).
func denseCrommelin(m *mxq, N int) []float64 {
	a := m.cpois()
	pi := make([]float64, N+1)
	pi[0] = 1
	for it := 0; it < 20000; it++ {
		nx := make([]float64, N+1)
		for i, p := range pi {
			if p == 0 {
				continue
			}
			l := max(0, i-m.c)
			for x, ax := range a {
				nx[min(l+x, N)] += p * ax
			}
		}
		d := 0.0
		for i := range nx {
			d += math.Abs(nx[i] - pi[i])
		}
		pi = nx
		if d < 1e-15 {
			break
		}
	}
	return pi
}

// piD against a dense power iteration of the same Crommelin chain, including more workers than the arrival law has
// columns, where piD's band reduction skipped the rows below c (and from c = 19 read past its slice).
func TestPiDAgainstDense(t *testing.T) {
	for _, cs := range []struct {
		c   int
		lam float64
	}{{2, 0.3}, {4, 0.8}, {8, 1.6}, {8, 2.4}, {16, 0.008}, {3, 0.5}, {18, 0.008}, {19, 0.008}, {64, 0.008}, {64, 2}, {16, 5}, {30, 1}} {
		m := &mxq{c: cs.c, s: 1, cs2: 0.25, lam: cs.lam, q: []float64{0, 0.5, 0.5}}
		pM, _ := m.piM()
		pD := m.piD(len(pM) - 1)
		ref := denseCrommelin(m, len(pM)-1+len(m.cpois()))
		md, mr, l1 := 0.0, 0.0, 0.0
		for i := range ref {
			mr += float64(i) * ref[i]
			if i < len(pD) {
				md += float64(i) * pD[i]
				l1 += math.Abs(pD[i] - ref[i])
			}
		}
		if l1 > 1e-10 || math.Abs(md-mr) > 1e-9 {
			t.Errorf("c %d lam %.3f (len(cpois) %d): mean piD %.6f, dense %.6f, L1 %.2e", cs.c, cs.lam, len(m.cpois()), md, mr, l1)
		}
	}
}
