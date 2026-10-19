// SPDX-License-Identifier: Apache-2.0

package main

import (
	"bytes"
	"encoding/json"
	"errors"
	"fmt"
	"math"
	"math/rand"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

const fixture = "../../testdata/capture-chain"

func exec(t *testing.T, args ...string) (string, string, int) {
	t.Helper()
	var out, errw bytes.Buffer
	code := run(args, &out, &errw)
	return out.String(), errw.String(), code
}

func TestPredictText(t *testing.T) {
	out, errw, code := exec(t, "predict", fixture, "--patch", "b=+6ms")
	if code != 0 {
		t.Fatalf("exit %d: %s", code, errw)
	}
	for _, want := range []string{"rhobound-cli: mean latency from traces", "a *", "b", "c", "change applied: b +6 ms", "scope"} {
		if !strings.Contains(out, want) {
			t.Errorf("report lacks %q:\n%s", want, out)
		}
	}
}

func TestPredictJSONAndFlagsAfterTheArgument(t *testing.T) {
	out, errw, code := exec(t, "predict", fixture, "--json", "--patch", "b=+6ms")
	if code != 0 {
		t.Fatalf("exit %d: %s", code, errw)
	}
	var rep struct {
		Version  string `json:"version"`
		Requests int64  `json:"requests"`
		Services []struct {
			Name     string   `json:"name"`
			Entry    bool     `json:"entry"`
			ModelMs  float64  `json:"model_ms"`
			ChangeMs *float64 `json:"change_ms"`
			Util     float64  `json:"utilization"`
		} `json:"services"`
	}
	if err := json.Unmarshal([]byte(out), &rep); err != nil {
		t.Fatalf("not JSON: %v\n%s", err, out)
	}
	if rep.Version != "rhobound-cli.report/v1" || rep.Requests < 2000 || len(rep.Services) != 3 {
		t.Fatalf("report: %+v", rep)
	}
	for _, s := range rep.Services {
		if s.ChangeMs == nil || s.ModelMs <= 0 || s.Util <= 0 || s.Util >= 1 {
			t.Errorf("service %+v", s)
		}
		if s.Name == "a" && (!s.Entry || *s.ChangeMs < 6) {
			t.Errorf("the entry should move by at least the 6 ms: %+v", s)
		}
		// c is downstream of the change: only through b's changed departure variability, a fraction of a ms
		if s.Name == "c" && math.Abs(*s.ChangeMs) > 0.3 {
			t.Errorf("c should hardly move: %+v", s)
		}
	}
}

func TestOutDirWritesBothFiles(t *testing.T) {
	dir := filepath.Join(t.TempDir(), "r")
	if _, errw, code := exec(t, "predict", fixture, "--out", dir); code != 0 {
		t.Fatalf("%s", errw)
	}
	for _, f := range []string{"report.txt", "report.json"} {
		if st, err := os.Stat(filepath.Join(dir, f)); err != nil || st.Size() == 0 {
			t.Errorf("%s: %v", f, err)
		}
	}
}

func TestRefusesHighLoadAndBadPatch(t *testing.T) {
	_, errw, code := exec(t, "predict", fixture, "--max-rho", "0.2")
	if code != 1 || !strings.Contains(errw, "refusing to predict") {
		t.Errorf("exit %d, %q: should refuse above the utilization limit", code, errw)
	}
	_, errw, code = exec(t, "predict", fixture, "--patch", "b=+500ms")
	if code != 1 || !strings.Contains(errw, "unstable") && !strings.Contains(errw, "utilization") {
		t.Errorf("a change that saturates b should be refused: exit %d %q", code, errw)
	}
	for _, p := range []string{"nosuch=+1ms", "b=banana", "b"} {
		if _, errw, code := exec(t, "predict", fixture, "--patch", p); code != 1 || !strings.Contains(errw, "--patch") {
			t.Errorf("patch %q: exit %d %q", p, code, errw)
		}
	}
	if _, _, code := exec(t, "predict", fixture, "--max-rho", "2"); code != 1 {
		t.Error("--max-rho above 0.95 should be refused")
	}
}

func TestInferThenModelRoundTrip(t *testing.T) {
	topo, _, code := exec(t, "infer", fixture)
	if code != 0 {
		t.Fatal("infer failed")
	}
	path := filepath.Join(t.TempDir(), "topo.json")
	if err := os.WriteFile(path, []byte(topo), 0o644); err != nil {
		t.Fatal(err)
	}
	out, errw, code := exec(t, "model", path, "--rps", "25", "--patch", "c=+20%")
	if code != 0 {
		t.Fatalf("model: %s", errw)
	}
	if !strings.Contains(out, "c") || !strings.Contains(out, "change applied") {
		t.Errorf("model output:\n%s", out)
	}
	if _, _, code := exec(t, "model", path, "--rps", "100000"); code != 1 {
		t.Error("an unstable load should fail")
	}
}

// `rhobound model` accepted --max-rho and --out and ignored both: a topology at 90% was evaluated at the default
// limit of 85%, and --out DIR wrote nothing. Its report showed 0.00 as what the traces saw, with no traces.
func TestModelLimitOutAndFlags(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, "topo.json")
	doc := `{"name":"m","entry":{"a":1},"services":[{"name":"a","s":5,"children":["b"]},{"name":"b","s":10}]}`
	if err := os.WriteFile(path, []byte(doc), 0o644); err != nil {
		t.Fatal(err)
	}
	if _, errw, code := exec(t, "model", path, "--rps", "90"); code != 1 || !strings.Contains(errw, "refusing to evaluate") ||
		!strings.Contains(errw, "b would run at 90.0% utilization") || !strings.Contains(errw, "--max-rho") {
		t.Errorf("90%% at the default limit: exit %d, %q", code, errw)
	}
	out, errw, code := exec(t, "model", path, "--rps", "90", "--max-rho", "0.95")
	if code != 0 || !strings.Contains(out, "busiest   b at 90% utilization") {
		t.Errorf("90%% under --max-rho 0.95: exit %d, %s\n%s", code, errw, out)
	}
	if _, errw, code := exec(t, "model", path, "--rps", "80", "--patch", "b=+1ms"); code != 1 ||
		!strings.Contains(errw, "refusing the change") || !strings.Contains(errw, "b would run at 88.0% utilization") {
		t.Errorf("a change to 88%%: exit %d, %q", code, errw)
	}
	if _, errw, code := exec(t, "model", path, "--rps", "20", "--max-rho", "2"); code != 1 || !strings.Contains(errw, "--max-rho") {
		t.Errorf("--max-rho 2: exit %d, %q", code, errw)
	}
	for _, f := range [][]string{{"--workers", "b=2"}, {"--kept-share", "0.5"}} {
		if _, errw, code := exec(t, append([]string{"model", path, "--rps", "20"}, f...)...); code != 1 || !strings.Contains(errw, f[0]) {
			t.Errorf("%s: exit %d, %q", f[0], code, errw)
		}
	}
	outDir := filepath.Join(dir, "r")
	out, errw, code = exec(t, "model", path, "--rps", "20", "--out", outDir)
	if code != 0 || !strings.Contains(errw, "wrote") {
		t.Fatalf("--out: exit %d, %q", code, errw)
	}
	for _, f := range []string{"report.txt", "report.json"} {
		if st, err := os.Stat(filepath.Join(outDir, f)); err != nil || st.Size() == 0 {
			t.Errorf("%s: %v", f, err)
		}
	}
	for _, want := range []string{"mean latency of a topology", "topology  " + path, "load      20.0 requests/s"} {
		if !strings.Contains(out, want) {
			t.Errorf("model report lacks %q:\n%s", want, out)
		}
	}
	if strings.Contains(out, "window") || strings.Contains(out, "0 spans") {
		t.Errorf("a topology has no capture window:\n%s", out)
	}
	for _, l := range strings.Split(out, "\n") { // service rps pods x w own cs2 util wait seen-wait model seen err
		if f := strings.Fields(l); len(f) > 0 && (f[0] == "a" || f[0] == "b") {
			if f[0] == "a" {
				f = append(f[:1], f[2:]...) // the entry mark
			}
			if len(f) < 13 || f[9] != "-" || f[11] != "-" {
				t.Errorf("seen columns should be '-' in a topology's report: %q", l)
			}
		}
	}
}

