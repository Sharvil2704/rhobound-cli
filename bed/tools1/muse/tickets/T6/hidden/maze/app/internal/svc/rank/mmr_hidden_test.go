//go:build hidden

package rank

import (
	"fmt"
	"io"
	"math"
	"net"
	"net/http"
	"os"
	"regexp"
	"sort"
	"strconv"
	"strings"
	"sync"
	"testing"
	"time"

	"maze/internal/rt"
)

// the ticket's definitions, written independently of the change under test
func refWeights() []float64 {
	w := make([]float64, 32)
	for i := range w {
		w[i] = float64((i*37)%11) / 10
	}
	return w
}

func refFeatures(seed uint64, c int) []float64 {
	f := make([]float64, 32)
	for d := range f {
		f[d] = float64((seed+uint64(c*32+d)*40503)%997) / 997
	}
	return f
}

func refScores(seed uint64) []float64 {
	w := refWeights()
	s := make([]float64, 64)
	for c := range s {
		for d, x := range refFeatures(seed, c) {
			s[c] += w[d] * x
		}
	}
	return s
}

func cosine(a, b []float64) float64 {
	var ab, aa, bb float64
	for i := range a {
		ab += a[i] * b[i]
		aa += a[i] * a[i]
		bb += b[i] * b[i]
	}
	if aa == 0 || bb == 0 {
		return 0
	}
	return ab / math.Sqrt(aa*bb)
}

// mmrValues: lambda*r(c) - (1-lambda)*s(c) for every candidate, given the chosen ones
func mmrValues(seed uint64, lambda float64, chosen []int) []float64 {
	sc := refScores(seed)
	mx := 0.0
	for _, x := range sc {
		mx = math.Max(mx, x)
	}
	v := make([]float64, 64)
	for c := range v {
		s := 0.0
		for i, p := range chosen {
			if x := cosine(refFeatures(seed, c), refFeatures(seed, p)); i == 0 || x > s {
				s = x
			}
		}
		v[c] = lambda*sc[c]/mx - (1-lambda)*s
	}
	return v
}

const eps = 1e-9

// checkMMR: got is a greedy MMR sequence of length clamp(k): distinct, in range, the first the most relevant, each next
// within eps of the best value given the earlier picks
func checkMMR(t *testing.T, seed uint64, k int, lambda float64, got []int) {
	t.Helper()
	want := min(max(k, 0), 64)
	if len(got) != want {
		t.Fatalf("Diversify(%d, %d, %v): %d candidates, want %d", seed, k, lambda, len(got), want)
	}
	seen := map[int]bool{}
	for i, p := range got {
		if p < 0 || p >= 64 || seen[p] {
			t.Fatalf("Diversify(%d, %d, %v): pick %d is %d (out of range or repeated): %v", seed, k, lambda, i, p, got)
		}
		seen[p] = true
		var v []float64
		if i == 0 {
			v = refScores(seed) // the first pick: the most relevant
		} else {
			v = mmrValues(seed, lambda, got[:i])
		}
		best := math.Inf(-1)
		for c, x := range v {
			if !seen[c] || c == p {
				best = math.Max(best, x)
			}
		}
		if v[p] < best-eps*math.Max(1, math.Abs(best)) {
			t.Fatalf("Diversify(%d, %d, %v): pick %d is candidate %d with value %.12f, but %.12f was possible: %v", seed, k, lambda, i, p, v[p], best, got)
		}
	}
}

func TestHiddenFeatures(t *testing.T) {
	for _, seed := range []uint64{1, 7, 123456789, 1 << 40} {
		for _, c := range []int{0, 13, 63} {
			got, want := Features(seed, c), refFeatures(seed, c)
			if len(got) != 32 {
				t.Fatalf("Features(%d, %d): %d features, want 32", seed, c, len(got))
			}
			for d := range want {
				if math.Abs(got[d]-want[d]) > 1e-12 {
					t.Fatalf("Features(%d, %d)[%d] = %v, want %v", seed, c, d, got[d], want[d])
				}
			}
		}
	}
}

func TestHiddenDiversifyIsMMR(t *testing.T) {
	for seed := uint64(1); seed <= 120; seed++ {
		for _, k := range []int{1, 5, 10} {
			for _, lambda := range []float64{0.7, 0.5, 0.3, 0} {
				checkMMR(t, seed, k, lambda, Diversify(seed, k, lambda))
			}
		}
	}
	for _, k := range []int{0, -3, 64, 70} {
		checkMMR(t, 99, k, 0.7, Diversify(99, k, 0.7))
	}
}

