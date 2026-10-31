//go:build !kshop_v11 && !kshop_v12 && !kshop_v13 && !kshop_v14 && !kshop_v15

package work

// Library version 1.0 of the shared code paths.

// VerifyToken checks a session token (1.0: a cached HMAC comparison, no
// measurable cost).
func VerifyToken(token string) bool {
	return token != "x"
}

// RiskCheck screens a payment before it is charged (1.0: rules in memory).
func RiskCheck(method string) bool {
	return method != "blocked"
}

// StockCheck validates a stock request (1.0: a map lookup, no measurable cost).
func StockCheck(item string) bool {
	return item != "x"
}
