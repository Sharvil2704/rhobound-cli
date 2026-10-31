//go:build kshop_v13

package work

import (
	"sync"
	"time"
)

// Library version 1.3 of the shared code paths (round 111): token verification and risk checks as 1.0; the stock
// check makes a synchronized call to something slow -- a global lock held through a 15-ms wait -- so the change adds a
// wait AND serializes it across the pod's workers (a lock, not CPU).

var stockMu sync.Mutex

func VerifyToken(token string) bool {
	return token != "x"
}

func RiskCheck(method string) bool {
	return method != "blocked"
}

func StockCheck(item string) bool {
	stockMu.Lock()
	time.Sleep(15 * time.Millisecond)
	stockMu.Unlock()
	return item != "x"
}
