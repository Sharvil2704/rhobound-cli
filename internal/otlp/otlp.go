// SPDX-License-Identifier: Apache-2.0

// Package otlp reads OpenTelemetry traces in OTLP/JSON (one
// ExportTraceServiceRequest per line, as the Collector's file exporter writes
// them), plain or gzip-compressed, and keeps only what the model needs.
package otlp

import (
	"bufio"
	"bytes"
	"compress/gzip"
	"encoding/json"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"regexp"
	"runtime"
	"sort"
	"strconv"
	"strings"
	"sync"
)

// Span kinds (OTLP SpanKind values).
const (
	KindInternal = 1
	KindServer   = 2
	KindClient   = 3
	KindProducer = 4
	KindConsumer = 5
)

// Span is one span reduced to the fields the model uses. Times are Unix
// nanoseconds.
type Span struct {
	Trace  [2]uint64
	ID     uint64
	Parent uint64 // 0 when the span has no parent
	Start  uint64
	End    uint64
	Res    int32 // index into Data.Resources
	Peer   int32 // index into Data.Peers for client spans, else -1
	Addr   int32 // index into Data.Addrs (the peer and its port) for client spans with a peer, else -1
	Scope  int32 // 1 + the index into Data.Scopes of the instrumentation scope that emitted the span; 0 when it names none
	Kind   uint8
}

// Dur returns the span's duration in milliseconds.
func (s *Span) Dur() float64 {
	if s.End < s.Start {
		return 0
	}
	return float64(s.End-s.Start) / 1e6
}

// Resource identifies who emitted a span.
type Resource struct {
	Service string // service.name, else k8s.deployment.name
	Pod     string // k8s.pod.name, else service.instance.id, else host.name
	Image   string // container.image.name[:tag]
}

// LongSpan is the duration, in nanoseconds, from which a SERVER span's name is kept (Data.LongNames).
const LongSpan = 1_000_000_000

// maxLongNames bounds Data.LongNames: a capture of spans that all last seconds keeps this many names.
const maxLongNames = 4096

// SpanKey names a span across the capture: its trace and its id.
type SpanKey struct {
	Trace [2]uint64
	ID    uint64
}

// Data is everything read from one capture.
type Data struct {
	Spans     []Span
	Resources []Resource
	Peers     []string
	Addrs     []string // "peer:port" as client spans name it (the port when given): where a call went
	Scopes    []string // instrumentation scope names (Span.Scope - 1 indexes it)
	// LongNames holds the names of the SERVER spans that lasted LongSpan or more (at most maxLongNames of them, the
	// first read), to name them in a report. Span names are not kept for the others.
	LongNames map[SpanKey]string
	Skipped   int // spans dropped for a missing id, service, start or end
	Probes    int // health and readiness probe spans dropped (see IsProbe)
	// ProbeChildren are spans whose parent was a dropped probe; they are
	// roots now (Parent 0), not spans with a lost parent.
	ProbeChildren int
	Files         []string
}

// ---------------------------------------------------------------- JSON shapes

type nanos uint64

func (n *nanos) UnmarshalJSON(b []byte) error {
	b = bytes.Trim(b, `"`)
	if len(b) == 0 {
		return nil
	}
	v, err := strconv.ParseUint(string(b), 10, 64)
	if err != nil {
		f, ferr := strconv.ParseFloat(string(b), 64)
		if ferr != nil {
			return err
		}
		v = uint64(f)
	}
	*n = nanos(v)
	return nil
}

type anyValue struct {
	StringValue string          `json:"stringValue"`
	IntValue    json.RawMessage `json:"intValue"` // a number, or (proto3 JSON) a string of one
}

// text is the value as text: a string, or an integer's digits.
func (v anyValue) text() string {
	if v.StringValue != "" || len(v.IntValue) == 0 {
		return v.StringValue
	}
	return strings.Trim(string(v.IntValue), `"`)
}

type keyValue struct {
	Key   string   `json:"key"`
	Value anyValue `json:"value"`
}

type jsonSpan struct {
	TraceID      string     `json:"traceId"`
	SpanID       string     `json:"spanId"`
	ParentSpanID string     `json:"parentSpanId"`
	Name         string     `json:"name"`
	Kind         int        `json:"kind"`
	Start        nanos      `json:"startTimeUnixNano"`
	End          nanos      `json:"endTimeUnixNano"`
	Attributes   []keyValue `json:"attributes"`
}

type jsonRequest struct {
	ResourceSpans []struct {
		Resource struct {
			Attributes []keyValue `json:"attributes"`
		} `json:"resource"`
		ScopeSpans []struct {
			Scope struct {
				Name string `json:"name"`
			} `json:"scope"`
			Spans []jsonSpan `json:"spans"`
		} `json:"scopeSpans"`
	} `json:"resourceSpans"`
}

