// SPDX-License-Identifier: Apache-2.0

package auth

import (
	"bytes"
	"context"
	"crypto"
	"crypto/rsa"
	"crypto/sha256"
	"encoding/base64"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"math/big"
	"net/http"
	"slices"
	"strings"
	"sync"
	"time"

	sdkauth "github.com/modelcontextprotocol/go-sdk/auth"
)

// JWTConfig configures the JWT verifier of container mode. It accepts RS256 only (the algorithm API Gateway's JWT
// authorizer supports), so a token cannot choose a weaker one.
type JWTConfig struct {
	Issuer string // required: iss must equal it
	// Audience: aud must contain it. A token without aud (a Cognito access token without resource binding) is
	// accepted only when its client_id is in ClientIDs (DEPLOY_AWS.md 2.1).
	Audience  string
	ClientIDs []string
	TokenUse  string // when set, token_use must equal it ("access" for Cognito)
	// ResourceServer is this server's resource-server identifier, whose scopes ("<ResourceServer>/rhobound:read")
	// count as this server's; a scope under any other prefix is ignored (ResourceScopes).
	ResourceServer string
	Keys           KeySource
	ClockSkew      time.Duration
	Now            func() time.Time // time.Now when nil
}

// KeySource returns the RSA public key with a key id.
type KeySource interface {
	Key(ctx context.Context, kid string) (*rsa.PublicKey, error)
}

// ErrUnknownKey: the key set has no key with that id.
var ErrUnknownKey = errors.New("auth: unknown key id")

// StaticKeys is a fixed key set.
type StaticKeys map[string]*rsa.PublicKey

func (k StaticKeys) Key(_ context.Context, kid string) (*rsa.PublicKey, error) {
	if key, ok := k[kid]; ok {
		return key, nil
	}
	return nil, ErrUnknownKey
}

// JWKS reads a JSON Web Key Set from URL, keeps it, and reads it again when asked for a key id it does not hold, at
// most once per MinRefresh (one minute when 0), counted from the last attempt, failed or not: tokens with made-up key
// ids, or a key set that is down, cause at most one fetch per MinRefresh. One fetch runs at a time, and a key id it
// already holds never waits for one.
type JWKS struct {
	URL        string
	HTTP       *http.Client // http.DefaultClient when nil
	MinRefresh time.Duration

	fetching  sync.Mutex // held during a fetch
	mu        sync.Mutex // guards keys and attempted
	keys      map[string]*rsa.PublicKey
	attempted time.Time
}

func (j *JWKS) Key(ctx context.Context, kid string) (*rsa.PublicKey, error) {
	if key, done, err := j.cached(kid); done {
		return key, err
	}
	j.fetching.Lock()
	defer j.fetching.Unlock()
	if key, done, err := j.cached(kid); done { // a fetch that ended while this one waited
		return key, err
	}
	keys, err := j.fetch(ctx)
	j.mu.Lock()
	j.attempted = time.Now()
	if err == nil {
		j.keys = keys
	}
	j.mu.Unlock()
	if err != nil {
		return nil, err
	}
	if key, ok := keys[kid]; ok {
		return key, nil
	}
	return nil, ErrUnknownKey
}

// cached answers from the key set held: the key, or ErrUnknownKey when the last attempt was within MinRefresh. done
// is false when the key set should be read again.
func (j *JWKS) cached(kid string) (key *rsa.PublicKey, done bool, err error) {
	j.mu.Lock()
	defer j.mu.Unlock()
	if key, ok := j.keys[kid]; ok {
		return key, true, nil
	}
	every := j.MinRefresh
	if every <= 0 {
		every = time.Minute
	}
	if !j.attempted.IsZero() && time.Since(j.attempted) < every {
		return nil, true, ErrUnknownKey
	}
	return nil, false, nil
}

func (j *JWKS) fetch(ctx context.Context) (map[string]*rsa.PublicKey, error) {
	c := j.HTTP
	if c == nil {
		c = http.DefaultClient
	}
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, j.URL, nil)
	if err != nil {
		return nil, err
	}
	resp, err := c.Do(req)
	if err != nil {
		return nil, fmt.Errorf("auth: key set: %w", err)
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		return nil, fmt.Errorf("auth: key set: HTTP %d", resp.StatusCode)
	}
	b, err := io.ReadAll(io.LimitReader(resp.Body, 1<<20))
	if err != nil {
		return nil, fmt.Errorf("auth: key set: %w", err)
	}
	return ParseJWKS(b)
}

