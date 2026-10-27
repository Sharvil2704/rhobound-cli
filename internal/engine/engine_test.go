// SPDX-License-Identifier: Apache-2.0

package engine

import (
	"errors"
	"math"
	"strings"
	"testing"

	"github.com/Sharvil2704/rhobound-cli/internal/abdiff"
	"github.com/Sharvil2704/rhobound-cli/internal/change"
	"github.com/Sharvil2704/rhobound-cli/internal/contract"
	"github.com/Sharvil2704/rhobound-cli/internal/fit"
	"github.com/Sharvil2704/rhobound-cli/internal/infer"
	"github.com/Sharvil2704/rhobound-cli/internal/model"
	"github.com/Sharvil2704/rhobound-cli/internal/report"
)

// handFit is the fit record of a hand-written topology at an external rate lam (requests per ms); entries are its
// entry services. A delay node named stage:S:n or shape:S:j is a stage node, as the inference marks one; any other
// delay node is a peer.
func handFit(t *testing.T, topo *model.Topology, lam float64) *fit.Record {
	t.Helper()
	if err := topo.Finish(); err != nil {
		t.Fatal(err)
	}
	inf := &infer.Inferred{Topology: topo, LamExtPerMs: lam, WindowS: 600, Requests: 1000}
	for i, s := range topo.Services {
		_, entry := topo.Entry[i]
		stage := s.Delay && (strings.HasPrefix(s.Name, "stage:") || strings.HasPrefix(s.Name, "shape:"))
		inf.Stats = append(inf.Stats, infer.ServiceStats{Name: s.Name, Entry: entry, External: s.Delay && !stage,
			Stage: stage})
	}
	r, err := fit.FromInferred(fit.Input{Capture: "hand"}, inf, fit.NewTool("test"))
	if err != nil {
		t.Fatal(err)
	}
	return r
}

// chain is a calls b; b is one pod of `workers` workers with service time s.
func chain(s float64, workers int) *model.Topology {
	return &model.Topology{Name: "chain", Entry: map[int]float64{0: 1}, Services: []model.Service{
		{Name: "a", S: 1, CS2: 1, Calls: []model.Call{{Child: 1, P: 1}}},
		{Name: "b", S: s, CS2: 1, Servers: workers},
	}}
}

func set(items ...change.Item) *change.Set {
	return &change.Set{Schema: change.Schema, Items: items}
}

func item(op, svc string, lo, hi float64) change.Item {
	return change.Item{Op: op, Service: svc, Value: change.Range{Lo: lo, Hi: hi}, Label: change.LabelDeclared}
}

func entryChange(t *testing.T, v *report.V2, name string) change.Range {
	t.Helper()
	for _, e := range v.Entries {
		if e.Name == name {
			if e.ChangeMs == nil {
				t.Fatalf("%s: no change range", name)
			}
			return *e.ChangeMs
		}
	}
	t.Fatalf("no entry %s", name)
	return change.Range{}
}

