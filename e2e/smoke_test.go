// SPDX-License-Identifier: Apache-2.0

//go:build e2e

package e2e

import (
	"bytes"
	"encoding/json"
	"fmt"
	"io"
	mrand "math/rand"
	"net"
	"net/http"
	"os"
	"os/exec"
	"path/filepath"
	"sort"
	"strings"
	"testing"
	"time"
)

// TestLoopbackSmoke runs the demo services and the load generator as local processes on loopback ports, with no
// cluster: frontend -> api (two processes behind a proxy that picks one per connection, as a Kubernetes Service
// does) -> db, and frontend -> cache. It checks what the cluster test relies on: a span line per request, the load
// generator's summary, analyze(), an even api split with a new connection per call, that `rhobound predict` reads
// the capture (no broken traces, the demo's structure), and a 502 (an error, with a null mean) when a downstream
// service is down. With keep-alive it only logs the split. About 35 s; -short skips it.
func TestLoopbackSmoke(t *testing.T) {
	if testing.Short() {
		t.Skip("-short")
	}
	root, _ := filepath.Abs("..")
	bin := t.TempDir()
	for b, pkg := range map[string]string{"demoapp": "./e2e/demoapp", "loadgen": "./e2e/loadgen", "rhobound": "./cmd/rhobound"} {
		cmd := exec.Command("go", "build", "-o", filepath.Join(bin, b), pkg)
		cmd.Dir = root
		if out, err := cmd.CombinedOutput(); err != nil {
			t.Fatalf("build %s: %v\n%s", b, err, out)
		}
	}
	for _, keepAlive := range []bool{false, true} {
		t.Run(fmt.Sprintf("keepalive=%v", keepAlive), func(t *testing.T) { smoke(t, bin, keepAlive) })
	}
}

func smoke(t *testing.T, bin string, keepAlive bool) {
	dir := t.TempDir()
	var outs []string
	procs := map[string]*exec.Cmd{}
	start := func(service, pod string, workers int, meanMs float64, calls string, parallel bool) string {
		addr := freeAddr(t)
		_, port, _ := net.SplitHostPort(addr)
		out := filepath.Join(dir, pod+".jsonl")
		stdout, err := os.Create(out)
		if err != nil {
			t.Fatal(err)
		}
		stderr, err := os.Create(filepath.Join(dir, pod+".err"))
		if err != nil {
			t.Fatal(err)
		}
		cmd := exec.Command(filepath.Join(bin, "demoapp"))
		cmd.Env = append(os.Environ(), "SERVICE="+service, "POD_NAME="+pod, fmt.Sprintf("WORKERS=%d", workers),
			fmt.Sprintf("MEAN_MS=%g", meanMs), "CALLS="+calls, fmt.Sprintf("PARALLEL=%v", parallel),
			fmt.Sprintf("KEEPALIVE=%v", keepAlive), "PORT="+port)
		cmd.Stdout, cmd.Stderr = stdout, stderr
		if err := cmd.Start(); err != nil {
			t.Fatal(err)
		}
		t.Cleanup(func() {
			cmd.Process.Kill()
			cmd.Wait()
			stdout.Close()
			stderr.Close()
		})
		waitHealthy(t, addr)
		outs = append(outs, out)
		procs[pod] = cmd
		return addr
	}
	db := start("db", "db-0", 1, 8, "", false)
	cache := start("cache", "cache-0", 2, 5, "", false)
	apiA := start("api", "api-a", 1, 20, "http://"+db, false)
	apiB := start("api", "api-b", 1, 20, "http://"+db, false)
	api := perConnectionProxy(t, apiA, apiB)
	fe := start("frontend", "frontend-0", 4, 3, "http://"+api+",http://"+cache, true)

	// the same skip as analyze(), so both means cover the same requests
	out := runLoadgen(t, bin, fe, "-duration=15s", fmt.Sprintf("-skip=%ds", skipSecs), "-window=3s")
	lg, err := parseLoad(out)
	if err != nil {
		t.Fatalf("load generator output %q: %v", out, err)
	}
	time.Sleep(300 * time.Millisecond) // a service writes its line just after it answers
	var lines []string
	for _, o := range outs {
		b, err := os.ReadFile(o)
		if err != nil {
			t.Fatal(err)
		}
		for _, l := range strings.Split(string(b), "\n") {
			if strings.HasPrefix(l, `{"resourceSpans"`) {
				lines = append(lines, l)
			}
		}
	}
	st := analyze(lines)
	pods := make([]string, 0, len(st.APIShare))
	for p := range st.APIShare {
		pods = append(pods, p)
	}
	sort.Strings(pods)
	split := []string{}
	for _, p := range pods {
		split = append(split, fmt.Sprintf("%s %.1f%% wait %.2f ms", p, 100*st.APIShare[p], st.APIWaitMs[p]))
	}
	t.Logf("load generator: sent %d, %d measured, %d errors, mean %.2f ms, lag %.1f ms, %d windows; traces: entry %.2f ms over %d spans; api %s",
		lg.Sent, lg.Requests, lg.Errors, lg.MeanMs, lg.MaxLagMs, len(lg.Windows), st.EntryMeanMs, st.EntrySpans, strings.Join(split, ", "))

	if lg.Sent == 0 || lg.Requests == 0 || lg.Errors != 0 {
		t.Errorf("load generator: sent %d, measured %d, errors %d", lg.Sent, lg.Requests, lg.Errors)
	}
	if len(lg.Windows) != 5 {
		t.Errorf("%d 3-s windows over 15 s, want 5", len(lg.Windows))
	}
	if st.EntrySpans != lg.Sent {
		t.Errorf("%d entry spans for %d requests sent", st.EntrySpans, lg.Sent)
	}
	if st.LostCallee != 0 || st.LostCaller != 0 || st.BadSpanLines != 0 {
		t.Errorf("unmatched spans: %d calls without a callee span, %d server spans without a caller span, %d bad lines",
			st.LostCallee, st.LostCaller, st.BadSpanLines)
	}
	if d := lg.MeanMs - st.EntryMeanMs; d < -maxGapMs || d > maxGapMs {
		t.Errorf("load generator %.2f ms vs entry spans %.2f ms", lg.MeanMs, st.EntryMeanMs)
	}
	if keepAlive {
		return // the split is per connection here, which is the point; it is only logged
	}
	// a new connection per call: the proxy's random pick is per call, so the split is binomial (sd 0.025 at 450)
	if len(st.APIShare) != 2 {
		t.Errorf("api pods in the traces: %v", pods)
	}
	for _, p := range pods {
		if sh := st.APIShare[p]; sh < 0.35 || sh > 0.65 {
			t.Errorf("api pod %s took %.1f%% of %d calls with a new connection per call", p, 100*sh, st.APICalls)
		}
	}
	predictSmoke(t, bin, dir, lines, lg.MeanMs)

	// db down: api's call fails, so api and then frontend answer 502 and the load generator counts errors
	procs["db-0"].Process.Kill()
	procs["db-0"].Wait()
	out = runLoadgen(t, bin, fe, "-duration=2s", "-skip=0s", "-window=2s")
	bad, err := parseLoad(out)
	if err != nil {
		t.Fatalf("load generator output with db down %q: %v", out, err)
	}
	t.Logf("db down: sent %d, errors %d, measured %d; %s", bad.Sent, bad.Errors, bad.Requests, strings.TrimSpace(out))
	if bad.Sent == 0 || bad.Errors != bad.Sent || bad.Requests != 0 || !strings.Contains(out, `"mean_ms":null`) {
		t.Errorf("with db down every request should fail and the mean be null: %s", out)
	}
}

