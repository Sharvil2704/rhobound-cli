// SPDX-License-Identifier: Apache-2.0

// Package contract is the data contract shared by every part of rhobound: the one registry of finding codes (codes.go),
// the finding and the check report, the capture manifest, and the canonical JSON that content ids are computed from.
// It depends on the standard library only, and nothing in it reads a file, the clock or the environment.
package contract

import (
	"bytes"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"math"
	"regexp"
	"slices"
	"sort"
	"strings"
)

// Version is the version of the registry, as a check report names it.
const Version = "rhobound.contract/v1.0"

// Level is how much a finding weighs: a refusal stops the input, a doubt is listed and may hold a gate's verdict, a note
// only informs.
type Level string

// The levels (DATA.md 1, rule 2).
const (
	Refuse Level = "refuse"
	Doubt  Level = "doubt"
	Note   Level = "note"
)

// Trigger is what raises a code, and so which test covers it (DATA.md 17): a defect in a capture or its store (an
// injected fixture), another input file (a unit test with a small defective file), or a component at run time (a unit
// test of that component).
type Trigger string

// The triggers.
const (
	Capture Trigger = "capture"
	Input   Trigger = "input"
	Runtime Trigger = "runtime"
)

// Code is one registered code. When, Fix and Today are the texts of the tables in DATA.md (Today only for the codes a
// capture triggers); Doc names the section that defines the code; Since is the registry version that added it; Status is
// one of StatusNew, StatusCoded, StatusLater and StatusResearch.
type Code struct {
	ID      string
	Level   Level
	Trigger Trigger
	When    string
	Fix     string
	Today   string
	Doc     string
	Since   string
	Status  string
	// Numbers are the names of the numbers a finding or a refusal of the code may carry (numberNames).
	Numbers []string
}

// Pattern is the shape of every code: domain.name (ARCHITECTURE.md 5.4).
var Pattern = regexp.MustCompile(`^[a-z]+\.[a-z0-9_]+$`)

var byID = func() map[string]int {
	m := make(map[string]int, len(registry))
	for i, c := range registry {
		m[c.ID] = i
	}
	return m
}()

// Lookup returns the registered code with this id.
func Lookup(id string) (Code, bool) {
	i, ok := byID[id]
	if !ok {
		return Code{}, false
	}
	return clone(registry[i]), true
}

// clone is a copy of a code that shares nothing with the registry.
func clone(c Code) Code {
	c.Numbers = slices.Clone(c.Numbers)
	return c
}

// All returns every registered code, in the registry's order (the order of the tables in DATA.md).
func All() []Code {
	out := make([]Code, len(registry))
	for i, c := range registry {
		out[i] = clone(c)
	}
	return out
}

// Finding is one coded finding (DATA.md 1, rule 2). The subject is sanitized (SafeName); numbers are the values read;
// examples are at most three trace ids, span ids, object names or line numbers that show the defect.
type Finding struct {
	Code             string             `json:"code"`
	Level            Level              `json:"level"`
	Subject          string             `json:"subject,omitempty"`
	SubjectUntrusted bool               `json:"subject_untrusted,omitempty"`
	Numbers          map[string]float64 `json:"numbers,omitempty"`
	Examples         []string           `json:"examples,omitempty"`
	Fix              string             `json:"fix"`
}

// MaxExamples is the number of examples a finding carries at most.
const MaxExamples = 3

// NewFinding returns a finding of a registered code, with the code's level and fix. An unregistered code is a
// programming error and panics: codes are the constants of this package.
func NewFinding(code string) Finding {
	c, ok := Lookup(code)
	if !ok {
		panic("contract: unregistered code " + code)
	}
	return Finding{Code: c.ID, Level: c.Level, Fix: c.Fix}
}

// WithSubject sets the subject, sanitized by SafeName.
func (f Finding) WithSubject(s string) Finding {
	f.Subject, f.SubjectUntrusted = SafeName(s)
	return f
}

// WithNumber adds one number. Non-finite values are not representable in JSON and are left out.
func (f Finding) WithNumber(name string, v float64) Finding {
	if math.IsNaN(v) || math.IsInf(v, 0) {
		return f
	}
	m := make(map[string]float64, len(f.Numbers)+1)
	for k, x := range f.Numbers {
		m[k] = x
	}
	m[name] = v
	f.Numbers = m
	return f
}

