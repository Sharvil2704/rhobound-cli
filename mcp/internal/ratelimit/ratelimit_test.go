// SPDX-License-Identifier: Apache-2.0

package ratelimit

import (
	"sync"
	"testing"
	"time"
)

func TestBucket(t *testing.T) {
	now := time.Date(2026, 10, 26, 12, 0, 0, 0, time.UTC)
	l := New(Rules{Tools: map[string]Bucket{"predict": {Burst: 3, Every: time.Second}}})
	l.Now = func() time.Time { return now }
	for i := 0; i < 3; i++ {
		if ok, _ := l.Allow("alice", "predict"); !ok {
			t.Fatalf("call %d of a burst of 3 refused", i+1)
		}
	}
	ok, wait := l.Allow("alice", "predict")
	if ok || wait != time.Second {
		t.Fatalf("the fourth call: %v, retry after %v", ok, wait)
	}
	// Another principal and another tool have their own buckets; an unlisted tool is not limited.
	if ok, _ := l.Allow("bob", "predict"); !ok {
		t.Error("bob is limited by alice's calls")
	}
	if ok, _ := l.Allow("alice", "context"); !ok {
		t.Error("an unlisted tool is limited")
	}
	// Tokens come back at the bucket's rate, never above its burst.
	now = now.Add(400 * time.Millisecond)
	if ok, wait := l.Allow("alice", "predict"); ok || wait != 600*time.Millisecond {
		t.Errorf("after 0.4 s: %v, %v", ok, wait)
	}
	now = now.Add(600 * time.Millisecond)
	if ok, _ := l.Allow("alice", "predict"); !ok {
		t.Error("after 1 s, no token")
	}
	now = now.Add(time.Hour)
	n := 0
	for {
		if ok, _ := l.Allow("alice", "predict"); !ok {
			break
		}
		n++
	}
	if n != 3 {
		t.Errorf("after an hour, %d calls at once; the burst is 3", n)
	}
}

// TestPrune: a bucket is forgotten once it has refilled to its burst, and a forgotten bucket allows what a new one
// does; one still refilling is kept, with its tokens.
func TestPrune(t *testing.T) {
	now := time.Date(2026, 10, 26, 12, 0, 0, 0, time.UTC)
	l := New(Rules{Tools: map[string]Bucket{"predict": {Burst: 2, Every: time.Second}}})
	l.Now = func() time.Time { return now }
	l.Allow("alice", "predict")
	l.Allow("bob", "predict")
	l.Allow("bob", "predict")
	now = now.Add(time.Second)
	if n := l.Prune(); n != 1 || len(l.buckets) != 1 {
		t.Fatalf("pruned %d, kept %v: only alice's bucket is full again", n, l.buckets)
	}
	if ok, wait := l.Allow("bob", "predict"); !ok {
		t.Errorf("bob's token after 1 s: %v", wait)
	}
	if ok, _ := l.Allow("bob", "predict"); ok {
		t.Error("bob's bucket was refilled by the prune")
	}
	for i := 0; i < 2; i++ {
		if ok, _ := l.Allow("alice", "predict"); !ok {
			t.Errorf("alice's call %d after her bucket was forgotten refused", i+1)
		}
	}
	now = now.Add(time.Hour)
	if n := l.Prune(); n != 2 || len(l.buckets) != 0 {
		t.Errorf("after an hour, pruned %d, kept %v", n, l.buckets)
	}
}

func TestFits(t *testing.T) {
	l := New(Rules{MaxFits: 2})
	d1, ok1 := l.StartFit("alice")
	d2, ok2 := l.StartFit("alice")
	if !ok1 || !ok2 {
		t.Fatal("two fits refused")
	}
	if _, ok := l.StartFit("alice"); ok {
		t.Error("a third concurrent fit allowed")
	}
	if d, ok := l.StartFit("bob"); !ok {
		t.Error("bob is limited by alice's fits")
	} else {
		d()
	}
	d1()
	d1() // done twice counts once
	d3, ok := l.StartFit("alice")
	if !ok {
		t.Fatal("a fit after one ended refused")
	}
	if _, ok := l.StartFit("alice"); ok {
		t.Error("done counted twice")
	}
	d2()
	d3()
	if len(l.fits) != 0 {
		t.Errorf("counts left: %v", l.fits)
	}
}

func TestConcurrent(t *testing.T) {
	l := New(Default)
	now := time.Now()
	l.Now = func() time.Time { return now }
	var wg sync.WaitGroup
	allowed := make(chan bool, 100)
	for i := 0; i < 100; i++ {
		wg.Add(1)
		go func() {
			defer wg.Done()
			ok, _ := l.Allow("alice", "budget")
			allowed <- ok
		}()
	}
	wg.Wait()
	close(allowed)
	n := 0
	for ok := range allowed {
		if ok {
			n++
		}
	}
	if n != Default.Tools["budget"].Burst {
		t.Errorf("%d of 100 simultaneous calls allowed; the burst is %d", n, Default.Tools["budget"].Burst)
	}
}
