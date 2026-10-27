// SPDX-License-Identifier: Apache-2.0

// Package state keeps what the server remembers between calls (ARCHITECTURE.md 5.10): artifacts by content digest,
// handles bound to a principal, jobs with a deadline, the preview log, and the baseline pointer per environment.
//
// A handle is a random ULID with a kind prefix (fit_, pred_, job_, ab_, ver_). It is stored under its principal, so
// possession of a handle is never authentication: another principal's handle resolves exactly like one that never
// existed (handle.unknown). Digests are content ids, not secrets.
//
// Two stores implement Store: Dir, a local folder (stdio and container modes), and Mem, for tests. DynamoDB and S3
// come later, behind the same interface.
package state

import (
	"bytes"
	"context"
	"crypto/rand"
	"crypto/sha256"
	"encoding/binary"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"regexp"
	"time"
)

// Principal names the caller: the local user in stdio mode, the token's subject over HTTP.
type Principal string

// Handle kinds (the prefixes of ARCHITECTURE.md 5.4 Handle).
const (
	KindFit        = "fit"
	KindPrediction = "pred"
	KindJob        = "job"
	KindAB         = "ab"
	KindVerified   = "ver"
)

// Job states, named as in the MCP Tasks extension so a later switch is a rename (ARCHITECTURE.md 5.1).
const (
	JobWorking   = "working"
	JobCompleted = "completed"
	JobFailed    = "failed"
	JobCancelled = "cancelled"
)

// Retention defaults (DEPLOY_AWS.md 3.2).
const (
	JobTTL     = 7 * 24 * time.Hour
	PreviewTTL = 30 * 24 * time.Hour
	// ExpiredKeep is how long Sweep keeps a handle past its expiry, so that a caller still holding it is told it
	// expired (handle.expired) rather than that it never existed.
	ExpiredKeep = 24 * time.Hour
)

var (
	// ErrHandleUnknown: no such handle for this principal (it may exist for another).
	ErrHandleUnknown = errors.New(CodeHandleUnknown)
	// ErrHandleExpired: the handle existed for this principal and is past its expiry.
	ErrHandleExpired = errors.New(CodeHandleExpired)
	// ErrNotFound: no artifact with that digest, or no baseline for that environment.
	ErrNotFound = errors.New("state: not found")
)

var (
	handleRE = regexp.MustCompile(`^(fit|pred|job|ab|ver)_[0-9A-HJKMNP-TV-Z]{26}$`)
	digestRE = regexp.MustCompile(`^sha256:[0-9a-f]{64}$`)
	kindRE   = regexp.MustCompile(`^[a-z][a-z0-9-]{0,31}$`)
	envRE    = regexp.MustCompile(`^[a-z0-9-]{1,40}$`)
)

// Store is the server's state. Every method is safe for concurrent use.
type Store interface {
	// PutArtifact stores b and returns its digest, "sha256:<hex>" of exactly these bytes.
	PutArtifact(ctx context.Context, kind string, b []byte) (digest string, err error)
	GetArtifact(ctx context.Context, digest string) ([]byte, error)

	// Mint makes a new handle of kind for principal p, naming digest, valid for ttl.
	Mint(ctx context.Context, p Principal, kind, digest string, ttl time.Duration) (string, error)
	// Resolve returns what p's handle names. ErrHandleUnknown for an unknown handle or another principal's,
	// ErrHandleExpired for one past its expiry.
	Resolve(ctx context.Context, p Principal, handle string) (kind, digest string, err error)

	// PutJob creates or replaces a job. Its ID is a job handle (NewHandle(KindJob, ...)); a job whose fields are not
	// ones the server writes (a state of the four, a step, a fit or an A/B handle as its result) is an error.
	PutJob(ctx context.Context, j Job) error
	// GetJob returns p's job, as Effective reports it at the store's clock. A stored record that is not one the server
	// writes, or not the job asked for, is ErrHandleUnknown (readJob).
	GetJob(ctx context.Context, p Principal, id string) (Job, error)
	// FindJob returns p's newest job with the idempotency key, if one exists, has not failed or been cancelled, and
	// passes readJob.
	FindJob(ctx context.Context, p Principal, key string) (Job, bool, error)

	// AppendPreview adds a row to the preview log and returns the attempt number: the rows under k within
	// PreviewTTL, this one included.
	AppendPreview(ctx context.Context, k PreviewKey, row PreviewRow) (attempt int, err error)

	// Baseline returns the environment's current fit digest (ErrNotFound when none).
	Baseline(ctx context.Context, env string) (fitDigest string, err error)
	SetBaseline(ctx context.Context, env, fitDigest string) error
}