// WithExamples adds examples, each sanitized by SafeName, up to MaxExamples in all.
func (f Finding) WithExamples(ex ...string) Finding {
	out := append([]string(nil), f.Examples...)
	for _, e := range ex {
		if len(out) >= MaxExamples {
			break
		}
		s, _ := SafeName(e)
		out = append(out, s)
	}
	if len(out) > 0 {
		f.Examples = out
	}
	return f
}

var nameRE = regexp.MustCompile(`^[A-Za-z0-9._:/@-]{1,128}$`)

// CheckStored reports why a finding read from a stored record is not one this registry makes, or nil when it is one:
// its code is registered, its level and fix are the code's, its numbers' names are the code's (Code.Numbers), and its
// subject and examples (at most MaxExamples) are names (ARCHITECTURE.md 5.4, Name). A stored record is not trusted to
// be this engine's (a baseline is made outside the server), and what a finding says reaches callers. The error names
// the code only when it is registered, and never a value of the finding.
func CheckStored(f Finding) error {
	c, ok := Lookup(f.Code)
	if !ok {
		return errors.New("a finding's code is not registered")
	}
	switch {
	case f.Level != c.Level:
		return fmt.Errorf("a finding of %s has another level than the code's", c.ID)
	case f.Fix != c.Fix:
		return fmt.Errorf("a finding of %s has another fix than the code's", c.ID)
	case f.Subject != "" && !nameRE.MatchString(f.Subject):
		return fmt.Errorf("a finding of %s has a subject that is not a name", c.ID)
	case len(f.Examples) > MaxExamples:
		return fmt.Errorf("a finding of %s has more than %d examples", c.ID, MaxExamples)
	}
	for _, e := range f.Examples {
		if !nameRE.MatchString(e) {
			return fmt.Errorf("a finding of %s has an example that is not a name", c.ID)
		}
	}
	for k := range f.Numbers {
		if !slices.Contains(c.Numbers, k) {
			return fmt.Errorf("a finding of %s has a number the code does not have", c.ID)
		}
	}
	return nil
}

// SafeName is the sanitizing rule for names (ARCHITECTURE.md 5.9): a string of at most 128 characters from
// [A-Za-z0-9._:/@-] is kept, unless the model's prefix of a peer node, ext:, starts a word of it anywhere but at its
// start (NodeInside); anything else becomes svc_ and the first 8 hex digits of its sha256, and untrusted is true. A
// name that starts with ext: is the model's node of a peer (ext:<peer>), which the views show as external_<hash8>. An
// AWS resource name (an ARN) names an account, a region and more: it is shown as its last element (ARNLast) unless that
// holds an account (holdsAccount: the ARN's own account field anywhere in it, or 12 digits in a row, as written or with
// its "-" taken out), and then hashed whole, as is any other name that holds arn: (NamesARN); all are untrusted. A
// stored record is shown through this rule whichever engine made it, so a rule of the reader that keeps an ARN out (an
// ECS task's id) holds for a record made without it too.
func SafeName(s string) (name string, untrusted bool) {
	if !strings.HasPrefix(s, nodePrefix) {
		if last, ok := ARNLast(s); ok && nameRE.MatchString(last) && !holdsAccount(s, last) {
			return last, true
		}
		if NamesARN(s) {
			return hashName(s), true
		}
	}
	if nameRE.MatchString(s) && !NodeInside(s) {
		return s, false
	}
	return hashName(s), true
}

// hashName is a name the rule does not keep: svc_ and the first 8 hex digits of its sha256.
func hashName(s string) string {
	sum := sha256.Sum256([]byte(s))
	return "svc_" + hex.EncodeToString(sum[:4])
}

// arnPrefix starts an AWS resource name: arn:partition:service:region:account:resource.
const arnPrefix = "arn:"

// ARNLast returns the last element of s, after the last "/" or ":" of its resource, when s is shaped like an AWS
// resource name: arn:, then a partition, a service, a region and an account (the last two may be empty), each ended by
// ":", then a resource. For an ECS task it is the task's id, as the reader keeps it (DATA.md 3.4). ok is false for
// any other s; last may be "" (a resource that ends in a separator).
func ARNLast(s string) (last string, ok bool) {
	parts := strings.SplitN(s, ":", 6)
	if len(parts) < 6 || parts[0]+":" != arnPrefix || parts[1] == "" || parts[2] == "" || parts[5] == "" {
		return "", false
	}
	r := parts[5]
	return r[strings.LastIndexAny(r, "/:")+1:], true
}

