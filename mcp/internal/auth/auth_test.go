// SPDX-License-Identifier: Apache-2.0

package auth

import (
	"context"
	"crypto"
	"crypto/hmac"
	"crypto/rand"
	"crypto/rsa"
	"crypto/sha256"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"math/big"
	"net/http"
	"net/http/httptest"
	"strings"
	"sync"
	"sync/atomic"
	"testing"
	"time"

	sdkauth "github.com/modelcontextprotocol/go-sdk/auth"
)

var (
	keyOnce sync.Once
	testKey *rsa.PrivateKey
)

func key(t *testing.T) *rsa.PrivateKey {
	keyOnce.Do(func() {
		k, err := rsa.GenerateKey(rand.Reader, 2048)
		if err != nil {
			panic(err)
		}
		testKey = k
	})
	return testKey
}

func b64(b []byte) string { return base64.RawURLEncoding.EncodeToString(b) }

func part(v any) string {
	b, _ := json.Marshal(v)
	return b64(b)
}

// sign makes an RS256 token with header hdr and claims.
func sign(t *testing.T, hdr, claims map[string]any) string {
	t.Helper()
	in := part(hdr) + "." + part(claims)
	d := sha256.Sum256([]byte(in))
	sig, err := rsa.SignPKCS1v15(rand.Reader, key(t), crypto.SHA256, d[:])
	if err != nil {
		t.Fatal(err)
	}
	return in + "." + b64(sig)
}

var now = time.Date(2026, 10, 26, 12, 0, 0, 0, time.UTC)

func claims(mod func(map[string]any)) map[string]any {
	c := map[string]any{"iss": "https://issuer.example", "sub": "user-1", "aud": "https://mcp.example.com/mcp",
		"exp": now.Add(time.Hour).Unix(), "scope": "rhobound:read rhobound:fit"}
	if mod != nil {
		mod(c)
	}
	return c
}

func jwks(t *testing.T, kid string) []byte {
	pub := key(t).PublicKey
	b, _ := json.Marshal(map[string]any{"keys": []map[string]any{
		{"kty": "RSA", "kid": kid, "use": "sig", "alg": "RS256", "n": b64(pub.N.Bytes()), "e": b64(big.NewInt(int64(pub.E)).Bytes())},
		{"kty": "EC", "kid": "ec", "crv": "P-256"},
	}})
	return b
}

func verifier(t *testing.T, mod func(*JWTConfig)) sdkauth.TokenVerifier {
	keys, err := ParseJWKS(jwks(t, "k1"))
	if err != nil {
		t.Fatal(err)
	}
	cfg := JWTConfig{Issuer: "https://issuer.example", Audience: "https://mcp.example.com/mcp", Keys: StaticKeys(keys),
		Now: func() time.Time { return now }}
	if mod != nil {
		mod(&cfg)
	}
	v, err := JWT(cfg)
	if err != nil {
		t.Fatal(err)
	}
	return v
}

// Scopes of a resource server count only under this server's identifier, in the container's verifier as in the Lambda
// mode's claims (cmd/rhobound-mcp claimsOf): https://other.example/rhobound:fit grants nothing.
func TestJWTResourceServerScopes(t *testing.T) {
	hdr := map[string]any{"alg": "RS256", "kid": "k1", "typ": "JWT"}
	tok := sign(t, hdr, claims(func(c map[string]any) {
		c["scope"] = "https://mcp.example.com/rhobound:read https://other.example/rhobound:fit " +
			"https://mcp.example.com/x/rhobound:fit openid"
	}))
	for _, c := range []struct {
		resource string
		want     []string
	}{
		{"https://mcp.example.com", []string{ScopeRead, "openid"}},
		{"https://mcp.example.com/", []string{ScopeRead, "openid"}},
		{"https://other.example", []string{ScopeFit, "openid"}},
		{"", []string{"openid"}},
	} {
		ti, err := verifier(t, func(cfg *JWTConfig) { cfg.ResourceServer = c.resource })(context.Background(), tok, nil)
		if err != nil || strings.Join(ti.Scopes, " ") != strings.Join(c.want, " ") {
			t.Errorf("resource server %q: %+v %v, want %v", c.resource, ti, err, c.want)
		}
	}
	if got := ResourceScopes("https://mcp.example.com", []string{"https://other.example/rhobound:fit", "rhobound:fit", "/", ""}); strings.Join(got, " ") != ScopeFit {
		t.Errorf("ResourceScopes: %v", got)
	}
}

