package main

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"math/rand/v2"
	"net"
	"net/http"
	"os"
	"sort"
	"strconv"
	"strings"
	"sync"
	"sync/atomic"
	"time"
)

// Mix is the request mix abmix.py writes (mix.json, SPEC 5 step 1). Other keys are ignored.
type Mix struct {
	Service     string    `json:"service"`
	RatePerPod  float64   `json:"rate_per_pod"`
	Paths       []MixPath `json:"paths"`
	FromCapture string    `json:"from_capture"`
}

// MixPath is one path of the mix and its weight.
type MixPath struct {
	Path string  `json:"path"`
	W    float64 `json:"w"`
}

// ReadMix reads and validates mix.json.
func ReadMix(path string) (*Mix, error) {
	b, err := os.ReadFile(path)
	if err != nil {
		return nil, err
	}
	var m Mix
	if err := json.Unmarshal(b, &m); err != nil {
		return nil, fmt.Errorf("%s: %w", path, err)
	}
	if len(m.Paths) == 0 {
		return nil, fmt.Errorf("%s: no paths", path)
	}
	sum := 0.0
	for _, p := range m.Paths {
		if !strings.HasPrefix(p.Path, "/") || !(p.W >= 0) {
			return nil, fmt.Errorf("%s: path %q weight %v: want a path from / and a weight >= 0", path, p.Path, p.W)
		}
		sum += p.W
	}
	if !(sum > 0) {
		return nil, fmt.Errorf("%s: the weights sum to %v", path, sum)
	}
	return &m, nil
}

// Arrival is one scheduled request: its offset from the run's start and the index of its path.
type Arrival struct {
	At   time.Duration
	Path int
}

// Schedule is the open-loop Poisson schedule over total: exponential gaps at rate per second, each arrival's path
// drawn by weight, all from one generator seeded with seed (the same seed gives the same schedule).
func Schedule(rate float64, total time.Duration, weights []float64, seed uint64) []Arrival {
	r := rand.New(rand.NewPCG(seed, 0x61626472697665))
	cum := make([]float64, len(weights))
	s := 0.0
	for i, w := range weights {
		s += w
		cum[i] = s
	}
	var out []Arrival
	for t := 0.0; ; {
		t += r.ExpFloat64() / rate
		if t >= total.Seconds() {
			return out
		}
		u := r.Float64() * s
		k := sort.Search(len(cum), func(i int) bool { return u < cum[i] })
		if k == len(cum) {
			k = len(cum) - 1
		}
		out = append(out, Arrival{At: time.Duration(t * 1e9), Path: k})
	}
}

// Config is one run of the driver.
type Config struct {
	URLs      [2]string // arm A (baseline) and arm B (candidate) base URLs
	Paths     []string
	Weights   []float64
	Rate      float64 // arrivals per second, each sent to both arms
	Seconds   float64 // the measured run
	Warmup    float64 // before it, not logged
	Seed      uint64
	FreshConn bool          // a new connection per request; default keep-alive
	Host      string        // the Host header sent to both arms ("": each URL's own host)
	Timeout   time.Duration // per request
	Log       io.Writer
}

// Row is one measured request to one arm. Done: an answer (any status) was read whole.
type Row struct {
	Sent, Answered int64
	Status         int
	Done           bool
	Err            string
}

// Counts are the warm-up's requests to one arm.
type Counts struct {
	Sent, Answered, Failed int64
}

// Result is a run: Rows[arm][seq-1] for the measured arrivals.
type Result struct {
	Rows        [2][]Row
	Warm        [2]Counts
	LateMaxNs   int64 // the latest a measured send went out after its scheduled time
	LateOver1ms int   // measured sends more than 1 ms late
	Interrupted bool
}

// clock gives Unix nanoseconds from one wall reading advanced by the monotonic clock.
type clock struct{ wall0 time.Time }

func (c clock) now() int64 { return c.wall0.UnixNano() + time.Since(c.wall0).Nanoseconds() }

func newClient(fresh bool, timeout time.Duration) *http.Client {
	tr := &http.Transport{
		Proxy:                 nil,
		DialContext:           (&net.Dialer{Timeout: 5 * time.Second, KeepAlive: 30 * time.Second}).DialContext,
		MaxIdleConns:          1024, // as kshop-svc's keep-alive callers
		MaxIdleConnsPerHost:   256,
		IdleConnTimeout:       90 * time.Second,
		DisableKeepAlives:     fresh,
		ResponseHeaderTimeout: timeout,
	}
	return &http.Client{Transport: tr, Timeout: timeout}
}

// A request carries only what kshop's own callers send (a GET from Go's net/http: Host, User-Agent
// Go-http-client/1.1, Accept-Encoding gzip), so an arm cannot tell the A/B from production by its headers; the
// arrival's index stays in abdrive's own records (loadgen.csv's seq). Not the traceparent kshop-svc's otelhttp transport
// adds: the arm's SERVER span must stay its trace's root (splitarms.py, SPEC 0b rule 4). tagHeader, set by the tests
// only, names a header that carries the index (the same on both arms, warm-up included).
var tagHeader string

