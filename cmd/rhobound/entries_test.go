// SPDX-License-Identifier: Apache-2.0

package main

// The report's header, entries and async calls, and the utilization refusals, on the code review's captures
// (among them cap-inf). Each failed at 5b71d67.

import (
	"encoding/json"
	"fmt"
	"math"
	"math/rand"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// mm1 is cap-base's queue: one worker, exponential 10 ms, lam requests per ms; arrivals and ends.
func mm1(n int, lam float64, seed int64) (arr, end []float64) {
	rng := rand.New(rand.NewSource(seed))
	t, free := 0.0, 0.0
	for i := 0; i < n; i++ {
		t += rng.ExpFloat64() / lam
		b := math.Max(t, free)
		free = b + 10*rng.ExpFloat64()
		arr, end = append(arr, t), append(end, free)
	}
	return arr, end
}

// consumer-db: fe publishes a message on every visit (a PRODUCER span); a worker's CONSUMER span handles it 20 ms
// after fe's span ended and calls db (SERVER spans, one worker, exponential 8 ms). 3000 user requests, and db's
// 3000 visits are entries fed by the consumer. At 5b71d67 the header read "6000 entry requests (115.4 /s)".
func TestHeaderCountsConsumerEntriesApart(t *testing.T) {
	arr, end := mm1(3000, 0.06, 15)
	rng := rand.New(rand.NewSource(16))
	var spans []tspan
	id := 0
	next := func() string { id++; return fmt.Sprintf("%016x", id) }
	dbFree := 0.0
	for i := range arr {
		root, pr, co, cl := next(), next(), next(), next()
		c0 := end[i] + 20
		b := math.Max(c0+0.1, dbFree)
		dbFree = b + 8*rng.ExpFloat64()
		spans = append(spans, tspan{"fe", "fe-0", root, "", 2, arr[i], end[i], i + 1, ""},
			tspan{"fe", "fe-0", pr, root, 4, end[i] - 0.2, end[i] - 0.1, i + 1, ""},
			tspan{"worker", "worker-0", co, pr, 5, c0 - 0.1, dbFree + 0.3, i + 1, ""},
			tspan{"worker", "worker-0", cl, co, 3, c0, dbFree + 0.2, i + 1, "db"},
			tspan{"db", "db-0", next(), cl, 2, c0 + 0.1, dbFree, i + 1, ""})
	}
	out, errw, code := exec(t, "predict", writeCapture(t, spans))
	if code != 0 {
		t.Fatalf("exit %d: %s", code, errw)
	}
	if !strings.Contains(out, " 3000 entry requests (") || !strings.Contains(out, "+ 3000 from message consumers (") {
		t.Errorf("the header should count the consumer's entries apart:\n%s", out)
	}
	for _, l := range strings.Split(out, "\n") {
		f := strings.Fields(l)
		if len(f) > 1 && f[0] == "db" && f[1] != ">" || len(f) > 1 && f[0] == "fe" && f[1] != "*" {
			t.Errorf("row %q: db should be marked >, fe *", l)
		}
	}
	js, _, _ := exec(t, "predict", writeCapture(t, spans), "--json")
	var rep struct {
		Requests         int64 `json:"requests"`
		ConsumerRequests int64 `json:"consumer_requests"`
	}
	if err := json.Unmarshal([]byte(js), &rep); err != nil || rep.Requests != 6000 || rep.ConsumerRequests != 3000 {
		t.Errorf("JSON: requests %d, consumer_requests %d (%v)", rep.Requests, rep.ConsumerRequests, err)
	}
}

// gw-two: a gateway outside the capture calls fe, then be, in one trace. At 5b71d67 the capture was refused (3000
// of 3000 traces broken); now both are entries, and the header says how many traces the entries came in.
func TestHeaderGatewayEntries(t *testing.T) {
	arr, end := mm1(3000, 0.06, 12)
	rng := rand.New(rand.NewSource(13))
	var spans []tspan
	id := 0
	next := func() string { id++; return fmt.Sprintf("%016x", id) }
	beFree := 0.0
	for i := range arr {
		a := end[i] + 0.5
		b := math.Max(a, beFree)
		beFree = b + 5*rng.ExpFloat64()
		spans = append(spans, tspan{"fe", "fe-0", next(), next(), 2, arr[i], end[i], i + 1, ""},
			tspan{"be", "be-0", next(), next(), 2, a, beFree, i + 1, ""})
	}
	out, errw, code := exec(t, "predict", writeCapture(t, spans))
	if code != 0 || !strings.Contains(out, "6000 entry requests in 3000 traces (") {
		t.Errorf("exit %d: %s\n%s", code, errw, out)
	}
}

// async-int: 30% of fe's visits call analytics 50 ms after fe's span ended. The report says the call is async
// (load only), infer writes the flag, and model reads it back: a change at analytics gives fe +0 (at 5b71d67
// +34.92 ms for +100 ms).
func TestAsyncCallsInTheReport(t *testing.T) {
	arr, end := mm1(3000, 0.06, 11)
	rng := rand.New(rand.NewSource(14))
	var spans []tspan
	id := 0
	next := func() string { id++; return fmt.Sprintf("%016x", id) }
	for i := range arr {
		root := next()
		spans = append(spans, tspan{"fe", "fe-0", root, "", 2, arr[i], end[i], i + 1, ""})
		if rng.Float64() < 0.3 {
			cs, cl, d := end[i]+50, next(), 200*rng.ExpFloat64()
			spans = append(spans, tspan{"fe", "fe-0", cl, root, 3, cs, cs + d + 0.2, i + 1, "analytics"},
				tspan{"analytics", "analytics-0", next(), cl, 2, cs + 0.1, cs + 0.1 + d, i + 1, ""})
		}
	}
	capture := writeCapture(t, spans)
	out, errw, code := exec(t, "predict", capture, "--patch", "analytics=+100ms")
	if code != 0 {
		t.Fatalf("exit %d: %s", code, errw)
	}
	if !strings.Contains(out, "async calls (sent after the response)") || !strings.Contains(out, "fe -> analytics (0.") {
		t.Errorf("no async line in the report:\n%s", out)
	}
	for _, l := range strings.Split(out, "\n") {
		if f := strings.Fields(l); len(f) > 2 && f[0] == "fe" && f[1] == "*" && f[len(f)-2] != "+0.00" {
			t.Errorf("fe's change for analytics +100 ms: %q, want +0.00", l)
		}
	}
	topo, _, code := exec(t, "infer", capture)
	if code != 0 || !strings.Contains(topo, `"async": true`) {
		t.Fatalf("infer: exit %d\n%s", code, topo)
	}
	path := filepath.Join(t.TempDir(), "topo.json")
	if err := os.WriteFile(path, []byte(topo), 0o644); err != nil {
		t.Fatal(err)
	}
	js, errw, code := exec(t, "model", path, "--rps", "60", "--patch", "analytics=+100ms", "--json")
	if code != 0 {
		t.Fatalf("model: exit %d: %s", code, errw)
	}
	var rep struct {
		Async []struct {
			Caller, Callee string
		} `json:"async_calls"`
		Services []struct {
			Name     string   `json:"name"`
			ChangeMs *float64 `json:"change_ms"`
		} `json:"services"`
	}
	if err := json.Unmarshal([]byte(js), &rep); err != nil {
		t.Fatal(err)
	}
	if len(rep.Async) != 1 || rep.Async[0].Caller != "fe" || rep.Async[0].Callee != "analytics" {
		t.Errorf("model: async calls %+v", rep.Async)
	}
	for _, s := range rep.Services {
		if s.Name == "fe" && (s.ChangeMs == nil || *s.ChangeMs != 0) {
			t.Errorf("model: fe's change %v for analytics +100 ms, want 0", s.ChangeMs)
		}
	}
}

// A pod with no worker limit reads as a lower bound (the code review's cap-inf: 1 x 236+ at 85%; here 10 erlangs, about 20+). A
// change that takes it past --max-rho at that bound was refused at 5b71d67 as if the bound were the pool ("after
// the change fe would run at 89.0% utilization, above the limit of 85.0%"), and past 100% as "the change makes the
// system unstable", naming nothing. The refusal now names the service and says its count is only a lower bound, its
// utilization then an upper bound, and how to set the count; with --workers the change is predicted.
func TestLowerBoundPoolRefusal(t *testing.T) {
	rng := rand.New(rand.NewSource(9))
	var spans []tspan
	at := 0.0
	for i := 1; i <= 5000; i++ {
		at += rng.ExpFloat64() / 0.25
		spans = append(spans, tspan{"fe", "fe-0", fmt.Sprintf("%016x", i), "", 2, at, at + 40*rng.ExpFloat64(), i, ""})
	}
	capture := writeCapture(t, spans)
	js, errw, code := exec(t, "predict", capture, "--json")
	if code != 0 {
		t.Fatalf("exit %d: %s", code, errw)
	}
	var rep struct {
		Services []struct {
			Name    string  `json:"name"`
			Workers int     `json:"workers_per_pod"`
			Lower   bool    `json:"workers_are_a_lower_bound"`
			Own     float64 `json:"own_ms"`
			Util    float64 `json:"utilization"`
		} `json:"services"`
	}
	if err := json.Unmarshal([]byte(js), &rep); err != nil || len(rep.Services) != 1 || !rep.Services[0].Lower {
		t.Fatalf("want fe with a lower-bound worker count: %v\n%s", err, js)
	}
	fe := rep.Services[0]
	for _, after := range []float64{0.92, 1.1} { // past the limit, and past 100%
		ms := fe.Own * (after/fe.Util - 1)
		patch := fmt.Sprintf("fe=+%.3fms", ms)
		_, errw, code := exec(t, "predict", capture, "--patch", patch)
		want := []string{fmt.Sprintf("fe would run at %.1f%% utilization", 100*after), "above the limit of 85.0% (--max-rho",
			fmt.Sprintf("worker count of fe (1 x %d+) is only a lower bound", fe.Workers), "upper bound", "--workers fe=N"}
		if after > 1 {
			want[0] = "fe would pass 100% utilization"
		}
		for _, w := range want {
			if code != 1 || !strings.Contains(errw, w) {
				t.Errorf("%s (fe at %.0f%% after it): exit %d, the refusal does not say %q: %s", patch, 100*after, code, w, errw)
			}
		}
		// with the pool's size given, the change is predicted: about the added time, for a pool that never queues
		js, errw, code = exec(t, "predict", capture, "--patch", patch, "--workers", "fe=1000", "--json")
		var r2 struct {
			Services []struct {
				ChangeMs *float64 `json:"change_ms"`
			} `json:"services"`
		}
		if err := json.Unmarshal([]byte(js), &r2); code != 0 || err != nil || r2.Services[0].ChangeMs == nil ||
			math.Abs(*r2.Services[0].ChangeMs-ms) > 0.01*ms {
			t.Errorf("%s --workers fe=1000: exit %d %s %s", patch, code, errw, js)
		}
	}
}
