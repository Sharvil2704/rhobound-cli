// SPDX-License-Identifier: Apache-2.0

// Package apigw runs an http.Handler on Amazon API Gateway events inside the Lambda process: an HTTP API event
// (payload format 2.0) or a REST API proxy event (payload format 1.0) becomes an *http.Request, the handler writes
// into an in-memory response, and the response becomes the event answer of the same format. No listener is
// opened, on loopback or anywhere else, so the request carries no local address and the MCP SDK's localhost
// Host-header protection never applies. The front door's authorizer result (JWT claims, a Lambda authorizer's
// context, an IAM caller) travels in the request's context for the server's principal extraction
// (RequestContextFrom).
package apigw

import (
	"bytes"
	"context"
	"encoding/base64"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"mime"
	"net/http"
	"net/url"
	"sort"
	"strings"
	"unicode/utf8"
)

// MaxResponseBytes is the largest event answer Lambda returns synchronously (6 MB, less room for the envelope).
const MaxResponseBytes = 6*1000*1000 - 16<<10

// RequestContext is what the front door said about a request.
type RequestContext struct {
	PayloadVersion string // "2.0" (HTTP API) or "1.0" (REST API proxy, or HTTP API with format 1.0)
	RequestID      string
	APIID          string
	Stage          string
	DomainName     string
	RouteKey       string // 2.0: "POST /mcp"; 1.0: the resource path
	SourceIP       string
	Authorizer     Authorizer
}

// Authorizer is the authorizer's result as API Gateway passes it on. Values are strings: API Gateway writes JWT
// claims as strings, and a Lambda authorizer's numbers and booleans are kept as their JSON text.
type Authorizer struct {
	// Claims are the JWT claims of an HTTP API JWT authorizer (2.0: authorizer.jwt.claims) or of a REST API
	// Cognito user pool authorizer (1.0: authorizer.claims).
	Claims map[string]string
	// NotStrings are the claims whose value was not a JSON string, sorted; Claims keeps their JSON text. The rule that
	// names a caller reads it (auth.JWTSubject): a sub or client_id that is not a string is refused.
	NotStrings []string
	// Scopes are the JWT authorizer's scopes (2.0: authorizer.jwt.scopes); with a 1.0 event, the "scope" claim
	// split on spaces.
	Scopes []string
	// Context is a Lambda authorizer's context (2.0: authorizer.lambda; 1.0: the authorizer's other keys).
	Context map[string]string
	// PrincipalID is a REST API Lambda authorizer's principalId.
	PrincipalID string
	// IAM is the SigV4 caller of a route authorized with AWS_IAM.
	IAM *IAMCaller
}

// IAMCaller identifies a SigV4 caller.
type IAMCaller struct {
	AccountID, CallerID, UserARN, UserID, PrincipalOrgID string
}

type ctxKey struct{}

// RequestContextFrom returns the front door's account of the request being served, if it came through Handler.
func RequestContextFrom(ctx context.Context) (*RequestContext, bool) {
	rc, ok := ctx.Value(ctxKey{}).(*RequestContext)
	return rc, ok
}

// Handler adapts h to a Lambda handler of API Gateway events. An event that is not an API Gateway proxy event
// is an error (the invocation fails); a request it cannot build (a body that is not valid base64) is answered
// 400.
func Handler(h http.Handler) func(ctx context.Context, event []byte) ([]byte, error) {
	return func(ctx context.Context, event []byte) ([]byte, error) {
		var probe struct {
			Version    string          `json:"version"`
			HTTPMethod string          `json:"httpMethod"`
			RC         json.RawMessage `json:"requestContext"`
		}
		if err := json.Unmarshal(event, &probe); err != nil {
			return nil, fmt.Errorf("apigw: the event is not JSON: %w", err)
		}
		switch {
		case probe.Version == "2.0":
			var e eventV2
			if err := json.Unmarshal(event, &e); err != nil {
				return nil, fmt.Errorf("apigw: bad payload 2.0 event: %w", err)
			}
			if e.RequestContext.HTTP.Method == "" {
				return nil, errors.New("apigw: payload 2.0 event without requestContext.http.method")
			}
			req, rc, err := e.request(ctx)
			if err != nil {
				return answerV2(badRequest(err))
			}
			return answerV2(serve(h, req, rc))
		case probe.HTTPMethod != "" && (probe.Version == "" || probe.Version == "1.0"):
			var e eventV1
			if err := json.Unmarshal(event, &e); err != nil {
				return nil, fmt.Errorf("apigw: bad payload 1.0 event: %w", err)
			}
			req, rc, err := e.request(ctx)
			if err != nil {
				return answerV1(badRequest(err))
			}
			return answerV1(serve(h, req, rc))
		}
		return nil, errors.New("apigw: not an API Gateway proxy event (payload format 1.0 or 2.0)")
	}
}

