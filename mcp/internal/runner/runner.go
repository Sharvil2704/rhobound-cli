// SPDX-License-Identifier: Apache-2.0

// Package runner runs the rhobound CLI as a subprocess (ARCHITECTURE.md 3). The server never computes a number
// itself: every view comes from a CLI twin, and the JSON the CLI prints is the interface between the two modules.
//
// The engine is run by absolute path after its sha256 is checked (server.engine_mismatch on a difference), with a
// minimal environment that it does not inherit from the server (no AWS_* variable, no RHOBOUND_ESTIMATOR), in a
// fresh 0700 folder per call. Inputs are files in that folder, never command-line strings built from names
// (DEPLOY_AWS.md 2.2).
package runner

import (
	"bytes"
	"context"
	"crypto/sha256"
	"encoding/hex"
	"errors"
	"fmt"
	"io"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"strings"
	"sync"
	"time"
)

// Runner runs one subcommand of the rhobound CLI. files are written to the call's private folder; an argument equal
// to File(name) is replaced by that file's path. exit is the process's exit status; err is set only when the
// process could not run to an exit status (it could not start, timed out, or printed too much).
type Runner interface {
	Run(ctx context.Context, sub string, args []string, files map[string][]byte) (stdout []byte, exit int, err error)
}

// File returns the argument that stands for the input file name in a Run call. It begins with a NUL byte, which no
// real command-line argument can contain, so no string a caller passes can be mistaken for it.
func File(name string) string { return "\x00" + name }

// IsFile reports whether arg is a File placeholder, and for which name.
func IsFile(arg string) (name string, ok bool) {
	if strings.HasPrefix(arg, "\x00") {
		return arg[1:], true
	}
	return "", false
}

var (
	// ErrTimeout: the call ran past the runner's timeout and was killed.
	ErrTimeout = errors.New("runner: the engine ran past its timeout")
	// ErrOutputTooLarge: the engine printed more than MaxStdout bytes and was killed.
	ErrOutputTooLarge = errors.New("runner: the engine's output is too large")
)

// EngineMismatchError: the engine binary's sha256 differs from the configured one (server.engine_mismatch).
type EngineMismatchError struct{ Want, Got string }

func (e *EngineMismatchError) Error() string {
	return fmt.Sprintf("runner: engine sha256 is %s, configured %s", e.Got, e.Want)
}

var (
	subRE  = regexp.MustCompile(`^[a-z][a-z0-9-]{0,31}$`)
	fileRE = regexp.MustCompile(`^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$`)
	hexRE  = regexp.MustCompile(`^[0-9a-f]{64}$`)
	envRE  = regexp.MustCompile(`^[A-Z][A-Z0-9_]*=`)
)

// DefaultMaxStdout caps what one call may print: views are kilobytes, a report v2 tens of kilobytes.
const DefaultMaxStdout = 64 << 20

// Exec runs the real engine.
type Exec struct {
	Path    string        // absolute path of the rhobound binary
	SHA256  string        // its expected sha256, lower-case hex
	Timeout time.Duration // per call; 0 means no timeout beyond the caller's context

	// Env is the child's whole environment besides PATH, HOME, TMPDIR and LC_ALL, which Run sets: NAME=value
	// entries such as RHOBOUND_STATE. Nothing is inherited from the server.
	Env []string
	// TempRoot is where per-call folders are made ("" for the system's temporary folder).
	TempRoot string
	// MaxStdout caps the output of one call (DefaultMaxStdout when 0).
	MaxStdout int64
	// Stderr, when set, receives the engine's standard error. It may hold names from traces, so it is not for logs
	// that leave the machine.
	Stderr io.Writer

	mu       sync.Mutex
	verified os.FileInfo // the binary as last verified
}

// NewExec checks the engine at path against sha256 and returns a runner for it.
func NewExec(path, sha string, timeout time.Duration, env []string) (*Exec, error) {
	e := &Exec{Path: path, SHA256: sha, Timeout: timeout, Env: env}
	if err := e.Verify(); err != nil {
		return nil, err
	}
	return e, nil
}

// Verify hashes the engine binary and compares it with SHA256. It is called at start; Run calls it again only when
// the file changed since (size, modification time or identity).
func (e *Exec) Verify() error {
	if !filepath.IsAbs(e.Path) {
		return fmt.Errorf("runner: engine path %q is not absolute", e.Path)
	}
	if !hexRE.MatchString(e.SHA256) {
		return fmt.Errorf("runner: engine sha256 %q is not 64 lower-case hex digits", e.SHA256)
	}
	for _, kv := range e.Env {
		name, _, _ := strings.Cut(kv, "=")
		if !envRE.MatchString(kv) || strings.HasPrefix(name, "AWS_") || name == "RHOBOUND_ESTIMATOR" ||
			name == "PATH" || name == "HOME" || name == "TMPDIR" || name == "LC_ALL" {
			return fmt.Errorf("runner: environment entry %q is not allowed", name)
		}
	}
	f, err := os.Open(e.Path)
	if err != nil {
		return fmt.Errorf("runner: %w", err)
	}
	defer f.Close()
	info, err := f.Stat()
	if err != nil {
		return fmt.Errorf("runner: %w", err)
	}
	h := sha256.New()
	if _, err := io.Copy(h, f); err != nil {
		return fmt.Errorf("runner: %w", err)
	}
	if got := hex.EncodeToString(h.Sum(nil)); got != e.SHA256 {
		return &EngineMismatchError{Want: e.SHA256, Got: got}
	}
	e.mu.Lock()
	e.verified = info
	e.mu.Unlock()
	return nil
}

