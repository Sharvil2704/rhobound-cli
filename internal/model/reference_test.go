// SPDX-License-Identifier: Apache-2.0

package model

import (
	"encoding/json"
	"math"
	"os"
	"testing"
)

// ErlangC against the Erlang-B recurrence in 50-digit decimal
// (testdata/numerics/gen_reference.py): 1 to 100000 servers at 1e-6 to 99.9%
// utilization. Below 1e-300 an absolute 1e-300 is allowed (subnormal range).
func TestErlangCReference(t *testing.T) {
	raw, err := os.ReadFile("../../testdata/numerics/reference.json")
	if err != nil {
		t.Fatal(err)
	}
	var ref struct {
		ErlangC [][3]float64 `json:"erlang_c"`
	}
	if err := json.Unmarshal(raw, &ref); err != nil {
		t.Fatal(err)
	}
	if len(ref.ErlangC) < 100 {
		t.Fatalf("only %d reference values", len(ref.ErlangC))
	}
	const tol = 1e-13 // measured 1.4e-14 (linux/arm64, Go 1.27)
	worst, wm, wa, wwant, wgot := 0.0, 0, 0.0, 0.0, 0.0
	for _, r := range ref.ErlangC {
		m, a, want := int(r[0]), r[1], r[2]
		got := ErlangC(m, a)
		e := 0.0
		if got != want && !(want < 1e-300 && math.Abs(got-want) <= 1e-300) {
			e = math.Abs(got-want) / want
		}
		if !(e <= worst) {
			worst, wm, wa, wwant, wgot = e, m, a, want, got
		}
	}
	t.Logf("ErlangC: worst relative error %.2e over %d values (tolerance %.0e) at m=%d a=%.17g: %.17g, got %.17g",
		worst, len(ref.ErlangC), tol, wm, wa, wwant, wgot)
	if !(worst <= tol) {
		t.Errorf("ErlangC(%d, %.17g) = %.17g, reference %.17g: relative error %.3e above %.0e", wm, wa, wgot, wwant, worst, tol)
	}
}
