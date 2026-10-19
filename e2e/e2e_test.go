// SPDX-License-Identifier: Apache-2.0

//go:build e2e

// Package e2e runs the CLI against a real (kind) Kubernetes cluster.
//
//	RHOBOUND_E2E=1 go test -tags e2e -v -timeout 40m ./e2e
//
// It needs docker, kind and kubectl on the PATH. It uses its own kubeconfig
// file and never touches the default one.
//
// The test builds the demo services and load generator in this folder, runs
// them as Deployments (frontend -> api x2 replicas -> db, frontend -> cache
// in parallel), drives an open-loop Poisson load, collects the spans the
// services print to stdout, and runs `rhobound predict` on that capture. The
// change is an extra constant time in api, rolled out with `kubectl set env`.
// The "observed" latencies are measured by the load generator, not by any trace.
//
// The windows are interleaved, before / after / before / after, and every
// deployment is restarted before each one, so each capture holds one window
// only and starts from an empty log. The test reads each capture itself (the
// entry spans' mean, each api pod's share of the calls and its wait, lost
// lines) and records the load generator's lag and worst 10-s window, pod
// restarts and the node's CPU and memory. If any of these says a window was
// not steady, or two windows of the same kind disagree, the run is UNSTABLE:
// the test logs why and skips instead of judging the model.
//
// Settings (environment):
//
//	RHOBOUND_E2E_ROUNDS=N     before/after pairs (default 2, about 13 minutes; 1 is the old single pair)
//	RHOBOUND_E2E_STRICT=1     fail instead of skip when the run is UNSTABLE
//	RHOBOUND_E2E_KEEPALIVE=1  frontend and api reuse connections: a robustness run (see maxShare)
//	RHOBOUND_E2E_WORK=DIR     the work folder; the default is a new folder under $HOME/.cache/rb-e2e-work,
//	                          kept when the test fails or skips (a pass removes the captures, keeps result.json)
//	RHOBOUND_E2E_KEEP=1       keep the cluster afterwards; a later run reuses it
//	RHOBOUND_E2E_CAPTURE=DIR  read one kept capture offline (TestAnalyzeCapture)
package e2e

import (
	"bytes"
	"encoding/json"
	"fmt"
	"math"
	"os"
	"os/exec"
	"path/filepath"
	"runtime"
	"sort"
	"strconv"
	"strings"
	"testing"
	"text/template"
	"time"
)

const (
	cluster = "rb-oss-e2e"
	ns      = "rb-e2e"
	image   = "rhobound-demo:e2e"
	rps     = 30
	runSecs = 150
	extraMs = 8.0 // the change: a constant extra time in api

	skipSecs = 5 // the load generator ignores the latencies of requests sent in this first part
)

// The gates. A window or a run that trips an UNSTABLE gate is not used to judge the model: the test logs the
// reasons and skips. The false-alarm rates are for a good run with a new connection per call and 2 rounds, from
// the binomial split or from a simulation of this demo (the connection simulator of the 2026-10-19 diagnosis,
// extended with these gates: exponential service times, no network hop, 3000-4000 simulated runs per number).
// "Not checked in a cluster" marks a threshold that no real run has tested yet.
const (
	// maxShare: one api pod taking more than this share of the api calls is not the model's even split. With a new
	// connection per call the split is binomial, sd 0.0076 at a window's about 4,350 calls, so 0.55 is 6.6 sd: a
	// false alarm about once in 10^10 windows. A split of 0.55 in every window would bias the measured change by
	// about +0.25 ms (simulated; 0.58: +0.64 ms). With keep-alive (RHOBOUND_E2E_KEEPALIVE=1) Kubernetes picks the
	// pod per connection and Go reuses the most recently used idle one, so a few connections set the split; the
	// simulation trips this gate in 99.7% of such runs. That is what a robustness run looks at: it logs the shares
	// and the model's errors as "not judged" (RHOBOUND_E2E_STRICT=1 makes it fail instead).
	maxShare = 0.55
	// repeatTol: two windows of the same kind further apart than this share of their mean (kind run 3's before
	// window read 52 ms against 43 in the other runs). Simulated false alarms: 0-0.07% of runs on the before
	// windows, 0.1-0.3% on the after windows (3 rounds: 0.2% and 0.2-0.6%).
	repeatTol = 0.10
	// maxWorst: a window whose worst 10-s mean is above this multiple of its median 10-s mean had a transient (a
	// stall, a slow start) that moves the window's mean by about 2 ms or more. Simulated false alarms: none in
	// 6,000 runs (at 1.5: 0.3-0.6%).
	maxWorst = 1.75
	// maxLagMs: the load generator fell this far behind its Poisson schedule (a stall of the client or the node).
	// Not checked in a cluster; a local run on a busy machine lagged 1-5 ms.
	maxLagMs = 100
	// minKept: fewer entry spans than this share of the requests sent, or fewer matched spans than this share of
	// the client or server spans, means log lines were lost (a rotation, a pod that went away). Exact on a good run.
	minKept = 0.98
	// maxGapMs: the load generator's mean minus the entry spans' mean is time outside the services, which the model
	// cannot see. Not checked in a cluster with a new connection per call; it was 0.2-0.33 ms in the keep-alive
	// kind runs and under 1 ms locally.
	maxGapMs = 2
	// maxMemStall: share of the window in which some task in the node waited for memory (the node container's
	// cgroup pressure). Not checked in a cluster; a node far below its memory limit should read 0.
	maxMemStall = 0.01

	// The model's gates (FAIL). On a steady run the simulated false failures are 0.1% if the model is right on
	// average, and 1-2% with its present bias of about +1 ms on the change (1 round: 2.3% and 5.5%; 3 rounds: 0.0%
	// and 0.4%). It is the change gate that trips; the level gate has a wide margin (window sd about 0.85 ms).
	levelTol  = 0.10 // |model - measured| entry latency, as a share of the measured
	changeRel = 0.15 // |predicted - measured| change at most changeRel*|measured| + changeAbs
	changeAbs = 1.5  // ms
)

// kindConfig raises the kubelet's log size limit when the test creates the cluster. kubectl logs reads only the
// current log file, so lines written before a rotation are lost without a sign; the default limit (10Mi) is about
// two windows of the frontend's lines (about 1 KiB per request). A reused cluster keeps its limit, which the test
// reads back from the kubelet and checks.
const kindConfig = `kind: Cluster
apiVersion: kind.x-k8s.io/v1alpha4
kubeadmConfigPatches:
- |
  kind: KubeletConfiguration
  containerLogMaxSize: 100Mi
`

