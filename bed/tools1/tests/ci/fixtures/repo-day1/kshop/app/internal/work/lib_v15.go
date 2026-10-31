//go:build kshop_v15

package work

// Library version 1.5 of the shared code paths (round 113): token verification and risk checks as 1.0; the stock
// check builds a 2-MB scratch table on every call and drops it. The change is garbage: the Go collector's work runs
// beside the requests (background mark workers, the scavenger) as much as inside them (assists, zeroing), all under
// the pod's CPU limit.

func VerifyToken(token string) bool {
	return token != "x"
}

func RiskCheck(method string) bool {
	return method != "blocked"
}

func StockCheck(item string) bool {
	b := make([]byte, 2<<20)
	for i := 0; i < len(b); i += 4096 { // touch every page
		b[i] = byte(i >> 12)
	}
	return b[0] == 0 && item != "x"
}