func TestVersionHelpAndUnknown(t *testing.T) {
	if out, _, code := exec(t, "version"); code != 0 || !strings.HasPrefix(out, "rhobound ") {
		t.Errorf("version: %d %q", code, out)
	}
	if out, _, code := exec(t, "help"); code != 0 || !strings.Contains(out, "predict") {
		t.Errorf("help: %d", code)
	}
	if _, _, code := exec(t, "frobnicate"); code != 2 {
		t.Error("an unknown command should exit 2")
	}
	if _, _, code := exec(t); code != 2 {
		t.Error("no command should exit 2")
	}
	if _, errw, code := exec(t, "predict", "/no/such/capture"); code != 1 || errw == "" {
		t.Error("a missing capture should fail with a message")
	}
}

func TestPlainSwitch(t *testing.T) {
	refined, _, _ := exec(t, "predict", fixture, "--json")
	plain, _, code := exec(t, "predict", fixture, "--json", "--plain")
	if code != 0 {
		t.Fatal("--plain failed")
	}
	var a, b struct {
		Model string `json:"model"`
	}
	json.Unmarshal([]byte(refined), &a)
	json.Unmarshal([]byte(plain), &b)
	if !strings.HasPrefix(a.Model, "refined") || !strings.HasPrefix(b.Model, "basic") || refined == plain {
		t.Errorf("models: %q vs %q", a.Model, b.Model)
	}
}