// lineBytes is about one frontend span line on the node's disk (the line plus the container runtime's prefix).
const lineBytes = 1100

type env struct {
	t         *testing.T
	root      string // repository root
	work      string // work folder
	kube      string // kubeconfig file of this test
	runID     string // this run's name, part of every window's pod template
	node      string // the kind node's name
	logMax    int64  // the kubelet's containerLogMaxSize in bytes, 0 if unknown
	keepAlive bool   // RHOBOUND_E2E_KEEPALIVE=1
}

func (e *env) run(name string, args ...string) string {
	e.t.Helper()
	out, err := e.try(name, args...)
	if err != nil {
		e.t.Fatalf("%s %s: %v\n%s", name, strings.Join(args, " "), err, out)
	}
	return out
}

// try runs a command with this test's kubeconfig and returns its stdout. Stderr goes into the error only, so
// a warning cannot corrupt the JSON that kubectl prints.
func (e *env) try(name string, args ...string) (string, error) {
	cmd := exec.Command(name, args...)
	cmd.Dir = e.root
	cmd.Env = append(os.Environ(), "KUBECONFIG="+e.kube)
	var out, errb bytes.Buffer
	cmd.Stdout, cmd.Stderr = &out, &errb
	if err := cmd.Run(); err != nil {
		return out.String(), fmt.Errorf("%v: %s", err, strings.TrimSpace(errb.String()))
	}
	return out.String(), nil
}

func (e *env) kubectl(args ...string) string {
	e.t.Helper()
	return e.run("kubectl", append([]string{"-n", ns}, args...)...)
}

var manifest = template.Must(template.New("m").Parse(`
apiVersion: v1
kind: Namespace
metadata: {name: rb-e2e}
{{range .Services}}
---
apiVersion: apps/v1
kind: Deployment
metadata: {name: {{.Name}}, namespace: rb-e2e}
spec:
  replicas: {{.Replicas}}
  selector: {matchLabels: {app: {{.Name}}}}
  template:
    metadata: {labels: {app: {{.Name}}}}
    spec:
      containers:
      - name: app
        image: rhobound-demo:e2e
        imagePullPolicy: IfNotPresent
        ports: [{containerPort: 8080}]
        readinessProbe: {httpGet: {path: /healthz, port: 8080}, periodSeconds: 1}
        resources: {requests: {cpu: 20m, memory: 24Mi}, limits: {memory: 128Mi}}
        env:
        - {name: SERVICE, value: {{.Name}}}
        - {name: POD_NAME, valueFrom: {fieldRef: {fieldPath: metadata.name}}}
        - {name: WORKERS, value: "{{.Workers}}"}
        - {name: MEAN_MS, value: "{{.MeanMs}}"}
        - {name: EXTRA_MS, value: "0"}
        - {name: CALLS, value: "{{.Calls}}"}
        - {name: PARALLEL, value: "{{.Parallel}}"}
        - {name: KEEPALIVE, value: "{{$.KeepAlive}}"} # false: a new connection per call, so a Service splits per request (see demoapp)
---
apiVersion: v1
kind: Service
metadata: {name: {{.Name}}, namespace: rb-e2e}
spec:
  selector: {app: {{.Name}}}
  ports: [{port: 8080, targetPort: 8080}]
{{end}}
`))

type svc struct {
	Name     string
	Replicas int
	Workers  int
	MeanMs   float64
	Calls    string
	Parallel bool
}

// the services and their true parameters; the test knows them, the CLI does not
var services = []svc{
	{"db", 1, 1, 8, "", false},
	{"cache", 1, 2, 5, "", false},
	{"api", 2, 1, 20, "http://db:8080", false},
	{"frontend", 1, 4, 3, "http://api:8080,http://cache:8080", true},
}

func (e *env) build() {
	arch := runtime.GOARCH
	for _, b := range []string{"demoapp", "loadgen"} {
		cmd := exec.Command("go", "build", "-o", filepath.Join(e.work, "img", b), "./e2e/"+b)
		cmd.Dir = e.root
		cmd.Env = append(os.Environ(), "CGO_ENABLED=0", "GOOS=linux", "GOARCH="+arch)
		if out, err := cmd.CombinedOutput(); err != nil {
			e.t.Fatalf("build %s: %v\n%s", b, err, out)
		}
	}
	data, _ := os.ReadFile(filepath.Join(e.root, "e2e", "Dockerfile"))
	os.WriteFile(filepath.Join(e.work, "img", "Dockerfile"), data, 0o644)
	e.run("docker", "build", "-q", "-t", image, filepath.Join(e.work, "img"))
	e.run("kind", "load", "docker-image", image, "--name", cluster)
}

// loadResult is what the load generator printed.
type loadResult struct {
	Requests int     `json:"requests"`
	Errors   int     `json:"errors"`
	Sent     int     `json:"sent"`
	MaxLagMs float64 `json:"max_lag_ms"`
	MeanMs   float64 `json:"mean_ms"` // null (read as 0) when no request succeeded
	Windows  []struct {
		StartS float64 `json:"start_s"`
		N      int     `json:"n"`
		MeanMs float64 `json:"mean_ms"`
	} `json:"windows"`
}

// parseLoad reads the load generator's last output line.
func parseLoad(out string) (loadResult, error) {
	var res loadResult
	s := strings.TrimSpace(out)
	err := json.Unmarshal([]byte(s[strings.LastIndex(s, "\n")+1:]), &res)
	return res, err
}

