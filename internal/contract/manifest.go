// SPDX-License-Identifier: Apache-2.0

package contract

import (
	"bytes"
	"encoding/json"
	"fmt"
	"path"
	"regexp"
	"strings"
	"time"
)

// ManifestSchema is the schema id of a capture manifest.
const ManifestSchema = "rhobound.capture-manifest/v1"

// Manifest is a capture manifest (rhobound.capture-manifest/v1, DATA.md 4.5): the files of one capture with their
// sha256, the window and how it was cut, and where the data came from. The capture's identity is Digest(), the sha256
// of the canonical manifest. It names no bucket: an S3 prefix is recorded only as its digest.
type Manifest struct {
	Schema      string       `json:"schema"`
	Source      Source       `json:"source"`
	Window      Window       `json:"window"`
	Margins     *Margins     `json:"margins_s,omitempty"`
	PartitionTZ *PartitionTZ `json:"partition_timezone,omitempty"`
	Objects     []Object     `json:"objects"`
	Dropped     *Dropped     `json:"dropped,omitempty"`
	Collector   *Collector   `json:"collector,omitempty"`
	KeepList    string       `json:"keep_list_sha256,omitempty"`
	Sampling    Sampling     `json:"sampling"`
	ClusterDump *ClusterDump `json:"cluster_dump,omitempty"`
	Limits      Limits       `json:"limits"`

	// Dir is the folder the object names are relative to. It is where the manifest was read from or written to, is
	// never serialized, and is not part of the capture's identity.
	Dir string `json:"-"`
	// Partial is true when the manifest lists some files of its folder only (a capture given as one trace file): the
	// folder's other files are not the capture's, and are not counted against it. Never serialized.
	Partial bool `json:"-"`
}

// Source says where a capture came from: an S3 window (with the environment and the digest of its configured prefix)
// or a local folder.
type Source struct {
	Kind         string `json:"kind"` // "s3" or "dir"
	Env          string `json:"env,omitempty"`
	PrefixDigest string `json:"prefix_digest,omitempty"`
}

// The window cuts.
const (
	CutEntrySpanStart = "entry_span_start"
	CutNone           = "none"
)

// Window is the capture's window. Cut is CutEntrySpanStart for a capture cut by `check --cut`, CutNone for a whole
// folder, whose window is then the span of its data.
type Window struct {
	Start time.Time `json:"start"`
	End   time.Time `json:"end"`
	Cut   string    `json:"cut"`
}

// Margins are the seconds read before and after the window (DATA.md 3.9).
type Margins struct {
	Before           float64 `json:"before"`
	After            float64 `json:"after"`
	AfterDerivedFrom string  `json:"after_derived_from,omitempty"`
}

// PartitionTZ is the time zone of an S3 exporter's partitions: as configured, and the offset derived from span starts.
type PartitionTZ struct {
	Configured     string `json:"configured"`
	DerivedOffsetH int    `json:"derived_offset_h"`
}

// Object is one file of the capture: its name relative to the manifest's folder (derived from the object's key path,
// never a bucket), its size and its sha256.
type Object struct {
	Name   string `json:"name"`
	Size   int64  `json:"size"`
	ETag   string `json:"etag,omitempty"`
	SHA256 string `json:"sha256"`
}

// Dropped counts what the cut left out.
type Dropped struct {
	DuplicateSpans      int64 `json:"duplicate_spans"`
	PartialTailLines    int64 `json:"partial_tail_lines"`
	TracesOutsideWindow int64 `json:"traces_outside_window"`
}

// Collector describes the capture Collector (DATA.md 4.1).
type Collector struct {
	ConfigSHA256 string `json:"config_sha256,omitempty"`
	Distribution string `json:"distribution,omitempty"`
	Version      string `json:"version,omitempty"`
	Mode         string `json:"mode"` // "direct" or "forwarded"
}

// Sampling is the evidence about sampling (DATA.md 3.8): its kind (a KeptShare source), the digest of the independent
// request count when there was one, and the SDK samplers declared per service.
type Sampling struct {
	Evidence            string            `json:"evidence"`
	IndependentCount    *string           `json:"independent_count,omitempty"`
	DeclaredSDKSamplers map[string]string `json:"declared_sdk_samplers,omitempty"`
}

// The cluster dump layouts.
const (
	LayoutStartEnd       = "start-end"
	LayoutSingleSnapshot = "single-snapshot"
)

// ClusterDump records the cluster dumps of the capture (DATA.md 5): their layout, digests, and when they were taken.
type ClusterDump struct {
	Layout string `json:"layout"`
	Start  *Dump  `json:"start,omitempty"`
	End    *Dump  `json:"end,omitempty"`
}

// Dump is one cluster dump: its digest, and the time it was taken (absent: cluster.time_unknown).
type Dump struct {
	Digest  string     `json:"digest"`
	TakenAt *time.Time `json:"taken_at,omitempty"`
}

// Limits are the reading limits the capture was read under.
type Limits struct {
	MaxObjectBytes  int64 `json:"max_object_bytes"`
	MaxCaptureBytes int64 `json:"max_capture_bytes"`
}

// Canonical is the manifest's canonical JSON (see Canonical). Its times are written in UTC.
func (m *Manifest) Canonical() []byte {
	c := *m
	c.Window.Start, c.Window.End = c.Window.Start.UTC(), c.Window.End.UTC()
	if d := c.ClusterDump; d != nil {
		cd := *d
		cd.Start, cd.End = utcDump(d.Start), utcDump(d.End)
		c.ClusterDump = &cd
	}
	b, err := Canonical(&c)
	if err != nil {
		// Only a NaN or infinite margin can fail to marshal; ParseManifest refuses those.
		panic("contract: manifest does not marshal: " + err.Error())
	}
	return b
}