// Corners are oriented by each operation's sign (ARCHITECTURE.md 4.5): a workers range mixed with an own_ms range on
// a service where both matter is evaluated at (own lo, workers hi) and (own hi, workers lo), never at all-low and
// all-high, and the range is that of a brute-force grid over both.
func TestCornersOrientedBySign(t *testing.T) {
	r := handFit(t, chain(4, 2), 0.2)
	v, err := Predict(Request{Fit: r, Changes: set(item(change.OpOwnMs, "b", 1, 3), item(change.OpWorkers, "b", 2, 4))})
	if err != nil {
		t.Fatal(err)
	}
	if v.Corners != 2 {
		t.Errorf("%d corners, want 2", v.Corners)
	}
	got := entryChange(t, v, "a")
	point := func(own, w float64) float64 {
		p, err := Predict(Request{Fit: r, Changes: set(item(change.OpOwnMs, "b", own, own), item(change.OpWorkers, "b", w, w))})
		if err != nil {
			t.Fatal(err)
		}
		return entryChange(t, p, "a").Lo
	}
	lo, hi := math.Inf(1), math.Inf(-1)
	var argLo, argHi [2]float64
	for _, own := range []float64{1, 1.5, 2, 2.5, 3} {
		for _, w := range []float64{2, 3, 4} {
			c := point(own, w)
			if c < lo {
				lo, argLo = c, [2]float64{own, w}
			}
			if c > hi {
				hi, argHi = c, [2]float64{own, w}
			}
		}
	}
	if argLo != [2]float64{1, 4} || argHi != [2]float64{3, 2} {
		t.Errorf("the grid's minimum is at %v and maximum at %v", argLo, argHi)
	}
	if math.Abs(got.Lo-lo) > 1e-12 || math.Abs(got.Hi-hi) > 1e-12 {
		t.Errorf("corners give %+v, the grid %v..%v", got, lo, hi)
	}
	// all-low and all-high would have given a narrower, wrong range
	if wrong := point(1, 2); wrong <= got.Lo {
		t.Errorf("(own lo, workers lo) %v is not above the range's low end %v", wrong, got.Lo)
	}
	// a point change has one corner, and the v1 keys of its rows are set; a range leaves them unset
	p, _ := Predict(Request{Fit: r, Changes: set(item(change.OpOwnMs, "b", 1, 1))})
	if p.Corners != 1 || p.Rows[0].ChangeMs == nil || len(p.Changes) != 1 || p.Changes[0].Spec != "+1ms" {
		t.Errorf("a point: %d corners, %v, %+v", p.Corners, p.Rows[0].ChangeMs, p.Changes)
	}
	if v.Rows[0].ChangeMs != nil || v.Changes != nil || v.Rows[0].ChangeRangeMs == nil || v.Rows[1].UtilizationAfter == nil {
		t.Error("a range: the v1 point keys are set, or the v2 row keys are not")
	}
	// the band: each end widened by the model band at its own change
	e := v.Entries[0]
	b := report.DefaultModelBand()
	if math.Abs(e.BandMs.Lo-(got.Lo-b.Ms(got.Lo, e.BeforeMs))) > 1e-12 || math.Abs(e.BandMs.Hi-(got.Hi+b.Ms(got.Hi, e.BeforeMs))) > 1e-12 ||
		e.ModelBandMs != b.Ms(math.Max(math.Abs(got.Lo), math.Abs(got.Hi)), e.BeforeMs) {
		t.Errorf("band %+v, model band %v, change %+v", e.BandMs, e.ModelBandMs, got)
	}
}

// Unsigned ranged items are enumerated at every corner of their own ranges; more than MaxUnsignedRanges is refused.
// No unsigned operation is applied in this version, so the engine refuses them by name first.
func TestEngineRefusals(t *testing.T) {
	r := handFit(t, chain(4, 2), 0.2)
	var items []change.Item
	for i := 0; i < change.MaxUnsignedRanges+1; i++ {
		items = append(items, item(change.OpSetAsync, "a", 0, 1))
	}
	for _, c := range []struct {
		set  *change.Set
		code string
	}{
		{set(item(change.OpCS2, "b", 1, 2)), contract.ChangeUnsupportedOp},
		{set(item(change.OpOwnMs, "x", 1, 1)), contract.ChangeUnknownService},
	} {
		_, err := Predict(Request{Fit: r, Changes: c.set})
		var re *report.RefusalError
		if !errors.As(err, &re) || re.Code != c.code {
			t.Errorf("%+v: %v", c.set.Items[0], err)
		}
	}
	inf, _ := r.Inferred()
	plan, err := planCorners(inf.Topology, items)
	var re *report.RefusalError
	if !errors.As(err, &re) || re.Code != contract.ChangeUnsupportedOp {
		t.Errorf("unsigned items: %v (%d corners)", err, len(plan.corners))
	}
	// the base load above the limit: model.utilization_observed, rhobound-cli's message
	_, err = Predict(Request{Fit: r, MaxRho: 0.3})
	if !errors.As(err, &re) || re.Code != contract.ModelUtilizationObserved ||
		!strings.HasPrefix(err.Error(), "refusing to predict: at the observed load b would run at 40.0% utilization") {
		t.Errorf("base above the limit: %v", err)
	}
	// a change that saturates is reported, not refused; the v1 form refuses it as predict CAPTURE does
	req := Request{Fit: r, Changes: set(item(change.OpOwnMs, "b", 7, 7))}
	v, err := Predict(req)
	if err != nil || v.Entries[0].ChangeMs != nil || v.Rows[1].UtilizationAfter == nil || v.Rows[1].UtilizationAfter.Lo < 1 {
		t.Errorf("a saturating change: %v, %+v", err, v.Rows[1].UtilizationAfter)
	}
	if err := AfterLimit(req); !errors.As(err, &re) || re.Code != contract.ModelUtilizationAfter ||
		!strings.HasPrefix(err.Error(), "refusing the change: after it b would pass 100% utilization") {
		t.Errorf("AfterLimit: %v", err)
	}
}