// loadgen runs the load generator as a Job and returns what it measured.
func (e *env) loadgen(name string, secs int) loadResult {
	e.t.Helper()
	job := fmt.Sprintf(`
apiVersion: batch/v1
kind: Job
metadata: {name: %s, namespace: rb-e2e}
spec:
  backoffLimit: 0
  template:
    spec:
      restartPolicy: Never
      containers:
      - name: load
        image: rhobound-demo:e2e
        imagePullPolicy: IfNotPresent
        command: ["/loadgen", "-target=http://frontend:8080/", "-rps=%d", "-duration=%ds", "-skip=%ds"]
`, name, rps, secs, skipSecs)
	path := filepath.Join(e.work, name+".yaml")
	os.WriteFile(path, []byte(job), 0o644)
	// a Job of this name left by an earlier run on a kept cluster is complete already: apply would leave it
	// "unchanged", and the wait and logs below would read that run's numbers as this one's
	e.kubectl("delete", "job", name, "--ignore-not-found", "--wait=true", "--cascade=foreground")
	e.run("kubectl", "apply", "-f", path)
	e.kubectl("wait", "--for=condition=complete", "job/"+name, fmt.Sprintf("--timeout=%ds", secs+120))
	out := e.kubectl("logs", "job/"+name)
	os.WriteFile(filepath.Join(e.work, name+".loadgen.json"), []byte(out), 0o644)
	res, err := parseLoad(out)
	if err != nil {
		e.t.Fatalf("loadgen output %q: %v", out, err)
	}
	if res.Requests == 0 || res.Errors > res.Requests/100 {
		e.t.Fatalf("loadgen: %d errors, %d requests measured, %d sent", res.Errors, res.Requests, res.Sent)
	}
	return res
}

// appPods returns the demo services' pods that serve (Running, ready, not being deleted) with their container
// restarts, and how many are being deleted. A terminating pod is still Running, and its log can vanish while the
// capture reads it.
func (e *env) appPods() (map[string]int, int) {
	names := make([]string, len(services))
	for i, s := range services {
		names[i] = s.Name
	}
	out, err := e.try("kubectl", "-n", ns, "get", "pods", "-l", "app in ("+strings.Join(names, ",")+")", "-o", "json")
	var list struct {
		Items []struct {
			Metadata struct {
				Name     string  `json:"name"`
				Deletion *string `json:"deletionTimestamp"`
			} `json:"metadata"`
			Status struct {
				Phase      string `json:"phase"`
				Containers []struct {
					Ready    bool `json:"ready"`
					Restarts int  `json:"restartCount"`
				} `json:"containerStatuses"`
			} `json:"status"`
		} `json:"items"`
	}
	if err == nil {
		err = json.Unmarshal([]byte(out), &list)
	}
	if err != nil {
		e.t.Logf("listing the pods: %v", err)
		return nil, 0
	}
	pods, terminating := map[string]int{}, 0
	for _, p := range list.Items {
		if p.Metadata.Deletion != nil {
			terminating++
			continue
		}
		ready, restarts := p.Status.Phase == "Running" && len(p.Status.Containers) > 0, 0
		for _, c := range p.Status.Containers {
			ready = ready && c.Ready
			restarts += c.Restarts
		}
		if ready {
			pods[p.Metadata.Name] = restarts
		}
	}
	return pods, terminating
}

// settle waits until exactly the declared pods serve and the old ones are gone.
func (e *env) settle() {
	want := 0
	for _, s := range services {
		want += s.Replicas
	}
	deadline := time.Now().Add(120 * time.Second)
	for {
		pods, terminating := e.appPods()
		if len(pods) == want && terminating == 0 {
			return
		}
		if time.Now().After(deadline) {
			e.t.Logf("after 120 s: %d serving pods (want %d), %d still terminating; going on", len(pods), want, terminating)
			return
		}
		time.Sleep(2 * time.Second)
	}
}

// nodeName is the kind node's name (one node).
func (e *env) nodeName() string {
	return strings.TrimSpace(e.run("kubectl", "get", "nodes", "-o", "jsonpath={.items[0].metadata.name}"))
}

// quantity reads a kubelet size such as "10Mi" or "100M" in bytes (0 if it cannot).
func quantity(s string) int64 {
	for _, u := range []struct {
		suffix string
		mult   float64
	}{{"Ki", 1 << 10}, {"Mi", 1 << 20}, {"Gi", 1 << 30}, {"K", 1e3}, {"k", 1e3}, {"M", 1e6}, {"G", 1e9}, {"", 1}} {
		if v, ok := strings.CutSuffix(s, u.suffix); ok {
			if f, err := strconv.ParseFloat(v, 64); err == nil {
				return int64(f * u.mult)
			}
			return 0
		}
	}
	return 0
}

// kubeletLogMax reads the kubelet's containerLogMaxSize from its live configuration (the cluster may be reused).
func (e *env) kubeletLogMax() (int64, string) {
	out, err := e.try("kubectl", "get", "--raw", "/api/v1/nodes/"+e.node+"/proxy/configz")
	var c struct {
		Kubelet struct {
			ContainerLogMaxSize string `json:"containerLogMaxSize"`
		} `json:"kubeletconfig"`
	}
	if err == nil {
		err = json.Unmarshal([]byte(out), &c)
	}
	if err != nil || c.Kubelet.ContainerLogMaxSize == "" {
		return 0, fmt.Sprintf("unknown (%v)", err)
	}
	return quantity(c.Kubelet.ContainerLogMaxSize), c.Kubelet.ContainerLogMaxSize
}

// nodeSample is a reading of the node's cumulative counters; -1 marks one that could not be read.
type nodeSample struct {
	at                   time.Time
	cpuNs, memBytes      float64 // the kubelet's node summary (kind has no metrics-server): CPU time, working set
	cpuStall, memStall   float64 // the node container's cgroup pressure, "some" total in microseconds
	oomKills             float64 // the node container's cgroup memory.events
	hostCPUUs, hostMemUs float64 // the host's /proc/pressure "some" totals in microseconds
}

