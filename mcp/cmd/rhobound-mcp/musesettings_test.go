// SPDX-License-Identifier: Apache-2.0

package main

import (
	"encoding/json"
	"errors"
	"reflect"
	"strings"
	"testing"
)

var testEntry = newMuseEntry("/opt/rb/bin/rhobound-mcp", "/home/u/.config/rhobound-mcp/config.json", true)

// entryIn decodes the rhobound entry of a settings document, and which spellings of the table it holds.
func entryIn(t *testing.T, doc []byte) (museEntry, []string) {
	t.Helper()
	var top map[string]json.RawMessage
	if err := json.Unmarshal(doc, &top); err != nil {
		t.Fatalf("not JSON: %v\n%s", err, doc)
	}
	var keys []string
	var e museEntry
	for _, k := range museServersKeys {
		if raw, ok := top[k]; ok {
			keys = append(keys, k)
			var servers map[string]json.RawMessage
			if err := json.Unmarshal(raw, &servers); err != nil {
				t.Fatal(err)
			}
			if err := json.Unmarshal(servers[museServerKey], &e); err != nil {
				t.Fatalf("%s.rhobound: %v", k, err)
			}
		}
	}
	return e, keys
}

// common is the length of the common prefix and suffix of a and b, not overlapping.
func common(a, b []byte) (int, int) {
	p := 0
	for p < len(a) && p < len(b) && a[p] == b[p] {
		p++
	}
	s := 0
	for s < len(a)-p && s < len(b)-p && a[len(a)-1-s] == b[len(b)-1-s] {
		s++
	}
	return p, s
}

// TestMuseSplicePreserves: the writer adds or replaces the one entry and leaves every other byte of the file as it
// was: an add only inserts (the old file is the new one less one run of bytes), and a replace changes bytes only inside
// the old entry's value. Numbers, escapes, key order, other servers, odd spacing and the spelling of the table stay.
func TestMuseSplicePreserves(t *testing.T) {
	old := `{"transport":"stdio","command":"/old/rhobound-mcp","args":["stdio","--config","/old.json"]}`
	cases := []struct {
		name, doc, action, key string
	}{
		{"minimal", `{"schema_version": 1}`, "add", "mcp_servers"},
		{"pretty", "{\n  \"schema_version\": 1,\n  \"model\": \"muse-spark-1.3\",\n  \"n\": 12345678901234567890,\n" +
			"  \"f\": 1.50e+3,\n  \"s\": \"caf\\u00e9 \\\"q\\\"\",\n  \"plugins\": {\"x\": {\"enabled\": true}}\n}\n",
			"add", "mcp_servers"},
		{"tabs, CRLF", "{\r\n\t\"schema_version\": 1,\r\n\t\"mcp_servers\": {\r\n\t\t\"docs\": {\"command\": \"d\"}\r\n\t}\r\n}",
			"add", "mcp_servers"},
		{"camel spelling", `{"schema_version":1,"mcpServers":{"docs":{"transport":"stdio","command":"d","args":[]}}}`,
			"add", "mcpServers"},
		{"empty table", "{\n  \"schema_version\": 1,\n  \"mcp_servers\": {}\n}\n", "add", "mcp_servers"},
		{"empty table, spaced", "{\"schema_version\": 1, \"mcp_servers\": { \n }, \"z\": [1, 2]}", "add", "mcp_servers"},
		{"replace", "{\n  \"schema_version\": 1,\n  \"mcp_servers\": {\n    \"a\": {\"command\": \"a\"},\n    \"rhobound\": " +
			old + ",\n    \"b\": {\"command\": \"b\"}\n  },\n  \"tail\": 0.0\n}\n", "replace", "mcp_servers"},
		{"replace last", `{"schema_version":1,"mcpServers":{"rhobound":` + old + `}}`, "replace", "mcpServers"},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			doc := []byte(c.doc)
			out, sr, err := museSplice(doc, testEntry, false)
			if err != nil {
				t.Fatal(err)
			}
			if sr.Action != c.action || sr.Key != c.key {
				t.Fatalf("result %+v, want %s under %s", sr, c.action, c.key)
			}
			e, keys := entryIn(t, out)
			if !reflect.DeepEqual(e, testEntry) || len(keys) != 1 || keys[0] != c.key {
				t.Fatalf("entry %+v under %v\n%s", e, keys, out)
			}
			p, s := common(doc, out)
			switch {
			case c.name == "empty table" || c.name == "empty table, spaced":
				// the empty object is written again: the changed bytes lie inside the table's old value
				k := strings.Index(c.doc, "mcp_servers")
				i := k + strings.Index(c.doc[k:], "{")
				if j := i + strings.Index(c.doc[i:], "}") + 1; p < i || len(doc)-s > j {
					t.Errorf("changed bytes [%d, %d) reach outside the empty table\n%s", p, len(doc)-s, out)
				}
			case c.action == "add":
				if p+s != len(doc) {
					t.Errorf("an add changed old bytes: prefix %d + suffix %d != %d\n%s", p, s, len(doc), out)
				}
			default:
				i := strings.Index(c.doc, old)
				if p < i || len(doc)-s > i+len(old) {
					t.Errorf("changed bytes [%d, %d) reach outside the old entry [%d, %d)\n%s", p, len(doc)-s, i, i+len(old), out)
				}
			}
			again, sr2, err := museSplice(out, testEntry, false)
			if err != nil || sr2.Action != "keep" || string(again) != string(out) {
				t.Errorf("a second run: %v %+v, changed %v", err, sr2, string(again) != string(out))
			}
		})
	}
	out, sr, err := museSplice(nil, testEntry, false)
	if err != nil || sr.Action != "add" {
		t.Fatal(err, sr)
	}
	var top map[string]any
	if json.Unmarshal(out, &top) != nil || top["schema_version"] != float64(1) {
		t.Fatalf("a new file: %s", out)
	}
	if e, keys := entryIn(t, out); !reflect.DeepEqual(e, testEntry) || len(keys) != 1 {
		t.Errorf("a new file: %+v %v", e, keys)
	}
	if e := testEntry; e.Mode != "optional" || e.Transport != "stdio" {
		t.Errorf("the entry: %+v", e)
	}
}

