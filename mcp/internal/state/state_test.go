// SPDX-License-Identifier: Apache-2.0

package state

import (
	"context"
	"encoding/json"
	"errors"
	"os"
	"path/filepath"
	"regexp"
	"strings"
	"sync"
	"testing"
	"time"
)

// clock is a settable time source.
type clock struct {
	mu sync.Mutex
	t  time.Time
}

func (c *clock) now() time.Time { c.mu.Lock(); defer c.mu.Unlock(); return c.t }
func (c *clock) add(d time.Duration) {
	c.mu.Lock()
	c.t = c.t.Add(d)
	c.mu.Unlock()
}

func newClock() *clock { return &clock{t: time.Date(2026, 10, 26, 12, 0, 0, 0, time.UTC)} }

// stores runs f against a Mem and a Dir store sharing one clock each.
func stores(t *testing.T, f func(t *testing.T, s Store, c *clock)) {
	t.Run("mem", func(t *testing.T) {
		c := newClock()
		f(t, NewMem(c.now), c)
	})
	t.Run("dir", func(t *testing.T) {
		c := newClock()
		d, err := NewDir(t.TempDir(), c.now)
		if err != nil {
			t.Fatal(err)
		}
		f(t, d, c)
	})
}

var handleRE2 = regexp.MustCompile(`^(fit|pred|job|ab|ver)_[0-9A-HJKMNP-TV-Z]{26}$`) // defs.v1.json Handle

func TestNewHandle(t *testing.T) {
	now := time.Date(2026, 10, 26, 12, 0, 0, 0, time.UTC)
	seen := map[string]bool{}
	for _, k := range []string{KindFit, KindPrediction, KindJob, KindAB, KindVerified} {
		for i := 0; i < 200; i++ {
			h, err := NewHandle(k, now)
			if err != nil {
				t.Fatal(err)
			}
			if !handleRE2.MatchString(h) || HandleKind(h) != k || seen[h] {
				t.Fatalf("handle %q (kind %q, seen %v)", h, HandleKind(h), seen[h])
			}
			seen[h] = true
		}
	}
	if _, err := NewHandle("x", now); err == nil {
		t.Error("kind x accepted")
	}
	// The first ten digits are the time: later handles sort after earlier ones.
	a, _ := NewHandle(KindFit, now)
	b, _ := NewHandle(KindFit, now.Add(time.Millisecond))
	if a[4:14] >= b[4:14] {
		t.Errorf("time prefix does not increase: %s, %s", a, b)
	}
	// Known value: all-zero random bits at the Unix epoch, and all ones.
	if got := ulid([16]byte{}); got != strings.Repeat("0", 26) {
		t.Errorf("ulid(0) = %s", got)
	}
	var ones [16]byte
	for i := range ones {
		ones[i] = 0xff
	}
	if got := ulid(ones); got != "7"+strings.Repeat("Z", 25) {
		t.Errorf("ulid(max) = %s", got)
	}
}

func TestCodesMatchPattern(t *testing.T) {
	re := regexp.MustCompile(`^[a-z]+\.[a-z0-9_]+$`)
	for _, c := range []string{CodeHandleUnknown, CodeHandleExpired, CodeJobTimeout, CodeRateLimited, CodeEngineMismatch,
		CodeProfileNotFound, CodeUnsupportedOp, CodeFitExpired, CodeFitNoBaseline, CodePolicyNotNamed, CodePolicyUnknown} {
		if !re.MatchString(c) {
			t.Errorf("%q does not match the code pattern", c)
		}
	}
}

func TestRefusalJSON(t *testing.T) {
	r := Refusal{Code: CodeRateLimited, Reason: "a <b> & c", Fix: "wait", Numbers: map[string]float64{"retry_after_ms": 1500}}
	want := `{"error":{"code":"rate.limited","fix":"wait","numbers":{"retry_after_ms":1500},"reason":"a <b> & c"}}`
	if got := string(r.Envelope()); got != want {
		t.Errorf("got  %s\nwant %s", got, want)
	}
}