func (e *env) nodeSample() nodeSample {
	s := nodeSample{at: time.Now(), cpuNs: -1, memBytes: -1, cpuStall: -1, memStall: -1, oomKills: -1,
		hostCPUUs: hostPressure("cpu"), hostMemUs: hostPressure("memory")}
	if out, err := e.try("kubectl", "get", "--raw", "/api/v1/nodes/"+e.node+"/proxy/stats/summary"); err == nil {
		var sum struct {
			Node struct {
				CPU struct {
					Ns *float64 `json:"usageCoreNanoSeconds"`
				} `json:"cpu"`
				Memory struct {
					WorkingSet *float64 `json:"workingSetBytes"`
				} `json:"memory"`
			} `json:"node"`
		}
		if json.Unmarshal([]byte(out), &sum) == nil {
			if sum.Node.CPU.Ns != nil {
				s.cpuNs = *sum.Node.CPU.Ns
			}
			if sum.Node.Memory.WorkingSet != nil {
				s.memBytes = *sum.Node.Memory.WorkingSet
			}
		}
	}
	// the kind node is a container with its own cgroup namespace, so its cgroup root is the whole node; grep prints
	// what it can read even if one file is missing
	out, _ := e.try("docker", "exec", e.node, "grep", "-H", "", "/sys/fs/cgroup/cpu.pressure",
		"/sys/fs/cgroup/memory.pressure", "/sys/fs/cgroup/memory.events")
	for _, l := range strings.Split(out, "\n") {
		file, line, ok := strings.Cut(l, ":")
		if !ok {
			continue
		}
		f := strings.Fields(line)
		switch {
		case strings.HasSuffix(file, "cpu.pressure") && len(f) > 0 && f[0] == "some":
			s.cpuStall = pressureTotal(f)
		case strings.HasSuffix(file, "memory.pressure") && len(f) > 0 && f[0] == "some":
			s.memStall = pressureTotal(f)
		case strings.HasSuffix(file, "memory.events") && len(f) == 2 && f[0] == "oom_kill":
			s.oomKills, _ = strconv.ParseFloat(f[1], 64)
		}
	}
	return s
}

// pressureTotal reads total=N from the fields of a pressure line.
func pressureTotal(fields []string) float64 {
	for _, f := range fields {
		if v, ok := strings.CutPrefix(f, "total="); ok {
			if x, err := strconv.ParseFloat(v, 64); err == nil {
				return x
			}
		}
	}
	return -1
}

// hostPressure reads the host's "some" stall total (microseconds) from /proc/pressure/<what>; -1 if unavailable.
func hostPressure(what string) float64 {
	b, err := os.ReadFile("/proc/pressure/" + what)
	if err != nil {
		return -1
	}
	return pressureTotal(strings.Fields(strings.SplitN(string(b), "\n", 2)[0]))
}

// rate is (b - a) / scale per microsecond of the interval, or -1 when either reading is missing.
func rate(a, b, scale float64, us float64) float64 {
	if a < 0 || b < 0 || us <= 0 {
		return -1
	}
	return (b - a) / scale / us
}

// capture writes CAPTURE/traces/spans.jsonl from the serving app pods' stdout since `since`, and
// CAPTURE/cluster/k8s.json. It returns the span lines and each pod's log size on the node's disk (estimated).
func (e *env) capture(dir string, since time.Time) ([]string, map[string]int64) {
	e.t.Helper()
	if err := os.MkdirAll(filepath.Join(dir, "traces"), 0o755); err != nil {
		e.t.Fatal(err)
	}
	if err := os.MkdirAll(filepath.Join(dir, "cluster"), 0o755); err != nil {
		e.t.Fatal(err)
	}
	var all strings.Builder
	var lines []string
	size := map[string]int64{}
	pods, _ := e.appPods()
	names := make([]string, 0, len(pods))
	for p := range pods {
		names = append(names, p)
	}
	sort.Strings(names)
	for _, p := range names {
		out, err := e.try("kubectl", "-n", ns, "logs", p, "--since-time="+since.UTC().Format(time.RFC3339))
		if err != nil { // a missing pod's lines show up in the lost-line gate
			e.t.Logf("logs of %s: %v", p, err)
		}
		n := 0
		for _, l := range strings.Split(out, "\n") {
			if strings.HasPrefix(l, `{"resourceSpans"`) {
				all.WriteString(l + "\n")
				lines = append(lines, l)
				n++
			}
		}
		size[p] = int64(len(out)) + 40*int64(n) // the runtime adds a time stamp and "stdout F " to each line
	}
	os.WriteFile(filepath.Join(dir, "traces", "spans.jsonl"), []byte(all.String()), 0o644)
	if k, err := e.try("kubectl", "-n", ns, "get", "deploy,svc,pods", "-o", "json"); err == nil {
		os.WriteFile(filepath.Join(dir, "cluster", "k8s.json"), []byte(k), 0o644)
	}
	return lines, size
}

// traceStats is what the test reads from a capture itself, independent of the CLI.
type traceStats struct {
	EntrySpans   int                // frontend server spans
	EntryMeanMs  float64            // their mean, for requests after the load generator's skip
	APIShare     map[string]float64 // share of api calls per api pod
	APIWaitMs    map[string]float64 // per api pod: the caller's client span minus api's server span (worker wait + hop)
	APICalls     int
	ClientSpans  int
	LostCallee   int // client spans with no server span below them: the callee's line is missing
	ServerSpans  int // server spans other than the entry's
	LostCaller   int // of those, the ones whose client span is missing: the caller's line is missing
	SpanLines    int
	BadSpanLines int
}

type otlpKV struct {
	Key   string `json:"key"`
	Value struct {
		StringValue string `json:"stringValue"`
	} `json:"value"`
}

type otlpLine struct {
	ResourceSpans []struct {
		Resource struct {
			Attributes []otlpKV `json:"attributes"`
		} `json:"resource"`
		ScopeSpans []struct {
			Spans []struct {
				SpanID string `json:"spanId"`
				Parent string `json:"parentSpanId"`
				Kind   int    `json:"kind"`
				Start  string `json:"startTimeUnixNano"`
				End    string `json:"endTimeUnixNano"`
			} `json:"spans"`
		} `json:"scopeSpans"`
	} `json:"resourceSpans"`
}

func attr(kv []otlpKV, k string) string {
	for _, a := range kv {
		if a.Key == k {
			return a.Value.StringValue
		}
	}
	return ""
}