func TestJWTAccepts(t *testing.T) {
	hdr := map[string]any{"alg": "RS256", "kid": "k1", "typ": "JWT"}
	v := verifier(t, nil)
	ti, err := v(context.Background(), sign(t, hdr, claims(nil)), nil)
	if err != nil {
		t.Fatal(err)
	}
	if ti.UserID != "jwt:sub:user-1" || len(ti.Scopes) != 2 || !ti.Expiration.Equal(now.Add(time.Hour)) {
		t.Errorf("%+v", ti)
	}
	// aud as a list, scopes as scp.
	ti, err = v(context.Background(), sign(t, hdr, claims(func(c map[string]any) {
		c["aud"] = []string{"other", "https://mcp.example.com/mcp"}
		delete(c, "scope")
		c["scp"] = []string{"rhobound:read"}
	})), nil)
	if err != nil || len(ti.Scopes) != 1 || ti.Scopes[0] != ScopeRead {
		t.Errorf("list aud, scp: %+v %v", ti, err)
	}
	// A Cognito access token: no aud, an allow-listed client_id, token_use access, no sub (client credentials).
	cv := verifier(t, func(c *JWTConfig) { c.Audience = ""; c.ClientIDs = []string{"app1"}; c.TokenUse = "access" })
	ti, err = cv(context.Background(), sign(t, hdr, claims(func(c map[string]any) {
		delete(c, "aud")
		delete(c, "sub")
		c["client_id"] = "app1"
		c["token_use"] = "access"
	})), nil)
	if err != nil || ti.UserID != "jwt:client:app1" {
		t.Errorf("cognito access token: %+v %v", ti, err)
	}
	// a user whose sub reads as a client's subject is not that client
	ti, err = cv(context.Background(), sign(t, hdr, claims(func(c map[string]any) {
		delete(c, "aud")
		c["sub"] = "client:app1"
		c["client_id"] = "app1"
		c["token_use"] = "access"
	})), nil)
	if err != nil || ti.UserID != "jwt:sub:client:app1" {
		t.Errorf("sub client:app1: %+v %v", ti, err)
	}
}

