// SPDX-License-Identifier: Apache-2.0

//go:build unix

package main

import (
	"os"
	"syscall"
)

// openNoFollow opens a file for reading without following a symbolic link and without blocking on a FIFO.
func openNoFollow(p string) (*os.File, error) {
	return os.OpenFile(p, os.O_RDONLY|syscall.O_NOFOLLOW|syscall.O_NONBLOCK, 0)
}

// openNonBlock opens a file for reading, following links, without blocking on a FIFO.
func openNonBlock(p string) (*os.File, error) {
	return os.OpenFile(p, os.O_RDONLY|syscall.O_NONBLOCK, 0)
}

// ownedByMe reports whether the file belongs to the process's user.
func ownedByMe(fi os.FileInfo) bool {
	st, ok := fi.Sys().(*syscall.Stat_t)
	return ok && int(st.Uid) == os.Geteuid()
}
