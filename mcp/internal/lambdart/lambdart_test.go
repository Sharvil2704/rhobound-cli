// SPDX-License-Identifier: Apache-2.0

package lambdart

import (
	"context"
	"encoding/json"
	"errors"
	"io"
	"net/http"
	"net/http/httptest"
	"strconv"
	"strings"
	"sync"
	"testing"
	"time"
)

// fakeRuntime is the Lambda Runtime API: it hands out queued invocations and records what the runtime posts.
// Once the queue is empty, /next blocks until the runtime gives up the request.
type fakeRuntime struct {
	srv *httptest.Server

	mu         sync.Mutex
	queue      []fakeInvocation
	responses  map[string]string
	errs       map[string]posted
	initErrs   []posted
	nextStatus int // answer /next with this status when set
	respStatus int // answer /response with this status when set
	posts      chan string
}

type fakeInvocation struct {
	id       string
	deadline time.Time
	event    string
}

type posted struct {
	header string // Lambda-Runtime-Function-Error-Type
	body   struct {
		Message    string   `json:"errorMessage"`
		Type       string   `json:"errorType"`
		StackTrace []string `json:"stackTrace"`
	}
}

func newFakeRuntime(t *testing.T, invs ...fakeInvocation) *fakeRuntime {
	f := &fakeRuntime{queue: invs, responses: map[string]string{}, errs: map[string]posted{}, posts: make(chan string, 16)}
	mux := http.NewServeMux()
	mux.HandleFunc("GET /2018-06-01/runtime/invocation/next", func(w http.ResponseWriter, r *http.Request) {
		f.mu.Lock()
		if f.nextStatus != 0 {
			f.mu.Unlock()
			w.WriteHeader(f.nextStatus)
			return
		}
		if len(f.queue) == 0 {
			f.mu.Unlock()
			<-r.Context().Done()
			return
		}
		inv := f.queue[0]
		f.queue = f.queue[1:]
		f.mu.Unlock()
		w.Header().Set("Lambda-Runtime-Aws-Request-Id", inv.id)
		w.Header().Set("Lambda-Runtime-Invoked-Function-Arn", "arn:aws:lambda:us-east-1:ACCOUNT:function:rhobound-mcp")
		w.Header().Set("Lambda-Runtime-Trace-Id", "Root=1-5759e988-bd862e3fe1be46a994272793;Sampled=1")
		if !inv.deadline.IsZero() {
			w.Header().Set("Lambda-Runtime-Deadline-Ms", strconv.FormatInt(inv.deadline.UnixMilli(), 10))
		}
		io.WriteString(w, inv.event)
	})
	mux.HandleFunc("POST /2018-06-01/runtime/invocation/{id}/response", func(w http.ResponseWriter, r *http.Request) {
		b, _ := io.ReadAll(r.Body)
		f.mu.Lock()
		status := f.respStatus
		if status == 0 {
			f.responses[r.PathValue("id")] = string(b)
		}
		f.mu.Unlock()
		if status != 0 {
			w.WriteHeader(status)
			return
		}
		w.WriteHeader(http.StatusAccepted)
		f.posts <- "response " + r.PathValue("id")
	})
	mux.HandleFunc("POST /2018-06-01/runtime/invocation/{id}/error", func(w http.ResponseWriter, r *http.Request) {
		p := readPosted(t, r)
		f.mu.Lock()
		f.errs[r.PathValue("id")] = p
		f.mu.Unlock()
		w.WriteHeader(http.StatusAccepted)
		f.posts <- "error " + r.PathValue("id")
	})
	mux.HandleFunc("POST /2018-06-01/runtime/init/error", func(w http.ResponseWriter, r *http.Request) {
		p := readPosted(t, r)
		f.mu.Lock()
		f.initErrs = append(f.initErrs, p)
		f.mu.Unlock()
		w.WriteHeader(http.StatusAccepted)
	})
	f.srv = httptest.NewServer(mux)
	t.Cleanup(f.srv.Close)
	return f
}

func readPosted(t *testing.T, r *http.Request) posted {
	var p posted
	p.header = r.Header.Get("Lambda-Runtime-Function-Error-Type")
	if err := json.NewDecoder(r.Body).Decode(&p.body); err != nil {
		t.Errorf("error post is not JSON: %v", err)
	}
	return p
}

func (f *fakeRuntime) api() string { return strings.TrimPrefix(f.srv.URL, "http://") }

