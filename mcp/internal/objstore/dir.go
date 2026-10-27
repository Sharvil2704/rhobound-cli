// SPDX-License-Identifier: Apache-2.0

package objstore

import (
	"context"
	"errors"
	"fmt"
	"io"
	"io/fs"
	"os"
	"path"
	"sort"
	"strings"
)

// Dir is a store on the local file system: the key k is the file Root/k, with "/" as the separator. Keys are
// resolved through os.OpenRoot, so neither ".." nor a symbolic link reaches a file outside Root. Only regular
// files are listed, and Dir has no ETags.
type Dir struct {
	Root string
}

// Kind names the store in a capture manifest's source.
func (d Dir) Kind() string { return "dir" }

// List walks only the folders that can hold a key with the prefix: a minute partition's listing reads one folder.
func (d Dir) List(ctx context.Context, prefix string) ([]Object, error) {
	root, err := os.OpenRoot(d.Root)
	if err != nil {
		return nil, err
	}
	defer root.Close()
	start := "."
	if i := strings.LastIndex(prefix, "/"); i > 0 {
		start = prefix[:i]
	}
	if !fs.ValidPath(start) {
		return nil, fmt.Errorf("objstore: invalid prefix %q", prefix)
	}
	var out []Object
	err = fs.WalkDir(root.FS(), start, func(p string, e fs.DirEntry, err error) error {
		if err != nil {
			if p == start && errors.Is(err, fs.ErrNotExist) {
				return fs.SkipAll
			}
			return err
		}
		if err := ctx.Err(); err != nil {
			return err
		}
		if e.IsDir() {
			if p != "." && !strings.HasPrefix(p+"/", prefix) && !strings.HasPrefix(prefix, p+"/") {
				return fs.SkipDir
			}
			return nil
		}
		if !e.Type().IsRegular() || !strings.HasPrefix(p, prefix) {
			return nil
		}
		info, err := e.Info()
		if err != nil {
			return err
		}
		out = append(out, Object{Key: p, Size: info.Size()})
		return nil
	})
	if err != nil {
		return nil, err
	}
	sort.Slice(out, func(i, j int) bool { return out[i].Key < out[j].Key })
	return out, nil
}

// Open opens the regular file under the key.
func (d Dir) Open(ctx context.Context, key string) (io.ReadCloser, error) {
	if err := ctx.Err(); err != nil {
		return nil, err
	}
	if !fs.ValidPath(key) || key == "." {
		return nil, fmt.Errorf("objstore: invalid key %q", key)
	}
	root, err := os.OpenRoot(d.Root)
	if err != nil {
		return nil, err
	}
	defer root.Close()
	f, err := root.Open(key)
	if errors.Is(err, fs.ErrNotExist) {
		return nil, fmt.Errorf("%s: %w", key, ErrNotFound)
	}
	if err != nil {
		return nil, err
	}
	if st, err := f.Stat(); err != nil || !st.Mode().IsRegular() {
		f.Close()
		return nil, fmt.Errorf("%s: %w", key, ErrNotFound)
	}
	return f, nil
}

// Head reads the first n bytes of the file under the key.
func (d Dir) Head(ctx context.Context, key string, n int64) ([]byte, error) {
	rc, err := d.Open(ctx, key)
	if err != nil {
		return nil, err
	}
	defer rc.Close()
	return io.ReadAll(io.LimitReader(rc, n))
}

// Put writes an object, creating its folders: for tests and for local tools that lay out a store.
func (d Dir) Put(key string, data []byte) error {
	if !fs.ValidPath(key) || key == "." {
		return fmt.Errorf("objstore: invalid key %q", key)
	}
	root, err := os.OpenRoot(d.Root)
	if err != nil {
		return err
	}
	defer root.Close()
	if dir := path.Dir(key); dir != "." {
		if err := root.MkdirAll(dir, 0o755); err != nil {
			return err
		}
	}
	return root.WriteFile(key, data, 0o644)
}