// Sweeper is a Store that removes what has expired. Dir and Mem are; on AWS, DynamoDB's time-to-live and the buckets'
// lifecycle rules do the same (DEPLOY_AWS.md 3).
type Sweeper interface {
	// Sweep removes handles ExpiredKeep past their expiry, jobs past JobTTL, job keys whose job is gone, preview logs
	// with no row within PreviewTTL, and the artifacts that are not live: named by no unexpired handle, no baseline, no
	// record an unexpired prediction handle names (references), and not in keep. An artifact is not removed until grace after it was
	// last stored (PutArtifact), on the machine's clock, so one stored for a handle about to be minted stays. It
	// returns how many entries it removed.
	Sweep(ctx context.Context, grace time.Duration, keep map[string]bool) (int, error)
}

// references are the artifacts a record names: its top-level string values that are digests. The server's prediction
// records name the fit, change set, policy and view they were computed from that way.
func references(record []byte) []string {
	var m map[string]any
	if json.Unmarshal(record, &m) != nil {
		return nil
	}
	var out []string
	for _, v := range m {
		if d, ok := v.(string); ok && digestRE.MatchString(d) {
			out = append(out, d)
		}
	}
	return out
}

// Job is a fit or an A/B difference running in the background (ARCHITECTURE.md 5.5).
type Job struct {
	ID         string          `json:"id"`
	Principal  Principal       `json:"principal"`
	Key        string          `json:"key,omitempty"` // idempotency key: the same request returns this job
	State      string          `json:"state"`
	Step       string          `json:"step,omitempty"` // fetch, check, fit, leverage, diff
	CreatedAt  time.Time       `json:"created_at"`
	DeadlineAt time.Time       `json:"deadline_at"`
	Result     string          `json:"result,omitempty"`   // the handle it made: fit_... or ab_...
	Refusal    json.RawMessage `json:"refusal,omitempty"`  // a Refusal object, when failed
	Findings   json.RawMessage `json:"findings,omitempty"` // an array of Finding objects
}

// Effective is the job as job_status reports it at now: a job still working past its deadline_at is failed with
// job.timeout, even if its worker died without writing anything.
func (j Job) Effective(now time.Time) Job {
	if j.State == JobWorking && !now.Before(j.DeadlineAt) {
		j.State = JobFailed
		j.Refusal = TimeoutRefusal().JSON()
	}
	return j
}

// FailedRefusal is the refusal of a job whose step failed without a coded refusal (job.failed): the engine exited
// without one, or wrote no record. The fix is the registry's.
func FailedRefusal() Refusal {
	return Refusal{Code: CodeJobFailed, Reason: "a step of the job failed without a coded refusal",
		Fix: "start the job again; if it fails again, the server's operator can run rhobound check and fit on the " +
			"capture to read the engine's message"}
}

// TimeoutRefusal is the refusal of a job past its deadline_at (job.timeout).
func TimeoutRefusal() Refusal {
	return Refusal{Code: CodeJobTimeout, Reason: "the job passed its deadline_at before it finished",
		Fix: "start it again with fit_start; a window that cannot be fitted in time needs a shorter window"}
}

// PreviewKey keys the preview log: one log per repository, principal and branch (ARCHITECTURE.md 5.10).
type PreviewKey struct {
	Repo      string
	Principal Principal
	Branch    string
}

// PreviewRow is one predict call: the change hash, the declared values, the preview verdict and the time.
type PreviewRow struct {
	Time       time.Time       `json:"time"`
	ChangeHash string          `json:"change_hash"`
	Declared   json.RawMessage `json:"declared,omitempty"`
	Verdict    string          `json:"verdict"`
}

// NewHandle returns a new handle of kind: the kind, "_", and a ULID (48 bits of milliseconds since the Unix epoch,
// then 80 random bits, in Crockford base32).
func NewHandle(kind string, now time.Time) (string, error) {
	switch kind {
	case KindFit, KindPrediction, KindJob, KindAB, KindVerified:
	default:
		return "", fmt.Errorf("state: %q is not a handle kind", kind)
	}
	var b [16]byte
	ms := uint64(now.UnixMilli())
	b[0], b[1], b[2], b[3], b[4], b[5] = byte(ms>>40), byte(ms>>32), byte(ms>>24), byte(ms>>16), byte(ms>>8), byte(ms)
	if _, err := rand.Read(b[6:]); err != nil {
		return "", err
	}
	return kind + "_" + ulid(b), nil
}

// ValidHandle reports whether s has the form of a handle.
func ValidHandle(s string) bool { return handleRE.MatchString(s) }