// NamesARN reports whether s holds an AWS resource name, or text that looks like one: arn:, in any case, at the start
// of s or after a character that is not a letter or a digit (so that "warn:" is not one, and "task_arn:" is), or
// anywhere before an AWS partition (arn:aws: or arn:aws-<...>:, as in "xarn:aws:").
func NamesARN(s string) bool {
	for i := 0; i+len(arnPrefix) <= len(s); i++ {
		if strings.EqualFold(s[i:i+len(arnPrefix)], arnPrefix) &&
			(i == 0 || !alnumByte(s[i-1]) || awsPartition(s[i+len(arnPrefix):])) {
			return true
		}
	}
	return false
}

// awsPartition reports whether s starts with an AWS partition: aws, in any case, then ":" or "-" (aws-cn, aws-us-gov).
func awsPartition(s string) bool {
	return len(s) > 3 && strings.EqualFold(s[:3], "aws") && (s[3] == ':' || s[3] == '-')
}

// holdsAccount reports whether last, the last element of the AWS resource name arn (ARNLast), may name an account, so
// that the name rule does not show it: it holds the ARN's own account field anywhere (an assumed role's session or a
// function named after the account, an id that embeds it), or 12 digits in a row (an account id, the ARN's own or
// another's, as an S3 object's name, whose ARN has no account field, may hold one), as written or with its "-" taken
// out (the dashed form the AWS console prints, 1111-2222-3333). A last element that happens to hold 12 digits in a
// row, or in groups joined by "-" (an ECS task's id given whole, an object named by a date and a time), is hashed too.
func holdsAccount(arn, last string) bool {
	undashed := strings.ReplaceAll(last, "-", "")
	if p := strings.SplitN(arn, ":", 6); len(p) == 6 && p[4] != "" &&
		(strings.Contains(last, p[4]) || strings.Contains(undashed, p[4])) {
		return true
	}
	run := 0
	for i := 0; i < len(undashed); i++ {
		if undashed[i] < '0' || undashed[i] > '9' {
			run = 0
		} else if run++; run == accountDigits {
			return true
		}
	}
	return false
}

// accountDigits is the length of an AWS account id.
const accountDigits = 12

// nodePrefix starts the model's node of a peer that no service of a capture answers: ext:<peer>, and ext:unknown
// (sanitize.ExternalPrefix).
const nodePrefix = "ext:"

// NodeInside reports whether ext:, the model's prefix of a peer node, starts a word of s after its first character:
// after a character outside [A-Za-z0-9_] (so that "next:" is not one). Such a string is trace text that only looks
// like a node, or a node inside other text (a route such as /status/ext:x), and no view shows it as written.
func NodeInside(s string) bool {
	for i := 1; i < len(s); i++ {
		if strings.HasPrefix(s[i:], nodePrefix) && !wordByte(s[i-1]) {
			return true
		}
	}
	return false
}

// wordByte reports whether c is in [A-Za-z0-9_].
func wordByte(c byte) bool {
	return c == '_' || alnumByte(c)
}

// alnumByte reports whether c is in [A-Za-z0-9].
func alnumByte(c byte) bool {
	return c >= '0' && c <= '9' || c >= 'A' && c <= 'Z' || c >= 'a' && c <= 'z'
}

var levelRank = map[Level]int{Refuse: 0, Doubt: 1, Note: 2}

// SortFindings orders findings as reports list them: refusals, then doubts, then notes; within a level by code, then
// subject, a subject as written before the same subject the name rule made (subject_untrusted).
func SortFindings(fs []Finding) {
	sort.SliceStable(fs, func(i, j int) bool {
		a, b := fs[i], fs[j]
		if levelRank[a.Level] != levelRank[b.Level] {
			return levelRank[a.Level] < levelRank[b.Level]
		}
		if a.Code != b.Code {
			return a.Code < b.Code
		}
		if a.Subject != b.Subject {
			return a.Subject < b.Subject
		}
		return !a.SubjectUntrusted && b.SubjectUntrusted
	})
}

// KeptShare is the share of requests a capture holds and how it was obtained (DATA.md 3.8): counted, derived-th,
// declared or assumed.
type KeptShare struct {
	Value  float64 `json:"value"`
	Source string  `json:"source"`
}

