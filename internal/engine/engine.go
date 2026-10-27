// SPDX-License-Identifier: Apache-2.0

// Package engine is the predictor as a pure function (docs/mcp/ARCHITECTURE.md 4.1): a fit record, a change set and a
// load point in, report v2 out. Pure means no file, clock or environment variable is read; the same request, tool
// version and GOARCH give the same bytes.
//
// For each corner of the change set's ranges (ARCHITECTURE.md 4.5) it solves the fit's topology before and after the
// change, and reports per entry the change range, the model band at the default fractions and the band widened on the
// side of each biased construct on the entry's path, per service the utilization after the change, the evidence
// class, the labels, the assumptions list and the findings.
//
// The v1 part of the report is made exactly as `rhobound predict CAPTURE` makes it, by the same calls (model.AnalyticWith,
// model.ChangePatchWith, report.Build) on the same values, so that the v1 projection of a prediction from a fit is
// byte-identical to the v1 report of the capture the fit was made from, with the same options and a point change.
package engine

import (
	"errors"
	"fmt"
	"math"
	"slices"
	"sort"
	"strconv"
	"strings"

	"github.com/Sharvil2704/rhobound-cli/internal/change"
	"github.com/Sharvil2704/rhobound-cli/internal/contract"
	"github.com/Sharvil2704/rhobound-cli/internal/fit"
	"github.com/Sharvil2704/rhobound-cli/internal/infer"
	"github.com/Sharvil2704/rhobound-cli/internal/model"
	"github.com/Sharvil2704/rhobound-cli/internal/report"
)

// DefaultMaxRho is the default utilization limit, as `predict --max-rho`.
const DefaultMaxRho = 0.85

// Request is one prediction.
type Request struct {
	// Fit is the fit record to predict from.
	Fit *fit.Record
	// Changes is the change set, validated (change.Set.Validate found no refusal) and resolved (change.Set.Resolve:
	// measured items widened to their delta +-2 standard errors). Nil, or a set without items, gives the fit's
	// baseline: every change range null.
	Changes *change.Set
	// ChangeHash is the digest of the set as it was read, before Resolve (change.Set.Digest); the report's
	// change_hash.
	ChangeHash string
	// Findings are the change set's own findings below refuse level (Validate's doubts and notes), which the report
	// lists beside the fit's and the engine's.
	Findings []contract.Finding
	// LoadScale is the load point: a multiplier of the fit's external rate. 0 and 1 are the fit's window
	// (evaluated_at fit_window); any other value is a what-if. A load_scale item of the set multiplies on top of it.
	LoadScale float64
	// Plain solves with the basic model (Poisson arrivals everywhere, exponential branches), as --plain.
	Plain bool
	// MaxRho is the utilization limit, in (0, 0.95]; 0 means DefaultMaxRho.
	MaxRho float64
}

// ModelName is the model line of a report, as rhobound-cli prints it.
func ModelName(plain bool) string {
	if plain {
		return "basic: Poisson arrivals at every queue, exponential parallel branches"
	}
	return "refined: arrival variability propagated through the graph (weight 0.7), parallel branches as correlated gammas"
}

// Config is the model configuration of --plain or the default.
func Config(plain bool) model.Config {
	if plain {
		return model.Plain
	}
	return model.Default
}

// EvidenceClass is the evidence class every report of this version carries: a fit is read from a real capture whose
// software is not the repository's own queue-like demo, and the engine cannot tell third-party software from it, so it
// says the least generous class (ARCHITECTURE.md 4.6). The gate may lower nothing from it.
const EvidenceClass = report.EvidenceRealUntested

