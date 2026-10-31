package main

import (
	"bytes"
	"context"
	"encoding/json"
	"io"
	"net"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"reflect"
	"sort"
	"strconv"
	"strings"
	"sync"
	"sync/atomic"
	"testing"
	"time"
)

// testSeqHeader carries the arrival's index to the test servers (tagHeader); production requests carry no such header.
const testSeqHeader = "X-Test-Seq"

func TestMain(m *testing.M) {
	tagHeader = testSeqHeader
	os.Exit(m.Run())
}

// arm is a test server that records every request (its seq header and path) and counts new connections.
type arm struct {
	srv   *httptest.Server
	mu    sync.Mutex
	seen  map[int]string
	conns atomic.Int64
	reqs  atomic.Int64
}

func newArm(t *testing.T, h func(w http.ResponseWriter, r *http.Request, n int64)) *arm {
	a := &arm{seen: map[int]string{}}
	a.srv = httptest.NewUnstartedServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		n := a.reqs.Add(1)
		seq, err := strconv.Atoi(r.Header.Get(testSeqHeader))
		if err != nil || r.Method != http.MethodGet || r.Header.Get("traceparent") != "" {
			t.Errorf("request without a seq header, not a GET, or with a traceparent: %v %v", r.Method, r.Header)
		}
		a.mu.Lock()
		if prev, dup := a.seen[seq]; dup {
			t.Errorf("seq %d twice (%s, %s)", seq, prev, r.URL.Path)
		}
		a.seen[seq] = r.URL.Path
		a.mu.Unlock()
		if h != nil {
			h(w, r, n)
			return
		}
		w.Write([]byte(`{"ok":true}`))
	}))
	a.srv.Config.ConnState = func(_ net.Conn, s http.ConnState) {
		if s == http.StateNew {
			a.conns.Add(1)
		}
	}
	a.srv.Start()
	t.Cleanup(a.srv.Close)
	return a
}

func writeMix(t *testing.T, dir string, m Mix) string {
	t.Helper()
	b, _ := json.Marshal(m)
	p := filepath.Join(dir, "mix.json")
	if err := os.WriteFile(p, b, 0o644); err != nil {
		t.Fatal(err)
	}
	return p
}

var twoPaths = Mix{Service: "payments", RatePerPod: 300,
	Paths: []MixPath{{Path: "/charge/card", W: 0.6}, {Path: "/charge/wallet", W: 0.4}}}

func TestScheduleDeterministic(t *testing.T) {
	w := []float64{0.6, 0.4}
	s1 := Schedule(100, 200*time.Second, w, 7)
	s2 := Schedule(100, 200*time.Second, w, 7)
	s3 := Schedule(100, 200*time.Second, w, 8)
	if len(s1) != len(s2) || len(s1) == 0 {
		t.Fatalf("lengths %d %d", len(s1), len(s2))
	}
	for i := range s1 {
		if s1[i] != s2[i] {
			t.Fatalf("arrival %d differs: %v %v", i, s1[i], s2[i])
		}
	}
	if len(s3) == len(s1) && s3[0] == s1[0] {
		t.Fatal("another seed gave the same schedule")
	}
	// Poisson at 100/s over 200 s: 20000 +- 3 sd (sd 141); the weights within 2 points
	if n := len(s1); n < 19580 || n > 20420 {
		t.Fatalf("%d arrivals over 200 s at 100/s", n)
	}
	card := 0
	for i, a := range s1 {
		if i > 0 && a.At <= s1[i-1].At {
			t.Fatal("arrivals not increasing")
		}
		if a.Path == 0 {
			card++
		}
	}
	if f := float64(card) / float64(len(s1)); f < 0.58 || f > 0.62 {
		t.Fatalf("card share %.3f, want 0.6", f)
	}
}

func readCSV(t *testing.T, p string) (rows [2][][5]int64) {
	t.Helper()
	b, err := os.ReadFile(p)
	if err != nil {
		t.Fatal(err)
	}
	lines := strings.Split(strings.TrimSuffix(string(b), "\n"), "\n")
	if lines[0] != "arm,seq,sent_unix_ns,answered_unix_ns,status" {
		t.Fatalf("header %q", lines[0])
	}
	sawB := false
	for _, l := range lines[1:] {
		f := strings.Split(l, ",")
		if len(f) != 5 || (f[0] != "A" && f[0] != "B") {
			t.Fatalf("row %q", l)
		}
		var v [5]int64
		for i := 1; i < 5; i++ {
			if v[i], err = strconv.ParseInt(f[i], 10, 64); err != nil {
				t.Fatalf("row %q: %v", l, err)
			}
		}
		if v[3] < v[2] || v[2] < 1e18 {
			t.Fatalf("row %q: answered before sent, or not Unix ns", l)
		}
		k := 0
		if f[0] == "B" {
			k, sawB = 1, true
		} else if sawB {
			t.Fatal("an A row after a B row")
		}
		if n := len(rows[k]); n > 0 && v[1] <= rows[k][n-1][1] {
			t.Fatalf("seq not increasing in arm %s", f[0])
		}
		rows[k] = append(rows[k], v)
	}
	return rows
}