func TestArtifacts(t *testing.T) {
	stores(t, func(t *testing.T, s Store, _ *clock) {
		ctx := context.Background()
		b := []byte(`{"schema":"rhobound.fit/v1"}`)
		d, err := s.PutArtifact(ctx, "fit", b)
		if err != nil {
			t.Fatal(err)
		}
		if d != Digest(b) || !strings.HasPrefix(d, "sha256:") {
			t.Errorf("digest %s", d)
		}
		if d2, _ := s.PutArtifact(ctx, "fit", b); d2 != d {
			t.Errorf("second put: %s", d2)
		}
		got, err := s.GetArtifact(ctx, d)
		if err != nil || string(got) != string(b) {
			t.Errorf("get: %q, %v", got, err)
		}
		if _, err := s.GetArtifact(ctx, Digest([]byte("other"))); !errors.Is(err, ErrNotFound) {
			t.Errorf("missing artifact: %v", err)
		}
		if _, err := s.GetArtifact(ctx, "sha256:../../x"); !errors.Is(err, ErrNotFound) {
			t.Errorf("bad digest: %v", err)
		}
		if _, err := s.PutArtifact(ctx, "../fit", b); err == nil {
			t.Error("bad kind accepted")
		}
	})
}

// TestHandlesArePrincipalBound: another principal's handle is unknown, an expired one is expired, a malformed one
// is unknown.
func TestHandlesArePrincipalBound(t *testing.T) {
	stores(t, func(t *testing.T, s Store, c *clock) {
		ctx := context.Background()
		d := Digest([]byte("fit"))
		h, err := s.Mint(ctx, "alice", KindFit, d, time.Hour)
		if err != nil {
			t.Fatal(err)
		}
		if kind, got, err := s.Resolve(ctx, "alice", h); err != nil || kind != KindFit || got != d {
			t.Errorf("own handle: %s %s %v", kind, got, err)
		}
		if _, _, err := s.Resolve(ctx, "mallory", h); !errors.Is(err, ErrHandleUnknown) {
			t.Errorf("foreign handle: %v", err)
		}
		other, _ := NewHandle(KindFit, c.now())
		if _, _, err := s.Resolve(ctx, "alice", other); !errors.Is(err, ErrHandleUnknown) {
			t.Errorf("never minted: %v", err)
		}
		for _, bad := range []string{"", "fit_", "../" + h, h + "/x", strings.ToLower(h)} {
			if _, _, err := s.Resolve(ctx, "alice", bad); !errors.Is(err, ErrHandleUnknown) {
				t.Errorf("malformed %q: %v", bad, err)
			}
		}
		c.add(time.Hour)
		if _, _, err := s.Resolve(ctx, "alice", h); !errors.Is(err, ErrHandleExpired) {
			t.Errorf("expired handle: %v", err)
		}
		if _, _, err := s.Resolve(ctx, "mallory", h); !errors.Is(err, ErrHandleUnknown) {
			t.Errorf("expired foreign handle reveals itself: %v", err)
		}
		if _, err := s.Mint(ctx, "", KindFit, d, time.Hour); err == nil {
			t.Error("mint without principal")
		}
		if _, err := s.Mint(ctx, "alice", KindFit, "sha256:xyz", time.Hour); err == nil {
			t.Error("mint of a bad digest")
		}
	})
}

