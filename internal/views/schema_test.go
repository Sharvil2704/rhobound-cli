// SPDX-License-Identifier: Apache-2.0

package views

import (
	"encoding/json"
	"fmt"
	"math"
	"os"
	"path/filepath"
	"regexp"
	"strings"
	"testing"
)

// schemaDir is the folder of the published JSON Schemas.
var schemaDir = filepath.Join("..", "..", "docs", "mcp", "schemas")

// validate checks a document against a published schema with the subset of JSON Schema 2020-12 the views' schemas
// use: $ref (relative), type, const, enum, properties, required, additionalProperties, items, maxItems, pattern,
// minimum, maximum, oneOf, anyOf, allOf. It is a guard for this package's own tests; the mcp module validates with a
// full implementation.
func validate(t *testing.T, file string, doc []byte) {
	t.Helper()
	var v any
	if err := json.Unmarshal(doc, &v); err != nil {
		t.Fatal(err)
	}
	s := &schemaSet{t: t, docs: map[string]map[string]any{}}
	root := s.load(file)
	if errs := s.check(file, root, v, "$"); len(errs) > 0 {
		t.Errorf("%s does not validate:\n  %s", file, strings.Join(errs, "\n  "))
	}
}

type schemaSet struct {
	t    *testing.T
	docs map[string]map[string]any
}

func (s *schemaSet) load(file string) map[string]any {
	if d, ok := s.docs[file]; ok {
		return d
	}
	b, err := os.ReadFile(filepath.Join(schemaDir, file))
	if err != nil {
		s.t.Fatal(err)
	}
	var d map[string]any
	if err := json.Unmarshal(b, &d); err != nil {
		s.t.Fatal(err)
	}
	s.docs[file] = d
	return d
}

func (s *schemaSet) resolve(file, ref string) (string, map[string]any) {
	f, ptr, _ := strings.Cut(ref, "#")
	if f != "" {
		file = f
	}
	var cur any = s.load(file)
	for _, part := range strings.Split(strings.TrimPrefix(ptr, "/"), "/") {
		if part == "" {
			continue
		}
		cur = cur.(map[string]any)[part]
	}
	return file, cur.(map[string]any)
}

func (s *schemaSet) check(file string, sc map[string]any, v any, at string) []string {
	var errs []string
	fail := func(f string, a ...any) { errs = append(errs, at+": "+fmt.Sprintf(f, a...)) }
	if ref, ok := sc["$ref"].(string); ok {
		f, r := s.resolve(file, ref)
		errs = append(errs, s.check(f, r, v, at)...)
	}
	if c, ok := sc["const"]; ok && fmt.Sprint(c) != fmt.Sprint(v) {
		fail("not the const %v", c)
	}
	if e, ok := sc["enum"].([]any); ok {
		found := false
		for _, x := range e {
			found = found || fmt.Sprint(x) == fmt.Sprint(v)
		}
		if !found {
			fail("%v not in %v", v, e)
		}
	}
	if ty, ok := sc["type"]; ok && !typeOK(ty, v) {
		fail("%v is not of type %v", v, ty)
	}
	if p, ok := sc["pattern"].(string); ok {
		if str, isStr := v.(string); isStr && !regexp.MustCompile(p).MatchString(str) {
			fail("%q does not match %s", str, p)
		}
	}
	if n, ok := v.(float64); ok {
		if m, ok := sc["minimum"].(float64); ok && n < m {
			fail("%v below %v", n, m)
		}
		if m, ok := sc["maximum"].(float64); ok && n > m {
			fail("%v above %v", n, m)
		}
	}
	for _, x := range anyList(sc["allOf"]) {
		errs = append(errs, s.check(file, x, v, at)...)
	}
	if xs := anyList(sc["oneOf"]); len(xs) > 0 {
		n := 0
		for _, x := range xs {
			if len(s.check(file, x, v, at)) == 0 {
				n++
			}
		}
		if n != 1 {
			fail("matches %d of oneOf", n)
		}
	}
	if xs := anyList(sc["anyOf"]); len(xs) > 0 {
		n := 0
		for _, x := range xs {
			if len(s.check(file, x, v, at)) == 0 {
				n++
			}
		}
		if n == 0 {
			fail("matches none of anyOf")
		}
	}
	if obj, ok := v.(map[string]any); ok {
		props, _ := sc["properties"].(map[string]any)
		for _, r := range anyStrings(sc["required"]) {
			if _, ok := obj[r]; !ok {
				fail("lacks %s", r)
			}
		}
		for k, x := range obj {
			if p, ok := props[k].(map[string]any); ok {
				errs = append(errs, s.check(file, p, x, at+"."+k)...)
				continue
			}
			switch ap := sc["additionalProperties"].(type) {
			case bool:
				if !ap && props != nil {
					fail("key %s is not in the schema", k)
				}
			case map[string]any:
				errs = append(errs, s.check(file, ap, x, at+"."+k)...)
			}
		}
	}
	if arr, ok := v.([]any); ok {
		if m, ok := sc["maxItems"].(float64); ok && float64(len(arr)) > m {
			fail("%d items, at most %v", len(arr), m)
		}
		if it, ok := sc["items"].(map[string]any); ok {
			for i, x := range arr {
				errs = append(errs, s.check(file, it, x, fmt.Sprintf("%s[%d]", at, i))...)
			}
		}
	}
	return errs
}

func typeOK(ty any, v any) bool {
	switch x := ty.(type) {
	case string:
		switch x {
		case "object":
			_, ok := v.(map[string]any)
			return ok
		case "array":
			_, ok := v.([]any)
			return ok
		case "string":
			_, ok := v.(string)
			return ok
		case "number":
			_, ok := v.(float64)
			return ok
		case "integer":
			n, ok := v.(float64)
			return ok && n == math.Trunc(n)
		case "boolean":
			_, ok := v.(bool)
			return ok
		case "null":
			return v == nil
		}
	case []any:
		for _, y := range x {
			if typeOK(y, v) {
				return true
			}
		}
	}
	return false
}

func anyList(v any) []map[string]any {
	xs, _ := v.([]any)
	var out []map[string]any
	for _, x := range xs {
		if m, ok := x.(map[string]any); ok {
			out = append(out, m)
		}
	}
	return out
}

func anyStrings(v any) []string {
	xs, _ := v.([]any)
	var out []string
	for _, x := range xs {
		if s, ok := x.(string); ok {
			out = append(out, s)
		}
	}
	return out
}
