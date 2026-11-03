// maze-svc is one maze microservice. What it does per request comes from
// the MAZE_CONFIG environment variable (JSON):
//
//	{"workers": 2,                                  // request workers in this pod
//	 "work": {"mean_ms": 9, "cs2": 0.5},            // own processing time per request
//	 "code_paths": ["verify_token"],                // shared library code it runs per request
//	 "mode": "sequential" | "parallel",             // how it calls its dependencies
//	 "calls": [{"url": "http://auth:8080/verify", "p": 1, "fresh_conn": false}],
//	 "hold": false}                                 // keep the worker through the calls (round 57)
//
// A request waits for a free worker (first come, first served), holds it for
// its own processing, releases it, then calls its dependencies and answers.
// With "hold": true it keeps the worker until it has answered (a thread-per-
// request server that blocks on its downstream calls).
// "{tail}" in a call URL is replaced by the last segment of the request path.
// fresh_conn opens a new connection per call, so a Kubernetes Service spreads
// the calls over its pods at random.
//
// Tracing is standard OpenTelemetry: otelhttp server and client spans,
// exported over OTLP/HTTP to OTEL_EXPORTER_OTLP_ENDPOINT, every request sampled.
package main

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"log"
	"math/rand/v2"
	"net/http"
	"os"
	"os/signal"
	"path"
	"strings"
	"sync"
	"syscall"
	"time"

	"go.opentelemetry.io/contrib/instrumentation/net/http/otelhttp"
	"go.opentelemetry.io/otel"
	"go.opentelemetry.io/otel/exporters/otlp/otlptrace/otlptracehttp"
	"go.opentelemetry.io/otel/propagation"
	"go.opentelemetry.io/otel/sdk/resource"
	sdktrace "go.opentelemetry.io/otel/sdk/trace"

	"maze/internal/work"
)

type call struct {
	URL       string  `json:"url"`
	P         float64 `json:"p"`
	FreshConn bool    `json:"fresh_conn"`
}

type config struct {
	Workers   int       `json:"workers"`
	Work      work.Dist `json:"work"`
	CodePaths []string  `json:"code_paths"`
	Mode      string    `json:"mode"`
	Calls     []call    `json:"calls"`
	Hold      bool      `json:"hold"`
	// round 75, a Python-like server: Gap takes the worker BEFORE the server span starts (a thread pool that picks a
	// request off its queue, then opens the span) and holds it to the end; OwnSlots (k > 0) lets at most k requests run
	// their own work at once, before the calls (Work) and after them (Post): CPython's GIL
	Gap      bool      `json:"gap"`
	OwnSlots int       `json:"own_slots"`
	Post     work.Dist `json:"post_work"`
}

func tracing(ctx context.Context) (*sdktrace.TracerProvider, error) {
	exp, err := otlptracehttp.New(ctx)
	if err != nil {
		return nil, err
	}
	res, err := resource.New(ctx, resource.WithFromEnv(), resource.WithTelemetrySDK())
	if err != nil {
		return nil, err
	}
	opts := []sdktrace.TracerProviderOption{
		sdktrace.WithResource(res),
		sdktrace.WithBatcher(exp, sdktrace.WithMaxQueueSize(1<<16), sdktrace.WithMaxExportBatchSize(4096),
			sdktrace.WithBatchTimeout(time.Second)),
	}
	// every request is traced unless the standard OTEL_TRACES_SAMPLER says otherwise (round 30: head sampling, e.g.
	// parentbased_traceidratio with OTEL_TRACES_SAMPLER_ARG=0.1, read by the SDK itself)
	if os.Getenv("OTEL_TRACES_SAMPLER") == "" {
		opts = append(opts, sdktrace.WithSampler(sdktrace.AlwaysSample()))
	}
	tp := sdktrace.NewTracerProvider(opts...)
	otel.SetTracerProvider(tp)
	otel.SetTextMapPropagator(propagation.TraceContext{})
	return tp, nil
}

