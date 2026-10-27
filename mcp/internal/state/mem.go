// SPDX-License-Identifier: Apache-2.0

package state

import (
	"context"
	"fmt"
	"slices"
	"sync"
	"time"
)

// Mem is a Store in memory, for tests.
type Mem struct {
	now func() time.Time

	mu        sync.Mutex
	artifacts map[string][]byte
	stored    map[string]time.Time    // when each artifact was last stored, on the machine's clock
	handles   map[string]handleRecord // principalKey + "/" + handle
	jobs      map[string]Job          // principalKey + "/" + id
	previews  map[string][]PreviewRow
	baselines map[string]string
}

// NewMem returns an empty store whose expiries are judged at now() (time.Now when nil).
func NewMem(now func() time.Time) *Mem {
	if now == nil {
		now = time.Now
	}
	return &Mem{now: now, artifacts: map[string][]byte{}, stored: map[string]time.Time{}, handles: map[string]handleRecord{},
		jobs: map[string]Job{}, previews: map[string][]PreviewRow{}, baselines: map[string]string{}}
}

func (m *Mem) PutArtifact(_ context.Context, kind string, b []byte) (string, error) {
	if !kindRE.MatchString(kind) {
		return "", fmt.Errorf("state: %q is not an artifact kind", kind)
	}
	d := Digest(b)
	m.mu.Lock()
	defer m.mu.Unlock()
	m.artifacts[d] = slices.Clone(b)
	m.stored[d] = time.Now()
	return d, nil
}

func (m *Mem) GetArtifact(_ context.Context, digest string) ([]byte, error) {
	m.mu.Lock()
	defer m.mu.Unlock()
	b, ok := m.artifacts[digest]
	if !ok {
		return nil, ErrNotFound
	}
	return slices.Clone(b), nil
}

func (m *Mem) Mint(_ context.Context, p Principal, kind, digest string, ttl time.Duration) (string, error) {
	if err := checkMint(p, kind, digest, ttl); err != nil {
		return "", err
	}
	now := m.now()
	h, err := NewHandle(kind, now)
	if err != nil {
		return "", err
	}
	m.mu.Lock()
	defer m.mu.Unlock()
	m.handles[principalKey(p)+"/"+h] = handleRecord{Kind: kind, Digest: digest, ExpiresAt: now.Add(ttl)}
	return h, nil
}

func (m *Mem) Resolve(_ context.Context, p Principal, handle string) (string, string, error) {
	if !ValidHandle(handle) {
		return "", "", ErrHandleUnknown
	}
	m.mu.Lock()
	r, ok := m.handles[principalKey(p)+"/"+handle]
	m.mu.Unlock()
	if !ok {
		return "", "", ErrHandleUnknown
	}
	return resolveRecord(r, m.now())
}

func (m *Mem) PutJob(_ context.Context, j Job) error {
	if err := checkJob(j); err != nil {
		return err
	}
	m.mu.Lock()
	defer m.mu.Unlock()
	m.jobs[principalKey(j.Principal)+"/"+j.ID] = j
	return nil
}

func (m *Mem) GetJob(_ context.Context, p Principal, id string) (Job, error) {
	if !ValidHandle(id) || HandleKind(id) != KindJob {
		return Job{}, ErrHandleUnknown
	}
	m.mu.Lock()
	j, ok := m.jobs[principalKey(p)+"/"+id]
	m.mu.Unlock()
	now := m.now()
	if !ok || readJob(j, p, id) != nil || !now.Before(j.CreatedAt.Add(JobTTL)) {
		return Job{}, ErrHandleUnknown
	}
	return j.Effective(now), nil
}

func (m *Mem) FindJob(_ context.Context, p Principal, key string) (Job, bool, error) {
	if key == "" {
		return Job{}, false, nil
	}
	pk := principalKey(p) + "/"
	now := m.now()
	m.mu.Lock()
	defer m.mu.Unlock()
	var best Job
	found := false
	for k, j := range m.jobs {
		if len(k) > len(pk) && k[:len(pk)] == pk && readJob(j, p, k[len(pk):]) == nil && j.Key == key && usable(j, now) &&
			now.Before(j.CreatedAt.Add(JobTTL)) && (!found || j.CreatedAt.After(best.CreatedAt)) {
			best, found = j, true
		}
	}
	if !found {
		return Job{}, false, nil
	}
	return best.Effective(now), true, nil
}

func (m *Mem) AppendPreview(_ context.Context, k PreviewKey, row PreviewRow) (int, error) {
	if k.Principal == "" {
		return 0, fmt.Errorf("state: preview without a principal")
	}
	if row.Time.IsZero() {
		row.Time = m.now()
	}
	key := previewKey(k)
	m.mu.Lock()
	defer m.mu.Unlock()
	m.previews[key] = append(m.previews[key], row)
	return countSince(m.previews[key], m.now().Add(-PreviewTTL)), nil
}

func (m *Mem) Baseline(_ context.Context, env string) (string, error) {
	m.mu.Lock()
	defer m.mu.Unlock()
	d, ok := m.baselines[env]
	if !ok {
		return "", ErrNotFound
	}
	return d, nil
}

func (m *Mem) SetBaseline(_ context.Context, env, fitDigest string) error {
	if !envRE.MatchString(env) || !digestRE.MatchString(fitDigest) {
		return fmt.Errorf("state: bad baseline %q -> %q", env, fitDigest)
	}
	m.mu.Lock()
	defer m.mu.Unlock()
	m.baselines[env] = fitDigest
	return nil
}

// Sweep implements Sweeper, as Dir does.
func (m *Mem) Sweep(_ context.Context, grace time.Duration, keep map[string]bool) (int, error) {
	now := m.now()
	m.mu.Lock()
	defer m.mu.Unlock()
	removed := 0
	live := map[string]bool{}
	for k := range keep {
		live[k] = true
	}
	for k, r := range m.handles {
		switch {
		case !now.Before(r.ExpiresAt.Add(ExpiredKeep)):
			delete(m.handles, k)
			removed++
			continue
		case !now.Before(r.ExpiresAt):
			continue
		}
		live[r.Digest] = true
		if r.Kind == KindPrediction {
			for _, x := range references(m.artifacts[r.Digest]) {
				live[x] = true
			}
		}
	}
	for k, j := range m.jobs {
		if !now.Before(j.CreatedAt.Add(JobTTL)) {
			delete(m.jobs, k)
			removed++
		}
	}
	for k, rows := range m.previews {
		if countSince(rows, now.Add(-PreviewTTL)) == 0 {
			delete(m.previews, k)
			removed++
		}
	}
	for _, d := range m.baselines {
		live[d] = true
	}
	for d := range m.artifacts {
		if !live[d] && time.Since(m.stored[d]) >= grace {
			delete(m.artifacts, d)
			delete(m.stored, d)
			removed++
		}
	}
	return removed, nil
}

// countSince counts the rows at or after t.
func countSince(rows []PreviewRow, t time.Time) int {
	n := 0
	for _, r := range rows {
		if !r.Time.Before(t) {
			n++
		}
	}
	return n
}
