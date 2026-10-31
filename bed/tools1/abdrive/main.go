// Command abdrive is demo1's A/B driver (SPEC 5): one open-loop Poisson schedule, every arrival sent to arm A and arm
// B at once, keep-alive by default; it writes loadgen.csv, rc-a.json, rc-b.json and summary.json (last) to -out.
//
//	abdrive -a URL -b URL -mix mix.json -out DIR [-rate R] [-seconds 600] [-warmup 60] [-seed S] [-service NAME]
//	        [-host HOST[:PORT]] [-fresh-conn] [-timeout 30s] [-min-answered 0.99]
//
// The requests are what kshop's own callers send (Go's default headers, no driver header); -host sets the Host header
// both arms see to the one production's callers send (e.g. auth:8080), so an arm cannot tell the A/B by it.
//
// Exit 0 when both arms answered at least -min-answered of the measured arrivals, 1 otherwise (outputs still
// written), 2 usage or setup error.
package main

import (
	"context"
	"flag"
	"fmt"
	"io"
	"net/url"
	"os"
	"os/signal"
	"syscall"
	"time"
)

func main() {
	ctx, stop := signal.NotifyContext(context.Background(), syscall.SIGINT, syscall.SIGTERM)
	code := run(ctx, os.Args[1:], os.Stderr)
	stop()
	os.Exit(code)
}

const usage = "usage: abdrive -a URL -b URL -mix mix.json -out DIR [-rate R] [-seconds 600] [-warmup 60] [-seed S] " +
	"[-service NAME] [-host HOST[:PORT]] [-fresh-conn] [-timeout 30s] [-min-answered 0.99]"

func run(ctx context.Context, args []string, stderr io.Writer) int {
	fs := flag.NewFlagSet("abdrive", flag.ContinueOnError)
	fs.SetOutput(io.Discard)
	a := fs.String("a", "", "arm A (baseline) base URL")
	b := fs.String("b", "", "arm B (candidate) base URL")
	rate := fs.Float64("rate", 0, "arrivals per second, each to both arms (default: mix.json's rate_per_pod)")
	seconds := fs.Float64("seconds", 600, "the measured run, s")
	warmup := fs.Float64("warmup", 60, "the warm-up before it, s (not logged)")
	seed := fs.Uint64("seed", 1, "the schedule's seed")
	mixPath := fs.String("mix", "", "mix.json (abmix.py)")
	out := fs.String("out", "", "output folder")
	service := fs.String("service", "", "the entry name in rc-a.json / rc-b.json (default: mix.json's service)")
	host := fs.String("host", "", "the Host header sent to both arms (default: each URL's own host)")
	fresh := fs.Bool("fresh-conn", false, "a new connection per request (default keep-alive)")
	timeout := fs.Duration("timeout", 30*time.Second, "per-request timeout")
	minAnswered := fs.Float64("min-answered", 0.99, "the share of answers each arm needs for exit 0")
	if err := fs.Parse(args); err != nil || fs.NArg() != 0 {
		fmt.Fprintln(stderr, usage)
		return 2
	}
	for _, u := range []string{*a, *b} {
		p, err := url.Parse(u)
		if err != nil || (p.Scheme != "http" && p.Scheme != "https") || p.Host == "" {
			fmt.Fprintf(stderr, "abdrive: %q is not an http(s) base URL\n%s\n", u, usage)
			return 2
		}
	}
	if p, err := url.Parse("http://" + *host); *host != "" && (err != nil || p.Host != *host) {
		fmt.Fprintf(stderr, "abdrive: -host %q is not a HOST[:PORT]\n%s\n", *host, usage)
		return 2
	}
	if *mixPath == "" || *out == "" || !(*minAnswered > 0 && *minAnswered <= 1) {
		fmt.Fprintln(stderr, usage)
		return 2
	}
	mix, err := ReadMix(*mixPath)
	if err != nil {
		fmt.Fprintln(stderr, "abdrive:", err)
		return 2
	}
	if *service == "" {
		*service = mix.Service
	}
	if *rate == 0 {
		*rate = mix.RatePerPod
	}
	if *service == "" {
		fmt.Fprintln(stderr, "abdrive: no service name (-service or mix.json's service)")
		return 2
	}
	cfg := Config{URLs: [2]string{*a, *b}, Rate: *rate, Seconds: *seconds, Warmup: *warmup, Seed: *seed,
		FreshConn: *fresh, Host: *host, Timeout: *timeout, Log: stderr}
	for _, p := range mix.Paths {
		cfg.Paths = append(cfg.Paths, p.Path)
		cfg.Weights = append(cfg.Weights, p.W)
	}
	if err := os.MkdirAll(*out, 0o755); err != nil {
		fmt.Fprintln(stderr, "abdrive:", err)
		return 2
	}
	res, err := Drive(ctx, cfg)
	if err != nil {
		fmt.Fprintln(stderr, err)
		return 2
	}
	s := Summarize(cfg, *service, *minAnswered, res)
	if err := WriteOutputs(*out, s, res); err != nil {
		fmt.Fprintln(stderr, "abdrive:", err)
		return 2
	}
	fmt.Fprintf(stderr, "abdrive: window %s .. %s; A answered %d/%d (mean %.3f ms), B answered %d/%d (mean %.3f ms); "+
		"late max %.2f ms; ok %v\n", s.Window.Start, s.Window.End, s.Arms["A"].Answered, s.Arms["A"].Scheduled,
		s.Arms["A"].MeanMs, s.Arms["B"].Answered, s.Arms["B"].Scheduled, s.Arms["B"].MeanMs, s.LateMaxMs, s.OK)
	if !s.OK {
		return 1
	}
	return 0
}
