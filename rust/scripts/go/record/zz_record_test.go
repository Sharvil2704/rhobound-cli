// SPDX-License-Identifier: Apache-2.0

// Records every command line the cmd/rhobound tests run through exec(), for rbfast's parity.sh: the arguments
// (with the test's temporary inputs copied out, since t.TempDir is removed after each test), and Go's own
// stdout, stderr and exit status. parity.sh copies this file next to a copy of cmd/rhobound and adds one call,
// recordCall(t, args, out, errw, code), at the end of exec in main_test.go; nothing else changes.
//
// Placeholders in args.json: @FIXTURE@ is testdata/capture-chain; @IN@/K is input K of the case (a copied
// file or folder); @OUT@ is a folder the command writes (--out), fresh for each replay.

package main

import (
	"encoding/json"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"testing"
)

var (
	recDir = os.Getenv("RBFAST_REC_DIR")
	recMu  sync.Mutex
	recN   int
)

func copyTree(src, dst string) error {
	return filepath.Walk(src, func(p string, fi os.FileInfo, err error) error {
		if err != nil {
			return err
		}
		rel, _ := filepath.Rel(src, p)
		target := filepath.Join(dst, rel)
		if fi.IsDir() {
			return os.MkdirAll(target, 0o755)
		}
		in, err := os.Open(p)
		if err != nil {
			return err
		}
		defer in.Close()
		out, err := os.Create(target)
		if err != nil {
			return err
		}
		if _, err := io.Copy(out, in); err != nil {
			out.Close()
			return err
		}
		return out.Close()
	})
}

func recordCall(t *testing.T, args []string, out, errw string, code int) {
	if recDir == "" {
		return
	}
	recMu.Lock()
	defer recMu.Unlock()
	recN++
	dir := filepath.Join(recDir, fmt.Sprintf("%04d", recN))
	if err := os.MkdirAll(filepath.Join(dir, "in"), 0o755); err != nil {
		t.Fatal(err)
	}
	tmp := os.TempDir()
	type repl struct{ from, to string }
	var repls []repl
	nargs := make([]string, len(args))
	nin := 0
	for k, a := range args {
		nargs[k] = a
		switch {
		case k > 0 && (args[k-1] == "--out" || args[k-1] == "-out"):
			nargs[k] = "@OUT@"
			repls = append(repls, repl{a, "@OUT@"})
		case a == fixture:
			nargs[k] = "@FIXTURE@"
		case strings.HasPrefix(a, tmp+string(os.PathSeparator)):
			if _, err := os.Stat(a); err != nil {
				continue // a path that does not exist stays as given
			}
			name := fmt.Sprintf("@IN@/%d", nin)
			if err := copyTree(a, filepath.Join(dir, "in", fmt.Sprint(nin))); err != nil {
				t.Fatal(err)
			}
			nin++
			nargs[k] = name
			repls = append(repls, repl{a, name})
		}
	}
	sub := func(s string) string {
		for _, r := range repls {
			s = strings.ReplaceAll(s, r.from, r.to)
		}
		return strings.ReplaceAll(s, fixture, "@FIXTURE@")
	}
	doc := map[string]any{"test": t.Name(), "args": nargs, "code": code, "stdout": sub(out), "stderr": sub(errw)}
	b, _ := json.MarshalIndent(doc, "", "  ")
	if err := os.WriteFile(filepath.Join(dir, "case.json"), b, 0o644); err != nil {
		t.Fatal(err)
	}
}
