// SPDX-License-Identifier: Apache-2.0

// Package auth establishes who is calling and what they may do (ARCHITECTURE.md 5.2).
//
//   - stdio: the local user, with every scope; there is no network listener.
//   - HTTP behind a front door (API Gateway's authorizer in Lambda mode): the claims the authorizer established, which
//     the event adapter puts in the request context with WithClaims.
//   - HTTP in container mode: a bearer token checked by the SDK's RequireBearerToken with one of this package's
//     verifiers (JWT with JWKS, or hashed static tokens for header-only clients).
//
// Scopes: rhobound:read for every read-only tool and resource, rhobound:fit for fit_start. A call to a tool that
// needs a scope the caller lacks is answered 403 insufficient_scope before it reaches the MCP handler.
package auth

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"os"
	"os/user"
	"slices"
	"strings"
	"time"

	sdkauth "github.com/modelcontextprotocol/go-sdk/auth"
)

// Scopes (ARCHITECTURE.md 5.2).
const (
	ScopeRead = "rhobound:read"
	ScopeFit  = "rhobound:fit"
)

// ToolScopes are the scopes a tool needs beyond ScopeRead.
var ToolScopes = map[string]string{"fit_start": ScopeFit}

// ResourceScopes are the scopes of a token that are this server's: a scope without a "/" as it is, and a scope of the
// resource server whose identifier is resourceServer ("<resourceServer>/rhobound:fit", as Cognito writes a resource
// server's scopes) without that prefix. A scope under any other prefix is another resource server's and is ignored, so
// "https://other.example/rhobound:fit" grants nothing here. With resourceServer "", every prefixed scope is ignored.
// The container mode's JWT verifier and the Lambda mode's authorizer claims apply the same rule.
func ResourceScopes(resourceServer string, scopes []string) []string {
	prefix := strings.TrimSuffix(resourceServer, "/") + "/"
	var out []string
	for _, s := range scopes {
		if resourceServer != "" {
			s = strings.TrimPrefix(s, prefix)
		}
		if s == "" || strings.Contains(s, "/") {
			continue
		}
		out = append(out, s)
	}
	return out
}

// Identity is the caller: a principal, which keys every handle and job, and the scopes it holds.
type Identity struct {
	Principal string
	Scopes    []string
}

// Has reports whether the identity holds scope.
func (id Identity) Has(scope string) bool { return slices.Contains(id.Scopes, scope) }

type identityKey struct{}

// WithIdentity returns ctx carrying id.
func WithIdentity(ctx context.Context, id Identity) context.Context {
	return context.WithValue(ctx, identityKey{}, id)
}

// FromContext returns the identity in ctx.
func FromContext(ctx context.Context) (Identity, bool) {
	id, ok := ctx.Value(identityKey{}).(Identity)
	return id, ok && id.Principal != ""
}

// Local is the stdio identity: the user running the server, with every scope.
func Local() Identity {
	name := ""
	if u, err := user.Current(); err == nil {
		name = u.Username
	}
	if name == "" {
		name = os.Getenv("USER")
	}
	if name == "" {
		name = fmt.Sprintf("uid%d", os.Getuid())
	}
	return Identity{Principal: "local:" + name, Scopes: []string{ScopeRead, ScopeFit}}
}

// Claims is what a front door established about a caller: a subject (a token's sub, an IAM principal, a static
// token's repository), the scopes granted, and which authorizer said so ("jwt", "iam" or "token").
type Claims struct {
	Subject string
	Scopes  []string
	Source  string
}

type claimsKey struct{}

// WithClaims returns ctx carrying the front door's claims. The API Gateway adapter calls it for each event.
func WithClaims(ctx context.Context, c Claims) context.Context {
	return context.WithValue(ctx, claimsKey{}, c)
}

// ClaimsFromContext returns the front door's claims in ctx.
func ClaimsFromContext(ctx context.Context) (Claims, bool) {
	c, ok := ctx.Value(claimsKey{}).(Claims)
	return c, ok
}

// FrontDoor is the middleware for Lambda mode: the authorizer has already checked the caller, and its claims are in
// the request context. A request without claims, or without rhobound:read, is refused.
func FrontDoor(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		c, ok := ClaimsFromContext(r.Context())
		if !ok || c.Subject == "" || c.Source == "" {
			http.Error(w, "no authorizer claims", http.StatusUnauthorized)
			return
		}
		id := Identity{Principal: c.Source + ":" + c.Subject, Scopes: slices.Clone(c.Scopes)}
		if !id.Has(ScopeRead) {
			insufficient(w, "", ScopeRead)
			return
		}
		requireToolScopes(next).ServeHTTP(w, r.WithContext(WithIdentity(r.Context(), id)))
	})
}

// BearerOptions configure Bearer.
type BearerOptions struct {
	ResourceMetadataURL string        // advertised in WWW-Authenticate
	ClockSkew           time.Duration // tolerance on a token's expiry
}

