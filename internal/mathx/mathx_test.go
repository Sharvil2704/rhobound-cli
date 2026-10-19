// SPDX-License-Identifier: Apache-2.0

package mathx

import (
	"math"
	"testing"
)

func near(t *testing.T, what string, got, want, tol float64) {
	t.Helper()
	if math.Abs(got-want) > tol*math.Max(1, math.Abs(want)) {
		t.Errorf("%s: got %.12g want %.12g", what, got, want)
	}
}

func TestEmaxExp(t *testing.T) {
	near(t, "one", EmaxExp([]float64{3}), 3, 0)
	near(t, "two equal exp(1)", EmaxExp([]float64{1, 1}), 1.5, 1e-14)
	near(t, "three equal exp(1)", EmaxExp([]float64{1, 1, 1}), 1+0.5+1.0/3, 1e-13)
	means := []float64{1, 2, 3, 0.5, 1.5, 2.5, 4, 0.7}
	near(t, "numeric vs exact (8 branches)", emaxNumeric(means, 200001), emaxIE(means), 1e-7)
	if EmaxExp(nil) != 0 {
		t.Error("no branches")
	}
}

func TestGammaPAndMax(t *testing.T) {
	near(t, "P(1,x) = 1-e^-x", GammaP(1, 2.5), 1-math.Exp(-2.5), 1e-13)
	near(t, "P(2,x)", GammaP(2, 3), 1-math.Exp(-3)*(1+3), 1e-13)
	near(t, "P(0.5,x) = erf(sqrt x)", GammaP(0.5, 1.7), math.Erf(math.Sqrt(1.7)), 1e-12)
	near(t, "P large a", GammaP(400, 400), 0.5+1/(3*math.Sqrt(2*math.Pi*400)), 2e-3)
	if GammaP(2, 0) != 0 || GammaP(2, -1) != 0 || GammaP(2, math.Inf(1)) != 1 {
		t.Error("P(a, x) should be 0 at x <= 0 and 1 at x = +Inf")
	}
	for _, ax := range [][2]float64{{math.NaN(), 1}, {1, math.NaN()}, {0, 1}, {-1, 1}, {math.Inf(1), 1}} {
		if !math.IsNaN(GammaP(ax[0], ax[1])) {
			t.Errorf("P(%v, %v) should be NaN", ax[0], ax[1])
		}
	}
	// two iid exponentials(1): E[max] = 1.5, Var = 1.25
	m, v := MaxMomentsGamma([]float64{1, 1}, []float64{1, 1})
	near(t, "E[max] of two exp(1)", m, 1.5, 1e-10)
	near(t, "Var[max] of two exp(1)", v, 1.25, 1e-9)
	// no correlation: the copula version agrees with the independent one
	m0, v0 := MaxMomentsGammaCorr([]float64{3, 5, 4}, []float64{4, 12, 3}, 0)
	mi, vi := MaxMomentsGamma([]float64{3, 5, 4}, []float64{4, 12, 3})
	near(t, "r=0 mean", m0, mi, 1e-12)
	near(t, "r=0 var", v0, vi, 1e-12)
	// the copula quadrature itself, near zero correlation, matches the independent integral
	mc, _ := MaxMomentsGammaCorr([]float64{1, 1}, []float64{1, 1}, 0.002)
	near(t, "r=0.002", mc, 1.5, 6e-3)
	// positive correlation lowers the maximum, and r near 1 tends to the common mean
	mr, _ := MaxMomentsGammaCorr([]float64{1, 1}, []float64{1, 1}, 0.5)
	mh, _ := MaxMomentsGammaCorr([]float64{1, 1}, []float64{1, 1}, 0.95)
	if !(mh < mr && mr < m) || mh < 1 || mh > 1.2 {
		t.Errorf("E[max] should fall from %.3f to %.3f (r=.5) to %.3f (r=.95), staying above the mean 1", m, mr, mh)
	}
}

func TestNormQuantileInvertsNormCDF(t *testing.T) {
	// up to z = 3: above, u = NormCDF(z) is near 1 and has lost the tail digits
	for _, z := range []float64{-37, -20, -8.5, -3, -1.44, -0.1, 0, 0.3, 1.44, 3} {
		near(t, "quantile of cdf", NormQuantile(NormCDF(z)), z, 1e-13)
	}
	if !math.IsInf(NormQuantile(0), -1) || !math.IsInf(NormQuantile(1), 1) {
		t.Error("the quantile of 0 and 1 should be -Inf and +Inf")
	}
	if !math.IsNaN(NormQuantile(math.NaN())) {
		t.Error("NaN in, NaN out")
	}
}
