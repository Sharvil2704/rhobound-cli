// Package catalog serves product lookups (/item) and full-text search over the catalogue (/search, merged with the
// index shards' answers).
package catalog

import (
	"fmt"
	"math"
	"sort"
	"strings"
	"sync/atomic"

	"maze/internal/rt"
)

var words = strings.Fields(`red blue green black white steel oak linen wool cotton lamp chair table desk sofa rug
	mug bowl plate knife spoon glass bottle jar shelf frame mirror clock vase pillow blanket towel basket crate stool
	bench cabinet drawer hook rail light bulb cord switch plug fan heater kettle pot pan lid tray board cloth brush`)

// Product is one catalogue entry.
type Product struct {
	ID    int
	Title string
	Price int // cents
}

var products = build(2000)

func build(n int) []Product {
	ps := make([]Product, n)
	for i := range ps {
		var t []string
		for j := range 6 + i%5 {
			t = append(t, words[(i*31+j*17+j*j)%len(words)])
		}
		ps[i] = Product{ID: i, Title: strings.Join(t, " "), Price: 199 + (i*7919)%40000}
	}
	return ps
}

var seq atomic.Uint64

func query() []string {
	n := seq.Add(1)
	return []string{words[n%uint64(len(words))], words[(n*7+3)%uint64(len(words))]}
}

// Search scores every product against the query terms (BM25) and returns the ids of the best k.
func Search(terms []string, k int) []int {
	df := map[string]int{}
	total := 0
	for _, p := range products {
		seen := map[string]bool{}
		toks := strings.Fields(p.Title)
		total += len(toks)
		for _, t := range toks {
			if !seen[t] {
				seen[t] = true
				df[t]++
			}
		}
	}
	avg := float64(total) / float64(len(products))
	type hit struct {
		id    int
		score float64
	}
	var hits []hit
	for _, p := range products {
		toks := strings.Fields(p.Title)
		s := 0.0
		for _, q := range terms {
			tf := 0
			for _, t := range toks {
				if t == q {
					tf++
				}
			}
			if tf == 0 {
				continue
			}
			idf := math.Log(1 + (float64(len(products))-float64(df[q])+0.5)/(float64(df[q])+0.5))
			s += idf * float64(tf) * 2.2 / (float64(tf) + 1.2*(0.25+0.75*float64(len(toks))/avg))
		}
		if s > 0 {
			hits = append(hits, hit{p.ID, s})
		}
	}
	sort.Slice(hits, func(i, j int) bool {
		if hits[i].score != hits[j].score {
			return hits[i].score > hits[j].score
		}
		return hits[i].id < hits[j].id
	})
	if len(hits) > k {
		hits = hits[:k]
	}
	ids := make([]int, len(hits))
	for i, h := range hits {
		ids[i] = h.id
	}
	return ids
}

func init() {
	rt.Register("catalog.item", func(r *rt.Req) error {
		p := products[int(seq.Add(1))%len(products)]
		r.Out = fmt.Appendf(nil, `{"id":%d,"title":%q,"price":%d}`, p.ID, p.Title, p.Price)
		return nil
	})
	rt.Register("catalog.search", func(r *rt.Req) error {
		r.Out = fmt.Appendf(nil, "%v", Search(query(), 20))
		return nil
	})
	rt.Register("catalog.merge", func(r *rt.Req) error {
		n := 0
		for _, b := range r.Bodies {
			n += len(b)
		}
		r.Out = fmt.Appendf(nil, `{"shards":%d,"bytes":%d}`, len(r.Bodies), n)
		return nil
	})
}
