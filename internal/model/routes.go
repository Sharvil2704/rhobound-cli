// SPDX-License-Identifier: Apache-2.0

package model

import (
	"fmt"
	"math"
)

// Route nodes. A service can serve routes of very different cost, each reached from its own callers: a cheap /item
// for one caller and a dear /search, with its own fan-out, for another. The queue sees the routes blended (one own
// time, one set of calls, each made with its share of the visits), but a caller that reaches only /search waits for
// /search: the queue's wait, then /search's own time and /search's calls. RouteAdj is that difference, added to the
// calls of the callers that carry the route weights (Call.RouteQ); the calls of the others keep the blend.

// Route is one route of a service: its share of the visits, its own time and the chance that a visit of the route
// makes each of the service's calls (P, in the order of Service.Calls).
type Route struct {
	Name  string
	Share float64
	S     float64 // mean own time of the route's visits, ms
	CS2   float64 // squared coefficient of variation of that time
	P     []float64
}

// checkRoutes validates a service's routes and its callers' route weights against them.
func (t *Topology) checkRoutes() error {
	for i := range t.Services {
		s := &t.Services[i]
		if len(s.Routes) == 0 {
			continue
		}
		if len(s.Routes) < 2 {
			return fmt.Errorf("%s: routes need two or more", s.Name)
		}
		sum := 0.0
		for _, r := range s.Routes {
			if len(r.P) != len(s.Calls) {
				return fmt.Errorf("%s: route %q has %d call chances for %d calls", s.Name, r.Name, len(r.P), len(s.Calls))
			}
			if !(r.Share >= 0 && r.Share <= 1) || !(r.S >= 0) || math.IsInf(r.S, 1) || !(r.CS2 >= 0) || math.IsInf(r.CS2, 1) {
				return fmt.Errorf("%s: route %q: share in [0, 1], own time and cs2 finite and non-negative", s.Name, r.Name)
			}
			for _, p := range r.P {
				if !(p >= 0 && p <= 1) {
					return fmt.Errorf("%s: route %q: a call chance must be in [0, 1], got %v", s.Name, r.Name, p)
				}
			}
			sum += r.Share
		}
		if math.Abs(sum-1) > 1e-6 {
			return fmt.Errorf("%s: route shares sum to %v, not 1", s.Name, sum)
		}
	}
	for i := range t.Services {
		for _, c := range t.Services[i].Calls {
			if c.RouteQ == nil {
				continue
			}
			ch := &t.Services[c.Child]
			if len(c.RouteQ) != len(ch.Routes) {
				return fmt.Errorf("%s -> %s: %d route weights for %d routes", t.Services[i].Name, ch.Name, len(c.RouteQ), len(ch.Routes))
			}
			sum := 0.0
			for _, q := range c.RouteQ {
				if !(q >= 0 && q <= 1) {
					return fmt.Errorf("%s -> %s: a route weight must be in [0, 1], got %v", t.Services[i].Name, ch.Name, q)
				}
				sum += q
			}
			if math.Abs(sum-1) > 1e-6 {
				return fmt.Errorf("%s -> %s: route weights sum to %v, not 1", t.Services[i].Name, ch.Name, sum)
			}
		}
	}
	return nil
}

// routed reports whether calls into service x can take its routes: it has routes, and its calls are made one after
// another (a parallel service or a batch group keeps the blend).
func (t *Topology) routed(x int) bool {
	s := &t.Services[x]
	return len(s.Routes) >= 2 && !s.Parallel
}

// RouteAdj is the change of mean (dm, ms) and of variance (dv, ms^2) of a call into service x with route weights q,
// against the blend the queue sees: Σ q_r m_r - Σ share_r m_r, where m_r is route r's own time plus its calls (each
// made with the route's chance, at the child's latency l and variance vl, its hop and any edge change). The variance
// is the routes' mixture at q less the blend's own-and-calls variance as the blend model forms it (pooled own time,
// calls independent of it and of each other), both from the routes: the mixture at the shares would exceed that by
// the between-route covariances the blend drops (lean/Rbproofs/Routes.lean, decomposition), leaving every routed
// call that much short. The queue's wait is the same for every route (one FIFO queue), so it cancels. dm and dv are
// 0 when x has no routes. A caller without route weights (q nil) is taken to reach the routes in their shares: its
// mean is the blend's, and its variance the mixture's, the blend model's plus the between-route covariances.
func (t *Topology) RouteAdj(x int, q []float64, l, vl []float64, edge, edgeVar map[Edge]float64) (dm, dv float64) {
	if !t.routed(x) {
		return 0, 0
	}
	s := &t.Services[x]
	n := len(s.Routes)
	m := make([]float64, n)
	v := make([]float64, n)
	for k, r := range s.Routes {
		m[k] = r.S
		v[k] = r.CS2 * r.S * r.S
		for j, c := range s.Calls {
			p := r.P[j]
			if c.Async || p == 0 {
				continue
			}
			mc := t.CallHop(c) + l[c.Child] + edgeMs(edge, x, c.Child)
			vc := 0.0
			if vl != nil {
				vc = edgeVariance(vl[c.Child], edgeVar, x, c.Child)
			}
			m[k] += p * mc
			v[k] += p*(vc+mc*mc) - (p*mc)*(p*mc)
		}
	}
	mix := func(w []float64) (mean, variance float64) {
		for k := range w {
			mean += w[k] * m[k]
			variance += w[k] * (v[k] + m[k]*m[k])
		}
		return mean, variance - mean*mean
	}
	share := make([]float64, n)
	for k, r := range s.Routes {
		share[k] = r.Share
	}
	if q == nil {
		q = share
	}
	mq, vq := mix(q)
	mb, _ := mix(share)
	return mq - mb, vq - t.blendVar(x, share, l, vl, edge, edgeVar)
}

// blendVar is the blend model's own-and-calls variance of routed service x, from its routes: the pooled own time
// (share-weighted mean S, variance the mean CS2 S^2 plus the spread of the routes' S) and each call made with its
// share-weighted chance, independently.
func (t *Topology) blendVar(x int, share []float64, l, vl []float64, edge, edgeVar map[Edge]float64) float64 {
	s := &t.Services[x]
	sm, s2 := 0.0, 0.0
	for k, r := range s.Routes {
		sm += share[k] * r.S
		s2 += share[k] * (r.CS2 + 1) * r.S * r.S
	}
	v := s2 - sm*sm
	for j, c := range s.Calls {
		if c.Async {
			continue
		}
		p := 0.0
		for k, r := range s.Routes {
			p += share[k] * r.P[j]
		}
		if p == 0 {
			continue
		}
		mc := t.CallHop(c) + l[c.Child] + edgeMs(edge, x, c.Child)
		vc := 0.0
		if vl != nil {
			vc = edgeVariance(vl[c.Child], edgeVar, x, c.Child)
		}
		v += p*(vc+mc*mc) - (p*mc)*(p*mc)
	}
	return v
}
