// SPDX-License-Identifier: Apache-2.0

// Command rhobound predicts mean latency of a service call graph from
// OpenTelemetry traces, and the effect of a change in one service's time.
package main

import (
	"errors"
	"flag"
	"fmt"
	"io"
	"math"
	"os"
	"path/filepath"
	"strconv"
	"strings"

	"github.com/Sharvil2704/rhobound-cli/internal/infer"
	"github.com/Sharvil2704/rhobound-cli/internal/model"
	"github.com/Sharvil2704/rhobound-cli/internal/otlp"
	"github.com/Sharvil2704/rhobound-cli/internal/report"
)

// Version is set at build time with -ldflags "-X main.Version=...".
var Version = "0.1.0-dev"

const usage = `rhobound - mean latency from OpenTelemetry traces

Usage:
  rhobound predict CAPTURE [--patch svc=+3ms,other=+10%] [--workers svc=N] [--kept-share F]
                           [--max-rho 0.85] [--out DIR] [--json] [--plain]
  rhobound infer   CAPTURE [--workers svc=N]        print the inferred call graph (JSON)
  rhobound model   TOPOLOGY.json --rps N [--patch ...] [--max-rho 0.85] [--out DIR] [--json] [--plain]
  rhobound version

CAPTURE is a folder with traces/ (OTLP/JSON lines, plain or .gz), or a trace file.
--patch svc=+3ms adds work that holds the worker to every visit; svc=+10% scales
the service's whole own time per visit, glue (time after its first call) included.
--plain turns off the refinements for 70-80% utilization (arrival variability
carried through the graph, correlated parallel branches); see docs/ACCURACY.md.
It models mean latency under steady, roughly Poisson load. It refuses a load
(the observed one, or the one after the change) at which a service is above
--max-rho utilization, and does not model tails, bursts, retries or timeouts.
`

func main() {
	os.Exit(run(os.Args[1:], os.Stdout, os.Stderr))
}

// run executes one command line and returns the exit status.
func run(args []string, out, errw io.Writer) int {
	if len(args) < 1 {
		fmt.Fprint(errw, usage)
		return 2
	}
	var err error
	switch args[0] {
	case "predict":
		err = cmdPredict(args[1:], out, errw)
	case "infer":
		err = cmdInfer(args[1:], out, errw)
	case "model":
		err = cmdModel(args[1:], out, errw)
	case "version", "--version", "-v":
		fmt.Fprintln(out, "rhobound", Version)
	case "help", "--help", "-h":
		fmt.Fprint(out, usage)
	default:
		fmt.Fprintf(errw, "unknown command %q\n\n%s", args[0], usage)
		return 2
	}
	if err != nil {
		fmt.Fprintln(errw, "rhobound:", err)
		return 1
	}
	return 0
}

// parseInterleaved parses flags that may follow positional arguments.
func parseInterleaved(fs *flag.FlagSet, args []string) ([]string, error) {
	var pos []string
	for {
		if err := fs.Parse(args); err != nil {
			return nil, err
		}
		if fs.NArg() == 0 {
			return pos, nil
		}
		pos = append(pos, fs.Arg(0))
		args = fs.Args()[1:]
	}
}

type common struct {
	workers, patch *string
	keptShare      *float64
	maxRho         *float64
	out            *string
	asJSON         *bool
	plain          *bool
}

func newFlags(name string) (*flag.FlagSet, *common) {
	fs := flag.NewFlagSet(name, flag.ContinueOnError)
	fs.SetOutput(io.Discard)
	c := &common{
		workers:   fs.String("workers", "", "workers per pod, as svc=N,svc=N (default: inferred)"),
		patch:     fs.String("patch", "", "change, as svc=+3ms (extra work holding the worker),svc=-10% (the whole own time, glue included)"),
		keptShare: fs.Float64("kept-share", 1, "share of requests the capture holds (1 = all)"),
		maxRho:    fs.Float64("max-rho", 0.85, "refuse when any service is busier than this"),
		out:       fs.String("out", "", "write report.txt and report.json into this folder"),
		asJSON:    fs.Bool("json", false, "print the JSON report instead of the text one"),
		plain:     fs.Bool("plain", false, "use the basic model (Poisson arrivals everywhere, exponential branches)"),
	}
	return fs, c
}

