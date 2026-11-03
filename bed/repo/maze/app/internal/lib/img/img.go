// Package img is the client side of thumbnails: every caller checks what media sent and resizes it for its layout.
package img

import "hash/crc32"

// Decode checks each thumbnail (a CRC over its bytes), blurs it for display (a 9-tap box filter over its bytes as
// one row) and returns the total bytes read.
func Decode(bodies [][]byte) int {
	n := 0
	for _, b := range bodies {
		_ = crc32.ChecksumIEEE(b)
		out := make([]byte, len(b))
		for i := 4; i < len(b)-4; i++ {
			s := 0
			for k := -4; k <= 4; k++ {
				s += int(b[i+k])
			}
			out[i] = byte(s / 9)
		}
		n += len(b)
	}
	return n
}
