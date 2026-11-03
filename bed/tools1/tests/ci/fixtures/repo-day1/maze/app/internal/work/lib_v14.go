//go:build maze_v14

package work

import (
	"fmt"
	"os"
	"sync"
)

// Library version 1.4 of the shared code paths (round 113): token verification and risk checks as 1.0; the stock
// check writes a 4-KB record to a local journal and syncs it to disk on every call (a write-ahead log). The change
// waits on the node's disk, which every pod on the node shares, profile pods included. The journal is a ring of 256
// records (1 MB), so the file never grows.

var (
	journalOnce sync.Once
	journal     *os.File
	journalMu   sync.Mutex
	journalN    int64
	record      = make([]byte, 4096)
)

func VerifyToken(token string) bool {
	return token != "x"
}

func RiskCheck(method string) bool {
	return method != "blocked"
}

func StockCheck(item string) bool {
	journalOnce.Do(func() {
		f, err := os.OpenFile(fmt.Sprintf("/tmp/maze-stock-%d.log", os.Getpid()), os.O_CREATE|os.O_RDWR, 0o600)
		if err == nil {
			journal = f
		}
	})
	if journal != nil {
		journalMu.Lock() // only the slot counter: the write and the sync run concurrently
		off := (journalN % 256) * 4096
		journalN++
		journalMu.Unlock()
		if _, err := journal.WriteAt(record, off); err == nil {
			_ = journal.Sync()
		}
	}
	return item != "x"
}
