// SPDX-License-Identifier: Apache-2.0

package objstore

import (
	"context"
	"errors"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"testing"
	"time"
)

func TestPartitionRoundTrip(t *testing.T) {
	at := time.Date(2026, 10, 26, 12, 7, 31, 0, time.UTC)
	p := Partition(at)
	if p != "year=2026/month=10/day=26/hour=12/minute=07/" {
		t.Fatalf("partition %q", p)
	}
	got, ok := ParsePartition("env=prod/" + p + "traces_x.json.gz")
	if !ok || !got.Equal(at.Truncate(time.Minute)) {
		t.Fatalf("parsed %v %v, want %v", got, ok, at.Truncate(time.Minute))
	}
	// a partition written in another location reads as UTC: the offset the fetcher derives
	loc := time.FixedZone("UTC+2", 2*3600)
	got, _ = ParsePartition(Partition(at.In(loc)))
	if d := got.Sub(at.Truncate(time.Minute)); d != 2*time.Hour {
		t.Fatalf("local partition reads %v from UTC, want 2h", d)
	}
	for _, bad := range []string{"year=2026/month=13/day=01/hour=00/minute=00/", "year=2026/month=10/day=26/hour=12/",
		"xyear=2026/month=10/day=26/hour=12/minute=00/"} {
		if _, ok := ParsePartition(bad); ok {
			t.Errorf("%q parsed as a partition", bad)
		}
	}
}

func TestDirListsOnlyThePrefix(t *testing.T) {
	d := Dir{Root: t.TempDir()}
	keys := []string{
		"env=prod/year=2026/month=10/day=26/hour=12/minute=00/traces_a.json.gz",
		"env=prod/year=2026/month=10/day=26/hour=12/minute=00/traces_b.json.gz",
		"env=prod/year=2026/month=10/day=26/hour=12/minute=01/traces_c.json.gz",
		"env=prod2/year=2026/month=10/day=26/hour=12/minute=00/traces_d.json.gz",
	}
	for i, k := range keys {
		if err := d.Put(k, []byte(fmt.Sprintf("object %d", i))); err != nil {
			t.Fatal(err)
		}
	}
	ctx := context.Background()
	got, err := d.List(ctx, "env=prod/year=2026/month=10/day=26/hour=12/minute=00/")
	if err != nil {
		t.Fatal(err)
	}
	if len(got) != 2 || got[0].Key != keys[0] || got[1].Key != keys[1] || got[0].Size != 8 {
		t.Fatalf("minute listing %+v", got)
	}
	got, _ = d.List(ctx, "env=prod/")
	if len(got) != 3 {
		t.Fatalf("env=prod/ lists %d objects, want 3 (not env=prod2's)", len(got))
	}
	got, _ = d.List(ctx, "env=prod")
	if len(got) != 4 {
		t.Fatalf("env=prod without the slash lists %d, want 4", len(got))
	}
	got, err = d.List(ctx, "env=none/year=2026/")
	if err != nil || len(got) != 0 {
		t.Fatalf("missing folder: %v %v", got, err)
	}
	b, err := d.Head(ctx, keys[2], 3)
	if err != nil || string(b) != "obj" {
		t.Fatalf("head %q %v", b, err)
	}
	rc, err := d.Open(ctx, keys[2])
	if err != nil {
		t.Fatal(err)
	}
	all, _ := io.ReadAll(rc)
	rc.Close()
	if string(all) != "object 2" {
		t.Fatalf("open read %q", all)
	}
	if _, err := d.Open(ctx, "env=prod/nothing.json.gz"); !errors.Is(err, ErrNotFound) {
		t.Fatalf("missing key: %v, want ErrNotFound", err)
	}
}

func TestDirNeverLeavesItsRoot(t *testing.T) {
	outer := t.TempDir()
	if err := os.WriteFile(filepath.Join(outer, "secret.json"), []byte("{}"), 0o600); err != nil {
		t.Fatal(err)
	}
	root := filepath.Join(outer, "store")
	if err := os.Mkdir(root, 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.Symlink(filepath.Join(outer, "secret.json"), filepath.Join(root, "link.json")); err != nil {
		t.Skip("no symbolic links here:", err)
	}
	d := Dir{Root: root}
	ctx := context.Background()
	for _, k := range []string{"../secret.json", "/etc/hostname", "a/../../secret.json", "link.json"} {
		if rc, err := d.Open(ctx, k); err == nil {
			rc.Close()
			t.Errorf("Open(%q) succeeded outside the root", k)
		}
	}
	if err := d.Put("../escape.json", []byte("x")); err == nil {
		t.Error("Put outside the root succeeded")
	}
	got, err := d.List(ctx, "")
	if err != nil {
		t.Fatal(err)
	}
	if len(got) != 0 {
		t.Errorf("a symbolic link was listed: %+v", got)
	}
}

func TestMemPagesItsListing(t *testing.T) {
	m := NewMem()
	m.PageSize = 1000
	for i := range 2500 {
		m.Put(fmt.Sprintf("p/%05d.json.gz", i), []byte{1})
	}
	m.Put("q/other.json.gz", []byte{1})
	got, err := m.List(context.Background(), "p/")
	if err != nil {
		t.Fatal(err)
	}
	if len(got) != 2500 || got[0].Key != "p/00000.json.gz" || got[2499].Key != "p/02499.json.gz" {
		t.Fatalf("listing of %d keys, first %q", len(got), got[0].Key)
	}
	if s := m.Stats(); s.Lists != 1 || s.Pages != 3 {
		t.Fatalf("stats %+v, want one listing of 3 pages", s)
	}
	if got[0].ETag == "" || got[0].ETag[0] != '"' {
		t.Fatalf("etag %q, want a quoted MD5 as S3 gives", got[0].ETag)
	}
}

func TestMemInjectsLateAndRepeatedObjects(t *testing.T) {
	m := NewMem()
	ctx := context.Background()
	m.Put("p/a.json.gz", []byte("a"))
	m.PutLate("p/b.json.gz", []byte("b"), 1)
	m.RepeatInListing("p/a.json.gz")
	got, _ := m.List(ctx, "p/")
	if len(got) != 2 || got[0].Key != "p/a.json.gz" || got[1].Key != "p/a.json.gz" {
		t.Fatalf("first listing %+v: want a twice and no late object", got)
	}
	got, _ = m.List(ctx, "p/")
	if len(got) != 3 || got[2].Key != "p/b.json.gz" {
		t.Fatalf("second listing %+v: want the late object", got)
	}
	boom := errors.New("boom")
	m.FailOn("p/a.json.gz", boom)
	if _, err := m.Open(ctx, "p/a.json.gz"); !errors.Is(err, boom) {
		t.Fatalf("open: %v", err)
	}
	if b, err := m.Head(ctx, "p/b.json.gz", 10); err != nil || string(b) != "b" {
		t.Fatalf("head %q %v", b, err)
	}
	if s := m.Stats(); s.Opens != 1 || s.Heads != 1 || s.Lists != 2 {
		t.Fatalf("stats %+v", s)
	}
}
