// SPDX-License-Identifier: Apache-2.0

package main

// Regression tests for the command line: non-finite flag values used to panic
// or pass the checks (each failed at 094b99a).

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func safeExec(t *testing.T, args ...string) (out, errw string, code int, panicked any) {
	t.Helper()
	defer func() {
		if p := recover(); p != nil {
			panicked = p
		}
	}()
	out, errw, code = exec(t, args...)
	return
}

func TestNonFiniteFlags(t *testing.T) {
	topo := filepath.Join(t.TempDir(), "t.json")
	os.WriteFile(topo, []byte(`{"entry":{"a":1},"services":[{"name":"a","s":10,"children":["b"]},{"name":"b","s":5}]}`), 0o644)
	cases := [][]string{
		{"model", topo, "--rps", "NaN"},
		{"model", topo, "--rps", "Inf"},
		{"model", topo, "--rps", "20", "--patch", "b=NaNms"},
		{"model", topo, "--rps", "20", "--patch", "b=Inf%", "--json"},
		{"predict", fixture, "--kept-share", "NaN"},
		{"predict", fixture, "--max-rho", "NaN", "--workers", "b=1"},
		{"predict", fixture, "--patch", "b=NaNms", "--json"},
	}
	for _, c := range cases {
		out, errw, code, p := safeExec(t, c...)
		line := strings.Join(c[0:1], " ") + " " + strings.Join(c[2:], " ")
		switch {
		case p != nil:
			t.Errorf("%s: panic: %v", line, p)
		case code != 0 && strings.Contains(errw, "unsupported value"):
			t.Errorf("%s: JSON encoder error instead of a flag error: %s", line, strings.TrimSpace(errw))
		case code == 0:
			t.Errorf("%s: accepted (exit 0); output:\n%.400s", line, out)
		}
	}
}
