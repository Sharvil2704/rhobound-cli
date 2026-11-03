// Package fraud scores a charge against the risk rules.
package fraud

import (
	"fmt"
	"sync/atomic"

	"maze/internal/rt"
)

var n atomic.Uint64

// Score returns a risk score in [0, 100) from the charge's features.
func Score(seed uint64) int {
	s := 0
	for rule := range 40 {
		if (seed>>uint(rule%16))&1 == 1 {
			s += rule % 7
		}
	}
	return s % 100
}

func init() {
	rt.Register("fraud.score", func(r *rt.Req) error {
		r.Out = fmt.Appendf(nil, `{"risk":%d}`, Score(n.Add(1)))
		return nil
	})
}