func TestJWTRefuses(t *testing.T) {
	hdr := map[string]any{"alg": "RS256", "kid": "k1"}
	v := verifier(t, nil)
	cognito := verifier(t, func(c *JWTConfig) { c.Audience = ""; c.ClientIDs = []string{"app1"}; c.TokenUse = "access" })
	good := sign(t, hdr, claims(nil))
	pieces := strings.Split(good, ".")
	tampered := pieces[0] + "." + part(claims(func(c map[string]any) { c["sub"] = "admin" })) + "." + pieces[2]

	// alg confusion: HS256 keyed with the public key's bytes.
	hsIn := part(map[string]any{"alg": "HS256", "kid": "k1"}) + "." + part(claims(nil))
	mac := hmac.New(sha256.New, key(t).PublicKey.N.Bytes())
	mac.Write([]byte(hsIn))
	hs := hsIn + "." + b64(mac.Sum(nil))

	cases := map[string]struct {
		v     sdkauth.TokenVerifier
		token string
	}{
		"not three parts":   {v, "abc.def"},
		"alg none":          {v, part(map[string]any{"alg": "none", "kid": "k1"}) + "." + part(claims(nil)) + "."},
		"alg HS256":         {v, hs},
		"no kid":            {v, sign(t, map[string]any{"alg": "RS256"}, claims(nil))},
		"unknown kid":       {v, sign(t, map[string]any{"alg": "RS256", "kid": "k2"}, claims(nil))},
		"crit header":       {v, sign(t, map[string]any{"alg": "RS256", "kid": "k1", "crit": []string{"x"}}, claims(nil))},
		"tampered payload":  {v, tampered},
		"wrong issuer":      {v, sign(t, hdr, claims(func(c map[string]any) { c["iss"] = "https://evil.example" }))},
		"wrong audience":    {v, sign(t, hdr, claims(func(c map[string]any) { c["aud"] = "https://other.example" }))},
		"no aud, no client": {v, sign(t, hdr, claims(func(c map[string]any) { delete(c, "aud") }))},
		"expired":           {v, sign(t, hdr, claims(func(c map[string]any) { c["exp"] = now.Add(-time.Second).Unix() }))},
		"no exp":            {v, sign(t, hdr, claims(func(c map[string]any) { delete(c, "exp") }))},
		"not yet valid":     {v, sign(t, hdr, claims(func(c map[string]any) { c["nbf"] = now.Add(time.Hour).Unix() }))},
		"no subject":        {v, sign(t, hdr, claims(func(c map[string]any) { delete(c, "sub") }))},
		// the Lambda mode's claims refuse the same (cmd/rhobound-mcp TestFrontDoorClaimsFromEachAuthorizer)
		"sub a number":      {v, sign(t, hdr, claims(func(c map[string]any) { c["sub"] = 123 }))},
		"sub blank":         {v, sign(t, hdr, claims(func(c map[string]any) { c["sub"] = "  " }))},
		"client_id blank":   {v, sign(t, hdr, claims(func(c map[string]any) { delete(c, "sub"); c["client_id"] = " " }))},
		"client_id number":  {v, sign(t, hdr, claims(func(c map[string]any) { delete(c, "sub"); c["client_id"] = 7 }))},
		"aud number":        {v, sign(t, hdr, claims(func(c map[string]any) { c["aud"] = 7 }))},
		"client not listed": {cognito, sign(t, hdr, claims(func(c map[string]any) { delete(c, "aud"); c["client_id"] = "app2"; c["token_use"] = "access" }))},
		"id token":          {cognito, sign(t, hdr, claims(func(c map[string]any) { delete(c, "aud"); c["client_id"] = "app1"; c["token_use"] = "id" }))},
	}
	for name, c := range cases {
		if ti, err := c.v(context.Background(), c.token, nil); !errors.Is(err, sdkauth.ErrInvalidToken) {
			t.Errorf("%s: %+v, %v", name, ti, err)
		}
	}
	if _, err := JWT(JWTConfig{Issuer: "x", Keys: StaticKeys{}}); err == nil {
		t.Error("a verifier with neither audience nor client ids")
	}
}

// TestJWKSRefresh: an unknown key id makes one fetch; a second unknown id within MinRefresh makes none, also when the
// key set is down.
func TestJWKSRefresh(t *testing.T) {
	var fetches atomic.Int32
	kid := "k1"
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		fetches.Add(1)
		w.Write(jwks(t, kid))
	}))
	defer srv.Close()
	ks := &JWKS{URL: srv.URL, HTTP: srv.Client(), MinRefresh: time.Hour}
	ctx := context.Background()
	if _, err := ks.Key(ctx, "k1"); err != nil {
		t.Fatal(err)
	}
	if _, err := ks.Key(ctx, "k1"); err != nil || fetches.Load() != 1 {
		t.Errorf("cached key: %v, %d fetches", err, fetches.Load())
	}
	if _, err := ks.Key(ctx, "k9"); !errors.Is(err, ErrUnknownKey) || fetches.Load() != 1 {
		t.Errorf("unknown kid within MinRefresh: %v, %d fetches", err, fetches.Load())
	}
	ks.MinRefresh = time.Nanosecond
	kid = "k9"
	if _, err := ks.Key(ctx, "k9"); err != nil || fetches.Load() != 2 {
		t.Errorf("rotated key: %v, %d fetches", err, fetches.Load())
	}
	// a key set that is down: tokens with made-up key ids cause one fetch per MinRefresh, not one each
	var failed atomic.Int32
	down := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		failed.Add(1)
		http.Error(w, "unavailable", http.StatusInternalServerError)
	}))
	defer down.Close()
	ds := &JWKS{URL: down.URL, HTTP: down.Client(), MinRefresh: time.Hour}
	for i := 0; i < 50; i++ {
		if _, err := ds.Key(ctx, fmt.Sprintf("made-up-%d", i)); err == nil {
			t.Fatal("a key from a key set that is down")
		}
	}
	if n := failed.Load(); n != 1 {
		t.Errorf("a key set that is down was fetched %d times for 50 unknown key ids", n)
	}
	small, _ := rsa.GenerateKey(rand.Reader, 1024)
	weak, _ := json.Marshal(map[string]any{"keys": []map[string]any{{"kty": "RSA", "kid": "w", "n": b64(small.N.Bytes()), "e": "AQAB"}}})
	if keys, _ := ParseJWKS(weak); len(keys) != 0 {
		t.Error("a 1024-bit key accepted")
	}
}

