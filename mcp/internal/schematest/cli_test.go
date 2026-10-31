// SPDX-License-Identifier: Apache-2.0

package schematest

import (
	"bytes"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"io"
	"os"
	"os/exec"
	"path/filepath"
	"runtime"
	"strings"
	"testing"
)

// The loop's clock, workers and policy name (testdata/mcp/README.md).
const (
	loopNow     = "2023-11-14T23:15:20Z"
	loopWorkers = "a=1,b=2,c=1"
)

// engine is the real CLI, built from the repository's root module for this test.
type engine struct {
	t     *testing.T
	bin   string
	state string
}

func buildEngine(t *testing.T, root string) engine {
	t.Helper()
	goTool, err := exec.LookPath("go")
	if err != nil {
		goTool = filepath.Join(runtime.GOROOT(), "bin", "go")
	}
	bin := filepath.Join(t.TempDir(), "rhobound")
	cmd := exec.Command(goTool, "build", "-o", bin, "./cmd/rhobound")
	cmd.Dir = root
	if out, err := cmd.CombinedOutput(); err != nil {
		t.Fatalf("go build ./cmd/rhobound: %v\n%s", err, out)
	}
	return engine{t: t, bin: bin, state: t.TempDir()}
}

// run returns stdout and the exit code; an exit code outside want fails the test.
func (e engine) run(want []int, args ...string) []byte {
	e.t.Helper()
	cmd := exec.Command(e.bin, args...)
	cmd.Env = append(os.Environ(), "RHOBOUND_ESTIMATOR=", "RHOBOUND_STATE="+e.state)
	var stderr bytes.Buffer
	cmd.Stderr = &stderr
	out, err := cmd.Output()
	code := 0
	if ee, ok := err.(*exec.ExitError); ok {
		code = ee.ExitCode()
	} else if err != nil {
		e.t.Fatalf("rhobound %v: %v", args, err)
	}
	for _, w := range want {
		if code == w {
			return out
		}
	}
	e.t.Fatalf("rhobound %v: exit %d, want %v: %s %s", args, code, want, out, stderr.Bytes())
	return nil
}

func ok(e engine, args ...string) []byte { e.t.Helper(); return e.run([]int{0}, args...) }

func write(t *testing.T, dir, name, body string) string {
	t.Helper()
	p := filepath.Join(dir, name)
	if err := os.WriteFile(p, []byte(body), 0o644); err != nil {
		t.Fatal(err)
	}
	return p
}

func readFile(t *testing.T, p string) []byte {
	t.Helper()
	b, err := os.ReadFile(p)
	if err != nil {
		t.Fatal(err)
	}
	return b
}

// copyCapture copies a capture's traces and request count, so that check --write-manifest can write beside them.
func copyCapture(t *testing.T, from, to string) {
	t.Helper()
	for _, rel := range []string{"traces/spans.jsonl.gz", "request-count.json"} {
		src, err := os.Open(filepath.Join(from, filepath.FromSlash(rel)))
		if err != nil {
			t.Fatal(err)
		}
		dst := filepath.Join(to, filepath.FromSlash(rel))
		if err := os.MkdirAll(filepath.Dir(dst), 0o755); err != nil {
			t.Fatal(err)
		}
		f, err := os.Create(dst)
		if err != nil {
			t.Fatal(err)
		}
		if _, err := io.Copy(f, src); err != nil {
			t.Fatal(err)
		}
		src.Close()
		f.Close()
	}
}