// ParseJWKS reads the RSA signing keys of a JSON Web Key Set (RFC 7517). Keys of other types or uses, and RSA keys
// under 2048 bits, are skipped.
func ParseJWKS(b []byte) (map[string]*rsa.PublicKey, error) {
	var set struct {
		Keys []struct {
			Kty, Kid, Use, Alg, N, E string
		} `json:"keys"`
	}
	if err := json.Unmarshal(b, &set); err != nil {
		return nil, fmt.Errorf("auth: key set: %w", err)
	}
	keys := map[string]*rsa.PublicKey{}
	for _, k := range set.Keys {
		if k.Kty != "RSA" || k.Kid == "" || (k.Use != "" && k.Use != "sig") || (k.Alg != "" && k.Alg != "RS256") {
			continue
		}
		n, err1 := base64.RawURLEncoding.DecodeString(k.N)
		e, err2 := base64.RawURLEncoding.DecodeString(k.E)
		if err1 != nil || err2 != nil || len(e) == 0 || len(e) > 4 {
			continue
		}
		key := &rsa.PublicKey{N: new(big.Int).SetBytes(n), E: int(new(big.Int).SetBytes(e).Int64())}
		if key.N.BitLen() < 2048 || key.E < 3 {
			continue
		}
		keys[k.Kid] = key
	}
	return keys, nil
}

// JWT returns a verifier for RS256 access tokens: signature by a key from cfg.Keys, iss, aud or an allow-listed
// client_id, token_use, exp (required) and nbf with cfg.ClockSkew. Scopes come from "scope" (space-separated) or
// "scp", through ResourceScopes with cfg.ResourceServer. The user id is "jwt:" and the token's JWTSubject: the
// principal, as FrontDoor names the same caller in Lambda mode.
func JWT(cfg JWTConfig) (sdkauth.TokenVerifier, error) {
	if cfg.Issuer == "" || cfg.Keys == nil || (cfg.Audience == "" && len(cfg.ClientIDs) == 0) {
		return nil, errors.New("auth: a JWT verifier needs an issuer, keys, and an audience or client ids")
	}
	now := cfg.Now
	if now == nil {
		now = time.Now
	}
	return func(ctx context.Context, token string, _ *http.Request) (*sdkauth.TokenInfo, error) {
		c, err := verifyJWT(ctx, token, cfg.Keys)
		if err != nil {
			return nil, err
		}
		return c.check(cfg, now())
	}, nil
}

// invalid is the error for any token that does not verify: the SDK answers 401 with only "invalid token", so
// nothing about why reaches the caller.
var invalid = fmt.Errorf("%w", sdkauth.ErrInvalidToken)

type jwtClaims struct {
	Iss      string          `json:"iss"`
	Sub      string          `json:"sub"`
	Aud      json.RawMessage `json:"aud"`
	Exp      *json.Number    `json:"exp"`
	Nbf      *json.Number    `json:"nbf"`
	ClientID string          `json:"client_id"`
	TokenUse string          `json:"token_use"`
	Scope    string          `json:"scope"`
	Scp      json.RawMessage `json:"scp"`
}

func verifyJWT(ctx context.Context, token string, keys KeySource) (*jwtClaims, error) {
	parts := strings.Split(token, ".")
	if len(parts) != 3 {
		return nil, invalid
	}
	var hdr struct {
		Alg  string          `json:"alg"`
		Kid  string          `json:"kid"`
		Crit json.RawMessage `json:"crit"`
	}
	if !decodePart(parts[0], &hdr) || hdr.Alg != "RS256" || hdr.Kid == "" || hdr.Crit != nil {
		return nil, invalid
	}
	key, err := keys.Key(ctx, hdr.Kid)
	if errors.Is(err, ErrUnknownKey) {
		return nil, invalid
	}
	if err != nil {
		return nil, errors.New("auth: key set unavailable")
	}
	sig, err := base64.RawURLEncoding.DecodeString(parts[2])
	if err != nil {
		return nil, invalid
	}
	digest := sha256.Sum256([]byte(parts[0] + "." + parts[1]))
	if rsa.VerifyPKCS1v15(key, crypto.SHA256, digest[:], sig) != nil {
		return nil, invalid
	}
	var c jwtClaims
	if !decodePart(parts[1], &c) {
		return nil, invalid
	}
	return &c, nil
}

