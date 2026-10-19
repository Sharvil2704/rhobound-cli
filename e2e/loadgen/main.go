// SPDX-License-Identifier: Apache-2.0

// Command loadgen sends an open-loop Poisson stream of GET requests to one
// URL and prints a JSON summary of the latencies it measured. Its numbers are
// the cluster test's ground truth for end-to-end latency: they come from the
// client, not from any trace. Besides the mean it prints how many requests
// it sent, how far it ever fell behind its schedule (a stall of this process
// or of the node) and the mean of each window of send times, so that a short
// stall or a warm-up transient can be told from a steady shift.
package main

import (
	"encoding/json"
	"flag"
	"fmt"
	mrand "math/rand"
	"net/http"
	"sort"
	"sync"
	"time"
)

func main() {
	target := flag.String("target", "http://localhost:8080/", "URL to call")
	rps := flag.Float64("rps", 30, "requests per second (Poisson)")
	dur := flag.Duration("duration", 60*time.Second, "how long to send")
	skip := flag.Duration("skip", 0, "ignore the latencies of requests sent in this first part")
	seed := flag.Int64("seed", time.Now().UnixNano(), "random seed")
	window := flag.Duration("window", 10*time.Second, "report the mean latency of each window of this length (by send time)")
	flag.Parse()

	rng := mrand.New(mrand.NewSource(*seed))
	client := &http.Client{Timeout: 30 * time.Second, Transport: &http.Transport{MaxIdleConnsPerHost: 512}}
	var mu sync.Mutex
	var lat []float64
	errs, sent := 0, 0
	maxLag := time.Duration(0)
	nw := int(*dur / *window)
	if *dur%*window != 0 {
		nw++
	}
	wsum, wn := make([]float64, nw), make([]int, nw)
	var wg sync.WaitGroup
	t0 := time.Now()
	next := t0
	for {
		next = next.Add(time.Duration(rng.ExpFloat64() / *rps * float64(time.Second)))
		if next.Sub(t0) > *dur {
			break
		}
		time.Sleep(time.Until(next))
		sentAt := time.Now()
		maxLag = max(maxLag, sentAt.Sub(next))
		sent++
		wg.Add(1)
		go func() {
			defer wg.Done()
			req, _ := http.NewRequest("GET", *target, nil)
			// no traceparent: this is where the request starts, so the frontend's span is the trace's root. (The CLI
			// reads a frontend span whose parent is outside the capture as the entry; the reference counts such a
			// trace as broken, so without the header the capture reads the same in both.)
			resp, err := client.Do(req)
			d := time.Since(sentAt)
			mu.Lock()
			defer mu.Unlock()
			if err != nil || resp.StatusCode != 200 {
				errs++
				if resp != nil {
					resp.Body.Close()
				}
				return
			}
			resp.Body.Close()
			ms := float64(d) / float64(time.Millisecond)
			if w := int(sentAt.Sub(t0) / *window); w < nw {
				wsum[w] += ms
				wn[w]++
			}
			if sentAt.Sub(t0) >= *skip {
				lat = append(lat, ms)
			}
		}()
	}
	wg.Wait()
	sort.Float64s(lat)
	sum := 0.0
	for _, x := range lat {
		sum += x
	}
	windows := make([]map[string]any, 0, nw)
	for i := range wsum {
		m := 0.0
		if wn[i] > 0 {
			m = wsum[i] / float64(wn[i])
		}
		windows = append(windows, map[string]any{"start_s": (time.Duration(i) * *window).Seconds(), "n": wn[i], "mean_ms": m})
	}
	out := map[string]any{"requests": len(lat), "errors": errs, "sent": sent, "max_lag_ms": float64(maxLag) / float64(time.Millisecond),
		"windows": windows, "mean_ms": nil, "rps": *rps}
	if len(lat) > 0 {
		out["mean_ms"] = sum / float64(len(lat))
		out["p50_ms"] = lat[len(lat)/2]
		out["p99_ms"] = lat[len(lat)*99/100]
	}
	b, _ := json.Marshal(out)
	fmt.Println(string(b))
}
