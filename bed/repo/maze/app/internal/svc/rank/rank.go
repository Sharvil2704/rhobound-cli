// Package rank reorders candidates by a learned score: a dot product of each candidate's features with the weights.
package rank

import (
	"fmt"
	"sort"
	"sync/atomic"

	"maze/internal/rt"
)

const dims, cands = 32, 64

var weights = func() []float64 {
	w := make([]float64, dims)
	for i := range w {
		w[i] = float64((i*37)%11) / 10
	}
	return w
}()

var n atomic.Uint64

// Rerank scores cands candidates and returns their order.
func Rerank(seed uint64) []int {
	scores := make([]float64, cands)
	for c := range cands {
		s := 0.0
		for d := range dims {
			s += weights[d] * float64((seed+uint64(c*dims+d)*40503)%997) / 997
		}
		scores[c] = s
	}
	idx := make([]int, cands)
	for i := range idx {
		idx[i] = i
	}
	sort.Slice(idx, func(a, b int) bool { return scores[idx[a]] > scores[idx[b]] })
	return idx
}

func init() {
	rt.Register("rank.rerank", func(r *rt.Req) error {
		r.Out = fmt.Appendf(nil, "%v", Rerank(n.Add(1))[:10])
		return nil
	})
}
