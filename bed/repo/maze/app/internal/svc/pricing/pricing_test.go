package pricing

import "testing"

func TestQuote(t *testing.T) {
	if got := Quote([]Line{{Cents: 1000, Qty: 1}}); got != 1000 {
		t.Fatalf("one line: %d", got)
	}
	if got := Quote([]Line{{Cents: 1000, Qty: 10}}); got != 9500 {
		t.Fatalf("10 units: %d, want 9500", got)
	}
	if got := Quote([]Line{{Cents: 199, Qty: 30}}); got != 5492 {
		t.Fatalf("30 units: %d, want 5492", got)
	}
}

func BenchmarkQuote(b *testing.B) {
	for b.Loop() {
		Quote(cart(7))
	}
}
