// maze-load sends open-loop Poisson traffic: LOAD_RPS requests per second for
// LOAD_SECONDS, each request's URL drawn from LOAD_MIX ([{"url": ..., "w": weight}]),
// arrival times and URLs from LOAD_SEED (the same seed gives the same schedule).
// LOAD_PATTERN (optional) shapes the rate over time, its mean staying LOAD_RPS
// where it can: mmpp:BURST:HIGH_S:LOW_S (a two-state burst: BURST x the low rate for
// exponential stays of mean HIGH_S, then the low rate for mean LOW_S), ramp:FROM:TO
// (FROM x LOAD_RPS rising linearly to TO x LOAD_RPS), step:AT_S:FACTOR (LOAD_RPS, then
// FACTOR x LOAD_RPS from AT_S). Unset, the schedule is exactly the Poisson one above.
// It sends no trace context, so the services' spans start at the entry points. LOAD_LOG (optional) names a CSV
// it writes one line per request to: url index, sent and answered (Unix ns), ok (1 or 0).
// At the end it prints one JSON line per URL: requests, errors and latency
// percentiles as the client saw them.
package main

import (
	"encoding/json"
	"fmt"
	"io"
	"log"
	"math"
	"math/rand/v2"
	"net/http"
	"os"
	"sort"
	"strconv"
	"strings"
	"sync"
	"time"
)

type target struct {
	URL string  `json:"url"`
	W   float64 `json:"w"`
}

func env(k string) string {
	v := os.Getenv(k)
	if v == "" {
		log.Fatalf("%s is not set", k)
	}
	return v
}

func main() {
	rps, _ := strconv.ParseFloat(env("LOAD_RPS"), 64)
	secs, _ := strconv.ParseFloat(env("LOAD_SECONDS"), 64)
	seed, _ := strconv.ParseUint(env("LOAD_SEED"), 10, 64)
	var mix []target
	if err := json.Unmarshal([]byte(env("LOAD_MIX")), &mix); err != nil {
		log.Fatalf("LOAD_MIX: %v", err)
	}
	total := 0.0
	for _, t := range mix {
		total += t.W
	}
	rng := rand.New(rand.NewPCG(seed, 0x6c6f6164))
	type job struct {
		at  time.Duration
		url int
	}
	var jobs []job
	rate, lmax := pattern(os.Getenv("LOAD_PATTERN"), rps, secs, seed)
	for t := 0.0; ; {
		t += rng.ExpFloat64() / lmax
		if t >= secs {
			break
		}
		if rate != nil && rng.Float64()*lmax >= rate(t) { // thinning: only with a pattern
			continue
		}
		u, x := 0, rng.Float64()*total
		for u < len(mix)-1 && x >= mix[u].W {
			x -= mix[u].W
			u++
		}
		jobs = append(jobs, job{time.Duration(t * float64(time.Second)), u})
	}
	client := &http.Client{Timeout: 60 * time.Second,
		Transport: &http.Transport{MaxIdleConns: 4096, MaxIdleConnsPerHost: 2048, IdleConnTimeout: 90 * time.Second}}
	lat := make([][]float64, len(mix))
	errs := make([]int, len(mix))
	type rec struct {
		u    int
		s, e int64
		ok   bool
	}
	var recs []rec
	var mu sync.Mutex
	var wg sync.WaitGroup
	log.Printf("maze-load: %d requests over %.0f s (%.1f rps), seed %d", len(jobs), secs, rps, seed)
	t0 := time.Now()
	for _, j := range jobs {
		if d := j.at - time.Since(t0); d > 0 {
			time.Sleep(d) // late requests go out at once: bunching is kept
		}
		wg.Add(1)
		go func(u int) {
			defer wg.Done()
			s := time.Now()
			resp, err := client.Get(mix[u].URL)
			ok := err == nil
			if ok {
				io.Copy(io.Discard, resp.Body)
				resp.Body.Close()
				ok = resp.StatusCode == http.StatusOK
			}
			e := time.Now()
			ms := float64(e.Sub(s)) / 1e6
			mu.Lock()
			recs = append(recs, rec{u, s.UnixNano(), e.UnixNano(), ok})
			if ok {
				lat[u] = append(lat[u], ms)
			} else {
				errs[u]++
			}
			mu.Unlock()
		}(j.url)
	}
	wg.Wait()
	if p := os.Getenv("LOAD_LOG"); p != "" {
		f, err := os.Create(p)
		if err != nil {
			log.Fatalf("LOAD_LOG: %v", err)
		}
		fmt.Fprintln(f, "url,sent_unix_ns,answered_unix_ns,ok")
		for _, r := range recs {
			ok := 0
			if r.ok {
				ok = 1
			}
			fmt.Fprintf(f, "%d,%d,%d,%d\n", r.u, r.s, r.e, ok)
		}
		if err := f.Close(); err != nil {
			log.Fatalf("LOAD_LOG: %v", err)
		}
	}
	for u, t := range mix {
		xs := lat[u]
		sort.Float64s(xs)
		q := func(p float64) float64 {
			if len(xs) == 0 {
				return math.NaN()
			}
			return xs[int(math.Min(float64(len(xs)-1), p*float64(len(xs))))]
		}
		sum := 0.0
		for _, x := range xs {
			sum += x
		}
		out, _ := json.Marshal(map[string]any{"url": t.URL, "ok": len(xs), "errors": errs[u],
			"mean_ms": sum / math.Max(1, float64(len(xs))), "p50_ms": q(0.5), "p95_ms": q(0.95), "p99_ms": q(0.99)})
		fmt.Println(string(out))
	}
	log.Printf("maze-load: done in %.0f s", time.Since(t0).Seconds())
}

// pattern parses LOAD_PATTERN into a rate function of time (nil: constant LOAD_RPS) and the
// rate the arrivals are drawn at before thinning.
func pattern(p string, rps, secs float64, seed uint64) (func(float64) float64, float64) {
	if p == "" {
		return nil, rps
	}
	f := strings.Split(p, ":")
	num := func(i int) float64 {
		if i >= len(f) {
			log.Fatalf("LOAD_PATTERN %q: too few fields", p)
		}
		v, err := strconv.ParseFloat(f[i], 64)
		if err != nil || v < 0 {
			log.Fatalf("LOAD_PATTERN %q: field %d", p, i)
		}
		return v
	}
	switch f[0] {
	case "mmpp":
		burst, hi, lo := num(1), num(2), num(3)
		low := rps / (hi/(hi+lo)*burst + lo/(hi+lo))
		srng := rand.New(rand.NewPCG(seed, 0x6d6d7070)) // its own stream: the states do not move the arrivals' draws
		var ends []float64                              // the end of each state; even index = low, odd = high
		for t, k := 0.0, 0; t < secs; k++ {
			m := lo
			if k%2 == 1 {
				m = hi
			}
			t += srng.ExpFloat64() * m
			ends = append(ends, t)
		}
		return func(t float64) float64 {
			k := sort.SearchFloat64s(ends, t)
			if k%2 == 1 {
				return burst * low
			}
			return low
		}, burst * low
	case "ramp":
		a, b := num(1), num(2)
		return func(t float64) float64 { return rps * (a + (b-a)*t/secs) }, rps * math.Max(a, b)
	case "step":
		at, k := num(1), num(2)
		return func(t float64) float64 {
			if t < at {
				return rps
			}
			return k * rps
		}, rps * math.Max(1, k)
	}
	log.Fatalf("LOAD_PATTERN %q: unknown (mmpp, ramp, step)", p)
	return nil, rps
}
