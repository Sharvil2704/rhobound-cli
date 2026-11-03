package catalog

import "testing"

func TestSearchFindsTitles(t *testing.T) {
	ids := Search([]string{"oak", "lamp"}, 20)
	if len(ids) == 0 || len(ids) > 20 {
		t.Fatalf("got %d hits", len(ids))
	}
	for _, id := range ids {
		if id < 0 || id >= len(products) {
			t.Fatalf("id %d out of range", id)
		}
	}
	if got := Search([]string{"nosuchword"}, 20); len(got) != 0 {
		t.Fatalf("unknown word matched %v", got)
	}
}

func BenchmarkSearch(b *testing.B) {
	for b.Loop() {
		Search(query(), 20)
	}
}
