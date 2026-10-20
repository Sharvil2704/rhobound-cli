// SPDX-License-Identifier: Apache-2.0

// Prints, for every Unicode scalar value, strconv.Quote of its string, strconv.QuoteRune, unicode.IsPrint and
// unicode.IsSpace; then Quote of every invalid lead byte; and an FNV-1a 64 hash of it all (on stderr).
//
//	go run . > go.txt   (the hash must equal GO_FNV64A in crates/gostr/tests/all_code_points.rs)
package main

import (
	"bufio"
	"fmt"
	"hash/fnv"
	"io"
	"os"
	"strconv"
	"unicode"
)

func main() {
	h := fnv.New64a()
	w := bufio.NewWriter(os.Stdout)
	out := io.MultiWriter(w, h)
	b := func(x bool) int {
		if x {
			return 1
		}
		return 0
	}
	for r := rune(0); r <= 0x10FFFF; r++ {
		if r >= 0xD800 && r <= 0xDFFF {
			continue
		}
		fmt.Fprintf(out, "%x %s %s %d %d\n", r, strconv.Quote(string(r)), strconv.QuoteRune(r), b(unicode.IsPrint(r)), b(unicode.IsSpace(r)))
	}
	for c := 0x80; c <= 0xFF; c++ {
		fmt.Fprintf(out, "%x %s %s\n", c, strconv.Quote(string([]byte{byte(c)})), strconv.Quote(string([]byte{byte(c), 'a', 0xe2, 0x82})))
	}
	w.Flush()
	fmt.Fprintf(os.Stderr, "fnv64a %016x\n", h.Sum64())
}
