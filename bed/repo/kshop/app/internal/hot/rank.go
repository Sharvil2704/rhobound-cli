package hot

import (
	"math"
	"sort"
	"sync"
	"unicode"
	"unicode/utf8"
)

// Hit is one search result: a document ID and its score.
type Hit struct {
	ID    int
	Score float64
}

const (
	// TopK is the most hits Rank returns.
	TopK = 10
	k1   = 1.2
	b    = 0.75
)

// Rank returns the TopK documents that best match q, by a BM25 score, highest first; equal scores in ascending ID
// order; documents with score 0 (no query term) are never returned, so there may be fewer than TopK hits (none for a
// query without terms).
//
// Terms: Fold, then split into maximal runs of letters and digits (unicode.IsLetter / unicode.IsDigit); a query's
// terms are its distinct tokens in order of first appearance. For a document d of dl tokens (avgdl: the mean over
// the catalog), N documents, df(t) of them holding term t, tf = t's count in d:
//
//	score(d) = sum over terms t with tf > 0 of  idf(t) * tf * (k1 + 1) / (tf + k1 * (1 - b + b * dl / avgdl))
//	idf(t)   = ln(1 + (N - df(t) + 0.5) / (df(t) + 0.5)),   k1 = 1.2, b = 0.75
//
// The sum runs over the terms in query order.
//
// This version builds an inverted index once and scores only documents holding a query term.
func Rank(q string) []Hit {
	terms := queryTerms(q)
	if len(terms) == 0 {
		return nil
	}
	rankOnce.Do(buildRankIndex)
	buf := getRankBuf(rankN)
	touched := buf.touched[:0]
	scores := buf.scores
	seen := buf.seen
	gen := buf.gen
	knorm := rankKNorm
	docIDs := rankDocIDs
	dict := rankDict
	for _, t := range terms {
		ti := dict[t]
		if ti == nil {
			continue
		}
		idf := ti.idf
		for _, p := range ti.postings {
			idx := int(p.doc)
			if seen[idx] != gen {
				seen[idx] = gen
				scores[idx] = 0
				touched = append(touched, idx)
			}
			f := float64(p.tf)
			scores[idx] += idf * f * (k1 + 1) / (f + knorm[idx])
		}
	}
	var out []Hit
	if m := len(touched); m == 0 {
		out = make([]Hit, 0, TopK)
	} else if m <= TopK {
		out = make([]Hit, m)
		for i, idx := range touched {
			out[i] = Hit{ID: docIDs[idx], Score: scores[idx]}
		}
		sort.Slice(out, func(x, y int) bool {
			if out[x].Score != out[y].Score {
				return out[x].Score > out[y].Score
			}
			return out[x].ID < out[y].ID
		})
	} else {
		heap := make([]Hit, TopK)
		for i := 0; i < TopK; i++ {
			idx := touched[i]
			heap[i] = Hit{ID: docIDs[idx], Score: scores[idx]}
		}
		for i := TopK/2 - 1; i >= 0; i-- {
			rankSiftDown(heap, i, TopK)
		}
		for _, idx := range touched[TopK:] {
			cand := Hit{ID: docIDs[idx], Score: scores[idx]}
			if rankBetter(cand, heap[0]) {
				heap[0] = cand
				rankSiftDown(heap, 0, TopK)
			}
		}
		sort.Slice(heap, func(x, y int) bool {
			if heap[x].Score != heap[y].Score {
				return heap[x].Score > heap[y].Score
			}
			return heap[x].ID < heap[y].ID
		})
		out = heap
	}
	buf.touched = touched[:0]
	rankPool.Put(buf)
	return out
}

// rankBetter reports whether a outranks c in the documented order:
// higher score first, equal scores in ascending ID order.
func rankBetter(a, c Hit) bool {
	if a.Score != c.Score {
		return a.Score > c.Score
	}
	return a.ID < c.ID
}

// rankWorse reports whether a ranks below c in the documented order.
func rankWorse(a, c Hit) bool {
	if a.Score != c.Score {
		return a.Score < c.Score
	}
	return a.ID > c.ID
}

