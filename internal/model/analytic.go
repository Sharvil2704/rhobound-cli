// SPDX-License-Identifier: Apache-2.0

package model

import (
	"fmt"
	"math"
	"slices"

	"github.com/Sharvil2704/rhobound-cli/internal/mathx"
)

// Config selects the refinements of the basic model. The basic model treats
// every queue's arrivals as Poisson and every parallel branch as exponential.
type Config struct {
	// ArrivalWeight carries the variability of arrivals through the call graph
	// (Whitt's QNA) and sets how much of it a queue uses: ca2 = 1 + w*(propagated
	// ca2 - 1). A queue with variable service emits burstier departures, a
	// regular one smoother, and the queues it feeds see that. 0 is Poisson
	// arrivals at every queue (the basic model), 1 is QNA in full; a weight
	// outside [0, 1] is refused. (It replaces a switch plus a weight in which a
	// weight of 0 silently meant 1.)
	ArrivalWeight float64
	// MatchedMax takes the expected maximum over parallel branches with each
	// branch a gamma matched to its mean and variance, not an exponential.
	MatchedMax bool
}

var (
	// Plain is the basic model (the reference implementation's default path).
	Plain = Config{}
	// Default is what the command line uses. The arrival weight 0.7 is an empirical
	// damping of Whitt's QNA, chosen on simulated chains and checked on two seeded holdouts
	// (see docs/ACCURACY.md); full QNA (1) over-corrects changes.
	Default = Config{ArrivalWeight: 0.7, MatchedMax: true}
)

// Result is the solved network at one load.
type Result struct {
	Stable bool      // every utilization is below 1 and every result is a finite number
	Rho    []float64 // utilization per service (0 for delays); with replica Shares, its busiest replica's
	Lam    []float64 // arrival rate per service, per ms
	Ca2    []float64 // squared coefficient of variation of the arrivals each service sees
	R      []float64 // mean residence per service (wait + service), ms
	V      []float64 // variance of the residence (only with MatchedMax)
	L      []float64 // mean subtree latency per service (residence + calls + hops), ms
}

// MaxRho returns the largest utilization and the service that has it. A NaN
// utilization is returned as such (it must not pass a limit check); with no
// services the index is -1.
func (r *Result) MaxRho() (float64, int) {
	best, at := -1.0, -1
	for i, v := range r.Rho {
		if math.IsNaN(v) {
			return v, i
		}
		if v > best {
			best, at = v, i
		}
	}
	return best, at
}

// Analytic solves the basic network for an external rate lamExt (requests per
// ms). ds is an optional per-service change of the mean service time, in ms.
func Analytic(t *Topology, lamExt float64, ds []float64) (*Result, error) {
	return AnalyticWith(t, lamExt, ds, Plain)
}