func readRC(t *testing.T, p string) RequestCount {
	t.Helper()
	b, err := os.ReadFile(p)
	if err != nil {
		t.Fatal(err)
	}
	dec := json.NewDecoder(bytes.NewReader(b))
	dec.DisallowUnknownFields()
	var rc RequestCount
	if err := dec.Decode(&rc); err != nil {
		t.Fatal(err)
	}
	return rc
}

func readSummary(t *testing.T, p string) Summary {
	t.Helper()
	b, err := os.ReadFile(p)
	if err != nil {
		t.Fatal(err)
	}
	var s Summary
	if err := json.Unmarshal(b, &s); err != nil {
		t.Fatal(err)
	}
	return s
}

// The same schedule reaches both arms: every arrival index carries the same path to A and to B, the measured ones are
// in loadgen.csv with seq = index - warm-up arrivals + 1, and both arms' sends of one arrival go out together.
func TestSameScheduleBothArms(t *testing.T) {
	A, B := newArm(t, nil), newArm(t, nil)
	dir := t.TempDir()
	mix := writeMix(t, dir, twoPaths)
	out := filepath.Join(dir, "out")
	code := run(context.Background(), []string{"-a", A.srv.URL, "-b", B.srv.URL, "-mix", mix, "-out", out,
		"-seconds", "0.8", "-warmup", "0.3", "-seed", "11"}, os.Stderr)
	if code != 0 {
		t.Fatalf("exit %d", code)
	}
	sched := Schedule(300, 1100*time.Millisecond, []float64{0.6, 0.4}, 11)
	nWarm := sort.Search(len(sched), func(i int) bool { return sched[i].At >= 300*time.Millisecond })
	if len(A.seen) != len(sched) || len(B.seen) != len(sched) {
		t.Fatalf("A saw %d, B saw %d, scheduled %d", len(A.seen), len(B.seen), len(sched))
	}
	for i, ar := range sched {
		want := twoPaths.Paths[ar.Path].Path
		if A.seen[i] != want || B.seen[i] != want {
			t.Fatalf("arrival %d: A %q B %q, want %q", i, A.seen[i], B.seen[i], want)
		}
	}
	rows := readCSV(t, filepath.Join(out, "loadgen.csv"))
	n := len(sched) - nWarm
	if len(rows[0]) != n || len(rows[1]) != n {
		t.Fatalf("csv rows A %d B %d, want %d measured", len(rows[0]), len(rows[1]), n)
	}
	var gaps []int64
	for i := range rows[0] {
		if rows[0][i][1] != int64(i+1) || rows[1][i][1] != int64(i+1) {
			t.Fatalf("row %d: seq A %d B %d", i, rows[0][i][1], rows[1][i][1])
		}
		g := rows[0][i][2] - rows[1][i][2]
		if g < 0 {
			g = -g
		}
		gaps = append(gaps, g)
	}
	sort.Slice(gaps, func(i, j int) bool { return gaps[i] < gaps[j] })
	if med := gaps[len(gaps)/2]; med > int64(2*time.Millisecond) {
		t.Fatalf("median gap between A's and B's send of one arrival %v", time.Duration(med))
	}
	// the measured sends follow the schedule's spacing (one clock for both arms)
	first := rows[0][0][2]
	for i, r := range rows[0] {
		want := int64(sched[nWarm+i].At - sched[nWarm].At)
		if d := (r[2] - first) - want; d < -int64(5*time.Millisecond) || d > int64(50*time.Millisecond) {
			t.Fatalf("row %d sent %v after the first, scheduled %v", i, time.Duration(r[2]-first), time.Duration(want))
		}
	}
}