// peerKeys are the attributes that name the far side of a client call, in
// order of preference.
var peerKeys = []string{"peer.service", "server.address", "net.peer.name", "http.host"}

// portKeys give the port of a client call's far side.
var portKeys = []string{"server.port", "net.peer.port"}

// The attributes that give a server span's path and method, in the
// reference's order (current and previous HTTP semantic conventions, then
// Zipkin and OpenTracing); the span name stands in for a missing path.
var (
	pathKeys   = []string{"url.path", "http.target", "http.route", "http.path", "http.url"}
	methodKeys = []string{"http.request.method", "http.method"}
)

// probeRoute is the reference's health-probe rule:
// kubelet liveness and readiness probes and gRPC health checks are not
// traffic. Left in, each probe is a near-zero visit and an entry request.
var probeRoute = regexp.MustCompile(`grpc\.health\.v1\.Health/|(^|\s)/(_?healthz?|readyz|livez|ready|ping)(\?|$)`)

// IsProbe reports whether a server span's route ("METHOD /path") is a
// health or readiness probe.
func IsProbe(route string) bool { return probeRoute.MatchString(route) }

// attr returns the first of keys that the span carries (even with an
// empty value, as the reference reads it) and whether there was one.
func attr(kvs []keyValue, keys []string) (string, bool) {
	for _, key := range keys {
		for _, kv := range kvs {
			if kv.Key == key {
				return kv.Value.StringValue, true
			}
		}
	}
	return "", false
}

// noQuery cuts a path's query string and fragment, only after a '/' (a
// span name such as "UsersController#show" is no URL).
func noQuery(p string) string {
	cut := -1
	for _, i := range []int{strings.IndexByte(p, '?'), strings.IndexByte(p, '#')} {
		if i >= 0 && (cut < 0 || i < cut) {
			cut = i
		}
	}
	if cut > 0 && strings.Contains(p[:cut], "/") {
		return p[:cut]
	}
	return p
}

// route is a server span's "METHOD /path" as the reference builds it: the
// path without its query, and an http.url without its scheme and host.
func route(js *jsonSpan) string {
	path, _ := attr(js.Attributes, pathKeys)
	if path == "" {
		path = js.Name
	}
	path = noQuery(path)
	if strings.HasPrefix(path, "http://") || strings.HasPrefix(path, "https://") {
		if strings.Count(path, "/") >= 3 {
			path = "/" + strings.SplitN(path, "/", 4)[3]
		} else {
			path = "/"
		}
	}
	meth, _ := attr(js.Attributes, methodKeys)
	return strings.TrimSpace(meth + " " + path)
}

func hex64(s string) (uint64, bool) {
	if len(s) != 16 {
		return 0, false
	}
	v, err := strconv.ParseUint(s, 16, 64)
	return v, err == nil
}

func traceID(s string) ([2]uint64, bool) {
	if len(s) != 32 {
		return [2]uint64{}, false
	}
	hi, err1 := strconv.ParseUint(s[:16], 16, 64)
	lo, err2 := strconv.ParseUint(s[16:], 16, 64)
	return [2]uint64{hi, lo}, err1 == nil && err2 == nil
}

// job is one raw request and its position in the capture.
type job struct {
	seq int
	raw []byte
}

// part is what one worker decodes from one request.
type part struct {
	seq     int
	res     []Resource
	peers   []string
	addrs   []string
	scopes  []string
	spans   []Span // Res, Peer, Addr and Scope index into this part's own tables
	probes  []SpanKey
	long    []longName
	skipped int
	err     error
}

// longName is the name of a SERVER span that lasted LongSpan or more.
type longName struct {
	key  SpanKey
	name string
}