func TestJobs(t *testing.T) {
	stores(t, func(t *testing.T, s Store, c *clock) {
		ctx := context.Background()
		id, _ := NewHandle(KindJob, c.now())
		j := Job{ID: id, Principal: "alice", Key: "k1", State: JobWorking, Step: "check",
			CreatedAt: c.now(), DeadlineAt: c.now().Add(2 * time.Minute)}
		if err := s.PutJob(ctx, j); err != nil {
			t.Fatal(err)
		}
		got, err := s.GetJob(ctx, "alice", id)
		if err != nil || got.State != JobWorking || got.Step != "check" {
			t.Fatalf("get: %+v %v", got, err)
		}
		if _, err := s.GetJob(ctx, "mallory", id); !errors.Is(err, ErrHandleUnknown) {
			t.Errorf("foreign job: %v", err)
		}
		if f, ok, err := s.FindJob(ctx, "alice", "k1"); err != nil || !ok || f.ID != id {
			t.Errorf("find: %+v %v %v", f, ok, err)
		}
		if _, ok, _ := s.FindJob(ctx, "mallory", "k1"); ok {
			t.Error("foreign principal found the job by key")
		}
		if _, ok, _ := s.FindJob(ctx, "alice", "k2"); ok {
			t.Error("other key found the job")
		}

		// Past the deadline, a job that is still working reports failed with job.timeout.
		c.add(2 * time.Minute)
		got, err = s.GetJob(ctx, "alice", id)
		if err != nil || got.State != JobFailed {
			t.Fatalf("past deadline: %+v %v", got, err)
		}
		var r Refusal
		if err := json.Unmarshal(got.Refusal, &r); err != nil || r.Code != CodeJobTimeout || r.Fix == "" {
			t.Errorf("timeout refusal %s: %v", got.Refusal, err)
		}
		if _, ok, _ := s.FindJob(ctx, "alice", "k1"); ok {
			t.Error("a timed-out job is returned for its key")
		}

		// A completed job stays completed after its deadline, and is found by its key.
		id2, _ := NewHandle(KindJob, c.now())
		done := Job{ID: id2, Principal: "alice", Key: "k1", State: JobCompleted, Result: "fit_" + strings.Repeat("0", 26),
			CreatedAt: c.now(), DeadlineAt: c.now().Add(time.Minute)}
		if err := s.PutJob(ctx, done); err != nil {
			t.Fatal(err)
		}
		c.add(time.Hour)
		if f, ok, _ := s.FindJob(ctx, "alice", "k1"); !ok || f.ID != id2 || f.State != JobCompleted {
			t.Errorf("completed job by key: %+v %v", f, ok)
		}
		// Jobs expire after JobTTL.
		c.add(JobTTL)
		if _, err := s.GetJob(ctx, "alice", id2); !errors.Is(err, ErrHandleUnknown) {
			t.Errorf("expired job: %v", err)
		}
		if err := s.PutJob(ctx, Job{ID: "fit_" + strings.Repeat("0", 26), Principal: "alice", State: JobWorking}); err == nil {
			t.Error("a fit handle accepted as a job id")
		}
		if err := s.PutJob(ctx, Job{ID: id, Principal: "alice", State: "done"}); err == nil {
			t.Error("unknown state accepted")
		}
	})
}

