// SPDX-License-Identifier: Apache-2.0

package infer_test

import (
	"math/rand"
	"testing"
)

// A pool whose count is a lower bound because its waits, though many, are too short to pin it (a pod with no
// worker limit reads so; here 64 workers at 70%, spans that include the wait, 4 s). At 5b71d67 the one-line warning
// for it said that no service shows enough requests waiting inside its spans, "none can when spans start once a
// worker has taken the request", where hundreds waited inside the spans (the code review's cap-inf: 2135).
func TestBriefWaitsAreNamed(t *testing.T) {
	rng := rand.New(rand.NewSource(7))
	const c, rho, s, secs = 64, 0.7, 10.0, 4.0
	lam := rho * c / s // per ms
	var arr, svc []float64
	for t := rng.ExpFloat64() / lam; t < secs*1000; t += rng.ExpFloat64() / lam {
		arr = append(arr, t)
		svc = append(svc, s*rng.ExpFloat64())
	}
	start := fifoOne(arr, svc, c)
	x := &ids{}
	var spans []span
	for i := range arr {
		spans = append(spans, span{svc: "fe", pod: "fe-0", id: x.next(), kind: 2, start: arr[i], end: start[i] + svc[i], trace: i + 1})
	}
	inf := infer1(t, spans)
	fe := inf.Stats[inf.Topology.Index("fe")]
	if fe.WorkersFromQueueing {
		t.Fatalf("fe: %d workers, identified; want a lower bound", fe.WorkersPerPod)
	}
	if !warned(inf, "too few requests waited for a worker, or too briefly", "too short to rule out more workers") ||
		warned(inf, "none can when spans start once a worker has taken the request") {
		t.Errorf("fe %d+: the warning should say the waits were too brief: %q", fe.WorkersPerPod, inf.Warnings)
	}
}
