// SPDX-License-Identifier: Apache-2.0

package server

import (
	"bytes"
	"encoding/json"
	"errors"
	"fmt"
)

// ServerKeys are the only keys the server adds to a CLI view (ARCHITECTURE.md 5.5). The CLI twin never prints them;
// the parity test removes exactly these from structuredContent and compares the rest with the twin's bytes.
var ServerKeys = []string{"prediction_id", "fit_id", "fit_age_s", "attempt", "max_preview_attempts", "escalate", "links"}

func isServerKey(k string) bool {
	for _, s := range ServerKeys {
		if s == k {
			return true
		}
	}
	return false
}

// Canonical re-encodes JSON: object keys sorted, no insignificant whitespace, numbers exactly as written, no HTML
// escaping. A document the CLI printed canonically comes back byte for byte.
func Canonical(b []byte) ([]byte, error) {
	v, err := decode(b)
	if err != nil {
		return nil, err
	}
	return encode(v)
}

// decode reads one JSON value, keeping numbers as written.
func decode(b []byte) (any, error) {
	dec := json.NewDecoder(bytes.NewReader(b))
	dec.UseNumber()
	var v any
	if err := dec.Decode(&v); err != nil {
		return nil, err
	}
	if dec.More() {
		return nil, errors.New("trailing data after the JSON value")
	}
	return v, nil
}

// decodeObject reads one JSON object.
func decodeObject(b []byte) (map[string]any, error) {
	v, err := decode(b)
	if err != nil {
		return nil, err
	}
	m, ok := v.(map[string]any)
	if !ok {
		return nil, errors.New("not a JSON object")
	}
	return m, nil
}

// encode writes v canonically. Maps encode with sorted keys; json.Number as written; json.RawMessage is decoded and
// re-encoded, so raw parts come out canonical too.
func encode(v any) ([]byte, error) {
	var buf bytes.Buffer
	enc := json.NewEncoder(&buf)
	enc.SetEscapeHTML(false)
	if err := enc.Encode(v); err != nil {
		return nil, err
	}
	out := bytes.TrimSuffix(buf.Bytes(), []byte("\n"))
	if !needsRecode(v) {
		return out, nil
	}
	// A json.RawMessage or Marshaler inside v kept its own key order and escaping: decode and encode once more.
	w, err := decode(out)
	if err != nil {
		return nil, err
	}
	buf.Reset()
	if err := enc.Encode(w); err != nil {
		return nil, err
	}
	return bytes.TrimSuffix(buf.Bytes(), []byte("\n")), nil
}

// needsRecode reports whether v holds a value whose encoding the encoder does not control (json.RawMessage, or any
// type other than the plain JSON shapes).
func needsRecode(v any) bool {
	switch t := v.(type) {
	case nil, bool, string, json.Number, float64, int, int64:
		return false
	case map[string]any:
		for _, x := range t {
			if needsRecode(x) {
				return true
			}
		}
		return false
	case []any:
		for _, x := range t {
			if needsRecode(x) {
				return true
			}
		}
		return false
	default:
		return true
	}
}

// withServerKeys adds the server's keys to a CLI view and re-serializes it canonically. Keys with a nil value are
// left out. When the result is over max bytes, links are dropped first (ARCHITECTURE.md 5.9); the rest of the size
// discipline is the CLI's, which leaves ServerKeyReserve bytes for these keys. A result still over max is an error:
// the server never returns one.
func withServerKeys(view []byte, keys map[string]any, max int) ([]byte, error) {
	obj, err := decodeObject(view)
	if err != nil {
		return nil, fmt.Errorf("the engine's view: %w", err)
	}
	for _, k := range ServerKeys {
		if _, ok := obj[k]; ok {
			return nil, fmt.Errorf("the engine's view holds the server key %s", k)
		}
	}
	for k, v := range keys {
		if !isServerKey(k) {
			return nil, fmt.Errorf("%s is not a server key", k)
		}
		if v != nil {
			obj[k] = v
		}
	}
	out, err := encode(obj)
	if err != nil {
		return nil, err
	}
	if _, ok := obj["links"]; ok && len(out) > max {
		delete(obj, "links")
		if out, err = encode(obj); err != nil {
			return nil, err
		}
	}
	if len(out) > max {
		return nil, fmt.Errorf("the result is %d bytes, over its cap of %d", len(out), max)
	}
	return out, nil
}