// current re-verifies the binary when it changed on disk since the last check.
func (e *Exec) current() error {
	info, err := os.Stat(e.Path)
	if err != nil {
		return fmt.Errorf("runner: %w", err)
	}
	e.mu.Lock()
	v := e.verified
	e.mu.Unlock()
	if v != nil && os.SameFile(v, info) && v.Size() == info.Size() && v.ModTime().Equal(info.ModTime()) {
		return nil
	}
	return e.Verify()
}

// Run implements Runner.
func (e *Exec) Run(ctx context.Context, sub string, args []string, files map[string][]byte) ([]byte, int, error) {
	if err := e.current(); err != nil {
		return nil, 0, err
	}
	if !subRE.MatchString(sub) {
		return nil, 0, fmt.Errorf("runner: %q is not a subcommand", sub)
	}
	dir, err := os.MkdirTemp(e.TempRoot, "rhobound-call-*")
	if err != nil {
		return nil, 0, fmt.Errorf("runner: %w", err)
	}
	defer os.RemoveAll(dir)
	if err := os.Chmod(dir, 0o700); err != nil {
		return nil, 0, fmt.Errorf("runner: %w", err)
	}
	argv, err := expand(args, files, dir)
	if err != nil {
		return nil, 0, err
	}
	for name, b := range files {
		if err := os.WriteFile(filepath.Join(dir, name), b, 0o600); err != nil {
			return nil, 0, fmt.Errorf("runner: %w", err)
		}
	}

	if e.Timeout > 0 {
		var cancel context.CancelFunc
		ctx, cancel = context.WithTimeout(ctx, e.Timeout)
		defer cancel()
	}
	cmd := exec.CommandContext(ctx, e.Path, append([]string{sub}, argv...)...)
	cmd.Dir = dir
	cmd.Env = append([]string{"PATH=/usr/bin:/bin", "HOME=" + dir, "TMPDIR=" + dir, "LC_ALL=C"}, e.Env...)
	cmd.WaitDelay = 2 * time.Second
	max := e.MaxStdout
	if max <= 0 {
		max = DefaultMaxStdout
	}
	out := &capped{max: max}
	cmd.Stdout = out
	cmd.Stderr = io.Discard
	if e.Stderr != nil {
		cmd.Stderr = e.Stderr
	}
	err = cmd.Run()
	switch {
	case out.over:
		return nil, 0, ErrOutputTooLarge
	case errors.Is(ctx.Err(), context.DeadlineExceeded):
		return nil, 0, ErrTimeout
	case ctx.Err() != nil:
		return nil, 0, fmt.Errorf("runner: %w", ctx.Err())
	}
	var ee *exec.ExitError
	if errors.As(err, &ee) {
		if code := ee.ExitCode(); code >= 0 {
			return out.Bytes(), code, nil
		}
		return nil, 0, fmt.Errorf("runner: engine killed: %v", ee)
	}
	if err != nil {
		return nil, 0, fmt.Errorf("runner: %w", err)
	}
	return out.Bytes(), 0, nil
}

// expand checks the call's file names and replaces each File placeholder with its path in dir.
func expand(args []string, files map[string][]byte, dir string) ([]string, error) {
	for name := range files {
		if !fileRE.MatchString(name) || name == "." || name == ".." {
			return nil, fmt.Errorf("runner: %q is not a plain file name", name)
		}
	}
	argv := make([]string, len(args))
	for i, a := range args {
		if name, ok := IsFile(a); ok {
			if _, have := files[name]; !have {
				return nil, fmt.Errorf("runner: argument %d names file %q, which the call does not carry", i, name)
			}
			argv[i] = filepath.Join(dir, name)
			continue
		}
		if strings.ContainsRune(a, 0) {
			return nil, fmt.Errorf("runner: argument %d holds a NUL byte", i)
		}
		argv[i] = a
	}
	return argv, nil
}

// capped is a buffer that stops accepting bytes past max (the process then fails on its next write). The buffer is
// a field, not embedded: an embedded bytes.Buffer would give capped a ReadFrom method, which io.Copy prefers to
// Write, and the cap would never be checked.
type capped struct {
	buf  bytes.Buffer
	max  int64
	over bool
}

func (c *capped) Write(p []byte) (int, error) {
	if int64(c.buf.Len()+len(p)) > c.max {
		c.over = true
		return 0, ErrOutputTooLarge
	}
	return c.buf.Write(p)
}

func (c *capped) Bytes() []byte { return c.buf.Bytes() }