// AnalyticWith is Analytic with the refinements in cfg.
func AnalyticWith(t *Topology, lamExt float64, ds []float64, cfg Config) (*Result, error) {
	n := len(t.Services)
	if ds != nil && len(ds) != n {
		return nil, fmt.Errorf("ds has %d entries for %d services", len(ds), n)
	}
	if !(lamExt >= 0) || math.IsInf(lamExt, 1) {
		return nil, fmt.Errorf("the external rate must be finite and non-negative, got %v", lamExt)
	}
	if !(cfg.ArrivalWeight >= 0 && cfg.ArrivalWeight <= 1) {
		// above 1 the weight over-shoots QNA: a smooth upstream drives a queue's ca2 below 0 (residence below the
		// service time, a negative latency, reported as stable)
		return nil, fmt.Errorf("the arrival weight must be in [0, 1] (0: Poisson arrivals, 1: QNA in full), got %v", cfg.ArrivalWeight)
	}
	for i := range ds {
		if math.IsNaN(ds[i]) || math.IsInf(ds[i], 0) || t.Services[i].S+ds[i] < 0 {
			return nil, fmt.Errorf("%s: the changed service time %v + %v is not a non-negative number", t.Services[i].Name, t.Services[i].S, ds[i])
		}
	}
	v := t.VisitRatios()
	res := &Result{Rho: make([]float64, n), Lam: make([]float64, n)}
	s := make([]float64, n)
	for i := range t.Services {
		s[i] = t.Services[i].S
		if ds != nil {
			s[i] += ds[i]
		}
		res.Lam[i] = lamExt * v[i]
		switch sv := &t.Services[i]; {
		case sv.Delay:
		case sv.Shares != nil: // the busiest replica: it is the one that saturates
			res.Rho[i] = res.Lam[i] * slices.Max(sv.Shares) * s[i] / float64(sv.Workers)
		default:
			capacity := float64(sv.Servers * sv.Workers)
			res.Rho[i] = res.Lam[i] * s[i] / capacity
		}
	}
	for _, rho := range res.Rho {
		if rho >= 1 {
			return res, nil // Stable stays false
		}
	}
	res.Ca2 = make([]float64, n)
	for i := range res.Ca2 {
		res.Ca2[i] = 1
	}
	if cfg.ArrivalWeight != 0 {
		arrivalVariability(t, lamExt, res, s, cfg.ArrivalWeight)
	}
	res.R = make([]float64, n)
	for i := range t.Services {
		sv := &t.Services[i]
		if sv.Delay {
			res.R[i] = s[i]
			continue
		}
		if sv.Shares != nil {
			res.R[i] = ResidenceShares(s[i], res.Lam[i], sv.Shares, sv.Workers, res.Ca2[i], sv.CS2)
			continue
		}
		r, err := ResidenceRouted(s[i], res.Lam[i], sv.Servers, sv.Routing, res.Ca2[i], sv.CS2, sv.Workers)
		if err != nil {
			return nil, err
		}
		res.R[i] = r
	}
	if cfg.MatchedMax {
		res.V = residenceVariance(t, res, s)
		res.L = composeMatched(t, res.R, res.V)
	} else {
		res.L = compose(t, res.R)
	}
	// A NaN or an infinity is never reported as stable. An infinity is a queue
	// at the edge of saturation (rounding can leave rho just below 1), so the
	// result is unstable; a NaN means an input got past the checks: an error.
	for _, xs := range [][]float64{res.Rho, res.Ca2, res.R, res.V, res.L} {
		for i, x := range xs {
			if math.IsNaN(x) {
				return nil, fmt.Errorf("%s: the model gives NaN at %v requests per ms (an input is out of range)", t.Services[i].Name, lamExt)
			}
		}
	}
	res.Stable = IsFinite(res.R) && IsFinite(res.V) && IsFinite(res.L)
	return res, nil
}

// compose returns the mean subtree latency per service. A call made with
// probability p contributes p times its subtree latency. A sequential service
// adds its calls; a parallel one adds the expected maximum of its branches,
// taken as if each branch latency were exponential. An async call adds
// nothing: the service does not wait for it. The glue comes last, once
// the calls are done. (The reference adds a parallel service's glue to each
// branch's return. For the exact maximum that is the same, max(X+g, Y+g) =
// max(X, Y) + g, but the exponential formula then inflates it: k equal
// branches add (1 + 1/2 + ... + 1/k) g instead of g.)
func compose(t *Topology, r []float64) []float64 {
	l := make([]float64, len(t.Services))
	for k := len(t.order) - 1; k >= 0; k-- {
		i := t.order[k]
		sv := &t.Services[i]
		calls := sv.SyncCalls()
		switch {
		case len(calls) == 0:
			l[i] = r[i]
		case sv.Parallel:
			vals := make([]float64, len(calls))
			for j, c := range calls {
				vals[j] = c.P * (t.CallHop(c) + l[c.Child])
			}
			l[i] = r[i] + mathx.EmaxExp(vals)
		default:
			sum := 0.0
			for _, c := range calls {
				sum += c.P * (t.CallHop(c) + l[c.Child])
			}
			l[i] = r[i] + sum
		}
		l[i] += sv.Glue
	}
	return l
}

