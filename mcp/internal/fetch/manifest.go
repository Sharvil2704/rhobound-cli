// SPDX-License-Identifier: Apache-2.0

package fetch

import (
	"bytes"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"time"
)

// The preliminary capture manifest (DATA.md 4.5, capture-manifest.v1.json). It lists the downloaded files by name
// (relative to the manifest's folder), with the size, ETag and sha256 of each; the window as requested, not yet
// cut ("cut": "none"); the margins; the partition time zone; and the prefix only as its digest. Sampling evidence
// is "assumed" until `rhobound check` reads a request count or a sampling threshold; check --cut writes the final
// manifest.
type manifestObject struct {
	Name   string `json:"name"`
	Size   int64  `json:"size"`
	ETag   string `json:"etag,omitempty"`
	SHA256 string `json:"sha256"`
}

type manifestDoc struct {
	Schema string `json:"schema"`
	Source struct {
		Kind         string `json:"kind"`
		Env          string `json:"env,omitempty"`
		PrefixDigest string `json:"prefix_digest"`
	} `json:"source"`
	Window struct {
		Start string `json:"start"`
		End   string `json:"end"`
		Cut   string `json:"cut"`
	} `json:"window"`
	MarginsS struct {
		Before           float64 `json:"before"`
		After            float64 `json:"after"`
		AfterDerivedFrom string  `json:"after_derived_from"`
	} `json:"margins_s"`
	PartitionTimezone struct {
		Configured     string `json:"configured"`
		DerivedOffsetH int    `json:"derived_offset_h"`
	} `json:"partition_timezone"`
	Objects  []manifestObject `json:"objects"`
	Sampling struct {
		Evidence string `json:"evidence"`
	} `json:"sampling"`
	Limits struct {
		MaxObjectBytes  int64 `json:"max_object_bytes"`
		MaxCaptureBytes int64 `json:"max_capture_bytes"`
	} `json:"limits"`
}

// storeKind names the store in the manifest: a store says its kind with a Kind method (objstore.Dir: "dir");
// any other store is the S3 binding.
func storeKind(st any) string {
	if k, ok := st.(interface{ Kind() string }); ok {
		return k.Kind()
	}
	return "s3"
}

func newManifest(cfg EnvConfig, req Request, objs []*listed, after time.Duration, afterFrom string) []byte {
	var m manifestDoc
	m.Schema = "rhobound.capture-manifest/v1"
	m.Source.Kind = storeKind(cfg.Store)
	m.Source.Env = req.Env
	sum := sha256.Sum256([]byte(cfg.Prefix))
	m.Source.PrefixDigest = "sha256:" + hex.EncodeToString(sum[:])
	m.Window.Start = req.Start.UTC().Format(time.RFC3339Nano)
	m.Window.End = req.End.UTC().Format(time.RFC3339Nano)
	m.Window.Cut = "none"
	m.MarginsS.Before = MarginBefore.Seconds()
	m.MarginsS.After = after.Seconds()
	m.MarginsS.AfterDerivedFrom = afterFrom
	m.PartitionTimezone.Configured = "UTC"
	if off, _, ok := partitionOffset(objs); ok {
		m.PartitionTimezone.DerivedOffsetH = int(off.Round(time.Hour) / time.Hour)
	}
	for _, o := range objs {
		m.Objects = append(m.Objects, manifestObject{Name: o.name, Size: o.Size, ETag: o.ETag, SHA256: o.sha})
	}
	m.Sampling.Evidence = "assumed"
	m.Limits.MaxObjectBytes = MaxObjectBytes
	m.Limits.MaxCaptureBytes = MaxCaptureBytes
	return canonical(m)
}

// canonical encodes v as canonical JSON: keys sorted, no insignificant whitespace, numbers as encoding/json
// writes them.
func canonical(v any) []byte {
	b, err := json.Marshal(v)
	if err != nil {
		panic(err) // the manifest holds only strings, integers and finite floats
	}
	dec := json.NewDecoder(bytes.NewReader(b))
	dec.UseNumber()
	var generic any
	if err := dec.Decode(&generic); err != nil {
		panic(err)
	}
	var out bytes.Buffer
	enc := json.NewEncoder(&out)
	enc.SetEscapeHTML(false)
	if err := enc.Encode(generic); err != nil {
		panic(err)
	}
	return bytes.TrimSuffix(out.Bytes(), []byte("\n"))
}
