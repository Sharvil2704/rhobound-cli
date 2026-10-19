// SPDX-License-Identifier: Apache-2.0

// Package model is a mean-latency model of a service call graph: M/G/c queues
// (Erlang C with the Allen-Cunneen correction) composed along the call tree.
//
// It is valid for steady, roughly Poisson traffic below about 85% utilization.
// It does not model bursts, tail latencies, retries or timeouts.
package model

import (
	"fmt"
	"math"
)

// ErlangC returns the probability that an arrival waits in an M/M/m queue with
// offered load a = lambda*s erlangs (NaN for a NaN load). It sums a^k/k!
// forward, as the reference implementation does. The terms leave float64's
// range near a = 709, so both sums are rescaled by an exact power of two once
// the term passes 2^600 (only their ratio is used): below a ~ 419 nothing is
// rescaled and the result is the plain sum bit for bit, which keeps the golden
// parity; above it the relative error stays near 1e-14 (testdata/numerics
// checks it up to 100000 servers).
func ErlangC(m int, a float64) float64 {
	if math.IsNaN(a) {
		return a
	}
	if m < 1 {
		return 1
	}
	rho := a / float64(m)
	if rho >= 1 {
		return 1
	}
	if a <= 0 {
		return 0
	}
	const big, small = 0x1p600, 0x1p-600
	term, total := 1.0, 1.0
	for k := 1; k < m; k++ {
		term *= a / float64(k)
		total += term
		if term > big {
			term *= small
			total *= small
		}
	}
	last := term * a / float64(m) / (1 - rho)
	return last / (total + last)
}

// Residence returns the mean time in system (wait plus service) of a G/G/m
// queue by the Allen-Cunneen approximation. s is the mean service time, lam the
// arrival rate (per the same time unit), ca2 and cs2 the squared coefficients of
// variation of inter-arrival and service times. It is +Inf when unstable.
func Residence(s, lam float64, m int, ca2, cs2 float64) float64 {
	if lam*s/float64(m) >= 1 {
		return math.Inf(1)
	}
	if lam <= 0 {
		return s
	}
	wq := ErlangC(m, lam*s) / (float64(m)/s - lam) * (ca2 + cs2) / 2
	return s + wq
}

// Routing policies this package models.
const (
	// Pooled is one shared queue served by servers*workers workers.
	Pooled = "pooled"
	// Random splits Poisson traffic at random over `servers` replicas, each
	// with `workers` workers (what a plain Kubernetes Service does): evenly, or
	// in the service's Shares when it has them.
	Random = "random"
)

// ResidenceRouted returns the mean residence at a service of `servers`
// replicas with `workers` workers each under a routing policy.
func ResidenceRouted(s, lam float64, servers int, policy string, ca2, cs2 float64, workers int) (float64, error) {
	if servers < 1 || workers < 1 {
		return 0, fmt.Errorf("servers and workers must be at least 1")
	}
	switch policy {
	case Pooled, "":
		return Residence(s, lam, servers*workers, ca2, cs2), nil
	case Random:
		if servers == 1 {
			return Residence(s, lam, workers, ca2, cs2), nil
		}
		if lam*s/float64(servers*workers) >= 1 {
			return math.Inf(1), nil
		}
		if lam <= 0 {
			return s, nil
		}
		r := float64(servers)
		return Residence(s, lam/r, workers, ca2/r+1-1/r, cs2), nil
	}
	return 0, fmt.Errorf("routing policy %q is not supported (pooled and random are)", policy)
}

// ResidenceShares returns the mean residence at a service whose replicas take
// uneven shares of its traffic (shares sum to 1), each with `workers` workers.
// A Kubernetes Service picks a replica per connection, not per request, so
// clients that keep their connections alive can hold such a split. Each
// replica is a G/G/c queue fed its share, the arrivals thinned at random as
// Random does (ca2 -> p*ca2 + 1-p); a visit's mean residence is the
// share-weighted mean. It is +Inf when a replica is unstable.
func ResidenceShares(s, lam float64, shares []float64, workers int, ca2, cs2 float64) float64 {
	r := 0.0
	for _, p := range shares {
		r += p * replicaResidence(s, lam, p, workers, ca2, cs2)
	}
	return r
}

// replicaResidence is the mean residence at the replica that takes the share
// p of a service's traffic lam (see ResidenceShares).
func replicaResidence(s, lam, p float64, workers int, ca2, cs2 float64) float64 {
	return Residence(s, lam*p, workers, p*ca2+1-p, cs2)
}
