// SPDX-License-Identifier: Apache-2.0

package otlp

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// A SERVER span's route: http.route first (with the method), else a span name "METHOD /path", else an RPC span's
// name, else url.path (then http.target) without its query; none for a CLIENT span, a long route or personal data.
func TestServerRoute(t *testing.T) {
	span := func(kind int, name, attrs string) string {
		return `{"traceId":"0000000000000000000000000000000a","spanId":"00000000000000` + name[len(name)-2:] +
			`","name":"` + name + `","kind":` + string(rune('0'+kind)) + `,"startTimeUnixNano":"1800000000000000000",` +
			`"endTimeUnixNano":"1800000000001000000","attributes":[` + attrs + `]}`
	}
	kv := func(k, v string) string { return `{"key":"` + k + `","value":{"stringValue":"` + v + `"}}` }
	spans := []string{
		span(KindServer, "GET /items/{id} 01", kv("http.route", "/items/{id}")+","+kv("http.request.method", "GET")+","+kv("url.path", "/items/42")),
		span(KindServer, "GET /search 02", ""),
		span(KindServer, "grpc.Catalog/Get 03", kv("rpc.method", "Get")),
		span(KindServer, "handler 04", kv("http.request.method", "POST")+","+kv("url.path", "/buy?id=7")),
		span(KindServer, "handler 05", kv("url.path", "/u/a@example.com")),
		span(KindServer, "handler 06", kv("url.path", "/"+strings.Repeat("x", MaxRouteBytes))),
		span(KindClient, "GET /search 07", ""),
		span(KindServer, "GET /search 08", ""),
	}
	doc := `{"resourceSpans":[{"resource":{"attributes":[` + kv("service.name", "s") + `]},"scopeSpans":[{"spans":[` +
		strings.Join(spans, ",") + `]}]}]}`
	dir := t.TempDir()
	if err := os.MkdirAll(filepath.Join(dir, "traces"), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(dir, "traces", "a.jsonl"), []byte(doc+"\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	d, err := ReadDir(dir)
	if err != nil {
		t.Fatal(err)
	}
	want := []string{"GET /items/{id}", "GET /search 02", "grpc.Catalog/Get 03", "POST /buy", "", "", "", "GET /search 08"}
	if len(d.Spans) != len(want) {
		t.Fatalf("%d spans", len(d.Spans))
	}
	for i, sp := range d.Spans {
		if got := d.RouteName(&sp); got != want[i] {
			t.Errorf("span %d: route %q, want %q", i, got, want[i])
		}
	}
	if len(d.Routes) != 5 {
		t.Errorf("routes %q: each distinct route once", d.Routes)
	}
}
