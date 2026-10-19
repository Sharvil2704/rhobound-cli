// SPDX-License-Identifier: Apache-2.0

// Command demoapp is a tiny HTTP service for the cluster test. It does
// "work" by sleeping for an exponentially distributed time (plus an optional
// constant), on at most WORKERS requests at once; queueing for a worker
// happens before its server span starts. Then it calls its downstream
// services, one after another or together. It writes one OTLP/JSON line to
// stdout per request, with W3C traceparent propagation, and uses only the
// standard library.
//
// KEEPALIVE=false makes every downstream call use a new connection. A
// Kubernetes Service picks the replica per connection, not per request, and
// Go's client reuses the most recently used idle connection, so with
// keep-alive a few pooled connections decide the split between replicas for
// minutes at a time (60/40 and 15-s windows at 80/20 were seen in the cluster
// test). Without keep-alive the split is random per request, which is what
// the model's "random" routing assumes. If a downstream call fails the
// request answers 502, so the load generator counts it.
package main

import (
	"crypto/rand"
	"encoding/hex"
	"fmt"
	"io"
	"math"
	mrand "math/rand"
	"net/http"
	"net/url"
	"os"
	"strconv"
	"strings"
	"sync"
	"time"
)

var (
	service  = env("SERVICE", "svc")
	pod      = env("POD_NAME", service+"-0")
	meanMs   = envF("MEAN_MS", 10)
	extraMs  = envF("EXTRA_MS", 0)
	parallel = env("PARALLEL", "false") == "true"
	calls    = split(env("CALLS", ""))
	sem      chan struct{}
	outMu    sync.Mutex
	client   = &http.Client{Timeout: 30 * time.Second, Transport: &http.Transport{
		MaxIdleConnsPerHost: 256,
		DisableKeepAlives:   env("KEEPALIVE", "true") == "false",
	}}
)

func env(k, d string) string {
	if v := os.Getenv(k); v != "" {
		return v
	}
	return d
}

func envF(k string, d float64) float64 {
	if v := os.Getenv(k); v != "" {
		if f, err := strconv.ParseFloat(v, 64); err == nil {
			return f
		}
	}
	return d
}

func split(s string) []string {
	var out []string
	for _, p := range strings.Split(s, ",") {
		if p = strings.TrimSpace(p); p != "" {
			out = append(out, p)
		}
	}
	return out
}

func randHex(n int) string {
	b := make([]byte, n)
	rand.Read(b)
	return hex.EncodeToString(b)
}

type spanRec struct {
	id, parent string
	kind       int
	start, end time.Time
	peer       string
}

func (s spanRec) json(trace string) string {
	attrs := ""
	if s.peer != "" {
		attrs = fmt.Sprintf(`,"attributes":[{"key":"server.address","value":{"stringValue":%q}}]`, s.peer)
	}
	return fmt.Sprintf(`{"traceId":%q,"spanId":%q,"parentSpanId":%q,"kind":%d,"startTimeUnixNano":"%d","endTimeUnixNano":"%d"%s}`,
		trace, s.id, s.parent, s.kind, s.start.UnixNano(), s.end.UnixNano(), attrs)
}

func emit(trace string, spans []spanRec) {
	var b strings.Builder
	fmt.Fprintf(&b, `{"resourceSpans":[{"resource":{"attributes":[{"key":"service.name","value":{"stringValue":%q}},`+
		`{"key":"k8s.pod.name","value":{"stringValue":%q}},{"key":"k8s.deployment.name","value":{"stringValue":%q}}]},`+
		`"scopeSpans":[{"spans":[`, service, pod, service)
	for i, s := range spans {
		if i > 0 {
			b.WriteByte(',')
		}
		b.WriteString(s.json(trace))
	}
	b.WriteString("]}]}]}\n")
	outMu.Lock()
	os.Stdout.WriteString(b.String())
	outMu.Unlock()
}

// parseTraceparent reads "00-<32 hex trace>-<16 hex span>-<flags>".
func parseTraceparent(h string) (trace, parent string) {
	p := strings.Split(h, "-")
	if len(p) == 4 && len(p[1]) == 32 && len(p[2]) == 16 {
		return p[1], p[2]
	}
	return randHex(16), ""
}

func handler(w http.ResponseWriter, r *http.Request) {
	trace, parent := parseTraceparent(r.Header.Get("traceparent"))
	sem <- struct{}{} // wait for a worker; the span starts when one is free
	start := time.Now()
	id := randHex(8)
	work := mrand.ExpFloat64()*meanMs + extraMs
	time.Sleep(time.Duration(work * float64(time.Millisecond)))
	<-sem // the worker is free while the calls run

	var mu sync.Mutex
	recs := []spanRec{}
	failed := false
	call := func(target string) {
		cid := randHex(8)
		cs := time.Now()
		req, _ := http.NewRequest("GET", target, nil)
		req.Header.Set("traceparent", "00-"+trace+"-"+cid+"-01")
		resp, err := client.Do(req)
		ok := err == nil && resp.StatusCode == http.StatusOK
		if err == nil {
			io.Copy(io.Discard, resp.Body)
			resp.Body.Close()
		}
		host := target
		if u, err := url.Parse(target); err == nil {
			host = u.Hostname()
		}
		mu.Lock()
		recs = append(recs, spanRec{id: cid, parent: id, kind: 3, start: cs, end: time.Now(), peer: host})
		failed = failed || !ok
		mu.Unlock()
	}
	if parallel {
		var wg sync.WaitGroup
		for _, c := range calls {
			wg.Add(1)
			go func(c string) { defer wg.Done(); call(c) }(c)
		}
		wg.Wait()
	} else {
		for _, c := range calls {
			call(c)
		}
	}
	end := time.Now()
	if failed {
		w.WriteHeader(http.StatusBadGateway)
	} else {
		w.WriteHeader(http.StatusOK)
		w.Write([]byte("ok"))
	}
	emit(trace, append([]spanRec{{id: id, parent: parent, kind: 2, start: start, end: end}}, recs...))
}

func main() {
	workers := int(envF("WORKERS", 1))
	sem = make(chan struct{}, workers)
	mrand.Seed(time.Now().UnixNano() ^ int64(math.Float64bits(meanMs)))
	mux := http.NewServeMux()
	mux.HandleFunc("/healthz", func(w http.ResponseWriter, r *http.Request) { w.Write([]byte("ok")) })
	mux.HandleFunc("/", handler)
	srv := &http.Server{Addr: ":" + env("PORT", "8080"), Handler: mux}
	fmt.Fprintf(os.Stderr, "%s (%s): %d workers, mean %.1f ms + %.1f ms, calls %v parallel=%v keepalive=%v\n",
		service, pod, workers, meanMs, extraMs, calls, parallel, env("KEEPALIVE", "true") != "false")
	if err := srv.ListenAndServe(); err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}
}