// analyze reads the demo's span lines. The entry is frontend; calls are matched to the spans they caused by
// span id (a server span's parent is its caller's client span), so it needs no host names.
func analyze(lines []string) traceStats {
	type span struct {
		svc, pod, parent string
		start, dur       float64 // s, ms
	}
	st := traceStats{APIShare: map[string]float64{}, APIWaitMs: map[string]float64{}, SpanLines: len(lines)}
	var entry, servers []span
	client := map[string]float64{} // client span id -> duration (ms)
	for _, l := range lines {
		var o otlpLine
		if json.Unmarshal([]byte(l), &o) != nil {
			st.BadSpanLines++
			continue
		}
		for _, rs := range o.ResourceSpans {
			svc, pod := attr(rs.Resource.Attributes, "service.name"), attr(rs.Resource.Attributes, "k8s.pod.name")
			for _, ss := range rs.ScopeSpans {
				for _, sp := range ss.Spans {
					a, _ := strconv.ParseInt(sp.Start, 10, 64)
					b, _ := strconv.ParseInt(sp.End, 10, 64)
					x := span{svc: svc, pod: pod, parent: sp.Parent, start: float64(a) / 1e9, dur: float64(b-a) / 1e6}
					switch {
					case sp.Kind == 2 && svc == "frontend":
						entry = append(entry, x)
					case sp.Kind == 2:
						servers = append(servers, x)
					case sp.Kind == 3:
						client[sp.SpanID] = x.dur
					}
				}
			}
		}
	}
	st.EntrySpans, st.ClientSpans, st.ServerSpans = len(entry), len(client), len(servers)
	if len(entry) > 0 {
		t0 := entry[0].start
		for _, x := range entry {
			t0 = math.Min(t0, x.start)
		}
		sum, n := 0.0, 0
		for _, x := range entry {
			if x.start >= t0+skipSecs {
				sum += x.dur
				n++
			}
		}
		if n > 0 {
			st.EntryMeanMs = sum / float64(n)
		}
	}
	matched := map[string]bool{}
	count, waits, nAPI := map[string]int{}, map[string]int{}, 0
	for _, x := range servers {
		c, ok := client[x.parent]
		if !ok {
			st.LostCaller++
		}
		matched[x.parent] = true
		if x.svc != "api" {
			continue
		}
		nAPI++
		count[x.pod]++
		if ok {
			st.APIWaitMs[x.pod] += c - x.dur
			waits[x.pod]++
		}
	}
	for id := range client {
		if !matched[id] {
			st.LostCallee++
		}
	}
	st.APICalls = nAPI
	for p, k := range count {
		st.APIShare[p] = float64(k) / float64(nAPI)
		if waits[p] > 0 {
			st.APIWaitMs[p] /= float64(waits[p])
		}
	}
	return st
}

// phaseResult is one measured window: the load generator's numbers, the traces' own, and the health signals.
type phaseResult struct {
	Name          string             `json:"name"`
	ExtraMs       float64            `json:"extra_ms"`
	Start         time.Time          `json:"start"`
	MeasuredMs    float64            `json:"measured_ms"`
	Requests      int                `json:"requests"`
	Sent          int                `json:"sent"`
	Errors        int                `json:"errors"`
	MaxLagMs      float64            `json:"loadgen_max_lag_ms"`
	WorstWindow   float64            `json:"worst_10s_over_median"`
	TraceEntryMs  float64            `json:"trace_entry_ms"`
	EntrySpans    int                `json:"entry_spans"`
	APIShare      map[string]float64 `json:"api_share"`
	APIWaitMs     map[string]float64 `json:"api_wait_ms"`
	LostCallee    int                `json:"client_spans_without_callee"`
	LostCaller    int                `json:"server_spans_without_caller"`
	PodsChanged   bool               `json:"pods_changed"`
	Restarts      int                `json:"pod_restarts"`
	LogBytesMax   int64              `json:"largest_pod_log_bytes"`
	NodeCores     float64            `json:"node_cpu_cores"`      // mean over the window
	NodeMemMiB    float64            `json:"node_memory_mib"`     // working set at the end
	NodeCPUStall  float64            `json:"node_cpu_some_share"` // -1: unavailable
	NodeMemStall  float64            `json:"node_memory_some_share"`
	NodeOOMKills  float64            `json:"node_oom_kills"`
	HostCPUStall  float64            `json:"host_cpu_some_share"`
	HostMemStall  float64            `json:"host_memory_some_share"`
	ModelMs       float64            `json:"model_entry_ms,omitempty"` // before windows: the CLI on this capture
	ModelChangeMs float64            `json:"model_change_ms,omitempty"`
	Capture       string             `json:"capture"`
	Unstable      []string           `json:"unstable,omitempty"`
}