// loadgen.csv, rc-a.json, rc-b.json and summary.json: formats, counts and the window (first send to last answer).
func TestOutputs(t *testing.T) {
	A, B := newArm(t, nil), newArm(t, nil)
	dir := t.TempDir()
	mix := writeMix(t, dir, Mix{Service: "auth", RatePerPod: 200, Paths: []MixPath{{Path: "/verify", W: 1}}})
	out := filepath.Join(dir, "out")
	if code := run(context.Background(), []string{"-a", A.srv.URL + "/", "-b", B.srv.URL, "-mix", mix, "-out", out,
		"-seconds", "0.5", "-warmup", "0.1"}, os.Stderr); code != 0 {
		t.Fatalf("exit %d", code)
	}
	rows := readCSV(t, filepath.Join(out, "loadgen.csv"))
	minSent, maxAns := int64(1<<62), int64(0)
	for k := range rows {
		for _, r := range rows[k] {
			if r[4] != 200 {
				t.Fatalf("status %d", r[4])
			}
			minSent, maxAns = min(minSent, r[2]), max(maxAns, r[3])
		}
	}
	for k, name := range []string{"rc-a.json", "rc-b.json"} {
		rc := readRC(t, filepath.Join(out, name))
		if rc.Schema != "rhobound.request-count/v1" || rc.Source != "loadgen" || len(rc.Entries) != 1 ||
			rc.Entries[0].Entry != "auth" || rc.Entries[0].Count != int64(len(rows[k])) {
			t.Fatalf("%s: %+v (csv rows %d)", name, rc, len(rows[k]))
		}
		s, err1 := time.Parse(time.RFC3339Nano, rc.Window.Start)
		e, err2 := time.Parse(time.RFC3339Nano, rc.Window.End)
		if err1 != nil || err2 != nil || !strings.HasSuffix(rc.Window.Start, "Z") || s.UnixNano() != minSent ||
			e.UnixNano() != maxAns {
			t.Fatalf("%s window %+v, want %s .. %s", name, rc.Window, rfc3339(minSent), rfc3339(maxAns))
		}
	}
	sum := readSummary(t, filepath.Join(out, "summary.json"))
	if !sum.OK || sum.Arms["A"].AnsweredShare != 1 || sum.Arms["B"].Status["200"] != len(rows[1]) ||
		sum.WarmupCounts["A"].Sent == 0 || sum.Rate != 200 || sum.Service != "auth" || sum.FreshConn {
		t.Fatalf("summary %+v", sum)
	}
	if ents, _ := os.ReadDir(out); len(ents) != 4 {
		t.Fatalf("out holds %d files, want 4 (no temporary left)", len(ents))
	}
}

// Keep-alive by default: a few connections carry every request; -fresh-conn opens one per request.
func TestKeepAlive(t *testing.T) {
	for _, fresh := range []bool{false, true} {
		A, B := newArm(t, nil), newArm(t, nil)
		dir := t.TempDir()
		mix := writeMix(t, dir, Mix{Service: "auth", RatePerPod: 200, Paths: []MixPath{{Path: "/verify", W: 1}}})
		args := []string{"-a", A.srv.URL, "-b", B.srv.URL, "-mix", mix, "-out", filepath.Join(dir, "out"),
			"-seconds", "0.5", "-warmup", "0.1"}
		if fresh {
			args = append(args, "-fresh-conn")
		}
		if code := run(context.Background(), args, os.Stderr); code != 0 {
			t.Fatalf("fresh %v: exit %d", fresh, code)
		}
		for _, a := range []*arm{A, B} {
			reqs, conns := a.reqs.Load(), a.conns.Load()
			if fresh && conns != reqs {
				t.Fatalf("-fresh-conn: %d connections for %d requests", conns, reqs)
			}
			if !fresh && (reqs < 50 || conns > reqs/5) {
				t.Fatalf("keep-alive: %d connections for %d requests", conns, reqs)
			}
		}
	}
}

// A request that times out is a failure: not in loadgen.csv, not counted, and below 99% answered the exit is 1.
func TestTimeout(t *testing.T) {
	A := newArm(t, nil)
	B := newArm(t, func(w http.ResponseWriter, r *http.Request, n int64) {
		if n%2 == 0 {
			select {
			case <-time.After(2 * time.Second):
			case <-r.Context().Done():
				return
			}
		}
		w.Write([]byte("ok"))
	})
	dir := t.TempDir()
	mix := writeMix(t, dir, Mix{Service: "auth", RatePerPod: 100, Paths: []MixPath{{Path: "/verify", W: 1}}})
	out := filepath.Join(dir, "out")
	t0 := time.Now()
	code := run(context.Background(), []string{"-a", A.srv.URL, "-b", B.srv.URL, "-mix", mix, "-out", out,
		"-seconds", "0.5", "-warmup", "0", "-timeout", "150ms"}, os.Stderr)
	if code != 1 {
		t.Fatalf("exit %d, want 1", code)
	}
	if el := time.Since(t0); el > 1500*time.Millisecond {
		t.Fatalf("took %v: the timeout did not cut the slow requests", el)
	}
	rows := readCSV(t, filepath.Join(out, "loadgen.csv"))
	s := readSummary(t, filepath.Join(out, "summary.json"))
	b := s.Arms["B"]
	if s.OK || b.Failed == 0 || int64(len(rows[1])) != b.Answered || b.Answered+int64(b.Failed) != int64(b.Scheduled) ||
		len(b.Errors) == 0 || s.Arms["A"].Failed != 0 {
		t.Fatalf("summary %+v, B csv rows %d", s, len(rows[1]))
	}
	if rc := readRC(t, filepath.Join(out, "rc-b.json")); rc.Entries[0].Count != b.Answered {
		t.Fatalf("rc-b counts %d, answered %d", rc.Entries[0].Count, b.Answered)
	}
}