// TestJobRecordsChecked: a job whose state, step or result the server does not write is refused where it is stored,
// in both stores; and a Dir store's job file rewritten afterwards (by another build of the server or its worker: a
// state, step, result or id it does not write, or a file that is not JSON) reads as unknown, by its id and by its key,
// never as stored.
func TestJobRecordsChecked(t *testing.T) {
	planted := "x 198.51.100.250"
	stores(t, func(t *testing.T, s Store, c *clock) {
		id, _ := NewHandle(KindJob, c.now())
		for _, j := range []Job{{State: planted}, {State: JobCompleted, Step: planted},
			{State: JobCompleted, Result: "fit_" + planted}, {State: JobCompleted, Result: "pred_" + strings.Repeat("0", 26)},
			{State: JobCompleted, Result: "job_" + strings.Repeat("0", 26)}} {
			j.ID, j.Principal, j.CreatedAt, j.DeadlineAt = id, "alice", c.now(), c.now().Add(time.Hour)
			if err := s.PutJob(context.Background(), j); err == nil || strings.Contains(err.Error(), planted) {
				t.Errorf("PutJob %+v: %v", j, err)
			}
		}
	})
	ctx := context.Background()
	c := newClock()
	root := t.TempDir()
	d, err := NewDir(root, c.now)
	if err != nil {
		t.Fatal(err)
	}
	for _, edit := range map[string]func(m map[string]any){
		"state":     func(m map[string]any) { m["state"] = planted },
		"step":      func(m map[string]any) { m["step"] = planted },
		"result":    func(m map[string]any) { m["result"] = "fit_" + planted },
		"ab result": func(m map[string]any) { m["result"] = "ab_" + planted },
		"id":        func(m map[string]any) { m["id"] = "job_" + strings.Repeat("0", 26) },
		"principal": func(m map[string]any) { m["principal"] = "mallory" },
		"not JSON":  nil,
	} {
		id, _ := NewHandle(KindJob, c.now())
		key := "k-" + id
		if err := d.PutJob(ctx, Job{ID: id, Principal: "alice", Key: key, State: JobCompleted, Step: "fit",
			Result: "fit_" + strings.Repeat("1", 26), CreatedAt: c.now(), DeadlineAt: c.now().Add(time.Hour)}); err != nil {
			t.Fatal(err)
		}
		if _, ok, err := d.FindJob(ctx, "alice", key); err != nil || !ok {
			t.Fatalf("the job as stored is not found: %v %v", ok, err)
		}
		files, _ := filepath.Glob(filepath.Join(root, "principals", "*", "jobs", id+".json"))
		if len(files) != 1 {
			t.Fatalf("%d files of the job", len(files))
		}
		b := []byte("{")
		if edit != nil {
			raw, err := os.ReadFile(files[0])
			if err != nil {
				t.Fatal(err)
			}
			var m map[string]any
			if err := json.Unmarshal(raw, &m); err != nil {
				t.Fatal(err)
			}
			edit(m)
			b, _ = json.Marshal(m)
		}
		if err := os.WriteFile(files[0], b, 0o600); err != nil {
			t.Fatal(err)
		}
		if j, err := d.GetJob(ctx, "alice", id); !errors.Is(err, ErrHandleUnknown) {
			t.Errorf("GetJob of a rewritten file (%s): %+v %v", b, j, err)
		}
		if j, ok, err := d.FindJob(ctx, "alice", key); ok || err != nil {
			t.Errorf("FindJob of a rewritten file (%s): %+v %v %v", b, j, ok, err)
		}
	}
}

func TestPreviewLog(t *testing.T) {
	stores(t, func(t *testing.T, s Store, c *clock) {
		ctx := context.Background()
		k := PreviewKey{Repo: "shop", Principal: "alice", Branch: "feature/x"}
		for i := 1; i <= 3; i++ {
			n, err := s.AppendPreview(ctx, k, PreviewRow{ChangeHash: Digest([]byte{byte(i)}), Verdict: "block"})
			if err != nil || n != i {
				t.Fatalf("attempt %d: got %d, %v", i, n, err)
			}
		}
		// Keyed by (repo, principal, branch): each part separates logs.
		for _, other := range []PreviewKey{{"shop", "bob", "feature/x"}, {"shop", "alice", "main"}, {"cart", "alice", "feature/x"},
			{"shopa", "lice", "feature/x"}} {
			if n, _ := s.AppendPreview(ctx, other, PreviewRow{Verdict: "block"}); n != 1 {
				t.Errorf("%+v: attempt %d, want 1", other, n)
			}
		}
		// Rows older than PreviewTTL no longer count.
		c.add(PreviewTTL + time.Second)
		if n, _ := s.AppendPreview(ctx, k, PreviewRow{Verdict: "inconclusive"}); n != 1 {
			t.Errorf("after the retention: attempt %d, want 1", n)
		}
		if _, err := s.AppendPreview(ctx, PreviewKey{Repo: "x"}, PreviewRow{}); err == nil {
			t.Error("preview without principal accepted")
		}
	})
}