// phase restarts every demo deployment (fresh pods, empty logs, new connections) with api's extra time, drives
// the load, captures the traces of this window only and checks the measurement for signs that it is not steady.
func (e *env) phase(name string, extra float64) phaseResult {
	e.t.Helper()
	// A new value of RB_WINDOW changes every pod template, so each deployment rolls exactly once, with EXTRA_MS in
	// the same change; setting EXTRA_MS every time also resets a kept cluster that ended on the last run's value
	// (kubectl apply would leave it, since it was set by `set env`, not by the manifest).
	for _, s := range services {
		args := []string{"set", "env", "deploy/" + s.Name, "RB_WINDOW=" + e.runID + "-" + name}
		if s.Name == "api" {
			args = append(args, fmt.Sprintf("EXTRA_MS=%g", extra))
		}
		e.kubectl(args...)
	}
	for _, s := range services {
		e.kubectl("rollout", "status", "deploy/"+s.Name, "--timeout=180s")
	}
	e.settle()
	time.Sleep(5 * time.Second)

	pods0, _ := e.appPods()
	n0 := e.nodeSample()
	lg := e.loadgen(name, runSecs)
	n1 := e.nodeSample()
	pods1, _ := e.appPods()
	us := float64(n1.at.Sub(n0.at).Microseconds())
	res := phaseResult{Name: name, ExtraMs: extra, Start: n0.at, MeasuredMs: lg.MeanMs, Requests: lg.Requests,
		Sent: lg.Sent, Errors: lg.Errors, MaxLagMs: lg.MaxLagMs,
		NodeCores: rate(n0.cpuNs, n1.cpuNs, 1e3, us), NodeMemMiB: n1.memBytes / (1 << 20),
		NodeCPUStall: rate(n0.cpuStall, n1.cpuStall, 1, us), NodeMemStall: rate(n0.memStall, n1.memStall, 1, us),
		NodeOOMKills: n1.oomKills - n0.oomKills,
		HostCPUStall: rate(n0.hostCPUUs, n1.hostCPUUs, 1, us), HostMemStall: rate(n0.hostMemUs, n1.hostMemUs, 1, us)}
	if n0.oomKills < 0 || n1.oomKills < 0 {
		res.NodeOOMKills = -1
	}
	if n1.memBytes < 0 {
		res.NodeMemMiB = -1
	}
	res.PodsChanged = len(pods0) != len(pods1)
	for p, r := range pods1 {
		r0, ok := pods0[p]
		res.PodsChanged = res.PodsChanged || !ok
		res.Restarts += r - r0
	}
	var wm []float64
	for _, w := range lg.Windows {
		if w.StartS >= skipSecs && w.N > 0 {
			wm = append(wm, w.MeanMs)
		}
	}
	if len(wm) > 0 {
		sort.Float64s(wm)
		res.WorstWindow = wm[len(wm)-1] / wm[len(wm)/2]
	}
	res.Capture = filepath.Join(e.work, "capture-"+name)
	lines, size := e.capture(res.Capture, n0.at)
	st := analyze(lines)
	res.TraceEntryMs, res.EntrySpans, res.APIShare, res.APIWaitMs = st.EntryMeanMs, st.EntrySpans, st.APIShare, st.APIWaitMs
	res.LostCallee, res.LostCaller = st.LostCallee, st.LostCaller
	biggest := ""
	for p, b := range size {
		if b > res.LogBytesMax {
			res.LogBytesMax, biggest = b, p
		}
	}

	// signs of a measurement that is not steady (see the gate constants for their false-alarm rates)
	bad := func(f string, a ...any) { res.Unstable = append(res.Unstable, fmt.Sprintf(f, a...)) }
	for p, sh := range st.APIShare {
		if sh > maxShare {
			sd := 0.5 / math.Sqrt(float64(st.APICalls))
			why := "a new connection per call should split them evenly; is the Service routing per request?"
			if e.keepAlive {
				why = "keep-alive is on (RHOBOUND_E2E_KEEPALIVE=1): the pod is picked per connection"
			}
			bad("api pod %s took %.1f%% of the api calls (more than %.0f%%; an even random split of %d calls is 50%% ± %.1f%%, 1 sd); %s",
				p, 100*sh, 100*maxShare, st.APICalls, 100*sd, why)
		}
	}
	if len(st.APIShare) != 2 {
		bad("the traces show %d api pods, not 2", len(st.APIShare))
	}
	if res.PodsChanged || res.Restarts > 0 {
		bad("the serving pods changed or restarted during the window (%d container restarts)", res.Restarts)
	}
	if lg.MaxLagMs > maxLagMs {
		bad("the load generator fell %.0f ms behind its schedule (a stall of the client or the node)", lg.MaxLagMs)
	}
	if res.WorstWindow > maxWorst {
		bad("the worst 10-s window's mean latency was %.2fx the median window's (a transient, not a steady state)", res.WorstWindow)
	}
	if float64(st.EntrySpans) < minKept*float64(lg.Sent) {
		bad("the capture holds %d entry spans for %d requests sent (lost log lines?)", st.EntrySpans, lg.Sent)
	} else if float64(st.EntrySpans) > float64(lg.Sent)/minKept {
		bad("the capture holds %d entry spans for %d requests sent: spans from outside this window", st.EntrySpans, lg.Sent)
	}
	if float64(st.LostCallee) > (1-minKept)*float64(st.ClientSpans) || float64(st.LostCaller) > (1-minKept)*float64(st.ServerSpans) {
		bad("lost log lines: %d of %d calls have no span from the callee, %d of %d server spans no span from the caller",
			st.LostCallee, st.ClientSpans, st.LostCaller, st.ServerSpans)
	}
	if st.BadSpanLines > 0 {
		bad("%d of %d span lines did not parse", st.BadSpanLines, st.SpanLines)
	}
	if d := lg.MeanMs - st.EntryMeanMs; math.Abs(d) > maxGapMs {
		bad("the load generator measured %.2f ms but the entry spans %.2f ms: %.2f ms outside the services", lg.MeanMs, st.EntryMeanMs, d)
	}
	if res.NodeMemStall > maxMemStall {
		bad("memory pressure in the node: some task waited for memory %.2f%% of the window", 100*res.NodeMemStall)
	}
	if res.NodeOOMKills > 0 {
		bad("%.0f processes in the node were killed for memory during the window", res.NodeOOMKills)
	}
	if e.logMax > 0 && res.LogBytesMax > e.logMax {
		bad("pod %s wrote about %.1f MiB, more than the kubelet's log limit of %.1f MiB: its log rotated and kubectl logs reads only the current file",
			biggest, float64(res.LogBytesMax)/(1<<20), float64(e.logMax)/(1<<20))
	} else if e.logMax > 0 && 2*res.LogBytesMax > e.logMax {
		e.t.Logf("warning: pod %s wrote about %.1f MiB in this window, more than half the kubelet's log limit (%.1f MiB)",
			biggest, float64(res.LogBytesMax)/(1<<20), float64(e.logMax)/(1<<20))
	}

	shares := []string{}
	for p, sh := range st.APIShare {
		shares = append(shares, fmt.Sprintf("%s %.1f%% wait %.2f ms", p[strings.LastIndex(p, "-")+1:], 100*sh, st.APIWaitMs[p]))
	}
	sort.Strings(shares)
	e.t.Logf("%-8s extra %gms: load generator %.2f ms (%d req, %d err, lag %.0f ms, worst 10-s x%.2f); traces: entry %.2f ms over %d spans, api %s",
		name, extra, lg.MeanMs, lg.Requests, lg.Errors, lg.MaxLagMs, res.WorstWindow, st.EntryMeanMs, st.EntrySpans, strings.Join(shares, ", "))
	e.t.Logf("%-8s node: %s cores, %s MiB, stall cpu %s mem %s, oom kills %s; host stall cpu %s mem %s; largest log %.1f MiB; restarts %d",
		name, orNA("%.2f", res.NodeCores), orNA("%.0f", res.NodeMemMiB), pct(res.NodeCPUStall), pct(res.NodeMemStall), orNA("%.0f", res.NodeOOMKills),
		pct(res.HostCPUStall), pct(res.HostMemStall), float64(res.LogBytesMax)/(1<<20), res.Restarts)
	for _, u := range res.Unstable {
		e.t.Logf("  unstable: %s", u)
	}
	return res
}

// orNA formats a reading, or "n/a" for one that could not be taken (-1).
func orNA(format string, x float64) string {
	if x < 0 {
		return "n/a"
	}
	return fmt.Sprintf(format, x)
}

func pct(x float64) string { return orNA("%.2f%%", 100*x) }