func TestStaticTokens(t *testing.T) {
	tok, sum, err := NewStaticToken()
	if err != nil {
		t.Fatal(err)
	}
	if len(tok) < 43 {
		t.Errorf("token %q is short", tok)
	}
	clock := now
	v, err := StaticTokens([]StaticToken{{SHA256: strings.Repeat("ab", 32), Repo: "a", Expires: now.Add(time.Hour)},
		{SHA256: sum, Repo: "shop", Expires: now.Add(time.Hour)}}, func() time.Time { return clock })
	if err != nil {
		t.Fatal(err)
	}
	ti, err := v(context.Background(), tok, nil)
	if err != nil || ti.UserID != "token:shop" || len(ti.Scopes) != 1 || ti.Scopes[0] != ScopeRead {
		t.Errorf("valid token: %+v %v", ti, err)
	}
	if _, err := v(context.Background(), tok+"x", nil); !errors.Is(err, sdkauth.ErrInvalidToken) {
		t.Errorf("wrong token: %v", err)
	}
	if _, err := v(context.Background(), sum, nil); !errors.Is(err, sdkauth.ErrInvalidToken) {
		t.Errorf("the stored hash used as a token: %v", err)
	}
	clock = now.Add(time.Hour)
	if _, err := v(context.Background(), tok, nil); !errors.Is(err, sdkauth.ErrInvalidToken) {
		t.Errorf("expired token: %v", err)
	}
	for _, bad := range []StaticToken{{SHA256: "xyz", Repo: "a", Expires: now}, {SHA256: sum, Expires: now}, {SHA256: sum, Repo: "a"}} {
		if _, err := StaticTokens([]StaticToken{bad}, nil); err == nil {
			t.Errorf("%+v accepted", bad)
		}
	}
	s := sha256.Sum256([]byte(tok))
	if hex.EncodeToString(s[:]) != sum {
		t.Error("NewStaticToken's hash is not the token's sha256")
	}
}

// echo records the identity and the body it received.
type echo struct {
	id   Identity
	body string
	hit  bool
}

func (e *echo) ServeHTTP(w http.ResponseWriter, r *http.Request) {
	e.id, _ = FromContext(r.Context())
	b, _ := io.ReadAll(r.Body)
	e.body, e.hit = string(b), true
	w.WriteHeader(http.StatusOK)
}

func call(tool string) string {
	return `{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"` + tool + `","arguments":{}}}`
}

