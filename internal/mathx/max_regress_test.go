// SPDX-License-Identifier: Apache-2.0

package mathx

import (
	"fmt"
	"math"
	"testing"
)

// E[max] is at least every branch's mean. At 29a7ed9 the t-grid was stretched to the heaviest branch's tail, so a
// branch of scv 4e9 beside one of mean 6.25 left no grid point inside the second: E[max] 2.3-2.6 (the
// numerics review). Over a grid of shapes from near-constant to scv 1e12, mean ratios 1e-3..1e3, two to five
// branches and r up to the cap: the mean is never below the largest branch mean, and the variance is a finite
// non-negative number. Before the clamp, the quadrature itself is not below the largest mean by more than 1e-9 of it
// up to scv 1e6 (with this t-grid and the earlier 33-point z-rule it fell 2.8e-4 below at scv 1e6 and r 0.9 and
// 7.5e-3 at r 0.98; at 29a7ed9, 198 of these 528 cases had E[max] itself below the largest mean, by up to all of it).
// Beyond scv 1e6 the heavy branch's mass spreads over more decades than the rule resolves; there the clamp holds the
// line, and the shortfall is logged.
func TestMaxNotBelowTheLargestMean(t *testing.T) {
	scvs := []float64{1e-6, 1e-4, 0.01, 0.3, 1, 3, 30, 1e3, 1e6, 1e9, 1e12}
	ratios := []float64{1e-3, 1, 1e3}
	worst, at := 0.0, ""
	worstAll, atAll := 0.0, ""
	n := 0
	for nb := 2; nb <= 4; nb += 2 {
		for _, heavy := range scvs {
			for _, other := range []float64{1e-4, 1.5} {
				for _, ratio := range ratios {
					for _, r := range []float64{0, 0.5, 0.9, 0.98} {
						mu, va := make([]float64, nb), make([]float64, nb)
						for j := range mu {
							mu[j] = 10 * (1 + 0.1*float64(j))
							va[j] = other * mu[j] * mu[j]
						}
						mu[0] = 10 * ratio
						va[0] = heavy * mu[0] * mu[0]
						m, v := MaxMomentsGammaCorr(mu, va, r)
						top := 0.0
						for _, x := range mu {
							top = math.Max(top, x)
						}
						what := fmt.Sprintf("%d branches, heavy scv %g at %g x, others scv %g, r %g", nb, heavy, ratio, other, r)
						if !(m >= top) || !(v >= 0) || math.IsInf(v, 0) {
							t.Errorf("%s: E[max] %.10g (largest mean %.10g), Var %v", what, m, top, v)
						}
						k, th, hi := gammaBranches(mu, va)
						c := maxMean(k, th)
						cdf := gammaMaxCDF(k, th)
						if r > 1e-3 {
							cdf = gammaMaxCDFCorr(k, th, math.Min(r, 0.98))
						}
						d, _ := maxMomentsAbout(c, maxEdges(k, th, c, hi), cdf)
						if heavy <= 1e6 && -d/c > worst {
							worst, at = -d/c, what
						}
						if -d/c > worstAll {
							worstAll, atAll = -d/c, what
						}
						n++
					}
				}
			}
		}
	}
	t.Logf("%d cases; the quadrature's largest shortfall below the largest mean, up to scv 1e6: %.2e of it (%s); "+
		"over the whole grid %.2e (%s)", n, worst, at, worstAll, atAll)
	if worst > 1e-9 {
		t.Errorf("the quadrature falls %.2e below the largest mean at %s", worst, at)
	}
}

// E[max] is at most the sum of the branch means: the maximum of non-negative branches is at most their sum. At
// 5b71d67 the matched maximum passed it in 91 of the 2016 cases of the code review's grid,
// all at a branch scv of 1e6 or more: by 9.6e-7 of the sum at 1e6, 8.7e-5 at 1e10 and 1.4e-2
// at 1e12. The grid below is the part of it around those cases (two and four branches, the heavy one 1e-3 to 1e3
// times the others' means, the others near-constant or at scv 1.5, r 0 to 0.98); at 5b71d67, 36 of its 216 fail.
func TestMaxNotAboveTheSumOfMeans(t *testing.T) {
	n, bad := 0, 0
	for nb := 2; nb <= 4; nb += 2 {
		for _, heavy := range []float64{1, 1e3, 1e6, 1e8, 1e10, 1e12} {
			for _, other := range []float64{1e-4, 1.5} {
				for _, ratio := range []float64{1e-3, 1, 1e3} {
					for _, r := range []float64{0, 0.5, 0.98} {
						mu, va := make([]float64, nb), make([]float64, nb)
						for j := range mu {
							mu[j] = 10 * (1 + 0.1*float64(j))
							va[j] = other * mu[j] * mu[j]
						}
						mu[0] = 10 * ratio
						va[0] = heavy * mu[0] * mu[0]
						m, _ := MaxMomentsGammaCorr(mu, va, r)
						sum := 0.0
						for _, x := range mu {
							sum += x
						}
						if !(m <= sum*(1+1e-15)) {
							bad++
							t.Errorf("%d branches, heavy scv %g at %g x, others scv %g, r %g: E[max] %.12g above the sum of "+
								"the means %.12g (%.2e)", nb, heavy, ratio, other, r, m, sum, m/sum-1)
						}
						n++
					}
				}
			}
		}
	}
	t.Logf("%d cases, %d above the sum of the means", n, bad)
}

// EmaxExp with more than 12 branches whose means are all 0 returned NaN (the quadrature's range was 50 times the
// largest mean); zero-mean branches never set the maximum.
func TestEmaxExpZeroMeans(t *testing.T) {
	for _, n := range []int{2, 12, 13, 16} {
		zero := make([]float64, n)
		if got := EmaxExp(zero); got != 0 {
			t.Errorf("%d zero means: %v", n, got)
		}
		if got := EmaxExp(append(zero, 1)); got != 1 {
			t.Errorf("%d zero means and one of 1: %.17g", n, got)
		}
	}
	if a, b := EmaxExp([]float64{3, 0, 5, 0}), EmaxExp([]float64{3, 5}); a != b {
		t.Errorf("zeros change the sum: %.17g against %.17g", a, b)
	}
}
