// SPDX-License-Identifier: Apache-2.0

package main

// Muse Code's user settings ($XDG_CONFIG_HOME/muse/settings.json, else ~/.config/muse/settings.json): init registers
// the server there, and the Muse plugin's hooks read the registration back. Muse reads the whole file, and a wrong type
// on any of its keys makes the file malformed for every Muse command, so the writer changes one entry and leaves every
// other byte as it was.

import (
	"bytes"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"os/user"
	"path/filepath"
	"reflect"
	"regexp"
	"sort"
	"strings"
)

// museServerKey is the server's name in Muse's server table: the agent sees its tools as mcp__rhobound__<tool>.
const museServerKey = "rhobound"

// museServersKeys are the two spellings Muse reads for its server table: mcp_servers, the documented one, and
// mcpServers. A file with both has MCP disabled by Muse, so init refuses it and the hooks take it as unregistered.
var museServersKeys = []string{"mcp_servers", "mcpServers"}

// museEntry is a stdio server entry, in the documented shape: {"transport": "stdio", "command", "args"} with
// enabled and mode. mode is always "optional": Muse's default, "required", aborts a run whose server fails to start.
type museEntry struct {
	Transport string   `json:"transport"`
	Command   string   `json:"command"`
	Args      []string `json:"args"`
	Enabled   bool     `json:"enabled"`
	Mode      string   `json:"mode"`
}

// newMuseEntry is the entry that runs server (an absolute path) in stdio mode on the configuration at config.
func newMuseEntry(server, config string, enabled bool) museEntry {
	return museEntry{Transport: "stdio", Command: server, Args: []string{"stdio", "--config", config},
		Enabled: enabled, Mode: "optional"}
}

// errMuseSettings is a settings file init will not change; the error says why and what to do.
var errMuseSettings = errors.New("muse settings")

func museRefuse(format string, a ...any) error {
	return fmt.Errorf("%w: %s", errMuseSettings, fmt.Sprintf(format, a...))
}

// member is one member of a JSON object: its key and the span of its value in the document, [start, end).
type member struct {
	key        string
	start, end int
}

// members lists the members of the JSON object at doc[off:off+len(obj)], with spans relative to doc. A duplicate key is
// an error: what a reader would take is then not known.
func members(doc []byte, off int, obj []byte) ([]member, error) {
	dec := json.NewDecoder(bytes.NewReader(obj))
	if t, err := dec.Token(); err != nil || t != json.Delim('{') {
		return nil, errors.New("expected a JSON object")
	}
	var ms []member
	seen := map[string]bool{}
	for dec.More() {
		t, err := dec.Token()
		if err != nil {
			return nil, err
		}
		k, _ := t.(string)
		if seen[k] {
			return nil, fmt.Errorf("the key %q appears twice", k)
		}
		seen[k] = true
		var raw json.RawMessage
		if err := dec.Decode(&raw); err != nil {
			return nil, err
		}
		end := off + int(dec.InputOffset())
		start := end - len(raw)
		if !bytes.Equal(doc[start:end], raw) {
			return nil, fmt.Errorf("muse settings: lost the span of %q", k) // a decoder change; never on Go 1.25+
		}
		ms = append(ms, member{key: k, start: start, end: end})
	}
	if t, err := dec.Token(); err != nil || t != json.Delim('}') {
		return nil, errors.New("expected the end of an object")
	}
	return ms, nil
}

// lineIndent is the run of spaces and tabs that starts the line holding doc[i].
func lineIndent(doc []byte, i int) string {
	ls := bytes.LastIndexByte(doc[:i], '\n') + 1
	j := ls
	for j < len(doc) && (doc[j] == ' ' || doc[j] == '\t') {
		j++
	}
	return string(doc[ls:j])
}

// sameLine reports whether doc[i] and doc[j] are on one line.
func sameLine(doc []byte, i, j int) bool {
	if i > j {
		i, j = j, i
	}
	return !bytes.Contains(doc[i:j], []byte{'\n'})
}

// layout is how a document writes its lines: its line end and its indentation unit.
type layout struct{ nl, unit string }

func layoutOf(doc []byte) layout {
	l := layout{nl: "\n", unit: "  "}
	if bytes.Contains(doc, []byte("\r\n")) {
		l.nl = "\r\n"
	}
	if bytes.Contains(doc, []byte("\n\t")) {
		l.unit = "\t"
	}
	return l
}

// text is s with its line ends in the document's form.
func (l layout) text(s string) string { return strings.ReplaceAll(s, "\n", l.nl) }