func TestBearerMiddleware(t *testing.T) {
	tok, sum, _ := NewStaticToken()
	v, _ := StaticTokens([]StaticToken{{SHA256: sum, Repo: "shop", Expires: time.Now().Add(time.Hour)}}, nil)
	next := &echo{}
	h := Bearer(v, BearerOptions{ResourceMetadataURL: "https://mcp.example.com/.well-known/oauth-protected-resource"})(next)
	do := func(token, body string) *httptest.ResponseRecorder {
		*next = echo{}
		r := httptest.NewRequest(http.MethodPost, "/mcp", strings.NewReader(body))
		if token != "" {
			r.Header.Set("Authorization", "Bearer "+token)
		}
		w := httptest.NewRecorder()
		h.ServeHTTP(w, r)
		return w
	}
	w := do("", call("context"))
	if w.Code != http.StatusUnauthorized || !strings.Contains(w.Header().Get("WWW-Authenticate"), "resource_metadata=") || next.hit {
		t.Errorf("no token: %d %q", w.Code, w.Header().Get("WWW-Authenticate"))
	}
	if w := do("wrong", call("context")); w.Code != http.StatusUnauthorized || strings.Contains(w.Body.String(), "sha") {
		t.Errorf("wrong token: %d %q", w.Code, w.Body.String())
	}
	if w := do(tok, call("context")); w.Code != http.StatusOK || next.id.Principal != "token:shop" || next.body != call("context") {
		t.Errorf("read tool: %d %+v %q", w.Code, next.id, next.body)
	}
	// A read-only token cannot start a fit, alone or inside a batch, nor with a key of another case beside the one the
	// MCP SDK reads ("Name" next to "name", "Method" next to "method": keys are matched exactly, as the SDK does), nor
	// with bytes after the message, which the SDK does not read (it reads the first JSON value of a body).
	for _, body := range []string{call("fit_start"), "[" + call("context") + "," + call("fit_start") + "]",
		`{"jsonrpc":"2.0","id":6,"method":"tools/call","params":{"name":"fit_start","Name":"context","arguments":{"capture":"x"}}}`,
		`{"jsonrpc":"2.0","id":7,"method":"tools/call","Method":"ping","params":{"name":"fit_start","arguments":{"capture":"x"}}}`,
		`[{"jsonrpc":"2.0","id":8,"Method":"ping","method":"tools/call","params":{"Name":"context","name":"fit_start"}}]`,
		call("fit_start") + " x", call("fit_start") + `{"jsonrpc":"2.0","id":2,"method":"ping"}`,
		"[" + call("fit_start") + "] x"} {
		w := do(tok, body)
		if w.Code != http.StatusForbidden || next.hit || !strings.Contains(w.Header().Get("WWW-Authenticate"), `error="insufficient_scope", scope="rhobound:fit"`) {
			t.Errorf("fit_start with read scope: %d %q", w.Code, w.Header().Get("WWW-Authenticate"))
		}
	}
	// A tool the server does not register (WithTools) is not checked: the MCP handler answers it as unknown.
	r := httptest.NewRequest(http.MethodPost, "/mcp", strings.NewReader(call("fit_start")))
	r.Header.Set("Authorization", "Bearer "+tok)
	r = r.WithContext(WithTools(r.Context(), func(name string) bool { return name != "fit_start" }))
	*next = echo{}
	rec := httptest.NewRecorder()
	if h.ServeHTTP(rec, r); rec.Code != http.StatusOK || !next.hit {
		t.Errorf("fit_start, not a tool of the server, with read scope: %d", rec.Code)
	}
	// A body over the peek limit is handed on unchanged (the MCP handler's cap refuses it).
	big := `{"jsonrpc":"2.0","id":1,"method":"tools/list","params":{"x":"` + strings.Repeat("a", maxPeek) + `"}}`
	if w := do(tok, big); w.Code != http.StatusOK || next.body != big {
		t.Errorf("large body: %d, %d bytes handed on", w.Code, len(next.body))
	}
}

func TestFrontDoor(t *testing.T) {
	next := &echo{}
	h := FrontDoor(next)
	do := func(c *Claims, body string) int {
		*next = echo{}
		r := httptest.NewRequest(http.MethodPost, "/mcp", strings.NewReader(body))
		if c != nil {
			r = r.WithContext(WithClaims(r.Context(), *c))
		}
		w := httptest.NewRecorder()
		h.ServeHTTP(w, r)
		return w.Code
	}
	if code := do(nil, call("context")); code != http.StatusUnauthorized || next.hit {
		t.Errorf("no claims: %d", code)
	}
	if code := do(&Claims{Subject: "u", Source: "jwt"}, call("context")); code != http.StatusForbidden {
		t.Errorf("no read scope: %d", code)
	}
	read := &Claims{Subject: "u", Source: "jwt", Scopes: []string{ScopeRead}}
	if code := do(read, call("context")); code != http.StatusOK || next.id.Principal != "jwt:u" {
		t.Errorf("read: %d %+v", code, next.id)
	}
	if code := do(read, call("fit_start")); code != http.StatusForbidden || next.hit {
		t.Errorf("fit_start with read: %d", code)
	}
	fit := &Claims{Subject: "u", Source: "iam", Scopes: []string{ScopeRead, ScopeFit}}
	if code := do(fit, call("fit_start")); code != http.StatusOK || !next.id.Has(ScopeFit) {
		t.Errorf("fit_start with fit: %d %+v", code, next.id)
	}
}

func TestLocal(t *testing.T) {
	id := Local()
	if !strings.HasPrefix(id.Principal, "local:") || len(id.Principal) <= len("local:") || !id.Has(ScopeRead) || !id.Has(ScopeFit) {
		t.Errorf("%+v", id)
	}
	ctx := WithIdentity(context.Background(), id)
	if got, ok := FromContext(ctx); !ok || got.Principal != id.Principal {
		t.Errorf("round trip: %+v %v", got, ok)
	}
	if _, ok := FromContext(context.Background()); ok {
		t.Error("identity in an empty context")
	}
}
