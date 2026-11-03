// SPDX-License-Identifier: Apache-2.0

package model

import (
	"encoding/json"
	"os"
	"testing"
)

// TestBatchSweepDump solves the queues of a DES sweep file (RB_BATCH_SWEEP, des.py's configs) and writes the model's
// numbers to RB_BATCH_SWEEP_OUT. It is a validation tool, skipped unless the variables are set.
func TestBatchSweepDump(t *testing.T) {
	in, out := os.Getenv("RB_BATCH_SWEEP"), os.Getenv("RB_BATCH_SWEEP_OUT")
	if in == "" || out == "" {
		t.Skip("RB_BATCH_SWEEP and RB_BATCH_SWEEP_OUT not set")
	}
	raw, err := os.ReadFile(in)
	if err != nil {
		t.Fatal(err)
	}
	var cfgs []struct {
		ID      string  `json:"id"`
		C       int     `json:"c"`
		S       float64 `json:"s"`
		CS2     float64 `json:"cs2"`
		Classes []struct {
			Rate  float64      `json:"rate"`
			Sizes [][2]float64 `json:"sizes"`
		} `json:"classes"`
		Variants [][2]float64 `json:"variants"`
		Post     *struct {
			P    float64 `json:"p"`
			Mean float64 `json:"mean"`
			CS2  float64 `json:"cs2"`
		} `json:"post"`
	}
	if err := json.Unmarshal(raw, &cfgs); err != nil {
		t.Fatal(err)
	}
	type vout struct {
		S, CS2, W0, Wbar float64
		MS               map[int]float64
	}
	res := map[string][]vout{}
	for _, cf := range cfgs {
		kmax := 1
		for _, cl := range cf.Classes {
			for _, sz := range cl.Sizes {
				kmax = max(kmax, int(sz[0]))
			}
		}
		lam := 0.0
		q := make([]float64, kmax+1)
		for _, cl := range cf.Classes {
			lam += cl.Rate
		}
		var sizes []int
		for _, cl := range cf.Classes {
			tw := 0.0
			for _, sz := range cl.Sizes {
				tw += sz[1]
			}
			for _, sz := range cl.Sizes {
				q[int(sz[0])] += cl.Rate / lam * sz[1] / tw
				sizes = append(sizes, int(sz[0]))
			}
		}
		for _, v := range cf.Variants {
			s := cf.S*v[1] + v[0]
			cs2 := cf.CS2 * (cf.S * v[1]) * (cf.S * v[1]) / (s * s)
			m := &mxq{c: cf.C, s: s, cs2: max(cs2, batchMinCS2), lam: lam, q: q}
			sol, err := m.solve(sizes)
			if err != nil {
				t.Fatalf("%s: %v", cf.ID, err)
			}
			o := vout{S: s, CS2: cs2, W0: sol.W0, Wbar: sol.Wbar, MS: map[int]float64{}}
			for _, k := range sizes {
				o.MS[k] = sol.MS[k]
				if cf.Post != nil {
					law := postLaw{p0: 1 - cf.Post.P, m: cf.Post.Mean, v: cf.Post.CS2 * cf.Post.Mean * cf.Post.Mean}
					o.MS[k] += postExtra(k, s/float64(cf.C), law)
				}
			}
			res[cf.ID] = append(res[cf.ID], o)
		}
	}
	b, _ := json.Marshal(res)
	if err := os.WriteFile(out, b, 0o644); err != nil {
		t.Fatal(err)
	}
}