// ownedKeys are the entry's members init sets; every other member of an existing entry is the user's and is kept.
var ownedKeys = []string{"transport", "command", "args", "enabled", "mode"}

// strayKeys are members that contradict a stdio entry (Muse ignores such an entry): a replace drops them.
var strayKeys = []string{"url", "headers"}

// entryObject is the entry as one JSON object at indent: the members of old (an existing entry's members, in their
// order, values byte for byte) with the owned ones set from want, then the owned ones old lacks. old may be nil.
func entryObject(doc []byte, old []member, want map[string]json.RawMessage, indent string, l layout) []byte {
	var parts []string
	done := map[string]bool{}
	for _, m := range old {
		if contains(strayKeys, m.key) {
			continue
		}
		k, _ := json.Marshal(m.key)
		v := doc[m.start:m.end]
		if w, ok := want[m.key]; ok {
			v, done[m.key] = w, true
		}
		parts = append(parts, string(k)+": "+string(v))
	}
	for _, k := range ownedKeys {
		if !done[k] {
			kb, _ := json.Marshal(k)
			parts = append(parts, string(kb)+": "+string(want[k]))
		}
	}
	in := indent + l.unit
	return []byte("{" + l.nl + in + strings.Join(parts, ","+l.nl+in) + l.nl + indent + "}")
}

// ownedValues are the owned members' values for e, as compact JSON.
func ownedValues(e museEntry) map[string]json.RawMessage {
	m := map[string]json.RawMessage{}
	for k, v := range map[string]any{"transport": e.Transport, "command": e.Command, "args": e.Args, "enabled": e.Enabled,
		"mode": e.Mode} {
		b, _ := json.Marshal(v)
		m[k] = b
	}
	return m
}

func contains(set []string, s string) bool {
	for _, x := range set {
		if x == s {
			return true
		}
	}
	return false
}

// jsonEqual reports whether two JSON values are equal as values.
func jsonEqual(a, b []byte) bool {
	var x, y any
	return json.Unmarshal(a, &x) == nil && json.Unmarshal(b, &y) == nil && reflect.DeepEqual(x, y)
}

// runsRhobound reports whether a server entry runs rhobound-mcp in stdio mode.
func runsRhobound(raw []byte) bool {
	var e struct {
		Command string   `json:"command"`
		Args    []string `json:"args"`
	}
	return json.Unmarshal(raw, &e) == nil && filepath.Base(e.Command) == "rhobound-mcp" && len(e.Args) > 0 &&
		e.Args[0] == "stdio"
}

// spliceResult is what museSplice did: "add", "replace" or "keep", under which spelling of the server table; the
// existing entry (not printed), the names of the owned members it changed, of the user's members it kept and of the
// stray ones it dropped, and whether it kept the user's "enabled": false (a parked server).
type spliceResult struct {
	Action   string          `json:"action"`
	Key      string          `json:"key"`
	Previous json.RawMessage `json:"-"` // the old entry: never printed (its env and headers may hold credentials)
	Changed  []string        `json:"changed,omitempty"`
	Kept     []string        `json:"kept,omitempty"`
	Dropped  []string        `json:"dropped,omitempty"`
	Parked   bool            `json:"parked,omitempty"`
}

