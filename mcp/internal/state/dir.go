// SPDX-License-Identifier: Apache-2.0

package state

import (
	"bufio"
	"bytes"
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io/fs"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"time"
)

// Dir is a Store in a local folder (stdio and container modes). Folders are 0700 and files 0600; files are written
// to a temporary name and renamed, so a reader never sees half a record. Layout:
//
//	artifacts/<hex>                         content, by sha256
//	principals/<key>/handles/<handle>.json  what a handle names, and its expiry
//	principals/<key>/jobs/<id>.json         a job
//	principals/<key>/jobkeys/<hash>         the newest job id for an idempotency key
//	previews/<key>.jsonl                    the preview log of one repository, principal and branch
//	baselines/<env>.json                    an environment's baseline pointer
//
// <key> is a hash: no principal, repository or branch string becomes part of a path.
//
// One process serializes its own writes. Several stdio servers sharing a folder are safe for artifacts, handles and
// jobs (each write is one rename); two previews appended at the same instant by two processes may both count the
// same attempt number.
type Dir struct {
	root string
	now  func() time.Time
	mu   sync.Mutex
}

// NewDir opens (creating if needed) a store in root; expiries are judged at now() (time.Now when nil).
func NewDir(root string, now func() time.Time) (*Dir, error) {
	if !filepath.IsAbs(root) {
		return nil, fmt.Errorf("state: %q is not an absolute folder", root)
	}
	if now == nil {
		now = time.Now
	}
	for _, sub := range []string{"artifacts", "principals", "previews", "baselines"} {
		if err := os.MkdirAll(filepath.Join(root, sub), 0o700); err != nil {
			return nil, fmt.Errorf("state: %w", err)
		}
	}
	return &Dir{root: root, now: now}, nil
}

func (d *Dir) PutArtifact(_ context.Context, kind string, b []byte) (string, error) {
	if !kindRE.MatchString(kind) {
		return "", fmt.Errorf("state: %q is not an artifact kind", kind)
	}
	dg := Digest(b)
	p := d.artifactPath(dg)
	if _, err := os.Stat(p); err == nil {
		// content-addressed: already there. Stored again now, which is when Sweep's grace starts.
		now := time.Now()
		return dg, os.Chtimes(p, now, now)
	}
	return dg, writeFile(p, b)
}

func (d *Dir) GetArtifact(_ context.Context, digest string) ([]byte, error) {
	if !digestRE.MatchString(digest) {
		return nil, ErrNotFound
	}
	b, err := os.ReadFile(d.artifactPath(digest))
	if errors.Is(err, fs.ErrNotExist) {
		return nil, ErrNotFound
	}
	if err != nil {
		return nil, err
	}
	if Digest(b) != digest {
		return nil, fmt.Errorf("state: artifact %s does not match its digest", digest)
	}
	return b, nil
}

func (d *Dir) Mint(_ context.Context, p Principal, kind, digest string, ttl time.Duration) (string, error) {
	if err := checkMint(p, kind, digest, ttl); err != nil {
		return "", err
	}
	now := d.now()
	h, err := NewHandle(kind, now)
	if err != nil {
		return "", err
	}
	b, err := json.Marshal(handleRecord{Kind: kind, Digest: digest, ExpiresAt: now.Add(ttl).UTC()})
	if err != nil {
		return "", err
	}
	return h, writeFile(filepath.Join(d.principal(p), "handles", h+".json"), b)
}

func (d *Dir) Resolve(_ context.Context, p Principal, handle string) (string, string, error) {
	if !ValidHandle(handle) {
		return "", "", ErrHandleUnknown
	}
	var r handleRecord
	if err := readJSON(filepath.Join(d.principal(p), "handles", handle+".json"), &r); err != nil {
		if errors.Is(err, fs.ErrNotExist) {
			return "", "", ErrHandleUnknown
		}
		return "", "", err
	}
	return resolveRecord(r, d.now())
}

func (d *Dir) PutJob(_ context.Context, j Job) error {
	if err := checkJob(j); err != nil {
		return err
	}
	b, err := json.Marshal(j)
	if err != nil {
		return err
	}
	d.mu.Lock()
	defer d.mu.Unlock()
	pdir := d.principal(j.Principal)
	if err := writeFile(filepath.Join(pdir, "jobs", j.ID+".json"), b); err != nil {
		return err
	}
	if j.Key == "" {
		return nil
	}
	return writeFile(filepath.Join(pdir, "jobkeys", hashName(j.Key)), []byte(j.ID))
}

