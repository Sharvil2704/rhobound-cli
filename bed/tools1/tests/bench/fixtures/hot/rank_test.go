package hot

import "testing"

func TestRank(t *testing.T) {
	if got := Rank("café"); got != 4 {
		t.Fatalf("Rank(café) = %d, want 4", got)
	}
}

func BenchmarkRank(b *testing.B) {
	for i := 0; i < b.N; i++ {
		Rank("ＴＶ remote café")
	}
}