// Glue (time after the calls that holds no worker) gets its own column, shown only when some service has it.
func TestGlueColumn(t *testing.T) {
	if out, _, _ := exec(t, "predict", fixture); strings.Contains(out, "glue") {
		t.Errorf("the fixture has no glue, so no glue column:\n%s", out)
	}
	path := filepath.Join(t.TempDir(), "topo.json")
	doc := `{"name":"g","entry":{"a":1},"services":[{"name":"a","s":5,"children":["b"],"glue":3},{"name":"b","s":10}]}`
	if err := os.WriteFile(path, []byte(doc), 0o644); err != nil {
		t.Fatal(err)
	}
	out, errw, code := exec(t, "model", path, "--rps", "20")
	if code != 0 || !strings.Contains(out, "glue ms") || !strings.Contains(out, "3.00") {
		t.Errorf("model (%d, %s):\n%s", code, errw, out)
	}
	js, _, _ := exec(t, "model", path, "--rps", "20", "--json")
	var rep struct {
		Services []struct {
			Name    string  `json:"name"`
			GlueMs  float64 `json:"glue_ms"`
			ModelMs float64 `json:"model_ms"`
		} `json:"services"`
	}
	if err := json.Unmarshal([]byte(js), &rep); err != nil || len(rep.Services) != 2 {
		t.Fatalf("json: %v\n%s", err, js)
	}
	if a := rep.Services[0]; a.Name != "a" || a.GlueMs != 3 {
		t.Errorf("a: %+v", a)
	}
}

// Uneven replica shares are marked in the pods column, the legend says the change keeps them, the JSON
// rows carry them, and the utilization limit sees the busy replica.
func TestReplicaSharesInTheReport(t *testing.T) {
	if out, _, _ := exec(t, "predict", fixture); strings.Contains(out, "pods~") {
		t.Errorf("the fixture has one pod per service, so no shares:\n%s", out)
	}
	path := filepath.Join(t.TempDir(), "topo.json")
	doc := `{"name":"s","entry":{"a":1},"services":[{"name":"a","s":2,"children":["b"]},
	 {"name":"b","s":10,"routing":"random","shares":[0.7,0.3]}]}`
	if err := os.WriteFile(path, []byte(doc), 0o644); err != nil {
		t.Fatal(err)
	}
	out, errw, code := exec(t, "model", path, "--rps", "60", "--patch", "b=+1ms")
	if code != 0 || !strings.Contains(out, "2~ x 1") || !strings.Contains(out, "kept at any load and after the change") ||
		!strings.Contains(out, "42% utilization") {
		t.Errorf("model (%d, %s):\n%s", code, errw, out)
	}
	js, _, _ := exec(t, "model", path, "--rps", "60", "--json")
	var rep struct {
		Services []struct {
			Name   string    `json:"name"`
			Shares []float64 `json:"replica_shares"`
		} `json:"services"`
	}
	if err := json.Unmarshal([]byte(js), &rep); err != nil || len(rep.Services) != 2 {
		t.Fatalf("json: %v\n%s", err, js)
	}
	if b := rep.Services[1]; b.Name != "b" || len(b.Shares) != 2 || b.Shares[0] != 0.7 || rep.Services[0].Shares != nil {
		t.Errorf("rows: %+v", rep.Services)
	}
	if _, _, code := exec(t, "model", path, "--rps", "150"); code != 1 {
		t.Error("the busy replica past saturation (105%, the service at 75%) should fail")
	}
}

// tspan is one span of a capture written by writeCapture: times in ms, ids as hex.
type tspan struct {
	svc, pod, id, parent string
	kind                 int
	start, end           float64
	trace                int
	peer                 string
}

