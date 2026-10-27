// SPDX-License-Identifier: Apache-2.0

package server

import (
	"encoding/json"
	"strings"
	"testing"
)

func TestCanonical(t *testing.T) {
	in := `{ "b": 1.50, "a": [3, {"d": "<&>", "c": 1e-7}], "z": 12345678901234567890, "u": "\u00e9\u2028" }`
	want := `{"a":[3,{"c":1e-7,"d":"<&>"}],"b":1.50,"u":"` + "\u00e9" + `\u2028","z":12345678901234567890}`
	got, err := Canonical([]byte(in))
	if err != nil || string(got) != want {
		t.Fatalf("got  %s %v\nwant %s", got, err, want)
	}
	again, _ := Canonical(got)
	if string(again) != string(got) {
		t.Errorf("not idempotent: %s", again)
	}
	for _, bad := range []string{`{"a":1} {"b":2}`, `{"a":`, ``} {
		if _, err := Canonical([]byte(bad)); err == nil {
			t.Errorf("%q accepted", bad)
		}
	}
	// Raw parts inside a value come out canonical too.
	b, err := encode(map[string]any{"z": json.RawMessage(`{"y":1, "x":[ 2 ]}`), "a": "<"})
	if err != nil || string(b) != `{"a":"<","z":{"x":[2],"y":1}}` {
		t.Errorf("encode: %s %v", b, err)
	}
}

func TestWithServerKeys(t *testing.T) {
	view := []byte(`{"schema":"rhobound-mcp.context/v1","own_ms":1.50}`)
	out, err := withServerKeys(view, map[string]any{"fit_id": "fit_X", "fit_age_s": int64(620), "escalate": nil}, SummaryMaxBytes)
	if err != nil || string(out) != `{"fit_age_s":620,"fit_id":"fit_X","own_ms":1.50,"schema":"rhobound-mcp.context/v1"}` {
		t.Errorf("%s %v", out, err)
	}
	if _, err := withServerKeys([]byte(`{"fit_id":"x"}`), nil, SummaryMaxBytes); err == nil {
		t.Error("a CLI view holding a server key accepted")
	}
	if _, err := withServerKeys(view, map[string]any{"verdict": "pass"}, SummaryMaxBytes); err == nil {
		t.Error("a key outside the server keys added")
	}
	if _, err := withServerKeys([]byte(`[1]`), nil, SummaryMaxBytes); err == nil {
		t.Error("a non-object view accepted")
	}
	// links go first when a result is over its cap.
	links := []any{"rhobound://fit/" + strings.Repeat("x", 100)}
	out, _ = withServerKeys(view, map[string]any{"links": links}, 120)
	if strings.Contains(string(out), "links") {
		t.Errorf("links kept over the cap: %s", out)
	}
	out, _ = withServerKeys(view, map[string]any{"links": links}, SummaryMaxBytes)
	if !strings.Contains(string(out), "links") {
		t.Errorf("links dropped under the cap: %s", out)
	}
	// a result over its cap once links are gone is never returned: an engine view over the CLI's own cap, or with no
	// links to drop
	big := []byte(`{"pad":"` + strings.Repeat("x", SummaryMaxBytes) + `"}`)
	if out, err := withServerKeys(big, map[string]any{"links": links}, SummaryMaxBytes); err == nil {
		t.Errorf("a result of %d bytes returned over the cap %d", len(out), SummaryMaxBytes)
	}
	if out, err := withServerKeys(view, nil, 20); err == nil {
		t.Errorf("a result of %d bytes returned over the cap 20", len(out))
	}
}

// TestServerKeyReserve: the server's own keys, at their longest, fit in the reserve the CLI leaves.
func TestServerKeyReserve(t *testing.T) {
	h := "pred_" + strings.Repeat("Z", 26)
	keys := map[string]any{"prediction_id": h, "fit_id": "fit_" + strings.Repeat("Z", 26),
		"fit_age_s": int64(1) << 40, "attempt": 1 << 20, "max_preview_attempts": 1 << 20, "escalate": "bench_non_pass"}
	view := []byte(`{"schema":"x"}`)
	out, err := withServerKeys(view, keys, FullMaxBytes)
	if err != nil {
		t.Fatal(err)
	}
	if added := len(out) - len(view); added > ServerKeyReserve {
		t.Errorf("server keys add %d bytes, reserve %d", added, ServerKeyReserve)
	}
}

// TestSummaryCapWithLinks: a view at the CLI's summary cap (SummaryMaxBytes-ServerKeyReserve) with every server key,
// links included, stays within SummaryMaxBytes: the keys fit in the reserve, and the links are dropped.
func TestSummaryCapWithLinks(t *testing.T) {
	h := "pred_" + strings.Repeat("Z", 26)
	pad := SummaryMaxBytes - ServerKeyReserve - len(`{"pad":""}`)
	view := []byte(`{"pad":"` + strings.Repeat("x", pad) + `"}`)
	keys := map[string]any{"prediction_id": h, "fit_id": "fit_" + strings.Repeat("Z", 26), "fit_age_s": int64(1) << 40,
		"attempt": 1 << 20, "max_preview_attempts": 1 << 20, "escalate": "bench_non_pass", "links": []any{predictionURI + h}}
	out, err := withServerKeys(view, keys, SummaryMaxBytes)
	if err != nil {
		t.Fatal(err)
	}
	if len(out) > SummaryMaxBytes || strings.Contains(string(out), "links") {
		t.Errorf("%d bytes, links kept: %v", len(out), strings.Contains(string(out), "links"))
	}
}
