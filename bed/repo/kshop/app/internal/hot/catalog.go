// Package hot is kshop's real CPU work (rbd-bench): a deterministic product catalog (Catalog), a search ranking
// (Rank, the catalog service's code path "rank"), cart pricing with promotions (Quote, pricing's code path "quote"),
// the text folding helper both of them share (Fold) and the seeded workload generators (NextQuery, NextCart).
//
// Contract: standard library only; no sleeps; every function is deterministic for its input (the generators for
// their seed) and safe for concurrent use. The catalog is built once per process (sync.Once) by its own splitmix64
// generator (seed 2026), so it is the same on every Go version and architecture.
package hot

import (
	"strings"
	"sync"
	"unicode"
	"unicode/utf8"
)

const (
	// NumDocs is the catalog's size; documents have IDs 1..NumDocs.
	NumDocs     = 8000
	catalogSeed = 2026
	vocabBase   = 3000 // words in all: generated ASCII words with their accented, kept-letter and full-width twins
)

// Doc is one product: its ID (1..NumDocs), its title (4 to 12 words) and its unit price in cents.
type Doc struct {
	ID    int
	Title string
	Cents int64
}

var (
	catOnce  sync.Once
	catDocs  []Doc
	catVocab []string
)

// Catalog returns the product documents, built on first use. The slice is shared: callers must not modify it.
func Catalog() []Doc {
	catOnce.Do(buildCatalog)
	return catDocs
}

// Vocabulary returns the words titles are drawn from (shared: do not modify).
func Vocabulary() []string {
	catOnce.Do(buildCatalog)
	return catVocab
}

// rng is splitmix64: tiny, fixed, and the same on every platform and Go release (math/rand's derived methods are not
// promised to stay stable).
type rng struct{ s uint64 }

func (r *rng) next() uint64 {
	r.s += 0x9e3779b97f4a7c15
	z := r.s
	z = (z ^ (z >> 30)) * 0xbf58476d1ce4e5b9
	z = (z ^ (z >> 27)) * 0x94d049bb133111eb
	return z ^ (z >> 31)
}

func (r *rng) intn(n int) int { return int(r.next() % uint64(n)) }

// float returns a uniform float64 in [0, 1).
func (r *rng) float() float64 { return float64(r.next()>>11) / (1 << 53) }

// skewed picks an index in [0, n) with small indices more likely (density ~ 1/(2 sqrt(x))): common and rare words.
func (r *rng) skewed(n int) int {
	u := r.float()
	return int(u * u * float64(n))
}

var (
	onsets = []string{"b", "c", "d", "f", "g", "h", "j", "k", "l", "m", "n", "p", "r", "s", "t", "v", "w", "z",
		"br", "cr", "dr", "fl", "gr", "pl", "st", "tr", "ch", "sh", "th", "qu"}
	nuclei = []string{"a", "e", "i", "o", "u", "a", "e", "o", "ai", "ea", "ou", "io", "y"}
	codas  = []string{"", "", "", "", "", "n", "r", "s", "l", "x", "m", "t"}
	// accented twins replace one vowel; Fold (today) keeps them distinct from their ASCII twin
	accents = map[byte][]string{
		'a': {"á", "à", "â", "ä", "ã", "å"}, 'e': {"é", "è", "ê", "ë"}, 'i': {"í", "ì", "î", "ï"},
		'o': {"ó", "ò", "ô", "ö", "õ", "ő"}, 'u': {"ú", "ù", "û", "ü", "ű"}, 'y': {"ý", "ÿ"},
		'c': {"ç", "č"}, 'n': {"ñ", "ń"}, 's': {"š", "ś"}, 'z': {"ž", "ź"},
	}
	// letters with no canonical decomposition (stay as they are under any fold that strips accents)
	kept = []string{"æ", "ø", "ß", "œ", "ł", "đ"}
	// fixed words a shop has, with twins that differ only by accents, case or width
	fixedWords = []string{"café", "cafe", "crème", "creme", "ñandú", "nandu", "ＴＶ", "tv", "ＵＳＢ", "usb", "ＨＤ", "hd",
		"résumé", "resume", "pâté", "pate", "jalapeño", "jalapeno", "über", "uber", "naïve", "naive", "smörgås", "smorgas"}
)

