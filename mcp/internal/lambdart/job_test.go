// SPDX-License-Identifier: Apache-2.0

package lambdart

import (
	"context"
	"errors"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

// recorded is what a Job's Fail was given.
type recorded struct {
	calls   int
	refusal string
	ctxErr  error
}

func (r *recorded) fail(ctx context.Context, event []byte, refusal []byte) error {
	r.calls++
	r.refusal = string(refusal)
	r.ctxErr = ctx.Err()
	return nil
}

type refused struct{}

func (refused) Error() string { return "store.too_large: the window is too large" }
func (refused) RefusalJSON() []byte {
	return []byte(`{"code":"store.too_large","reason":"the window is too large","fix":"a shorter window"}`)
}

func event(deadline time.Time) []byte {
	return []byte(`{"job_id":"job_01JBQX4Y9W2N7M6K5H3G2D1C0B","deadline_at":"` + deadline.UTC().Format(time.RFC3339Nano) + `"}`)
}

func TestJobRunsInAFreshFolderAndRemovesIt(t *testing.T) {
	root := t.TempDir()
	var dirs []string
	rec := &recorded{}
	j := Job{Root: root, Fail: rec.fail, Run: func(ctx context.Context, ev []byte, dir string) error {
		st, err := os.Stat(dir)
		if err != nil || !st.IsDir() || st.Mode().Perm() != 0o700 || filepath.Dir(dir) != root {
			t.Errorf("job folder %s: %v %v", dir, st, err)
		}
		dirs = append(dirs, dir)
		return os.WriteFile(filepath.Join(dir, "window.json.gz"), []byte("x"), 0o600)
	}}
	for range 2 {
		if out, err := j.Handle(context.Background(), event(time.Now().Add(time.Minute))); err != nil || out != nil {
			t.Fatalf("Handle: %q %v", out, err)
		}
	}
	if len(dirs) != 2 || dirs[0] == dirs[1] {
		t.Fatalf("folders %v: each invocation gets its own", dirs)
	}
	if ents, _ := os.ReadDir(root); len(ents) != 0 {
		t.Fatalf("%d entries left in the root", len(ents))
	}
	if rec.calls != 0 {
		t.Fatal("Fail called for a job that succeeded")
	}
}

func TestJobFailuresAreRecorded(t *testing.T) {
	for _, c := range []struct {
		name    string
		run     func(ctx context.Context) error
		refusal string
	}{
		{"an error without a code", func(context.Context) error { return errors.New("exit status 2") }, ""},
		{"a coded refusal", func(context.Context) error { return refused{} }, `"code":"store.too_large"`},
		{"a panic", func(context.Context) error { panic("nil map") }, ""},
		{"the deadline", func(ctx context.Context) error { <-ctx.Done(); return errors.New("killed") }, `"code":"job.timeout"`},
	} {
		t.Run(c.name, func(t *testing.T) {
			root, rec := t.TempDir(), &recorded{}
			j := Job{Root: root, Fail: rec.fail, Run: func(ctx context.Context, ev []byte, dir string) error { return c.run(ctx) }}
			_, err := j.Handle(context.Background(), event(time.Now().Add(100*time.Millisecond)))
			if err == nil {
				t.Fatal("a failed job reported success to Lambda")
			}
			if rec.calls != 1 || rec.ctxErr != nil {
				t.Fatalf("Fail called %d times, its context %v", rec.calls, rec.ctxErr)
			}
			if (c.refusal == "") != (rec.refusal == "") || !strings.Contains(rec.refusal, c.refusal) {
				t.Fatalf("refusal %q, want %q", rec.refusal, c.refusal)
			}
			if ents, _ := os.ReadDir(root); len(ents) != 0 {
				t.Fatal("the job folder was left behind")
			}
		})
	}
}

func TestJobPastItsDeadlineNeverRuns(t *testing.T) {
	rec := &recorded{}
	ran := false
	j := Job{Root: t.TempDir(), Fail: rec.fail, Run: func(context.Context, []byte, string) error { ran = true; return nil }}
	if _, err := j.Handle(context.Background(), event(time.Now().Add(-time.Second))); err == nil {
		t.Fatal("a job past its deadline succeeded")
	}
	if ran || rec.calls != 1 || rec.refusal != string(TimeoutRefusal) {
		t.Fatalf("ran %v, Fail %+v", ran, rec)
	}
}

func TestJobStopsBeforeTheInvocationDeadline(t *testing.T) {
	rec := &recorded{}
	var left time.Duration
	j := Job{Root: t.TempDir(), Fail: rec.fail, Margin: 900 * time.Millisecond,
		Run: func(ctx context.Context, ev []byte, dir string) error {
			dl, _ := ctx.Deadline()
			left = time.Until(dl)
			<-ctx.Done()
			return ctx.Err()
		}}
	ctx, cancel := context.WithTimeout(context.Background(), time.Second)
	defer cancel()
	_, err := j.Handle(ctx, event(time.Now().Add(time.Hour)))
	if err == nil || left > 150*time.Millisecond {
		t.Fatalf("err %v; the job had %v, want at most the invocation's second less the margin", err, left)
	}
	if rec.refusal != string(TimeoutRefusal) || rec.ctxErr != nil {
		t.Fatalf("Fail %+v: it must still write after the job's context ended", rec)
	}
}

func TestJobRejectsAnUnreadableEvent(t *testing.T) {
	rec := &recorded{}
	j := Job{Root: t.TempDir(), Fail: rec.fail, Run: func(context.Context, []byte, string) error { return nil }}
	for _, bad := range []string{`not json`, `{"deadline_at":"tomorrow"}`, `[]`} {
		if _, err := j.Handle(context.Background(), []byte(bad)); err == nil {
			t.Errorf("%s accepted", bad)
		}
	}
	if rec.calls != 0 {
		t.Fatal("Fail called without a job")
	}
	if _, err := (Job{}).Handle(context.Background(), []byte(`{}`)); err == nil {
		t.Fatal("a job without Run and Fail accepted")
	}
}

func TestJobThroughTheRuntimeLoop(t *testing.T) {
	f := newFakeRuntime(t, fakeInvocation{id: "fit-1", deadline: time.Now().Add(time.Minute),
		event: string(event(time.Now().Add(time.Minute)))})
	rec := &recorded{}
	j := Job{Root: t.TempDir(), Fail: rec.fail, Run: func(context.Context, []byte, string) error { return refused{} }}
	f.serve(t, 1, j.Handle)
	if p := f.errs["fit-1"]; p.body.Type != "Runtime.HandlerError" || !strings.Contains(p.body.Message, "store.too_large") {
		t.Fatalf("posted %+v", p)
	}
	if rec.calls != 1 || !strings.Contains(rec.refusal, "store.too_large") {
		t.Fatalf("Fail %+v", rec)
	}
}