// The load point and the other operations: a what-if load scale, a load_scale item on the entry, a workers item.
func TestLoadAndOperations(t *testing.T) {
	r := handFit(t, chain(4, 2), 0.2)
	base, _ := Predict(Request{Fit: r})
	if base.Load.EvaluatedAt != report.EvaluatedAtFitWindow || base.Corners != 0 || base.Entries[0].ChangeMs != nil ||
		base.Load.MaxUtilizationAfter != nil || len(base.Items) != 0 || base.WeakestLabel != "" {
		t.Errorf("baseline: %+v", base.Load)
	}
	what, _ := Predict(Request{Fit: r, LoadScale: 1.5})
	if what.Load.EvaluatedAt != report.EvaluatedAtWhatIf || math.Abs(what.Load.MaxUtilizationBefore-0.6) > 1e-12 {
		t.Errorf("what-if: %+v", what.Load)
	}
	// load_scale on the only entry is the what-if load, after the change only
	sc, _ := Predict(Request{Fit: r, Changes: set(item(change.OpLoadScale, "a", 1.5, 1.5))})
	if d := entryChange(t, sc, "a").Lo; math.Abs(d-(what.Entries[0].BeforeMs-base.Entries[0].BeforeMs)) > 1e-9 {
		t.Errorf("load_scale 1.5: change %v, want %v", d, what.Entries[0].BeforeMs-base.Entries[0].BeforeMs)
	}
	// more workers lower the mean
	w, _ := Predict(Request{Fit: r, Changes: set(item(change.OpWorkers, "b", 4, 4))})
	if d := entryChange(t, w, "a").Lo; !(d < 0) || w.Items[0].Sign != change.SignDecreasing {
		t.Errorf("workers 2 -> 4: change %v", d)
	}
}

