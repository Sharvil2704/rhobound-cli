// Package rt is the runtime every maze service runs on. What a service does per request comes from MAZE_CONFIG
// (JSON, written by deploy/render.py from spec.json):
//
//	{"service": "catalog", "workers": 3,
//	 "routes": {"/search": {"work": {"mean_ms": 10, "cs2": 1.5}, "code": "catalog.search",
//	                        "steps": [{"par": [{"to": "index-a", "path": "/shard"}, ...]}],
//	                        "post": "", "after": [], "payload_kb": 0}}}
//
// A request takes a worker (first come, first served) inside its server span, runs its own work (the route's work
// draw, then its code hook) and frees the worker; then it runs its steps in order and answers. A step is one call
// ({"call": ...}, repeated "count": [lo, hi] times one after another), calls at once ({"par": [...]}) or n calls at once
// to one callee ({"batch": {"to", "path", "n": [lo, hi]}}). After the calls the route's post hook runs on the
// responses, without a worker. "after" calls go out once the response is written (fire and forget). A route with
// payload_kb answers with that many KiB. Peers are found through MAZE_PEERS ({"name": "http://host:port"}), else
// http://NAME:8080. Tracing is standard OpenTelemetry (otelhttp server and client spans, OTLP/HTTP).
package rt

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
	"sort"
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

// Image is the image this binary is (set at build time: -ldflags "-X maze/internal/rt.Image=NAME").
var Image = "dev"

// Call is one call to a peer.
type Call struct {
	To    string  `json:"to"`
	Path  string  `json:"path"`
	P     float64 `json:"p,omitempty"`     // probability per visit (0 = 1)
	Count [2]int  `json:"count,omitempty"` // calls one after another, uniform in [lo, hi] (zero = 1)
}

// Batch is n calls at once to one callee.
type Batch struct {
	To   string `json:"to"`
	Path string `json:"path"`
	N    [2]int `json:"n"`
}

// Step is one stage of a route: exactly one of Call, Par, Batch.
type Step struct {
	Call  *Call  `json:"call,omitempty"`
	Par   []Call `json:"par,omitempty"`
	Batch *Batch `json:"batch,omitempty"`
}

// Route is what the service does for one path.
type Route struct {
	Work      work.Dist `json:"work"`
	Code      string    `json:"code,omitempty"`
	Steps     []Step    `json:"steps,omitempty"`
	Post      string    `json:"post,omitempty"`
	After     []Call    `json:"after,omitempty"`
	PayloadKB int       `json:"payload_kb,omitempty"`
}

// Config is MAZE_CONFIG.
type Config struct {
	Service string           `json:"service"`
	Workers int              `json:"workers"`
	Routes  map[string]Route `json:"routes"`
}

// Req is what a hook sees: the request's path and query, the responses of the route's calls (post hooks), and the
// body it may set. A code hook may set Skip[i] to leave out the route's step i (a cache hit, say).
type Req struct {
	Path   string
	Query  string
	Bodies [][]byte
	Out    []byte
	Skip   map[int]bool
}

// Hook is a service's own code for a route, registered by name from the service's package.
type Hook func(*Req) error

var hooks = map[string]Hook{}

// Register adds a hook; service packages call it from init.
func Register(name string, h Hook) { hooks[name] = h }

func resolve(name string) (Hook, error) {
	if name == "" {
		return nil, nil
	}
	h, ok := hooks[name]
	if !ok {
		return nil, fmt.Errorf("no hook %q in image %s", name, Image)
	}
	return h, nil
}

func uniformInt(r [2]int) int {
	lo, hi := r[0], r[1]
	if lo <= 0 && hi <= 0 {
		return 1
	}
	if hi < lo {
		hi = lo
	}
	return lo + rand.IntN(hi-lo+1)
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
	tp := sdktrace.NewTracerProvider(sdktrace.WithResource(res), sdktrace.WithSampler(sdktrace.AlwaysSample()),
		sdktrace.WithBatcher(exp, sdktrace.WithMaxQueueSize(1<<17), sdktrace.WithMaxExportBatchSize(4096),
			sdktrace.WithBatchTimeout(time.Second)))
	otel.SetTracerProvider(tp)
	otel.SetTextMapPropagator(propagation.TraceContext{})
	return tp, nil
}

