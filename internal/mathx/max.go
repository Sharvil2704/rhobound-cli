// SPDX-License-Identifier: Apache-2.0

package mathx

import (
	"math"
	"slices"
)

// gammaBranches matches a gamma (shape k, scale th) to each branch's mean and
// variance and returns the end of the quadrature range. The scv is floored at
// 1e-4 (shape 1e4), where a branch is all but constant, and the mean at 1e-12.
// hi = m(1 + 10 sqrt(scv) + 25 scv) leaves P(X > hi) below 3e-15 for every
// shape, and a tail beyond hi below 2e-13 of the mean (4e-15 from shape 0.3).
func gammaBranches(mu, variance []float64) (k, th []float64, hi float64) {
	n := len(mu)
	k = make([]float64, n)
	th = make([]float64, n)
	for j := range mu {
		m := math.Max(mu[j], 1e-12)
		scv := math.Max(variance[j]/(m*m), 1e-4)
		k[j] = 1 / scv
		th[j] = m / k[j]
		hi = math.Max(hi, m*(1+10*math.Sqrt(scv)+25*scv))
	}
	return k, th, hi
}

// glX and glW are the 10-point Gauss-Legendre rule on [-1, 1].
var glX, glW = gaussLegendre(10)

// gaussLegendre returns the n-point Gauss-Legendre nodes and weights on
// [-1, 1] (Newton's method on the Legendre polynomial, from Tricomi's guess).
func gaussLegendre(n int) ([]float64, []float64) {
	x, w := make([]float64, n), make([]float64, n)
	for i := 0; i < (n+1)/2; i++ {
		z := math.Cos(math.Pi * (float64(i) + 0.75) / (float64(n) + 0.5))
		var dp float64
		for it := 0; it < 100; it++ {
			p0, p1 := 1.0, z // P_0, P_1
			for j := 2; j <= n; j++ {
				p0, p1 = p1, ((2*float64(j)-1)*z*p1-(float64(j)-1)*p0)/float64(j)
			}
			dp = float64(n) * (z*p1 - p0) / (z*z - 1) // P_n'(z)
			dz := p1 / dp
			z -= dz
			if math.Abs(dz) < 1e-16 {
				break
			}
		}
		x[i], x[n-1-i] = -z, z
		w[i] = 2 / ((1 - z*z) * dp * dp)
		w[n-1-i] = w[i]
	}
	return x, w
}

// maxEdges are the panel edges for the moments of the maximum of gamma
// branches (shape k, scale th) on [0, hi]: for every branch its mean and the
// mean plus multiples of its standard deviation, where its distribution
// function turns, so a narrow branch is resolved next to a heavy one whatever
// the range; a doubling sequence from a thousandth of the smallest mean up to
// hi, for the tails at every scale (a branch of scv 1e9 has its mass spread
// over ten decades); and c, the largest mean, where the moments are centred.
// The edges grow with the branches (up to 26 each), and every point of the
// correlated maximum evaluates every branch at 65 nodes, so the cost grows
// with the square of the number of distinct branches: about 2 ms a call for 2
// branches, 90 ms for 16 and 1.4 s for 64 (one of scv 1e6; the code review's
// measurement). Fan-outs of a few branches, as traces show them, are cheap.
func maxEdges(k, th []float64, c, hi float64) []float64 {
	zs := [...]float64{-8, -6, -5, -4, -3, -2.5, -2, -1.5, -1, -0.5, 0, 0.5, 1, 1.5, 2, 2.5, 3, 4, 5, 6, 8, 10, 13, 17, 22, 28}
	pts := []float64{c, hi}
	lo := math.Inf(1)
	for j := range k {
		m, sd := k[j]*th[j], math.Sqrt(k[j])*th[j]
		lo = math.Min(lo, m)
		for _, z := range zs {
			if p := m + z*sd; p > 0 && p < hi {
				pts = append(pts, p)
			}
		}
	}
	for p := lo / 1000; p < hi; p *= 2 {
		pts = append(pts, p)
	}
	slices.Sort(pts)
	edges := []float64{0}
	for _, p := range pts {
		if p > edges[len(edges)-1]*(1+1e-12) && p <= hi {
			edges = append(edges, p)
		}
	}
	return edges
}