func rankSiftDown(heap []Hit, i, size int) {
	for {
		left := 2*i + 1
		right := left + 1
		worst := i
		if left < size && rankWorse(heap[left], heap[worst]) {
			worst = left
		}
		if right < size && rankWorse(heap[right], heap[worst]) {
			worst = right
		}
		if worst == i {
			return
		}
		heap[i], heap[worst] = heap[worst], heap[i]
		i = worst
	}
}

type rankPosting struct {
	doc uint32
	tf  uint32
}

type rankTerm struct {
	idf      float64
	postings []rankPosting
}

type rankBuf struct {
	scores  []float64
	seen    []uint32
	gen     uint32
	touched []int
}

var (
	rankOnce   sync.Once
	rankN      int
	rankKNorm  []float64
	rankDocIDs []int
	rankDict   map[string]*rankTerm
	rankPool   sync.Pool
)

func getRankBuf(n int) *rankBuf {
	if v := rankPool.Get(); v != nil {
		buf := v.(*rankBuf)
		if len(buf.scores) == n {
			buf.gen++
			if buf.gen == 0 {
				for i := range buf.seen {
					buf.seen[i] = 0
				}
				buf.gen = 1
			}
			buf.touched = buf.touched[:0]
			return buf
		}
	}
	return &rankBuf{
		scores:  make([]float64, n),
		seen:    make([]uint32, n),
		gen:     1,
		touched: make([]int, 0, 256),
	}
}

func buildRankIndex() {
	docs := Catalog()
	n := len(docs)
	dl := make([]int, n)
	docIDs := make([]int, n)
	for i, d := range docs {
		docIDs[i] = d.ID
	}
	tmp := make(map[string][]rankPosting)
	total := 0
	for i, d := range docs {
		toks := tokenize(Fold(d.Title))
		dl[i] = len(toks)
		total += len(toks)
		if len(toks) == 0 {
			continue
		}
		uniq := make([]string, 0, 8)
		counts := make([]int, 0, 8)
		for _, w := range toks {
			found := -1
			for k, u := range uniq {
				if u == w {
					found = k
					break
				}
			}
			if found >= 0 {
				counts[found]++
			} else {
				uniq = append(uniq, w)
				counts = append(counts, 1)
			}
		}
		for k, term := range uniq {
			tmp[term] = append(tmp[term], rankPosting{doc: uint32(i), tf: uint32(counts[k])})
		}
	}
	avgdl := float64(total) / float64(n)
	knorm := make([]float64, n)
	for i := range dl {
		knorm[i] = k1 * (1 - b + b*float64(dl[i])/avgdl)
	}
	dict := make(map[string]*rankTerm, len(tmp))
	for term, postings := range tmp {
		df := len(postings)
		idf := math.Log(1 + (float64(n-df)+0.5)/(float64(df)+0.5))
		dict[term] = &rankTerm{idf: idf, postings: postings}
	}
	rankN = n
	rankKNorm = knorm
	rankDocIDs = docIDs
	rankDict = dict
}

func isWordRune(r rune) bool { return unicode.IsLetter(r) || unicode.IsDigit(r) }

// tokenize splits folded text into its maximal runs of letters and digits.
func tokenize(s string) []string {
	toks := make([]string, 0, 16)
	start := -1
	for i, r := range s {
		w := false
		if r < utf8.RuneSelf {
			w = 'a' <= r && r <= 'z' || 'A' <= r && r <= 'Z' || '0' <= r && r <= '9'
		} else {
			w = isWordRune(r)
		}
		switch {
		case w && start < 0:
			start = i
		case !w && start >= 0:
			toks = append(toks, s[start:i])
			start = -1
		}
	}
	if start >= 0 {
		toks = append(toks, s[start:])
	}
	return toks
}

// queryTerms is Fold + tokenize, duplicates dropped (first appearance kept).
func queryTerms(q string) []string {
	var terms []string
	for _, t := range tokenize(Fold(q)) {
		dup := false
		for _, u := range terms {
			if u == t {
				dup = true
				break
			}
		}
		if !dup {
			terms = append(terms, t)
		}
	}
	return terms
}