// The kept-share sources.
const (
	KeptCounted   = "counted"
	KeptDerivedTH = "derived-th"
	KeptDeclared  = "declared"
	KeptAssumed   = "assumed"
)

// CheckSchema is the schema id of a check report.
const CheckSchema = "rhobound.check/v1"

// The verdicts of a check report.
const (
	Admitted           = "admitted"
	AdmittedWithDoubts = "admitted-with-doubts"
	Refused            = "refused"
)

// CheckReport is what `rhobound check` reports (schema rhobound.check/v1): the verdict, every finding, how many findings
// each code raised, what the input carried that was ignored, the digest of the capture manifest, and the kept share.
type CheckReport struct {
	Schema    string           `json:"schema"`
	Contract  string           `json:"contract"`
	Verdict   string           `json:"verdict"`
	Findings  []Finding        `json:"findings"`
	Counts    map[string]int   `json:"counts"`
	Ignored   map[string]int64 `json:"ignored"`
	Manifest  string           `json:"manifest_sha256"`
	KeptShare KeptShare        `json:"kept_share"`
}

// NewCheckReport builds a report from its findings: sorted, counted, and the verdict they give.
func NewCheckReport(findings []Finding, ignored map[string]int64, manifestDigest string, kept KeptShare) *CheckReport {
	fs := append([]Finding{}, findings...)
	SortFindings(fs)
	r := &CheckReport{Schema: CheckSchema, Contract: Version, Verdict: Admitted, Findings: fs, Counts: map[string]int{},
		Ignored: map[string]int64{}, Manifest: manifestDigest, KeptShare: kept}
	for k, v := range ignored {
		r.Ignored[k] = v
	}
	for _, f := range fs {
		r.Counts[f.Code]++
		switch {
		case f.Level == Refuse:
			r.Verdict = Refused
		case f.Level == Doubt && r.Verdict == Admitted:
			r.Verdict = AdmittedWithDoubts
		}
	}
	return r
}

// Has reports whether the report carries a finding of this code.
func (r *CheckReport) Has(code string) bool { return r.Counts[code] > 0 }

// ------------------------------------------------------------------ canonical JSON

// Canonical returns the canonical JSON of v: object keys sorted, no insignificant whitespace, no HTML escaping, numbers
// as encoding/json writes them, and no trailing newline. Content ids (Digest) are computed over these bytes, and every
// view, record and report that is compared byte for byte (a CLI twin and its MCP tool) is written in this form.
func Canonical(v any) ([]byte, error) {
	raw, err := marshalNoEscape(v)
	if err != nil {
		return nil, err
	}
	return CanonicalizeJSON(raw)
}

// CanonicalizeJSON rewrites one JSON value in canonical form (see Canonical). Numbers keep their text.
func CanonicalizeJSON(raw []byte) ([]byte, error) {
	dec := json.NewDecoder(bytes.NewReader(raw))
	dec.UseNumber()
	var x any
	if err := dec.Decode(&x); err != nil {
		return nil, err
	}
	if dec.More() {
		return nil, fmt.Errorf("canonical JSON: more than one value")
	}
	return marshalNoEscape(x)
}

func marshalNoEscape(v any) ([]byte, error) {
	var b bytes.Buffer
	enc := json.NewEncoder(&b)
	enc.SetEscapeHTML(false)
	if err := enc.Encode(v); err != nil {
		return nil, err
	}
	return bytes.TrimSuffix(b.Bytes(), []byte("\n")), nil
}

// Digest is the content id of some bytes: "sha256:" and the hex of their sha256.
func Digest(b []byte) string {
	s := sha256.Sum256(b)
	return "sha256:" + hex.EncodeToString(s[:])
}

// DigestOf is the content id of v's canonical JSON.
func DigestOf(v any) (string, error) {
	b, err := Canonical(v)
	if err != nil {
		return "", err
	}
	return Digest(b), nil
}

// SHA256Hex is the bare hex sha256 of some bytes, as capture manifests list files.
func SHA256Hex(b []byte) string {
	s := sha256.Sum256(b)
	return hex.EncodeToString(s[:])
}

// Domain returns the domain of a code: the part before the dot.
func Domain(code string) string {
	d, _, _ := strings.Cut(code, ".")
	return d
}
