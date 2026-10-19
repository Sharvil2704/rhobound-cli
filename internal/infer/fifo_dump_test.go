// SPDX-License-Identifier: Apache-2.0

package infer_test

import (
	"encoding/json"
	"math"
	"math/rand"
	"os"
	"sort"
	"testing"
)

// TestDumpFIFOInputs writes per-pod (arrival, release) arrays from simulated
// captures, for the cross-check against the reference implementation:
//
//	FIFO_DUMP=/path/inputs.json go test -count=1 ./internal/infer -run DumpFIFOInputs
//
// The reference implementation's outputs on these inputs are
// testdata/fifo_golden.json, which TestFIFOGolden reads (the script that
// made it is not published).
func TestDumpFIFOInputs(t *testing.T) {
	path := os.Getenv("FIFO_DUMP")
	if path == "" {
		t.Skip("FIFO_DUMP not set")
	}
	type pc struct {
		Name string    `json:"name"`
		A    []float64 `json:"a"`
		D    []float64 `json:"d"`
	}
	var cases []pc
	// per pod: a = the server span's start, d = its first client span's start, else its end
	pods := func(out *simOut) map[string]*pc {
		first := map[string]float64{}
		for _, sp := range out.spans {
			if sp.kind == 3 {
				if v, ok := first[sp.parent]; !ok || sp.start < v {
					first[sp.parent] = sp.start
				}
			}
		}
		m := map[string]*pc{}
		for _, sp := range out.spans {
			if sp.kind != 2 {
				continue
			}
			p := m[sp.pod]
			if p == nil {
				p = &pc{Name: sp.pod}
				m[sp.pod] = p
			}
			d, ok := first[sp.id]
			if !ok {
				d = sp.end
			}
			p.A, p.D = append(p.A, sp.start), append(p.D, d)
		}
		return m
	}
	add := func(prefix string, out *simOut, which ...string) {
		m := pods(out)
		var keys []string
		for k := range m {
			keys = append(keys, k)
		}
		sort.Strings(keys)
		for _, k := range keys {
			for _, w := range which {
				if w == k {
					p := m[k]
					p.Name = prefix + "/" + k
					cases = append(cases, *p)
				}
			}
		}
	}
	// the chain a(1) -> b(2) -> c(1), spans include the wait / start at service
	add("chain-spanq", run(chain(), 50, 15, 7, true), "a-0", "b-0", "c-0")
	add("chain-default", run(chain(), 50, 15, 7, false), "b-0")
	// two replicas of one worker, spans include the wait
	rb := &node{name: "b", c: 1, pods: 2, mean: 30, dist: "h2", cs2: 3}
	add("replicas-spanq", run(&node{name: "a", c: 4, pods: 1, mean: 3, children: []*node{rb}}, 45, 30, 3, true), "b-0", "b-1")
	// four workers, low-variance service, spans include the wait
	q4 := &node{name: "q", c: 4, pods: 1, mean: 20, dist: "gamma", cs2: 0.25}
	add("c4-spanq", run(q4, 150, 8, 5, true), "q-0")
	// jitter: clock noise on the releases and arrivals rounded to 0.1 ms (ties, contradictions)
	out := run(chain(), 50, 15, 9, true)
	rng := rand.New(rand.NewSource(17))
	m := pods(out)
	p := *m["b-0"]
	p.Name = "jitter/b-0"
	for i := range p.A {
		p.A[i] = math.Round(p.A[i]*10) / 10
		p.D[i] += 0.3 * rng.NormFloat64()
	}
	cases = append(cases, p)
	// pairs 1 ms apart that two workers serve at once: at one worker the second of each pair waits for the
	// first and keeps only the gap as its service time, a shortfall with no contradiction
	pp := pc{Name: "pairs/hand"}
	for k := 0; k < 60; k++ {
		t0, s := 50*float64(k), 10+0.1*float64(k%7)
		pp.A = append(pp.A, t0, t0+1)
		pp.D = append(pp.D, t0+s, t0+1+s+0.05*float64(k%3))
	}
	cases = append(cases, pp)
	// times as a trace holds them: whole nanoseconds
	for _, c := range cases {
		for i := range c.A {
			c.A[i] = math.Round(c.A[i]*1e6) / 1e6
			c.D[i] = math.Round(c.D[i]*1e6) / 1e6
		}
	}
	f, err := os.Create(path)
	if err != nil {
		t.Fatal(err)
	}
	defer f.Close()
	if err := json.NewEncoder(f).Encode(map[string]any{"cases": cases}); err != nil {
		t.Fatal(err)
	}
}