// Predict solves the request and writes report v2.
//
// It refuses, with a *report.RefusalError, a base load already above MaxRho (model.utilization_observed, with
// rhobound-cli's message), an operation this version cannot apply (change.unsupported_op) and more than
// change.MaxUnsignedRanges unsigned ranged items (change.too_many_ranges). A change that pushes a service past MaxRho
// or to saturation is not refused: the report shows it (the rows' utilization_after, null ranges where a corner leaves
// no finite mean), because the gate must be able to block on it (ARCHITECTURE.md 6.3, rule 8). `predict --fit F
// --report v1` refuses it from the report, with the message `predict CAPTURE` prints (AfterLimit).
func Predict(req Request) (*report.V2, error) {
	if req.Fit == nil {
		return nil, errors.New("engine: no fit")
	}
	maxRho := req.MaxRho
	if maxRho == 0 {
		maxRho = DefaultMaxRho
	}
	if !(maxRho > 0 && maxRho <= 0.95) {
		return nil, fmt.Errorf("engine: the utilization limit must be in (0, 0.95], got %v", maxRho)
	}
	scale := req.LoadScale
	if scale == 0 {
		scale = 1
	}
	if !(scale > 0) || math.IsInf(scale, 0) {
		return nil, fmt.Errorf("engine: the load scale must be a positive number, got %v", scale)
	}
	inf, err := req.Fit.Inferred()
	if err != nil {
		return nil, err
	}
	topo := inf.Topology
	cfg := Config(req.Plain)
	lam := inf.LamExtPerMs * scale
	base, err := model.AnalyticWith(topo, lam, nil, cfg)
	if err != nil {
		return nil, err
	}
	if mr, _ := base.MaxRho(); !base.Stable || !(mr <= maxRho) { // a NaN utilization is refused too
		when := "refusing to predict: at the observed load"
		if scale != 1 {
			when = fmt.Sprintf("refusing to predict: at %g times the observed load", scale)
		}
		return nil, LimitError(contract.ModelUtilizationObserved, when, inf, base, maxRho)
	}
	var items []change.Item
	if req.Changes != nil {
		items = req.Changes.Items
	}
	plan, err := planCorners(topo, items)
	if err != nil {
		return nil, err
	}
	deltas := make([]*model.Delta, len(plan.corners))
	for k, c := range plan.corners {
		if deltas[k], err = solve(topo, lam, base, c, cfg); err != nil {
			return nil, err
		}
	}

	// the v1 part, as predict CAPTURE makes it
	kept := req.Fit.KeptShare.Value
	var point *model.Delta
	var changes []report.Change
	if plan.points && len(deltas) == 1 {
		point, changes = deltas[0], plan.changes
	}
	rep := report.Build(req.Fit.Capture, inf, kept, base, point, changes)
	rep.Model = ModelName(req.Plain)
	v := &report.V2{Report: *rep}
	v.Version = report.VersionV2
	v.FitDigest = req.Fit.Digest()
	v.ManifestDigest = req.Fit.ManifestDigest
	v.FitWindow = req.Fit.Window
	v.ChangeHash = req.ChangeHash
	v.Tool = req.Fit.Tool
	v.EvidenceClass = EvidenceClass
	v.UtilizationLimit = maxRho
	v.Corners = len(deltas)
	v.Monotonicity = report.Monotonicity
	v.ModelBand = report.DefaultModelBand()
	v.Items, v.Labels, v.RecordDigests, v.WeakestLabel = applied(items)
	v.Load = report.Load{EvaluatedAt: report.EvaluatedAtFitWindow, LoadScale: scale, MaxUtilizationBefore: v.MaxRho}
	if scale != 1 {
		v.Load.EvaluatedAt = report.EvaluatedAtWhatIf
	}
	if len(deltas) > 0 {
		r := rangeOf(len(deltas), func(k int) float64 { mr, _ := deltas[k].Patched.MaxRho(); return mr })
		v.Load.MaxUtilizationAfter = &r
	}
	hops := make([]float64, len(topo.Services))
	for i, st := range inf.Stats {
		if !st.Entry {
			hops[i] = topo.Services[i].Hop
		}
	}
	stable := true
	for _, d := range deltas {
		stable = stable && d.Stable
	}
	rows := make([]report.Row, len(v.Rows))
	for i, row := range v.Rows {
		if len(deltas) > 0 {
			u := rangeOf(len(deltas), func(k int) float64 { return deltas[k].Patched.Rho[i] })
			row.UtilizationAfter = &u
			if stable {
				c := rangeOf(len(deltas), func(k int) float64 { return deltas[k].Patched.L[i] + hops[i] - row.ModelMs })
				row.ChangeRangeMs = &c
			}
		}
		rows[i] = row
	}
	v.Rows = rows
	v.Entries = entries(topo, inf, base, v.Rows, deltas, stable, plan.changed, req.Plain, v.ModelBand)
	v.Findings = findings(req.Fit.Findings, req.Findings)
	v.Assumptions = assumptions(v.Findings)
	return v, nil
}