func (d *Dir) GetJob(_ context.Context, p Principal, id string) (Job, error) {
	if !ValidHandle(id) || HandleKind(id) != KindJob {
		return Job{}, ErrHandleUnknown
	}
	b, err := os.ReadFile(filepath.Join(d.principal(p), "jobs", id+".json"))
	if errors.Is(err, fs.ErrNotExist) {
		return Job{}, ErrHandleUnknown
	}
	if err != nil {
		return Job{}, err
	}
	var j Job
	if json.Unmarshal(b, &j) != nil || readJob(j, p, id) != nil {
		return Job{}, ErrHandleUnknown
	}
	now := d.now()
	if !now.Before(j.CreatedAt.Add(JobTTL)) {
		return Job{}, ErrHandleUnknown
	}
	return j.Effective(now), nil
}

func (d *Dir) FindJob(ctx context.Context, p Principal, key string) (Job, bool, error) {
	if key == "" {
		return Job{}, false, nil
	}
	id, err := os.ReadFile(filepath.Join(d.principal(p), "jobkeys", hashName(key)))
	if errors.Is(err, fs.ErrNotExist) {
		return Job{}, false, nil
	}
	if err != nil {
		return Job{}, false, err
	}
	j, err := d.GetJob(ctx, p, string(id))
	if errors.Is(err, ErrHandleUnknown) {
		return Job{}, false, nil
	}
	if err != nil {
		return Job{}, false, err
	}
	if j.Key != key || !usable(j, d.now()) {
		return Job{}, false, nil
	}
	return j, true, nil
}

func (d *Dir) AppendPreview(_ context.Context, k PreviewKey, row PreviewRow) (int, error) {
	if k.Principal == "" {
		return 0, fmt.Errorf("state: preview without a principal")
	}
	if row.Time.IsZero() {
		row.Time = d.now()
	}
	row.Time = row.Time.UTC()
	line, err := json.Marshal(row)
	if err != nil {
		return 0, err
	}
	d.mu.Lock()
	defer d.mu.Unlock()
	p := filepath.Join(d.root, "previews", previewKey(k)+".jsonl")
	f, err := os.OpenFile(p, os.O_WRONLY|os.O_APPEND|os.O_CREATE, 0o600)
	if err != nil {
		return 0, err
	}
	if _, err := f.Write(append(line, '\n')); err != nil {
		f.Close()
		return 0, err
	}
	if err := f.Close(); err != nil {
		return 0, err
	}
	rows, err := readRows(p)
	if err != nil {
		return 0, err
	}
	since := d.now().Add(-PreviewTTL)
	// The log keeps PreviewTTL of rows: older ones are dropped when a row is added, so it does not grow without end.
	if n := countSince(rows, since); n < len(rows) {
		var buf bytes.Buffer
		for _, r := range rows {
			if r.Time.Before(since) {
				continue
			}
			b, err := json.Marshal(r)
			if err != nil {
				return 0, err
			}
			buf.Write(append(b, '\n'))
		}
		if err := writeFile(p, buf.Bytes()); err != nil {
			return 0, err
		}
	}
	return countSince(rows, since), nil
}

func (d *Dir) Baseline(_ context.Context, env string) (string, error) {
	if !envRE.MatchString(env) {
		return "", ErrNotFound
	}
	var b struct {
		Fit string `json:"fit"`
	}
	if err := readJSON(filepath.Join(d.root, "baselines", env+".json"), &b); err != nil {
		if errors.Is(err, fs.ErrNotExist) {
			return "", ErrNotFound
		}
		return "", err
	}
	return b.Fit, nil
}

func (d *Dir) SetBaseline(_ context.Context, env, fitDigest string) error {
	if !envRE.MatchString(env) || !digestRE.MatchString(fitDigest) {
		return fmt.Errorf("state: bad baseline %q -> %q", env, fitDigest)
	}
	b, _ := json.Marshal(map[string]string{"fit": fitDigest})
	return writeFile(filepath.Join(d.root, "baselines", env+".json"), b)
}