// predictSmoke runs the CLI on the smoke's capture, as the cluster test does on each before window. It checks
// what the cluster test needs before it can judge anything: the capture is not refused (a span below the trace's
// top whose parent is not in the capture marks its trace broken, and more than 5% broken is refused) and the
// structure is the demo's.
// The numbers are only logged: loopback on a shared machine adds time the cluster does not have.
func predictSmoke(t *testing.T, bin, dir string, lines []string, measuredMs float64) {
	t.Helper()
	capture := filepath.Join(dir, "capture")
	if err := os.MkdirAll(filepath.Join(capture, "traces"), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(capture, "traces", "spans.jsonl"), []byte(strings.Join(lines, "\n")+"\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	args := []string{"predict", capture, "--json", "--patch", fmt.Sprintf("api=+%gms", defaultExtraMs)}
	cmd := exec.Command(filepath.Join(bin, "rhobound"), args...)
	var out, errb bytes.Buffer
	cmd.Stdout, cmd.Stderr = &out, &errb
	if err := cmd.Run(); err != nil {
		t.Fatalf("rhobound %v on the loopback capture: %v\n%s", args, err, errb.String())
	}
	var rep map[string]any
	if err := json.Unmarshal(out.Bytes(), &rep); err != nil {
		t.Fatalf("report: %v", err)
	}
	if n := num(rep, "broken_traces"); n != 0 {
		t.Errorf("the CLI read %v broken traces in a capture that lost nothing", n)
	}
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
	t.Logf("rhobound: own ms frontend %.2f (3), api %.2f (20), db %.2f (8), cache %.2f (5); entry model %.2f ms, load generator %.2f ms; change api +%gms: %+.2f ms",
		num(fe, "own_ms"), num(api, "own_ms"), num(db, "own_ms"), num(cache, "own_ms"), num(fe, "model_ms"), measuredMs, defaultExtraMs, num(fe, "change_ms"))
}

func runLoadgen(t *testing.T, bin, target string, args ...string) string {
	t.Helper()
	cmd := exec.Command(filepath.Join(bin, "loadgen"), append([]string{"-target=http://" + target + "/", "-rps=30"}, args...)...)
	var out, errb bytes.Buffer
	cmd.Stdout, cmd.Stderr = &out, &errb
	if err := cmd.Run(); err != nil {
		t.Fatalf("loadgen: %v\n%s", err, errb.String())
	}
	return out.String()
}

// freeAddr is a loopback address with a port that was free a moment ago.
func freeAddr(t *testing.T) string {
	ln, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	defer ln.Close()
	return ln.Addr().String()
}

func waitHealthy(t *testing.T, addr string) {
	t.Helper()
	for deadline := time.Now().Add(5 * time.Second); time.Now().Before(deadline); time.Sleep(20 * time.Millisecond) {
		if resp, err := http.Get("http://" + addr + "/healthz"); err == nil {
			resp.Body.Close()
			return
		}
	}
	t.Fatalf("%s did not answer", addr)
}

// perConnectionProxy stands in for a Kubernetes Service: it picks a backend at random for each connection, as
// kube-proxy does, and keeps it for the connection's life.
func perConnectionProxy(t *testing.T, backends ...string) string {
	ln, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { ln.Close() })
	go func() {
		for {
			c, err := ln.Accept()
			if err != nil {
				return
			}
			go func() {
				defer c.Close()
				b, err := net.Dial("tcp", backends[mrand.Intn(len(backends))])
				if err != nil {
					return
				}
				defer b.Close()
				go func() {
					io.Copy(b, c)
					b.(*net.TCPConn).CloseWrite()
				}()
				io.Copy(c, b)
			}()
		}
	}()
	return ln.Addr().String()
}
