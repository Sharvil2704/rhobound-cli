package hot

import (
	"math"
	"sort"
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
// This is the straightforward version: every call folds and tokenizes every title, scores every document and sorts
// the whole list.
func Rank(q string) []Hit {
	terms := queryTerms(q)
	if len(terms) == 0 {
		return nil
	}
	docs := Catalog()
	n, nt := len(docs), len(terms)
	tf := make([]int, n*nt)
	dl := make([]int, n)
	df := make([]int, nt)
	total := 0
	for i, d := range docs {
		toks := tokenize(Fold(d.Title))
		dl[i] = len(toks)
		total += len(toks)
		for j, t := range terms {
			c := 0
			for _, w := range toks {
				if w == t {
					c++
				}
			}
			tf[i*nt+j] = c
			if c > 0 {
				df[j]++
			}
		}
	}
	avgdl := float64(total) / float64(n)
	idf := make([]float64, nt)
	for j := range terms {
		idf[j] = math.Log(1 + (float64(n-df[j])+0.5)/(float64(df[j])+0.5))
	}
	hits := make([]Hit, n)
	for i, d := range docs {
		s := 0.0
		for j := range terms {
			if c := tf[i*nt+j]; c > 0 {
				f := float64(c)
				s += idf[j] * f * (k1 + 1) / (f + k1*(1-b+b*float64(dl[i])/avgdl))
			}
		}
		hits[i] = Hit{ID: d.ID, Score: s}
	}
	sort.Slice(hits, func(x, y int) bool {
		if hits[x].Score != hits[y].Score {
			return hits[x].Score > hits[y].Score
		}
		return hits[x].ID < hits[y].ID
	})
	out := make([]Hit, 0, TopK)
	for _, h := range hits[:min(TopK, n)] {
		if h.Score > 0 {
			out = append(out, h)
		}
	}
	return out
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
