// SPDX-License-Identifier: Apache-2.0

// Package lambdart is the AWS Lambda Runtime API loop for a custom runtime (provided.al2023): fetch the next
// invocation, run the handler with the invocation's deadline, post the answer or the error, and repeat. It uses
// only net/http; the Runtime API is plain HTTP on the address Lambda gives in AWS_LAMBDA_RUNTIME_API
// (https://docs.aws.amazon.com/lambda/latest/dg/runtimes-api.html).
package lambdart

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"strconv"
	"time"
)

// Handler handles one invocation's event and returns its answer.
type Handler func(ctx context.Context, event []byte) ([]byte, error)

// Invocation is the runtime's account of the invocation being served.
type Invocation struct {
	RequestID   string
	FunctionARN string
	TraceID     string
	Deadline    time.Time
}

type ctxKey struct{}

// InvocationFrom returns the invocation a handler's context belongs to.
func InvocationFrom(ctx context.Context) (*Invocation, bool) {
	inv, ok := ctx.Value(ctxKey{}).(*Invocation)
	return inv, ok
}

// Invoker starts a function asynchronously with event as its payload: the MCP function starting the fit worker
// for fit_start. The binding to the Lambda Invoke API needs AWS credentials and the AWS SDK, and is not part of
// this package; tests use a fake.
type Invoker interface {
	InvokeAsync(ctx context.Context, function string, event []byte) error
}

// An error with an ErrorType method reports that type to Lambda; any other error is "Runtime.HandlerError", and a
// panic "Runtime.HandlerPanic".
type typed interface{ ErrorType() string }

const (
	apiVersion = "/2018-06-01/runtime"
	// maxErrorMessage bounds the error message posted to Lambda (it ends in the function's log).
	maxErrorMessage = 4 << 10
)

// Start serves invocations from the Runtime API at runtimeAPI (host:port) until the API fails. It returns only
// with an error, after which the process should exit and Lambda starts a new one.
func Start(runtimeAPI string, h func(ctx context.Context, event []byte) ([]byte, error)) error {
	return Serve(context.Background(), runtimeAPI, h)
}

// Serve is Start, stopping also when ctx ends.
func Serve(ctx context.Context, runtimeAPI string, h func(ctx context.Context, event []byte) ([]byte, error)) error {
	if runtimeAPI == "" {
		return errors.New("lambdart: no Runtime API address (AWS_LAMBDA_RUNTIME_API is set only inside Lambda)")
	}
	c := newClient(runtimeAPI)
	for {
		inv, event, err := c.next(ctx)
		if err != nil {
			return err
		}
		if err := c.invoke(ctx, inv, event, h); err != nil {
			return err
		}
	}
}

// InitError reports that the function could not initialize (its configuration or engine binary is wrong).
// Lambda then fails the invocation that started this environment and starts a fresh one for the next.
func InitError(runtimeAPI string, err error) error {
	if runtimeAPI == "" {
		return errors.New("lambdart: no Runtime API address")
	}
	c := newClient(runtimeAPI)
	return c.postError(context.Background(), c.base+"/init/error", errorType(err, "Runtime.InitError"), err.Error())
}

type client struct {
	base string
	http *http.Client
}

func newClient(api string) *client {
	tr := http.DefaultTransport.(*http.Transport).Clone()
	tr.Proxy = nil // the Runtime API is local to the execution environment
	// no client timeout: /next is a long poll that returns when an invocation arrives
	return &client{base: "http://" + api + apiVersion, http: &http.Client{Transport: tr}}
}

