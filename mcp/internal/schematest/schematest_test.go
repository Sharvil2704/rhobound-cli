// SPDX-License-Identifier: Apache-2.0

package schematest

import (
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func load(t *testing.T) (*Set, string) {
	t.Helper()
	s, err := LoadRepo()
	if err != nil {
		t.Fatal(err)
	}
	root, err := RepoRoot()
	if err != nil {
		t.Fatal(err)
	}
	return s, root
}

// Every schema of the folder resolves, its tool input too, and every relative reference reaches a definition.
func TestEverySchemaResolves(t *testing.T) {
	s, _ := load(t)
	if len(s.Files()) < 25 {
		t.Fatalf("only %d schemas: %v", len(s.Files()), s.Files())
	}
	for _, f := range s.Files() {
		if _, err := s.Resolve(f, ""); err != nil {
			t.Errorf("%s: %v", f, err)
		}
		var d struct {
			Defs map[string]json.RawMessage `json:"$defs"`
		}
		if err := json.Unmarshal(s.Raw(f), &d); err != nil {
			t.Fatal(err)
		}
		for name := range d.Defs {
			if _, err := s.Resolve(f, "/$defs/"+name); err != nil {
				t.Errorf("%s#/$defs/%s: %v", f, name, err)
			}
		}
	}
}

// The schema of a document rejects what it must reject: an unknown key in a closed object, a code outside the
// pattern, and a view without its schema id.
func TestSchemasReject(t *testing.T) {
	s, _ := load(t)
	for _, c := range []struct{ file, ptr, doc string }{
		{"defs.v1.json", "/$defs/Finding", `{"code":"trace.ok","level":"doubt","fix":"x","extra":1}`},
		{"defs.v1.json", "/$defs/Finding", `{"code":"Trace.Bad","level":"doubt","fix":"x"}`},
		{"defs.v1.json", "/$defs/Code", `"no_domain"`},
		{"refusal.v1.json", "", `{"error":{"code":"change.free_text","reason":"r"}}`},
		{"request-count.v1.json", "", `{"schema":"rhobound.request-count/v1"}`},
		{"policy.v1.json", "", `{"schema":"rhobound.policy/v1"}`},
		{"judge-answer.v1.json", "", `{"schema":"rhobound-mcp.judge-answer/v1","packet":"sha256:x","decision":"accept"}`},
	} {
		if err := s.Validate(c.file, c.ptr, []byte(c.doc)); err == nil {
			t.Errorf("%s#%s accepts %s", c.file, c.ptr, c.doc)
		}
	}
}

// golden is a committed file and the schema it must validate against: the whole document, or (each) every element of
// an array.
type golden struct {
	glob      string // relative to the repository's root
	file, ptr string
	each      bool
}

var goldens = []golden{
	// WP-independent fixtures and examples of this repository
	{"examples/mcp/policy.example.json", "policy.v1.json", "", false},
	{"examples/mcp/config.example.json", "config.v1.json", "", false},
	{"testdata/mcp/loop/policy.json", "policy.v1.json", "", false},
	{"testdata/mcp/loop/request-count.json", "request-count.v1.json", "", false},
	{"testdata/mcp/loop/ab/*/request-count.json", "request-count.v1.json", "", false},
	{"testdata/mcp/hostile/request-count.json", "request-count.v1.json", "", false},
	{"testdata/mcp/loop/judge-answer.json", "judge-answer.v1.json", "", false},
	{"docs/mcp/data-contract.json", "data-contract.v1.json", "", false},
	// the views' goldens (internal/views)
	{"internal/views/testdata/context.golden.json", "context.v1.json", "", false},
	{"internal/views/testdata/budget.golden.json", "budget.v1.json", "", false},
	{"internal/views/testdata/prediction-*.golden.json", "prediction.v1.json", "", false},
	{"internal/views/testdata/explain-*.golden.json", "explain.v1.json", "", false},
	{"internal/views/testdata/judge-packet.golden.json", "judge-packet.v1.json", "", false},
	// the report v1 outputs of the 1a2df09 golden sweep
	{"testdata/golden-1a2df09/*/*.json", "report.v1.json", "", false},
	// the window fetcher and the OCI client (mcp/internal/fetch, mcp/internal/oci)
	{"mcp/internal/fetch/testdata/manifest.golden.json", "capture-manifest.v1.json", "", false},
	{"mcp/internal/fetch/testdata/findings.golden.json", "defs.v1.json", "/$defs/Finding", true},
	{"mcp/internal/fetch/testdata/refusals.golden.json", "defs.v1.json", "/$defs/Refusal", true},
	{"mcp/internal/oci/testdata/findings.golden.json", "defs.v1.json", "/$defs/Finding", true},
	{"mcp/internal/oci/testdata/profile-valid.json", "perf-profile.v0.1.json", "", false},
}

// Every golden and example validates against its schema.
func TestGoldens(t *testing.T) {
	s, root := load(t)
	for _, g := range goldens {
		paths, err := filepath.Glob(filepath.Join(root, filepath.FromSlash(g.glob)))
		if err != nil || len(paths) == 0 {
			t.Errorf("%s: no file (%v)", g.glob, err)
			continue
		}
		for _, p := range paths {
			if strings.HasSuffix(p, "manifest.json") {
				continue // the golden sweep's own manifest, not a report
			}
			b, err := os.ReadFile(p)
			if err != nil {
				t.Fatal(err)
			}
			rel, _ := filepath.Rel(root, p)
			if g.each {
				err = s.ValidateEach(g.file, g.ptr, b)
			} else {
				err = s.Validate(g.file, g.ptr, b)
			}
			if err != nil {
				t.Errorf("%s against %s#%s: %v", filepath.ToSlash(rel), g.file, g.ptr, err)
			}
		}
	}
}
