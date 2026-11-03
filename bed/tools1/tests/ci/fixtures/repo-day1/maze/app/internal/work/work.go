// Package work is the request-processing code shared by every maze service: a
// service's own processing time per request and the library code paths some
// services run on every request (token verification, payment risk checks).
package work

import (
	"math"
	"math/rand/v2"
	"sync"
	"time"
)

// Dist is a service-time distribution: gamma with mean MeanMs and squared
// coefficient of variation CS2 (1 = exponential, 0 = deterministic).
type Dist struct {
	MeanMs float64 `json:"mean_ms"`
	CS2    float64 `json:"cs2"`
}

var (
	mu  sync.Mutex
	rng = rand.New(rand.NewPCG(uint64(time.Now().UnixNano()), 0x6b73686f70))
)

func normal() float64 {
	mu.Lock()
	defer mu.Unlock()
	return rng.NormFloat64()
}

func uniform() float64 {
	mu.Lock()
	defer mu.Unlock()
	return rng.Float64()
}

// gamma draws Gamma(shape k, scale 1) by Marsaglia and Tsang (k < 1 by boosting).
func gamma(k float64) float64 {
	if k < 1 {
		return gamma(k+1) * math.Pow(uniform(), 1/k)
	}
	d := k - 1.0/3
	c := 1 / math.Sqrt(9*d)
	for {
		x := normal()
		v := 1 + c*x
		if v <= 0 {
			continue
		}
		v = v * v * v
		u := uniform()
		if math.Log(u) < 0.5*x*x+d-d*v+d*math.Log(v) {
			return d * v
		}
	}
}

// Draw returns one processing time.
func (d Dist) Draw() time.Duration {
	if d.MeanMs <= 0 {
		return 0
	}
	ms := d.MeanMs
	if d.CS2 > 0 {
		ms = gamma(1/d.CS2) * d.MeanMs * d.CS2
	}
	return time.Duration(ms * float64(time.Millisecond))
}

// Process holds the calling goroutine for one draw of d (I/O-bound work: a
// database round trip, a blocking client library).
func Process(d Dist) {
	time.Sleep(d.Draw())
}
