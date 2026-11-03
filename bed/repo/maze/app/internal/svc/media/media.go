// Package media renders product thumbnails: a box-filtered downscale of the source image to ThumbKB of pixels.
package media

import (
	"sync/atomic"

	"maze/internal/rt"
)

// ThumbKB is the size of one thumbnail.
const ThumbKB = 16

var n atomic.Uint64

// Thumb downsamples a deterministic 4x-larger source image into ThumbKB bytes.
func Thumb(seed uint64) []byte {
	out := make([]byte, ThumbKB<<10)
	for i := range out {
		s := 0
		for k := range 4 {
			s += int((seed + uint64(i*4+k)*2654435761) >> 24 & 0xff)
		}
		out[i] = byte(s / 4)
	}
	return out
}

func init() {
	rt.Register("media.thumb", func(r *rt.Req) error {
		r.Out = Thumb(n.Add(1))
		return nil
	})
}
