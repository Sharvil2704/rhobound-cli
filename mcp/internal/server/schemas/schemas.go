// SPDX-License-Identifier: Apache-2.0

// Package schemas holds the published JSON Schemas (docs/mcp/schemas) that the server needs at run time, and turns a
// schema that refers to defs.v1.json into one self-contained document.
//
// The files here are byte copies of the published ones: go:embed cannot reach outside the module, and the SDK resolves
// a tool's schema without a loader, so a schema it is given must not refer to another file. A test compares the copies
// with docs/mcp/schemas; refresh them with
//
//	cp docs/mcp/schemas/<file> mcp/internal/server/schemas/
package schemas

import (
	"bytes"
	"embed"
	"encoding/json"
	"fmt"
	"io/fs"
	"sort"
	"strings"

	"github.com/google/jsonschema-go/jsonschema"
)

//go:embed *.json
var files embed.FS

// defsFile is the file of shared definitions; a reference into it is written defsFile + "#/$defs/<name>".
const defsFile = "defs.v1.json"

// Names lists the embedded schema files, sorted.
func Names() []string {
	ents, _ := fs.ReadDir(files, ".")
	var out []string
	for _, e := range ents {
		out = append(out, e.Name())
	}
	sort.Strings(out)
	return out
}

// File returns an embedded schema file's bytes.
func File(name string) ([]byte, error) {
	return files.ReadFile(name)
}

// Bundle returns the schema at ptr in the file name ("" for the file's root, or "/$defs/<name>") as one
// self-contained document: every $ref into defs.v1.json, or into the file's own $defs, is rewritten to #/$defs/<name>
// and the definitions it reaches are copied into a local $defs. $schema, $id and title are dropped, so the result
// resolves without a loader and without a base URI. Keys come out sorted, so the bytes are stable.
func Bundle(name, ptr string) (json.RawMessage, error) {
	root, err := load(name)
	if err != nil {
		return nil, err
	}
	shared, err := load(defsFile)
	if err != nil {
		return nil, err
	}
	target := any(root)
	switch {
	case ptr == "":
	case strings.HasPrefix(ptr, "/$defs/") && !strings.Contains(ptr[len("/$defs/"):], "/"):
		target = defsOf(root)[ptr[len("/$defs/"):]]
		if target == nil {
			return nil, fmt.Errorf("schemas: %s has no %s", name, ptr)
		}
	default:
		return nil, fmt.Errorf("schemas: pointer %q is not supported (use \"\" or /$defs/<name>)", ptr)
	}
	b := &bundler{file: name, local: defsOf(root), shared: defsOf(shared), out: map[string]any{}}
	top, ok := b.walk(target, name).(map[string]any)
	if !ok {
		return nil, fmt.Errorf("schemas: %s%s is not an object", name, ptr)
	}
	if b.err != nil {
		return nil, b.err
	}
	if ptr == "" {
		delete(top, "$defs")
	} else if _, has := top["$defs"]; has {
		return nil, fmt.Errorf("schemas: %s%s has its own $defs", name, ptr)
	}
	for _, k := range []string{"$schema", "$id", "title"} {
		delete(top, k)
	}
	if len(b.out) > 0 {
		top["$defs"] = b.out
	}
	var buf bytes.Buffer
	enc := json.NewEncoder(&buf)
	enc.SetEscapeHTML(false)
	if err := enc.Encode(top); err != nil {
		return nil, err
	}
	return json.RawMessage(bytes.TrimSuffix(buf.Bytes(), []byte("\n"))), nil
}

// Resolve prepares a bundled schema for validation.
func Resolve(bundled []byte) (*jsonschema.Resolved, error) {
	var s jsonschema.Schema
	if err := json.Unmarshal(bundled, &s); err != nil {
		return nil, err
	}
	return s.Resolve(&jsonschema.ResolveOptions{ValidateDefaults: true})
}

func load(name string) (map[string]any, error) {
	raw, err := files.ReadFile(name)
	if err != nil {
		return nil, fmt.Errorf("schemas: %w", err)
	}
	var m map[string]any
	if err := json.Unmarshal(raw, &m); err != nil {
		return nil, fmt.Errorf("schemas: %s: %w", name, err)
	}
	return m, nil
}

func defsOf(m map[string]any) map[string]any {
	d, _ := m["$defs"].(map[string]any)
	return d
}

// bundler copies a schema tree, rewriting references and collecting the definitions they reach.
type bundler struct {
	file          string
	local, shared map[string]any
	out           map[string]any
	from          map[string]string // collected definition -> the file it came from
	err           error
}

// walk returns a copy of v with every $ref rewritten. in is the file v belongs to.
func (b *bundler) walk(v any, in string) any {
	switch t := v.(type) {
	case map[string]any:
		c := make(map[string]any, len(t))
		for k, x := range t {
			if k == "$ref" {
				if s, ok := x.(string); ok {
					c[k] = b.ref(s, in)
					continue
				}
			}
			c[k] = b.walk(x, in)
		}
		return c
	case []any:
		c := make([]any, len(t))
		for i, x := range t {
			c[i] = b.walk(x, in)
		}
		return c
	default:
		return v
	}
}

// ref rewrites one reference made from the file in, and copies the definition it names into the bundle.
func (b *bundler) ref(r, in string) string {
	file, frag, _ := strings.Cut(r, "#")
	if file == "" {
		file = in
	}
	name, ok := strings.CutPrefix(frag, "/$defs/")
	if !ok || name == "" || strings.Contains(name, "/") {
		b.fail(fmt.Errorf("schemas: %s: reference %q is not to a definition", in, r))
		return r
	}
	var src map[string]any
	switch file {
	case defsFile:
		src = b.shared
	case b.file:
		src = b.local
	default:
		b.fail(fmt.Errorf("schemas: %s: reference %q leaves the bundle", in, r))
		return r
	}
	if b.from == nil {
		b.from = map[string]string{}
	}
	if prev, seen := b.from[name]; seen {
		if prev != file {
			b.fail(fmt.Errorf("schemas: definition %q exists in both %s and %s", name, prev, file))
		}
		return "#/$defs/" + name
	}
	def, ok := src[name]
	if !ok {
		b.fail(fmt.Errorf("schemas: %s: %q names no definition", in, r))
		return r
	}
	b.from[name] = file
	b.out[name] = nil // reserve the name before walking, so a definition that refers to itself terminates
	b.out[name] = b.walk(def, file)
	return "#/$defs/" + name
}

func (b *bundler) fail(err error) {
	if b.err == nil {
		b.err = err
	}
}
