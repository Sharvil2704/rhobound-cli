// SPDX-License-Identifier: Apache-2.0

//go:build e2e

package e2e

import (
	"os"
	"path/filepath"
	"sort"
	"strings"
	"testing"
)

// TestAnalyzeCapture reads a kept capture (RHOBOUND_E2E_CAPTURE=DIR, the folder holding traces/spans.jsonl) and
// prints what the cluster test reads from it: the entry spans' mean, each api pod's share and wait, and lost lines.
func TestAnalyzeCapture(t *testing.T) {
	dir := os.Getenv("RHOBOUND_E2E_CAPTURE")
	if dir == "" {
		t.Skip("set RHOBOUND_E2E_CAPTURE to a capture folder")
	}
	b, err := os.ReadFile(filepath.Join(dir, "traces", "spans.jsonl"))
	if err != nil {
		t.Fatal(err)
	}
	st := analyze(strings.Split(strings.TrimSpace(string(b)), "\n"))
	t.Logf("entry spans %d, mean %.2f ms after the first %d s", st.EntrySpans, st.EntryMeanMs, skipSecs)
	pods := make([]string, 0, len(st.APIShare))
	for p := range st.APIShare {
		pods = append(pods, p)
	}
	sort.Strings(pods)
	for _, p := range pods {
		t.Logf("api pod %s: share %.4f of %d calls, wait (client minus server span) %.2f ms", p, st.APIShare[p], st.APICalls, st.APIWaitMs[p])
	}
	t.Logf("calls without the callee's span %d of %d; server spans without the caller's %d of %d; unreadable lines %d",
		st.LostCallee, st.ClientSpans, st.LostCaller, st.ServerSpans, st.BadSpanLines)
	if st.EntrySpans == 0 || len(st.APIShare) == 0 {
		t.Errorf("nothing read from %s", dir)
	}
}

// TestHelpers checks the small parsers and the manifest without a cluster.
func TestHelpers(t *testing.T) {
	for in, want := range map[string]int64{"10Mi": 10 << 20, "100Mi": 100 << 20, "512Ki": 512 << 10, "1Gi": 1 << 30,
		"100M": 100e6, "1024": 1024, "": 0, "big": 0} {
		if got := quantity(in); got != want {
			t.Errorf("quantity(%q) = %d, want %d", in, got, want)
		}
	}
	if got := pressureTotal(strings.Fields("some avg10=0.12 avg60=0.00 avg300=0.00 total=12345")); got != 12345 {
		t.Errorf("pressureTotal = %v", got)
	}
	res, err := parseLoad("starting\n" + `{"errors":3,"mean_ms":null,"requests":0,"sent":3,"windows":[]}` + "\n")
	if err != nil || res.Errors != 3 || res.Sent != 3 || res.MeanMs != 0 {
		t.Errorf("parseLoad: %+v, %v", res, err)
	}
	var m strings.Builder
	if err := manifest.Execute(&m, map[string]any{"Services": services, "KeepAlive": "false"}); err != nil {
		t.Fatal(err)
	}
	if n := strings.Count(m.String(), `{name: KEEPALIVE, value: "false"}`); n != len(services) {
		t.Errorf("KEEPALIVE=false in %d of %d deployments:\n%s", n, len(services), m.String())
	}
}
