// SPDX-License-Identifier: Apache-2.0

// Package mathx holds the generic numerical kernels of the model: the
// regularized incomplete gamma function, the standard normal distribution and
// its quantile, and the moments of the maximum of gamma or exponential
// variables. testdata/numerics holds the reference values they are tested
// against, and the script that made them.
package mathx

import "math"

// GammaP is the regularized lower incomplete gamma function P(a, x): 0 for
// x <= 0, 1 at x = +Inf, and NaN unless a is positive and finite and x is a
// number (an iteration on a NaN would run to its cap). Below x = a+1 it sums
// the series, above it the continued fraction for Q = 1-P (modified Lentz),
// each to 1e-15 relative in at most 10000 terms; they need about sqrt(70a),
// so a stays below ~1e6. The relative error is about 1e-13 up to a = 100 and
// grows to 3e-11 at a = 1e4 and 1.5e-10 at 1e5, from the rounding of
// -x + a ln x - lnGamma(a); the model's shapes stay at or below 1e4 (its scv
// floor). Above x = a+1 the result is 1 - Q, so near 1 only its absolute error
// is small.
func GammaP(a, x float64) float64 {
	switch {
	case !(a > 0) || math.IsInf(a, 1) || math.IsNaN(x):
		return math.NaN()
	case x <= 0:
		return 0
	case math.IsInf(x, 1):
		return 1
	}
	lg, _ := math.Lgamma(a)
	if x < a+1 { // series
		sum, term := 1/a, 1/a
		for n := 1; n < 10000; n++ {
			term *= x / (a + float64(n))
			sum += term
			if math.Abs(term) < math.Abs(sum)*1e-15 {
				break
			}
		}
		return sum * math.Exp(-x+a*math.Log(x)-lg)
	}
	// continued fraction for Q(a, x) (modified Lentz)
	const tiny = 1e-300
	b := x + 1 - a
	c := 1 / tiny
	d := 1 / b
	h := d
	for i := 1; i < 10000; i++ {
		an := -float64(i) * (float64(i) - a)
		b += 2
		d = an*d + b
		if math.Abs(d) < tiny {
			d = tiny
		}
		c = b + an/c
		if math.Abs(c) < tiny {
			c = tiny
		}
		d = 1 / d
		del := d * c
		h *= del
		if math.Abs(del-1) < 1e-15 {
			break
		}
	}
	return 1 - math.Exp(-x+a*math.Log(x)-lg)*h
}