func (e *env) predict(capture string, extra ...string) map[string]any {
	e.t.Helper()
	args := append([]string{"predict", capture, "--json"}, extra...)
	cmd := exec.Command(filepath.Join(e.root, "bin", "rhobound"), args...)
	var out, errb bytes.Buffer
	cmd.Stdout, cmd.Stderr = &out, &errb
	if err := cmd.Run(); err != nil {
		e.t.Fatalf("rhobound %v: %v\n%s", args, err, errb.String())
	}
	var rep map[string]any
	if err := json.Unmarshal(out.Bytes(), &rep); err != nil {
		e.t.Fatalf("report: %v", err)
	}
	return rep
}

func row(rep map[string]any, name string) map[string]any {
	for _, s := range rep["services"].([]any) {
		m := s.(map[string]any)
		if m["name"] == name {
			return m
		}
	}
	return nil
}

func num(m map[string]any, k string) float64 {
	v, _ := m[k].(float64)
	return v
}

// workFolder is RHOBOUND_E2E_WORK, or a new folder under $HOME/.cache/rb-e2e-work. Not t.TempDir(): that is
// removed even when the test fails, and a failed run's captures are the only evidence of what happened (kind
// run 3's were lost that way). A pass removes the bulky parts of a folder the test made and keeps result.json.
func workFolder(t *testing.T) string {
	if d := os.Getenv("RHOBOUND_E2E_WORK"); d != "" {
		if err := os.MkdirAll(d, 0o755); err != nil {
			t.Fatal(err)
		}
		t.Logf("work folder %s (RHOBOUND_E2E_WORK, always kept)", d)
		return d
	}
	home, err := os.UserHomeDir()
	if err != nil {
		t.Fatal(err)
	}
	parent := filepath.Join(home, ".cache", "rb-e2e-work")
	if err := os.MkdirAll(parent, 0o755); err != nil {
		t.Fatal(err)
	}
	d, err := os.MkdirTemp(parent, time.Now().Format("20060102-150405")+"-")
	if err != nil {
		t.Fatal(err)
	}
	t.Logf("work folder %s", d)
	t.Cleanup(func() {
		if t.Failed() || t.Skipped() {
			t.Logf("kept the work folder %s (captures, load generator outputs, result.json)", d)
			return
		}
		os.RemoveAll(filepath.Join(d, "img"))
		caps, _ := filepath.Glob(filepath.Join(d, "capture-*"))
		for _, c := range caps {
			os.RemoveAll(c)
		}
		t.Logf("passed: removed the captures and the image from %s; result.json and the load generator outputs are kept", d)
	})
	return d
}

