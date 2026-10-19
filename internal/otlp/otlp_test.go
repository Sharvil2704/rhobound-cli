// SPDX-License-Identifier: Apache-2.0

package otlp

import (
	"bytes"
	"compress/gzip"
	"fmt"
	"os"
	"path/filepath"
	"sort"
	"strings"
	"testing"
)

const req = `{"resourceSpans":[{"resource":{"attributes":[{"key":"service.name","value":{"stringValue":"api"}},` +
	`{"key":"k8s.pod.name","value":{"stringValue":"api-1"}},{"key":"container.image.name","value":{"stringValue":"reg/api"}},` +
	`{"key":"container.image.tag","value":{"stringValue":"1.2"}}]},"scopeSpans":[{"spans":[` +
	`{"traceId":"0102030405060708090a0b0c0d0e0f10","spanId":"1111111111111111","parentSpanId":"","kind":2,` +
	`"startTimeUnixNano":"1700000000000000000","endTimeUnixNano":"1700000000010000000"},` +
	`{"traceId":"0102030405060708090a0b0c0d0e0f10","spanId":"2222222222222222","parentSpanId":"1111111111111111","kind":3,` +
	`"startTimeUnixNano":1700000000002000000,"endTimeUnixNano":"1700000000008000000",` +
	`"attributes":[{"key":"http.host","value":{"stringValue":"slow.example"}},{"key":"server.address","value":{"stringValue":"db"}}]},` +
	`{"traceId":"zz","spanId":"3333333333333333","kind":2,"startTimeUnixNano":"1","endTimeUnixNano":"2"}]}]}]}`

func write(t *testing.T, dir, name, body string) {
	t.Helper()
	if err := os.MkdirAll(dir, 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(dir, name), []byte(body), 0o644); err != nil {
		t.Fatal(err)
	}
}

func TestReadJSONLines(t *testing.T) {
	dir := t.TempDir()
	write(t, filepath.Join(dir, "traces"), "a.jsonl", req+"\n\n"+req+"\n")
	d, err := ReadDir(dir)
	if err != nil {
		t.Fatal(err)
	}
	if len(d.Spans) != 4 || d.Skipped != 2 {
		t.Fatalf("spans=%d skipped=%d, want 4 and 2 (a bad trace id is skipped, not fatal)", len(d.Spans), d.Skipped)
	}
	if len(d.Resources) != 1 || d.Resources[0].Service != "api" || d.Resources[0].Pod != "api-1" || d.Resources[0].Image != "reg/api:1.2" {
		t.Errorf("resources: %+v", d.Resources)
	}
	var client *Span
	for i := range d.Spans {
		if d.Spans[i].Kind == KindClient {
			client = &d.Spans[i]
		}
	}
	if client == nil || client.Peer < 0 || d.Peers[client.Peer] != "db" {
		t.Fatalf("client peer: %+v peers=%v (peer.service, then server.address, wins over http.host)", client, d.Peers)
	}
	if got := client.Dur(); got != 6 {
		t.Errorf("duration %v ms, want 6 (a start given as a bare number is read too)", got)
	}
}

func TestReadGzipAndPrettyJSON(t *testing.T) {
	dir := t.TempDir()
	var buf bytes.Buffer
	zw := gzip.NewWriter(&buf)
	zw.Write([]byte(req + "\n"))
	zw.Close()
	write(t, dir, "a.jsonl.gz", buf.String())
	write(t, dir, "b.json", strings.ReplaceAll(req, `,"scopeSpans"`, ",\n  \"scopeSpans\"")+"\n"+req)
	d, err := ReadDir(dir)
	if err != nil {
		t.Fatal(err)
	}
	if len(d.Spans) != 6 || len(d.Files) != 2 {
		t.Fatalf("spans=%d files=%v", len(d.Spans), d.Files)
	}
}

func TestErrors(t *testing.T) {
	if _, err := ReadDir(filepath.Join(t.TempDir(), "missing")); err == nil {
		t.Error("a missing path should fail")
	}
	empty := t.TempDir()
	if _, err := ReadDir(empty); err == nil || !strings.Contains(err.Error(), "no trace files") {
		t.Errorf("empty folder: %v", err)
	}
	bad := t.TempDir()
	write(t, bad, "x.jsonl", "{not json}\n")
	if _, err := ReadDir(bad); err == nil || !strings.Contains(err.Error(), "bad OTLP/JSON") {
		t.Errorf("bad json: %v", err)
	}
	// zstd and proto are named, not guessed
	z := t.TempDir()
	write(t, z, "x.jsonl.zst", "x")
	if _, err := ReadDir(z); err == nil {
		t.Error("an unsupported compression should not be read")
	}
}

