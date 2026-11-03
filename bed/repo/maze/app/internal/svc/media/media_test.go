package media

import "testing"

func BenchmarkThumb(b *testing.B) {
	for b.Loop() {
		Thumb(7)
	}
}
