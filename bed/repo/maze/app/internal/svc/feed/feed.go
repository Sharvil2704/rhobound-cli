// Package feed builds a member's feed: profile, follows, the posts' thumbnails, then a rerank.
package feed

import (
	"fmt"

	"maze/internal/lib/img"
	"maze/internal/rt"
)

func init() {
	rt.Register("feed.decode", func(r *rt.Req) error {
		r.Out = fmt.Appendf(nil, `{"parts":%d,"bytes":%d}`, len(r.Bodies), img.Decode(r.Bodies))
		return nil
	})
}