func decodeRequest(raw []byte) part {
	var req jsonRequest
	var p part
	if err := json.Unmarshal(raw, &req); err != nil {
		p.err = err
		return p
	}
	peerIdx := map[string]int32{}
	addrIdx := map[string]int32{}
	scopeIdx := map[string]int32{}
	for _, rs := range req.ResourceSpans {
		var r Resource
		var svc, dep string
		var inst, host, imgName, imgTag string
		for _, kv := range rs.Resource.Attributes {
			switch kv.Key {
			case "service.name":
				svc = kv.Value.StringValue
			case "k8s.deployment.name":
				dep = kv.Value.StringValue
			case "k8s.pod.name":
				r.Pod = kv.Value.StringValue
			case "service.instance.id":
				inst = kv.Value.StringValue
			case "host.name":
				host = kv.Value.StringValue
			case "container.image.name":
				imgName = kv.Value.StringValue
			case "container.image.tag":
				imgTag = kv.Value.StringValue
			}
		}
		r.Service = svc
		if r.Service == "" {
			r.Service = dep
		}
		if r.Pod == "" {
			r.Pod = inst
		}
		if r.Pod == "" {
			r.Pod = host
		}
		r.Image = imgName
		if imgTag != "" && imgName != "" {
			r.Image = imgName + ":" + imgTag
		}
		ri := int32(len(p.res))
		p.res = append(p.res, r)
		for _, ss := range rs.ScopeSpans {
			var scope int32 // 0: no scope name
			if n := ss.Scope.Name; n != "" {
				si, seen := scopeIdx[n]
				if !seen {
					si = int32(len(p.scopes))
					p.scopes = append(p.scopes, n)
					scopeIdx[n] = si
				}
				scope = si + 1
			}
			for i := range ss.Spans {
				js := &ss.Spans[i]
				tid, ok1 := traceID(js.TraceID)
				sid, ok2 := hex64(js.SpanID)
				// a span without an end (0) or ending before it starts has no usable duration
				if !ok1 || !ok2 || r.Service == "" || js.Start == 0 || js.End < js.Start {
					p.skipped++
					continue
				}
				var pid uint64
				if js.ParentSpanID != "" {
					pid, _ = hex64(js.ParentSpanID)
				}
				if js.Kind == KindServer && IsProbe(route(js)) {
					p.probes = append(p.probes, SpanKey{tid, sid})
					continue
				}
				sp := Span{Trace: tid, ID: sid, Parent: pid, Start: uint64(js.Start), End: uint64(js.End),
					Res: ri, Peer: -1, Addr: -1, Scope: scope, Kind: uint8(js.Kind)}
				if js.Kind == KindServer && js.End-js.Start >= LongSpan {
					p.long = append(p.long, longName{SpanKey{tid, sid}, js.Name})
				}
				if js.Kind == KindClient {
					for _, key := range peerKeys {
						found := ""
						for _, kv := range js.Attributes {
							if kv.Key == key && kv.Value.StringValue != "" {
								found = kv.Value.StringValue
								break
							}
						}
						if found != "" {
							pi, seen := peerIdx[found]
							if !seen {
								pi = int32(len(p.peers))
								p.peers = append(p.peers, found)
								peerIdx[found] = pi
							}
							sp.Peer = pi
							addr := found
							for _, kv := range js.Attributes {
								if (kv.Key == portKeys[0] || kv.Key == portKeys[1]) && kv.Value.text() != "" {
									addr = found + ":" + kv.Value.text()
									break
								}
							}
							ai, seen := addrIdx[addr]
							if !seen {
								ai = int32(len(p.addrs))
								p.addrs = append(p.addrs, addr)
								addrIdx[addr] = ai
							}
							sp.Addr = ai
							break
						}
					}
				}
				p.spans = append(p.spans, sp)
			}
		}
	}
	return p
}

// ------------------------------------------------------------------- reading