// TestMuseSpliceRefuses: a file whose meaning to Muse is not plain is left alone, with a reason.
func TestMuseSpliceRefuses(t *testing.T) {
	for name, doc := range map[string]string{
		"comment":          "{\n  // mine\n  \"schema_version\": 1\n}",
		"trailing comma":   `{"schema_version": 1,}`,
		"schema 2":         `{"schema_version": 2}`,
		"schema string":    `{"schema_version": "1"}`,
		"schema 1.0":       `{"schema_version": 1.0}`,
		"no schema":        `{"model": "x"}`,
		"both spellings":   `{"schema_version": 1, "mcp_servers": {}, "mcpServers": {}}`,
		"table not object": `{"schema_version": 1, "mcp_servers": []}`,
		"duplicate top":    `{"schema_version": 1, "schema_version": 1}`,
		"duplicate server": `{"schema_version": 1, "mcp_servers": {"a": {}, "a": {}}}`,
		"empty":            " \n",
		"array":            `[{"schema_version": 1}]`,
	} {
		if _, _, err := museSplice([]byte(doc), testEntry, false); !errors.Is(err, errMuseSettings) {
			t.Errorf("%s: %v", name, err)
		}
	}
}

// TestMuseRegistration: the hooks find the server's configuration in the settings only through an enabled stdio entry
// that runs rhobound-mcp stdio --config with an absolute file, and say why when there is none.
func TestMuseRegistration(t *testing.T) {
	env := map[string]string{"HOME": "/home/u", "RB": "/opt/rb"}
	getenv := func(k string) string { return env[k] }
	entry := func(fields string) string { return `{"schema_version":1,"mcp_servers":{"rhobound":{` + fields + `}}}` }
	good := `"transport":"stdio","command":"/opt/rb/rhobound-mcp","args":["stdio","--config","/c/config.json"]`
	cases := []struct {
		name, doc, cfg, code string
	}{
		{"missing", "", "", regMissing},
		{"invalid", `{"schema_version":1,`, "", regInvalid},
		{"no table", `{"schema_version":1}`, "", regUnregistered},
		{"both", `{"schema_version":1,"mcp_servers":{},"mcpServers":{}}`, "", regBothSpelling},
		{"table not object", `{"schema_version":1,"mcp_servers":[]}`, "", regInvalid},
		{"good", entry(good), "/c/config.json", ""},
		{"enabled", entry(good + `,"enabled":true,"mode":"optional"`), "/c/config.json", ""},
		{"no transport", entry(`"command":"/x/rhobound-mcp","args":["stdio","--config=/c/b.json"]`), "/c/b.json", ""},
		{"disabled", entry(good + `,"enabled":false`), "", regDisabled},
		{"http", entry(`"transport":"streamable_http","url":"http://x","command":"/x/rhobound-mcp","args":["stdio","--config","/c"]`), "", regUnregistered},
		{"other binary", entry(`"command":"/x/other","args":["stdio","--config","/c/config.json"]`), "", regUnregistered},
		{"http mode", entry(`"command":"/x/rhobound-mcp","args":["http","--config","/c/config.json"]`), "", regUnregistered},
		{"relative config", entry(`"command":"/x/rhobound-mcp","args":["stdio","--config","config.json"]`), "", regUnregistered},
		{"vars", entry(`"command":"${RB}/rhobound-mcp","args":["stdio","--config","${HOME}/.config/rhobound-mcp/config.json"]`),
			"/home/u/.config/rhobound-mcp/config.json", ""},
		{"unset var", entry(`"command":"${NOPE}/rhobound-mcp","args":["stdio","--config","/c/config.json"]`), "", regUnregistered},
		{"another name", `{"schema_version":1,"mcpServers":{"rb":{` + good + `}}}`, "/c/config.json", ""},
		{"rhobound first", `{"schema_version":1,"mcp_servers":{"a":{"command":"/x/rhobound-mcp","args":["stdio","--config","/a.json"]},"rhobound":{` + good + `}}}`,
			"/c/config.json", ""},
	}
	for _, c := range cases {
		var doc []byte
		if c.doc != "" {
			doc = []byte(c.doc)
		}
		cfg, code := museRegistration(doc, getenv)
		if cfg != c.cfg || code != c.code {
			t.Errorf("%s: %q %q, want %q %q", c.name, cfg, code, c.cfg, c.code)
		}
	}
}