// maxMoments returns the mean and variance of a non-negative variable X with
// distribution function cdf, about the centre c (the largest branch mean):
// E[X] = c + int_c^hi P(X > t) dt - int_0^c P(X <= t) dt and
// E[(X-c)^2] = int_0^c 2(c-t) P(X <= t) dt + int_c^hi 2(t-c) P(X > t) dt, so no
// large terms cancel. Each panel between edges (maxEdges, c among them) gets
// a 10-point Gauss-Legendre rule. The first runs in s with t = t1*s^3: a
// branch of gamma shape k < 1 has P(X <= t) ~ t^k at 0, whose infinite slope
// the rule would resolve badly; in s the integrand is smooth at 0. The mean
// is returned no lower than c: E[max] is at least every branch's mean.
func maxMoments(c float64, edges []float64, cdf func(t float64) float64) (float64, float64) {
	d, m2 := maxMomentsAbout(c, edges, cdf)
	return c + math.Max(d, 0), math.Max(m2-d*d, 0)
}

// maxMomentsAbout returns E[X] - c and E[(X-c)^2] as maxMoments integrates them.
func maxMomentsAbout(c float64, edges []float64, cdf func(t float64) float64) (float64, float64) {
	var below, above, below2, above2 float64
	for e := 0; e+1 < len(edges); e++ {
		a, b := edges[e], edges[e+1]
		for q := range glX {
			u := (glX[q] + 1) / 2
			t, wt := a+(b-a)*u, glW[q]*(b-a)/2
			if e == 0 {
				t, wt = b*u*u*u, glW[q]/2*3*b*u*u
			}
			f := cdf(t)
			if t < c {
				below += wt * f
				below2 += wt * 2 * (c - t) * f
			} else {
				above += wt * (1 - f)
				above2 += wt * 2 * (t - c) * (1 - f)
			}
		}
	}
	return above - below, below2 + above2
}

// MaxMomentsGamma returns the mean and variance of the maximum of independent
// gamma variables with the given means and variances (see gammaBranches for
// the floors). The mean is at least the largest branch mean and at most the
// sum of the means (sumMeanCap).
func MaxMomentsGamma(mu, variance []float64) (float64, float64) {
	k, th, hi := gammaBranches(mu, variance)
	c := maxMean(k, th)
	m, v := maxMoments(c, maxEdges(k, th, c, hi), gammaMaxCDF(k, th))
	return sumMeanCap(m, k, th), v
}

// sumMeanCap caps E[max] at the sum of the (floored) branch means: the
// maximum of non-negative branches is at most their sum. The quadrature can
// pass it only at a branch scv of 1e6 or more (by 1e-6 to 1e-2 of the sum,
// from 1e6 to 1e12), where a gamma match means little anyway.
func sumMeanCap(m float64, k, th []float64) float64 {
	sum := 0.0
	for j := range k {
		sum += k[j] * th[j]
	}
	return math.Min(m, sum)
}

// gammaMaxCDF is P(max <= t) for independent gamma branches.
func gammaMaxCDF(k, th []float64) func(t float64) float64 {
	return func(t float64) float64 {
		cdf := 1.0
		for j := range k {
			cdf *= GammaP(k[j], t/th[j])
		}
		return cdf
	}
}

// maxMean is the largest of the branches' (floored) means.
func maxMean(k, th []float64) float64 {
	c := 0.0
	for j := range k {
		c = math.Max(c, k[j]*th[j])
	}
	return c
}