func parseWorkers(s string) (map[string]int, error) {
	out := map[string]int{}
	for _, kv := range splitList(s) {
		k, v, ok := strings.Cut(kv, "=")
		n, err := strconv.Atoi(strings.TrimSpace(v))
		if !ok || err != nil || n < 1 {
			return nil, fmt.Errorf("--workers: %q is not svc=N with N >= 1", kv)
		}
		out[strings.TrimSpace(k)] = n
	}
	return out, nil
}

func splitList(s string) []string {
	var out []string
	for _, p := range strings.Split(s, ",") {
		if p = strings.TrimSpace(p); p != "" {
			out = append(out, p)
		}
	}
	return out
}

// parsePatch turns "svc=+3ms,other=-10%" into a model patch. +N ms is extra
// work on every visit, added to the service time (it holds the worker); +N%
// scales the service's whole own time per visit, the service time and the
// glue (the time after its first call out, which holds no worker) alike.
func parsePatch(s string, topo *model.Topology) (model.Patch, []report.Change, error) {
	if s == "" {
		return model.Patch{}, nil, nil
	}
	n := len(topo.Services)
	p := model.Patch{DS: make([]float64, n), Shift: make([]bool, n), Glue: make([]float64, n)}
	var changes []report.Change
	for _, kv := range splitList(s) {
		name, val, ok := strings.Cut(kv, "=")
		name, val = strings.TrimSpace(name), strings.TrimSpace(val)
		i := topo.Index(name)
		if !ok || i < 0 {
			return model.Patch{}, nil, fmt.Errorf("--patch: unknown service in %q (services: %s)", kv, strings.Join(topo.Names(), ", "))
		}
		var delta, glue float64
		var err error
		switch {
		case strings.HasSuffix(val, "%"):
			var pct float64
			pct, err = strconv.ParseFloat(strings.TrimSuffix(val, "%"), 64)
			delta = topo.Services[i].S * pct / 100
			glue = topo.Services[i].Glue * pct / 100
		default:
			delta, err = strconv.ParseFloat(strings.TrimSuffix(val, "ms"), 64)
			p.Shift[i] = true // a fixed amount of extra time per visit: the mean moves, the variance stays
		}
		if err != nil || math.IsNaN(delta) || math.IsInf(delta, 0) || math.IsNaN(glue) || math.IsInf(glue, 0) {
			return model.Patch{}, nil, fmt.Errorf("--patch: cannot read %q (use +3ms or -10%%)", kv)
		}
		p.DS[i] += delta
		p.Glue[i] += glue
		changes = append(changes, report.Change{Service: name, DeltaMs: delta + glue, GlueMs: glue, Spec: val})
		if topo.Services[i].S+p.DS[i] < 0 {
			return model.Patch{}, nil, fmt.Errorf("--patch: %s would get a negative service time", name)
		}
		if topo.Services[i].Glue+p.Glue[i] < 0 {
			return model.Patch{}, nil, fmt.Errorf("--patch: %s would get a negative glue time", name)
		}
	}
	return p, changes, nil
}

func load(path string, c *common) (*infer.Inferred, error) {
	if k := *c.keptShare; !(k > 0 && k <= 1) {
		return nil, fmt.Errorf("--kept-share must be in (0, 1], got %v", k)
	}
	w, err := parseWorkers(*c.workers)
	if err != nil {
		return nil, err
	}
	d, err := otlp.ReadDir(path)
	if err != nil {
		return nil, err
	}
	return infer.Run(d, infer.Options{KeptShare: *c.keptShare, Workers: w})
}

func cmdInfer(args []string, out, errw io.Writer) error {
	fs, c := newFlags("infer")
	pos, err := parseInterleaved(fs, args)
	if err != nil || len(pos) != 1 {
		return fmt.Errorf("usage: rhobound infer CAPTURE [--workers svc=N]")
	}
	inf, err := load(pos[0], c)
	if err != nil {
		return err
	}
	b, err := model.MarshalTopology(inf.Topology)
	if err != nil {
		return err
	}
	fmt.Fprintln(out, string(b))
	for _, w := range inf.Warnings {
		fmt.Fprintln(errw, "warning:", w)
	}
	fmt.Fprintf(errw, "external load %.2f requests/s over %.0f s\n", inf.LamExtPerMs*1000, inf.WindowS)
	return nil
}