// Delta is the model before and after a change of service times.
type Delta struct {
	Stable        bool
	Base, Patched *Result
	DL            []float64 // patched.L - base.L per service; nil if unstable
}

// Change solves the network at lamExt before and after adding ds (ms) to the
// service times, with the squared coefficient of variation held fixed (the
// time is scaled, not shifted). See ChangeShift for a constant added time.
func Change(t *Topology, lamExt float64, ds []float64) (*Delta, error) {
	return ChangeShiftWith(t, lamExt, ds, nil, Plain)
}

// ChangeShift is Change where services with shift[i] set get a constant extra
// time ds[i] on every visit: the mean moves by ds[i] and the variance stays,
// so the squared coefficient of variation falls to cs2*s^2/(s+ds)^2. Services
// without it have their time scaled (cs2 unchanged). Replica shares are kept:
// the change does not move traffic between replicas.
func ChangeShift(t *Topology, lamExt float64, ds []float64, shift []bool) (*Delta, error) {
	return ChangeShiftWith(t, lamExt, ds, shift, Plain)
}

// ChangeShiftWith is ChangeShift with the refinements in cfg.
func ChangeShiftWith(t *Topology, lamExt float64, ds []float64, shift []bool, cfg Config) (*Delta, error) {
	return ChangePatchWith(t, lamExt, Patch{DS: ds, Shift: shift}, cfg)
}

// Patch is a change of per-visit times. DS[i] ms is added to service i's
// service time: a constant extra time on every visit where Shift[i] is set
// (the variance stays), else the time is scaled (its cs2 stays). Glue[i] ms
// is added to its glue, scaled (GlueCS2 stays). Nil slices change nothing.
type Patch struct {
	DS    []float64
	Shift []bool
	Glue  []float64
}

// ChangePatchWith solves the network at lamExt before and after the patch p.
func ChangePatchWith(t *Topology, lamExt float64, p Patch, cfg Config) (*Delta, error) {
	n := len(t.Services)
	ds, shift := p.DS, p.Shift
	if shift != nil && (len(shift) != n || len(ds) != n) {
		return nil, fmt.Errorf("shift has %d entries and ds %d for %d services", len(shift), len(ds), n)
	}
	if p.Glue != nil && len(p.Glue) != n {
		return nil, fmt.Errorf("the glue change has %d entries for %d services", len(p.Glue), n)
	}
	b, err := AnalyticWith(t, lamExt, nil, cfg)
	if err != nil {
		return nil, err
	}
	pt := *t
	pt.Services = append([]Service(nil), t.Services...)
	for i := range pt.Services {
		if shift != nil && shift[i] && ds[i] != 0 {
			s := pt.Services[i].S
			if s+ds[i] > 0 {
				pt.Services[i].CS2 = t.Services[i].CS2 * s * s / ((s + ds[i]) * (s + ds[i]))
			}
		}
		if p.Glue != nil && p.Glue[i] != 0 {
			g := pt.Services[i].Glue + p.Glue[i]
			if !(g >= 0) || math.IsInf(g, 0) {
				return nil, fmt.Errorf("%s: the changed glue %v + %v is not a non-negative number", t.Services[i].Name, t.Services[i].Glue, p.Glue[i])
			}
			pt.Services[i].Glue = g
		}
	}
	pr, err := AnalyticWith(&pt, lamExt, ds, cfg)
	if err != nil {
		return nil, err
	}
	d := &Delta{Stable: b.Stable && pr.Stable, Base: b, Patched: pr}
	if d.Stable {
		d.DL = make([]float64, len(b.L))
		for i := range d.DL {
			d.DL[i] = pr.L[i] - b.L[i]
		}
	}
	return d, nil
}

// IsFinite reports whether every value is a finite number.
func IsFinite(xs []float64) bool {
	for _, x := range xs {
		if math.IsNaN(x) || math.IsInf(x, 0) {
			return false
		}
	}
	return true
}