// The biased constructs on the path from an entry to a changed service (ARCHITECTURE.md 4.5, item 3), and the side
// each widens.
func TestBiasedConstructs(t *testing.T) {
	// a calls b then c in sequence; p calls q and r in parallel (r the slower); s calls stage:s:1, which calls t; u, a
	// smooth service, calls v
	topo := &model.Topology{Name: "shapes", Entry: map[int]float64{0: 0.25, 3: 0.25, 6: 0.25, 9: 0.25}, Services: []model.Service{
		{Name: "a", S: 1, CS2: 1, Calls: []model.Call{{Child: 1, P: 1}, {Child: 2, P: 1}}},
		{Name: "b", S: 1, CS2: 1},
		{Name: "c", S: 1, CS2: 1},
		{Name: "p", S: 1, CS2: 1, Parallel: true, Calls: []model.Call{{Child: 4, P: 1}, {Child: 5, P: 1}}},
		{Name: "q", S: 1, CS2: 1},
		{Name: "r", S: 5, CS2: 1},
		{Name: "s", S: 1, CS2: 1, Calls: []model.Call{{Child: 7, P: 1}}},
		{Name: "stage:s:1", Delay: true, CS2: 1, Calls: []model.Call{{Child: 8, P: 1}}},
		{Name: "t", S: 1, CS2: 1},
		{Name: "u", S: 1, CS2: 0.25, Calls: []model.Call{{Child: 10, P: 1}}},
		{Name: "v", S: 1, CS2: 1},
	}}
	r := handFit(t, topo, 0.05)
	v, err := Predict(Request{Fit: r, Changes: set(item(change.OpOwnMs, "c", 1, 1), item(change.OpOwnMs, "q", 1, 1),
		item(change.OpOwnMs, "t", 1, 1), item(change.OpOwnMs, "v", 1, 1), item(change.OpOwnMs, "b", 0, 0))})
	if err != nil {
		t.Fatal(err)
	}
	want := map[string]report.Biased{
		"a": {Construct: report.ConstructSecondSequentialCall, Service: "a", Direction: report.DirectionBoth},
		"p": {Construct: report.ConstructNonSlowestBranch, Service: "p", Direction: report.DirectionOver},
		"s": {Construct: report.ConstructStagedCalls, Service: "s", Direction: report.DirectionOver},
		"u": {Construct: report.ConstructRegularUpstream, Service: "u", Direction: report.DirectionUnder},
	}
	for _, e := range v.Entries {
		w := want[e.Name]
		if len(e.Biased) != 1 || e.Biased[0] != w {
			t.Errorf("%s: %+v, want %+v", e.Name, e.Biased, w)
			continue
		}
		m := report.DefaultModelBand()
		low := e.ChangeMs.Lo - m.Ms(e.ChangeMs.Lo, e.BeforeMs) - e.BandMs.Lo
		high := e.BandMs.Hi - e.ChangeMs.Hi - m.Ms(e.ChangeMs.Hi, e.BeforeMs)
		switch w.Direction {
		case report.DirectionOver: // the true change is nearer zero: the low side of an increase
			if !(low > 0) || math.Abs(high) > 1e-12 {
				t.Errorf("%s: widened %v below, %v above", e.Name, low, high)
			}
		case report.DirectionUnder:
			if !(high > 0) || math.Abs(low) > 1e-12 {
				t.Errorf("%s: widened %v below, %v above", e.Name, low, high)
			}
		case report.DirectionBoth:
			if !(high > 0) || !(low > 0) {
				t.Errorf("%s: widened %v below, %v above", e.Name, low, high)
			}
		}
	}
	// the basic model has no regular-upstream bias; a decrease widens the other way
	plain, _ := Predict(Request{Fit: r, Plain: true, Changes: set(item(change.OpOwnMs, "v", 1, 1))})
	for _, e := range plain.Entries {
		if len(e.Biased) != 0 {
			t.Errorf("plain: %s %+v", e.Name, e.Biased)
		}
	}
	if lo, hi := widening([]report.Biased{want["p"]}, change.Range{Lo: -2, Hi: -1}, 50); lo != 0 || math.Abs(hi-0.85) > 1e-12 {
		t.Errorf("a decrease over-predicted: widened %v below, %v above", lo, hi)
	}
}

// A service the traces name like a stage node (stage:S:1, S any text) is a service of its own, not a stage node: the
// biased constructs name it by its whole name, a row's, never by S, and a call to it is no staged call.
func TestBiasedServiceNamedLikeAStage(t *testing.T) {
	name := "stage:x 203.0.113.9:1"
	topo := &model.Topology{Name: "named", Entry: map[int]float64{0: 1}, Services: []model.Service{
		{Name: "e", S: 1, CS2: 1, Calls: []model.Call{{Child: 1, P: 1}}},
		{Name: name, S: 1, CS2: 0.25, Calls: []model.Call{{Child: 2, P: 1}}},
		{Name: "f", S: 1, CS2: 1},
	}}
	v, err := Predict(Request{Fit: handFit(t, topo, 0.05), Changes: set(item(change.OpOwnMs, "f", 1, 1))})
	if err != nil {
		t.Fatal(err)
	}
	want := report.Biased{Construct: report.ConstructRegularUpstream, Service: name, Direction: report.DirectionUnder}
	if len(v.Entries) != 1 || len(v.Entries[0].Biased) != 1 || v.Entries[0].Biased[0] != want {
		t.Errorf("biased: %+v, want [%+v]", v.Entries, want)
	}
	for _, sv := range []struct {
		name  string
		stage bool
		want  string
	}{{name, false, name}, {"stage:s:1", true, "s"}, {"stage:s:2.1", true, "s"}, {"shape:s:1", true, "s"},
		{"shape:x y:1", false, "shape:x y:1"}} {
		if got := nodeService(sv.name, sv.stage); got != sv.want {
			t.Errorf("nodeService(%q, %v) = %q, want %q", sv.name, sv.stage, got, sv.want)
		}
	}
}