func serve(h http.Handler, req *http.Request, rc *RequestContext) *recorder {
	w := &recorder{header: http.Header{}}
	h.ServeHTTP(w, req.WithContext(context.WithValue(req.Context(), ctxKey{}, rc)))
	return w
}

func badRequest(err error) *recorder {
	w := &recorder{header: http.Header{}}
	w.header.Set("Content-Type", "text/plain; charset=utf-8")
	w.WriteHeader(http.StatusBadRequest)
	io.WriteString(w, "bad request: "+err.Error()+"\n")
	return w
}

// newRequest builds the request every payload format shares.
func newRequest(ctx context.Context, method, path, rawQuery string, body string, b64 bool) (*http.Request, error) {
	var data []byte
	if b64 {
		var err error
		if data, err = base64.StdEncoding.DecodeString(body); err != nil {
			return nil, errors.New("the body is marked base64 but is not")
		}
	} else {
		data = []byte(body)
	}
	if path == "" || path[0] != '/' {
		path = "/" + path
	}
	u := &url.URL{Path: path, RawQuery: rawQuery}
	if p, err := url.PathUnescape(path); err == nil && p != path {
		u.Path, u.RawPath = p, path
	}
	req, err := http.NewRequestWithContext(ctx, method, u.String(), bytes.NewReader(data))
	if err != nil {
		return nil, err
	}
	req.RequestURI = u.RequestURI()
	req.ContentLength = int64(len(data))
	if len(data) == 0 {
		req.Body = http.NoBody
	}
	return req, nil
}

// finish applies the host and the remote address once the headers are in. As in a request http.Server reads, the
// host is in req.Host and the URL holds only the path and query.
func finish(req *http.Request, domain, sourceIP string) {
	req.Host = req.Header.Get("Host")
	if req.Host == "" {
		req.Host = domain
	}
	if sourceIP != "" {
		req.RemoteAddr = sourceIP
	}
}

// recorder is the in-memory http.ResponseWriter. Flush is a no-op, so a handler that streams still works; its
// whole output is answered at once.
type recorder struct {
	header      http.Header
	status      int
	body        bytes.Buffer
	wroteHeader bool
}

func (w *recorder) Header() http.Header { return w.header }

func (w *recorder) WriteHeader(code int) {
	if w.wroteHeader {
		return
	}
	w.wroteHeader, w.status = true, code
}

func (w *recorder) Write(b []byte) (int, error) {
	w.WriteHeader(http.StatusOK)
	return w.body.Write(b)
}

func (w *recorder) Flush() { w.WriteHeader(http.StatusOK) }

func (w *recorder) statusCode() int {
	if !w.wroteHeader {
		return http.StatusOK
	}
	return w.status
}

// encodeBody returns the body as the event answer carries it: text as is, anything else in base64.
func (w *recorder) encodeBody() (string, bool) {
	b := w.body.Bytes()
	if len(b) == 0 {
		return "", false
	}
	if isText(w.header.Get("Content-Type")) && utf8.Valid(b) {
		return string(b), false
	}
	return base64.StdEncoding.EncodeToString(b), true
}

func isText(ct string) bool {
	mt, _, err := mime.ParseMediaType(ct)
	if err != nil {
		return false
	}
	switch {
	case strings.HasPrefix(mt, "text/"), mt == "application/json", strings.HasSuffix(mt, "+json"),
		mt == "application/xml", strings.HasSuffix(mt, "+xml"), mt == "application/javascript",
		mt == "application/x-www-form-urlencoded":
		return true
	}
	return false
}

// tooLarge replaces an answer that Lambda could not return.
func tooLarge() *recorder {
	w := &recorder{header: http.Header{}}
	w.header.Set("Content-Type", "text/plain; charset=utf-8")
	w.WriteHeader(http.StatusBadGateway)
	io.WriteString(w, "response too large for a Lambda answer\n")
	return w
}

// notStrings lists the keys of raw whose value is present (not null) and is not a JSON string, sorted.
func notStrings(raw map[string]json.RawMessage) []string {
	var out []string
	for k, v := range raw {
		var s string
		if t := strings.TrimSpace(string(v)); t != "null" && t != "" && json.Unmarshal(v, &s) != nil {
			out = append(out, k)
		}
	}
	sort.Strings(out)
	return out
}

// strings of a JSON object whose values may be strings, numbers, booleans or null
func stringMap(raw map[string]json.RawMessage) map[string]string {
	if len(raw) == 0 {
		return nil
	}
	out := map[string]string{}
	for k, v := range raw {
		t := strings.TrimSpace(string(v))
		var s string
		switch {
		case t == "null" || t == "":
		case json.Unmarshal(v, &s) == nil:
			out[k] = s
		default:
			out[k] = t
		}
	}
	if len(out) == 0 {
		return nil
	}
	return out
}