// An error status is an answer: logged with its status, counted, exit 0.
func TestErrorStatusIsAnswered(t *testing.T) {
	A := newArm(t, nil)
	B := newArm(t, func(w http.ResponseWriter, r *http.Request, n int64) {
		if n%3 == 0 {
			http.Error(w, "no", http.StatusServiceUnavailable)
			return
		}
		w.Write([]byte("ok"))
	})
	dir := t.TempDir()
	mix := writeMix(t, dir, Mix{Service: "auth", RatePerPod: 200, Paths: []MixPath{{Path: "/verify", W: 1}}})
	out := filepath.Join(dir, "out")
	if code := run(context.Background(), []string{"-a", A.srv.URL, "-b", B.srv.URL, "-mix", mix, "-out", out,
		"-seconds", "0.4", "-warmup", "0"}, os.Stderr); code != 0 {
		t.Fatalf("exit %d", code)
	}
	rows := readCSV(t, filepath.Join(out, "loadgen.csv"))
	n503 := 0
	for _, r := range rows[1] {
		if r[4] == 503 {
			n503++
		}
	}
	s := readSummary(t, filepath.Join(out, "summary.json"))
	if n503 == 0 || s.Arms["B"].Status["503"] != n503 || s.Arms["B"].Answered != int64(len(rows[1])) {
		t.Fatalf("503 rows %d, summary %+v", n503, s.Arms["B"])
	}
}

// Open loop: slow answers never hold the schedule back.
func TestOpenLoop(t *testing.T) {
	slow := func(w http.ResponseWriter, r *http.Request, n int64) {
		time.Sleep(200 * time.Millisecond)
		w.Write([]byte("ok"))
	}
	A, B := newArm(t, slow), newArm(t, slow)
	dir := t.TempDir()
	mix := writeMix(t, dir, Mix{Service: "auth", RatePerPod: 100, Paths: []MixPath{{Path: "/verify", W: 1}}})
	out := filepath.Join(dir, "out")
	t0 := time.Now()
	if code := run(context.Background(), []string{"-a", A.srv.URL, "-b", B.srv.URL, "-mix", mix, "-out", out,
		"-seconds", "0.5", "-warmup", "0"}, os.Stderr); code != 0 {
		t.Fatalf("exit %d", code)
	}
	s := readSummary(t, filepath.Join(out, "summary.json"))
	if el := time.Since(t0); el > 1500*time.Millisecond || s.Arms["A"].Answered < 20 || s.LateMaxMs > 50 {
		t.Fatalf("%v for %d requests of 200 ms each, late max %.1f ms: not open loop", el, s.Arms["A"].Answered,
			s.LateMaxMs)
	}
}

// A signal stops the sending: outputs are written, interrupted, exit 1.
func TestInterrupted(t *testing.T) {
	A, B := newArm(t, nil), newArm(t, nil)
	dir := t.TempDir()
	mix := writeMix(t, dir, Mix{Service: "auth", RatePerPod: 100, Paths: []MixPath{{Path: "/verify", W: 1}}})
	out := filepath.Join(dir, "out")
	ctx, cancel := context.WithTimeout(context.Background(), 300*time.Millisecond)
	defer cancel()
	t0 := time.Now()
	if code := run(ctx, []string{"-a", A.srv.URL, "-b", B.srv.URL, "-mix", mix, "-out", out, "-seconds", "30",
		"-warmup", "0"}, os.Stderr); code != 1 {
		t.Fatalf("exit %d, want 1", code)
	}
	s := readSummary(t, filepath.Join(out, "summary.json"))
	if time.Since(t0) > 2*time.Second || !s.Interrupted || s.OK || s.Arms["A"].Sent == 0 ||
		s.Arms["A"].Sent >= s.Arms["A"].Scheduled {
		t.Fatalf("summary %+v", s)
	}
}