// TestMuseSpliceMerges: an existing entry keeps the members init does not own, byte for byte, and a "enabled": false
// the user set; init's own false (initOff) is turned on; members that contradict stdio are dropped; an entry that
// already matches in every owned member is kept as it is, extra members and all.
func TestMuseSpliceMerges(t *testing.T) {
	user := `{"transport": "stdio", "command": "/old/rhobound-mcp", "args": ["stdio", "--config", "/old.json"], ` +
		`"enabled": false, "env": {"RHOBOUND_X": "1",  "N": 12345678901234567890}, "startup_timeout_sec": 6.0e1, ` +
		`"url": "http://stray", "disabled_tools": ["fit_start"]}`
	doc := []byte("{\n  \"schema_version\": 1,\n  \"mcp_servers\": {\n    \"rhobound\": " + user + "\n  }\n}\n")
	out, r, err := museSplice(doc, testEntry, false)
	if err != nil || r.Action != "replace" || !r.Parked {
		t.Fatalf("%v %+v", err, r)
	}
	for _, raw := range []string{`"env": {"RHOBOUND_X": "1",  "N": 12345678901234567890}`, `"startup_timeout_sec": 6.0e1`,
		`"disabled_tools": ["fit_start"]`, `"enabled": false`} {
		if !strings.Contains(string(out), raw) {
			t.Errorf("not kept byte for byte: %s\n%s", raw, out)
		}
	}
	if strings.Contains(string(out), "stray") || !reflect.DeepEqual(r.Dropped, []string{"url"}) ||
		!reflect.DeepEqual(r.Kept, []string{"env", "startup_timeout_sec", "disabled_tools"}) {
		t.Errorf("dropped %v kept %v\n%s", r.Dropped, r.Kept, out)
	}
	if !reflect.DeepEqual(r.Changed, []string{"command", "args", "mode"}) || string(r.Previous) != user {
		t.Errorf("changed %v, previous %s", r.Changed, r.Previous)
	}
	e, _ := entryIn(t, out)
	if e.Enabled || e.Command != testEntry.Command || e.Mode != "optional" {
		t.Errorf("the merged entry: %+v", e)
	}
	// the same again: every owned member matches (enabled parked): kept, extra members and all
	again, r2, err := museSplice(out, testEntry, false)
	if err != nil || r2.Action != "keep" || string(again) != string(out) {
		t.Errorf("a second run: %v %+v", err, r2)
	}
	// init wrote that false itself (an incomplete configuration, now complete): turned on
	on, r3, err := museSplice(out, testEntry, true)
	if e, _ := entryIn(t, on); err != nil || r3.Action != "replace" || r3.Parked || !e.Enabled {
		t.Errorf("init's own false: %v %+v %+v", err, r3, e)
	}
	// an incomplete configuration turns a true entry off
	off, _, _ := museSplice(on, newMuseEntry(testEntry.Command, testEntry.Args[2], false), false)
	if e, _ := entryIn(t, off); e.Enabled {
		t.Error("an incomplete configuration left the entry on")
	}
}

