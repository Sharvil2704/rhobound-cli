// SPDX-License-Identifier: Apache-2.0

package mathx

// The kernels against testdata/numerics/reference.json, made by
// gen_reference.py there (decimal arithmetic, scipy, adaptive quadrature and
// Monte Carlo). Each tolerance sits a few times above the worst error measured
// when it was set (noted next to it; linux/arm64, Go 1.27), so a regression
// fails instead of drifting; go test -v prints the worst errors. The matched
// maximum's tiers sit 20-40 times above, since their errors are near rounding
// and amd64 does not fuse multiply-adds as arm64 does.

import (
	"encoding/json"
	"fmt"
	"math"
	"os"
	"testing"
)

type maxCase struct {
	Mu     []float64 `json:"mu"`
	Var    []float64 `json:"var"`
	R      float64   `json:"r"`
	Mean   float64   `json:"mean"`
	VarMax float64   `json:"var_max"`
	MeanSE float64   `json:"mean_se"` // Monte Carlo cases only
	VarSE  float64   `json:"var_se"`
}

type reference struct {
	GammaP       [][3]float64 `json:"gamma_p"`
	NormCDF      [][2]float64 `json:"norm_cdf"`
	NormQuantile [][2]float64 `json:"norm_quantile"`
	EmaxExp      []struct {
		Means []float64 `json:"means"`
		Emax  float64   `json:"emax"`
	} `json:"emax_exp"`
	MaxGamma      []maxCase `json:"max_gamma"`
	MaxGammaMC    []maxCase `json:"max_gamma_mc"`
	MaxGammaMixed []maxCase `json:"max_gamma_mixed"`
}

func loadReference(t *testing.T) *reference {
	t.Helper()
	raw, err := os.ReadFile("../../testdata/numerics/reference.json")
	if err != nil {
		t.Fatal(err)
	}
	var ref reference
	if err := json.Unmarshal(raw, &ref); err != nil {
		t.Fatal(err)
	}
	return &ref
}

// relErr is |got - want| / |want|; an exact match (both 0) is 0.
func relErr(got, want float64) float64 {
	if got == want {
		return 0
	}
	return math.Abs(got-want) / math.Abs(want)
}

// worst tracks the largest error in one tier against its tolerance.
type worst struct {
	name     string
	tol, err float64
	at       string
	n        int
}

func (w *worst) add(e float64, at func() string) {
	w.n++
	if !(e <= w.err) { // NaN counts as worse than anything
		w.err, w.at = e, at()
	}
}

func (w *worst) check(t *testing.T) {
	t.Helper()
	if w.n == 0 {
		t.Errorf("%s: no reference values", w.name)
		return
	}
	t.Logf("%-40s worst %.2e (tolerance %.0e, %d values) at %s", w.name, w.err, w.tol, w.n, w.at)
	if !(w.err <= w.tol) {
		t.Errorf("%s: error %.3e above the tolerance %.0e at %s", w.name, w.err, w.tol, w.at)
	}
}

func TestGammaPReference(t *testing.T) {
	ref := loadReference(t)
	// Relative error of P. Below 1e-300 an absolute 1e-300 is allowed (the
	// series' exp underflows into subnormals there; nothing reads such values).
	tiers := []*worst{
		{name: "GammaP, shape <= 100", tol: 1e-12},   // measured 1.1e-13
		{name: "GammaP, shape 100..1e4", tol: 1e-10}, // measured 2.7e-11
		{name: "GammaP, shape 1e4..1e5", tol: 5e-10}, // measured 1.5e-10
	}
	for _, r := range ref.GammaP {
		a, x, want := r[0], r[1], r[2]
		w := tiers[0]
		if a > 1e4 {
			w = tiers[2]
		} else if a > 100 {
			w = tiers[1]
		}
		got := GammaP(a, x)
		e := relErr(got, want)
		if want < 1e-300 && math.Abs(got-want) <= 1e-300 {
			e = 0
		}
		w.add(e, func() string { return fmt.Sprintf("P(%g, %.17g) = %.17g, got %.17g", a, x, want, got) })
	}
	for _, w := range tiers {
		w.check(t)
	}
}

func TestNormalReference(t *testing.T) {
	ref := loadReference(t)
	cdf := &worst{name: "NormCDF, x in [-37.5, 8.25]", tol: 1e-12} // measured 2.1e-13
	for _, r := range ref.NormCDF {
		x, want := r[0], r[1]
		got := NormCDF(x)
		cdf.add(relErr(got, want), func() string { return fmt.Sprintf("x = %g: %.17g, got %.17g", x, want, got) })
	}
	cdf.check(t)
	// The quantile's relative error, with an absolute 1e-16 near the median
	// where z is near 0.
	q := &worst{name: "NormQuantile, u in [1e-300, 1-2^-53]", tol: 2e-15} // measured 4.6e-16
	for _, r := range ref.NormQuantile {
		u, want := r[0], r[1]
		got := NormQuantile(u)
		e := math.Abs(got-want) / math.Max(math.Abs(want), 0.1)
		q.add(e, func() string { return fmt.Sprintf("u = %.17g: %.17g, got %.17g", u, want, got) })
	}
	q.check(t)
}