func TestClusterEndToEnd(t *testing.T) {
	if os.Getenv("RHOBOUND_E2E") != "1" {
		t.Skip("set RHOBOUND_E2E=1 (needs docker, kind and kubectl)")
	}
	root, _ := filepath.Abs("..")
	work := workFolder(t)
	os.MkdirAll(filepath.Join(work, "img"), 0o755)
	e := &env{t: t, root: root, work: work, kube: filepath.Join(work, "kubeconfig"),
		runID: time.Now().Format("20060102-150405"), keepAlive: os.Getenv("RHOBOUND_E2E_KEEPALIVE") == "1"}

	// the CLI under test
	build := exec.Command("go", "build", "-o", filepath.Join(root, "bin", "rhobound"), "./cmd/rhobound")
	build.Dir = root
	if out, err := build.CombinedOutput(); err != nil {
		t.Fatalf("build: %v\n%s", err, out)
	}
	ctxBefore, _ := exec.Command("kubectl", "config", "current-context").CombinedOutput()

	if _, err := e.try("kind", "get", "kubeconfig", "--name", cluster); err != nil {
		kc := filepath.Join(work, "kind.yaml")
		os.WriteFile(kc, []byte(kindConfig), 0o644)
		if _, err := e.try("kind", "create", "cluster", "--name", cluster, "--kubeconfig", e.kube, "--config", kc, "--wait", "180s"); err != nil {
			// the config only raises the log size limit; without it the check below warns about the default
			t.Logf("kind create with %s failed (%v); creating the cluster without it", kc, err)
			e.try("kind", "delete", "cluster", "--name", cluster)
			e.run("kind", "create", "cluster", "--name", cluster, "--kubeconfig", e.kube, "--wait", "180s")
		}
	} else {
		out, _ := e.try("kind", "get", "kubeconfig", "--name", cluster)
		os.WriteFile(e.kube, []byte(out), 0o600)
		t.Logf("reusing the kind cluster %s", cluster)
	}
	if os.Getenv("RHOBOUND_E2E_KEEP") != "1" {
		t.Cleanup(func() { e.try("kind", "delete", "cluster", "--name", cluster) })
	}
	t.Cleanup(func() {
		ctxAfter, _ := exec.Command("kubectl", "config", "current-context").CombinedOutput()
		if string(ctxBefore) != string(ctxAfter) {
			t.Errorf("the default kubectl context changed: %q -> %q", ctxBefore, ctxAfter)
		}
	})
	e.node = e.nodeName()
	e.try("docker", "update", "--memory", "3g", "--memory-swap", "3g", e.node)
	var limit string
	e.logMax, limit = e.kubeletLogMax()
	perWindow := int64(rps * (runSecs + skipSecs) * lineBytes)
	t.Logf("kubelet containerLogMaxSize %s; the frontend writes about %.1f MiB per window", limit, float64(perWindow)/(1<<20))
	if e.logMax > 0 && e.logMax < 2*perWindow {
		t.Logf("warning: the kubelet rotates logs at %s, less than twice a window's frontend log: spans may be lost (recreate the cluster to get %q)",
			limit, "containerLogMaxSize: 100Mi")
	}

	e.build()
	keepAlive := "false"
	if e.keepAlive {
		keepAlive = "true"
		t.Logf("RHOBOUND_E2E_KEEPALIVE=1: frontend and api reuse connections, so the api split is per connection; expect the share gate to mark the run UNSTABLE")
	}
	var m bytes.Buffer
	if err := manifest.Execute(&m, map[string]any{"Services": services, "KeepAlive": keepAlive}); err != nil {
		t.Fatal(err)
	}
	mp := filepath.Join(work, "app.yaml")
	os.WriteFile(mp, m.Bytes(), 0o644)
	e.run("kubectl", "apply", "-f", mp)
	for _, s := range services {
		e.kubectl("rollout", "status", "deploy/"+s.Name, "--timeout=180s")
	}
	e.loadgen("warmup", 15)

	rounds := 2
	if v := os.Getenv("RHOBOUND_E2E_ROUNDS"); v != "" {
		fmt.Sscan(v, &rounds)
	}
	rounds = max(rounds, 1)
	var before, after []phaseResult
	var reps []map[string]any
	for r := 1; r <= rounds; r++ {
		b := e.phase(fmt.Sprintf("before%d", r), 0)
		rep := e.predict(b.Capture, "--patch", fmt.Sprintf("api=+%gms", extraMs))
		fe, api := row(rep, "frontend"), row(rep, "api")
		b.ModelMs, b.ModelChangeMs = num(fe, "model_ms"), num(fe, "change_ms")
		t.Logf("before%d model: entry %.2f ms, change %+.2f ms; api wait: model %.2f ms, traces %.2f ms",
			r, b.ModelMs, b.ModelChangeMs, num(api, "model_wait_ms"), num(api, "observed_wait_ms"))
		reps = append(reps, rep)
		before = append(before, b)
		after = append(after, e.phase(fmt.Sprintf("after%d", r), extraMs))
	}
	mean := func(ps []phaseResult) float64 {
		m := 0.0
		for _, p := range ps {
			m += p.MeasuredMs
		}
		return m / float64(len(ps))
	}
	obsBefore, obsAfter := mean(before), mean(after)

	// structure, from the first window
	rep := reps[0]
	fe, api, db, cache := row(rep, "frontend"), row(rep, "api"), row(rep, "db"), row(rep, "cache")
	if fe == nil || api == nil || db == nil || cache == nil {
		t.Fatalf("services missing from the report: %v", rep["services"])
	}
	if fe["entry"] != true || fe["parallel"] != true {
		t.Errorf("frontend should be the entry and a parallel fan-out: %v", fe)
	}
	if num(api, "replicas") != 2 {
		t.Errorf("api has 2 replicas, the report says %v", api["replicas"])
	}
	for name, want := range map[string]float64{"db": 8, "cache": 5, "api": 20, "frontend": 3} {
		if got := num(row(rep, name), "own_ms"); math.Abs(got-want) > 0.15*want+0.4 {
			t.Errorf("%s: service time %.2f ms, the true value is %v", name, got, want)
		}
	}
	repAfter := e.predict(after[0].Capture)
	if got := num(row(repAfter, "api"), "own_ms"); math.Abs(got-(20+extraMs)) > 0.15*(20+extraMs)+0.4 {
		t.Errorf("after the change the traces show api at %.2f ms, expected about %v", got, 20+extraMs)
	}

	// the model, averaged over the before windows' captures
	modelBefore, predicted := 0.0, 0.0
	for _, b := range before {
		modelBefore += b.ModelMs / float64(len(before))
		predicted += b.ModelChangeMs / float64(len(before))
	}
	observed := obsAfter - obsBefore
	t.Logf("before: measured %.2f ms (%d windows), model %.2f ms; change in api of +%g ms: predicted %+.2f ms, measured %+.2f ms",
		obsBefore, len(before), modelBefore, extraMs, predicted, observed)

	// is the measurement steady enough to judge the model by?
	var unstable []string
	for _, p := range append(append([]phaseResult{}, before...), after...) {
		for _, u := range p.Unstable {
			unstable = append(unstable, p.Name+": "+u)
		}
	}
	for _, set := range [][]phaseResult{before, after} {
		lo, hi := set[0].MeasuredMs, set[0].MeasuredMs
		for _, p := range set {
			lo, hi = math.Min(lo, p.MeasuredMs), math.Max(hi, p.MeasuredMs)
		}
		if m := mean(set); hi-lo > repeatTol*m {
			kind := strings.TrimRight(set[0].Name, "0123456789")
			unstable = append(unstable, fmt.Sprintf("the %s windows read %.2f to %.2f ms, more than %.0f%% of their mean apart",
				kind, lo, hi, 100*repeatTol))
		}
	}
	var wrong []string
	if math.Abs(modelBefore-obsBefore) > levelTol*obsBefore {
		wrong = append(wrong, fmt.Sprintf("entry latency: model %.2f ms, measured %.2f ms (more than %.0f%% apart)",
			modelBefore, obsBefore, 100*levelTol))
	}
	if math.Abs(predicted-observed) > changeRel*math.Abs(observed)+changeAbs {
		wrong = append(wrong, fmt.Sprintf("predicted change %+.2f ms, measured %+.2f ms", predicted, observed))
	}
	res := map[string]any{"before_measured_ms": obsBefore, "after_measured_ms": obsAfter, "predicted_change_ms": predicted,
		"observed_change_ms": observed, "model_before_ms": modelBefore, "rounds": rounds, "keepalive": e.keepAlive,
		"kubelet_log_max": limit, "windows": append(before, after...), "unstable": unstable, "model_wrong": wrong,
		"gates": map[string]float64{"max_share": maxShare, "repeat_tol": repeatTol, "max_worst_10s": maxWorst,
			"max_lag_ms": maxLagMs, "min_kept": minKept, "max_gap_ms": maxGapMs, "max_mem_stall": maxMemStall,
			"level_tol": levelTol, "change_rel": changeRel, "change_abs_ms": changeAbs}}
	b, _ := json.MarshalIndent(res, "", "  ")
	os.WriteFile(filepath.Join(work, "result.json"), b, 0o644)
	if len(unstable) > 0 {
		for _, u := range unstable {
			t.Logf("UNSTABLE: %s", u)
		}
		for _, w := range wrong {
			t.Logf("(not judged) %s", w)
		}
		if len(wrong) == 0 {
			t.Logf("(not judged) the model's numbers were within the gates")
		}
		msg := fmt.Sprintf("UNSTABLE measurement: %d reasons above, not judging the model; see %s",
			len(unstable), filepath.Join(work, "result.json"))
		if os.Getenv("RHOBOUND_E2E_STRICT") == "1" {
			t.Fatal(msg + " (RHOBOUND_E2E_STRICT=1)")
		}
		t.Skip(msg + " (RHOBOUND_E2E_STRICT=1 fails instead)")
	}
	for _, w := range wrong {
		t.Error(w)
	}
}
