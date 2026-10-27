// SPDX-License-Identifier: Apache-2.0

package main

// The golden sweep: `rhobound predict` on every capture of the repository's test data, as text, as JSON and as JSON
// with a change, prints what commit 1a2df09 printed, byte for byte. The files under testdata/golden-1a2df09/ were
// written by a binary built from 1a2df09, and only such a binary may write them: there is no update flag. They are
// kept per GOARCH (the last bits of floating point differ between architectures); see the README there.

import (
	"bytes"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io/fs"
	"os"
	osexec "os/exec"
	"path/filepath"
	"regexp"
	"runtime"
	"slices"
	"strings"
	"testing"
)

// goldenCase is one run of the sweep: the arguments (the capture as a path from the repository root, which the
// reports print), the exit status, the standard output (a file name, "" when it was empty) and the standard error.
type goldenCase struct {
	Name         string   `json:"name"`
	Capture      string   `json:"capture"`
	Args         []string `json:"args"`
	Exit         int      `json:"exit"`
	Stdout       string   `json:"stdout"`
	StdoutSHA256 string   `json:"stdout_sha256"`
	Stderr       string   `json:"stderr"`
	StderrSHA256 string   `json:"stderr_sha256"`
}

type goldenManifest struct {
	Schema string       `json:"schema"`
	Commit string       `json:"commit"`
	GOARCH string       `json:"goarch"`
	Cases  []goldenCase `json:"cases"`
}

func sha256Hex(b []byte) string {
	s := sha256.Sum256(b)
	return hex.EncodeToString(s[:])
}

// codedRefusal reports whether b is the coded refusal a --json run may print in place of nothing: one object
// {"error": {"code", "reason", "fix", ...}} with a registry-shaped code.
func codedRefusal(b []byte) bool {
	var doc map[string]json.RawMessage
	if json.Unmarshal(b, &doc) != nil || len(doc) != 1 || doc["error"] == nil {
		return false
	}
	var r struct{ Code, Reason, Fix string }
	return json.Unmarshal(doc["error"], &r) == nil && regexp.MustCompile(`^[a-z]+\.[a-z0-9_]+$`).MatchString(r.Code) &&
		r.Reason != "" && r.Fix != ""
}

// firstDiff names the first line where got and want differ.
func firstDiff(got, want []byte) string {
	g, w := strings.Split(string(got), "\n"), strings.Split(string(want), "\n")
	for i := 0; i < len(g) && i < len(w); i++ {
		if g[i] != w[i] {
			return fmt.Sprintf("line %d:\n  got:  %s\n  want: %s", i+1, g[i], w[i])
		}
	}
	return fmt.Sprintf("the end: %d lines, want %d", len(g), len(w))
}

func TestGoldenSweep1a2df09(t *testing.T) {
	root, err := filepath.Abs(filepath.Join("..", ".."))
	if err != nil {
		t.Fatal(err)
	}
	dir := filepath.Join(root, "testdata", "golden-1a2df09", runtime.GOARCH)
	raw, err := os.ReadFile(filepath.Join(dir, "manifest.json"))
	if errors.Is(err, fs.ErrNotExist) && runtime.GOARCH == "arm64" {
		// the architecture the goldens were recorded on: a missing manifest is a lost check, never a skip
		t.Fatalf("testdata/golden-1a2df09/arm64/manifest.json is missing: %v", err)
	}
	if errors.Is(err, fs.ErrNotExist) {
		t.Skipf("no goldens of 1a2df09 for GOARCH=%s: floating point differs in the last bits between architectures "+
			"(testdata/golden-1a2df09/README.md says how to add them; tools/golden-live.sh compares with a 1a2df09 "+
			"binary built here instead)", runtime.GOARCH)
	}
	if err != nil {
		t.Fatal(err)
	}
	var m goldenManifest
	if err := json.Unmarshal(raw, &m); err != nil {
		t.Fatal(err)
	}
	if m.Schema != "rhobound.golden-sweep/v1" || m.Commit != "1a2df09" || m.GOARCH != runtime.GOARCH || len(m.Cases) == 0 {
		t.Fatalf("manifest: schema %q, commit %q, goarch %q, %d cases", m.Schema, m.Commit, m.GOARCH, len(m.Cases))
	}
	inRoot(t, root)
	for _, c := range m.Cases {
		t.Run(c.Name, func(t *testing.T) {
			var want []byte
			if c.Stdout != "" {
				if want, err = os.ReadFile(filepath.Join(dir, c.Stdout)); err != nil {
					t.Fatal(err)
				}
			}
			if sha256Hex(want) != c.StdoutSHA256 || sha256Hex([]byte(c.Stderr)) != c.StderrSHA256 {
				t.Fatalf("the golden files of %s do not match the manifest's sha256: they were edited", c.Name)
			}
			compareWith1a2df09(t, c.Args, c.Exit, want, c.Stderr)
		})
	}
}