// Sweep implements Sweeper. Expiries are judged at the store's clock, as Resolve and GetJob judge them; an artifact's
// age is its file's modification time on the machine's clock.
func (d *Dir) Sweep(ctx context.Context, grace time.Duration, keep map[string]bool) (int, error) {
	now := d.now()
	removed := 0
	remove := func(p string) error {
		if err := os.Remove(p); err != nil && !errors.Is(err, fs.ErrNotExist) {
			return err
		}
		removed++
		return nil
	}
	live := map[string]bool{}
	for k := range keep {
		live[k] = true
	}
	principals, err := os.ReadDir(filepath.Join(d.root, "principals"))
	if err != nil {
		return 0, err
	}
	for _, pe := range principals {
		if err := ctx.Err(); err != nil {
			return removed, err
		}
		pdir := filepath.Join(d.root, "principals", pe.Name())
		err := eachFile(filepath.Join(pdir, "handles"), func(p string) error {
			var r handleRecord
			if readJSON(p, &r) != nil {
				return nil // a record that does not read is left as it is
			}
			switch {
			case !now.Before(r.ExpiresAt.Add(ExpiredKeep)):
				return remove(p)
			case !now.Before(r.ExpiresAt):
				return nil // expired, kept a while so that it reads as expired
			}
			live[r.Digest] = true
			if r.Kind == KindPrediction {
				if b, err := d.GetArtifact(ctx, r.Digest); err == nil {
					for _, x := range references(b) {
						live[x] = true
					}
				}
			}
			return nil
		})
		if err != nil {
			return removed, err
		}
		err = eachFile(filepath.Join(pdir, "jobs"), func(p string) error {
			var j Job
			if readJSON(p, &j) != nil || now.Before(j.CreatedAt.Add(JobTTL)) {
				return nil
			}
			return remove(p)
		})
		if err != nil {
			return removed, err
		}
		// A job key whose job is gone; under mu, since PutJob writes a job, then its key.
		d.mu.Lock()
		err = eachFile(filepath.Join(pdir, "jobkeys"), func(p string) error {
			id, err := os.ReadFile(p)
			if err != nil {
				return nil
			}
			if ValidHandle(string(id)) {
				if _, err := os.Stat(filepath.Join(pdir, "jobs", string(id)+".json")); !errors.Is(err, fs.ErrNotExist) {
					return nil
				}
			}
			return remove(p)
		})
		d.mu.Unlock()
		if err != nil {
			return removed, err
		}
	}
	d.mu.Lock()
	err = eachFile(filepath.Join(d.root, "previews"), func(p string) error {
		rows, err := readRows(p)
		if err != nil || countSince(rows, now.Add(-PreviewTTL)) > 0 {
			return nil
		}
		return remove(p)
	})
	d.mu.Unlock()
	if err != nil {
		return removed, err
	}
	err = eachFile(filepath.Join(d.root, "baselines"), func(p string) error {
		var b struct {
			Fit string `json:"fit"`
		}
		if readJSON(p, &b) == nil {
			live[b.Fit] = true
		}
		return nil
	})
	if err != nil {
		return removed, err
	}
	if err := ctx.Err(); err != nil {
		return removed, err
	}
	err = eachFile(filepath.Join(d.root, "artifacts"), func(p string) error {
		if live["sha256:"+filepath.Base(p)] {
			return nil
		}
		info, err := os.Stat(p)
		if err != nil || time.Since(info.ModTime()) < grace {
			return nil
		}
		return remove(p)
	})
	return removed, err
}

// eachFile calls f with the path of each file in dir, skipping temporary files (writeFile's); a folder that does not
// exist holds none.
func eachFile(dir string, f func(path string) error) error {
	entries, err := os.ReadDir(dir)
	if errors.Is(err, fs.ErrNotExist) {
		return nil
	}
	if err != nil {
		return err
	}
	for _, e := range entries {
		if e.IsDir() || strings.HasPrefix(e.Name(), ".tmp-") {
			continue
		}
		if err := f(filepath.Join(dir, e.Name())); err != nil {
			return err
		}
	}
	return nil
}

func (d *Dir) artifactPath(digest string) string {
	return filepath.Join(d.root, "artifacts", strings.TrimPrefix(digest, "sha256:"))
}

func (d *Dir) principal(p Principal) string {
	return filepath.Join(d.root, "principals", principalKey(p))
}

func hashName(s string) string {
	h := sha256.Sum256([]byte(s))
	return hex.EncodeToString(h[:16])
}

// writeFile writes b to path through a temporary file and a rename, creating the folder (0700) when needed.
func writeFile(path string, b []byte) error {
	dir := filepath.Dir(path)
	if err := os.MkdirAll(dir, 0o700); err != nil {
		return err
	}
	f, err := os.CreateTemp(dir, ".tmp-*")
	if err != nil {
		return err
	}
	tmp := f.Name()
	_, werr := f.Write(b)
	if cerr := f.Close(); werr == nil {
		werr = cerr
	}
	if werr == nil {
		werr = os.Chmod(tmp, 0o600)
	}
	if werr == nil {
		werr = os.Rename(tmp, path)
	}
	if werr != nil {
		os.Remove(tmp)
	}
	return werr
}

func readJSON(path string, v any) error {
	b, err := os.ReadFile(path)
	if err != nil {
		return err
	}
	return json.Unmarshal(b, v)
}

func readRows(path string) ([]PreviewRow, error) {
	b, err := os.ReadFile(path)
	if err != nil {
		return nil, err
	}
	var rows []PreviewRow
	sc := bufio.NewScanner(bytes.NewReader(b))
	sc.Buffer(make([]byte, 64<<10), 1<<20)
	for sc.Scan() {
		var r PreviewRow
		if err := json.Unmarshal(sc.Bytes(), &r); err != nil {
			continue // a torn line from a crashed writer counts as no attempt
		}
		rows = append(rows, r)
	}
	return rows, sc.Err()
}