// AfterLimit is the refusal of `predict --fit F --report v1` for a change that a v1 report cannot show: one that leaves
// some service, at some corner, above the utilization limit or without a steady state (model.utilization_after, with
// the message `predict CAPTURE` prints); nil when there is none. It expects a request Predict answered.
func AfterLimit(req Request) error {
	if req.Changes == nil || len(req.Changes.Items) == 0 {
		return nil
	}
	maxRho, scale := req.MaxRho, req.LoadScale
	if maxRho == 0 {
		maxRho = DefaultMaxRho
	}
	if scale == 0 {
		scale = 1
	}
	inf, err := req.Fit.Inferred()
	if err != nil {
		return err
	}
	cfg := Config(req.Plain)
	lam := inf.LamExtPerMs * scale
	base, err := model.AnalyticWith(inf.Topology, lam, nil, cfg)
	if err != nil {
		return err
	}
	plan, err := planCorners(inf.Topology, req.Changes.Items)
	if err != nil {
		return err
	}
	for _, c := range plan.corners {
		d, err := solve(inf.Topology, lam, base, c, cfg)
		if err != nil {
			return err
		}
		if mr, _ := d.Patched.MaxRho(); !d.Stable || !(mr <= maxRho) {
			return LimitError(contract.ModelUtilizationAfter, "refusing the change: after it", inf, d.Patched, maxRho)
		}
	}
	return nil
}

// corner is the change at one corner of the ranges: the model patch, the workers per pod by node and the entry
// weights' factors by node.
type corner struct {
	patch   model.Patch
	workers map[int]int
	entry   map[int]float64
}

type cornerPlan struct {
	corners []corner
	// points: every item is a point (one corner), as --patch gives; changes are then v1's changes list.
	points  bool
	changes []report.Change
	// changed are the nodes the items change (own time or workers), for the biased constructs on their paths.
	changed []int
}

// planCorners lists the corners of a set's ranges (ARCHITECTURE.md 4.5): the low corner takes every increasing item at
// its lo and every decreasing one at its hi, the high corner the opposite ends, and each unsigned ranged item is
// enumerated at both ends, combined with both signed corners. A set of points has one corner; no items, none.
func planCorners(topo *model.Topology, items []change.Item) (cornerPlan, error) {
	var p cornerPlan
	if len(items) == 0 {
		return p, nil
	}
	p.points = true
	var unsigned []int
	for k, it := range items {
		if !change.Applies(it.Op) {
			return p, &report.RefusalError{Code: contract.ChangeUnsupportedOp, Subject: it.Service,
				Err: fmt.Errorf("%s: this version cannot apply %s", it.Service, it.Op)}
		}
		i := topo.Index(it.Service)
		if i < 0 {
			return p, &report.RefusalError{Code: contract.ChangeUnknownService, Subject: it.Service,
				Err: fmt.Errorf("%s: unknown service %q", it.Op, it.Service)}
		}
		if !slices.Contains(p.changed, i) && it.Op != change.OpLoadScale {
			p.changed = append(p.changed, i)
		}
		if !it.Value.IsPoint() {
			p.points = false
			if change.SignOf(it.Op) == change.SignUnsigned {
				unsigned = append(unsigned, k)
			}
		}
	}
	if len(unsigned) > change.MaxUnsignedRanges {
		return p, &report.RefusalError{Code: contract.ChangeTooManyRanges,
			Numbers: map[string]float64{"unsigned_ranges": float64(len(unsigned)), "limit": change.MaxUnsignedRanges},
			Err:     fmt.Errorf("%d unsigned ranged items; at most %d", len(unsigned), change.MaxUnsignedRanges)}
	}
	signed := []bool{false}
	if !p.points {
		signed = []bool{false, true}
	}
	for _, high := range signed {
		for mask := 0; mask < 1<<len(unsigned); mask++ {
			c := corner{workers: map[int]int{}, entry: map[int]float64{}}
			n := len(topo.Services)
			c.patch = model.Patch{DS: make([]float64, n), Shift: make([]bool, n), Glue: make([]float64, n)}
			for k, it := range items {
				v := it.Value.Lo
				switch change.SignOf(it.Op) {
				case change.SignIncreasing:
					if high {
						v = it.Value.Hi
					}
				case change.SignDecreasing:
					if !high {
						v = it.Value.Hi
					}
				case change.SignUnsigned:
					if j := slices.Index(unsigned, k); j >= 0 && mask&(1<<j) != 0 {
						v = it.Value.Hi
					}
				}
				i := topo.Index(it.Service)
				sv := topo.Services[i]
				switch it.Op {
				case change.OpOwnMs: // as --patch svc=+Nms: extra work holding the worker; the mean moves, the variance stays
					c.patch.DS[i] += v
					c.patch.Shift[i] = true
					if p.points && mask == 0 && !high {
						p.changes = append(p.changes, report.Change{Service: it.Service, DeltaMs: v + 0, GlueMs: 0, Spec: spec(it)})
					}
				case change.OpOwnPct: // as --patch svc=+N%: the service time and the glue scaled alike
					delta := sv.S * v / 100
					glue := sv.Glue * v / 100
					c.patch.DS[i] += delta
					c.patch.Glue[i] += glue
					if p.points && mask == 0 && !high {
						p.changes = append(p.changes, report.Change{Service: it.Service, DeltaMs: delta + glue, GlueMs: glue, Spec: spec(it)})
					}
				case change.OpWorkers:
					c.workers[i] = int(v)
				case change.OpLoadScale:
					if _, ok := c.entry[i]; !ok {
						c.entry[i] = 1
					}
					c.entry[i] *= v
				}
			}
			p.corners = append(p.corners, c)
		}
	}
	return p, nil
}