// TestMuseSpliceLayout: CRLF files get CRLF, tab-indented files get tabs.
func TestMuseSpliceLayout(t *testing.T) {
	doc := []byte("{\r\n\t\"schema_version\": 1,\r\n\t\"mcp_servers\": {\r\n\t\t\"docs\": {\"command\": \"d\"}\r\n\t}\r\n}\r\n")
	out, _, err := museSplice(doc, testEntry, false)
	if err != nil {
		t.Fatal(err)
	}
	if n := strings.Count(string(out), "\n") - strings.Count(string(out), "\r\n"); n != 0 {
		t.Errorf("%d bare line feeds in a CRLF file:\n%q", n, out)
	}
	if !strings.Contains(string(out), "\r\n\t\t\t\"transport\"") {
		t.Errorf("not tab-indented:\n%q", out)
	}
}

// TestMuseSpliceRefusesMore: another entry already running rhobound-mcp, an entry that is not an object, and the
// messages for a byte-order mark and a missing schema_version.
func TestMuseSpliceRefusesMore(t *testing.T) {
	for name, c := range map[string]struct{ doc, want string }{
		"second server": {`{"schema_version":1,"mcp_servers":{"rb":{"command":"/opt/rb/rhobound-mcp","args":["stdio","--config","/x"]}}}`, `"rb" already runs rhobound-mcp`},
		"not an object": {`{"schema_version":1,"mcp_servers":{"rhobound":"rhobound-mcp"}}`, "is not an object"},
		"bom":           {"\xef\xbb\xbf{\"schema_version\":1}", "byte-order mark"},
		"no schema":     {`{"mcp_servers":{}}`, "schema_version is missing"},
	} {
		if _, _, err := museSplice([]byte(c.doc), testEntry, false); !errors.Is(err, errMuseSettings) || !strings.Contains(err.Error(), c.want) {
			t.Errorf("%s: %v", name, err)
		}
	}
}

// TestMuseSpliceLayoutNewTable: a CRLF, tab-indented file without a server table gets one in its own layout.
func TestMuseSpliceLayoutNewTable(t *testing.T) {
	doc := []byte("{\r\n\t\"schema_version\": 1\r\n}\r\n")
	out, r, err := museSplice(doc, testEntry, false)
	if err != nil || r.Action != "add" {
		t.Fatal(err, r)
	}
	if n := strings.Count(string(out), "\n") - strings.Count(string(out), "\r\n"); n != 0 || !strings.Contains(string(out), "\r\n\t\"mcp_servers\": {\r\n\t\t\"rhobound\"") {
		t.Errorf("%d bare line feeds, layout:\n%q", n, out)
	}
}

// TestMuseSpliceAfterApprove: the file as Muse Code 1.4.14 rewrote it after `muse plugins approve` (measured live on
// the cluster, 2026-11-02): the entry moved to mcpServers, its keys reordered and "enabled": true dropped (the
// default). init reads it as the entry it wrote: keep, nothing to change.
func TestMuseSpliceAfterApprove(t *testing.T) {
	doc := []byte(`{
  "schema_version": 1,
  "mcpServers": {
    "rhobound": {
      "mode": "optional",
      "transport": "stdio",
      "command": "/opt/rb/bin/rhobound-mcp",
      "args": [
        "stdio",
        "--config",
        "/home/u/.config/rhobound-mcp/config.json"
      ]
    }
  },
  "runtime_capabilities": {
    "plugin:rhobound:hook:rhobound-stop": {
      "enabled": true,
      "trusted_definition_hash": "sha256:732836ab4a588fefb246f8b271ef0dc85f6943b527ccc27e04bc2a2308ae986d"
    }
  }
}`)
	out, r, err := museSplice(doc, testEntry, false)
	if err != nil || r.Action != "keep" || string(out) != string(doc) || r.Key != "mcpServers" {
		t.Errorf("%v %+v", err, r)
	}
	if cfg, code := museRegistration(doc, func(string) string { return "" }); cfg != testEntry.Args[2] || code != "" {
		t.Errorf("the hooks: %q %q", cfg, code)
	}
	// a parked entry is still kept parked; an incomplete configuration still turns it off
	off, r2, _ := museSplice(doc, newMuseEntry(testEntry.Command, testEntry.Args[2], false), false)
	if e, _ := entryIn(t, off); r2.Action != "replace" || e.Enabled {
		t.Errorf("an incomplete configuration: %+v %+v", r2, e)
	}
}
