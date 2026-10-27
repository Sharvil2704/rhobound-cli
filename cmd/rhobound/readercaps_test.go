// SPDX-License-Identifier: Apache-2.0

package main

// Report v1 reads a capture whole, as rhobound-cli at 1a2df09 did. The reader's caps (DATA.md 3.2: 1 GiB inflated per
// file, 8 GiB per capture, 64 MiB per line, 20 million spans, 4 KiB per kept attribute value) protect check, fit and
// the server; predict CAPTURE and infer read with none, so a capture past them prints the report 1a2df09 printed, never
// input.too_large. internal/otlp's TestReadDirHasNoLimits pins all five caps; this test runs three of them end to end.

import (
	"bytes"
	"compress/gzip"
	"encoding/json"
	"io"
	"os"
	"path/filepath"
	"runtime"
	"strconv"
	"strings"
	"testing"
)

// goldenOf returns 1a2df09's standard output and error for a capture by form (the arguments after the capture), where
// they were recorded for this architecture; nil elsewhere.
func goldenOf(t *testing.T, root, capture string) map[string][2]string {
	t.Helper()
	gdir := filepath.Join(root, "testdata", "golden-1a2df09", runtime.GOARCH)
	raw, err := os.ReadFile(filepath.Join(gdir, "manifest.json"))
	if err != nil {
		if runtime.GOARCH == "arm64" {
			t.Fatalf("the goldens of 1a2df09 for arm64 are missing: %v", err)
		}
		t.Logf("no goldens of 1a2df09 for GOARCH=%s: %s is compared with this tree's report of the capture as it is only",
			runtime.GOARCH, capture)
		return nil
	}
	var m goldenManifest
	if err := json.Unmarshal(raw, &m); err != nil {
		t.Fatal(err)
	}
	out := map[string][2]string{}
	for _, c := range m.Cases {
		if c.Capture == capture && c.Exit == 0 {
			b, err := os.ReadFile(filepath.Join(gdir, c.Stdout))
			if err != nil {
				t.Fatal(err)
			}
			out[strings.Join(c.Args[2:], " ")] = [2]string{string(b), c.Stderr}
		}
	}
	if len(out) != 3 {
		t.Fatalf("the goldens of 1a2df09 hold %d forms of %s, want 3", len(out), capture)
	}
	return out
}

// inflate returns the inflated bytes of a capture's spans.jsonl.gz.
func inflate(t *testing.T, root, capture string) []byte {
	t.Helper()
	f, err := os.Open(filepath.Join(root, capture, "traces", "spans.jsonl.gz"))
	if err != nil {
		t.Fatal(err)
	}
	defer f.Close()
	zr, err := gzip.NewReader(f)
	if err != nil {
		t.Fatal(err)
	}
	b, err := io.ReadAll(zr)
	if err != nil {
		t.Fatal(err)
	}
	return b
}

// predictLike runs predict on a variant of a capture in each form and compares its output, the variant's path mapped
// back to the capture's, with this tree's report of the capture as it is and with 1a2df09's golden bytes.
func predictLike(t *testing.T, variant, capture string, forms [][]string, golden map[string][2]string) {
	t.Helper()
	for _, form := range forms {
		var out, errw, baseOut, baseErr bytes.Buffer
		code := run(append([]string{"predict", variant}, form...), &out, &errw)
		if code != 0 {
			t.Errorf("predict %s %v: exit %d, want 0: %s", variant, form, code, errw.String())
			continue
		}
		got := bytes.ReplaceAll(out.Bytes(), []byte(variant), []byte(capture))
		if code := run(append([]string{"predict", capture}, form...), &baseOut, &baseErr); code != 0 {
			t.Fatalf("predict %s %v: exit %d", capture, form, code)
		}
		if !bytes.Equal(got, baseOut.Bytes()) || errw.String() != baseErr.String() {
			t.Errorf("predict %s %v differs from the capture as it is, at %s", variant, form, firstDiff(got, baseOut.Bytes()))
		}
		if g, ok := golden[strings.Join(form, " ")]; ok && (string(got) != g[0] || errw.String() != g[1]) {
			t.Errorf("predict %s %v differs from 1a2df09's, at %s", variant, form, firstDiff(got, []byte(g[0])))
		}
	}
}

