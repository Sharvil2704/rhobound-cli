// SPDX-License-Identifier: Apache-2.0

package model

import (
	"encoding/json"
	"math"
	"os"
	"testing"
)

type goldenCase struct {
	Name          string          `json:"name"`
	Lam           float64         `json:"lam"`
	Topology      json.RawMessage `json:"topology"`
	DS            []float64       `json:"ds"`
	BaseStable    bool            `json:"base_stable"`
	PatchedStable bool            `json:"patched_stable"`
	RhoBySvc      []float64       `json:"rho_by_service"`
	LamBySvc      []float64       `json:"lam_by_service"`
	R             []float64       `json:"R"`
	L             []float64       `json:"L"`
	RPatched      []float64       `json:"R_patched"`
	LPatched      []float64       `json:"L_patched"`
}

func relClose(got, want, tol float64) bool {
	if got == want {
		return true
	}
	return math.Abs(got-want) <= tol*math.Max(1, math.Abs(want))
}

func checkVec(t *testing.T, name, what string, got, want []float64, tol float64) {
	t.Helper()
	if len(got) != len(want) {
		t.Fatalf("%s %s: %d values, want %d", name, what, len(got), len(want))
	}
	for i := range got {
		if !relClose(got[i], want[i], tol) {
			t.Errorf("%s %s[%d]: got %.15g want %.15g (rel %.2e)", name, what, i, got[i], want[i],
				math.Abs(got[i]-want[i])/math.Max(1, math.Abs(want[i])))
			return
		}
	}
}

// TestGolden checks the Go solver against the reference implementation's
// results on files and randomised topologies (see testdata/golden).
func TestGolden(t *testing.T) {
	raw, err := os.ReadFile("../../testdata/golden/golden.json")
	if err != nil {
		t.Fatal(err)
	}
	var doc struct {
		Cases []goldenCase `json:"cases"`
	}
	if err := json.Unmarshal(raw, &doc); err != nil {
		t.Fatal(err)
	}
	if len(doc.Cases) < 100 {
		t.Fatalf("only %d golden cases", len(doc.Cases))
	}
	const tol = 1e-10
	worst := 0.0
	for _, c := range doc.Cases {
		topo, err := ParseTopology(c.Topology)
		if err != nil {
			t.Fatalf("%s: %v", c.Name, err)
		}
		b, err := Analytic(topo, c.Lam, nil)
		if err != nil {
			t.Fatalf("%s: %v", c.Name, err)
		}
		if b.Stable != c.BaseStable {
			t.Errorf("%s: base stable=%v, reference %v", c.Name, b.Stable, c.BaseStable)
			continue
		}
		if b.Stable {
			checkVec(t, c.Name, "rho", b.Rho, c.RhoBySvc, tol)
			checkVec(t, c.Name, "lam", b.Lam, c.LamBySvc, tol)
			checkVec(t, c.Name, "R", b.R, c.R, tol)
			checkVec(t, c.Name, "L", b.L, c.L, tol)
			for i := range b.L {
				worst = math.Max(worst, math.Abs(b.L[i]-c.L[i])/math.Max(1, math.Abs(c.L[i])))
			}
		}
		p, err := Analytic(topo, c.Lam, c.DS)
		if err != nil {
			t.Fatalf("%s: %v", c.Name, err)
		}
		if p.Stable != c.PatchedStable {
			t.Errorf("%s: patched stable=%v, reference %v", c.Name, p.Stable, c.PatchedStable)
			continue
		}
		if p.Stable {
			checkVec(t, c.Name, "R patched", p.R, c.RPatched, tol)
			checkVec(t, c.Name, "L patched", p.L, c.LPatched, tol)
		}
	}
	t.Logf("%d golden cases; worst relative difference in L: %.2e", len(doc.Cases), worst)
}
