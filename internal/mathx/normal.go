// SPDX-License-Identifier: Apache-2.0

package mathx

import "math"

// NormCDF is the standard normal distribution function. Erfc keeps the
// relative error near 1e-13 far into the lower tail (x = -37.5).
func NormCDF(x float64) float64 { return 0.5 * math.Erfc(-x/math.Sqrt2) }

// NormQuantile is the standard normal quantile, the inverse of NormCDF, for u
// in (0, 1); it is -Inf at 0 and +Inf at 1. Below u = 0.075, 2u-1 has lost the
// low digits of u (and is -1 below 1.1e-16), so the value is polished on u
// itself by Halley's method; above, 2u-1 is exact or well conditioned.
func NormQuantile(u float64) float64 {
	z := math.Sqrt2 * math.Erfinv(2*u-1)
	if !(u > 0) || u >= 0.075 {
		return z
	}
	if math.IsInf(z, -1) { // asymptotic start
		l := -2 * math.Log(u)
		z = -math.Sqrt(l - math.Log(l) - math.Log(2*math.Pi))
	}
	for i := 0; i < 3; i++ {
		d := (NormCDF(z) - u) / (math.Exp(-z*z/2) / math.Sqrt(2*math.Pi))
		z -= d / (1 + z*d/2)
	}
	return z
}