// museSplice returns doc with the server table's "rhobound" entry set to e, and every byte outside that entry
// unchanged; a missing doc (nil) becomes a new file. An existing entry keeps its other members (env,
// startup_timeout_sec, enabled_tools...) byte for byte, and its "enabled": false unless initOff says init itself wrote
// that false (a server init parked for an incomplete configuration). It refuses a file that is not plain JSON (Muse's
// settings are JSON), a schema_version other than 1, a file with both spellings of the server table, a table or
// entry that is not an object, another entry that already runs rhobound-mcp, and duplicate keys.
func museSplice(doc []byte, e museEntry, initOff bool) ([]byte, spliceResult, error) {
	want := ownedValues(e)
	if doc == nil {
		l := layout{nl: "\n", unit: "  "}
		var b bytes.Buffer
		b.WriteString("{\n  \"schema_version\": 1,\n  \"mcp_servers\": {\n    \"" + museServerKey + "\": ")
		b.Write(entryObject(nil, nil, want, "    ", l))
		b.WriteString("\n  }\n}\n")
		return b.Bytes(), spliceResult{Action: "add", Key: "mcp_servers"}, nil
	}
	if bytes.HasPrefix(doc, []byte("\xef\xbb\xbf")) {
		return nil, spliceResult{}, museRefuse("the file starts with a byte-order mark; remove it (Muse reads plain JSON)")
	}
	if len(bytes.TrimSpace(doc)) == 0 {
		return nil, spliceResult{}, museRefuse("the file is empty; Muse needs at least {\"schema_version\": 1}")
	}
	if !json.Valid(doc) {
		return nil, spliceResult{}, museRefuse("the file is not plain JSON (comments or trailing commas?); " +
			"add the entry by hand")
	}
	l := layoutOf(doc)
	trim := bytes.TrimLeft(doc, " \t\r\n")
	off := len(doc) - len(trim)
	top, err := members(doc, off, bytes.TrimRight(trim, " \t\r\n"))
	if err != nil {
		return nil, spliceResult{}, museRefuse("%v", err)
	}
	var tables []member
	schema := ""
	for _, m := range top {
		switch m.key {
		case "schema_version":
			schema = string(doc[m.start:m.end])
		case museServersKeys[0], museServersKeys[1]:
			tables = append(tables, m)
		}
	}
	switch schema {
	case "1":
	case "":
		return nil, spliceResult{}, museRefuse(`schema_version is missing; Muse requires "schema_version": 1, add it`)
	default:
		return nil, spliceResult{}, museRefuse("schema_version is %s, not 1; this init writes only schema_version 1 files", schema)
	}
	if len(tables) == 2 {
		return nil, spliceResult{}, museRefuse("both mcp_servers and mcpServers are present, and Muse disables MCP " +
			"then; merge them into one by hand")
	}
	var out bytes.Buffer
	if len(tables) == 0 {
		// A new table after the last member (there is at least schema_version).
		last := top[len(top)-1]
		ind := lineIndent(doc, last.start)
		if sameLine(doc, off, last.start) {
			ind = l.unit
		}
		out.Write(doc[:last.end])
		out.WriteString(l.text(",\n" + ind + "\"mcp_servers\": {\n" + ind + l.unit + "\"" + museServerKey + "\": "))
		out.Write(entryObject(nil, nil, want, ind+l.unit, l))
		out.WriteString(l.text("\n" + ind + "}"))
		out.Write(doc[last.end:])
		return out.Bytes(), spliceResult{Action: "add", Key: "mcp_servers"}, nil
	}
	tm := tables[0]
	if doc[tm.start] != '{' {
		return nil, spliceResult{}, museRefuse("%s is not an object", tm.key)
	}
	servers, err := members(doc, tm.start, doc[tm.start:tm.end])
	if err != nil {
		return nil, spliceResult{}, museRefuse("%s: %v", tm.key, err)
	}
	for _, m := range servers {
		if m.key != museServerKey && runsRhobound(doc[m.start:m.end]) {
			return nil, spliceResult{}, museRefuse("the entry %q already runs rhobound-mcp; remove it, or rename it to %q, "+
				"so that one server is registered", m.key, museServerKey)
		}
	}
	keyInd := lineIndent(doc, tm.start)
	for _, m := range servers {
		if m.key != museServerKey {
			continue
		}
		if doc[m.start] != '{' {
			return nil, spliceResult{}, museRefuse("%s.%s is not an object", tm.key, museServerKey)
		}
		old, err := members(doc, m.start, doc[m.start:m.end])
		if err != nil {
			return nil, spliceResult{}, museRefuse("%s.%s: %v", tm.key, museServerKey, err)
		}
		r := spliceResult{Key: tm.key, Previous: append(json.RawMessage{}, doc[m.start:m.end]...)}
		have := map[string][]byte{}
		for _, om := range old {
			have[om.key] = doc[om.start:om.end]
			switch {
			case contains(strayKeys, om.key):
				r.Dropped = append(r.Dropped, om.key)
			case !contains(ownedKeys, om.key):
				r.Kept = append(r.Kept, om.key)
			}
		}
		if e.Enabled && string(have["enabled"]) == "false" && !initOff {
			want["enabled"], r.Parked = json.RawMessage("false"), true
		}
		for _, k := range ownedKeys {
			v, ok := have[k]
			if !ok && k == "enabled" && string(want[k]) == "true" {
				continue // Muse's default: its own rewrite of the file (muse plugins approve) drops "enabled": true
			}
			if !ok || !jsonEqual(v, want[k]) {
				r.Changed = append(r.Changed, k)
			}
		}
		if len(r.Changed) == 0 && len(r.Dropped) == 0 {
			r.Action = "keep"
			return doc, r, nil
		}
		r.Action = "replace"
		out.Write(doc[:m.start])
		out.Write(entryObject(doc, old, want, lineIndent(doc, m.start), l))
		out.Write(doc[m.end:])
		return out.Bytes(), r, nil
	}
	if len(servers) == 0 {
		// An empty table: written again, as one object holding the entry.
		out.Write(doc[:tm.start])
		out.WriteString(l.text("{\n" + keyInd + l.unit + "\"" + museServerKey + "\": "))
		out.Write(entryObject(nil, nil, want, keyInd+l.unit, l))
		out.WriteString(l.text("\n" + keyInd + "}"))
		out.Write(doc[tm.end:])
		return out.Bytes(), spliceResult{Action: "add", Key: tm.key}, nil
	}
	last := servers[len(servers)-1]
	ind := lineIndent(doc, last.start)
	if sameLine(doc, tm.start, last.start) {
		ind = keyInd + l.unit
	}
	out.Write(doc[:last.end])
	out.WriteString(l.text(",\n" + ind + "\"" + museServerKey + "\": "))
	out.Write(entryObject(nil, nil, want, ind, l))
	out.Write(doc[last.end:])
	return out.Bytes(), spliceResult{Action: "add", Key: tm.key}, nil
}

