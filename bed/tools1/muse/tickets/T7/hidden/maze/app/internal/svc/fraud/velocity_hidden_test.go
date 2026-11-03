//go:build hidden

package fraud

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

type hidCharge struct {
	card, amount int
	at           time.Time
}

// hidRefCheck: the ticket's rules over every earlier hidCharge (no eviction), for the newest hidCharge in hist
func hidRefCheck(hist []hidCharge) (int, []string) {
	c := hist[len(hist)-1]
	n60, nPrev, sum := 0, 0, 0
	for i, h := range hist {
		if h.card != c.card {
			continue
		}
		if h.at.After(c.at.Add(-60*time.Second)) && !h.at.After(c.at) {
			n60++
		}
		if i < len(hist)-1 && h.at.After(c.at.Add(-10*time.Minute)) && h.at.Before(c.at) {
			nPrev++
			sum += h.amount
		}
	}
	extra, reasons := 0, []string{}
	if n60 >= 4 {
		extra += 30
		reasons = append(reasons, "velocity")
	}
	if nPrev >= 3 && float64(c.amount) > 3*float64(sum)/float64(nPrev) {
		extra += 25
		reasons = append(reasons, "amount")
	}
	return extra, reasons
}

func hidNorm(r []string) []string {
	if r == nil {
		return []string{}
	}
	return r
}

func TestHiddenCardAmount(t *testing.T) {
	for _, s := range []uint64{0, 1, 996, 997, 123456789, 1 << 50} {
		if got, want := Card(s), int(s%997); got != want {
			t.Fatalf("Card(%d) = %d, want %d", s, got, want)
		}
		if got, want := Amount(s), 500+int(s*7919%20000); got != want {
			t.Fatalf("Amount(%d) = %d, want %d", s, got, want)
		}
	}
}

func TestHiddenVelocityRules(t *testing.T) {
	t0 := time.Date(2026, 11, 3, 6, 0, 0, 0, time.UTC)
	for _, seed := range []uint64{1, 2, 3} {
		r := rand.New(rand.NewPCG(seed, 99))
		v := NewVelocity()
		var hist []hidCharge
		at := t0
		for i := range 3000 {
			at = at.Add(time.Duration(1+r.IntN(1500)) * time.Millisecond)
			amt := 500 + r.IntN(4000)
			if r.IntN(25) == 0 {
				amt *= 6 // now and then a spike
			}
			c := hidCharge{card: r.IntN(20), amount: amt, at: at}
			hist = append(hist, c)
			wantX, wantR := hidRefCheck(hist)
			gotX, gotR := v.Check(c.card, c.amount, c.at)
			if gotX != wantX || !slices.Equal(hidNorm(gotR), wantR) {
				t.Fatalf("stream %d, hidCharge %d (card %d, %d cents, +%v): Check = %d %v, want %d %v", seed, i, c.card,
					c.amount, c.at.Sub(t0), gotX, gotR, wantX, wantR)
			}
		}
	}
}

func TestHiddenVelocityBounded(t *testing.T) {
	t0 := time.Date(2026, 11, 3, 6, 0, 0, 0, time.UTC)
	v := NewVelocity()
	for i := range 5000 {
		v.Check(1+i%50, 1000, t0.Add(time.Duration(i)*time.Millisecond))
	}
	if n := v.Len(); n != 5000 {
		t.Fatalf("Len() = %d after 5000 charges within 5 s, want 5000", n)
	}
	// charges at or before at-10min are dropped, whatever their card: here those at t0..t0+2.5s
	v.Check(999, 1000, t0.Add(10*time.Minute+2500*time.Millisecond))
	if n := v.Len(); n != 2500 {
		t.Fatalf("Len() = %d after a hidCharge at t0+10m2.5s, want 2500 (2499 recent + this one)", n)
	}
	v.Check(998, 1000, t0.Add(11*time.Minute))
	if n := v.Len(); n != 2 {
		t.Fatalf("Len() = %d after a hidCharge at t0+11m, want 2 (the one at t0+10m2.5s and this one)", n)
	}
}

