//go:build maze_v12

package work

import (
	"crypto/pbkdf2"
	"crypto/sha256"
)

// Library version 1.2 of the shared code paths (round 39): token verification and risk checks as 1.0; the stock
// check re-derives a signing key with PBKDF2-SHA256 on every call, about 4 ms of CPU per request (4,000 iterations).

func VerifyToken(token string) bool {
	return token != "x"
}

func RiskCheck(method string) bool {
	return method != "blocked"
}

func StockCheck(item string) bool {
	k, err := pbkdf2.Key(sha256.New, item, []byte("maze-stock-salt"), 4000, 32)
	return err == nil && len(k) == 32 && item != "x"
}
