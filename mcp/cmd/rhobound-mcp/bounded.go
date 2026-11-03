// SPDX-License-Identifier: Apache-2.0

package main

import (
	"fmt"
	"io"
	"path/filepath"
	"strings"
)

// readBounded reads a regular file of at most max bytes: opened without blocking (a FIFO), checked after the open
// (a device such as /dev/zero, or a file swapped in after a check, is refused), and read through a limit. follow says
// whether a symbolic link may be followed (a dotfiles manager's settings file is one; a marker never is).
func readBounded(p string, max int64, follow bool) ([]byte, error) {
	open := openNoFollow
	if follow {
		open = openNonBlock
	}
	f, err := open(p)
	if err != nil {
		return nil, err
	}
	defer f.Close()
	fi, err := f.Stat()
	if err != nil {
		return nil, err
	}
	if !fi.Mode().IsRegular() {
		return nil, fmt.Errorf("%s is not a regular file", p)
	}
	if fi.Size() > max {
		return nil, fmt.Errorf("%s is larger than %d bytes", p, max)
	}
	b, err := io.ReadAll(io.LimitReader(f, max+1))
	if err != nil {
		return nil, err
	}
	if int64(len(b)) > max {
		return nil, fmt.Errorf("%s is larger than %d bytes", p, max)
	}
	return b, nil
}

// physical is p with its existing leading part's links resolved (the rest kept as written): where p is, or would be.
func physical(p string) string {
	p = filepath.Clean(p)
	rest := ""
	for q := p; ; {
		if r, err := filepath.EvalSymlinks(q); err == nil {
			return filepath.Join(r, rest)
		}
		up := filepath.Dir(q)
		if up == q {
			return p
		}
		rest = filepath.Join(filepath.Base(q), rest)
		q = up
	}
}

// under reports whether p lies in folder dir (or is dir), comparing both as written and with links resolved.
func under(p, dir string) bool {
	if p == "" || dir == "" {
		return false
	}
	in := func(a, b string) bool {
		a, b = filepath.Clean(a), filepath.Clean(b)
		return a == b || strings.HasPrefix(a, strings.TrimSuffix(b, string(filepath.Separator))+string(filepath.Separator))
	}
	return in(p, dir) || in(physical(p), physical(dir)) || in(physical(p), dir) || in(p, physical(dir))
}
