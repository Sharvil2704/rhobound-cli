// SPDX-License-Identifier: Apache-2.0

package runner

import (
	"context"
	"fmt"
	"maps"
	"slices"
	"strings"
	"sync"
)

// Call is one recorded Run call. Args keep their File placeholders; Files are copies of the inputs.
type Call struct {
	Sub   string
	Args  []string
	Files map[string][]byte
}

// Flag returns the value after the flag name in the call's arguments ("--name VALUE" or "--name=VALUE"), and
// whether the flag is present.
func (c Call) Flag(name string) (string, bool) {
	for i, a := range c.Args {
		if a == name && i+1 < len(c.Args) {
			return c.Args[i+1], true
		}
		if v, ok := strings.CutPrefix(a, name+"="); ok {
			return v, true
		}
	}
	return "", false
}

// FileFor returns the bytes of the input file a flag points to through a File placeholder.
func (c Call) FileFor(flag string) ([]byte, bool) {
	v, ok := c.Flag(flag)
	if !ok {
		return nil, false
	}
	name, ok := IsFile(v)
	if !ok {
		return nil, false
	}
	b, ok := c.Files[name]
	return b, ok
}

// Reply is what a Fake answers for a subcommand.
type Reply struct {
	Stdout []byte
	Exit   int
	Err    error
}

// Fake is a recording Runner for tests. Handle, when set, answers every call; otherwise Replies answers by
// subcommand, and an unknown subcommand is exit 2 with no output, as the CLI does.
type Fake struct {
	Handle  func(ctx context.Context, c Call) Reply
	Replies map[string]Reply

	mu    sync.Mutex
	calls []Call
}

// Run implements Runner. It applies the same checks to file names and placeholders as Exec.
func (f *Fake) Run(ctx context.Context, sub string, args []string, files map[string][]byte) ([]byte, int, error) {
	if !subRE.MatchString(sub) {
		return nil, 0, fmt.Errorf("runner: %q is not a subcommand", sub)
	}
	if _, err := expand(args, files, "/nonexistent"); err != nil {
		return nil, 0, err
	}
	c := Call{Sub: sub, Args: slices.Clone(args), Files: map[string][]byte{}}
	for k, v := range files {
		c.Files[k] = slices.Clone(v)
	}
	f.mu.Lock()
	f.calls = append(f.calls, c)
	f.mu.Unlock()
	var r Reply
	switch {
	case f.Handle != nil:
		r = f.Handle(ctx, c)
	case f.Replies != nil:
		var ok bool
		if r, ok = f.Replies[sub]; !ok {
			r = Reply{Exit: 2}
		}
	default:
		r = Reply{Exit: 2}
	}
	return slices.Clone(r.Stdout), r.Exit, r.Err
}

// Calls returns the calls so far, in order.
func (f *Fake) Calls() []Call {
	f.mu.Lock()
	defer f.mu.Unlock()
	out := make([]Call, len(f.calls))
	for i, c := range f.calls {
		out[i] = Call{Sub: c.Sub, Args: slices.Clone(c.Args), Files: maps.Clone(c.Files)}
	}
	return out
}