type server struct {
	cfg    Config
	peers  map[string]string
	client *http.Client
	sem    chan struct{}
	code   map[string]Hook
	post   map[string]Hook
	pay    map[string][]byte
}

func (s *server) url(to, path, q string) string {
	base, ok := s.peers[to]
	if !ok {
		base = "http://" + to + ":8080"
	}
	if q != "" {
		return base + path + "?" + q
	}
	return base + path
}

func (s *server) get(ctx context.Context, to, path, q string) ([]byte, error) {
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, s.url(to, path, q), nil)
	if err != nil {
		return nil, err
	}
	resp, err := s.client.Do(req)
	if err != nil {
		return nil, err
	}
	defer resp.Body.Close()
	b, err := io.ReadAll(resp.Body)
	if err != nil {
		return nil, err
	}
	if resp.StatusCode != http.StatusOK {
		return nil, fmt.Errorf("%s%s: %s", to, path, resp.Status)
	}
	return b, nil
}

// all runs fs at once and returns their bodies in order.
func all(fs []func() ([]byte, error)) ([][]byte, error) {
	out := make([][]byte, len(fs))
	errs := make([]error, len(fs))
	var wg sync.WaitGroup
	for i, f := range fs {
		wg.Add(1)
		go func() {
			defer wg.Done()
			out[i], errs[i] = f()
		}()
	}
	wg.Wait()
	return out, errors.Join(errs...)
}

func (s *server) steps(ctx context.Context, rt Route, q string, skip map[int]bool) ([][]byte, error) {
	var bodies [][]byte
	for i, st := range rt.Steps {
		if skip[i] {
			continue
		}
		switch {
		case st.Call != nil:
			c := st.Call
			if c.P > 0 && c.P < 1 && rand.Float64() >= c.P {
				continue
			}
			for range uniformInt(c.Count) {
				b, err := s.get(ctx, c.To, c.Path, q)
				if err != nil {
					return nil, err
				}
				bodies = append(bodies, b)
			}
		case len(st.Par) > 0:
			var fs []func() ([]byte, error)
			for _, c := range st.Par {
				if c.P > 0 && c.P < 1 && rand.Float64() >= c.P {
					continue
				}
				fs = append(fs, func() ([]byte, error) { return s.get(ctx, c.To, c.Path, q) })
			}
			bs, err := all(fs)
			if err != nil {
				return nil, err
			}
			bodies = append(bodies, bs...)
		case st.Batch != nil:
			b := st.Batch
			n := uniformInt(b.N)
			fs := make([]func() ([]byte, error), n)
			for i := range fs {
				iq := fmt.Sprintf("i=%d", i)
				if q != "" {
					iq = q + "&" + iq
				}
				fs[i] = func() ([]byte, error) { return s.get(ctx, b.To, b.Path, iq) }
			}
			bs, err := all(fs)
			if err != nil {
				return nil, err
			}
			bodies = append(bodies, bs...)
		}
	}
	return bodies, nil
}

func (s *server) handle(w http.ResponseWriter, r *http.Request) {
	rt, ok := s.cfg.Routes[r.URL.Path]
	if !ok {
		http.NotFound(w, r)
		return
	}
	req := &Req{Path: r.URL.Path, Query: r.URL.RawQuery}
	s.sem <- struct{}{}
	work.Process(rt.Work)
	var err error
	if h := s.code[r.URL.Path]; h != nil {
		err = h(req)
	}
	<-s.sem
	if err != nil {
		http.Error(w, err.Error(), http.StatusUnprocessableEntity)
		return
	}
	bodies, err := s.steps(r.Context(), rt, r.URL.RawQuery, req.Skip)
	if err != nil {
		http.Error(w, err.Error(), http.StatusBadGateway)
		return
	}
	if h := s.post[r.URL.Path]; h != nil {
		req.Bodies = bodies
		if err := h(req); err != nil {
			http.Error(w, err.Error(), http.StatusUnprocessableEntity)
			return
		}
	}
	out := req.Out
	if out == nil {
		out = s.pay[r.URL.Path]
	}
	if out == nil {
		out = []byte(`{"ok":true}`)
	}
	w.Header().Set("Content-Type", "application/octet-stream")
	w.Write(out)
	if len(rt.After) > 0 {
		ctx := context.WithoutCancel(r.Context())
		for _, c := range rt.After {
			go s.get(ctx, c.To, c.Path, "")
		}
	}
}