func syllable(r *rng) string {
	return onsets[r.intn(len(onsets))] + nuclei[r.intn(len(nuclei))] + codas[r.intn(len(codas))]
}

// accentTwin replaces the first letter that has accented forms; "" when the word has none.
func accentTwin(r *rng, w string) string {
	for i := 0; i < len(w); i++ {
		if forms, ok := accents[w[i]]; ok {
			return w[:i] + forms[r.intn(len(forms))] + w[i+1:]
		}
	}
	return ""
}

// fullWidth maps ASCII '!'..'~' to U+FF01..U+FF5E, upper-cased first.
func fullWidth(w string) string {
	var b strings.Builder
	for _, c := range strings.ToUpper(w) {
		if c >= '!' && c <= '~' {
			c += 0xFEE0
		}
		b.WriteRune(c)
	}
	return b.String()
}

func buildVocab(r *rng) []string {
	seen := map[string]bool{}
	var vocab []string
	add := func(w string) {
		if w != "" && !seen[w] {
			seen[w] = true
			vocab = append(vocab, w)
		}
	}
	for len(vocab) < vocabBase-len(fixedWords) {
		w := ""
		for n := 1 + r.intn(2); n > 0; n-- {
			w += syllable(r)
		}
		if len(w) < 3 || seen[w] {
			continue
		}
		add(w)
		switch r.intn(50) {
		case 0, 1, 2: // ~6%: an accented twin next to the plain word
			add(accentTwin(r, w))
		case 3: // ~2%: a full-width twin
			if len(w) <= 6 {
				add(fullWidth(w))
			}
		case 4: // ~2%: a word with a letter no fold strips
			add(w[:len(w)/2] + kept[r.intn(len(kept))] + w[len(w)/2:])
		}
	}
	// the fixed words go in at mid-frequency ranks (titles draw low indices most often)
	for i, w := range fixedWords {
		if !seen[w] {
			at := 150 + 61*i
			vocab = append(vocab[:at], append([]string{w}, vocab[at:]...)...)
			seen[w] = true
		}
	}
	return vocab
}

// titleCase upper-cases the first rune (Go's simple case mapping).
func titleCase(w string) string {
	c, n := utf8.DecodeRuneInString(w)
	return string(unicode.ToUpper(c)) + w[n:]
}

func buildCatalog() {
	r := &rng{s: catalogSeed}
	vocab := buildVocab(r)
	seps := []string{" ", " ", " ", " ", " - ", ", ", " / "}
	docs := make([]Doc, NumDocs)
	for i := range docs {
		n := 4 + r.intn(9)
		var b strings.Builder
		for j := 0; j < n; j++ {
			w := vocab[r.skewed(len(vocab))]
			switch k := r.intn(10); {
			case j == 0 || k == 0:
				w = titleCase(w)
			case k == 1:
				w = strings.ToUpper(w)
			}
			if j > 0 {
				b.WriteString(seps[r.intn(len(seps))])
			}
			b.WriteString(w)
		}
		if r.intn(8) == 0 { // model numbers: digits are word characters too
			b.WriteString(" ")
			b.WriteString(string(rune('A' + r.intn(26))))
			b.WriteString(itoa(100 + r.intn(9900)))
		}
		docs[i] = Doc{ID: i + 1, Title: b.String(), Cents: int64(199 + r.intn(49801))}
	}
	catDocs, catVocab = docs, vocab
}

func itoa(n int) string {
	if n == 0 {
		return "0"
	}
	var b [20]byte
	i := len(b)
	for ; n > 0; n /= 10 {
		i--
		b[i] = byte('0' + n%10)
	}
	return string(b[i:])
}
