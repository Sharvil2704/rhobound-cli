// SPDX-License-Identifier: Apache-2.0

// Package registry holds the one registry of codes (docs/mcp/data-contract.json, which tools/gencontract writes from
// internal/contract) that the server needs at run time: the whole document, which the rhobound://data-contract
// resource serves, and each code's level, fix and numbers' names, by which it shows a finding or a refusal read from a
// stored job record, never as the record says them. A job record may have been written by another build of the server
// or its worker (ARCHITECTURE.md 5.9).
//
// The file here is a byte copy of the published one: go:embed cannot reach outside the module, and this module cannot
// import internal/contract. A test compares the copy with docs/mcp/data-contract.json; refresh it with
//
//	cp docs/mcp/data-contract.json mcp/internal/registry/
package registry

import (
	_ "embed"
	"encoding/json"
	"slices"
)

//go:embed data-contract.json
var published []byte

// Code is what the registry says of one code: its level, its fix, and the names of the numbers its findings and
// refusals may carry.
type Code struct {
	Level   string   `json:"level"`
	Fix     string   `json:"fix"`
	Numbers []string `json:"numbers,omitempty"`
}

// HasNumber reports whether a finding or a refusal of the code may carry a number of this name.
func (c Code) HasNumber(name string) bool { return slices.Contains(c.Numbers, name) }

var codes = func() map[string]Code {
	var doc struct {
		Codes []struct {
			ID      string   `json:"code"`
			Level   string   `json:"level"`
			Fix     string   `json:"fix"`
			Numbers []string `json:"numbers"`
		} `json:"codes"`
	}
	if err := json.Unmarshal(published, &doc); err != nil || len(doc.Codes) == 0 {
		panic("registry: the embedded data contract does not parse")
	}
	m := make(map[string]Code, len(doc.Codes))
	for _, c := range doc.Codes {
		m[c.ID] = Code{Level: c.Level, Fix: c.Fix, Numbers: c.Numbers}
	}
	return m
}()

// Published returns the registry as published (docs/mcp/data-contract.json, rhobound.data-contract/v1): every code with
// its level, trigger, condition, fix, behaviour at 1a2df09, section, version and status. The caller gets its own copy.
func Published() []byte { return append([]byte(nil), published...) }

// Lookup returns what the registry says of a code, and whether it is registered.
func Lookup(code string) (Code, bool) {
	c, ok := codes[code]
	c.Numbers = slices.Clone(c.Numbers)
	return c, ok
}
