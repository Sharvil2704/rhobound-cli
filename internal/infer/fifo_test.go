// SPDX-License-Identifier: Apache-2.0

package infer

import (
	"encoding/json"
	"math"
	"math/rand"
	"os"
	"path/filepath"
	"slices"
	"strconv"
	"testing"
)

// Three jobs arriving at 0, 1, 2 ms that free their worker at 5, 6, 7 ms.
func TestFIFOStartByHand(t *testing.T) {
	a := []float64{0, 1, 2}
	d := []float64{5, 6, 7}
	for c, want := range map[int][]float64{
		1: {0, 5, 6}, // one worker: each waits for the release before it
		2: {0, 1, 5}, // two: the third waits for the first release
		3: {0, 1, 2}, // three: nobody waits
		9: {0, 1, 2},
	} {
		if got := fifoStart(a, d, c); !slices.Equal(got, want) {
			t.Errorf("c=%d: b=%v, want %v", c, got, want)
		}
	}
	// first come, first served: a job never starts before the one ahead of it, even if a worker is free
	// (job 2 is released early, 3, but job 3 must still wait for job 1's start)
	got := fifoStart([]float64{0, 1, 1.5, 2}, []float64{10, 3, 12, 4}, 2)
	if want := []float64{0, 1, 3, 10}; !slices.Equal(got, want) {
		t.Errorf("b=%v, want %v", got, want)
	}
}

// Arrivals closer than tieMs are put in order of release; others keep their order.
func TestQueueOrderTies(t *testing.T) {
	a := []float64{0.02, 0.0, 0.04, 5, 9, 9.03}
	d := []float64{1, 9, 3, 6, 12, 10}
	got := queueOrder(a, d)
	// 0.0, 0.02, 0.04 form one group (each within 0.05 of the last): by release 1 (idx 0), 3 (idx 2), 9 (idx 1)
	if want := []int{0, 2, 1, 3, 5, 4}; !slices.Equal(got, want) {
		t.Errorf("order %v, want %v", got, want)
	}
}

// Five pairs of overlapping jobs: one worker is contradicted by every pair, two explain them.
func TestInferWorkersByHand(t *testing.T) {
	var a, d []float64
	for k := 0; k < 5; k++ {
		base := 100 * float64(k)
		a = append(a, base, base+1)
		d = append(d, base+10, base+5)
	}
	q := inferWorkers(a, d, 0)
	if q.Workers != 2 || q.Contradictions != 0 || q.MaxInSystem != 2 || q.Identified {
		t.Fatalf("got %+v", q)
	}
	if q.RefutedBy[1] != "contradictions" || q.RefutedBelow != 0.5 {
		t.Fatalf("refuted %v below %v", q.RefutedBy, q.RefutedBelow)
	}
	// a count set by the user is taken as given
	if q1 := inferWorkers(a, d, 1); q1.Workers != 1 || q1.Contradictions != 5 || q1.Waited != 5 {
		t.Fatalf("fixed: %+v", q1)
	}
}

type goldenCase struct {
	Name           string               `json:"name"`
	A              []float64            `json:"a"`
	D              []float64            `json:"d"`
	Order          []int                `json:"order"`
	FIFO           map[string][]float64 `json:"fifo"`
	Workers        int                  `json:"workers"`
	Jobs           int                  `json:"jobs"`
	Contradictions int                  `json:"contradictions"`
	RefutedBelow   *float64             `json:"refuted_below"`
	Identified     bool                 `json:"identified"`
	MaxInSystem    int                  `json:"max_in_system"`
	Waited         int                  `json:"waited"`
	ShortfallZ     *float64             `json:"shortfall_z"`
	ShortfallRel   *float64             `json:"shortfall_rel"`
	RefutedBy      map[string]string    `json:"refuted_by"`
	B              []float64            `json:"b"`
}

func closeOrNaN(got float64, want *float64) bool {
	if want == nil {
		return math.IsNaN(got)
	}
	return math.Abs(got-*want) <= 1e-9*math.Max(1, math.Abs(*want))
}

// The reference implementation's outputs on the same inputs (testdata/fifo_golden.json; the script that made it is
// not published):
// queue order, start of service of every job, worker count, contradictions, waits and shortfall.
func TestFIFOGolden(t *testing.T) {
	raw, err := os.ReadFile(filepath.Join("testdata", "fifo_golden.json"))
	if err != nil {
		t.Fatal(err)
	}
	var g struct{ Cases []goldenCase }
	if err := json.Unmarshal(raw, &g); err != nil {
		t.Fatal(err)
	}
	if len(g.Cases) < 5 {
		t.Fatalf("only %d cases", len(g.Cases))
	}
	for _, c := range g.Cases {
		q := inferWorkers(c.A, c.D, 0)
		if !slices.Equal(q.Order, c.Order) {
			t.Errorf("%s: queue order differs", c.Name)
		}
		if !slices.Equal(q.B, c.B) {
			t.Errorf("%s: start of service differs", c.Name)
		}
		// the reference's "identified" is EnoughWaits; these are real queues, so their waits are material too
		if q.Workers != c.Workers || q.Jobs != c.Jobs || q.Contradictions != c.Contradictions || q.EnoughWaits != c.Identified ||
			q.Identified != c.Identified || q.MaxInSystem != c.MaxInSystem || q.Waited != c.Waited {
			t.Errorf("%s: got workers %d jobs %d contradictions %d identified %v/%v max %d waited %d; want %d %d %d %v %d %d", c.Name,
				q.Workers, q.Jobs, q.Contradictions, q.EnoughWaits, q.Identified, q.MaxInSystem, q.Waited,
				c.Workers, c.Jobs, c.Contradictions, c.Identified, c.MaxInSystem, c.Waited)
		}
		if !closeOrNaN(q.ShortfallZ, c.ShortfallZ) || !closeOrNaN(q.ShortfallRel, c.ShortfallRel) || !closeOrNaN(q.RefutedBelow, c.RefutedBelow) {
			t.Errorf("%s: shortfall z %v rel %v below %v; want %v %v %v", c.Name, q.ShortfallZ, q.ShortfallRel, q.RefutedBelow,
				c.ShortfallZ, c.ShortfallRel, c.RefutedBelow)
		}
		if len(q.RefutedBy) != len(c.RefutedBy) {
			t.Errorf("%s: refuted by %v, want %v", c.Name, q.RefutedBy, c.RefutedBy)
		}
		for k, v := range q.RefutedBy {
			if c.RefutedBy[strconv.Itoa(k)] != v {
				t.Errorf("%s: refuted by %v, want %v", c.Name, q.RefutedBy, c.RefutedBy)
			}
		}
		for k, want := range c.FIFO {
			kk, err := strconv.Atoi(k)
			if err != nil {
				t.Fatal(err)
			}
			if got := fifoStart(q.A, q.D, kk); !slices.Equal(got, want) {
				t.Errorf("%s: start of service with %d workers differs", c.Name, kk)
			}
		}
	}
}