// serve runs the loop until n outcomes were posted, then stops it.
func (f *fakeRuntime) serve(t *testing.T, n int, h Handler) {
	t.Helper()
	ctx, cancel := context.WithCancel(context.Background())
	done := make(chan error, 1)
	go func() { done <- Serve(ctx, f.api(), h) }()
	for range n {
		select {
		case <-f.posts:
		case err := <-done:
			t.Fatalf("the loop stopped early: %v", err)
		case <-time.After(10 * time.Second):
			t.Fatal("no outcome posted")
		}
	}
	cancel()
	if err := <-done; !errors.Is(err, context.Canceled) {
		t.Fatalf("Serve returned %v, want the cancellation", err)
	}
}

func TestResponseCarriesTheInvocationAndItsDeadline(t *testing.T) {
	deadline := time.Now().Add(30 * time.Second).Truncate(time.Millisecond)
	f := newFakeRuntime(t, fakeInvocation{"req-1", deadline, `{"ping":1}`})
	var got Invocation
	var dl time.Time
	f.serve(t, 1, func(ctx context.Context, event []byte) ([]byte, error) {
		inv, _ := InvocationFrom(ctx)
		got = *inv
		dl, _ = ctx.Deadline()
		return []byte(`pong ` + string(event)), nil
	})
	if f.responses["req-1"] != `pong {"ping":1}` {
		t.Fatalf("responses %v", f.responses)
	}
	if got.RequestID != "req-1" || !strings.HasSuffix(got.FunctionARN, ":function:rhobound-mcp") ||
		!strings.HasPrefix(got.TraceID, "Root=") || !got.Deadline.Equal(deadline) || !dl.Equal(deadline) {
		t.Fatalf("invocation %+v, context deadline %v, want %v", got, dl, deadline)
	}
}

type customErr struct{}

func (customErr) Error() string     { return "refused by the handler" }
func (customErr) ErrorType() string { return "Handler.Refused" }

func TestErrorsAndPanicsArePostedAndTheLoopGoesOn(t *testing.T) {
	f := newFakeRuntime(t,
		fakeInvocation{id: "a", event: "plain"},
		fakeInvocation{id: "b", event: "typed"},
		fakeInvocation{id: "c", event: "panic"},
		fakeInvocation{id: "d", event: "fine"})
	f.serve(t, 4, func(ctx context.Context, event []byte) ([]byte, error) {
		switch string(event) {
		case "plain":
			return nil, errors.New("it broke")
		case "typed":
			return nil, customErr{}
		case "panic":
			panic("boom")
		}
		return []byte("ok"), nil
	})
	for id, want := range map[string]string{"a": "Runtime.HandlerError", "b": "Handler.Refused", "c": "Runtime.HandlerPanic"} {
		p := f.errs[id]
		if p.header != want || p.body.Type != want || p.body.Message == "" || p.body.StackTrace == nil {
			t.Errorf("%s: posted %+v, want type %s", id, p, want)
		}
	}
	if f.errs["c"].body.Message != "handler panic: boom" || f.responses["d"] != "ok" {
		t.Fatalf("panic %+v, response %q", f.errs["c"].body, f.responses["d"])
	}
}

func TestAnOversizeAnswerBecomesAnError(t *testing.T) {
	f := newFakeRuntime(t, fakeInvocation{id: "big", event: "{}"})
	f.respStatus = http.StatusRequestEntityTooLarge
	f.serve(t, 1, func(ctx context.Context, event []byte) ([]byte, error) { return []byte("too much"), nil })
	if p := f.errs["big"]; p.body.Type != "Function.ResponseSizeTooLarge" {
		t.Fatalf("posted %+v", p)
	}
}

func TestARuntimeAPIFailureEndsTheLoop(t *testing.T) {
	f := newFakeRuntime(t, fakeInvocation{id: "x", event: "{}"})
	f.respStatus = http.StatusInternalServerError
	err := Serve(context.Background(), f.api(), func(ctx context.Context, event []byte) ([]byte, error) { return nil, nil })
	if err == nil || !strings.Contains(err.Error(), "500") {
		t.Fatalf("Serve returned %v, want the API failure", err)
	}
	f2 := newFakeRuntime(t)
	f2.nextStatus = http.StatusInternalServerError
	if err := Start(f2.api(), nil); err == nil {
		t.Fatal("a failing /next did not end the loop")
	}
	if err := Start("", nil); err == nil {
		t.Fatal("no Runtime API address accepted")
	}
}

func TestInitError(t *testing.T) {
	f := newFakeRuntime(t)
	if err := InitError(f.api(), errors.New("the engine's sha256 differs from the configuration")); err != nil {
		t.Fatal(err)
	}
	if err := InitError(f.api(), customErr{}); err != nil {
		t.Fatal(err)
	}
	if len(f.initErrs) != 2 || f.initErrs[0].header != "Runtime.InitError" || f.initErrs[1].body.Type != "Handler.Refused" ||
		!strings.Contains(f.initErrs[0].body.Message, "sha256") {
		t.Fatalf("init errors %+v", f.initErrs)
	}
}