// homeDir is the user's home folder: $HOME when it is absolute, else the user database (a hook's cleared environment
// may have no HOME).
func homeDir(getenv func(string) string) (string, error) {
	if h := getenv("HOME"); filepath.IsAbs(h) {
		return filepath.Clean(h), nil
	}
	u, err := user.Current()
	if err != nil {
		return "", err
	}
	if !filepath.IsAbs(u.HomeDir) {
		return "", fmt.Errorf("no home folder")
	}
	return filepath.Clean(u.HomeDir), nil
}

// configHome is $XDG_CONFIG_HOME when it is absolute, else ~/.config: where Muse keeps muse/settings.json.
func configHome(getenv func(string) string) (string, error) {
	if x := getenv("XDG_CONFIG_HOME"); filepath.IsAbs(x) {
		return filepath.Clean(x), nil
	}
	h, err := homeDir(getenv)
	if err != nil {
		return "", err
	}
	return filepath.Join(h, ".config"), nil
}

// museSettingsPath is Muse's user settings file.
func museSettingsPath(getenv func(string) string) (string, error) {
	c, err := configHome(getenv)
	if err != nil {
		return "", err
	}
	return filepath.Join(c, "muse", "settings.json"), nil
}

// museRecord is what init last registered: the Muse settings file it wrote and the entry it chose (enabled as init's
// own verdict, also when the file keeps a false the user set). It is kept at a place that depends on the home folder
// only (the hooks' environment may lack XDG_CONFIG_HOME), so the hooks read the same file init wrote, and init can
// tell its own "enabled": false from a user's.
type museRecord struct {
	Schema   string    `json:"schema"`
	Settings string    `json:"settings"`
	Entry    museEntry `json:"entry"`
}

const museRecordSchema = "rhobound-mcp.muse-registration/v1"

// museRecordPath is <home>/.local/state/rhobound-mcp/muse-registration.json.
func museRecordPath(getenv func(string) string) (string, error) {
	h, err := homeDir(getenv)
	if err != nil {
		return "", err
	}
	return filepath.Join(h, ".local", "state", "rhobound-mcp", "muse-registration.json"), nil
}

// readMuseRecord reads the record; ok is false when there is none or it is not one.
func readMuseRecord(getenv func(string) string) (museRecord, bool) {
	p, err := museRecordPath(getenv)
	if err != nil {
		return museRecord{}, false
	}
	b, err := readBounded(p, 1<<16, true)
	if err != nil {
		return museRecord{}, false
	}
	var r museRecord
	if json.Unmarshal(b, &r) != nil || r.Schema != museRecordSchema || !filepath.IsAbs(r.Settings) {
		return museRecord{}, false
	}
	return r, true
}

