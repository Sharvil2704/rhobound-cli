//go:build hidden

package catalog

import (
	"fmt"
	"io"
	"net"
	"net/http"
	"os"
	"regexp"
	"slices"
	"strconv"
	"strings"
	"sync"
	"testing"
	"time"

	"maze/internal/rt"
	"maze/internal/svc/pricing"
)

// wantBulk is the ticket's definition: pricing.Quote for 50 units of the product, divided by 50, rounded half up.
func wantBulk(id int) int {
	total := pricing.Quote([]pricing.Line{{Cents: products[id].Price, Qty: 50}})
	return (total + 25) / 50
}

var hiddenQueries = [][]string{{"oak", "lamp"}, {"steel"}, {"wool", "rug"}, {"chair", "table"}, {"nosuchword"}, {"mug", "vase"}}

func checkHits(t *testing.T, q []string, k int) {
	t.Helper()
	ids := Search(q, k)
	hits := SearchHits(q, k)
	if len(hits) != len(ids) {
		t.Fatalf("SearchHits(%q, %d): %d hits, Search finds %d", q, k, len(hits), len(ids))
	}
	for i, h := range hits {
		if h.ID != ids[i] {
			t.Fatalf("SearchHits(%q, %d)[%d] is product %d, Search's is %d", q, k, i, h.ID, ids[i])
		}
		if w := wantBulk(h.ID); h.BulkCents != w {
			t.Fatalf("SearchHits(%q, %d): product %d (price %d) has bulk price %d, pricing charges %d", q, k, h.ID,
				products[h.ID].Price, h.BulkCents, w)
		}
	}
}

func TestHiddenBulkHits(t *testing.T) {
	for _, q := range hiddenQueries {
		for _, k := range []int{1, 7, 20} {
			checkHits(t, q, k)
			checkHits(t, q, k) // asked again: the same answer
		}
	}
}

// TestHiddenPricingUnchanged pins the volume discount at 50 units (12%), so the bulk price is the one checkout charges
// today, not one a changed pricing package charges.
func TestHiddenPricingUnchanged(t *testing.T) {
	for _, c := range []int{199, 1000, 12345, 40198} {
		if got, want := pricing.Quote([]pricing.Line{{Cents: c, Qty: 50}}), (c*50*880+500)/1000; got != want {
			t.Fatalf("pricing.Quote of 50 x %d cents = %d, want %d (pricing must stay as it is)", c, got, want)
		}
	}
	if got := wantBulk(0); got != 175 {
		t.Fatalf("product 0 (199 cents): bulk price %d, want 175", got)
	}
}

func TestHiddenBulkConcurrent(t *testing.T) {
	var wg sync.WaitGroup
	errs := make(chan string, 64)
	for g := range 8 {
		wg.Add(1)
		go func() {
			defer wg.Done()
			q := hiddenQueries[g%len(hiddenQueries)]
			for range 3 {
				ids := Search(q, 20)
				for i, h := range SearchHits(q, 20) {
					if i >= len(ids) || h.ID != ids[i] || h.BulkCents != wantBulk(h.ID) {
						errs <- fmt.Sprintf("goroutine %d: %q: hit %d = %+v", g, q, i, h)
						return
					}
				}
			}
		}()
	}
	wg.Wait()
	close(errs)
	for e := range errs {
		t.Error(e)
	}
}

// TestHiddenSearchHookServesBulk runs the catalog service (rt.Main) with a /search route that has only its code hook
// (no shard calls, no merge) and reads what the hook answers: the hits of one query, as [id:cents ...].
func TestHiddenSearchHookServesBulk(t *testing.T) {
	ln, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatalf("no loopback listener (this check serves the hook on 127.0.0.1): %v", err)
	}
	addr := ln.Addr().String()
	ln.Close()
	os.Setenv("MAZE_CONFIG", `{"service":"catalog","workers":2,"routes":{"/search":{"work":{"mean_ms":0,"cs2":0},"code":"catalog.search"}}}`)
	os.Setenv("MAZE_LISTEN", addr)
	os.Setenv("OTEL_EXPORTER_OTLP_TRACES_ENDPOINT", "http://127.0.0.1:9/v1/traces") // nothing listens: spans are dropped
	go rt.Main()
	cl := &http.Client{Timeout: 20 * time.Second}
	get := func(path string) (string, error) {
		resp, err := cl.Get("http://" + addr + path)
		if err != nil {
			return "", err
		}
		defer resp.Body.Close()
		b, err := io.ReadAll(resp.Body)
		if resp.StatusCode != http.StatusOK {
			return "", fmt.Errorf("%s: %s %s", path, resp.Status, b)
		}
		return string(b), err
	}
	deadline := time.Now().Add(15 * time.Second)
	for {
		if _, err := get("/healthz"); err == nil {
			break
		} else if time.Now().After(deadline) {
			t.Fatalf("the service did not come up: %v", err)
		}
		time.Sleep(50 * time.Millisecond)
	}
	// every query the hook can ask (query(): two words of the vocabulary, a cycle of len(words))
	var cycle [][]int
	for n := range len(words) {
		cycle = append(cycle, Search([]string{words[n%len(words)], words[(n*7+3)%len(words)]}, 20))
	}
	form := regexp.MustCompile(`^\[(\d+:\d+( \d+:\d+)*)?\]$`)
	for range 3 {
		body, err := get("/search")
		if err != nil {
			t.Fatal(err)
		}
		if !form.MatchString(body) {
			t.Fatalf("/search hook answered %.200q, want [id:cents id:cents ...]", body)
		}
		var ids []int
		for _, f := range strings.Fields(strings.Trim(body, "[]")) {
			id, _ := strconv.Atoi(strings.SplitN(f, ":", 2)[0])
			c, _ := strconv.Atoi(strings.SplitN(f, ":", 2)[1])
			if id < 0 || id >= len(products) {
				t.Fatalf("/search: product %d out of range", id)
			}
			if w := wantBulk(id); c != w {
				t.Fatalf("/search: product %d at %d cents, pricing charges %d", id, c, w)
			}
			ids = append(ids, id)
		}
		if len(ids) != 20 || !slices.ContainsFunc(cycle, func(s []int) bool { return slices.Equal(s, ids) }) {
			t.Fatalf("/search answered %d hits %v: not the top 20 of a query the hook asks", len(ids), ids)
		}
	}
}