func main() {
	var cfg config
	if err := json.Unmarshal([]byte(os.Getenv("MAZE_CONFIG")), &cfg); err != nil {
		log.Fatalf("MAZE_CONFIG: %v", err)
	}
	if cfg.Workers < 1 {
		log.Fatal("MAZE_CONFIG: workers must be >= 1")
	}
	ctx, stop := signal.NotifyContext(context.Background(), syscall.SIGINT, syscall.SIGTERM)
	defer stop()
	tp, err := tracing(ctx)
	if err != nil {
		log.Fatalf("tracing: %v", err)
	}

	keep := otelhttp.NewTransport(&http.Transport{MaxIdleConns: 1024, MaxIdleConnsPerHost: 256,
		IdleConnTimeout: 90 * time.Second})
	fresh := otelhttp.NewTransport(&http.Transport{DisableKeepAlives: true})
	clients := map[bool]*http.Client{false: {Transport: keep, Timeout: 30 * time.Second},
		true: {Transport: fresh, Timeout: 30 * time.Second}}

	paths := map[string]bool{}
	for _, p := range cfg.CodePaths {
		paths[p] = true
	}
	sem := make(chan struct{}, cfg.Workers) // a buffered channel queues blocked senders in arrival order
	var gil chan struct{}
	if cfg.OwnSlots > 0 {
		gil = make(chan struct{}, cfg.OwnSlots)
	}
	own := func(f func()) {
		if gil != nil {
			gil <- struct{}{}
			defer func() { <-gil }()
		}
		f()
	}

	do := func(ctx context.Context, c call, tail string) error {
		req, err := http.NewRequestWithContext(ctx, http.MethodGet, strings.ReplaceAll(c.URL, "{tail}", tail), nil)
		if err != nil {
			return err
		}
		resp, err := clients[c.FreshConn].Do(req)
		if err != nil {
			return err
		}
		defer resp.Body.Close()
		io.Copy(io.Discard, resp.Body)
		if resp.StatusCode != http.StatusOK {
			return fmt.Errorf("%s: %s", c.URL, resp.Status)
		}
		return nil
	}

	mux := http.NewServeMux()
	mux.HandleFunc("/healthz", func(w http.ResponseWriter, r *http.Request) { io.WriteString(w, "ok") })
	mux.HandleFunc("/", func(w http.ResponseWriter, r *http.Request) {
		tail := path.Base(r.URL.Path)
		held := false
		release := func() {
			if held {
				held = false
				<-sem
			}
		}
		if !cfg.Gap { // gap mode: the worker was taken before the span (see the outer handler)
			sem <- struct{}{}
			held = true
		}
		if cfg.Hold {
			defer release()
		}
		ok := true
		own(func() {
			work.Process(cfg.Work)
			if paths["verify_token"] {
				ok = ok && work.VerifyToken(r.Header.Get("X-Session")+tail)
			}
			if paths["risk_check"] {
				ok = ok && work.RiskCheck(tail)
			}
			if paths["stock_check"] {
				ok = ok && work.StockCheck(tail)
			}
		})
		if !cfg.Hold {
			release()
		}
		if !ok {
			http.Error(w, "rejected", http.StatusForbidden)
			return
		}
		var todo []call
		for _, c := range cfg.Calls {
			if c.P >= 1 || rand.Float64() < c.P {
				todo = append(todo, c)
			}
		}
		var errs []error
		if cfg.Mode == "parallel" && len(todo) > 1 {
			var wg sync.WaitGroup
			var m sync.Mutex
			for _, c := range todo {
				wg.Add(1)
				go func(c call) {
					defer wg.Done()
					if err := do(r.Context(), c, tail); err != nil {
						m.Lock()
						errs = append(errs, err)
						m.Unlock()
					}
				}(c)
			}
			wg.Wait()
		} else {
			for _, c := range todo {
				if err := do(r.Context(), c, tail); err != nil {
					errs = append(errs, err)
					break
				}
			}
		}
		if len(errs) > 0 {
			http.Error(w, errors.Join(errs...).Error(), http.StatusBadGateway)
			return
		}
		if cfg.Post.MeanMs > 0 {
			own(func() { work.Process(cfg.Post) })
		}
		w.Header().Set("Content-Type", "application/json")
		io.WriteString(w, `{"ok":true}`)
	})

	h := otelhttp.NewHandler(mux, "maze",
		otelhttp.WithFilter(func(r *http.Request) bool { return r.URL.Path != "/healthz" }),
		otelhttp.WithSpanNameFormatter(func(_ string, r *http.Request) string { return r.Method + " " + r.URL.Path }))
	var top http.Handler = h
	if cfg.Gap {
		// the worker is taken before otelhttp opens the span and held until the span has ended
		top = http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
			if r.URL.Path == "/healthz" {
				h.ServeHTTP(w, r)
				return
			}
			sem <- struct{}{}
			defer func() { <-sem }()
			h.ServeHTTP(w, r)
		})
	}
	srv := &http.Server{Addr: ":8080", Handler: top, ReadHeaderTimeout: 10 * time.Second}
	go func() {
		if err := srv.ListenAndServe(); err != nil && !errors.Is(err, http.ErrServerClosed) {
			log.Fatal(err)
		}
	}()
	log.Printf("maze-svc %s: %d workers, %s calls %d, hold %v, gap %v, own slots %d", os.Getenv("OTEL_SERVICE_NAME"),
		cfg.Workers, cfg.Mode, len(cfg.Calls), cfg.Hold, cfg.Gap, cfg.OwnSlots)
	<-ctx.Done()
	sctx, cancel := context.WithTimeout(context.Background(), 20*time.Second)
	defer cancel()
	srv.Shutdown(sctx)
	tp.Shutdown(sctx)
}