// Payload returns n KiB of deterministic printable bytes (a route's default response body).
func Payload(n int) []byte {
	b := make([]byte, n<<10)
	for i := range b {
		b[i] = 'a' + byte((i*7+i/13)%26)
	}
	return b
}

// Main runs the service until SIGINT or SIGTERM.
func Main() {
	var cfg Config
	if err := json.Unmarshal([]byte(os.Getenv("MAZE_CONFIG")), &cfg); err != nil {
		log.Fatalf("MAZE_CONFIG: %v", err)
	}
	if cfg.Workers < 1 || len(cfg.Routes) == 0 {
		log.Fatal("MAZE_CONFIG: workers >= 1 and at least one route")
	}
	peers := map[string]string{}
	if p := os.Getenv("MAZE_PEERS"); p != "" {
		if err := json.Unmarshal([]byte(p), &peers); err != nil {
			log.Fatalf("MAZE_PEERS: %v", err)
		}
	}
	s := &server{cfg: cfg, peers: peers, sem: make(chan struct{}, cfg.Workers),
		code: map[string]Hook{}, post: map[string]Hook{}, pay: map[string][]byte{}}
	paths := make([]string, 0, len(cfg.Routes))
	for path, rt := range cfg.Routes {
		paths = append(paths, path)
		var err error
		if s.code[path], err = resolve(rt.Code); err != nil {
			log.Fatal(err)
		}
		if s.post[path], err = resolve(rt.Post); err != nil {
			log.Fatal(err)
		}
		if rt.PayloadKB > 0 {
			s.pay[path] = Payload(rt.PayloadKB)
		}
	}
	sort.Strings(paths)
	ctx, stop := signal.NotifyContext(context.Background(), syscall.SIGINT, syscall.SIGTERM)
	defer stop()
	tp, err := tracing(ctx)
	if err != nil {
		log.Fatalf("tracing: %v", err)
	}
	s.client = &http.Client{Timeout: 30 * time.Second, Transport: otelhttp.NewTransport(&http.Transport{
		MaxIdleConns: 4096, MaxIdleConnsPerHost: 1024, IdleConnTimeout: 90 * time.Second})}
	mux := http.NewServeMux()
	mux.HandleFunc("/healthz", func(w http.ResponseWriter, r *http.Request) { io.WriteString(w, "ok") })
	mux.HandleFunc("/", s.handle)
	h := otelhttp.NewHandler(mux, cfg.Service,
		otelhttp.WithFilter(func(r *http.Request) bool { return r.URL.Path != "/healthz" }),
		otelhttp.WithSpanNameFormatter(func(_ string, r *http.Request) string { return r.Method + " " + r.URL.Path }))
	addr := os.Getenv("MAZE_LISTEN")
	if addr == "" {
		addr = ":8080"
	}
	srv := &http.Server{Addr: addr, Handler: h, ReadHeaderTimeout: 10 * time.Second}
	go func() {
		if err := srv.ListenAndServe(); err != nil && !errors.Is(err, http.ErrServerClosed) {
			log.Fatal(err)
		}
	}()
	log.Printf("maze %s (image %s): %d workers, routes %s", cfg.Service, Image, cfg.Workers, strings.Join(paths, " "))
	<-ctx.Done()
	sctx, cancel := context.WithTimeout(context.Background(), 20*time.Second)
	defer cancel()
	srv.Shutdown(sctx)
	tp.Shutdown(sctx)
}
