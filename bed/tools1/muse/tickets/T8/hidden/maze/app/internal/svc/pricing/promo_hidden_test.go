//go:build hidden

package pricing

import (
	"encoding/json"
	"fmt"
	"io"
	"math/rand/v2"
	"net"
	"net/http"
	"os"
	"slices"
	"strings"
	"sync"
	"testing"
	"time"

	"maze/internal/rt"
)

type hidRefPromo struct {
	code, group, kind       string
	minQty, minTotal, value int
}

var hidRefPromos = []hidRefPromo{
	{"SPRING10", "season", "pct_line", 1, 0, 100}, {"SUMMER15", "season", "pct_line", 5, 0, 150},
	{"FLASH20", "season", "pct_line", 12, 0, 200}, {"BULK5", "volume", "pct_line", 10, 0, 50},
	{"FREE1", "volume", "free_unit", 6, 0, 1}, {"FREE2", "volume", "free_unit", 12, 0, 2},
	{"OFF500", "cart", "fixed_cart", 0, 10000, 500}, {"OFF2000", "cart", "fixed_cart", 0, 40000, 2000},
	{"OFF5000", "cart", "fixed_cart", 0, 90000, 5000}, {"LOYAL3", "loyalty", "pct_line", 1, 0, 30},
	{"WELCOME", "loyalty", "fixed_cart", 0, 0, 300}, {"STACK7", "stack", "pct_line", 3, 0, 70},
}

// the volume discount table as bed main computes it (pricing.discounts), built once here
var hidRefDisc = func() []int {
	d := make([]int, 101)
	for q := range d {
		best := 0
		for band := range 4000 {
			for tier, from := range []int{10, 25, 50} {
				if q >= from && band%(tier+3) == 0 {
					best = max(best, []int{50, 80, 120}[tier]-band%7)
				}
			}
		}
		d[q] = best
	}
	return d
}()

func hidRefLine(l Line) int { return (l.Cents*l.Qty*(1000-hidRefDisc[min(l.Qty, 100)]) + 500) / 1000 }

func hidRefQuote(lines []Line) int {
	t := 0
	for _, l := range lines {
		t += hidRefLine(l)
	}
	return t
}

func hidRefApply(lines []Line, combo []hidRefPromo) int {
	lt := make([]int, len(lines))
	for i, l := range lines {
		lt[i] = hidRefLine(l)
	}
	for _, p := range combo {
		if p.kind == "pct_line" {
			for i, l := range lines {
				if l.Qty >= p.minQty {
					lt[i] -= (lt[i]*p.value + 500) / 1000
				}
			}
		}
	}
	for _, p := range combo {
		if p.kind == "free_unit" {
			for i, l := range lines {
				if l.Qty >= p.minQty {
					lt[i] = max(0, lt[i]-p.value*l.Cents)
				}
			}
		}
	}
	sub := 0
	for _, x := range lt {
		sub += x
	}
	for _, p := range combo {
		if p.kind == "fixed_cart" && sub >= p.minTotal {
			sub = max(0, sub-p.value)
		}
	}
	return sub
}

// hidRefQuotePromo: every combination with at most one promotion per group (table order kept), the lowest total; ties
// to fewer promotions, then the lexicographically smallest sorted codes
func hidRefQuotePromo(lines []Line) (int, []string) {
	groups := []string{}
	for _, p := range hidRefPromos {
		if !slices.Contains(groups, p.group) {
			groups = append(groups, p.group)
		}
	}
	bestT, bestC := -1, []string(nil)
	var rec func(gi int, pick map[string]int)
	rec = func(gi int, pick map[string]int) {
		if gi == len(groups) {
			var combo []hidRefPromo
			var codes []string
			for i, p := range hidRefPromos {
				if pick[p.group] == i+1 {
					combo = append(combo, p)
					codes = append(codes, p.code)
				}
			}
			slices.Sort(codes)
			t := hidRefApply(lines, combo)
			if bestC == nil || t < bestT || (t == bestT && (len(codes) < len(bestC) ||
				(len(codes) == len(bestC) && slices.Compare(codes, bestC) < 0))) {
				bestT, bestC = t, append([]string{}, codes...)
			}
			return
		}
		pick[groups[gi]] = 0
		rec(gi+1, pick)
		for i, p := range hidRefPromos {
			if p.group == groups[gi] {
				pick[groups[gi]] = i + 1
				rec(gi+1, pick)
			}
		}
		pick[groups[gi]] = 0
	}
	rec(0, map[string]int{})
	return bestT, bestC
}

func hidRefCart(seed uint64) []Line {
	ls := make([]Line, 1+seed%6)
	for i := range ls {
		ls[i] = Line{Cents: 199 + int((seed*7919+uint64(i)*104729)%40000), Qty: 1 + int((seed+uint64(i))%14)}
	}
	return ls
}

func hidRandCart(r *rand.Rand) []Line {
	ls := make([]Line, 1+r.IntN(8))
	for i := range ls {
		ls[i] = Line{Cents: 199 + r.IntN(40000), Qty: 1 + r.IntN(30)}
	}
	return ls
}

func TestHiddenPromotionsTable(t *testing.T) {
	if len(Promotions) != len(hidRefPromos) {
		t.Fatalf("%d promotions, want %d", len(Promotions), len(hidRefPromos))
	}
	for i, p := range Promotions {
		w := hidRefPromos[i]
		if p.Code != w.code || p.Group != w.group || p.Kind != w.kind || p.MinQty != w.minQty || p.MinTotal != w.minTotal || p.Value != w.value {
			t.Fatalf("Promotions[%d] = %+v, want %+v", i, p, w)
		}
	}
}

