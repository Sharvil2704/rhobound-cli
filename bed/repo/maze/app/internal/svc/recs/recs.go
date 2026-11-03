// Package recs picks recommendation candidates for a member.
package recs

import (
	"fmt"
	"sync/atomic"

	"maze/internal/rt"
)

var n atomic.Uint64

func init() {
	rt.Register("recs.top", func(r *rt.Req) error {
		r.Out = fmt.Appendf(nil, `{"seed":%d}`, n.Add(1))
		return nil
	})
}