func TestHiddenVelocityConcurrent(t *testing.T) {
	t0 := time.Date(2026, 11, 3, 6, 0, 0, 0, time.UTC)
	v := NewVelocity()
	var wg sync.WaitGroup
	errs := make(chan string, 8)
	for g := range 8 {
		wg.Add(1)
		go func() {
			defer wg.Done()
			var hist []hidCharge // this goroutine's cards only: 100g .. 100g+4
			for i := range 500 {
				c := hidCharge{card: 100*g + i%5, amount: 500 + (i*37)%3000, at: t0.Add(time.Duration(i) * 10 * time.Millisecond)}
				hist = append(hist, c)
				wantX, wantR := hidRefCheck(hist)
				if gotX, gotR := v.Check(c.card, c.amount, c.at); gotX != wantX || !slices.Equal(hidNorm(gotR), wantR) {
					errs <- fmt.Sprintf("goroutine %d, hidCharge %d: %d %v, want %d %v", g, i, gotX, gotR, wantX, wantR)
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
	if n := v.Len(); n != 4000 {
		t.Fatalf("Len() = %d after 8 x 500 charges within 5 s, want 4000", n)
	}
}

func hidRefScore(seed uint64) int {
	s := 0
	for rule := range 40 {
		if (seed>>uint(rule%16))&1 == 1 {
			s += rule % 7
		}
	}
	return s % 100
}

func TestHiddenScoreUnchanged(t *testing.T) {
	for _, s := range []uint64{0, 1, 2, 77, 65535, 1 << 33} {
		if got, want := Score(s), hidRefScore(s); got != want {
			t.Fatalf("Score(%d) = %d, want %d", s, got, want)
		}
	}
}

// TestHiddenHookAnswersRiskAndReasons runs the fraud service (rt.Main) with only its /score code hook and reads five
// answers: each is {"risk":R,"reasons":[...]} with known reasons in the ticket's order and R = min(99, Score(seed) + 30
// for velocity + 25 for amount), for five consecutive seeds. The process's Velocity may already hold charges (the
// package's own tests run first in this process), so which rules fire is not assumed.
func TestHiddenHookAnswersRiskAndReasons(t *testing.T) {
	ln, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatalf("no loopback listener (this check serves the hook on 127.0.0.1): %v", err)
	}
	addr := ln.Addr().String()
	ln.Close()
	os.Setenv("MAZE_CONFIG", `{"service":"fraud","workers":1,"routes":{"/score":{"work":{"mean_ms":0,"cs2":0},"code":"fraud.score"}}}`)
	os.Setenv("MAZE_LISTEN", addr)
	os.Setenv("OTEL_EXPORTER_OTLP_TRACES_ENDPOINT", "http://127.0.0.1:9/v1/traces")
	go rt.Main()
	cl := &http.Client{Timeout: 20 * time.Second}
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
	var risks []int
	var extras []int
	for range 5 {
		b, err := get("/score")
		if err != nil {
			t.Fatal(err)
		}
		var ans struct {
			Risk    *int      `json:"risk"`
			Reasons *[]string `json:"reasons"`
		}
		if err := json.Unmarshal(b, &ans); err != nil || ans.Risk == nil || ans.Reasons == nil {
			t.Fatalf("/score answered %q, want {\"risk\":R,\"reasons\":[...]}", b)
		}
		extra := 0
		switch strings.Join(*ans.Reasons, ",") {
		case "":
		case "velocity":
			extra = 30
		case "amount":
			extra = 25
		case "velocity,amount":
			extra = 55
		default:
			t.Fatalf("/score answered reasons %v: want a subset of [velocity amount], in that order", *ans.Reasons)
		}
		risks = append(risks, *ans.Risk)
		extras = append(extras, extra)
	}
	for s0 := uint64(1); s0 <= 100000; s0++ {
		ok := true
		for i, r := range risks {
			ok = ok && r == min(99, hidRefScore(s0+uint64(i))+extras[i])
		}
		if ok {
			return
		}
	}
	t.Fatalf("/score answered risks %v (extras %v), which are not min(99, Score + extra) of five consecutive seeds", risks, extras)
}