func hidCheckPromo(t *testing.T, what string, lines []Line) {
	t.Helper()
	wantT, wantC := hidRefQuotePromo(lines)
	gotT, gotC := QuotePromo(lines)
	if gotC == nil {
		gotC = []string{}
	}
	if gotT != wantT || !slices.Equal(gotC, wantC) {
		t.Fatalf("QuotePromo(%s %v) = %d %v, want %d %v", what, lines, gotT, gotC, wantT, wantC)
	}
}

func TestHiddenQuotePromo(t *testing.T) {
	for s := uint64(1); s <= 150; s++ {
		hidCheckPromo(t, fmt.Sprintf("cart(%d)", s), hidRefCart(s))
	}
	r := rand.New(rand.NewPCG(7, 8))
	for i := range 250 {
		hidCheckPromo(t, fmt.Sprintf("random cart %d", i), hidRandCart(r))
	}
	hidCheckPromo(t, "a single line of 100", []Line{{Cents: 30000, Qty: 100}})
	hidCheckPromo(t, "the empty cart", nil)
}

func TestHiddenQuoteUnchanged(t *testing.T) {
	r := rand.New(rand.NewPCG(1, 2))
	for i := range 40 {
		c := hidRandCart(r)
		if got, want := Quote(c), hidRefQuote(c); got != want {
			t.Fatalf("Quote(random cart %d) = %d, want %d (Quote must keep its meaning)", i, got, want)
		}
	}
}

func TestHiddenQuotePromoConcurrent(t *testing.T) {
	carts := make([][]Line, 30)
	type res struct {
		t int
		c []string
	}
	want := make([]res, 30)
	for i := range carts {
		carts[i] = hidRefCart(uint64(i + 1))
		tt, cc := QuotePromo(carts[i])
		want[i] = res{tt, cc}
	}
	var wg sync.WaitGroup
	errs := make(chan string, 8)
	for g := range 8 {
		wg.Add(1)
		go func() {
			defer wg.Done()
			for i := range 30 {
				j := (g*5 + i) % 30
				if tt, cc := QuotePromo(carts[j]); tt != want[j].t || !slices.Equal(cc, want[j].c) {
					errs <- fmt.Sprintf("cart %d: %d %v under concurrent calls, %d %v alone", j, tt, cc, want[j].t, want[j].c)
					return
				}
			}
		}()
	}
	wg.Wait()
	close(errs)
	for e := range errs {
		t.Fatal(e)
	}
}

// TestHiddenHookAnswersPromotions runs the pricing service (rt.Main) with only its /quote code hook and reads three
// answers: each is QuotePromo of the hook's cart for consecutive request seeds.
func TestHiddenHookAnswersPromotions(t *testing.T) {
	ln, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatalf("no loopback listener (this check serves the hook on 127.0.0.1): %v", err)
	}
	addr := ln.Addr().String()
	ln.Close()
	os.Setenv("MAZE_CONFIG", `{"service":"pricing","workers":2,"routes":{"/quote":{"work":{"mean_ms":0,"cs2":0},"code":"pricing.quote"}}}`)
	os.Setenv("MAZE_LISTEN", addr)
	os.Setenv("OTEL_EXPORTER_OTLP_TRACES_ENDPOINT", "http://127.0.0.1:9/v1/traces")
	go rt.Main()
	cl := &http.Client{Timeout: 30 * time.Second}
	get := func(path string) ([]byte, error) {
		resp, err := cl.Get("http://" + addr + path)
		if err != nil {
			return nil, err
		}
		defer resp.Body.Close()
		b, err := io.ReadAll(resp.Body)
		if resp.StatusCode != http.StatusOK {
			return nil, fmt.Errorf("%s: %s %s", path, resp.Status, b)
		}
		return b, err
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
	type ans struct {
		Total  *int      `json:"total"`
		Promos *[]string `json:"promos"`
	}
	var got []ans
	for range 3 {
		b, err := get("/quote")
		if err != nil {
			t.Fatal(err)
		}
		var a ans
		if err := json.Unmarshal(b, &a); err != nil || a.Total == nil || a.Promos == nil {
			t.Fatalf("/quote answered %q, want {\"total\":T,\"promos\":[...]}", b)
		}
		got = append(got, a)
	}
	// the package's own tests may have called the hook first (they run in this process): search a wide range of seeds
	type res struct {
		t int
		c []string
	}
	memo := map[uint64]res{}
	ref := func(s uint64) res {
		r, ok := memo[s]
		if !ok {
			t, c := hidRefQuotePromo(hidRefCart(s))
			r = res{t, c}
			memo[s] = r
		}
		return r
	}
	for s0 := uint64(1); s0 <= 20000; s0++ {
		ok := true
		for i, a := range got {
			r := ref(s0 + uint64(i))
			ok = ok && *a.Total == r.t && slices.Equal(*a.Promos, r.c)
			if !ok {
				break
			}
		}
		if ok {
			return
		}
	}
	var desc []string
	for _, a := range got {
		desc = append(desc, fmt.Sprintf("%d %v", *a.Total, *a.Promos))
	}
	t.Fatalf("/quote answered %s, which is not QuotePromo of the hook's cart for three consecutive seeds", strings.Join(desc, "; "))
}