func (c *client) next(ctx context.Context) (*Invocation, []byte, error) {
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, c.base+"/invocation/next", nil)
	if err != nil {
		return nil, nil, err
	}
	resp, err := c.http.Do(req)
	if err != nil {
		return nil, nil, fmt.Errorf("lambdart: next invocation: %w", err)
	}
	defer resp.Body.Close()
	event, err := io.ReadAll(resp.Body)
	if err != nil {
		return nil, nil, fmt.Errorf("lambdart: next invocation: %w", err)
	}
	if resp.StatusCode != http.StatusOK {
		return nil, nil, fmt.Errorf("lambdart: next invocation: status %d", resp.StatusCode)
	}
	inv := &Invocation{
		RequestID:   resp.Header.Get("Lambda-Runtime-Aws-Request-Id"),
		FunctionARN: resp.Header.Get("Lambda-Runtime-Invoked-Function-Arn"),
		TraceID:     resp.Header.Get("Lambda-Runtime-Trace-Id"),
	}
	if inv.RequestID == "" {
		return nil, nil, errors.New("lambdart: next invocation without a request id")
	}
	if ms, err := strconv.ParseInt(resp.Header.Get("Lambda-Runtime-Deadline-Ms"), 10, 64); err == nil {
		inv.Deadline = time.UnixMilli(ms)
	}
	return inv, event, nil
}

// invoke runs one invocation and posts its outcome. Only a failure of the Runtime API itself is returned.
func (c *client) invoke(ctx context.Context, inv *Invocation, event []byte, h Handler) error {
	hctx := context.WithValue(ctx, ctxKey{}, inv)
	if !inv.Deadline.IsZero() {
		var cancel context.CancelFunc
		hctx, cancel = context.WithDeadline(hctx, inv.Deadline)
		defer cancel()
	}
	out, err := call(hctx, h, event)
	at := c.base + "/invocation/" + url.PathEscape(inv.RequestID)
	if err != nil {
		return c.postError(ctx, at+"/error", errorType(err, "Runtime.HandlerError"), err.Error())
	}
	status, err := c.post(ctx, at+"/response", nil, out)
	if err != nil {
		return err
	}
	if status == http.StatusRequestEntityTooLarge {
		return c.postError(ctx, at+"/error", "Function.ResponseSizeTooLarge",
			fmt.Sprintf("the answer of %d bytes is over Lambda's limit", len(out)))
	}
	return nil
}

type panicError struct{ v any }

func (p panicError) Error() string     { return fmt.Sprintf("handler panic: %v", p.v) }
func (p panicError) ErrorType() string { return "Runtime.HandlerPanic" }

func call(ctx context.Context, h Handler, event []byte) (out []byte, err error) {
	defer func() {
		if v := recover(); v != nil {
			out, err = nil, panicError{v}
		}
	}()
	return h(ctx, event)
}

func errorType(err error, fallback string) string {
	var t typed
	if errors.As(err, &t) && t.ErrorType() != "" {
		return t.ErrorType()
	}
	return fallback
}

func (c *client) postError(ctx context.Context, at, typ, msg string) error {
	if len(msg) > maxErrorMessage {
		msg = msg[:maxErrorMessage]
	}
	body, _ := json.Marshal(struct {
		Message    string   `json:"errorMessage"`
		Type       string   `json:"errorType"`
		StackTrace []string `json:"stackTrace"`
	}{msg, typ, []string{}})
	_, err := c.post(ctx, at, http.Header{"Lambda-Runtime-Function-Error-Type": {typ}}, body)
	return err
}

// post sends one outcome. A 5xx answer means the Runtime API failed and the process must exit; a 4xx answer
// (the invocation already timed out, say) is the caller's to judge.
func (c *client) post(ctx context.Context, at string, hdr http.Header, body []byte) (int, error) {
	req, err := http.NewRequestWithContext(ctx, http.MethodPost, at, bytes.NewReader(body))
	if err != nil {
		return 0, err
	}
	for k, vs := range hdr {
		req.Header[k] = vs
	}
	req.Header.Set("Content-Type", "application/json")
	resp, err := c.http.Do(req)
	if err != nil {
		return 0, fmt.Errorf("lambdart: post: %w", err)
	}
	io.Copy(io.Discard, resp.Body)
	resp.Body.Close()
	if resp.StatusCode >= 500 {
		return resp.StatusCode, fmt.Errorf("lambdart: the Runtime API answered %d", resp.StatusCode)
	}
	return resp.StatusCode, nil
}
