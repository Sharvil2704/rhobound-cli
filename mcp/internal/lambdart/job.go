// SPDX-License-Identifier: Apache-2.0

package lambdart

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"time"
)

// Job turns an asynchronous job (the fit worker's) into a Handler that never leaves a job unrecorded or a folder
// behind: each invocation works in a fresh, random 0700 folder that is removed at the end, so a warm execution
// environment never mixes one window's files into the next fit (DEPLOY_AWS.md 2.3); the job's context ends at
// the event's deadline_at or Margin before the invocation's own deadline, whichever is first; and any failure
// (an error, a panic, the deadline) is recorded with Fail before the invocation reports it.
type Job struct {
	// Root is where the per-invocation folders are made; "" means os.TempDir() (/tmp on Lambda).
	Root string
	// Run does the job in dir.
	Run func(ctx context.Context, event []byte, dir string) error
	// Fail records the job as failed. refusal is a defs.v1.json Refusal object: job.timeout, or the refusal of an
	// error with a RefusalJSON method (a coded refusal); nil for a failure without a code. Fail gets a context
	// of its own, so it can still write after the job's context ended.
	Fail func(ctx context.Context, event []byte, refusal []byte) error
	// Margin is kept before the invocation's deadline for Fail to write; 0 means 10 s.
	Margin time.Duration
}

// FailTimeout bounds how long Fail may take.
const FailTimeout = 5 * time.Second

// coded is an error that carries a refusal: fetch.RefusalError, and any other coded refusal.
type coded interface{ RefusalJSON() []byte }

// TimeoutRefusal is the refusal of a job that passed its deadline.
var TimeoutRefusal = []byte(`{"code":"job.timeout","reason":"the job did not finish before its deadline","fix":"fit a shorter window, or fit the window in a container"}`)

// Handle runs one job event. Its answer is empty: an asynchronous invocation's answer goes nowhere. A failed
// job returns its error after Fail, so Lambda's on-failure destination and metrics see it too.
func (j Job) Handle(ctx context.Context, event []byte) ([]byte, error) {
	if j.Run == nil || j.Fail == nil {
		return nil, errors.New("lambdart: a job needs Run and Fail")
	}
	var hdr struct {
		DeadlineAt time.Time `json:"deadline_at"`
	}
	if err := json.Unmarshal(event, &hdr); err != nil {
		// without a readable event there is no job to record as failed
		return nil, fmt.Errorf("lambdart: the job event is not a JSON object with an RFC 3339 deadline_at: %w", err)
	}
	margin := j.Margin
	if margin <= 0 {
		margin = 10 * time.Second
	}
	runCtx, cancel := ctx, context.CancelFunc(func() {})
	if dl, ok := ctx.Deadline(); ok {
		runCtx, cancel = context.WithDeadline(ctx, dl.Add(-margin))
	}
	defer cancel()
	if !hdr.DeadlineAt.IsZero() {
		var cancel2 context.CancelFunc
		runCtx, cancel2 = context.WithDeadline(runCtx, hdr.DeadlineAt)
		defer cancel2()
	}
	err := j.run(runCtx, event)
	if err == nil {
		return nil, nil
	}
	var refusal []byte
	var c coded
	switch {
	case errors.Is(err, context.DeadlineExceeded) || errors.Is(runCtx.Err(), context.DeadlineExceeded):
		refusal = TimeoutRefusal
	case errors.As(err, &c):
		refusal = c.RefusalJSON()
	}
	fctx, fcancel := context.WithTimeout(context.WithoutCancel(ctx), FailTimeout)
	defer fcancel()
	if ferr := j.Fail(fctx, event, refusal); ferr != nil {
		return nil, errors.Join(err, fmt.Errorf("lambdart: recording the failure: %w", ferr))
	}
	return nil, err
}

func (j Job) run(ctx context.Context, event []byte) (err error) {
	if err := ctx.Err(); err != nil {
		return err // the job's deadline passed before it started
	}
	root := j.Root
	if root == "" {
		root = os.TempDir()
	}
	dir, err := os.MkdirTemp(root, "job-")
	if err != nil {
		return err
	}
	defer func() {
		if rerr := os.RemoveAll(dir); err == nil && rerr != nil {
			err = rerr
		}
	}()
	defer func() {
		if v := recover(); v != nil {
			err = panicError{v}
		}
	}()
	return j.Run(ctx, event, dir)
}