func (c *jwtClaims) check(cfg JWTConfig, now time.Time) (*sdkauth.TokenInfo, error) {
	if c.Iss != cfg.Issuer {
		return nil, invalid
	}
	aud, ok := stringOrList(c.Aud)
	if !ok {
		return nil, invalid
	}
	switch {
	case len(aud) > 0:
		if cfg.Audience == "" || !slices.Contains(aud, cfg.Audience) {
			return nil, invalid
		}
	case c.ClientID == "" || !slices.Contains(cfg.ClientIDs, c.ClientID):
		return nil, invalid
	}
	if cfg.TokenUse != "" && c.TokenUse != cfg.TokenUse {
		return nil, invalid
	}
	exp, ok := unixTime(c.Exp)
	if !ok || !now.Before(exp.Add(cfg.ClockSkew)) {
		return nil, invalid
	}
	if c.Nbf != nil {
		nbf, ok := unixTime(c.Nbf)
		if !ok || now.Add(cfg.ClockSkew).Before(nbf) {
			return nil, invalid
		}
	}
	scopes := strings.Fields(c.Scope)
	if len(scopes) == 0 {
		if scp, ok := stringOrList(c.Scp); ok {
			for _, s := range scp {
				scopes = append(scopes, strings.Fields(s)...)
			}
		}
	}
	scopes = ResourceScopes(cfg.ResourceServer, scopes)
	user := JWTSubject(c.Sub, c.ClientID)
	if user == "" {
		return nil, invalid
	}
	return &sdkauth.TokenInfo{Scopes: scopes, Expiration: exp, UserID: "jwt:" + user, Extra: map[string]any{"iss": c.Iss}}, nil
}

// JWTSubject is the subject a JWT names its caller by: "sub:" and its sub, or "client:" and its client_id for a token
// without a sub (client credentials); "" for neither, and for a sub (or the client_id taken) of only white space,
// which names no one: the token is then refused, whatever else it carries. No sub can give the client form, so a user
// whose sub is "client:x" never shares a principal with client x. The principal is "jwt:" and the subject in container
// mode (JWT) and in Lambda mode (FrontDoor, from the API Gateway authorizer's claims) alike, and both modes refuse a
// token whose sub or client_id is not a string: the container's verifier cannot decode it, and Lambda mode refuses
// claims that apigw.Authorizer.NotStrings names.
func JWTSubject(sub, clientID string) string {
	switch {
	case sub != "" && strings.TrimSpace(sub) == "":
		return ""
	case sub != "":
		return "sub:" + sub
	case strings.TrimSpace(clientID) != "":
		return "client:" + clientID
	}
	return ""
}

func decodePart(s string, v any) bool {
	b, err := base64.RawURLEncoding.DecodeString(s)
	if err != nil {
		return false
	}
	dec := json.NewDecoder(bytes.NewReader(b))
	dec.UseNumber()
	return dec.Decode(v) == nil
}

// stringOrList reads a claim that is a string or a list of strings; absent is an empty list.
func stringOrList(raw json.RawMessage) ([]string, bool) {
	if len(raw) == 0 || string(raw) == "null" {
		return nil, true
	}
	var s string
	if json.Unmarshal(raw, &s) == nil {
		return []string{s}, true
	}
	var l []string
	if json.Unmarshal(raw, &l) == nil {
		return l, true
	}
	return nil, false
}

func unixTime(n *json.Number) (time.Time, bool) {
	if n == nil {
		return time.Time{}, false
	}
	f, err := n.Float64()
	if err != nil || f <= 0 || f > 1e11 {
		return time.Time{}, false
	}
	return time.Unix(int64(f), 0), true
}
