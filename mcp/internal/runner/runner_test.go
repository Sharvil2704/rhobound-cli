// SPDX-License-Identifier: Apache-2.0

package runner

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"errors"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

// engine is a stand-in for the rhobound binary: a shell script that answers a few subcommands.
const engine = `#!/bin/sh
sub=$1; shift
case $sub in
env)   env | sort ;;
cat)   cat "$1" ;;
args)  for a in "$@"; do printf '[%s]\n' "$a"; done ;;
pwd)   pwd; ls -ld . | cut -c1-10 ;;
exit3) echo '{"error":{"code":"change.unknown_service","reason":"r","fix":"f"}}'; exit 3 ;;
sleep) sleep 5 ;;
big)   i=0; while [ $i -lt 2000 ]; do echo 0123456789012345678901234567890123456789; i=$((i+1)); done ;;
*)     echo "unknown $sub" >&2; exit 2 ;;
esac
`

// newEngine writes the script to a fresh folder and returns its path and sha256.
func newEngine(t *testing.T) (string, string) {
	t.Helper()
	p := filepath.Join(t.TempDir(), "rhobound")
	if err := os.WriteFile(p, []byte(engine), 0o755); err != nil {
		t.Fatal(err)
	}
	s := sha256.Sum256([]byte(engine))
	return p, hex.EncodeToString(s[:])
}

func TestExecEnvironmentIsMinimal(t *testing.T) {
	t.Setenv("AWS_SECRET_ACCESS_KEY", "do-not-pass")
	t.Setenv("AWS_REGION", "eu-west-1")
	t.Setenv("RHOBOUND_ESTIMATOR", "rise")
	t.Setenv("RHOBOUND_TEST_SECRET", "x")
	p, sum := newEngine(t)
	e, err := NewExec(p, sum, 10*time.Second, []string{"RHOBOUND_STATE=/state"})
	if err != nil {
		t.Fatal(err)
	}
	out, exit, err := e.Run(context.Background(), "env", nil, nil)
	if err != nil || exit != 0 {
		t.Fatalf("exit %d, %v", exit, err)
	}
	var names []string
	for _, line := range strings.Split(strings.TrimSpace(string(out)), "\n") {
		name, _, _ := strings.Cut(line, "=")
		names = append(names, name)
		if strings.HasPrefix(name, "AWS_") || name == "RHOBOUND_ESTIMATOR" || name == "RHOBOUND_TEST_SECRET" {
			t.Errorf("the child inherited %s", name)
		}
	}
	got := strings.Join(names, ",")
	for _, want := range []string{"HOME", "LC_ALL", "PATH", "RHOBOUND_STATE", "TMPDIR"} {
		if !strings.Contains(","+got+",", ","+want+",") {
			t.Errorf("child environment %s lacks %s", got, want)
		}
	}
}

func TestExecRefusesForbiddenEnv(t *testing.T) {
	p, sum := newEngine(t)
	for _, kv := range []string{"AWS_PROFILE=x", "RHOBOUND_ESTIMATOR=rise", "PATH=/tmp", "lower=x", "NOEQUALS"} {
		if _, err := NewExec(p, sum, 0, []string{kv}); err == nil {
			t.Errorf("%q accepted", kv)
		}
	}
}

func TestExecFilesAndFolder(t *testing.T) {
	p, sum := newEngine(t)
	root := t.TempDir()
	e, err := NewExec(p, sum, 10*time.Second, nil)
	if err != nil {
		t.Fatal(err)
	}
	e.TempRoot = root
	out, exit, err := e.Run(context.Background(), "cat", []string{File("changes.json")},
		map[string][]byte{"changes.json": []byte(`{"schema":"rhobound.change/v1"}`)})
	if err != nil || exit != 0 || string(out) != `{"schema":"rhobound.change/v1"}` {
		t.Fatalf("cat: %q exit %d %v", out, exit, err)
	}
	out, _, _ = e.Run(context.Background(), "pwd", nil, nil)
	lines := strings.Split(strings.TrimSpace(string(out)), "\n")
	if len(lines) != 2 || !strings.HasPrefix(lines[0], root) || lines[1] != "drwx------" {
		t.Errorf("call folder: %q", out)
	}
	if left, _ := os.ReadDir(root); len(left) != 0 {
		t.Errorf("call folders left behind: %d", len(left))
	}
	// Arguments reach the child as separate words, unchanged.
	args := []string{"--service=-x", "a b", "$(id)", "--json"}
	out, _, _ = e.Run(context.Background(), "args", args, nil)
	if want := "[--service=-x]\n[a b]\n[$(id)]\n[--json]\n"; string(out) != want {
		t.Errorf("args: %q", out)
	}
}