// The arms see what kshop's callers send (SPEC 5, review R13): the headers of a plain Go GET through a transport like
// kshop-svc's (keep-alive, or Connection: close as its fresh_conn calls), no driver header or User-Agent, and with -host
// the Host production's callers use. (kshop-svc's otelhttp transport adds a traceparent; abdrive sends none, so the
// arm's SERVER span stays the trace's root, which splitarms.py and SPEC 0b rule 4 rely on.)
func TestCallerHeaders(t *testing.T) {
	tagHeader = ""
	t.Cleanup(func() { tagHeader = testSeqHeader })
	type seen struct {
		h    http.Header
		host string
	}
	var mu sync.Mutex
	var got []seen
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		mu.Lock()
		got = append(got, seen{r.Header.Clone(), r.Host})
		mu.Unlock()
		w.Write([]byte(`{"ok":true}`))
	}))
	t.Cleanup(srv.Close)
	for _, fresh := range []bool{false, true} {
		// the reference: one request as kshop-svc's do() makes it, less otelhttp's traceparent
		ref := &http.Client{Timeout: 30 * time.Second, Transport: &http.Transport{MaxIdleConns: 1024,
			MaxIdleConnsPerHost: 256, IdleConnTimeout: 90 * time.Second, DisableKeepAlives: fresh}}
		mu.Lock()
		got = nil
		mu.Unlock()
		resp, err := ref.Get(srv.URL + "/verify")
		if err != nil {
			t.Fatal(err)
		}
		io.Copy(io.Discard, resp.Body)
		resp.Body.Close()
		ref.CloseIdleConnections()
		mu.Lock()
		want := got[0].h
		mu.Unlock()
		dir := t.TempDir()
		mix := writeMix(t, dir, Mix{Service: "auth", RatePerPod: 100, Paths: []MixPath{{Path: "/verify", W: 1}}})
		out := filepath.Join(dir, "out")
		args := []string{"-a", srv.URL, "-b", srv.URL, "-mix", mix, "-out", out, "-seconds", "0.3", "-warmup", "0.1",
			"-host", "auth:8080"}
		if fresh {
			args = append(args, "-fresh-conn")
		}
		if code := run(context.Background(), args, os.Stderr); code != 0 {
			t.Fatalf("fresh %v: exit %d", fresh, code)
		}
		mu.Lock()
		reqs := got[1:]
		mu.Unlock()
		if len(reqs) < 20 || want.Get("User-Agent") != "Go-http-client/1.1" {
			t.Fatalf("fresh %v: %d requests; reference headers %v", fresh, len(reqs), want)
		}
		for _, r := range reqs {
			if !reflect.DeepEqual(r.h, want) || r.host != "auth:8080" {
				t.Fatalf("fresh %v: headers %v Host %q, want kshop's %v Host auth:8080", fresh, r.h, r.host, want)
			}
		}
		if s := readSummary(t, filepath.Join(out, "summary.json")); s.Host != "auth:8080" {
			t.Fatalf("summary host %q", s.Host)
		}
	}
}

func TestUsage(t *testing.T) {
	dir := t.TempDir()
	good := writeMix(t, dir, Mix{Service: "auth", RatePerPod: 100, Paths: []MixPath{{Path: "/verify", W: 1}}})
	bad := filepath.Join(dir, "bad.json")
	os.WriteFile(bad, []byte(`{"service":"auth","paths":[{"path":"verify","w":1}]}`), 0o644)
	out := filepath.Join(dir, "out")
	for _, args := range [][]string{
		{},
		{"-a", "http://x:8080", "-b", "http://y:8080", "-out", out},
		{"-a", "x:8080", "-b", "http://y:8080", "-mix", good, "-out", out},
		{"-a", "http://x:8080", "-b", "http://y:8080", "-mix", bad, "-out", out},
		{"-a", "http://x:8080", "-b", "http://y:8080", "-mix", good, "-out", out, "-rate", "-1"},
		{"-a", "http://x:8080", "-b", "http://y:8080", "-mix", good, "-out", out, "extra"},
		{"-a", "http://x:8080", "-b", "http://y:8080", "-mix", good, "-out", out, "-host", "auth:8080/verify"},
		{"-a", "http://x:8080", "-b", "http://y:8080", "-mix", good, "-out", out, "-host", "u@auth:8080"},
	} {
		if code := run(context.Background(), args, &bytes.Buffer{}); code != 2 {
			t.Fatalf("%v: exit %d, want 2", args, code)
		}
	}
}
