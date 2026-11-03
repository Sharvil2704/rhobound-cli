package main

import (
	"context"
	"net/http"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"testing"
)

// Each arm's mean response body is in summary.json; with -log-bytes each body's size is loadgen.csv's 6th column
// (arm A answers 16 KiB, arm B 48 KiB: maze's c4 thumbnails). Without it the log keeps its 5 columns.
func TestResponseBytes(t *testing.T) {
	body := func(n int) func(w http.ResponseWriter, r *http.Request, _ int64) {
		return func(w http.ResponseWriter, r *http.Request, _ int64) { w.Write(make([]byte, n)) }
	}
	for _, logBytes := range []bool{false, true} {
		A, B := newArm(t, body(16<<10)), newArm(t, body(48<<10))
		dir := t.TempDir()
		mix := writeMix(t, dir, Mix{Service: "media", RatePerPod: 200, Paths: []MixPath{{Path: "/thumb", W: 1}}})
		out := filepath.Join(dir, "out")
		args := []string{"-a", A.srv.URL, "-b", B.srv.URL, "-mix", mix, "-out", out, "-seconds", "0.3", "-warmup", "0.1"}
		if logBytes {
			args = append(args, "-log-bytes")
		}
		if code := run(context.Background(), args, os.Stderr); code != 0 {
			t.Fatalf("exit %d", code)
		}
		sum := readSummary(t, filepath.Join(out, "summary.json"))
		if sum.Arms["A"].MeanBytes != 16<<10 || sum.Arms["B"].MeanBytes != 48<<10 || sum.LogBytes != logBytes {
			t.Fatalf("summary arms %+v, log_bytes %v", sum.Arms, sum.LogBytes)
		}
		b, err := os.ReadFile(filepath.Join(out, "loadgen.csv"))
		if err != nil {
			t.Fatal(err)
		}
		lines := strings.Split(strings.TrimSuffix(string(b), "\n"), "\n")
		if !logBytes {
			readCSV(t, filepath.Join(out, "loadgen.csv")) // the 5-column form, as before
			continue
		}
		if lines[0] != LoadgenHeaderBytes || len(lines) < 3 {
			t.Fatalf("header %q, %d lines", lines[0], len(lines))
		}
		for _, l := range lines[1:] {
			f := strings.Split(l, ",")
			n, err := strconv.ParseInt(f[len(f)-1], 10, 64)
			want := int64(16 << 10)
			if f[0] == "B" {
				want = 48 << 10
			}
			if len(f) != 6 || err != nil || n != want {
				t.Fatalf("row %q", l)
			}
		}
	}
}