// Every document the CLI writes for the server or for CI, made by the real CLI on the scripted agent's fixture,
// validates against its published schema: the version, the check report and the capture manifests, the fit record,
// report v2 and its v1 projection, a refusal, the four views, every explain section, the judge packet and
// judge-check's output, gate.json and the A/B record.
func TestCLIOutputs(t *testing.T) {
	if testing.Short() {
		t.Skip("builds the CLI")
	}
	s, root := load(t)
	e := buildEngine(t, root)
	loop := filepath.Join(root, "testdata", "mcp", "loop")
	policy := filepath.Join(loop, "policy.json")
	tmp := t.TempDir()
	check := func(what, file, ptr string, doc []byte) {
		t.Helper()
		if err := s.Validate(file, ptr, doc); err != nil {
			t.Errorf("%s against %s#%s: %v\n%s", what, file, ptr, err, doc)
		}
	}

	check("version --json", "version.v1.json", "", ok(e, "version", "--json"))

	// check, and the manifests it writes
	check("check --json", "check.v1.json", "", ok(e, "check", loop, "--json"))
	cp := filepath.Join(tmp, "copy")
	copyCapture(t, loop, cp)
	ok(e, "check", cp, "--write-manifest", "--json")
	check("check --write-manifest", "capture-manifest.v1.json", "", readFile(t, filepath.Join(cp, "manifest.json")))
	cut := filepath.Join(tmp, "cut")
	ok(e, "check", loop, "--window", "2023-11-14T22:13:00Z,2023-11-14T22:16:00Z", "--cut", "entry-start", "--out", cut, "--json")
	check("check --cut", "capture-manifest.v1.json", "", readFile(t, filepath.Join(cut, "manifest.json")))

	// the fit, report v2 and its v1 projection, a refusal
	fitDir := filepath.Join(tmp, "fit")
	ok(e, "fit", loop, "--workers", loopWorkers, "--out", fitDir, "--json")
	fit := filepath.Join(fitDir, "fit.json")
	check("fit.json", "fit.v1.json", "", readFile(t, fit))
	block := write(t, tmp, "block.json", `{"schema":"rhobound.change/v1","fit":"","items":[{"op":"own_ms","service":"b","value":{"lo":3.5,"hi":6},"label":"declared"}]}`)
	declared := write(t, tmp, "declared.json", `{"schema":"rhobound.change/v1","fit":"","items":[{"op":"own_ms","service":"b","value":0.4,"label":"declared"}]}`)
	check("change set", "change.v1.json", "", readFile(t, block))
	v2 := ok(e, "predict", "--fit", fit, "--changes", block, "--json")
	check("predict --fit --json", "report.v2.json", "", v2)
	pred := write(t, tmp, "prediction.json", string(v2))
	check("predict --fit --report v1", "report.v1.json", "", ok(e, "predict", "--fit", fit, "--changes", declared, "--report", "v1", "--json"))
	check("predict CAPTURE --json", "report.v1.json", "", ok(e, "predict", loop, "--patch", "b=+1ms", "--json"))
	unknown := write(t, tmp, "unknown.json", `{"schema":"rhobound.change/v1","fit":"","items":[{"op":"own_ms","service":"nope","value":1,"label":"declared"}]}`)
	check("a refusal", "refusal.v1.json", "", e.run([]int{1}, "predict", "--fit", fit, "--changes", unknown, "--json"))

	// the views
	check("context", "context.v1.json", "", ok(e, "context", "--fit", fit, "--json"))
	check("context full", "context.v1.json", "", ok(e, "context", "--fit", fit, "--policy", policy, "--detail=full", "--json"))
	check("budget", "budget.v1.json", "", ok(e, "budget", "--fit", fit, "--policy", policy, "--json"))
	check("budget of b", "budget.v1.json", "", ok(e, "budget", "--fit", fit, "--service=b", "--json"))
	check("budget of load", "budget.v1.json", "", ok(e, "budget", "--fit", fit, "--policy", policy, "--kinds=own_ms,load_scale", "--json"))
	for name, ch := range map[string]string{"block": block, "declared": declared} {
		for _, detail := range []string{"summary", "full"} {
			check("preview "+name+" "+detail, "prediction.v1.json", "",
				ok(e, "preview", "--fit", fit, "--changes", ch, "--policy", policy, "--now", loopNow, "--detail="+detail, "--json"))
		}
	}

	// the A/B record, and a measured preview citing it
	abDir := filepath.Join(tmp, "ab")
	var printed struct {
		Digest string `json:"ab_digest"`
	}
	if err := json.Unmarshal(ok(e, "diff-fit", "--baseline", filepath.Join(loop, "ab", "baseline"), "--candidate",
		filepath.Join(loop, "ab", "candidate"), "--out", abDir, "--json"), &printed); err != nil {
		t.Fatal(err)
	}
	ab := filepath.Join(abDir, "ab-record.json")
	rec := readFile(t, ab)
	check("ab-record.json", "ab-record.v1.json", "", rec)
	var r struct {
		Services []struct {
			Service string `json:"service"`
			OwnMs   struct {
				Delta json.Number `json:"delta"`
			} `json:"own_ms"`
		} `json:"services"`
	}
	if err := json.Unmarshal(rec, &r); err != nil {
		t.Fatal(err)
	}
	for _, sv := range r.Services {
		if sv.Service == "b" {
			measured := write(t, tmp, "measured.json", `{"schema":"rhobound.change/v1","fit":"","items":[{"op":"own_ms","service":"b","value":`+
				string(sv.OwnMs.Delta)+`,"label":"measured-ab","evidence":["`+printed.Digest+`"]}]}`)
			check("change set, measured", "change.v1.json", "", readFile(t, measured))
			check("preview measured", "prediction.v1.json", "",
				ok(e, "preview", "--fit", fit, "--changes", measured, "--policy", policy, "--now", loopNow, "--json"))
		}
	}

	// explain: every section of every target it applies to
	for _, sec := range []string{"summary", "services", "findings", "assumptions"} {
		check("explain report "+sec, "explain.v1.json", "", ok(e, "explain", "--target", pred, "--section="+sec, "--json"))
	}
	for _, sec := range []string{"summary", "services", "findings"} {
		check("explain fit "+sec, "explain.v1.json", "", ok(e, "explain", "--target", fit, "--section="+sec, "--json"))
		check("explain ab "+sec, "explain.v1.json", "", ok(e, "explain", "--target", ab, "--section="+sec, "--json"))
	}
	for _, sec := range []string{"rules", "judge_packet"} {
		check("explain report "+sec, "explain.v1.json", "", ok(e, "explain", "--target", pred, "--section="+sec, "--policy", policy,
			"--policy-name", "default", "--now", loopNow, "--fit", fit, "--max-chars=8000", "--json"))
	}
	for _, sec := range []string{"data_contract", "scope"} {
		check("explain "+sec, "explain.v1.json", "", ok(e, "explain", "--section="+sec, "--max-chars=8000", "--json"))
	}

	// the judge hand-off and the gate
	packet := ok(e, "judge-packet", pred, "--policy", policy, "--policy-name", "default", "--fit", fit, "--now", loopNow, "--json")
	check("judge-packet", "judge-packet.v1.json", "", packet)
	pk := write(t, tmp, "packet.json", string(packet))
	answer := filepath.Join(loop, "judge-answer.json")
	check("judge-check", "judge-check.v1.json", "", ok(e, "judge-check", answer, "--packet", pk, "--json"))
	gateDir := filepath.Join(tmp, "gate")
	out := e.run([]int{1}, "gate", pred, "--policy", policy, "--now", loopNow, "--out", gateDir, "--json")
	check("gate --json", "gate.v1.json", "", out)
	check("gate.json", "gate.v1.json", "", readFile(t, filepath.Join(gateDir, "gate.json")))
	sum := sha256.Sum256([]byte("a request"))
	jd := filepath.Join(tmp, "gate-judged")
	check("gate with a judge", "gate.v1.json", "", e.run([]int{1}, "gate", pred, "--policy", policy, "--now", loopNow, "--out", jd,
		"--judge-answer", answer, "--judge-packet", pk, "--judge-model", "example-model", "--judge-request", "sha256:"+hex.EncodeToString(sum[:]), "--json"))
	refusal := write(t, tmp, "refused.json", string(e.run([]int{1}, "predict", "--fit", fit, "--changes", unknown, "--json")))
	check("gate on a refusal", "gate.v1.json", "", e.run([]int{3}, "gate", refusal, "--policy", policy, "--now", loopNow, "--out",
		filepath.Join(tmp, "gate-refused"), "--json"))

	// a what-if (predict --fit F --load-scale S): report v2 at the load point and the judge packet of it, gate.json with
	// its load_scale; a base refused at a load point (the refusal's load_scale number) and the gate on that refusal
	whatIf := write(t, tmp, "what-if.json", string(ok(e, "predict", "--fit", fit, "--changes", declared, "--load-scale", "1.3", "--json")))
	check("predict --load-scale", "report.v2.json", "", readFile(t, whatIf))
	check("judge-packet of a what-if", "judge-packet.v1.json", "", ok(e, "judge-packet", whatIf, "--policy", policy,
		"--policy-name", "default", "--fit", fit, "--now", loopNow, "--json"))
	check("gate on a what-if", "gate.v1.json", "", e.run([]int{3}, "gate", whatIf, "--policy", policy, "--now", loopNow,
		"--out", filepath.Join(tmp, "gate-what-if"), "--json"))
	refusedAt := write(t, tmp, "refused-at.json", string(e.run([]int{1}, "predict", "--fit", fit, "--changes", declared,
		"--load-scale", "3.5", "--json")))
	check("a refusal at a load point", "refusal.v1.json", "", readFile(t, refusedAt))
	check("gate on a refusal at a load point", "gate.v1.json", "", e.run([]int{3}, "gate", refusedAt, "--policy", policy,
		"--now", loopNow, "--out", filepath.Join(tmp, "gate-refused-at"), "--json"))
	if strings.Contains(string(out), loop) {
		t.Error("gate.json names a local path")
	}

	// a policy with block_band "model" (rule 10's block test on the model-only band): gate.json with the variant and
	// the entries' two bands, its effective policy, the preview and the explain section of rules
	model := write(t, tmp, "model.json", `{"schema": "rhobound.policy/v1", "max_entry_mean_change_pct": 5, "block_band": "model"}`)
	gm := e.run([]int{1}, "gate", pred, "--policy", model, "--now", loopNow, "--out", filepath.Join(tmp, "gate-model"), "--json")
	check("gate under block_band model", "gate.v1.json", "", gm)
	if !strings.Contains(string(gm), `"variant":"block_band_model"`) || !strings.Contains(string(gm), `"block_band_ms":{`) {
		t.Errorf("gate under block_band model: %s", gm)
	}
	check("policy with block_band model", "policy.v1.json", "", readFile(t, model))
	for _, ch := range []string{block, declared} {
		check("preview under block_band model", "prediction.v1.json", "",
			ok(e, "preview", "--fit", fit, "--changes", ch, "--policy", model, "--now", loopNow, "--detail=full", "--json"))
	}
	check("explain rules under block_band model", "explain.v1.json", "", ok(e, "explain", "--target", pred, "--section=rules",
		"--policy", model, "--policy-name", "model", "--now", loopNow, "--fit", fit, "--json"))
}
