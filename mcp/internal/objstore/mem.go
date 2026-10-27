// SPDX-License-Identifier: Apache-2.0

package objstore

import (
	"bytes"
	"context"
	"crypto/md5"
	"encoding/hex"
	"fmt"
	"io"
	"sort"
	"strings"
	"sync"
)

// Mem is an in-memory fake of an S3 bucket for tests. It pages its listings internally, as the S3 binding must,
// counts the calls it serves, and injects the defects a real store shows: objects that appear only after some
// listings (late uploads), a key repeated in a listing, and failing reads. Wrong suffixes, local-time partitions,
// duplicate keys and non-gzip ".gz" objects are just objects put under such keys. Safe for concurrent use.
type Mem struct {
	// PageSize is the number of keys one listing page holds (S3's ListObjectsV2 returns at most 1,000); 0 means
	// 1,000.
	PageSize int

	mu     sync.Mutex
	objs   map[string]memObject
	late   []lateObject
	repeat map[string]bool
	fail   map[string]error
	stats  Stats
}

// Stats counts the calls a Mem served. Pages counts listing pages, Lists the calls to List.
type Stats struct {
	Lists, Pages, Heads, Opens int
}

type memObject struct {
	data []byte
	etag string
}

type lateObject struct {
	key   string
	obj   memObject
	after int
}

// NewMem returns an empty store.
func NewMem() *Mem { return &Mem{} }

// Kind names the store in a capture manifest's source: Mem stands for S3.
func (m *Mem) Kind() string { return "s3" }

func newMemObject(data []byte) memObject {
	sum := md5.Sum(data)
	return memObject{data: bytes.Clone(data), etag: `"` + hex.EncodeToString(sum[:]) + `"`}
}

// Put stores an object, replacing any object under the key.
func (m *Mem) Put(key string, data []byte) {
	m.mu.Lock()
	defer m.mu.Unlock()
	if m.objs == nil {
		m.objs = map[string]memObject{}
	}
	m.objs[key] = newMemObject(data)
}

// PutLate stores an object that the first afterLists calls to List do not see: an upload that lands while a
// fetch is running.
func (m *Mem) PutLate(key string, data []byte, afterLists int) {
	m.mu.Lock()
	defer m.mu.Unlock()
	m.late = append(m.late, lateObject{key, newMemObject(data), afterLists})
}

// RepeatInListing makes every listing that holds the key return it twice.
func (m *Mem) RepeatInListing(key string) {
	m.mu.Lock()
	defer m.mu.Unlock()
	if m.repeat == nil {
		m.repeat = map[string]bool{}
	}
	m.repeat[key] = true
}

// FailOn makes Open and Head of the key return err.
func (m *Mem) FailOn(key string, err error) {
	m.mu.Lock()
	defer m.mu.Unlock()
	if m.fail == nil {
		m.fail = map[string]error{}
	}
	m.fail[key] = err
}

// Stats returns the calls served so far.
func (m *Mem) Stats() Stats {
	m.mu.Lock()
	defer m.mu.Unlock()
	return m.stats
}

// List returns the objects under the prefix, sorted by key, one page at a time.
func (m *Mem) List(ctx context.Context, prefix string) ([]Object, error) {
	if err := ctx.Err(); err != nil {
		return nil, err
	}
	m.mu.Lock()
	defer m.mu.Unlock()
	m.stats.Lists++
	kept := m.late[:0]
	for _, l := range m.late {
		if l.after < m.stats.Lists {
			if m.objs == nil {
				m.objs = map[string]memObject{}
			}
			m.objs[l.key] = l.obj
		} else {
			kept = append(kept, l)
		}
	}
	m.late = kept
	var keys []string
	for k := range m.objs {
		if strings.HasPrefix(k, prefix) {
			keys = append(keys, k)
		}
	}
	sort.Strings(keys)
	page := m.PageSize
	if page <= 0 {
		page = 1000
	}
	var out []Object
	for at := 0; ; at += page {
		m.stats.Pages++
		for _, k := range keys[at:min(at+page, len(keys))] {
			o := Object{Key: k, Size: int64(len(m.objs[k].data)), ETag: m.objs[k].etag}
			out = append(out, o)
			if m.repeat[k] {
				out = append(out, o)
			}
		}
		if at+page >= len(keys) {
			break
		}
	}
	return out, nil
}

func (m *Mem) get(key string) ([]byte, error) {
	if err := m.fail[key]; err != nil {
		return nil, err
	}
	o, ok := m.objs[key]
	if !ok {
		return nil, fmt.Errorf("%s: %w", key, ErrNotFound)
	}
	return o.data, nil
}

// Open returns the object's bytes.
func (m *Mem) Open(ctx context.Context, key string) (io.ReadCloser, error) {
	if err := ctx.Err(); err != nil {
		return nil, err
	}
	m.mu.Lock()
	defer m.mu.Unlock()
	m.stats.Opens++
	b, err := m.get(key)
	if err != nil {
		return nil, err
	}
	return io.NopCloser(bytes.NewReader(b)), nil
}

// Head returns the object's first n bytes.
func (m *Mem) Head(ctx context.Context, key string, n int64) ([]byte, error) {
	if err := ctx.Err(); err != nil {
		return nil, err
	}
	m.mu.Lock()
	defer m.mu.Unlock()
	m.stats.Heads++
	b, err := m.get(key)
	if err != nil {
		return nil, err
	}
	return bytes.Clone(b[:min(int64(len(b)), max(n, 0))]), nil
}
