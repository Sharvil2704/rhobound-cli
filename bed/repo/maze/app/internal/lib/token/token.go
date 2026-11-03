// Package token is the session-token library every service that checks a caller links: an HMAC-SHA256 tag over the
// session id and its expiry, compared in constant time.
package token

import (
	"crypto/hmac"
	"crypto/sha256"
	"encoding/hex"
	"strconv"
	"strings"
)

var key = []byte("maze-demo-signing-key-not-a-secret")

// Rounds is how many times the tag is chained (the library's cost knob).
const Rounds = 64

// Sign returns "id.expiry.tag".
func Sign(id string, expiry int64) string {
	return id + "." + strconv.FormatInt(expiry, 10) + "." + hex.EncodeToString(tag(id, expiry))
}

func tag(id string, expiry int64) []byte {
	m := []byte(id + "." + strconv.FormatInt(expiry, 10))
	for range Rounds {
		h := hmac.New(sha256.New, key)
		h.Write(m)
		m = h.Sum(nil)
	}
	return m
}

// Verify reports whether tok is a well-formed, correctly signed token that has not expired at now.
func Verify(tok string, now int64) bool {
	parts := strings.Split(tok, ".")
	if len(parts) != 3 {
		return false
	}
	exp, err := strconv.ParseInt(parts[1], 10, 64)
	if err != nil || exp < now {
		return false
	}
	want, err := hex.DecodeString(parts[2])
	return err == nil && hmac.Equal(want, tag(parts[0], exp))
}