// TestPreviewLogPruned: the Dir store's preview log keeps PreviewTTL of rows; older ones go when a row is added.
func TestPreviewLogPruned(t *testing.T) {
	c := newClock()
	root := t.TempDir()
	d, err := NewDir(root, c.now)
	if err != nil {
		t.Fatal(err)
	}
	ctx := context.Background()
	k := PreviewKey{Repo: "shop", Principal: "alice", Branch: "main"}
	for i := 0; i < 5; i++ {
		if _, err := d.AppendPreview(ctx, k, PreviewRow{Verdict: "block"}); err != nil {
			t.Fatal(err)
		}
	}
	c.add(PreviewTTL + time.Second)
	if n, err := d.AppendPreview(ctx, k, PreviewRow{Verdict: "inconclusive"}); err != nil || n != 1 {
		t.Fatalf("after the retention: attempt %d, %v", n, err)
	}
	rows, err := readRows(filepath.Join(root, "previews", previewKey(k)+".jsonl"))
	if err != nil || len(rows) != 1 || rows[0].Verdict != "inconclusive" {
		t.Errorf("the log after the retention: %+v, %v", rows, err)
	}
}

func TestBaseline(t *testing.T) {
	stores(t, func(t *testing.T, s Store, _ *clock) {
		ctx := context.Background()
		if _, err := s.Baseline(ctx, "staging"); !errors.Is(err, ErrNotFound) {
			t.Errorf("no baseline: %v", err)
		}
		d := Digest([]byte("fit"))
		if err := s.SetBaseline(ctx, "staging", d); err != nil {
			t.Fatal(err)
		}
		if got, err := s.Baseline(ctx, "staging"); err != nil || got != d {
			t.Errorf("baseline %s %v", got, err)
		}
		if err := s.SetBaseline(ctx, "../x", d); err == nil {
			t.Error("bad env accepted")
		}
	})
}

// TestDirLayout: no principal, repository or branch string reaches a path, and modes are private.
func TestDirLayout(t *testing.T) {
	root := filepath.Join(t.TempDir(), "state")
	c := newClock()
	d, err := NewDir(root, c.now)
	if err != nil {
		t.Fatal(err)
	}
	ctx := context.Background()
	hostile := Principal("../../alice@example.com/x")
	if _, err := d.Mint(ctx, hostile, KindFit, Digest([]byte("f")), time.Hour); err != nil {
		t.Fatal(err)
	}
	if _, err := d.AppendPreview(ctx, PreviewKey{Repo: "../repo", Principal: hostile, Branch: "../../b"}, PreviewRow{}); err != nil {
		t.Fatal(err)
	}
	err = filepath.Walk(root, func(p string, info os.FileInfo, err error) error {
		if err != nil {
			return err
		}
		rel, _ := filepath.Rel(root, p)
		if strings.Contains(rel, "alice") || strings.Contains(rel, "repo") || strings.Contains(rel, "..") {
			t.Errorf("a caller string reached a path: %s", rel)
		}
		if info.IsDir() && info.Mode().Perm() != 0o700 {
			t.Errorf("%s: mode %v", rel, info.Mode().Perm())
		}
		if !info.IsDir() && info.Mode().Perm() != 0o600 {
			t.Errorf("%s: mode %v", rel, info.Mode().Perm())
		}
		return nil
	})
	if err != nil {
		t.Fatal(err)
	}
	if _, err := NewDir("relative/state", nil); err == nil {
		t.Error("relative root accepted")
	}
}

