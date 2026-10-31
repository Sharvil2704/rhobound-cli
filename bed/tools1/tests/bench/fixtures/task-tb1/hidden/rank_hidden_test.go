package hot

import "testing"

func TestRankHidden(t *testing.T) {
	for q, want := range map[string]int{"": 0, "abc": 3, "ＴＶ": 2} {
		if got := Rank(q); got != want {
			t.Errorf("Rank(%q) = %d, want %d", q, got, want)
		}
	}
}
