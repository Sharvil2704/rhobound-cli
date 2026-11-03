package img

import "testing"

func BenchmarkDecode8(b *testing.B) {
	bodies := make([][]byte, 8)
	for i := range bodies {
		bodies[i] = make([]byte, 16<<10)
	}
	for b.Loop() {
		Decode(bodies)
	}
}
