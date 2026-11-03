// Package layout renders the browse page: a template, then the thumbnails media sends.
package layout

import (
	"fmt"
	"strings"

	"maze/internal/lib/img"
	"maze/internal/rt"
)

func init() {
	rt.Register("layout.render", func(r *rt.Req) error {
		var b strings.Builder
		for i := range 24 {
			fmt.Fprintf(&b, `<div class="tile" data-i="%d"></div>`, i)
		}
		r.Out = []byte(b.String())
		return nil
	})
	rt.Register("layout.decode", func(r *rt.Req) error {
		r.Out = fmt.Appendf(nil, `{"thumbs":%d,"bytes":%d}`, len(r.Bodies), img.Decode(r.Bodies))
		return nil
	})
}