// spec is an item's text in report v1's changes list: the --patch text as typed, or the value written so.
func spec(it change.Item) string {
	if it.Spec != "" {
		return it.Spec
	}
	s := strconv.FormatFloat(it.Value.Lo, 'g', -1, 64)
	if it.Value.Lo >= 0 {
		s = "+" + s
	}
	if it.Op == change.OpOwnPct {
		return s + "%"
	}
	return s + "ms"
}

// solve solves the topology after one corner's change, at the load lam. A corner that changes own times only is solved
// by model.ChangePatchWith, as predict CAPTURE solves a patch.
func solve(topo *model.Topology, lam float64, base *model.Result, c corner, cfg model.Config) (*model.Delta, error) {
	if len(c.workers) == 0 && len(c.entry) == 0 {
		return model.ChangePatchWith(topo, lam, c.patch, cfg)
	}
	pt := *topo
	pt.Services = append([]model.Service(nil), topo.Services...)
	for i, w := range c.workers {
		if pt.Services[i].Routing == model.Pooled {
			pt.Services[i].Servers = w // one pod: a pool of w workers
		} else {
			pt.Services[i].Workers = w
		}
	}
	if len(c.entry) > 0 {
		pt.Entry = make(map[int]float64, len(topo.Entry))
		for i, w := range topo.Entry {
			if f, ok := c.entry[i]; ok {
				w *= f
			}
			pt.Entry[i] = w
		}
	}
	ds := c.patch.DS
	for i := range pt.Services {
		if c.patch.Shift[i] && ds[i] != 0 {
			s := pt.Services[i].S
			if s+ds[i] > 0 {
				pt.Services[i].CS2 = topo.Services[i].CS2 * s * s / ((s + ds[i]) * (s + ds[i]))
			}
		}
		if c.patch.Glue[i] != 0 {
			g := pt.Services[i].Glue + c.patch.Glue[i]
			if !(g >= 0) || math.IsInf(g, 0) {
				return nil, fmt.Errorf("%s: the changed glue %v + %v is not a non-negative number", topo.Services[i].Name,
					topo.Services[i].Glue, c.patch.Glue[i])
			}
			pt.Services[i].Glue = g
		}
	}
	pr, err := model.AnalyticWith(&pt, lam, ds, cfg)
	if err != nil {
		return nil, err
	}
	return &model.Delta{Stable: base.Stable && pr.Stable, Base: base, Patched: pr}, nil
}