func cmdPredict(args []string, out, errw io.Writer) error {
	fs, c := newFlags("predict")
	pos, err := parseInterleaved(fs, args)
	if err != nil || len(pos) != 1 {
		return fmt.Errorf("usage: rhobound predict CAPTURE [--patch svc=+3ms] [--workers svc=N] [--out DIR] [--json]")
	}
	if !(*c.maxRho > 0 && *c.maxRho <= 0.95) { // also refuses NaN
		return fmt.Errorf("--max-rho must be in (0, 0.95]")
	}
	inf, err := load(pos[0], c)
	if err != nil {
		return err
	}
	patch, changes, err := parsePatch(*c.patch, inf.Topology)
	if err != nil {
		return err
	}
	cfg := modelConfig(c)
	base, err := model.AnalyticWith(inf.Topology, inf.LamExtPerMs, nil, cfg)
	if err != nil {
		return err
	}
	if mr, _ := base.MaxRho(); !base.Stable || !(mr <= *c.maxRho) { // a NaN utilization is refused too
		return limitError("refusing to predict: at the observed load", inf, base, *c.maxRho)
	}
	var delta *model.Delta
	if patch.DS != nil {
		delta, err = model.ChangePatchWith(inf.Topology, inf.LamExtPerMs, patch, cfg)
		if err != nil {
			return err
		}
		if mr, _ := delta.Patched.MaxRho(); !delta.Stable || !(mr <= *c.maxRho) {
			return limitError("refusing the change: after it", inf, delta.Patched, *c.maxRho)
		}
	}
	rep := report.Build(pos[0], inf, *c.keptShare, base, delta, changes)
	rep.Model = modelName(c)
	return writeReport(rep, c, out, errw)
}

// writeReport writes the report into the --out folder (report.txt and
// report.json) when one is given, then prints it, as JSON with --json.
func writeReport(rep *report.Report, c *common, out, errw io.Writer) error {
	if *c.out != "" {
		if err := os.MkdirAll(*c.out, 0o755); err != nil {
			return err
		}
		tf, err := os.Create(filepath.Join(*c.out, "report.txt"))
		if err != nil {
			return err
		}
		err = rep.WriteText(tf)
		if cerr := tf.Close(); err == nil {
			err = cerr
		}
		if err != nil {
			return err
		}
		jf, err := os.Create(filepath.Join(*c.out, "report.json"))
		if err != nil {
			return err
		}
		err = rep.WriteJSON(jf)
		if cerr := jf.Close(); err == nil {
			err = cerr
		}
		if err != nil {
			return err
		}
		fmt.Fprintf(errw, "wrote %s/report.txt and report.json\n", *c.out)
	}
	if *c.asJSON {
		return rep.WriteJSON(out)
	}
	return rep.WriteText(out)
}