func TestExecRejectsBadCalls(t *testing.T) {
	p, sum := newEngine(t)
	e, err := NewExec(p, sum, 10*time.Second, nil)
	if err != nil {
		t.Fatal(err)
	}
	ctx := context.Background()
	bad := []struct {
		sub   string
		args  []string
		files map[string][]byte
	}{
		{"--help", nil, nil},
		{"../x", nil, nil},
		{"cat", []string{File("missing.json")}, nil},
		{"cat", []string{"a\x00b"}, nil},
		{"cat", nil, map[string][]byte{"../x.json": nil}},
		{"cat", nil, map[string][]byte{"a/b.json": nil}},
		{"cat", nil, map[string][]byte{".hidden": nil}},
	}
	for _, c := range bad {
		if _, _, err := e.Run(ctx, c.sub, c.args, c.files); err == nil {
			t.Errorf("%q %q %v: accepted", c.sub, c.args, c.files)
		}
	}
}

func TestExecExitStatusAndLimits(t *testing.T) {
	p, sum := newEngine(t)
	e, err := NewExec(p, sum, 300*time.Millisecond, nil)
	if err != nil {
		t.Fatal(err)
	}
	ctx := context.Background()
	out, exit, err := e.Run(ctx, "exit3", nil, nil)
	if err != nil || exit != 3 || !strings.Contains(string(out), "change.unknown_service") {
		t.Errorf("exit3: %q %d %v", out, exit, err)
	}
	if _, exit, err := e.Run(ctx, "nosuch", nil, nil); err != nil || exit != 2 {
		t.Errorf("unknown subcommand: %d %v", exit, err)
	}
	start := time.Now()
	if _, _, err := e.Run(ctx, "sleep", nil, nil); !errors.Is(err, ErrTimeout) {
		t.Errorf("sleep: %v", err)
	}
	if d := time.Since(start); d > 4*time.Second {
		t.Errorf("timeout took %v", d)
	}
	e.Timeout = 10 * time.Second
	e.MaxStdout = 1000
	if _, _, err := e.Run(ctx, "big", nil, nil); !errors.Is(err, ErrOutputTooLarge) {
		t.Errorf("big: %v", err)
	}
}

// TestExecEngineMismatch: a wrong sha256 is refused at start, and a binary replaced after the check is refused at
// the next call.
func TestExecEngineMismatch(t *testing.T) {
	p, sum := newEngine(t)
	other := strings.Repeat("0", 64)
	var em *EngineMismatchError
	if _, err := NewExec(p, other, 0, nil); !errors.As(err, &em) || em.Got != sum {
		t.Errorf("wrong sha256 at start: %v", err)
	}
	if _, err := NewExec("bin/rhobound", sum, 0, nil); err == nil {
		t.Error("relative path accepted")
	}
	e, err := NewExec(p, sum, 10*time.Second, nil)
	if err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(p, []byte(engine+"# changed\n"), 0o755); err != nil {
		t.Fatal(err)
	}
	if _, _, err := e.Run(context.Background(), "env", nil, nil); !errors.As(err, &em) {
		t.Errorf("replaced binary: %v", err)
	}
}

func TestFakeRecords(t *testing.T) {
	f := &Fake{Replies: map[string]Reply{"context": {Stdout: []byte(`{"schema":"rhobound-mcp.context/v1"}`)}}}
	ctx := context.Background()
	out, exit, err := f.Run(ctx, "context", []string{"--fit", File("fit.json"), "--json"}, map[string][]byte{"fit.json": []byte("F")})
	if err != nil || exit != 0 || !strings.Contains(string(out), "context/v1") {
		t.Fatalf("%q %d %v", out, exit, err)
	}
	if _, exit, _ := f.Run(ctx, "budget", nil, nil); exit != 2 {
		t.Errorf("unknown reply: exit %d", exit)
	}
	if _, _, err := f.Run(ctx, "context", []string{File("nope")}, nil); err == nil {
		t.Error("a placeholder without its file accepted")
	}
	calls := f.Calls()
	if len(calls) != 2 || calls[0].Sub != "context" {
		t.Fatalf("calls %+v", calls)
	}
	if b, ok := calls[0].FileFor("--fit"); !ok || string(b) != "F" {
		t.Errorf("FileFor: %q %v", b, ok)
	}
	if _, ok := calls[0].Flag("--json"); ok {
		t.Error("a bare flag has no value")
	}
}