// TestGoldenLive1a2df09 is the sweep against a binary built from commit 1a2df09 on this machine, run now, rather than
// against the files it printed on linux/arm64: the check of the byte rule on any architecture. It runs only when
// RHOBOUND_GOLDEN_1A2DF09 names that binary (tools/golden-live.sh builds it from the repository's history and runs
// this test), on the arguments of the manifest's cases, which are the same on every architecture.
func TestGoldenLive1a2df09(t *testing.T) {
	bin := os.Getenv("RHOBOUND_GOLDEN_1A2DF09")
	if bin == "" {
		t.Skip("RHOBOUND_GOLDEN_1A2DF09 names no binary of 1a2df09 (tools/golden-live.sh builds one and runs this test)")
	}
	root, err := filepath.Abs(filepath.Join("..", ".."))
	if err != nil {
		t.Fatal(err)
	}
	raw, err := os.ReadFile(filepath.Join(root, "testdata", "golden-1a2df09", "arm64", "manifest.json"))
	if err != nil {
		t.Fatal(err)
	}
	var m goldenManifest
	if err := json.Unmarshal(raw, &m); err != nil || m.Commit != "1a2df09" || len(m.Cases) == 0 {
		t.Fatalf("manifest: %v, commit %q, %d cases", err, m.Commit, len(m.Cases))
	}
	inRoot(t, root)
	for _, c := range m.Cases {
		t.Run(c.Name, func(t *testing.T) {
			cmd := osexec.Command(bin, c.Args...)
			cmd.Env = append(os.Environ(), "RHOBOUND_ESTIMATOR=")
			var out, errw bytes.Buffer
			cmd.Stdout, cmd.Stderr = &out, &errw
			exit := 0
			if err := cmd.Run(); err != nil {
				var ee *osexec.ExitError
				if !errors.As(err, &ee) {
					t.Fatalf("1a2df09 %s: %v", strings.Join(c.Args, " "), err)
				}
				exit = ee.ExitCode()
			}
			// the binary is 1a2df09's: the case's exit status, the same on every architecture, says so
			if exit != c.Exit {
				t.Fatalf("1a2df09 %s: exit %d, the manifest says %d: is %s built from 1a2df09?", strings.Join(c.Args, " "),
					exit, c.Exit, bin)
			}
			compareWith1a2df09(t, c.Args, exit, out.Bytes(), errw.String())
		})
	}
}

// inRoot runs the rest of the test from the repository root, as the goldens were made: the reports print the capture
// argument. No test of this package runs in parallel, so changing the working directory is safe.
func inRoot(t *testing.T, root string) {
	t.Helper()
	t.Setenv("RHOBOUND_ESTIMATOR", "") // the default estimator, as the goldens were made
	wd, err := os.Getwd()
	if err != nil {
		t.Fatal(err)
	}
	if err := os.Chdir(root); err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { os.Chdir(wd) })
}

// compareWith1a2df09 runs this tree's CLI on args and compares what it prints with what 1a2df09 printed (exit status,
// standard output, standard error), byte for byte, but for the one planned change: a refusal with --json may print the
// coded refusal object on standard output where 1a2df09 printed nothing, its standard error unchanged.
func compareWith1a2df09(t *testing.T, args []string, wantExit int, want []byte, wantErr string) {
	t.Helper()
	var out, errw bytes.Buffer
	code := run(args, &out, &errw)
	if code != wantExit {
		t.Fatalf("rhobound %s: exit %d, want %d (stderr %q)", strings.Join(args, " "), code, wantExit, errw.String())
	}
	if wantExit != 0 && slices.Contains(args, "--json") {
		// A refusal with --json: what 1a2df09 printed on standard output, or the coded refusal object where 1a2df09
		// printed nothing. Its text form, another case of the sweep, keeps the message.
		if !bytes.Equal(out.Bytes(), want) && (len(want) != 0 || !codedRefusal(out.Bytes())) {
			t.Errorf("rhobound %s: standard output is neither 1a2df09's nor, where 1a2df09 printed nothing, a coded "+
				"refusal:\n%s", strings.Join(args, " "), out.String())
		}
		// standard error keeps the message unchanged (USAGE.md section 9)
		if errw.String() != wantErr {
			t.Errorf("rhobound %s: standard error %q, want %q", strings.Join(args, " "), errw.String(), wantErr)
		}
		return
	}
	if !bytes.Equal(out.Bytes(), want) {
		t.Errorf("rhobound %s: standard output differs from 1a2df09's at %s", strings.Join(args, " "), firstDiff(out.Bytes(), want))
	}
	if errw.String() != wantErr {
		t.Errorf("rhobound %s: standard error %q, want %q", strings.Join(args, " "), errw.String(), wantErr)
	}
}
