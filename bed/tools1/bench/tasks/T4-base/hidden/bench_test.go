// rbd-bench hidden microbenchmarks (kit only), T4-base. One call per op on the production input distribution: the inputs
// are drawn ahead from the same seeded generators the service uses (NewQueryGen / NewCartGen, fixed seeds), so a
// per-input cache sees the hit rate it would see in production. sbx.sh runs them with -count 5 -benchmem, baseline and
// candidate interleaved.

package hot_test

import (
	"testing"

	"kshop/internal/hot"
)

// BenchmarkRank: catalog's code path "rank", hot.Rank(hot.NextQuery()).
func BenchmarkRank(b *testing.B) {
	g := hot.NewQueryGen(9001)
	qs := make([]string, 4096)
	for i := range qs {
		qs[i] = g.Next()
	}
	hot.Rank(qs[0])
	b.ResetTimer()
	for i := 0; i < b.N; i++ {
		hot.Rank(qs[i%len(qs)])
	}
}

// BenchmarkQuote: pricing's code path "quote", hot.Quote(hot.NextCart()).
func BenchmarkQuote(b *testing.B) {
	g := hot.NewCartGen(9002)
	cs := make([]string, 4096)
	for i := range cs {
		cs[i] = g.Next()
	}
	hot.Quote(cs[0])
	b.ResetTimer()
	for i := 0; i < b.N; i++ {
		hot.Quote(cs[i%len(cs)])
	}
}