// writeCapture writes spans as a capture folder (traces/spans.jsonl, one request per service and pod).
func writeCapture(t *testing.T, spans []tspan) string {
	t.Helper()
	dir := t.TempDir()
	if err := os.MkdirAll(filepath.Join(dir, "traces"), 0o755); err != nil {
		t.Fatal(err)
	}
	by := map[[2]string][]tspan{}
	var keys [][2]string
	for _, sp := range spans {
		k := [2]string{sp.svc, sp.pod}
		if by[k] == nil {
			keys = append(keys, k)
		}
		by[k] = append(by[k], sp)
	}
	var b strings.Builder
	for _, k := range keys {
		fmt.Fprintf(&b, `{"resourceSpans":[{"resource":{"attributes":[{"key":"service.name","value":{"stringValue":%q}},`+
			`{"key":"k8s.pod.name","value":{"stringValue":%q}}]},"scopeSpans":[{"spans":[`, k[0], k[1])
		for i, sp := range by[k] {
			if i > 0 {
				b.WriteByte(',')
			}
			ns := func(ms float64) int64 { return 1_700_000_000_000_000_000 + int64(ms*1e6) }
			fmt.Fprintf(&b, `{"traceId":"%032x","spanId":%q,"parentSpanId":%q,"kind":%d,"startTimeUnixNano":"%d","endTimeUnixNano":"%d"`,
				sp.trace, sp.id, sp.parent, sp.kind, ns(sp.start), ns(sp.end))
			if sp.peer != "" {
				fmt.Fprintf(&b, `,"attributes":[{"key":"server.address","value":{"stringValue":%q}}]`, sp.peer)
			}
			b.WriteByte('}')
		}
		b.WriteString("]}]}]}\n")
	}
	if err := os.WriteFile(filepath.Join(dir, "traces", "spans.jsonl"), []byte(b.String()), 0o644); err != nil {
		t.Fatal(err)
	}
	return dir
}

type reportChange struct {
	Services []struct {
		Name     string   `json:"name"`
		Workers  int      `json:"workers_per_pod"`
		ChangeMs *float64 `json:"change_ms"`
	} `json:"services"`
	Changes []struct {
		Service string  `json:"service"`
		DeltaMs float64 `json:"delta_ms"`
		GlueMs  float64 `json:"glue_delta_ms"`
	} `json:"changes"`
	Warnings []string `json:"warnings"`
}

// The code review's cap-skew0_1: fe calls be through a SERVER -> SERVER link after about 1 ms of work and works 1 ms after
// the call returns (glue). --patch fe=+100% doubles fe's whole own time, about +2 ms per visit; at 29a7ed9 it
// scaled the service time only and predicted +1.01 ms (094b99a: +2.01).
func TestPatchPercentScalesTheGlue(t *testing.T) {
	rng := rand.New(rand.NewSource(4))
	var spans []tspan
	at := 0.0
	for i := 1; i <= 3000; i++ {
		at += rng.ExpFloat64() * 1000 / 40
		pre, be := rng.ExpFloat64(), 4*rng.ExpFloat64()
		root := fmt.Sprintf("%016x", 2*i)
		spans = append(spans, tspan{"fe", "fe-0", root, "", 2, at, at + pre + be + 1, i, ""},
			tspan{"be", "be-0", fmt.Sprintf("%016x", 2*i+1), root, 2, at + pre, at + pre + be, i, ""})
	}
	capture := writeCapture(t, spans)
	out, errw, code := exec(t, "predict", capture, "--json", "--patch", "fe=+100%")
	if code != 0 {
		t.Fatalf("exit %d: %s", code, errw)
	}
	var rep reportChange
	if err := json.Unmarshal([]byte(out), &rep); err != nil {
		t.Fatal(err)
	}
	ch := rep.Changes[0]
	if math.Abs(ch.DeltaMs-2) > 0.15 || math.Abs(ch.GlueMs-1) > 0.05 {
		t.Errorf("fe +100%%: the change is %+.3f ms of which %+.3f ms glue; want about +2 and +1", ch.DeltaMs, ch.GlueMs)
	}
	for _, s := range rep.Services {
		if s.Name == "fe" && (s.ChangeMs == nil || *s.ChangeMs < ch.DeltaMs) {
			t.Errorf("fe's latency changes by %v ms, less than its own time (%+.3f ms)", s.ChangeMs, ch.DeltaMs)
		}
	}
	text, _, _ := exec(t, "predict", capture, "--patch", "fe=+100%")
	if !strings.Contains(text, "ms glue);") {
		t.Errorf("the change line does not show the glue part:\n%s", text)
	}
	// +N ms is extra work holding the worker: no glue part
	out, _, _ = exec(t, "predict", capture, "--json", "--patch", "fe=+1ms")
	rep = reportChange{}
	json.Unmarshal([]byte(out), &rep)
	if ch := rep.Changes[0]; ch.DeltaMs != 1 || ch.GlueMs != 0 {
		t.Errorf("fe +1ms: %+v", ch)
	}
	// -150% would make the glue negative where the service time is 0
	path := filepath.Join(t.TempDir(), "topo.json")
	if err := os.WriteFile(path, []byte(`{"entry":{"a":1},"services":[{"name":"a","s":0,"glue":2}]}`), 0o644); err != nil {
		t.Fatal(err)
	}
	if _, errw, code := exec(t, "model", path, "--rps", "10", "--patch", "a=-150%"); code != 1 || !strings.Contains(errw, "negative glue") {
		t.Errorf("a=-150%%: exit %d, %q", code, errw)
	}
}

