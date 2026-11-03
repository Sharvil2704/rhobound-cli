//go:build hidden

package catalog

import "testing"

func TestHiddenHello(t *testing.T) {
	if got := Hello(); got != "hi" {
		t.Fatalf("Hello() = %q, want %q", got, "hi")
	}
}

func TestHiddenSearchUnchanged(t *testing.T) {
	if len(Search([]string{"oak"}, 5)) == 0 {
		t.Fatal("Search finds no oak")
	}
}