// rangeOf is the range of f over k = 0..n-1.
func rangeOf(n int, f func(k int) float64) change.Range {
	r := change.Range{Lo: math.Inf(1), Hi: math.Inf(-1)}
	for k := 0; k < n; k++ {
		x := f(k)
		r.Lo, r.Hi = math.Min(r.Lo, x), math.Max(r.Hi, x)
	}
	return r
}

// labelRank orders the labels from the strongest to the weakest: the order of ARCHITECTURE.md 4.3 and of the schema's
// enum.
func labelRank(l string) int { return slices.Index(change.Labels, l) }

// applied lists the items as applied, their labels, the records they cite, and the weakest label.
func applied(items []change.Item) ([]report.Applied, []report.LabelRef, []string, string) {
	out := make([]report.Applied, 0, len(items))
	labels := make([]report.LabelRef, 0, len(items))
	var recs []string
	weakest := ""
	for k, it := range items {
		out = append(out, report.Applied{Op: it.Op, Service: it.Service, Callee: it.Callee, Value: it.Value, Label: it.Label,
			Evidence: append([]string(nil), it.Evidence...), Sign: change.SignOf(it.Op)})
		labels = append(labels, report.LabelRef{Item: k, Label: it.Label})
		if weakest == "" || labelRank(it.Label) > labelRank(weakest) {
			weakest = it.Label
		}
		if it.Label != change.LabelDeclared {
			for _, e := range it.Evidence {
				if !slices.Contains(recs, e) {
					recs = append(recs, e)
				}
			}
		}
	}
	sort.Strings(recs)
	return out, labels, recs, weakest
}

// entries are the report's entry rows: the change range over the corners, the model band and the band widened by the
// biased constructs on the path from the entry to a changed service.
func entries(topo *model.Topology, inf *infer.Inferred, base *model.Result, rows []report.Row, deltas []*model.Delta,
	stable bool, changed []int, plain bool, band report.ModelBand) []report.Entry {
	out := []report.Entry{}
	stage := make([]bool, len(topo.Services)) // node i is row i (fit.Record.Check)
	for i, st := range inf.Stats {
		if i < len(stage) {
			stage[i] = st.Stage
		}
	}
	for i, st := range inf.Stats {
		if !st.Entry || st.External {
			continue
		}
		e := report.Entry{Name: st.Name, BeforeMs: rows[i].ModelMs, Biased: []report.Biased{}}
		if len(deltas) > 0 && stable {
			after := rangeOf(len(deltas), func(k int) float64 { return deltas[k].Patched.L[i] })
			ch := rangeOf(len(deltas), func(k int) float64 { return deltas[k].Patched.L[i] - e.BeforeMs })
			e.AfterMs, e.ChangeMs = &after, &ch
			if e.BeforeMs > 0 {
				pct := change.Range{Lo: 100 * ch.Lo / e.BeforeMs, Hi: 100 * ch.Hi / e.BeforeMs}
				e.ChangePct = &pct
			}
		}
		mag := 0.0
		if e.ChangeMs != nil {
			mag = math.Max(math.Abs(e.ChangeMs.Lo), math.Abs(e.ChangeMs.Hi))
		}
		e.ModelBandMs = band.Ms(mag, e.BeforeMs)
		if len(deltas) > 0 {
			e.Biased = biased(topo, stage, base, i, changed, plain)
		}
		if e.ChangeMs != nil {
			low, high := widening(e.Biased, *e.ChangeMs, e.BeforeMs)
			// the model band at each end's own change (ARCHITECTURE.md 4.7: band(x) at the change x)
			e.BandMs = &change.Range{Lo: e.ChangeMs.Lo - band.Ms(e.ChangeMs.Lo, e.BeforeMs) - low,
				Hi: e.ChangeMs.Hi + band.Ms(e.ChangeMs.Hi, e.BeforeMs) + high}
		}
		out = append(out, e)
	}
	return out
}