// The code review's cap-rare: fe (400 visits) calls rare once. --workers rare=4 was ignored at 29a7ed9, silently: rare's
// queue has too few jobs to rebuild, and the count stayed 1 (shown as if the user had set it).
func TestWorkersForAServiceTooRareToRebuild(t *testing.T) {
	rng := rand.New(rand.NewSource(2))
	var spans []tspan
	at := 0.0
	for i := 1; i <= 400; i++ {
		at += rng.ExpFloat64() * 1000 / 20
		root := fmt.Sprintf("%016x", 3*i)
		if i == 7 {
			cl := fmt.Sprintf("%016x", 3*i+1)
			spans = append(spans, tspan{"fe", "fe-0", root, "", 2, at, at + 12, i, ""},
				tspan{"fe", "fe-0", cl, root, 3, at + 2, at + 9, i, "rare"},
				tspan{"rare", "rare-0", fmt.Sprintf("%016x", 3*i+2), cl, 2, at + 3, at + 8, i, ""})
			continue
		}
		spans = append(spans, tspan{"fe", "fe-0", root, "", 2, at, at + 3 + 5*rng.ExpFloat64(), i, ""})
	}
	out, errw, code := exec(t, "predict", writeCapture(t, spans), "--json", "--workers", "rare=4")
	if code != 0 {
		t.Fatalf("exit %d: %s", code, errw)
	}
	var rep reportChange
	if err := json.Unmarshal([]byte(out), &rep); err != nil {
		t.Fatal(err)
	}
	for _, s := range rep.Services {
		if s.Name == "rare" && s.Workers != 4 {
			t.Errorf("rare: %d workers per pod, want the 4 given", s.Workers)
		}
	}
	warned := false
	for _, w := range rep.Warnings {
		warned = warned || (strings.HasPrefix(w, "rare:") && strings.Contains(w, "--workers 4"))
	}
	if !warned {
		t.Errorf("no warning that --workers is taken as given for rare: %q", rep.Warnings)
	}
}

type failWriter struct{}

func (failWriter) Write([]byte) (int, error) { return 0, errors.New("no space left on device") }

// `predict CAPTURE > /dev/full` exited 0 with nothing written: the text report ignored its write errors.
func TestTextReportWriteErrors(t *testing.T) {
	var errw bytes.Buffer
	if code := run([]string{"predict", fixture}, failWriter{}, &errw); code != 1 || !strings.Contains(errw.String(), "no space left") {
		t.Errorf("predict: exit %d, %q", code, errw.String())
	}
	topo, _, _ := exec(t, "infer", fixture)
	path := filepath.Join(t.TempDir(), "topo.json")
	if err := os.WriteFile(path, []byte(topo), 0o644); err != nil {
		t.Fatal(err)
	}
	errw.Reset()
	if code := run([]string{"model", path, "--rps", "25"}, failWriter{}, &errw); code != 1 || !strings.Contains(errw.String(), "no space left") {
		t.Errorf("model: exit %d, %q", code, errw.String())
	}
	if f, err := os.OpenFile("/dev/full", os.O_WRONLY, 0); err == nil {
		defer f.Close()
		errw.Reset()
		if code := run([]string{"predict", fixture}, f, &errw); code != 1 {
			t.Errorf("predict > /dev/full: exit %d, %q", code, errw.String())
		}
	}
}