// TestSweep: Sweep removes what has expired and keeps what is live, in both stores. A handle goes ExpiredKeep after its
// expiry, and reads as expired until then; a job goes after JobTTL, with its key; a preview log once none of its rows
// is within PreviewTTL; an artifact once nothing live names it (an unexpired handle, a baseline, a record an unexpired
// prediction handle names, keep) and grace has passed since it was last stored.
func TestSweep(t *testing.T) {
	stores(t, func(t *testing.T, s Store, c *clock) {
		ctx := context.Background()
		sw, ok := s.(Sweeper)
		if !ok {
			t.Fatal("the store does not sweep")
		}
		put := func(b string) string {
			t.Helper()
			d, err := s.PutArtifact(ctx, "x", []byte(b))
			if err != nil {
				t.Fatal(err)
			}
			return d
		}
		mint := func(p Principal, kind, d string, ttl time.Duration) string {
			t.Helper()
			h, err := s.Mint(ctx, p, kind, d, ttl)
			if err != nil {
				t.Fatal(err)
			}
			return h
		}
		fitOld, fitLive, base, changes := put(`{"f":1}`), put(`{"f":2}`), put(`{"f":3}`), put(`{"c":1}`)
		pred := put(`{"fit":"` + fitOld + `","changes":"` + changes + `","now":"2026-10-26T12:00:00Z"}`)
		orphan, kept := put(`{"o":1}`), put(`{"k":1}`)
		hOld := mint("alice", KindFit, fitOld, time.Hour)
		hLive := mint("alice", KindFit, fitLive, 48*time.Hour)
		mint("bob", KindPrediction, pred, 72*time.Hour)
		if err := s.SetBaseline(ctx, "staging", base); err != nil {
			t.Fatal(err)
		}
		id, _ := NewHandle(KindJob, c.now())
		job := Job{ID: id, Principal: "alice", Key: "k1", State: JobCompleted, CreatedAt: c.now(), DeadlineAt: c.now().Add(time.Minute)}
		if err := s.PutJob(ctx, job); err != nil {
			t.Fatal(err)
		}
		pk := PreviewKey{Repo: "shop", Principal: "alice", Branch: "x"}
		if _, err := s.AppendPreview(ctx, pk, PreviewRow{Time: c.now(), Verdict: "block"}); err != nil {
			t.Fatal(err)
		}
		has := func(d string) bool { _, err := s.GetArtifact(ctx, d); return err == nil }

		if n, err := sw.Sweep(ctx, time.Hour, nil); err != nil || n != 0 {
			t.Fatalf("nothing has expired: %d removed, %v", n, err)
		}
		c.add(2 * time.Hour)
		if n, err := sw.Sweep(ctx, time.Hour, nil); err != nil || n != 0 {
			t.Errorf("a handle just past its expiry is kept: %d removed, %v", n, err)
		}
		if _, _, err := s.Resolve(ctx, "alice", hOld); !errors.Is(err, ErrHandleExpired) {
			t.Errorf("an expired handle: %v", err)
		}
		c.add(ExpiredKeep)
		// grace 0: every artifact nothing live names goes; fitOld stays, named by the prediction record
		if n, err := sw.Sweep(ctx, 0, map[string]bool{kept: true}); err != nil || n != 2 {
			t.Errorf("%d removed, %v; want the expired handle and the orphan", n, err)
		}
		if _, _, err := s.Resolve(ctx, "alice", hOld); !errors.Is(err, ErrHandleUnknown) {
			t.Errorf("a swept handle: %v", err)
		}
		if _, _, err := s.Resolve(ctx, "alice", hLive); err != nil {
			t.Errorf("a live handle: %v", err)
		}
		for name, d := range map[string]string{"fitOld": fitOld, "fitLive": fitLive, "base": base, "changes": changes,
			"pred": pred, "kept": kept} {
			if !has(d) {
				t.Errorf("%s was removed", name)
			}
		}
		if has(orphan) {
			t.Error("the orphan was kept")
		}

		// everything past its time: only the baseline's fit stays, and the logs start again
		c.add(PreviewTTL + ExpiredKeep)
		if _, err := sw.Sweep(ctx, 0, nil); err != nil {
			t.Fatal(err)
		}
		for name, d := range map[string]string{"fitOld": fitOld, "fitLive": fitLive, "changes": changes, "pred": pred, "kept": kept} {
			if has(d) {
				t.Errorf("%s was kept", name)
			}
		}
		if !has(base) {
			t.Error("the baseline's fit was removed")
		}
		if _, err := s.GetJob(ctx, "alice", id); !errors.Is(err, ErrHandleUnknown) {
			t.Errorf("an old job: %v", err)
		}
		if n, err := s.AppendPreview(ctx, pk, PreviewRow{Time: c.now(), Verdict: "pass"}); err != nil || n != 1 {
			t.Errorf("the preview log after the sweep: attempt %d %v", n, err)
		}
		if d, ok := s.(*Dir); ok {
			for _, pattern := range []string{"principals/*/handles/*", "principals/*/jobs/*", "principals/*/jobkeys/*"} {
				if left, _ := filepath.Glob(filepath.Join(d.root, pattern)); len(left) != 0 {
					t.Errorf("%s: %v left", pattern, left)
				}
			}
		}
	})
}