// probeCases are server (and one client) spans, and whether the reference implementation's reader drops each as a
// health or readiness probe (its health-probe rule, run on these spans).
var probeCases = []struct {
	attrs map[string]string
	name  string
	kind  int
	probe bool
}{
	{map[string]string{"url.path": "/healthz", "http.request.method": "GET"}, "", 2, true},
	{map[string]string{"http.target": "/health?x=1"}, "", 2, true},
	{map[string]string{"http.route": "/readyz"}, "", 2, true},
	{nil, "GET /livez", 2, true},
	{map[string]string{"http.url": "http://10.0.0.1:8080/ready"}, "", 2, true},
	{map[string]string{"http.url": "https://host/ping?probe"}, "", 2, true},
	{nil, "grpc.health.v1.Health/Check", 2, true},
	{map[string]string{"url.path": "/api/health"}, "", 2, false},
	{map[string]string{"url.path": "/healthy"}, "", 2, false},
	{map[string]string{"url.path": "/ping2"}, "", 2, false},
	{map[string]string{"url.path": "/_health"}, "", 2, true},
	{map[string]string{"url.path": "/healthcheck"}, "", 2, false},
	{map[string]string{"url.path": ""}, "/healthz", 2, true},
	{map[string]string{"url.path": "/ready/"}, "", 2, false},
	{map[string]string{"url.path": "/healthz", "http.method": "POST"}, "", 2, true},
	{map[string]string{"http.target": "/healthz#frag"}, "", 2, true},
	{nil, "UsersController#show", 2, false},
	{map[string]string{"url.path": "/HEALTHZ"}, "", 2, false},
	{map[string]string{"url.path": "/livez?verbose"}, "", 2, true},
	{nil, "GET /api/ready", 2, false},
	{map[string]string{"http.url": "http://host"}, "", 2, false},
	{map[string]string{"url.path": "/healthz"}, "", 3, false},
	{map[string]string{"url.path": "/readyz", "http.target": "/orders"}, "", 2, true},
	{map[string]string{"http.target": "/orders", "http.route": "/healthz"}, "", 2, false},
	{nil, "/ping", 2, true},
	{nil, "ping", 2, false},
}

func spanJSON(trace, id, parent int, kind int, name string, attrs map[string]string) string {
	var b strings.Builder
	fmt.Fprintf(&b, `{"traceId":"%032x","spanId":"%016x","parentSpanId":"%s","name":%q,"kind":%d,`+
		`"startTimeUnixNano":"1700000000000000000","endTimeUnixNano":"1700000000001000000","attributes":[`, trace, id,
		map[bool]string{true: fmt.Sprintf("%016x", parent), false: ""}[parent > 0], name, kind)
	keys := make([]string, 0, len(attrs))
	for k := range attrs {
		keys = append(keys, k)
	}
	sort.Strings(keys)
	for i, k := range keys {
		if i > 0 {
			b.WriteByte(',')
		}
		fmt.Fprintf(&b, `{"key":%q,"value":{"stringValue":%q}}`, k, attrs[k])
	}
	b.WriteString("]}")
	return b.String()
}

func resourceLine(spans ...string) string {
	return `{"resourceSpans":[{"resource":{"attributes":[{"key":"service.name","value":{"stringValue":"s"}}]},` +
		`"scopeSpans":[{"spans":[` + strings.Join(spans, ",") + `]}]}]}` + "\n"
}

// TestProbesDropped: the reader drops the same spans as the reference's health-probe rule, server spans only.
func TestProbesDropped(t *testing.T) {
	var body strings.Builder
	for i, c := range probeCases {
		body.WriteString(resourceLine(spanJSON(i+1, i+1, 0, c.kind, c.name, c.attrs)))
	}
	dir := t.TempDir()
	write(t, dir, "p.jsonl", body.String())
	d, err := ReadDir(dir)
	if err != nil {
		t.Fatal(err)
	}
	kept := map[uint64]bool{}
	for _, sp := range d.Spans {
		kept[sp.Trace[1]] = true
	}
	want := 0
	for i, c := range probeCases {
		if c.probe {
			want++
		}
		if dropped := !kept[uint64(i+1)]; dropped != c.probe {
			t.Errorf("case %d (%v %q kind %d): dropped %v, the reference %v", i, c.attrs, c.name, c.kind, dropped, c.probe)
		}
	}
	if d.Probes != want {
		t.Errorf("Probes = %d, want %d", d.Probes, want)
	}
}

// TestProbeChildrenAreRoots: a span under a dropped probe (zipkin-go's "health check" span under GET /health)
// is a root, not a span whose parent is missing; other spans keep their parents.
func TestProbeChildrenAreRoots(t *testing.T) {
	body := resourceLine(
		spanJSON(1, 1, 0, 2, "", map[string]string{"url.path": "/health"}),
		spanJSON(1, 2, 1, 1, "health check", nil),
		spanJSON(2, 3, 0, 2, "", map[string]string{"url.path": "/orders"}),
		spanJSON(2, 4, 3, 1, "work", nil))
	dir := t.TempDir()
	write(t, dir, "p.jsonl", body)
	d, err := ReadDir(dir)
	if err != nil {
		t.Fatal(err)
	}
	if d.Probes != 1 || d.ProbeChildren != 1 || len(d.Spans) != 3 {
		t.Fatalf("probes %d, probe children %d, spans %d; want 1, 1, 3", d.Probes, d.ProbeChildren, len(d.Spans))
	}
	for _, sp := range d.Spans {
		if sp.ID == 2 && sp.Parent != 0 {
			t.Errorf("the probe's child keeps parent %x", sp.Parent)
		}
		if sp.ID == 4 && sp.Parent != 3 {
			t.Errorf("an ordinary child lost its parent: %x", sp.Parent)
		}
	}
}
