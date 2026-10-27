// SPDX-License-Identifier: Apache-2.0

package auth

import (
	"context"
	"crypto/rand"
	"crypto/sha256"
	"crypto/subtle"
	"encoding/base64"
	"encoding/hex"
	"fmt"
	"net/http"
	"regexp"
	"time"

	sdkauth "github.com/modelcontextprotocol/go-sdk/auth"
)

// StaticToken is one header-only client's token, stored hashed (DEPLOY_AWS.md 2.1): the hex sha256 of the token, the
// repository it belongs to, and its expiry (a rotation period). A static token only ever grants rhobound:read.
type StaticToken struct {
	SHA256  string
	Repo    string
	Expires time.Time
}

var hexRE = regexp.MustCompile(`^[0-9a-f]{64}$`)

// NewStaticToken returns a fresh token (256 random bits, base64url) and the hash to store for it.
func NewStaticToken() (token, sha string, err error) {
	var b [32]byte
	if _, err := rand.Read(b[:]); err != nil {
		return "", "", err
	}
	token = base64.RawURLEncoding.EncodeToString(b[:])
	s := sha256.Sum256([]byte(token))
	return token, hex.EncodeToString(s[:]), nil
}

// StaticTokens returns a verifier for hashed static tokens. The presented token is hashed and compared with every
// stored hash in constant time, so neither a match nor its position shows in the timing. now is the clock (time.Now
// when nil).
func StaticTokens(tokens []StaticToken, now func() time.Time) (sdkauth.TokenVerifier, error) {
	if now == nil {
		now = time.Now
	}
	type entry struct {
		sum     [32]byte
		repo    string
		expires time.Time
	}
	var es []entry
	for i, t := range tokens {
		if !hexRE.MatchString(t.SHA256) || t.Repo == "" || t.Expires.IsZero() {
			return nil, fmt.Errorf("auth: static token %d needs a sha256, a repository and an expiry", i)
		}
		var e entry
		hex.Decode(e.sum[:], []byte(t.SHA256))
		e.repo, e.expires = t.Repo, t.Expires
		es = append(es, e)
	}
	return func(_ context.Context, token string, _ *http.Request) (*sdkauth.TokenInfo, error) {
		sum := sha256.Sum256([]byte(token))
		match := -1
		for i := range es {
			if subtle.ConstantTimeCompare(sum[:], es[i].sum[:]) == 1 {
				match = i
			}
		}
		if match < 0 || !now().Before(es[match].expires) {
			return nil, fmt.Errorf("%w", sdkauth.ErrInvalidToken)
		}
		return &sdkauth.TokenInfo{
			Scopes:     []string{ScopeRead},
			Expiration: es[match].expires,
			UserID:     "token:" + es[match].repo,
		}, nil
	}, nil
}