// TestSweepGraceCountsFromTheLastStore: storing an artifact again restarts its grace, so one stored for a handle about
// to be minted is not swept under it.
func TestSweepGraceCountsFromTheLastStore(t *testing.T) {
	d, err := NewDir(t.TempDir(), nil)
	if err != nil {
		t.Fatal(err)
	}
	ctx := context.Background()
	dg, _ := d.PutArtifact(ctx, "fit", []byte(`{"f":1}`))
	old := time.Now().Add(-48 * time.Hour)
	if err := os.Chtimes(d.artifactPath(dg), old, old); err != nil {
		t.Fatal(err)
	}
	if _, err := d.PutArtifact(ctx, "fit", []byte(`{"f":1}`)); err != nil {
		t.Fatal(err)
	}
	if n, err := d.Sweep(ctx, time.Hour, nil); err != nil || n != 0 {
		t.Errorf("an artifact stored again just now: %d removed, %v", n, err)
	}
	if err := os.Chtimes(d.artifactPath(dg), old, old); err != nil {
		t.Fatal(err)
	}
	if n, err := d.Sweep(ctx, time.Hour, nil); err != nil || n != 1 {
		t.Errorf("an artifact unreferenced for two days: %d removed, %v", n, err)
	}
}

// TestPreviewedSince: rows are judged by their time, not their file's; a missing store or log is no row and is not
// created; a torn line is skipped.
func TestPreviewedSince(t *testing.T) {
	root := filepath.Join(t.TempDir(), "server")
	t0 := time.Date(2026, 11, 2, 12, 0, 0, 0, time.UTC)
	if ok, err := PreviewedSince(root, t0); ok || err != nil {
		t.Errorf("no store: %v %v", ok, err)
	}
	if _, err := os.Stat(root); !os.IsNotExist(err) {
		t.Error("PreviewedSince created the store")
	}
	d, err := NewDir(root, func() time.Time { return t0 })
	if err != nil {
		t.Fatal(err)
	}
	k := PreviewKey{Repo: "r", Principal: "p", Branch: "b"}
	if _, err := d.AppendPreview(context.Background(), k, PreviewRow{Time: t0.Add(-time.Minute), Verdict: "pass"}); err != nil {
		t.Fatal(err)
	}
	if ok, _ := PreviewedSince(root, t0); ok {
		t.Error("a row from before counted")
	}
	f, _ := os.OpenFile(filepath.Join(root, "previews", previewKey(k)+".jsonl"), os.O_APPEND|os.O_WRONLY, 0)
	f.WriteString(`{"time":"2026-11-02T12:00:01Z","verd` + "\n")
	f.Close()
	if ok, err := PreviewedSince(root, t0); ok || err != nil {
		t.Errorf("a torn line counted: %v %v", ok, err)
	}
	k2 := PreviewKey{Repo: "r2", Principal: "q", Branch: "main"}
	if _, err := d.AppendPreview(context.Background(), k2, PreviewRow{Time: t0, Verdict: "block"}); err != nil {
		t.Fatal(err)
	}
	if ok, err := PreviewedSince(root, t0); !ok || err != nil {
		t.Errorf("a row at t, in another log: %v %v", ok, err)
	}
	if ok, _ := PreviewedSince(root, t0.Add(time.Nanosecond)); ok {
		t.Error("a row before t counted")
	}
}
