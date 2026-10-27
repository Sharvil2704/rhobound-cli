// SPDX-License-Identifier: Apache-2.0

// Package objstore is the object store the window fetcher reads: a listing of the keys under a prefix, whole
// objects, and the first bytes of an object for sniffing. Dir is a folder laid out as the OpenTelemetry
// Collector's S3 exporter lays out its objects, so the same fetcher runs locally; Mem is an in-memory fake that can
// inject the store defects the fetcher must catch. The S3 binding needs the AWS SDK and lives outside this module's
// first build.
package objstore

import (
	"context"
	"errors"
	"fmt"
	"io"
	"regexp"
	"strconv"
	"time"
)

// Object is one listed object. ETag is the store's own tag (S3: the quoted MD5 of a single-part upload); a store
// without tags leaves it empty.
type Object struct {
	Key  string
	Size int64
	ETag string
}

// Store is a read-only object store.
type Store interface {
	// List returns every object whose key starts with prefix, sorted by key. The listing is complete: a store
	// whose API pages its listings pages internally.
	List(ctx context.Context, prefix string) ([]Object, error)
	// Open opens one object.
	Open(ctx context.Context, key string) (io.ReadCloser, error)
	// Head returns the first n bytes of an object, or all of it when it is shorter.
	Head(ctx context.Context, key string, n int64) ([]byte, error)
}

// ErrNotFound is returned, wrapped, by Open and Head for a key the store does not hold.
var ErrNotFound = errors.New("object not found")

// Partition returns the minute partition of t in t's own location, as the S3 exporter writes it with its default
// s3_partition_format "year=%Y/month=%m/day=%d/hour=%H/minute=%M", followed by "/". The exporter's own default
// location is Local; the data contract requires s3_partition_timezone UTC, so callers pass UTC times.
func Partition(t time.Time) string {
	return fmt.Sprintf("year=%04d/month=%02d/day=%02d/hour=%02d/minute=%02d/",
		t.Year(), int(t.Month()), t.Day(), t.Hour(), t.Minute())
}

var partitionRE = regexp.MustCompile(`(?:^|/)year=(\d{4})/month=(\d{2})/day=(\d{2})/hour=(\d{2})/minute=(\d{2})/`)

// ParsePartition finds the first minute partition in key and returns its minute, read as UTC.
func ParsePartition(key string) (time.Time, bool) {
	m := partitionRE.FindStringSubmatch(key)
	if m == nil {
		return time.Time{}, false
	}
	var v [5]int
	for i := range v {
		v[i], _ = strconv.Atoi(m[i+1])
	}
	t := time.Date(v[0], time.Month(v[1]), v[2], v[3], v[4], 0, 0, time.UTC)
	// time.Date normalizes month 13 or minute 61; such a key is not a partition
	if t.Year() != v[0] || int(t.Month()) != v[1] || t.Day() != v[2] || t.Hour() != v[3] || t.Minute() != v[4] {
		return time.Time{}, false
	}
	return t, true
}
