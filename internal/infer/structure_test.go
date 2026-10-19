// SPDX-License-Identifier: Apache-2.0

package infer

import (
	"encoding/json"
	"math"
	"os"
	"path/filepath"
	"slices"
	"sort"
	"strings"
	"testing"
)

// TestStageGolden: the stage template and its shares equal the reference implementation's on the shapes in
// testdata/stage_golden.json (the reference's outputs; the script that made them is not published).
func TestStageGolden(t *testing.T) {
	raw, err := os.ReadFile(filepath.Join("testdata", "stage_golden.json"))
	if err != nil {
		t.Fatal(err)
	}
	var doc struct {
		Cases []struct {
			Name   string `json:"name"`
			Shapes []struct {
				Stages [][]string `json:"stages"`
				Visits int64      `json:"visits"`
			} `json:"shapes"`
			Nsp      int64 `json:"nsp"`
			Expected *struct {
				Stages [][]string `json:"stages"`
				Ran    []float64  `json:"ran"`
				Fit    float64    `json:"fit"`
			} `json:"expected"`
		} `json:"cases"`
	}
	if err := json.Unmarshal(raw, &doc); err != nil {
		t.Fatal(err)
	}
	if len(doc.Cases) < 10 {
		t.Fatalf("only %d cases", len(doc.Cases))
	}
	for _, c := range doc.Cases {
		// callee ids in name order, as the inference numbers services
		seen := map[string]bool{}
		for _, s := range c.Shapes {
			for _, g := range s.Stages {
				for _, n := range g {
					seen[n] = true
				}
			}
		}
		var names []string
		for n := range seen {
			names = append(names, n)
		}
		sort.Strings(names)
		id := map[string]int32{}
		for i, n := range names {
			id[n] = int32(i)
		}
		sigs := map[string]int64{}
		for _, s := range c.Shapes {
			var sig stageSig
			for _, g := range s.Stages {
				var st []int32
				for _, n := range g {
					st = append(st, id[n])
				}
				slices.Sort(st)
				sig = append(sig, st)
			}
			if len(sig) > 0 {
				sigs[sig.key()] += s.Visits
			}
		}
		tm, ran, fit, ok := stageTemplate(sigs, c.Nsp)
		if !ok || c.Expected == nil {
			if ok != (c.Expected != nil) {
				t.Errorf("%s: template found %v, the reference %v", c.Name, ok, c.Expected != nil)
			}
			continue
		}
		var got [][]string
		for _, g := range tm {
			var st []string
			for _, x := range g {
				st = append(st, names[x])
			}
			got = append(got, st)
		}
		if gs, ws := stagesText(got), stagesText(c.Expected.Stages); gs != ws {
			t.Errorf("%s: template %s, the reference %s", c.Name, gs, ws)
			continue
		}
		if math.Abs(fit-c.Expected.Fit) > 1e-12 {
			t.Errorf("%s: fit %v, the reference %v", c.Name, fit, c.Expected.Fit)
		}
		for j := range ran {
			if math.Abs(ran[j]-c.Expected.Ran[j]) > 1e-12 {
				t.Errorf("%s: stage %d ran %v, the reference %v", c.Name, j, ran[j], c.Expected.Ran[j])
			}
		}
	}
}

func stagesText(st [][]string) string {
	var parts []string
	for _, g := range st {
		parts = append(parts, strings.Join(g, " "))
	}
	return strings.Join(parts, " | ")
}

// TestCallCount: the reference's rule for calls per visit.
func TestCallCount(t *testing.T) {
	for _, c := range []struct {
		hist   map[int]int64
		nsp    int64
		k      int
		p, oth float64
		refuse bool
	}{
		{map[int]int64{1: 1000}, 1000, 1, 0, 0, false},          // always once
		{map[int]int64{2: 1000}, 1000, 2, 0, 0, false},          // always twice
		{map[int]int64{1: 300}, 1000, 0, 0.3, 0, false},         // once on 30% of visits
		{map[int]int64{1: 15}, 1000, 0, 0.015, 0, false},        // a rare call is kept, not dropped
		{map[int]int64{1: 985}, 1000, 0, 0.985, 0, false},       // a near-certain call is not rounded up
		{map[int]int64{1: 700, 2: 300}, 1000, 1, 0.3, 0, false}, // once, and a second time on 30%
		{map[int]int64{1: 500, 3: 500}, 1000, 0, 0, 0, true},    // 1 or 3: no form for it
		{map[int]int64{2: 400}, 1000, 0, 0, 0, true},            // 0 or 2
		{map[int]int64{1: 250, 2: 500, 3: 250}, 1000, 0, 0, 0, true},
		{map[int]int64{1: 700, 2: 295, 3: 5}, 1000, 1, 0.295, 0.005, false}, // 99.5% agree: the rest is ignored
		{map[int]int64{1: 700, 2: 285, 3: 15}, 1000, 0, 0, 0, true},         // 98.5%: refused
	} {
		k, p, oth, err := callCount(c.hist, c.nsp)
		if (err != nil) != c.refuse {
			t.Errorf("%v of %d: err %v, want refused %v", c.hist, c.nsp, err, c.refuse)
			continue
		}
		if err == nil && (k != c.k || math.Abs(p-c.p) > 1e-12 || math.Abs(oth-c.oth) > 1e-12) {
			t.Errorf("%v of %d: k %d p %v other %v, want %d %v %v", c.hist, c.nsp, k, p, oth, c.k, c.p, c.oth)
		}
	}
}

// TestStagesOf: the reference's stage split, by start and the latest end of the stage so far.
func TestStagesOf(t *testing.T) {
	cs := []call{{callee: 1, start: 0, end: 10}, {callee: 2, start: 1, end: 5}, {callee: 3, start: 6, end: 8},
		{callee: 4, start: 10, end: 12}, {callee: 5, start: 12, end: 13}}
	got := sigOf(cs, stagesOf(cs)).key()
	if want := "1,2,3|4|5"; got != want {
		t.Errorf("stages %q, want %q (3 starts before 1 ends; 4 starts when 1 ends; 5 when 4 ends)", got, want)
	}
	if s := parseSig(got).key(); s != got {
		t.Errorf("parseSig(key) = %q", s)
	}
}