func utcDump(d *Dump) *Dump {
	if d == nil || d.TakenAt == nil {
		return d
	}
	c := *d
	t := d.TakenAt.UTC()
	c.TakenAt = &t
	return &c
}

// Digest is the capture's identity: "sha256:" and the hex sha256 of the canonical manifest.
func (m *Manifest) Digest() string { return Digest(m.Canonical()) }

var (
	hex64RE  = regexp.MustCompile(`^[0-9a-f]{64}$`)
	digestRE = regexp.MustCompile(`^sha256:[0-9a-f]{64}$`)
	envRE    = regexp.MustCompile(`^[a-z0-9-]{1,40}$`)
)

// ParseManifest reads a capture manifest and checks it against rhobound.capture-manifest/v1: unknown keys, missing
// required fields, values out of their sets, and object names that would leave the manifest's folder are errors.
func ParseManifest(b []byte) (*Manifest, error) {
	dec := json.NewDecoder(bytes.NewReader(b))
	dec.DisallowUnknownFields()
	var m Manifest
	if err := dec.Decode(&m); err != nil {
		return nil, fmt.Errorf("capture manifest: %w", err)
	}
	if dec.More() {
		return nil, fmt.Errorf("capture manifest: more than one JSON value")
	}
	if err := m.Validate(); err != nil {
		return nil, err
	}
	return &m, nil
}

// Validate checks a manifest against the rules ParseManifest applies.
func (m *Manifest) Validate() error {
	bad := func(f string, a ...any) error { return fmt.Errorf("capture manifest: "+f, a...) }
	if m.Schema != ManifestSchema {
		return bad("schema %q, want %q", m.Schema, ManifestSchema)
	}
	switch m.Source.Kind {
	case "s3", "dir":
	default:
		return bad("source.kind %q is not s3 or dir", m.Source.Kind)
	}
	if m.Source.Env != "" && !envRE.MatchString(m.Source.Env) {
		return bad("source.env %q is not an environment name", m.Source.Env)
	}
	if m.Source.PrefixDigest != "" && !digestRE.MatchString(m.Source.PrefixDigest) {
		return bad("source.prefix_digest is not sha256:<hex>")
	}
	if m.Window.Start.IsZero() || m.Window.End.IsZero() || m.Window.End.Before(m.Window.Start) {
		return bad("window: start and end are required, start not after end")
	}
	if m.Window.Cut != CutEntrySpanStart && m.Window.Cut != CutNone {
		return bad("window.cut %q is not %s or %s", m.Window.Cut, CutEntrySpanStart, CutNone)
	}
	if mg := m.Margins; mg != nil && !(mg.Before >= 0 && mg.After >= 0 && mg.Before < 1e9 && mg.After < 1e9) {
		return bad("margins_s must be finite and not negative")
	}
	if len(m.Objects) == 0 {
		return bad("no objects")
	}
	seen := map[string]bool{}
	for _, o := range m.Objects {
		if err := CheckObjectName(o.Name); err != nil {
			return bad("%v", err)
		}
		if seen[o.Name] {
			return bad("object %q listed twice", o.Name)
		}
		seen[o.Name] = true
		if o.Size < 0 || !hex64RE.MatchString(o.SHA256) {
			return bad("object %q: size must not be negative and sha256 must be 64 lower-case hex digits", o.Name)
		}
	}
	if d := m.Dropped; d != nil && (d.DuplicateSpans < 0 || d.PartialTailLines < 0 || d.TracesOutsideWindow < 0) {
		return bad("dropped counts must not be negative")
	}
	if c := m.Collector; c != nil {
		if c.Mode != "direct" && c.Mode != "forwarded" {
			return bad("collector.mode %q is not direct or forwarded", c.Mode)
		}
		if c.ConfigSHA256 != "" && !hex64RE.MatchString(c.ConfigSHA256) {
			return bad("collector.config_sha256 is not 64 lower-case hex digits")
		}
	}
	if m.KeepList != "" && !hex64RE.MatchString(m.KeepList) {
		return bad("keep_list_sha256 is not 64 lower-case hex digits")
	}
	switch m.Sampling.Evidence {
	case KeptCounted, KeptDerivedTH, KeptDeclared, KeptAssumed:
	default:
		return bad("sampling.evidence %q is not counted, derived-th, declared or assumed", m.Sampling.Evidence)
	}
	if ic := m.Sampling.IndependentCount; ic != nil && !digestRE.MatchString(*ic) {
		return bad("sampling.independent_count is not sha256:<hex>")
	}
	if d := m.ClusterDump; d != nil {
		if d.Layout != LayoutStartEnd && d.Layout != LayoutSingleSnapshot {
			return bad("cluster_dump.layout %q is not %s or %s", d.Layout, LayoutStartEnd, LayoutSingleSnapshot)
		}
		for _, x := range []*Dump{d.Start, d.End} {
			if x != nil && !digestRE.MatchString(x.Digest) {
				return bad("cluster_dump digest is not sha256:<hex>")
			}
		}
	}
	if m.Limits.MaxObjectBytes < 1 || m.Limits.MaxCaptureBytes < 1 {
		return bad("limits must be at least 1")
	}
	return nil
}

// CheckObjectName refuses an object name that is empty, absolute, not clean, or that would leave the manifest's
// folder: a manifest names files inside its own folder only.
func CheckObjectName(name string) error {
	if name == "" || strings.HasPrefix(name, "/") || strings.Contains(name, "\\") || strings.ContainsRune(name, 0) ||
		path.Clean(name) != name || name == ".." || strings.HasPrefix(name, "../") || name == "." {
		return fmt.Errorf("object name %q is not a clean relative path inside the manifest's folder", name)
	}
	return nil
}