type records map[string]*abdiff.Record

func (r records) AB(d string) (*abdiff.Record, bool) { x, ok := r[d]; return x, ok }

// A measured item enters as its record's delta +-2 standard errors, cites the record, and carries its doubts.
func TestMeasuredItem(t *testing.T) {
	r := handFit(t, chain(4, 2), 0.2)
	rec := &abdiff.Record{Schema: abdiff.Schema, SelfReportConsistent: false, Findings: []contract.Finding{
		contract.NewFinding(contract.ABErrorsDiffer)},
		Services: []abdiff.Service{{Service: "b", OwnMs: abdiff.Delta{Baseline: 4, Candidate: 4.4, Delta: 0.4, SE: 0.05},
			VarianceChanged: true, CallsChanged: true}}}
	d := "sha256:" + strings.Repeat("ab", 32)
	recs := records{d: rec}
	it := change.Item{Op: change.OpOwnMs, Service: "b", Value: change.Point(0.4), Label: change.LabelMeasuredAB, Evidence: []string{d}}
	s := set(it)
	if err := s.Refusal(r, recs); err != nil {
		t.Fatal(err)
	}
	fs := s.Validate(r, recs)
	var codes []string
	for _, f := range fs {
		codes = append(codes, f.Code)
	}
	if strings.Join(codes, " ") != strings.Join([]string{contract.ABErrorsDiffer, contract.ProfileSelfReportMismatch,
		contract.ProfileStructureChanged, contract.ProfileVarianceChanged}, " ") {
		t.Errorf("doubts %v", codes)
	}
	res, err := s.Resolve(r, recs)
	se := rec.Services[0].OwnMs.SE
	if err != nil || res.Items[0].Value != (change.Range{Lo: 0.4 - 2*se, Hi: 0.4 + 2*se}) || s.Items[0].Value != change.Point(0.4) {
		t.Fatalf("resolved %+v (%v)", res.Items[0].Value, err)
	}
	h, _ := s.Digest()
	v, err := Predict(Request{Fit: r, Changes: res, ChangeHash: h, Findings: fs})
	if err != nil {
		t.Fatal(err)
	}
	if len(v.RecordDigests) != 1 || v.RecordDigests[0] != d || v.WeakestLabel != change.LabelMeasuredAB || v.Corners != 2 ||
		v.ChangeHash != h || len(v.Findings) != 4 {
		t.Errorf("record digests %v, weakest %q, %d corners, %d findings", v.RecordDigests, v.WeakestLabel, v.Corners, len(v.Findings))
	}
	if steady := v.Assumptions[7]; steady.ID != report.AssumeSteadyPoisson || steady.Status != report.NotChecked {
		t.Errorf("a fit with no check report: %+v", steady)
	}
	// a label the CLI did not mint, or a value that is not the record's
	for _, bad := range []change.Item{
		{Op: change.OpOwnMs, Service: "b", Value: change.Point(0.3), Label: change.LabelMeasuredAB, Evidence: []string{d}},
		{Op: change.OpOwnMs, Service: "b", Value: change.Point(0.4), Label: change.LabelMeasuredAB, Evidence: []string{"sha256:" + strings.Repeat("0", 64)}},
		{Op: change.OpOwnMs, Service: "b", Value: change.Point(0.4), Label: change.LabelMeasuredAB},
		{Op: change.OpOwnMs, Service: "b", Value: change.Point(0.4), Label: change.LabelDerived},
		{Op: change.OpOwnMs, Service: "b", Value: change.Point(0.4), Label: change.LabelMeasuredPaired, Evidence: []string{d}},
	} {
		var ce *change.Error
		if err := set(bad).Refusal(r, recs); !errors.As(err, &ce) || ce.Finding.Code != contract.ChangeLabelNotMinted {
			t.Errorf("%+v: %v", bad, err)
		}
	}
	if err := set(it).Refusal(r, nil); err == nil {
		t.Error("a measured item with no record store")
	}
}