// A service faster than the jitter allowance: 0.12 ms per request, arrivals 6000/s, nobody waits. At one
// worker no wait passes jitterMs and no service time is negative, so the reference's tests both pass and it
// reads 1 worker with the overlaps' invented waits taken out of the service time. The brief-wait test refutes that.
func TestInferWorkersFasterThanJitter(t *testing.T) {
	rng := rand.New(rand.NewSource(11))
	var a, d []float64
	x := 0.0
	for i := 0; i < 3000; i++ {
		x += rng.ExpFloat64() / 6
		a = append(a, x)
		d = append(d, x+0.12*(0.9+0.2*rng.Float64()))
	}
	b1 := fifoStart(a, d, 1)
	for i := range b1 {
		if b1[i]-a[i] > jitterMs || d[i]-b1[i] < -jitterMs {
			t.Fatalf("job %d: at one worker the reference's tests would see it (wait %.3f, service %.3f)", i, b1[i]-a[i], d[i]-b1[i])
		}
	}
	q := inferWorkers(a, d, 0)
	if q.Workers < 2 || q.RefutedBy[1] != "brief-wait shortfall" || q.Identified {
		t.Fatalf("workers %d refuted %v identified %v", q.Workers, q.RefutedBy, q.Identified)
	}
	s := 0.0
	for i := range q.B {
		s += q.D[i] - q.B[i]
	}
	if m := s / float64(len(q.B)); math.Abs(m-0.12) > 0.02*0.12 {
		t.Errorf("service time %.4f ms, want about 0.12 (workers %d)", m, q.Workers)
	}
}

// Pods with fewer than minPodJobs spans are left out of their service's queues (as in the reference), unless
// every pod of the service is that small: then all are rebuilt rather than none.
func TestReconstructQueuesSmallPods(t *testing.T) {
	var v []visitRec
	add := func(pod, svc int32, n int) {
		for i := 0; i < n; i++ {
			st := uint64(i) * 10_000_000 // 10 ms apart, 2 ms each
			v = append(v, visitRec{pod: pod, svc: svc, start: st, rel: st + 2_000_000, own: 2})
		}
	}
	add(0, 0, 25)
	add(1, 0, 5)
	add(2, 1, 5)
	add(3, 1, 6)
	q := reconstructQueues(v, 2, nil)
	if len(q[0].pods) != 1 || q[0].jobs != 25 {
		t.Errorf("service 0: %d pods, %d jobs; want the 25-job pod only", len(q[0].pods), q[0].jobs)
	}
	if len(q[1].pods) != 2 || q[1].jobs != 11 {
		t.Errorf("service 1: %d pods, %d jobs; want both small pods", len(q[1].pods), q[1].jobs)
	}
	if q[0].workers != 1 || math.Abs(q[0].relMean-2) > 1e-9 || q[0].waitMean != 0 {
		t.Errorf("service 0: workers %d service %.6f wait %.6f", q[0].workers, q[0].relMean, q[0].waitMean)
	}
}

// A job released at its own arrival (its first call starts at or before its span's start, so the release is
// clipped to the start) still needs a worker at that instant. The reference's sweep took its release off before
// counting it, so a pod whose long visit A overlaps three such visits read 1 in the system at once, the search
// for the worker count stopped at 1, and every one of them came out 7-9 ms negative.
func TestMaxInSystemCountsInstantJobs(t *testing.T) {
	a := []float64{0, 1, 2, 3}
	d := []float64{10, 1, 2, 3}
	if got := maxInSystem(a, d); got != 2 {
		t.Errorf("got %d, want 2 (A and each instant job)", got)
	}
	var aa, dd []float64 // the same, ten times over (three contradictions pass as jitter)
	for g := 0; g < 10; g++ {
		for i := range a {
			aa, dd = append(aa, a[i]+50*float64(g)), append(dd, d[i]+50*float64(g))
		}
	}
	if q := inferWorkers(aa, dd, 0); q.Workers != 2 || q.Contradictions != 0 {
		t.Errorf("workers %d with %d contradictions, want 2 and 0", q.Workers, q.Contradictions)
	}
	// a release at the instant of another job's arrival frees its worker first
	if got := maxInSystem([]float64{0, 1, 1}, []float64{1, 2, 3}); got != 2 {
		t.Errorf("got %d, want 2", got)
	}
}
