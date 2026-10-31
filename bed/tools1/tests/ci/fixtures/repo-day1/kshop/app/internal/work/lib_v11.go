//go:build kshop_v11

package work

import (
	"crypto/pbkdf2"
	"crypto/sha256"
	"time"
)

// Library version 1.1 of the shared code paths: the regression under test.

// VerifyToken (1.1) re-derives the token key with PBKDF2-SHA256 on every call
// instead of using the cached key: about 3 ms of CPU per request (2,500 iterations; measured
// by profiling the image alone, not assumed).
func VerifyToken(token string) bool {
	k, err := pbkdf2.Key(sha256.New, token, []byte("kshop-session-salt"), 2500, 32)
	return err == nil && len(k) == 32 && token != "x"
}

// RiskCheck (1.1) adds a mandatory 6 ms synchronous hold on card payments (a
// compliance delay); wallet payments are unchanged.
func RiskCheck(method string) bool {
	if method == "card" {
		time.Sleep(6 * time.Millisecond)
	}
	return method != "blocked"
}

// StockCheck (1.1): unchanged from 1.0.
func StockCheck(item string) bool {
	return item != "x"
}