// limitError is the refusal of a load (the observed one, or the one after the
// change) at which a service is above the --max-rho limit: it names each such
// service and its utilization, says which would pass 100% (no steady state;
// the model is unstable there), and, for a service whose worker count is only
// a lower bound, that its utilization is then an upper bound and --workers
// sets the count (a pod with no worker limit reads as such a bound).
func limitError(when string, inf *infer.Inferred, r *model.Result, limit float64) error {
	var busy, lower []string
	example := ""
	for i, rho := range r.Rho {
		if rho <= limit {
			continue
		}
		name := inf.Topology.Services[i].Name
		if math.IsNaN(rho) {
			busy = append(busy, fmt.Sprintf("%s has no utilization (NaN: an input is out of range)", name))
			continue
		}
		if rho < 1 {
			busy = append(busy, fmt.Sprintf("%s would run at %.1f%% utilization", name, 100*rho))
		} else {
			busy = append(busy, fmt.Sprintf("%s would pass 100%% utilization (%.1f%%: no steady state, the model is unstable)", name, 100*rho))
		}
		if i < len(inf.Stats) {
			if st := inf.Stats[i]; st.WorkersInferred && !st.WorkersFromQueueing && !st.External && !st.Stage {
				sv := inf.Topology.Services[i]
				pods, w := sv.Servers, sv.Workers
				if sv.Routing == model.Pooled {
					pods, w = 1, sv.Servers*sv.Workers
				}
				lower = append(lower, fmt.Sprintf("%s (%d x %d+)", name, pods, w))
				if example == "" {
					example = name
				}
			}
		}
	}
	if len(busy) == 0 { // every utilization is within the limit, but a residence is not finite (rounding at saturation)
		busy = append(busy, "the model has no finite latency (a queue at the edge of saturation)")
	}
	msg := fmt.Sprintf("%s %s, above the limit of %.1f%% (--max-rho; the model covers steady load below it only)", when,
		strings.Join(busy, ", "), 100*limit)
	if len(lower) > 0 {
		msg += fmt.Sprintf(". The worker count of %s is only a lower bound: too few of its requests waited for a worker, or "+
			"too briefly, to tell its pool from a larger one or from one with no limit, so that utilization is an upper bound. "+
			"If the pool is larger, or has no limit, set its size with --workers (for example --workers %s=N with N its "+
			"workers per pod)", strings.Join(lower, ", "), example)
	}
	return errors.New(msg)
}

func cmdModel(args []string, out, errw io.Writer) error {
	fs, c := newFlags("model")
	rps := fs.Float64("rps", 0, "external request rate, requests per second")
	pos, err := parseInterleaved(fs, args)
	if err != nil || len(pos) != 1 || !(*rps > 0) || math.IsInf(*rps, 1) {
		return fmt.Errorf("usage: rhobound model TOPOLOGY.json --rps N [--patch svc=+3ms] [--max-rho 0.85] [--out DIR] [--json]")
	}
	// the topology fixes the worker counts and holds no capture to sample
	var unused []string
	fs.Visit(func(f *flag.Flag) {
		if f.Name == "workers" || f.Name == "kept-share" {
			unused = append(unused, "--"+f.Name)
		}
	})
	if len(unused) > 0 {
		return fmt.Errorf("model does not take %s (they apply to a capture: predict and infer)", strings.Join(unused, " or "))
	}
	if !(*c.maxRho > 0 && *c.maxRho <= 0.95) { // also refuses NaN
		return fmt.Errorf("--max-rho must be in (0, 0.95]")
	}
	topo, err := model.LoadTopology(pos[0])
	if err != nil {
		return err
	}
	lam := *rps / 1000
	inf := &infer.Inferred{Topology: topo, LamExtPerMs: lam}
	for _, s := range topo.Services {
		inf.Stats = append(inf.Stats, infer.ServiceStats{Name: s.Name, Entry: false})
	}
	for i := range topo.Entry {
		inf.Stats[i].Entry = true
	}
	cfg := modelConfig(c)
	base, err := model.AnalyticWith(topo, lam, nil, cfg)
	if err != nil {
		return err
	}
	if mr, _ := base.MaxRho(); !base.Stable || !(mr <= *c.maxRho) {
		return limitError(fmt.Sprintf("refusing to evaluate: at %g requests/s", *rps), inf, base, *c.maxRho)
	}
	patch, changes, err := parsePatch(*c.patch, topo)
	if err != nil {
		return err
	}
	var delta *model.Delta
	if patch.DS != nil {
		if delta, err = model.ChangePatchWith(topo, lam, patch, cfg); err != nil {
			return err
		}
		if mr, _ := delta.Patched.MaxRho(); !delta.Stable || !(mr <= *c.maxRho) {
			return limitError("refusing the change: after it", inf, delta.Patched, *c.maxRho)
		}
	}
	rep := report.Build(pos[0], inf, 1, base, delta, changes)
	rep.Model = modelName(c)
	rep.FromTopology = true
	return writeReport(rep, c, out, errw)
}

func modelConfig(c *common) model.Config {
	if *c.plain {
		return model.Plain
	}
	return model.Default
}

func modelName(c *common) string {
	if *c.plain {
		return "basic: Poisson arrivals at every queue, exponential parallel branches"
	}
	return "refined: arrival variability propagated through the graph (weight 0.7), parallel branches as correlated gammas"
}