// hookRegistration is the server's configuration file as the hooks find it: through the settings file init last
// wrote (the record), else through Muse's default settings file; or the registration code of the last one read. A
// record that names a settings file inside the repository (root) or the session's folder (ws) is not used.
func hookRegistration(getenv func(string) string, root, ws string) (string, string) {
	var paths []string
	if r, ok := readMuseRecord(getenv); ok && !under(r.Settings, root) && !under(r.Settings, ws) {
		paths = append(paths, r.Settings)
	}
	if p, err := museSettingsPath(getenv); err == nil && (len(paths) == 0 || paths[0] != p) {
		paths = append(paths, p)
	}
	code := regMissing
	for _, p := range paths {
		doc, err := readMuseSettings(p)
		if err != nil {
			continue
		}
		var cfg string
		if cfg, code = museRegistration(doc, getenv); code == "" {
			return cfg, ""
		}
	}
	return "", code
}

// Registration codes: why the settings name no usable server ("" when they do).
const (
	regMissing      = "settings.missing"        // no settings file
	regInvalid      = "settings.invalid"        // not JSON, or no server table of the right type
	regBothSpelling = "settings.both_spellings" // mcp_servers and mcpServers both present: Muse disables MCP
	regUnregistered = "settings.unregistered"   // no entry runs rhobound-mcp stdio --config FILE
	regDisabled     = "settings.disabled"       // such an entry exists, but enabled is false
)

var varRE = regexp.MustCompile(`\$\{([A-Za-z_][A-Za-z0-9_]*)\}`)

// expand replaces each ${VAR} in s with its value; ok is false when one of them is unset or empty (the entry's
// meaning is then unknown, so it is not used).
func expand(s string, getenv func(string) string) (string, bool) {
	ok := true
	out := varRE.ReplaceAllStringFunc(s, func(m string) string {
		v := getenv(m[2 : len(m)-1])
		if v == "" {
			ok = false
		}
		return v
	})
	return out, ok
}

// museRegistration finds the server's configuration file in Muse's settings document: the entry that runs
// rhobound-mcp in stdio mode with --config FILE (FILE absolute after ${VAR} expansion), enabled, of stdio transport.
// The "rhobound" entry is looked at first, then the others by name. It returns the file, or a registration code.
func museRegistration(doc []byte, getenv func(string) string) (string, string) {
	if doc == nil {
		return "", regMissing
	}
	var top map[string]json.RawMessage
	if json.Unmarshal(doc, &top) != nil {
		return "", regInvalid
	}
	var table json.RawMessage
	n := 0
	for _, k := range museServersKeys {
		if t, ok := top[k]; ok {
			table, n = t, n+1
		}
	}
	switch n {
	case 0:
		return "", regUnregistered
	case 2:
		return "", regBothSpelling
	}
	var servers map[string]json.RawMessage
	if json.Unmarshal(table, &servers) != nil {
		return "", regInvalid
	}
	names := make([]string, 0, len(servers))
	for k := range servers {
		if k != museServerKey {
			names = append(names, k)
		}
	}
	sort.Strings(names)
	if _, ok := servers[museServerKey]; ok {
		names = append([]string{museServerKey}, names...)
	}
	code := regUnregistered
	for _, k := range names {
		var e struct {
			Transport *string  `json:"transport"`
			Command   string   `json:"command"`
			Args      []string `json:"args"`
			Enabled   *bool    `json:"enabled"`
		}
		if json.Unmarshal(servers[k], &e) != nil {
			continue
		}
		if e.Transport != nil && *e.Transport != "stdio" {
			continue
		}
		cmd, ok := expand(e.Command, getenv)
		if !ok || filepath.Base(cmd) != "rhobound-mcp" || len(e.Args) < 1 || e.Args[0] != "stdio" {
			continue
		}
		cfg := ""
		for i := 1; i < len(e.Args); i++ {
			switch a := e.Args[i]; {
			case (a == "--config" || a == "-config") && i+1 < len(e.Args):
				cfg = e.Args[i+1]
				i++
			case strings.HasPrefix(a, "--config="):
				cfg = strings.TrimPrefix(a, "--config=")
			}
		}
		cfg, ok = expand(cfg, getenv)
		if !ok || !filepath.IsAbs(cfg) {
			continue
		}
		if e.Enabled != nil && !*e.Enabled {
			code = regDisabled
			continue
		}
		return filepath.Clean(cfg), ""
	}
	return "", code
}

// museSettingsMax is the largest settings file read: Muse's own are a few KB.
const museSettingsMax = 4 << 20

// readMuseSettings reads the settings file (a regular file, through links, of at most museSettingsMax bytes): nil and
// no error when there is none.
func readMuseSettings(path string) ([]byte, error) {
	b, err := readBounded(path, museSettingsMax, true)
	if errors.Is(err, os.ErrNotExist) {
		return nil, nil
	}
	return b, err
}
