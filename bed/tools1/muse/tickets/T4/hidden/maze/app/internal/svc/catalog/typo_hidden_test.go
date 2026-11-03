//go:build hidden

package catalog

import (
	"strings"
	"testing"
)

func has(ids []int, word string) bool {
	for _, id := range ids {
		for _, w := range strings.Fields(products[id].Title) {
			if w == word {
				return true
			}
		}
	}
	return false
}

func TestHiddenTypos(t *testing.T) {
	for typo, word := range map[string]string{"lanp": "lamp", "chaor": "chair", "lam": "lamp", "lamps": "lamp", "rug": "rug"} {
		if ids := Search([]string{typo}, 20); len(ids) == 0 || !has(ids, word) {
			t.Errorf("Search(%q) finds no %q: %v", typo, word, ids)
		}
	}
	if ids := Search([]string{"lxmxp"}, 20); len(ids) != 0 {
		t.Errorf("two edits away matched: %v", ids)
	}
}

func TestHiddenExactStillFound(t *testing.T) {
	for _, q := range []string{"oak", "steel lamp", "wool rug"} {
		for _, id := range Search(strings.Fields(q), 2000) {
			_ = id
		}
		exact := 0
		for _, p := range products {
			for _, w := range strings.Fields(q) {
				if strings.Contains(" "+p.Title+" ", " "+w+" ") {
					exact++
					break
				}
			}
		}
		if got := len(Search(strings.Fields(q), 2000)); got < exact {
			t.Errorf("%q: %d hits, fewer than the %d exact matches", q, got, exact)
		}
	}
}