func fire(c *http.Client, url, host string, idx int, clk clock) Row {
	req, err := http.NewRequest(http.MethodGet, url, nil)
	if err != nil {
		return Row{Err: err.Error()}
	}
	if host != "" {
		req.Host = host
	}
	if tagHeader != "" {
		req.Header.Set(tagHeader, strconv.Itoa(idx))
	}
	sent := clk.now()
	resp, err := c.Do(req)
	if err != nil {
		return Row{Sent: sent, Answered: clk.now(), Err: err.Error()}
	}
	_, err = io.Copy(io.Discard, resp.Body)
	resp.Body.Close()
	ans := clk.now()
	if err != nil {
		return Row{Sent: sent, Answered: ans, Status: resp.StatusCode, Err: "body: " + err.Error()}
	}
	return Row{Sent: sent, Answered: ans, Status: resp.StatusCode, Done: true}
}

// Drive runs the schedule: the warm-up, then the measured run; every arrival goes to both arms at once, open loop (a
// late send goes out at once, never waits for an answer). ctx ends the sending early (Interrupted); requests in flight
// still finish or time out.
func Drive(ctx context.Context, cfg Config) (*Result, error) {
	if len(cfg.Paths) == 0 || len(cfg.Paths) != len(cfg.Weights) || !(cfg.Rate > 0) || !(cfg.Seconds > 0) ||
		!(cfg.Warmup >= 0) || cfg.Timeout <= 0 {
		return nil, errors.New("abdrive: paths with weights, rate > 0, seconds > 0, warmup >= 0 and a timeout are needed")
	}
	logw := cfg.Log
	if logw == nil {
		logw = io.Discard
	}
	warm := time.Duration(cfg.Warmup * 1e9)
	sched := Schedule(cfg.Rate, warm+time.Duration(cfg.Seconds*1e9), cfg.Weights, cfg.Seed)
	nWarm := sort.Search(len(sched), func(i int) bool { return sched[i].At >= warm })
	res := &Result{}
	for k := range res.Rows {
		res.Rows[k] = make([]Row, len(sched)-nWarm)
	}
	if len(sched) == nWarm {
		return nil, errors.New("abdrive: the schedule has no measured arrival (rate x seconds too small)")
	}
	clients := [2]*http.Client{newClient(cfg.FreshConn, cfg.Timeout), newClient(cfg.FreshConn, cfg.Timeout)}
	urls := make([][2]string, len(cfg.Paths))
	for i, p := range cfg.Paths {
		for k := range urls[i] {
			urls[i][k] = strings.TrimRight(cfg.URLs[k], "/") + p
		}
	}
	clk := clock{wall0: time.Now()}
	start := time.Now()
	fmt.Fprintf(logw, "abdrive: %d arrivals (%d warm-up) at %.3g/s to each arm, keep-alive %v\n", len(sched), nWarm,
		cfg.Rate, !cfg.FreshConn)
	var wg sync.WaitGroup
	var warmCounts [2][3]atomic.Int64
	timer := time.NewTimer(time.Hour)
	timer.Stop()
	for i, ar := range sched {
		if d := time.Until(start.Add(ar.At)); d > 0 {
			timer.Reset(d)
			select {
			case <-ctx.Done():
				timer.Stop()
				res.Interrupted = true
			case <-timer.C:
			}
		} else if ctx.Err() != nil {
			res.Interrupted = true
		}
		if res.Interrupted {
			fmt.Fprintf(logw, "abdrive: interrupted at arrival %d of %d\n", i, len(sched))
			break
		}
		if i == nWarm {
			fmt.Fprintf(logw, "abdrive: measured run from %s\n", time.Unix(0, clk.now()).UTC().Format(time.RFC3339Nano))
		}
		if i >= nWarm {
			if late := time.Since(start.Add(ar.At)).Nanoseconds(); late > res.LateMaxNs {
				res.LateMaxNs = late
			}
			if time.Since(start.Add(ar.At)) > time.Millisecond {
				res.LateOver1ms++
			}
		}
		for k := 0; k < 2; k++ {
			wg.Add(1)
			go func() {
				defer wg.Done()
				row := fire(clients[k], urls[ar.Path][k], cfg.Host, i, clk)
				if i >= nWarm {
					res.Rows[k][i-nWarm] = row
					return
				}
				warmCounts[k][0].Add(1)
				if row.Done {
					warmCounts[k][1].Add(1)
				} else {
					warmCounts[k][2].Add(1)
				}
			}()
		}
	}
	wg.Wait()
	for k := range res.Warm {
		res.Warm[k] = Counts{warmCounts[k][0].Load(), warmCounts[k][1].Load(), warmCounts[k][2].Load()}
	}
	for _, c := range clients {
		c.CloseIdleConnections()
	}
	return res, nil
}
