// SPDX-License-Identifier: Apache-2.0

package otlp

import (
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"sort"
	"strings"
)

// KeepList is the canonical keep-list (docs/mcp/DATA.md 15): every attribute key the reader reads, so that a capture
// reduced to it reads exactly as the capture did. It is built from the reader's own key lists; a test fails when the
// reader reads a key that is not in it.
type KeepList struct {
	// Resource are the resource attribute keys, and ResourcePrefixes the prefixes of keys whose presence is read.
	Resource         []string `json:"resource"`
	ResourcePrefixes []string `json:"resource_prefixes"`
	// Span are the span attribute keys.
	Span []string `json:"span"`
	// Event are the span events kept (by name), and EventKeys their attribute keys.
	Event     []string `json:"event"`
	EventKeys []string `json:"event_keys"`
}

// Keep returns the canonical keep-list, each list sorted.
func Keep() KeepList {
	var span []string
	for _, l := range [][]string{peerKeys, portKeys, pathKeys, methodKeys, spanKeys, codeKeys} {
		span = append(span, l...)
	}
	return KeepList{
		Resource:         sortedUnique(append([]string(nil), resourceKeys...)),
		ResourcePrefixes: []string{faasPrefix},
		Span:             sortedUnique(span),
		Event:            []string{eventName},
		EventKeys:        sortedUnique(append([]string(nil), eventTypeKeys...)),
	}
}

// KeepsResource reports whether the keep-list keeps a resource attribute.
func (k KeepList) KeepsResource(key string) bool {
	for _, p := range k.ResourcePrefixes {
		if strings.HasPrefix(key, p) {
			return true
		}
	}
	return contains(k.Resource, key)
}

// KeepsSpan reports whether the keep-list keeps a span attribute.
func (k KeepList) KeepsSpan(key string) bool { return contains(k.Span, key) }

// KeepsEventKey reports whether the keep-list keeps an attribute of a kept event.
func (k KeepList) KeepsEventKey(key string) bool { return contains(k.EventKeys, key) }

func contains(sorted []string, s string) bool {
	i := sort.SearchStrings(sorted, s)
	return i < len(sorted) && sorted[i] == s
}

// SHA256 is the hex sha256 of the keep-list's JSON, as a capture manifest records it (keep_list_sha256).
func (k KeepList) SHA256() string {
	b, _ := json.Marshal(k) // sorted lists of strings: always marshals, and always to the same bytes
	s := sha256.Sum256(b)
	return hex.EncodeToString(s[:])
}
