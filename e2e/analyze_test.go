// SPDX-License-Identifier: Apache-2.0

//go:build e2e

package e2e

import (
	"encoding/json"
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
	if err := manifest.Execute(&m, map[string]any{"Services": services, "KeepAlive": "false", "Place": placement{}}); err != nil {
		t.Fatal(err)
	}
	if n := strings.Count(m.String(), `{name: KEEPALIVE, value: "false"}`); n != len(services) {
		t.Errorf("KEEPALIVE=false in %d of %d deployments:\n%s", n, len(services), m.String())
	}
	// the kind test's manifest: no placement at all
	for _, s := range []string{"nodeSelector", "topologySpreadConstraints", "strategy", "rb-e2e-demo", "tolerations"} {
		if strings.Contains(m.String(), s) {
			t.Errorf("the default manifest has %s:\n%s", s, m.String())
		}
	}
	if (placement{}).loadPlacement("      ") != "" {
		t.Errorf("the default load generator has a placement")
	}
}

// TestPlacement checks the external cluster's settings: the selectors, the spread and the load node's toleration.
func TestPlacement(t *testing.T) {
	for in, want := range map[string]string{"": "", "rbv/role=app": "rbv/role=app", " b=2, a=1 ": "a=1,b=2", "k=": "k="} {
		m, err := parseSelector(in)
		if err != nil || selectorArg(m) != want {
			t.Errorf("parseSelector(%q) = %v, %v; want %q", in, m, err, want)
		}
	}
	for _, in := range []string{"rbv/role", "a=b=c", "a!=b", "=v", "a=1,,b=2", "a in (b)"} {
		if m, err := parseSelector(in); err == nil {
			t.Errorf("parseSelector(%q) = %v, want an error", in, m)
		}
	}
	app, _ := parseSelector("rbv/role=app")
	load, _ := parseSelector("rbv/role=load")
	p := placement{AppSelector: app, LoadSelector: load, Spread: true}
	var m strings.Builder
	if err := manifest.Execute(&m, map[string]any{"Services": services, "KeepAlive": "false", "Place": p}); err != nil {
		t.Fatal(err)
	}
	out := m.String()
	for s, want := range map[string]int{
		`nodeSelector: {"rbv/role": "app"}`:                                                len(services),
		`strategy: {type: RollingUpdate, rollingUpdate: {maxSurge: 0, maxUnavailable: 1}}`: len(services),
		`whenUnsatisfiable: DoNotSchedule`:                                                 len(services),
		`whenUnsatisfiable: ScheduleAnyway`:                                                len(services),
		`labelSelector: {matchLabels: {rb-e2e-demo: "true"}}`:                              len(services),
		`metadata: {labels: {app: api, rb-e2e-demo: "true"}}`:                              1,
		`labelSelector: {matchLabels: {app: api}}`:                                         1,
		`nodeTaintsPolicy: Honor`:                                                          2 * len(services),
	} {
		if n := strings.Count(out, s); n != want {
			t.Errorf("%q %d times, want %d:\n%s", s, n, want, out)
		}
	}
	lp := p.loadPlacement("      ")
	if lp != "      nodeSelector: {\"rbv/role\": \"load\"}\n      tolerations: [{key: \"rbv/role\", operator: Exists}]\n" {
		t.Errorf("load placement:\n%s", lp)
	}
}

// TestDemoTopology checks that examples/fanout-topology.json, which validation/cluster/phase-a.sh reads to choose its
// loads (and `rhobound model` evaluates), is the demo's true topology: the services table above.
func TestDemoTopology(t *testing.T) {
	b, err := os.ReadFile(filepath.Join("..", "examples", "fanout-topology.json"))
	if err != nil {
		t.Fatal(err)
	}
	var topo struct {
		Services []struct {
			Name     string   `json:"name"`
			S        float64  `json:"s"`
			Children []string `json:"children"`
			Parallel bool     `json:"parallel"`
			Servers  int      `json:"servers"`
			Workers  int      `json:"workers"`
			Routing  string   `json:"routing"`
		} `json:"services"`
		Entry map[string]float64 `json:"entry"`
	}
	if err := json.Unmarshal(b, &topo); err != nil {
		t.Fatal(err)
	}
	if len(topo.Entry) != 1 || topo.Entry["frontend"] != 1 || len(topo.Services) != len(services) {
		t.Fatalf("entry %v, %d services; the demo has frontend and %d", topo.Entry, len(topo.Services), len(services))
	}
	for _, ts := range topo.Services {
		var s *svc
		for i := range services {
			if services[i].Name == ts.Name {
				s = &services[i]
			}
		}
		if s == nil {
			t.Errorf("%s is not a demo service", ts.Name)
			continue
		}
		var calls []string
		for _, c := range split(s.Calls) {
			calls = append(calls, strings.TrimSuffix(strings.TrimPrefix(c, "http://"), ":8080"))
		}
		w := max(ts.Workers, 1)
		pods, perPod := ts.Servers, w
		if ts.Routing != "random" { // pooled: one queue of servers workers, i.e. one pod
			pods, perPod = 1, ts.Servers*w
		}
		if ts.S != s.MeanMs || ts.Parallel != s.Parallel || strings.Join(ts.Children, ",") != strings.Join(calls, ",") ||
			pods != s.Replicas || perPod != s.Workers {
			t.Errorf("%s: topology s %v, calls %v, parallel %v, %d pods x %d workers; the demo: %v, %v, %v, %d x %d",
				ts.Name, ts.S, ts.Children, ts.Parallel, pods, perPod, s.MeanMs, calls, s.Parallel, s.Replicas, s.Workers)
		}
	}
}

// split is "a,b" as its parts ("" is none).
func split(s string) []string {
	if s == "" {
		return nil
	}
	return strings.Split(s, ",")
}
