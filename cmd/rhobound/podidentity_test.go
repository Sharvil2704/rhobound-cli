// SPDX-License-Identifier: Apache-2.0

package main

// The record of the documented pod-identity change (ARCHITECTURE.md 4.1, DATA.md 3.4 and 17,
// testdata/golden-1a2df09/README.md). Report v1 is byte-identical to rhobound-cli at 1a2df09 on the repository's test
// captures and on every capture without a platform pod identity. A capture that names its pods only by k8s.pod.uid or
// by an ECS task (aws.ecs.task.arn) and has no k8s.pod.name is keyed by that identity, an ECS task by its id, so its
// predictions can change: 1a2df09 keyed pods by k8s.pod.name, else service.instance.id, else host.name, and with none
// of these read all of a service's spans as one pod. On the two variants of hops/cache-30s made here (k8s.pod.name
// renamed to k8s.pod.uid, and replaced by the task ARN), a build of 1a2df09 prints api at 1 x 2+ and the frontend's
// model at 42.84 ms; this tree reads api's two pods, as it does on the capture as it is (2 x 1+, 52.16 ms).

import (
	"bytes"
	"compress/gzip"
	"encoding/json"
	"io"
	"math"
	"os"
	"path/filepath"
	"regexp"
	"runtime"
	"strings"
	"testing"
)

func TestPodIdentityChange(t *testing.T) {
	root, err := filepath.Abs(filepath.Join("..", ".."))
	if err != nil {
		t.Fatal(err)
	}
	const capture = "internal/infer/testdata/hops/cache-30s"
	f, err := os.Open(filepath.Join(root, capture, "traces", "spans.jsonl.gz"))
	if err != nil {
		t.Fatal(err)
	}
	defer f.Close()
	zr, err := gzip.NewReader(f)
	if err != nil {
		t.Fatal(err)
	}
	spans, err := io.ReadAll(zr)
	if err != nil {
		t.Fatal(err)
	}
	podName := regexp.MustCompile(`"key":"k8s\.pod\.name","value":\{"stringValue":"([^"]*)"\}`)
	if !podName.Match(spans) || bytes.Contains(spans, []byte("k8s.pod.uid")) || bytes.Contains(spans, []byte("aws.ecs.")) {
		t.Fatalf("%s no longer names its pods by k8s.pod.name alone", capture)
	}
	account := strings.Repeat("1", 4) + strings.Repeat("2", 4) + strings.Repeat("3", 4) // AWS's documentation example
	dir := t.TempDir()
	variants := map[string][]byte{
		capture:                   nil, // as it is
		filepath.Join(dir, "uid"): podName.ReplaceAll(spans, []byte(`"key":"k8s.pod.uid","value":{"stringValue":"$1"}`)),
		filepath.Join(dir, "ecs"): podName.ReplaceAll(spans,
			[]byte(`"key":"aws.ecs.task.arn","value":{"stringValue":"arn:aws:ecs:us-east-1:`+account+`:task/shop/$1"}`)),
	}
	for path, b := range variants {
		if b == nil {
			continue
		}
		if err := os.MkdirAll(filepath.Join(path, "traces"), 0o755); err != nil {
			t.Fatal(err)
		}
		if err := os.WriteFile(filepath.Join(path, "traces", "spans.jsonl"), b, 0o644); err != nil {
			t.Fatal(err)
		}
	}

	// 1a2df09's bytes, where they were recorded for this architecture
	golden := map[string][]byte{}
	gdir := filepath.Join(root, "testdata", "golden-1a2df09", runtime.GOARCH)
	if raw, err := os.ReadFile(filepath.Join(gdir, "manifest.json")); err == nil {
		var m goldenManifest
		if err := json.Unmarshal(raw, &m); err != nil {
			t.Fatal(err)
		}
		for _, c := range m.Cases {
			if c.Capture == capture && c.Exit == 0 {
				b, err := os.ReadFile(filepath.Join(gdir, c.Stdout))
				if err != nil {
					t.Fatal(err)
				}
				golden[strings.Join(c.Args[2:], " ")] = b
			}
		}
		if len(golden) != 3 {
			t.Fatalf("the goldens of 1a2df09 hold %d forms of %s, want 3", len(golden), capture)
		}
	} else if runtime.GOARCH == "arm64" {
		t.Fatalf("the goldens of 1a2df09 for arm64 are missing: %v", err)
	} else {
		t.Logf("no goldens of 1a2df09 for GOARCH=%s: only the numbers and the absence of the ARN are checked here; the "+
			"comparison with 1a2df09's bytes runs on arm64", runtime.GOARCH)
	}

	t.Setenv("RHOBOUND_ESTIMATOR", "")
	wd, err := os.Getwd()
	if err != nil {
		t.Fatal(err)
	}
	if err := os.Chdir(root); err != nil { // the reports print the capture argument, as the goldens were made
		t.Fatal(err)
	}
	defer os.Chdir(wd)
	for path := range variants {
		for _, form := range [][]string{nil, {"--json"}, {"--patch", "api=+2ms", "--json"}} {
			var out, errw bytes.Buffer
			if code := run(append([]string{"predict", path}, form...), &out, &errw); code != 0 || errw.Len() > 0 {
				t.Fatalf("predict %s %v: exit %d, %s", path, form, code, errw.String())
			}
			got := bytes.ReplaceAll(out.Bytes(), []byte(path), []byte(capture))
			if bytes.Contains(got, []byte(account)) || bytes.Contains(got, []byte("arn:aws")) {
				t.Errorf("predict %s %v prints the task ARN:\n%s", path, form, got)
			}
			// the variants print what 1a2df09 printed for the capture as it is: the same pods, a new key
			if want, ok := golden[strings.Join(form, " ")]; ok && !bytes.Equal(got, want) {
				t.Errorf("predict %s %v differs from 1a2df09's on the capture as it is, at %s", path, form, firstDiff(got, want))
			}
			if len(form) != 1 {
				continue
			}
			var rep struct {
				Services []struct {
					Name     string  `json:"name"`
					Replicas int     `json:"replicas"`
					Workers  int     `json:"workers_per_pod"`
					Lower    bool    `json:"workers_are_a_lower_bound"`
					ModelMs  float64 `json:"model_ms"`
				} `json:"services"`
			}
			if err := json.Unmarshal(out.Bytes(), &rep); err != nil {
				t.Fatal(err)
			}
			for _, s := range rep.Services {
				switch s.Name {
				case "api":
					if s.Replicas != 2 || s.Workers != 1 || !s.Lower {
						t.Errorf("%s: api at %d x %d (lower bound %v), want 2 x 1+ (1a2df09 read one pod on the variants: 1 x 2+)",
							path, s.Replicas, s.Workers, s.Lower)
					}
				case "frontend":
					if math.Abs(s.ModelMs-52.16475275773813) > 1e-9*52.16 {
						t.Errorf("%s: the frontend's model at %v ms, want 52.16 (1a2df09: 42.84 on the variants)", path, s.ModelMs)
					}
				}
			}
		}
	}
}

