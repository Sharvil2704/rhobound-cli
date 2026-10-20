// SPDX-License-Identifier: Apache-2.0

package infer_test

// Not part of rhobound-cli: parity.sh copies this file into a copy of internal/infer and runs it to record
// simulated captures in which a service calls one callee several times in parallel (children [b, b, b]), so that
// CLIENT spans of one parent to one callee often start at the same nanosecond: the order Go's sort leaves such
// ties in reaches the branch pairing. (Adapted from a test written to check the first version.)
//
//	RBFAST_TIE_CAPTURES=DIR go test -count=1 -run TestWriteTieCaptures ./internal/infer

import (
	"os"
	"path/filepath"
	"testing"
)

func TestWriteTieCaptures(t *testing.T) {
	dir := os.Getenv("RBFAST_TIE_CAPTURES")
	if dir == "" {
		t.Skip("RBFAST_TIE_CAPTURES not set")
	}
	for _, spanq := range []bool{false, true} {
		b := &node{name: "b", c: 4, pods: 1, mean: 6, dist: "gamma", cs2: 0.5}
		c := &node{name: "c", c: 1, pods: 1, mean: 4}
		a := &node{name: "a", c: 2, pods: 1, mean: 2, parallel: true, children: []*node{b, b, b}}
		a2 := &node{name: "a", c: 2, pods: 1, mean: 2, parallel: true, children: []*node{b, c, b}}
		name := "sim-par-same-callee"
		if spanq {
			name += "-spanq"
		}
		if err := writeOTLPTo(filepath.Join(dir, name), run(a, 30, 300, 23, spanq).spans); err != nil {
			t.Fatal(err)
		}
		if err := writeOTLPTo(filepath.Join(dir, name+"-mixed"), run(a2, 30, 300, 29, spanq).spans); err != nil {
			t.Fatal(err)
		}
	}
}