// HandleKind returns the kind prefix of a well-formed handle.
func HandleKind(h string) string {
	for i := 0; i < len(h); i++ {
		if h[i] == '_' {
			return h[:i]
		}
	}
	return ""
}

const crockford = "0123456789ABCDEFGHJKMNPQRSTVWXYZ"

// ulid encodes 128 bits as 26 base32 digits, most significant first (the top digit holds 3 bits).
func ulid(b [16]byte) string {
	hi, lo := binary.BigEndian.Uint64(b[:8]), binary.BigEndian.Uint64(b[8:])
	var out [26]byte
	for i := len(out) - 1; i >= 0; i-- {
		out[i] = crockford[lo&31]
		lo = lo>>5 | hi<<59
		hi >>= 5
	}
	return string(out[:])
}

// Digest is the content id of b: "sha256:" and the hex sha256 of exactly these bytes.
func Digest(b []byte) string {
	s := sha256.Sum256(b)
	return "sha256:" + hex.EncodeToString(s[:])
}

// principalKey is a fixed-length, path-safe key for a principal. The raw principal (a token subject, an email) never
// becomes part of a path.
func principalKey(p Principal) string {
	s := sha256.Sum256([]byte(p))
	return hex.EncodeToString(s[:16])
}

// previewKey is the path-safe key of a preview log.
func previewKey(k PreviewKey) string {
	var b bytes.Buffer
	for _, s := range []string{k.Repo, string(k.Principal), k.Branch} {
		fmt.Fprintf(&b, "%d:%s", len(s), s)
	}
	s := sha256.Sum256(b.Bytes())
	return hex.EncodeToString(s[:16])
}

// handleRecord is what a handle names.
type handleRecord struct {
	Kind      string    `json:"kind"`
	Digest    string    `json:"digest"`
	ExpiresAt time.Time `json:"expires_at"`
}

func checkMint(p Principal, kind, digest string, ttl time.Duration) error {
	if p == "" {
		return errors.New("state: no principal")
	}
	if !digestRE.MatchString(digest) {
		return fmt.Errorf("state: %q is not a digest", digest)
	}
	if ttl <= 0 {
		return errors.New("state: a handle needs a positive ttl")
	}
	return nil
}

// ValidStep reports whether s is a step of a job (job-status.v1 step): fetch, check, fit, leverage or diff.
func ValidStep(s string) bool {
	switch s {
	case "fetch", "check", "fit", "leverage", "diff":
		return true
	}
	return false
}

// checkJob reports why a job is not one the server writes, or nil: a principal, a job handle as its id, a state of the
// four, a step of ValidStep's or none, and as its result a fit or an A/B handle or none. PutJob stores no other, and
// GetJob and FindJob return no other (readJob).
func checkJob(j Job) error {
	if j.Principal == "" {
		return errors.New("state: job without a principal")
	}
	if !ValidHandle(j.ID) || HandleKind(j.ID) != KindJob {
		return errors.New("state: the job's id is not a job handle")
	}
	switch j.State {
	case JobWorking, JobCompleted, JobFailed, JobCancelled:
	default:
		return errors.New("state: the job's state is not one of the four")
	}
	if j.Step != "" && !ValidStep(j.Step) {
		return errors.New("state: the job's step is not a step")
	}
	if k := HandleKind(j.Result); j.Result != "" && (!ValidHandle(j.Result) || k != KindFit && k != KindAB) {
		return errors.New("state: the job's result is not a fit or an A/B handle")
	}
	return nil
}

// readJob is the one read boundary of a stored job: GetJob and FindJob return a record only when it is one the server
// writes (checkJob) and it is the job asked for, p's job id. A job record may have been written by another build of
// the server or its worker (ARCHITECTURE.md 5.9), and its fields reach the caller (job_status, fit_start), so a record
// that fails, or that does not parse, is unknown (ErrHandleUnknown), never returned as stored.
func readJob(j Job, p Principal, id string) error {
	if checkJob(j) != nil || j.Principal != p || j.ID != id {
		return ErrHandleUnknown
	}
	return nil
}

// resolveRecord applies the expiry rule to a stored handle.
func resolveRecord(r handleRecord, now time.Time) (string, string, error) {
	if !now.Before(r.ExpiresAt) {
		return "", "", ErrHandleExpired
	}
	return r.Kind, r.Digest, nil
}

// usable reports whether a job may be returned for its idempotency key.
func usable(j Job, now time.Time) bool {
	j = j.Effective(now)
	return j.State == JobWorking || j.State == JobCompleted
}