// TestPodIdentitySplitWarning: on a capture whose api pods take uneven shares of its visits (hops/cache-30s with a
// quarter of one pod's lines moved to the other), the split warning names pods by the key the reader uses. Named only
// by ECS task ARNs, the pods are named by their task ids, never the ARN, its account or its cluster, and every form of
// report v1 prints the bytes it prints for the same capture with the task ids written as k8s.pod.name (a capture
// without a platform pod identity, on which report v1 is 1a2df09's).
func TestPodIdentitySplitWarning(t *testing.T) {
	root, err := filepath.Abs(filepath.Join("..", ".."))
	if err != nil {
		t.Fatal(err)
	}
	f, err := os.Open(filepath.Join(root, "internal/infer/testdata/hops/cache-30s", "traces", "spans.jsonl.gz"))
	if err != nil {
		t.Fatal(err)
	}
	defer f.Close()
	zr, err := gzip.NewReader(f)
	if err != nil {
		t.Fatal(err)
	}
	spans, err := io.ReadAll(zr)
	if err != nil {
		t.Fatal(err)
	}
	const busy, idle = "api-85f4dc7498-8vrv9", "api-85f4dc7498-zwqv9"
	lines := bytes.SplitAfter(spans, []byte("\n"))
	moved := 0
	for i, l := range lines {
		if bytes.Contains(l, []byte(`"stringValue":"`+idle+`"`)) {
			if moved%2 == 0 {
				lines[i] = bytes.ReplaceAll(l, []byte(idle), []byte(busy))
			}
			moved++
		}
	}
	if moved < 100 {
		t.Fatalf("the capture holds %d lines of %s", moved, idle)
	}
	uneven := bytes.Join(lines, nil)
	podName := regexp.MustCompile(`"key":"k8s\.pod\.name","value":\{"stringValue":"([^"]*)"\}`)
	account := strings.Repeat("1", 4) + strings.Repeat("2", 4) + strings.Repeat("3", 4) // AWS's documentation example
	dir := t.TempDir()
	k8s, ecs := filepath.Join(dir, "k8s"), filepath.Join(dir, "ecs")
	for path, b := range map[string][]byte{k8s: uneven, ecs: podName.ReplaceAll(uneven,
		[]byte(`"key":"aws.ecs.task.arn","value":{"stringValue":"arn:aws:ecs:us-east-1:`+account+`:task/shop/$1"}`))} {
		if err := os.MkdirAll(filepath.Join(path, "traces"), 0o755); err != nil {
			t.Fatal(err)
		}
		if err := os.WriteFile(filepath.Join(path, "traces", "spans.jsonl"), b, 0o644); err != nil {
			t.Fatal(err)
		}
	}
	t.Setenv("RHOBOUND_ESTIMATOR", "")
	for _, form := range [][]string{nil, {"--json"}, {"--patch", "api=+2ms", "--json"}} {
		got := map[string][]byte{}
		for _, path := range []string{k8s, ecs} {
			var out, errw bytes.Buffer
			if code := run(append([]string{"predict", path}, form...), &out, &errw); code != 0 {
				t.Fatalf("predict %s %v: exit %d, %s", path, form, code, errw.String())
			}
			got[path] = append(bytes.ReplaceAll(out.Bytes(), []byte(path), []byte("CAPTURE")), errw.Bytes()...)
		}
		if b := got[ecs]; bytes.Contains(b, []byte(account)) || bytes.Contains(b, []byte("arn:aws")) ||
			bytes.Contains(b, []byte("task/shop")) {
			t.Errorf("predict %v on the task ARNs prints the ARN:\n%s", form, b)
		}
		if !bytes.Equal(got[ecs], got[k8s]) {
			t.Errorf("predict %v: the task ARNs print other bytes than their ids as k8s.pod.name, at %s", form,
				firstDiff(got[ecs], got[k8s]))
		}
		if len(form) == 0 {
			if w := got[ecs]; !bytes.Contains(w, []byte("api: its 2 pods took uneven shares")) ||
				!bytes.Contains(w, []byte(busy)) || !bytes.Contains(w, []byte(idle)) {
				t.Errorf("predict on the task ARNs warns of no uneven split of api by its task ids:\n%s", w)
			}
		}
	}
}
