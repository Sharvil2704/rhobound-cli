// SPDX-License-Identifier: Apache-2.0

package check_test

import (
	"bytes"
	"encoding/json"
	"os"
	"path/filepath"
	"sort"
	"strings"
	"testing"
	"time"

	"github.com/Sharvil2704/rhobound-cli/internal/check"
	"github.com/Sharvil2704/rhobound-cli/internal/contract"
	"github.com/Sharvil2704/rhobound-cli/internal/otlp"
	"github.com/Sharvil2704/rhobound-cli/internal/testgen"
)

func fixture(t *testing.T, code string) *testgen.Fixture {
	t.Helper()
	for _, f := range testgen.Fixtures() {
		if f.Code == code {
			return &f
		}
	}
	t.Fatalf("no fixture for %s", code)
	return nil
}

func build(t *testing.T, code string) *testgen.Case {
	t.Helper()
	cs, err := fixture(t, code).Build(base(t), t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	return cs
}

func runDir(t *testing.T, dir string, opt check.Options) (*contract.CheckReport, *otlp.Data, *contract.Manifest) {
	t.Helper()
	m, _, err := check.ManifestFromDir(dir, opt.Limits)
	if err != nil {
		t.Fatal(err)
	}
	rep, d, err := check.Run(m, opt)
	if err != nil {
		t.Fatal(err)
	}
	return rep, d, m
}

// pods returns the distinct pods of a service in the data check hands to a fit.
func pods(d *otlp.Data, svc string) []string {
	set := map[string]bool{}
	for _, r := range d.Resources {
		if r.Service == svc {
			set[r.Pod] = true
		}
	}
	var out []string
	for p := range set {
		out = append(out, p)
	}
	sort.Strings(out)
	return out
}

// Pod identity (DATA.md 3.4): worker processes of one host with no pod or task identity. Traces cannot tell pre-fork
// workers sharing a socket from independent replicas on one machine, so the reading is the declaration's: by default
// (independent replicas) each process is a pod and the doubt says so; with --pod-identity host (pre-fork workers) the
// host is the pod and the doubt is resolved.
func TestPodIdentityReadings(t *testing.T) {
	cs := build(t, contract.TraceInstancePerProcess)
	rep, d, _ := runDir(t, cs.Dir, check.Options{})
	if got := pods(d, "a"); !rep.Has(contract.TraceInstancePerProcess) || len(got) != 4 {
		t.Errorf("independent replicas: pods %v, findings %s", got, codesOf(rep))
	}
	rep, d, _ = runDir(t, cs.Dir, check.Options{PodIdentity: check.PodIdentityHost})
	if got := pods(d, "a"); rep.Has(contract.TraceInstancePerProcess) || len(got) != 1 || got[0] != "vm-1" {
		t.Errorf("pre-fork workers: pods %v, findings %s", got, codesOf(rep))
	}
	// a platform identity wins over the declaration
	rep, d, _ = runDir(t, filepath.Join(must(testgen.RepoRoot()), "testdata", "capture-chain"), check.Options{PodIdentity: check.PodIdentityHost})
	if got := pods(d, "b"); len(got) != 1 || got[0] != "b-0" {
		t.Errorf("pods with names: %v", got)
	}
	m, _, err := check.ManifestFromDir(cs.Dir, otlp.Limits{})
	if err != nil {
		t.Fatal(err)
	}
	if _, _, err := check.Run(m, check.Options{PodIdentity: "process"}); err == nil {
		t.Error("an unknown --pod-identity is accepted")
	}
}

func must(s string, err error) string {
	if err != nil {
		panic(err)
	}
	return s
}

// Identical copies are dropped from what a fit reads, the order of the other spans kept; the span ids that collide
// with different content refuse.
func TestDuplicates(t *testing.T) {
	cs := build(t, contract.TraceDuplicateSpansDropped)
	rep, d, _ := runDir(t, cs.Dir, check.Options{})
	want, err := otlp.ReadDir(filepath.Join(must(testgen.RepoRoot()), "testdata", "capture-chain"))
	if err != nil {
		t.Fatal(err)
	}
	if rep.Verdict == contract.Refused || len(d.Spans) != len(want.Spans) || len(d.DroppedDuplicates) == 0 {
		t.Fatalf("%s: %d spans, want %d", codesOf(rep), len(d.Spans), len(want.Spans))
	}
	for i := range d.Spans {
		if d.Spans[i] != want.Spans[i] {
			t.Fatalf("span %d moved", i)
		}
	}
	cs = build(t, contract.TraceSpanIDCollision)
	if rep, _, _ := runDir(t, cs.Dir, check.Options{}); rep.Verdict != contract.Refused || rep.Has(contract.TraceDuplicateSpansDropped) {
		t.Errorf("collisions: %s", codesOf(rep))
	}
}

// The manifest's objects against the folder: a file that is missing, one of another size, and one the manifest does
// not list.
func TestManifestAgainstFolder(t *testing.T) {
	cs := build(t, contract.TraceSamplingUnverified)
	mp, err := testgen.Manifest(cs.Dir, base(t), nil)
	if err != nil {
		t.Fatal(err)
	}
	m, err := check.ReadManifest(mp)
	if err != nil {
		t.Fatal(err)
	}
	if rep, _, err := check.Run(m, check.Options{}); err != nil || rep.Verdict == contract.Refused {
		t.Fatalf("%v %s", err, codesOf(rep))
	}
	extra := filepath.Join(cs.Dir, "traces", "late.jsonl")
	if err := os.WriteFile(extra, []byte{}, 0o644); err != nil {
		t.Fatal(err)
	}
	if rep, _, _ := check.Run(must2(check.ReadManifest(mp)), check.Options{}); !strings.Contains(codesOf(rep), "store.manifest_mismatch(late.jsonl)") {
		t.Errorf("an unlisted file: %s", codesOf(rep))
	}
	os.Remove(extra)
	m = must2(check.ReadManifest(mp))
	m.Objects[0].Size++
	if rep, _, _ := check.Run(m, check.Options{}); !rep.Has(contract.StoreManifestMismatch) {
		t.Errorf("a size that differs: %s", codesOf(rep))
	}
	m = must2(check.ReadManifest(mp))
	m.Objects = append(m.Objects, contract.Object{Name: "traces/gone.jsonl.gz", Size: 1, SHA256: strings.Repeat("0", 64)})
	if rep, _, _ := check.Run(m, check.Options{}); !rep.Has(contract.StoreManifestMismatch) {
		t.Errorf("a missing file: %s", codesOf(rep))
	}
	m = must2(check.ReadManifest(mp))
	m.Objects[0].Name = "../escape.jsonl"
	if _, _, err := check.Run(m, check.Options{}); err == nil {
		t.Error("an object outside the manifest's folder is read")
	}
}

func must2(m *contract.Manifest, err error) *contract.Manifest {
	if err != nil {
		panic(err)
	}
	return m
}

// A window that holds part of the capture: the traces whose entry starts in it, whole, and the others counted.
func TestCutWindow(t *testing.T) {
	root := must(testgen.RepoRoot())
	rep, d, m := runDir(t, filepath.Join(root, "testdata", "capture-chain"), check.Options{})
	if rep.Verdict == contract.Refused {
		t.Fatal(codesOf(rep))
	}
	start := m.Window.Start
	end := start.Add(60 * time.Second)
	out := filepath.Join(t.TempDir(), "cut")
	final, err := check.Cut(m, d, start, end, out)
	if err != nil {
		t.Fatal(err)
	}
	if final.Window.Cut != contract.CutEntrySpanStart || !final.Window.Start.Equal(start) || final.Dropped.TracesOutsideWindow == 0 ||
		final.KeepList != otlp.Keep().SHA256() || final.Validate() != nil {
		t.Fatalf("final manifest %+v", final)
	}
	got, err := otlp.ReadDir(out)
	if err != nil {
		t.Fatal(err)
	}
	traces := map[[2]uint64]int{}
	for _, s := range got.Spans {
		traces[s.Trace]++
	}
	for tr, n := range traces {
		if n != 5 {
			t.Fatalf("trace %x has %d of its 5 spans: a trace is cut whole", tr, n)
		}
	}
	if int64(len(traces))+final.Dropped.TracesOutsideWindow != 3099 {
		t.Errorf("%d traces kept and %d outside, of 3099", len(traces), final.Dropped.TracesOutsideWindow)
	}
	for _, s := range got.Spans {
		if s.Kind == otlp.KindServer && s.Parent == 0 && (s.Start < uint64(start.UnixNano()) || s.Start >= uint64(end.UnixNano())) {
			t.Fatalf("an entry outside the window: %d", s.Start)
		}
	}
	// the same cut, the same bytes
	again := filepath.Join(t.TempDir(), "cut")
	if f2, err := check.Cut(m, d, start, end, again); err != nil || f2.Digest() != final.Digest() {
		t.Errorf("a second cut: %v", err)
	}
	if _, err := check.Cut(m, d, start, end, out); err == nil {
		t.Error("a cut into a folder that is not empty")
	}
	if _, err := check.Cut(m, d, end, start, filepath.Join(t.TempDir(), "x")); err == nil {
		t.Error("an inverted window")
	}
}

// The canonical form keeps the keys the reader reads and nothing else, masks what looks like personal data, writes
// float times as integers, drops identical duplicates and the cut-short last line, and carries the other inputs along.
func TestCanonicalForm(t *testing.T) {
	c := base(t)
	c.Visit(func(rs *testgen.ResourceSpans, s *testgen.Span) {
		rs.SetAttr("team", testgen.Str("payments"))
		if rs.Service() == "a" && s.KindOf() == otlp.KindServer {
			s.SetAttr("db.statement", testgen.Str("select 1"))
			s.SetAttr("url.path", testgen.Str("/users/jane.doe@example.com"))
			s.SetAttr("http.route", testgen.Str("/users/{id}"))
			s.Events = []testgen.Event{{Name: "exception", Attributes: []testgen.KV{{Key: "exception.message", Value: testgen.Str("boom")}}},
				{Name: "rpc.message", Attributes: []testgen.KV{{Key: "rpc.message.type", Value: testgen.Str("SENT")},
					{Key: "rpc.message.id", Value: testgen.Int(1)}}}}
			s.Status = json.RawMessage(`{"code":1,"message":"user jane"}`)
			s.TraceState = "vendor=abc,ot=th:0"
		}
	})
	c.Requests = append(c.Requests, c.Clone().Requests[:2]...) // identical duplicates
	dir := t.TempDir()
	ls := c.Lines()
	ls = append(ls, ls[0][:100]) // the last line cut short
	if err := testgen.WriteFile(filepath.Join(dir, "traces", "spans.jsonl.gz"), bytes.Join(ls, nil)); err != nil {
		t.Fatal(err)
	}
	for _, f := range []string{"request-count.json", "peer-map.json", "cluster/start/a.json"} {
		if err := testgen.WriteFile(filepath.Join(dir, f), []byte(`{"copied":true}`)); err != nil {
			t.Fatal(err)
		}
	}
	m, _, err := check.ManifestFromDir(dir, otlp.Limits{})
	if err != nil {
		t.Fatal(err)
	}
	// the inputs above are not valid ones; read the traces alone for this test
	os.Remove(filepath.Join(dir, "request-count.json"))
	os.Remove(filepath.Join(dir, "peer-map.json"))
	os.RemoveAll(filepath.Join(dir, "cluster"))
	rep, d, err := check.Run(m, check.Options{})
	if err != nil || !rep.Has(contract.TraceDuplicateSpansDropped) || !rep.Has(contract.TracePartialTailDropped) ||
		!rep.Has(contract.TracePersonalDataSuspect) {
		t.Fatalf("%v %s", err, codesOf(rep))
	}
	for _, f := range []string{"request-count.json", "peer-map.json", "cluster/start/a.json"} {
		if err := testgen.WriteFile(filepath.Join(dir, f), []byte(`{"copied":true}`)); err != nil {
			t.Fatal(err)
		}
	}
	out := filepath.Join(t.TempDir(), "cut")
	final, err := check.Cut(m, d, m.Window.Start, m.Window.End.Add(time.Second), out)
	if err != nil {
		t.Fatal(err)
	}
	if final.Dropped.DuplicateSpans == 0 || final.Dropped.PartialTailLines != 1 || final.Dropped.TracesOutsideWindow != 0 {
		t.Errorf("dropped %+v", final.Dropped)
	}
	for _, f := range []string{"request-count.json", "peer-map.json", "cluster/start/a.json"} {
		if b, err := os.ReadFile(filepath.Join(out, f)); err != nil || string(b) != `{"copied":true}` {
			t.Errorf("%s not carried along: %v", f, err)
		}
	}
	lines, err := testgen.Lines(filepath.Join(out, "traces", "000000.jsonl.gz"))
	if err != nil {
		t.Fatal(err)
	}
	all := string(bytes.Join(lines, nil))
	for _, gone := range []string{"team", "db.statement", "jane.doe@example.com", "exception", "rpc.message.id", "vendor=abc", "user jane"} {
		if strings.Contains(all, gone) {
			t.Errorf("the canonical form keeps %q", gone)
		}
	}
	for _, kept := range []string{`"http.route"`, `"/users/{id}"`, `"url.path"`, `[masked]`, `"rpc.message"`, `"rpc.message.type"`,
		`"traceState":"ot=th:0"`, `"status":{"code":1}`, `"k8s.pod.name"`} {
		if !strings.Contains(all, kept) {
			t.Errorf("the canonical form lacks %s", kept)
		}
	}
	// read again, the canonical form has no duplicates, no partial line, and the same spans as the check's data
	got, err := otlp.ReadDir(out)
	if err != nil {
		t.Fatal(err)
	}
	if len(got.Spans) != len(d.Spans) {
		t.Fatalf("%d spans in the canonical form, %d checked", len(got.Spans), len(d.Spans))
	}
	for i := range got.Spans {
		a, b := got.Spans[i], d.Spans[i]
		a.Ext, b.Ext = 0, 0
		if a != b {
			t.Fatalf("span %d: %+v, checked %+v", i, a, b)
		}
	}
}

// Float times are written as the integers the reader read them as: the canonical form reads the same and needs no note.
func TestCanonicalTimes(t *testing.T) {
	cs := build(t, contract.TraceTimeNotInteger)
	rep, d, m := runDir(t, cs.Dir, check.Options{})
	if !rep.Has(contract.TraceTimeNotInteger) {
		t.Fatal(codesOf(rep))
	}
	out := filepath.Join(t.TempDir(), "cut")
	if _, err := check.Cut(m, d, m.Window.Start, m.Window.End.Add(time.Second), out); err != nil {
		t.Fatal(err)
	}
	rep2, d2, _ := runDir(t, out, check.Options{})
	if rep2.Has(contract.TraceTimeNotInteger) || len(d2.Spans) != len(d.Spans) {
		t.Fatalf("%s", codesOf(rep2))
	}
	for i := range d.Spans {
		if d.Spans[i].Start != d2.Spans[i].Start || d.Spans[i].End != d2.Spans[i].End {
			t.Fatalf("span %d: times %d-%d, canonical %d-%d", i, d.Spans[i].Start, d.Spans[i].End, d2.Spans[i].Start, d2.Spans[i].End)
		}
	}
}

// A capture given as one trace file is that file: the other trace files of its folder are not counted against it.
func TestSingleFileCapture(t *testing.T) {
	dir := t.TempDir()
	c := base(t)
	if err := testgen.WriteFile(filepath.Join(dir, "a.jsonl.gz"), bytes.Join(c.Lines(), nil)); err != nil {
		t.Fatal(err)
	}
	if err := testgen.WriteFile(filepath.Join(dir, "b.jsonl"), []byte("{}\n")); err != nil {
		t.Fatal(err)
	}
	rep, d, m := runDir(t, filepath.Join(dir, "a.jsonl.gz"), check.Options{})
	if rep.Has(contract.StoreManifestMismatch) || len(m.Objects) != 1 || len(d.Spans) != 15495 || !m.Partial {
		t.Errorf("one file of a folder: %s, %d objects", codesOf(rep), len(m.Objects))
	}
	// the folder is another capture, with both files
	if _, _, m := runDir(t, dir, check.Options{}); len(m.Objects) != 2 || m.Partial {
		t.Errorf("the folder: %d objects", len(m.Objects))
	}
}

// ClusterInputs gives a fit the cluster dump, the peer map and the names they give together: the dump's win.
func TestClusterInputs(t *testing.T) {
	cs := build(t, contract.TracePeerRenamed)
	pm := `{"schema":"rhobound.peer-map/v1","taken_at":"2023-11-14T22:14:00Z","addresses":{"192.0.2.10:8080":"x","cart.local":"cart"}}`
	if err := os.WriteFile(filepath.Join(cs.Dir, "peer-map.json"), []byte(pm), 0o644); err != nil {
		t.Fatal(err)
	}
	rep, _, m := runDir(t, cs.Dir, check.Options{})
	dump, peers, names, fs, err := check.ClusterInputs(m)
	if err != nil || dump == nil || peers == nil {
		t.Fatalf("%v %v %v", err, dump, peers)
	}
	if names["192.0.2.10:8080"] != "b" || names["192.0.2.10"] != "b" || names["cart.local"] != "cart" {
		t.Errorf("names %v", names)
	}
	var got []string
	for _, f := range fs {
		got = append(got, f.Code)
	}
	if strings.Join(got, " ") != contract.ClusterTimeUnknown+" "+contract.ClusterSingleSnapshot {
		t.Errorf("findings %v (the flat dump has no recorded time; the peer map's is inside the window)", got)
	}
	if !rep.Has(contract.TracePeerRenamed) || m.ClusterDump == nil || m.ClusterDump.Layout != contract.LayoutSingleSnapshot {
		t.Errorf("%s; manifest record %+v", codesOf(rep), m.ClusterDump)
	}
	if env := dump.Environment(); env.PodImages == nil {
		t.Error("no environment record")
	}
	// no cluster folder, no peer map: nothing
	_, _, plain := runDir(t, build(t, contract.TraceSamplingUnverified).Dir, check.Options{})
	if d, p, n, f, err := check.ClusterInputs(plain); d != nil || p != nil || len(n) != 0 || len(f) != 0 || err != nil {
		t.Errorf("a capture without cluster inputs: %v %v %v %v %v", d, p, n, f, err)
	}
}