func TestHiddenLambdaOneIsScoreOrder(t *testing.T) {
	for seed := uint64(1); seed <= 60; seed++ {
		sc := refScores(seed)
		idx := make([]int, 64)
		for i := range idx {
			idx[i] = i
		}
		sort.SliceStable(idx, func(a, b int) bool { return sc[idx[a]] > sc[idx[b]] })
		got := Diversify(seed, 10, 1)
		for i := range got {
			if got[i] != idx[i] && math.Abs(sc[got[i]]-sc[idx[i]]) > 1e-12 {
				t.Fatalf("Diversify(%d, 10, 1) = %v, want the 10 highest-scoring in order %v", seed, got, idx[:10])
			}
		}
	}
}

// Rerank as it was before the ticket
func refRerank(seed uint64) []int {
	sc := refScores(seed)
	idx := make([]int, 64)
	for i := range idx {
		idx[i] = i
	}
	sort.Slice(idx, func(a, b int) bool { return sc[idx[a]] > sc[idx[b]] })
	return idx
}

func TestHiddenRerankUnchanged(t *testing.T) {
	for _, seed := range []uint64{1, 2, 3, 1000, 77777} {
		got, want := Rerank(seed), refRerank(seed)
		if len(got) != 64 {
			t.Fatalf("Rerank(%d): %d candidates, want 64", seed, len(got))
		}
		sc := refScores(seed)
		for i := range want {
			if math.Abs(sc[got[i]]-sc[want[i]]) > 1e-12 {
				t.Fatalf("Rerank(%d) changed: %v, want %v", seed, got[:10], want[:10])
			}
		}
	}
}

func TestHiddenDiversifyConcurrent(t *testing.T) {
	want := map[uint64][]int{}
	for s := uint64(1); s <= 40; s++ {
		want[s] = Diversify(s, 10, 0.7)
	}
	var wg sync.WaitGroup
	errs := make(chan string, 16)
	for g := range 16 {
		wg.Add(1)
		go func() {
			defer wg.Done()
			for i := range 60 {
				s := uint64((g*7+i)%40 + 1)
				if got := Diversify(s, 10, 0.7); fmt.Sprint(got) != fmt.Sprint(want[s]) {
					errs <- fmt.Sprintf("seed %d: %v under concurrent calls, %v alone", s, got, want[s])
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

// TestHiddenHookServesDiversified runs the rank service (rt.Main) with only its /rerank code hook and reads three
// answers: each is the diversified top 10 of some request seed, written [i i ...].
func TestHiddenHookServesDiversified(t *testing.T) {
	ln, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatalf("no loopback listener (this check serves the hook on 127.0.0.1): %v", err)
	}
	addr := ln.Addr().String()
	ln.Close()
	os.Setenv("MAZE_CONFIG", `{"service":"rank","workers":1,"routes":{"/rerank":{"work":{"mean_ms":0,"cs2":0},"code":"rank.rerank"}}}`)
	os.Setenv("MAZE_LISTEN", addr)
	os.Setenv("OTEL_EXPORTER_OTLP_TRACES_ENDPOINT", "http://127.0.0.1:9/v1/traces")
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
	form := regexp.MustCompile(`^\[(\d+( \d+)*)?\]$`)
	for range 3 {
		body, err := get("/rerank")
		if err != nil {
			t.Fatal(err)
		}
		body = strings.TrimSpace(body)
		if !form.MatchString(body) {
			t.Fatalf("/rerank answered %q, want [i i ...]", body)
		}
		var got []int
		for _, f := range strings.Fields(strings.Trim(body, "[]")) {
			x, _ := strconv.Atoi(f)
			got = append(got, x)
		}
		if len(got) != 10 {
			t.Fatalf("/rerank answered %d candidates, want 10: %q", len(got), body)
		}
		found := false
		for s := uint64(1); s <= 3000 && !found; s++ {
			found = fmt.Sprint(Diversify(s, 10, 0.7)) == fmt.Sprint(got)
		}
		if !found {
			t.Fatalf("/rerank answered %v, which is not Diversify(seed, 10, 0.7) for any of the first 3000 seeds", got)
		}
	}
}