// MaxMomentsGammaCorr is MaxMomentsGamma for branches whose latencies are
// positively correlated, through a Gaussian copula with one common
// correlation r between every pair. Given a common standard normal factor z the
// branches are independent, so P(max <= t) = E_z prod_j Phi((a_j(t) - sqrt(r) z) /
// sqrt(1-r)), a_j(t) = Phi^-1(F_j(t)). The z-integral is a 65-point trapezoid
// on [-8, 8] (spectrally accurate for this Gaussian weight while its spacing,
// 0.25, stays below the width of the integrand's step in z, sqrt((1-r)/r):
// 0.14 at r = 0.98, where 33 points on [-6, 6] were 1e-6 off and 65 are 1e-9).
// r <= 1e-3 is taken as independent and r is capped at 0.98.
func MaxMomentsGammaCorr(mu, variance []float64, r float64) (float64, float64) {
	if r <= 1e-3 {
		return MaxMomentsGamma(mu, variance)
	}
	k, th, hi := gammaBranches(mu, variance)
	c := maxMean(k, th)
	m, v := maxMoments(c, maxEdges(k, th, c, hi), gammaMaxCDFCorr(k, th, math.Min(r, 0.98)))
	return sumMeanCap(m, k, th), v
}

// gammaMaxCDFCorr is P(max <= t) for gamma branches under the copula of
// MaxMomentsGammaCorr with correlation r in (0, 1).
func gammaMaxCDFCorr(k, th []float64, r float64) func(t float64) float64 {
	const nz = 65
	zs := make([]float64, nz)
	zw := make([]float64, nz)
	var wsum float64
	for i := range zs {
		zs[i] = -8 + 16*float64(i)/float64(nz-1)
		zw[i] = math.Exp(-zs[i] * zs[i] / 2)
		wsum += zw[i]
	}
	for i := range zw {
		zw[i] /= wsum
	}
	sr, s1 := math.Sqrt(r), math.Sqrt(1-r)
	a := make([]float64, len(k))
	return func(t float64) float64 {
		for j := range k {
			u := math.Min(math.Max(GammaP(k[j], t/th[j]), 1e-300), 1-1e-16)
			a[j] = NormQuantile(u)
		}
		g := 0.0
		for q := 0; q < nz; q++ {
			p := 1.0
			for j := range a {
				p *= NormCDF((a[j] - sr*zs[q]) / s1)
			}
			g += zw[q] * p
		}
		return g
	}
}

// emaxExactLimit is the largest number of branches EmaxExp sums exactly; the
// inclusion-exclusion sum has 2^n terms.
const emaxExactLimit = 12

// EmaxExp returns the expected maximum of independent exponential random
// variables with the given means: exact (inclusion-exclusion) up to 12
// branches, by quadrature above. A branch of mean 0 never sets the maximum,
// so it is left out (the quadrature's range would be 0 if all were).
func EmaxExp(means []float64) float64 {
	if slices.Contains(means, 0) {
		means = slices.DeleteFunc(slices.Clone(means), func(x float64) bool { return x == 0 })
	}
	switch len(means) {
	case 0:
		return 0
	case 1:
		return means[0]
	}
	if len(means) <= emaxExactLimit {
		return emaxIE(means)
	}
	return emaxNumeric(means, 200001)
}

func emaxIE(means []float64) float64 {
	n := len(means)
	rates := make([]float64, n)
	for i, x := range means {
		rates[i] = 1 / x
	}
	tot := 0.0
	for mask := 1; mask < 1<<n; mask++ {
		s, bits := 0.0, 0
		for j := 0; j < n; j++ {
			if mask>>j&1 == 1 {
				s += rates[j]
				bits++
			}
		}
		if bits%2 == 1 {
			tot += 1 / s
		} else {
			tot -= 1 / s
		}
	}
	return tot
}

// emaxNumeric integrates 1 - prod(1 - exp(-t/x)) on [0, 50 max(means)].
func emaxNumeric(means []float64, points int) float64 {
	mx := 0.0
	for _, x := range means {
		mx = math.Max(mx, x)
	}
	hi := 50 * mx
	step := hi / float64(points-1)
	prev := 1.0 // 1 - cdf at t = 0 (cdf = 0)
	sum := 0.0
	for i := 1; i < points; i++ {
		t := step * float64(i)
		cdf := 1.0
		for _, x := range means {
			cdf *= 1 - math.Exp(-t/x)
		}
		cur := 1 - cdf
		sum += (prev + cur) / 2 * step
		prev = cur
	}
	return sum
}