// ReadDir reads every trace file in a capture: CAPTURE/traces/*.jsonl,
// *.json, and their .gz forms. A path to a single file or to a folder of
// trace files is also accepted. It uses all cores.
func ReadDir(path string) (*Data, error) {
	files, err := traceFiles(path)
	if err != nil {
		return nil, err
	}
	if len(files) == 0 {
		return nil, fmt.Errorf("no trace files (*.jsonl, *.json, *.gz) under %s", path)
	}
	workers := runtime.GOMAXPROCS(0)
	jobs := make(chan job, workers*2)
	parts := make(chan part, workers*2)
	var wg sync.WaitGroup
	for w := 0; w < workers; w++ {
		wg.Add(1)
		go func() {
			defer wg.Done()
			for j := range jobs {
				p := decodeRequest(j.raw)
				p.seq = j.seq
				parts <- p
			}
		}()
	}
	go func() { wg.Wait(); close(parts) }()

	var readErr error
	go func() {
		defer close(jobs)
		seq := 0
		for _, f := range files {
			if e := feedFile(f, jobs, &seq); e != nil {
				readErr = e
				return
			}
		}
	}()

	d := &Data{Files: files}
	resIdx := map[Resource]int32{}
	peerIdx := map[string]int32{}
	addrIdx := map[string]int32{}
	scopeIdx := map[string]int32{}
	var firstErr error
	// Parts arrive in the order the workers finish; they are merged in capture
	// order, so the spans, resources and peers (and every sum over them) come
	// out the same on every run.
	pending := map[int]part{}
	next := 0
	probes := map[SpanKey]bool{}
	merge := func(p part) {
		if p.err != nil {
			if firstErr == nil {
				firstErr = p.err
			}
			return
		}
		d.Skipped += p.skipped
		d.Probes += len(p.probes)
		for _, k := range p.probes {
			probes[k] = true
		}
		rmap := make([]int32, len(p.res))
		for i, r := range p.res {
			gi, ok := resIdx[r]
			if !ok {
				gi = int32(len(d.Resources))
				d.Resources = append(d.Resources, r)
				resIdx[r] = gi
			}
			rmap[i] = gi
		}
		pmap := make([]int32, len(p.peers))
		for i, s := range p.peers {
			gi, ok := peerIdx[s]
			if !ok {
				gi = int32(len(d.Peers))
				d.Peers = append(d.Peers, s)
				peerIdx[s] = gi
			}
			pmap[i] = gi
		}
		smap := make([]int32, len(p.scopes)+1) // 0 stays 0: no scope
		for i, s := range p.scopes {
			gi, ok := scopeIdx[s]
			if !ok {
				gi = int32(len(d.Scopes)) + 1
				d.Scopes = append(d.Scopes, s)
				scopeIdx[s] = gi
			}
			smap[i+1] = gi
		}
		for _, ln := range p.long {
			if d.LongNames == nil {
				d.LongNames = map[SpanKey]string{}
			}
			if len(d.LongNames) < maxLongNames {
				d.LongNames[ln.key] = ln.name
			}
		}
		amap := make([]int32, len(p.addrs))
		for i, s := range p.addrs {
			gi, ok := addrIdx[s]
			if !ok {
				gi = int32(len(d.Addrs))
				d.Addrs = append(d.Addrs, s)
				addrIdx[s] = gi
			}
			amap[i] = gi
		}
		for _, sp := range p.spans {
			sp.Res = rmap[sp.Res]
			if sp.Peer >= 0 {
				sp.Peer = pmap[sp.Peer]
			}
			if sp.Addr >= 0 {
				sp.Addr = amap[sp.Addr]
			}
			sp.Scope = smap[sp.Scope]
			d.Spans = append(d.Spans, sp)
		}
	}
	for p := range parts {
		pending[p.seq] = p
		for {
			q, ok := pending[next]
			if !ok {
				break
			}
			delete(pending, next)
			next++
			merge(q)
		}
	}
	if readErr != nil {
		return nil, readErr
	}
	if firstErr != nil {
		return nil, fmt.Errorf("bad OTLP/JSON: %w", firstErr)
	}
	if len(probes) > 0 {
		// a probe's own child spans (zipkin-go records the health check under its GET /health) are probe
		// traffic with no parent left, not spans whose parent was lost: they would mark their trace broken
		for i := range d.Spans {
			sp := &d.Spans[i]
			if sp.Parent != 0 && probes[SpanKey{sp.Trace, sp.Parent}] {
				sp.Parent = 0
				d.ProbeChildren++
			}
		}
	}
	return d, nil
}

func traceFiles(path string) ([]string, error) {
	st, err := os.Stat(path)
	if err != nil {
		return nil, err
	}
	if !st.IsDir() {
		return []string{path}, nil
	}
	dir := path
	if sub := filepath.Join(path, "traces"); isDir(sub) {
		dir = sub
	}
	ents, err := os.ReadDir(dir)
	if err != nil {
		return nil, err
	}
	var out []string
	for _, e := range ents {
		if e.IsDir() {
			continue
		}
		n := e.Name()
		if strings.HasSuffix(n, ".jsonl") || strings.HasSuffix(n, ".json") ||
			strings.HasSuffix(n, ".jsonl.gz") || strings.HasSuffix(n, ".json.gz") {
			out = append(out, filepath.Join(dir, n))
		}
	}
	sort.Strings(out)
	return out, nil
}

func isDir(p string) bool {
	st, err := os.Stat(p)
	return err == nil && st.IsDir()
}

func feedFile(path string, jobs chan<- job, seq *int) error {
	f, err := os.Open(path)
	if err != nil {
		return err
	}
	defer f.Close()
	var r io.Reader = f
	if strings.HasSuffix(path, ".gz") {
		gz, err := gzip.NewReader(f)
		if err != nil {
			return fmt.Errorf("%s: %w", path, err)
		}
		defer gz.Close()
		r = gz
	}
	if strings.Contains(filepath.Base(path), ".jsonl") {
		br := bufio.NewReaderSize(r, 1<<20)
		for {
			line, err := br.ReadBytes('\n')
			if len(bytes.TrimSpace(line)) > 0 {
				jobs <- job{*seq, line}
				*seq++
			}
			if err == io.EOF {
				return nil
			}
			if err != nil {
				return fmt.Errorf("%s: %w", path, err)
			}
		}
	}
	// *.json: any number of whitespace-separated top-level values
	dec := json.NewDecoder(bufio.NewReaderSize(r, 1<<20))
	for {
		var raw json.RawMessage
		if err := dec.Decode(&raw); err == io.EOF {
			return nil
		} else if err != nil {
			return fmt.Errorf("%s: %w", path, err)
		}
		jobs <- job{*seq, []byte(raw)}
		*seq++
	}
}
