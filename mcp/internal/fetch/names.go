// SPDX-License-Identifier: Apache-2.0

package fetch

import (
	"crypto/sha256"
	"encoding/hex"
	"fmt"
	"strings"
)

// maxStem keeps a file name well under the 255-byte limit of common file systems.
const maxStem = 160

// flatName derives a file name from an object's key path below the prefix: the folders joined by "_" and every
// byte outside [A-Za-z0-9=_-] replaced by "-", then the readable suffix. The partition path survives
// ("year=2026_month=10_day=26_hour=12_minute=00_traces_<id>.json.gz", as DATA.md 4.5 shows), the stem can never
// hold ".jsonl" or ".gz" (the reader picks framing and compression from the name), and nothing in the name comes
// from outside the key.
func flatName(rel, sfx string) string {
	stem := strings.TrimSuffix(rel, sfx)
	var b strings.Builder
	for i := 0; i < len(stem); i++ {
		c := stem[i]
		switch {
		case c == '/':
			b.WriteByte('_')
		case c >= 'a' && c <= 'z', c >= 'A' && c <= 'Z', c >= '0' && c <= '9', c == '=', c == '_', c == '-':
			b.WriteByte(c)
		default:
			b.WriteByte('-')
		}
	}
	s := b.String()
	if len(s) > maxStem {
		s = s[:maxStem] + "-" + keyHash(rel)
	}
	return s + sfx
}

func keyHash(key string) string {
	sum := sha256.Sum256([]byte(key))
	return hex.EncodeToString(sum[:6])
}

// assignNames gives every object a file name. Flattening is not one-to-one ("a/b_c" and "a_b/c" meet), so every
// object whose name another object also gets carries the hash of its key in its stem; the names are then
// distinct, which is checked.
func assignNames(objs []*listed, taken map[string]bool) error {
	count := map[string]int{}
	for _, o := range objs {
		o.name = flatName(o.rel, o.sfx)
		count[o.name]++
	}
	for _, o := range objs {
		if count[o.name] > 1 || taken[o.name] {
			o.name = strings.TrimSuffix(o.name, o.sfx) + "-" + keyHash(o.rel) + o.sfx
		}
	}
	for _, o := range objs {
		if taken[o.name] {
			return fmt.Errorf("fetch: two objects map to the file name %s", o.name)
		}
		taken[o.name] = true
	}
	return nil
}