func TestReportV1ReadsWithoutCaps(t *testing.T) {
	root, err := filepath.Abs(filepath.Join("..", ".."))
	if err != nil {
		t.Fatal(err)
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
	dir := t.TempDir()
	forms := [][]string{nil, {"--json"}, {"--patch", "api=+2ms", "--json"}}

	// A kept attribute value at the cap and one byte over it: service.version, which 1a2df09 never read, on api's
	// first resource of hops/cache-30s.
	const cache = "internal/infer/testdata/hops/cache-30s"
	spans := inflate(t, root, cache)
	svc := []byte(`{"key":"service.name","value":{"stringValue":"api"}}`)
	if bytes.Contains(spans, []byte("service.version")) || !bytes.Contains(spans, svc) {
		t.Fatalf("%s no longer has api's service.name without a service.version", cache)
	}
	golden := goldenOf(t, root, cache)
	for _, n := range []int{4096, 4097} {
		version := append(append([]byte{}, svc...),
			[]byte(`,{"key":"service.version","value":{"stringValue":"`+strings.Repeat("v", n)+`"}}`)...)
		variant := filepath.Join(dir, "version-"+strconv.Itoa(n))
		if err := os.MkdirAll(filepath.Join(variant, "traces"), 0o755); err != nil {
			t.Fatal(err)
		}
		b := bytes.Replace(spans, svc, version, 1)
		if err := os.WriteFile(filepath.Join(variant, "traces", "spans.jsonl"), b, 0o644); err != nil {
			t.Fatal(err)
		}
		predictLike(t, variant, cache, forms, golden)
	}

	// testdata/capture-chain, then resources of a with no spans, each one line: one line past 64 MiB, and a file that
	// inflates past 1 GiB in lines under it. The lines compress about 1000:1, so the files are small; the reads are not.
	if testing.Short() || raceEnabled {
		// the race detector makes the 1 GiB read take about a minute and many times the memory, and it tests no
		// concurrency; CI's golden-arm64 job runs these cases without it
		t.Log("-short or -race: the captures of 65 MiB and 1 GiB are not read")
		return
	}
	const chain = "testdata/capture-chain"
	golden = goldenOf(t, root, chain)
	head := inflate(t, root, chain)
	for _, c := range []struct {
		name       string
		line, many int
	}{{"line-65mib", 65 << 20, 1}, {"object-1gib", 60 << 20, 18}} {
		variant := filepath.Join(dir, c.name)
		if err := os.MkdirAll(filepath.Join(variant, "traces"), 0o755); err != nil {
			t.Fatal(err)
		}
		f, err := os.Create(filepath.Join(variant, "traces", "spans.jsonl.gz"))
		if err != nil {
			t.Fatal(err)
		}
		zw, err := gzip.NewWriterLevel(f, gzip.BestSpeed)
		if err != nil {
			t.Fatal(err)
		}
		open := `{"resourceSpans":[{"resource":{"attributes":[{"key":"service.name","value":{"stringValue":"a"}},` +
			`{"key":"pad","value":{"stringValue":"`
		shut := `"}}]}}]}` + "\n"
		pad := []byte(open + strings.Repeat("p", c.line-len(open)-len(shut)) + shut)
		inflated := int64(len(head))
		if _, err := zw.Write(head); err != nil {
			t.Fatal(err)
		}
		for i := 0; i < c.many; i++ {
			if _, err := zw.Write(pad); err != nil {
				t.Fatal(err)
			}
			inflated += int64(len(pad))
		}
		if err := zw.Close(); err != nil {
			t.Fatal(err)
		}
		if err := f.Close(); err != nil {
			t.Fatal(err)
		}
		if past := int64(len(pad)) > 64<<20 || inflated > 1<<30; !past {
			t.Fatalf("%s: lines of %d bytes, %d in all: past no cap", c.name, len(pad), inflated)
		}
		predictLike(t, variant, chain, [][]string{nil}, golden)
	}
}