// Bearer is the middleware for container mode: the SDK's RequireBearerToken with verify, requiring rhobound:read,
// then the identity from the token (the principal is its user id, which names the verifier that accepted it: "jwt:"
// or "token:", as FrontDoor names the same caller in Lambda mode, so the two verifiers never share a principal), then
// the per-tool scopes.
func Bearer(verify sdkauth.TokenVerifier, opt BearerOptions) func(http.Handler) http.Handler {
	require := sdkauth.RequireBearerToken(verify, &sdkauth.RequireBearerTokenOptions{
		ResourceMetadataURL: opt.ResourceMetadataURL,
		Scopes:              []string{ScopeRead},
		ClockSkew:           opt.ClockSkew,
	})
	return func(next http.Handler) http.Handler {
		inner := requireToolScopes(next)
		return require(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
			ti := sdkauth.TokenInfoFromContext(r.Context())
			if ti == nil || ti.UserID == "" {
				http.Error(w, "token has no subject", http.StatusUnauthorized)
				return
			}
			id := Identity{Principal: ti.UserID, Scopes: slices.Clone(ti.Scopes)}
			inner.ServeHTTP(w, r.WithContext(WithIdentity(r.Context(), id)))
		}))
	}
}

// maxPeek bounds how much of a request body requireToolScopes reads; a larger body is passed on untouched, and the
// MCP handler's own cap (256 KiB) refuses it.
const maxPeek = 256 << 10

type toolsKey struct{}

// WithTools returns ctx carrying the tools the server registers, for the per-tool scopes: a tool's scope is checked
// only for a tool the server has, so a call of one its profile does not register (fit_start in the bench profile)
// reaches the MCP handler, which answers it as an unknown tool, rather than a step-up challenge for a scope that would
// run nothing. A request without it has every tool of ToolScopes checked.
func WithTools(ctx context.Context, has func(name string) bool) context.Context {
	return context.WithValue(ctx, toolsKey{}, has)
}

// requireToolScopes answers 403 insufficient_scope to a tools/call of a tool in ToolScopes when the identity lacks
// that tool's scope, for a tool the server has (WithTools). It reads the JSON-RPC body (one message, or a batch) and
// hands the same bytes on.
func requireToolScopes(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.Method != http.MethodPost || r.Body == nil {
			next.ServeHTTP(w, r)
			return
		}
		head, err := io.ReadAll(io.LimitReader(r.Body, maxPeek+1))
		if err != nil {
			http.Error(w, "cannot read request", http.StatusBadRequest)
			return
		}
		r.Body = struct {
			io.Reader
			io.Closer
		}{io.MultiReader(bytes.NewReader(head), r.Body), r.Body}
		if len(head) > maxPeek {
			next.ServeHTTP(w, r)
			return
		}
		id, _ := FromContext(r.Context())
		has, _ := r.Context().Value(toolsKey{}).(func(string) bool)
		for _, tool := range calledTools(head) {
			if need, ok := ToolScopes[tool]; ok && (has == nil || has(tool)) && !id.Has(need) {
				insufficient(w, "", need)
				return
			}
		}
		next.ServeHTTP(w, r)
	})
}

// calledTools returns the tool names of the tools/call requests in a JSON-RPC body. A body it cannot parse names
// none; the MCP handler then rejects it. It reads the body as the MCP SDK does: the first JSON value only, so that
// bytes after the message, which the SDK does not read, do not hide the message from this check; and the keys "method"
// and "name" exactly as written: encoding/json would match a struct's field to "Method" or "Name" too, so that a body
// with both spellings would name one tool here and run another.
func calledTools(body []byte) []string {
	var msgs []map[string]json.RawMessage
	trimmed := bytes.TrimSpace(body)
	dec := json.NewDecoder(bytes.NewReader(trimmed))
	if len(trimmed) > 0 && trimmed[0] == '[' {
		_ = dec.Decode(&msgs)
	} else {
		var m map[string]json.RawMessage
		if dec.Decode(&m) == nil {
			msgs = []map[string]json.RawMessage{m}
		}
	}
	var out []string
	for _, m := range msgs {
		var method string
		if json.Unmarshal(m["method"], &method) != nil || method != "tools/call" {
			continue
		}
		var params map[string]json.RawMessage
		var name string
		_ = json.Unmarshal(m["params"], &params)
		_ = json.Unmarshal(params["name"], &name)
		out = append(out, name)
	}
	return out
}

// insufficient answers 403 with the step-up challenge of RFC 6750 section 3.1.
func insufficient(w http.ResponseWriter, metadataURL, scope string) {
	params := []string{`error="insufficient_scope"`, fmt.Sprintf("scope=%q", scope)}
	if metadataURL != "" {
		params = append(params, fmt.Sprintf("resource_metadata=%q", metadataURL))
	}
	w.Header().Set("WWW-Authenticate", "Bearer "+strings.Join(params, ", "))
	http.Error(w, "insufficient scope", http.StatusForbidden)
}