// findings are the fit's findings and the request's, each once by its code, subject, subject_untrusted and level, as
// the views list them (two services the name rule shows by one subject, one of them untrusted, keep a finding each),
// sorted.
func findings(lists ...[]contract.Finding) []contract.Finding {
	out := []contract.Finding{}
	seen := map[string]bool{}
	for _, l := range lists {
		for _, f := range l {
			key := f.Code + "\x00" + f.Subject + "\x00" + strconv.FormatBool(f.SubjectUntrusted) + "\x00" + string(f.Level)
			if !seen[key] {
				seen[key] = true
				out = append(out, f)
			}
		}
	}
	contract.SortFindings(out)
	return out
}

// assumptions is the assumptions list (ARCHITECTURE.md 4.8; DATA.md 3.12, 3.13), in a fixed order: what no check of
// the traces can see is not-checkable, and steady roughly Poisson load is checked by check's arrival detectors.
func assumptions(fs []contract.Finding) []report.Assumption {
	has := func(codes ...string) bool {
		for _, f := range fs {
			if slices.Contains(codes, f.Code) {
				return true
			}
		}
		return false
	}
	const traces = "not visible in traces"
	out := []report.Assumption{
		{ID: report.AssumeBalancingRandom, Status: report.NotCheckable, How: "the balancing policy is " + traces + "; modelled as random (wait too high under round-robin)"},
		{ID: report.AssumeWorkerFreedAtCall, Status: report.NotCheckable, How: "a worker held after the first call out is " + traces},
		{ID: report.AssumeClientsInstrumented, Status: report.NotCheckable, How: "an uninstrumented client folds its time into the caller's own time"},
		{ID: report.AssumeNoUntracedRetries, Status: report.NotCheckable, How: "retries and timeouts that leave no span are " + traces},
		{ID: report.AssumeNoCPUThrottling, Status: report.NotCheckable, How: "no resource metrics were supplied"},
		{ID: report.AssumeEntriesNotLostCalls, Status: report.NotCheckable, How: "a capture with no captured top that lost most calls into a service reads them as entries"},
		{ID: report.AssumeTailSamplingDeclared, Status: report.NotCheckable, How: "tail sampling that was not declared is " + traces},
	}
	steady := report.Assumption{ID: report.AssumeSteadyPoisson, Status: report.CheckedOK, How: "check's arrival detectors (DATA.md 3.12)"}
	switch {
	case has(contract.TraceLoadTrend, contract.TraceArrivalsOverdispersed, contract.ModelBatchArrivals):
		steady.Status = report.CheckedDoubt
	case has(contract.TraceArrivalsUnjudged):
		steady.Status, steady.How = report.NotChecked, "too few entry requests to judge the arrivals (trace.arrivals_unjudged)"
	case len(fs) == 0 || !hasCheck(fs):
		steady.Status, steady.How = report.NotChecked, "the fit carries no check report"
	}
	out = append(out, steady,
		report.Assumption{ID: report.AssumeServiceTimeFlat, Status: report.NotCheckable, How: "one capture is one load level"})
	return out
}

// hasCheck reports whether the findings come from a check report: every checked capture carries the permanent
// sampling doubt or a kept-share source finding, so a check report is never silent.
func hasCheck(fs []contract.Finding) bool {
	for _, f := range fs {
		if strings.HasPrefix(f.Code, "trace.") || strings.HasPrefix(f.Code, "store.") || strings.HasPrefix(f.Code, "cluster.") {
			return true
		}
	}
	return false
}

// LimitError is the refusal of a load (the observed one, or the one after the change) at which a service is above the
// --max-rho limit (code model.utilization_observed or model.utilization_after): it names each such service and its
// utilization, says which would pass 100% (no steady state; the model is unstable there), and, for a service whose
// worker count is only a lower bound, that its utilization is then an upper bound and --workers sets the count (a pod
// with no worker limit reads as such a bound). The message is rhobound-cli's.
func LimitError(code, when string, inf *infer.Inferred, r *model.Result, limit float64) error {
	var busy, lower []string
	example, subject := "", ""
	for i, rho := range r.Rho {
		if rho <= limit {
			continue
		}
		name := inf.Topology.Services[i].Name
		if subject == "" {
			subject = name
		}
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
	mr, _ := r.MaxRho()
	return &report.RefusalError{Code: code, Subject: subject, Numbers: map[string]float64{"utilization": mr, "limit": limit},
		Err: errors.New(msg)}
}
