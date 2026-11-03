// maze-collect is the trace collector of a local run: OTLP/HTTP (protobuf) in on COLLECT_LISTEN (default
// 127.0.0.1:4318), one ExportTraceServiceRequest per line out, in the JSON of the OpenTelemetry file exporter (hex ids,
// enum numbers). What the Kubernetes Collector's k8sattributes processor adds, it adds from COLLECT_RESOURCES, by the
// k8s.pod.name each process reports ({"POD": {"k8s.deployment.name": "...", "container.image.repo_digests": ["..."]}}):
// string values as strings, lists as arrays. Nothing is written until POST /window?file=PATH opens a window; POST /window (no file) closes it.
package main

import (
	"encoding/hex"
	"encoding/json"
	"io"
	"log"
	"net/http"
	"os"
	"sync"

	collv1 "go.opentelemetry.io/proto/otlp/collector/trace/v1"
	commonv1 "go.opentelemetry.io/proto/otlp/common/v1"
	"google.golang.org/protobuf/encoding/protojson"
	"google.golang.org/protobuf/proto"
)

var ids = map[string]bool{"traceId": true, "spanId": true, "parentSpanId": true}

// hexIDs rewrites the base64 ids protojson writes as the hex the OTLP file format uses.
func hexIDs(v any) {
	switch t := v.(type) {
	case map[string]any:
		for k, x := range t {
			if s, ok := x.(string); ok && ids[k] {
				if b, err := decode64(s); err == nil {
					t[k] = hex.EncodeToString(b)
				}
				continue
			}
			hexIDs(x)
		}
	case []any:
		for _, x := range t {
			hexIDs(x)
		}
	}
}

func decode64(s string) ([]byte, error) {
	var b []byte
	err := json.Unmarshal([]byte(`"`+s+`"`), &b)
	return b, err
}

func attr(k string, v any) *commonv1.KeyValue {
	switch t := v.(type) {
	case []any:
		var vs []*commonv1.AnyValue
		for _, x := range t {
			s, _ := x.(string)
			vs = append(vs, &commonv1.AnyValue{Value: &commonv1.AnyValue_StringValue{StringValue: s}})
		}
		return &commonv1.KeyValue{Key: k, Value: &commonv1.AnyValue{Value: &commonv1.AnyValue_ArrayValue{
			ArrayValue: &commonv1.ArrayValue{Values: vs}}}}
	default:
		s, _ := v.(string)
		return &commonv1.KeyValue{Key: k, Value: &commonv1.AnyValue{Value: &commonv1.AnyValue_StringValue{StringValue: s}}}
	}
}

func main() {
	res := map[string]map[string]any{}
	if r := os.Getenv("COLLECT_RESOURCES"); r != "" {
		if err := json.Unmarshal([]byte(r), &res); err != nil {
			log.Fatalf("COLLECT_RESOURCES: %v", err)
		}
	}
	var mu sync.Mutex
	var out *os.File
	var spans int
	mo := protojson.MarshalOptions{UseEnumNumbers: true}
	http.HandleFunc("/v1/traces", func(w http.ResponseWriter, r *http.Request) {
		body, err := io.ReadAll(r.Body)
		if err != nil {
			http.Error(w, err.Error(), http.StatusBadRequest)
			return
		}
		var req collv1.ExportTraceServiceRequest
		if err := proto.Unmarshal(body, &req); err != nil {
			http.Error(w, err.Error(), http.StatusBadRequest)
			return
		}
		mu.Lock()
		defer mu.Unlock()
		w.Header().Set("Content-Type", "application/x-protobuf")
		b, _ := proto.Marshal(&collv1.ExportTraceServiceResponse{})
		if out == nil {
			w.Write(b)
			return
		}
		n := 0
		for _, rs := range req.ResourceSpans {
			pod := ""
			for _, kv := range rs.GetResource().GetAttributes() {
				if kv.Key == "k8s.pod.name" {
					pod = kv.GetValue().GetStringValue()
				}
			}
			for k, v := range res[pod] {
				rs.Resource.Attributes = append(rs.Resource.Attributes, attr(k, v))
			}
			for _, ss := range rs.ScopeSpans {
				n += len(ss.Spans)
			}
		}
		j, err := mo.Marshal(&req)
		if err == nil {
			var m any
			if err = json.Unmarshal(j, &m); err == nil {
				hexIDs(m)
				j, err = json.Marshal(m)
			}
		}
		if err != nil {
			http.Error(w, err.Error(), http.StatusInternalServerError)
			return
		}
		out.Write(append(j, '\n'))
		spans += n
		w.Write(b)
	})
	http.HandleFunc("/window", func(w http.ResponseWriter, r *http.Request) {
		mu.Lock()
		defer mu.Unlock()
		if out != nil {
			out.Close()
			log.Printf("window closed: %d spans", spans)
			out, spans = nil, 0
		}
		if f := r.URL.Query().Get("file"); f != "" {
			var err error
			if out, err = os.Create(f); err != nil {
				http.Error(w, err.Error(), http.StatusInternalServerError)
				return
			}
			log.Printf("window open: %s", f)
		}
		io.WriteString(w, "ok\n")
	})
	addr := os.Getenv("COLLECT_LISTEN")
	if addr == "" {
		addr = "127.0.0.1:4318"
	}
	log.Fatal(http.ListenAndServe(addr, nil))
}
