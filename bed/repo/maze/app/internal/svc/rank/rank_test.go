package rank

import "testing"

func BenchmarkRerank(b *testing.B) {
	for b.Loop() {
		Rerank(7)
	}
}
