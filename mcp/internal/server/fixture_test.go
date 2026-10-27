// SPDX-License-Identifier: Apache-2.0

package server

import (
	"encoding/json"
	"os"
	"path/filepath"
	"testing"
	"time"
)

// The scripted agent's fixture is testdata/mcp/loop (testdata/mcp/README.md): testdata/capture-chain with image digests
// and its request count, as a capture folder, plus
//
//	ab/baseline/          arm A of the A/B run of b, with the load generator's loadgen.csv
//	ab/candidate/         arm B: b's image changed, +0.4 ms of own time per visit of b
//	judge-answer.json     the canned judge answer to the block (decision revise, one expected operation)
//	policy.json           the policy: a 5% threshold, every other key at its default
//
// testdata/mcp/hostile is the hostile-names capture.

// loopFixture is where the scripted agent's inputs are.
type loopFixture struct {
	capture, baseline, candidate string
	answer, policy               []byte
	windowEnd                    time.Time // the end of the capture's window, from its request count
}

// loop returns the scripted agent's fixture.
func loop(t *testing.T) loopFixture {
	t.Helper()
	realCLI(t)
	dir := filepath.Join(real.root, "testdata", "mcp", "loop")
	fx := loopFixture{capture: dir, baseline: filepath.Join(dir, "ab", "baseline"), candidate: filepath.Join(dir, "ab", "candidate")}
	for _, p := range []string{filepath.Join(dir, "traces"), filepath.Join(fx.baseline, "traces"),
		filepath.Join(fx.candidate, "traces"), filepath.Join(fx.baseline, "loadgen.csv")} {
		if _, err := os.Stat(p); err != nil {
			t.Fatalf("testdata/mcp/loop does not have the layout the scripted agent reads (fixture_test.go): %v", err)
		}
	}
	var err error
	if fx.answer, err = os.ReadFile(filepath.Join(dir, "judge-answer.json")); err != nil {
		t.Fatal(err)
	}
	if fx.policy, err = os.ReadFile(filepath.Join(dir, "policy.json")); err != nil {
		t.Fatal(err)
	}
	fx.windowEnd = windowEnd(t, dir)
	return fx
}

// hostileCapture is the folder of the hostile-names capture.
func hostileCapture(t *testing.T) string {
	t.Helper()
	realCLI(t)
	dir := filepath.Join(real.root, "testdata", "mcp", "hostile")
	if _, err := os.Stat(filepath.Join(dir, "traces")); err != nil {
		t.Fatalf("the hostile-names capture: %v", err)
	}
	return dir
}

// windowEnd is the end of a capture's window, as its request count states it.
func windowEnd(t *testing.T, dir string) time.Time {
	t.Helper()
	b, err := os.ReadFile(filepath.Join(dir, "request-count.json"))
	if err != nil {
		t.Fatal(err)
	}
	var rc struct {
		Window struct{ End time.Time } `json:"window"`
	}
	if err := json.Unmarshal(b, &rc); err != nil || rc.Window.End.IsZero() {
		t.Fatalf("the capture's request count has no window end: %v", err)
	}
	return rc.Window.End
}