func TestEmaxExpReference(t *testing.T) {
	ref := loadReference(t)
	exact := &worst{name: "EmaxExp, 2-12 branches (exact sum)", tol: 1e-12}     // measured 1.0e-13
	numeric := &worst{name: "EmaxExp, 13-16 branches (quadrature)", tol: 2e-12} // measured 2.5e-13
	for _, c := range ref.EmaxExp {
		w := exact
		if len(c.Means) > emaxExactLimit {
			w = numeric
		}
		got := EmaxExp(c.Means)
		w.add(relErr(got, c.Emax), func() string {
			return fmt.Sprintf("%d branches %v: %.17g, got %.17g", len(c.Means), c.Means, c.Emax, got)
		})
	}
	exact.check(t)
	numeric.check(t)
}

// minShape is the smallest gamma shape (1/scv) of a case's branches.
func minShape(c maxCase) float64 {
	k := math.Inf(1)
	for j := range c.Mu {
		k = math.Min(k, c.Mu[j]*c.Mu[j]/c.Var[j])
	}
	return k
}

func TestMaxMomentsGammaReference(t *testing.T) {
	ref := loadReference(t)
	// Realistic branches (scv <= 1.5, r <= 0.9) apart from heavy tails and
	// near-perfect correlation, so the looser bound of the second does not hide
	// a regression in the first.
	real := [2]*worst{
		{name: "E[max], scv <= 1.5 and r <= 0.9", tol: 3e-13},   // measured 7.3e-15 (5.0e-9 at 29a7ed9)
		{name: "Var[max], scv <= 1.5 and r <= 0.9", tol: 2e-11}, // measured 5.6e-13 (9.8e-8)
	}
	rest := [2]*worst{
		{name: "E[max], shapes 0.3..100, r <= 0.95", tol: 3e-9},   // measured 1.2e-10 (1.0e-6 at 29a7ed9)
		{name: "Var[max], shapes 0.3..100, r <= 0.95", tol: 1e-8}, // measured 3.6e-10 (1.5e-6)
	}
	for _, c := range ref.MaxGamma {
		w := rest
		if minShape(c) >= 1/1.5 && c.R <= 0.9 {
			w = real
		}
		m, v := MaxMomentsGammaCorr(c.Mu, c.Var, c.R)
		at := func() string {
			return fmt.Sprintf("%d branches, smallest shape %.3g, r %g: mean %.10g var %.10g, got %.10g %.10g",
				len(c.Mu), minShape(c), c.R, c.Mean, c.VarMax, m, v)
		}
		w[0].add(relErr(m, c.Mean), at)
		w[1].add(relErr(v, c.VarMax), at)
	}
	for _, w := range append(real[:], rest[:]...) {
		w.check(t)
	}
}

// One heavy branch (scv 1.5-1000) beside a near-constant one (scv 1e-4-0.1), the numerics review's failing
// cases: at 29a7ed9 the t-grid ran to the heavy branch's tail and under-resolved the narrow branch, E[max] up to
// 2.8e-5 off independent and 4.5e-4 correlated at heavy scv 100, 1.7e-3 at 1000.
func TestMaxMomentsGammaMixedReference(t *testing.T) {
	ref := loadReference(t)
	tiers := [2][2]*worst{
		{{name: "E[max], heavy beside narrow, r = 0", tol: 3e-11}, // measured 1.2e-12
			{name: "Var[max], heavy beside narrow, r = 0", tol: 5e-10}}, // measured 2.0e-11
		{{name: "E[max], heavy beside narrow, r 0.5-0.9", tol: 1.5e-10}, // measured 6.1e-12
			{name: "Var[max], heavy beside narrow, r 0.5-0.9", tol: 2.5e-9}}, // measured 1.3e-10
	}
	for _, c := range ref.MaxGammaMixed {
		w := tiers[0]
		if c.R > 0 {
			w = tiers[1]
		}
		m, v := MaxMomentsGammaCorr(c.Mu, c.Var, c.R)
		at := func() string {
			return fmt.Sprintf("mu %v var %v r %g: mean %.12g var %.12g, got %.12g %.12g", c.Mu, c.Var, c.R, c.Mean, c.VarMax, m, v)
		}
		w[0].add(relErr(m, c.Mean), at)
		w[1].add(relErr(v, c.VarMax), at)
	}
	for _, ws := range tiers {
		for _, w := range ws {
			w.check(t)
		}
	}
}

// The Monte Carlo cases check the quadrature with no shared method: the Go
// moments must lie within 4 standard errors of the sample moments.
func TestMaxMomentsGammaMonteCarlo(t *testing.T) {
	ref := loadReference(t)
	if len(ref.MaxGammaMC) == 0 {
		t.Fatal("no Monte Carlo cases")
	}
	for _, c := range ref.MaxGammaMC {
		m, v := MaxMomentsGammaCorr(c.Mu, c.Var, c.R)
		zm, zv := (m-c.Mean)/c.MeanSE, (v-c.VarMax)/c.VarSE
		t.Logf("%d branches, shape %.3g, r %g: E[max] %.5f vs %.5f +- %.5f (%+.2f se), Var %.3f vs %.3f +- %.3f (%+.2f se)",
			len(c.Mu), minShape(c), c.R, m, c.Mean, c.MeanSE, zm, v, c.VarMax, c.VarSE, zv)
		if !(math.Abs(zm) <= 4 && math.Abs(zv) <= 4) {
			t.Errorf("%d branches, shape %.3g, r %g: %+.2f se in the mean, %+.2f se in the variance", len(c.Mu), minShape(c), c.R, zm, zv)
		}
	}
}
