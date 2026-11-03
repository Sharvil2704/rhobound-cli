// SPDX-License-Identifier: Apache-2.0

//go:build !unix

package main

import "os"

// openNoFollow opens a file for reading (the caller has checked with Lstat that it is a regular file).
func openNoFollow(p string) (*os.File, error) { return os.Open(p) }

// openNonBlock opens a file for reading.
func openNonBlock(p string) (*os.File, error) { return os.Open(p) }

// ownedByMe has no owner to compare on this platform.
func ownedByMe(os.FileInfo) bool { return true }
