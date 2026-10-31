package hot

import (
	"sort"
	"strings"
	"sync"
	"testing"
	"unicode"
)

// Visible tests: shapes and invariants only (no golden answers), through the exported API.

// visibleTokens is Rank's documented tokenization: maximal runs of letters and digits.
func visibleTokens(s string) []string {
	return strings.FieldsFunc(s, func(r rune) bool { return !unicode.IsLetter(r) && !unicode.IsDigit(r) })
}

func TestCatalogShape(t *testing.T) {
	docs := Catalog()
	if len(docs) != NumDocs {
		t.Fatalf("catalog has %d docs, want %d", len(docs), NumDocs)
	}
	for i, d := range docs {
		n := len(visibleTokens(Fold(d.Title)))
		if d.ID != i+1 || n < 4 || n > 13 || d.Cents < 199 || d.Cents > 49999 {
			t.Fatalf("doc %d: id %d, %d tokens, %d cents", i, d.ID, n, d.Cents)
		}
	}
	if &Catalog()[0] != &docs[0] {
		t.Fatal("the catalog is built more than once")
	}
}

func TestFoldLowerCasesASCII(t *testing.T) {
	if got := Fold("Hello, WORLD 42"); got != "hello, world 42" {
		t.Fatalf("Fold = %q", got)
	}
}

func TestRankInvariants(t *testing.T) {
	if h := Rank(""); len(h) != 0 {
		t.Fatalf("empty query: %v", h)
	}
	if h := Rank(" ,- / "); len(h) != 0 {
		t.Fatalf("query without terms: %v", h)
	}
	for _, q := range QueryLog()[:20] {
		hits := Rank(q)
		if len(hits) == 0 || len(hits) > TopK {
			t.Fatalf("%q: %d hits", q, len(hits))
		}
		if !sort.SliceIsSorted(hits, func(i, j int) bool {
			return hits[i].Score > hits[j].Score || hits[i].Score == hits[j].Score && hits[i].ID < hits[j].ID
		}) {
			t.Fatalf("%q: not by score desc, then ID asc: %v", q, hits)
		}
		terms := visibleTokens(Fold(q))
		for _, h := range hits {
			if h.Score <= 0 {
				t.Fatalf("%q: hit with score %v", q, h.Score)
			}
			toks := " " + strings.Join(visibleTokens(Fold(Catalog()[h.ID-1].Title)), " ") + " "
			found := false
			for _, term := range terms {
				found = found || strings.Contains(toks, " "+term+" ")
			}
			if !found {
				t.Fatalf("%q: doc %d holds no query term", q, h.ID)
			}
		}
	}
}

func TestRankDuplicateTermsCountOnce(t *testing.T) {
	q := QueryLog()[0]
	a, b := Rank(q), Rank(q+" "+strings.ToUpper(q))
	if len(a) != len(b) {
		t.Fatalf("%d vs %d hits", len(a), len(b))
	}
	for i := range a {
		if a[i] != b[i] {
			t.Fatalf("hit %d: %v vs %v", i, a[i], b[i])
		}
	}
}

func TestQuoteWithoutPromotion(t *testing.T) {
	d := Catalog()
	if got := Quote(""); got != 0 {
		t.Fatalf("empty cart: %d", got)
	}
	if got, want := Quote("1:2,3:1"), 2*d[0].Cents+d[2].Cents; got != want {
		t.Fatalf("Quote = %d, want %d", got, want)
	}
	if got, want := Quote("1:2,0:1,99999:1,x:1,2:0,2:100,5;NOSUCHCODE"), 2*d[0].Cents; got != want {
		t.Fatalf("bad items and an unknown code: %d, want %d", got, want)
	}
}

func TestQuotePromotionLowersTheTotal(t *testing.T) {
	plain, off := Quote("10:3,20:1"), Quote("10:3,20:1;SAVE10")
	if off >= plain || off < plain*85/100 {
		t.Fatalf("SAVE10: %d -> %d", plain, off)
	}
}

func TestGeneratorsAreSeededAndConcurrent(t *testing.T) {
	a, b := NewQueryGen(1), NewQueryGen(1)
	c, d := NewCartGen(1), NewCartGen(1)
	for i := 0; i < 50; i++ {
		if a.Next() != b.Next() || c.Next() != d.Next() {
			t.Fatal("same seed, different sequence")
		}
	}
	var wg sync.WaitGroup
	for i := 0; i < 4; i++ {
		wg.Add(1)
		go func() {
			defer wg.Done()
			for j := 0; j < 200; j++ {
				if NextQuery() == "" || NextCart() == "" {
					t.Error("empty input")
				}
			}
		}()
	}
	wg.Wait()
}
