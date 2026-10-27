// SPDX-License-Identifier: Apache-2.0

// Package change is the change set (rhobound.change/v1, docs/mcp/schemas/change.v1.json; docs/mcp/DATA.md 11.2): the
// operations a prediction applies to a fit, each a number or a range, each with a label that says where the number
// came from (docs/mcp/ARCHITECTURE.md 4.3).
//
// Labels are checked, not trusted. A caller can only ever supply declared numbers: any other label must cite evidence
// the CLI resolves to a record it computed itself (an A/B record in its record store), and the item's value must be
// that record's; otherwise the set is refused with change.label_not_minted. Ranges are evaluated at their corners,
// oriented by each operation's sign (ARCHITECTURE.md 4.5).
//
// The life of a set in the CLI: Parse (or FromPatch for today's --patch), then Validate against the fit and the record
// store, then Resolve, which widens each measured item to its record's delta +-2 standard errors, then the engine.
package change

import (
	"bytes"
	"encoding/json"
	"errors"
	"fmt"
	"math"
	"slices"
	"sort"
	"strconv"
	"strings"
	"unicode/utf8"

	"github.com/Sharvil2704/rhobound-cli/internal/abdiff"
	"github.com/Sharvil2704/rhobound-cli/internal/contract"
	"github.com/Sharvil2704/rhobound-cli/internal/fit"
	"github.com/Sharvil2704/rhobound-cli/internal/model"
	"github.com/Sharvil2704/rhobound-cli/internal/sanitize"
)

// Schema is the schema id of a change set.
const Schema = "rhobound.change/v1"

// The limits of a set: items, unsigned ranged items (2 x 2^6 = 128 solves at most; change.too_many_ranges above it),
// and the length of a note.
const (
	MaxItems          = 64
	MaxUnsignedRanges = 6
	MaxNoteChars      = 200
)

// The operations (DATA.md 11.2). This version applies OpOwnMs, OpOwnPct, OpWorkers and OpLoadScale; the others are
// refused with change.unsupported_op until the variance patch (cs2) and the structural patch ship.
const (
	OpOwnMs        = "own_ms"     // +ms per visit, holding a worker (--patch svc=+Nms)
	OpOwnPct       = "own_pct"    // +-% of own time and glue (--patch svc=+N%)
	OpWorkers      = "workers"    // workers per pod (--workers)
	OpLoadScale    = "load_scale" // a multiplier of the external rate: a what-if beyond the fit's window
	OpGlueMs       = "glue_ms"
	OpCS2          = "cs2"
	OpAddCall      = "add_call"
	OpRemoveCall   = "remove_call"
	OpSetP         = "set_p"
	OpScaleCount   = "scale_count"
	OpSetAsync     = "set_async"
	OpMakeParallel = "make_parallel"
)

// Ops lists every operation, in the order of the schema's enum.
var Ops = []string{OpOwnMs, OpOwnPct, OpWorkers, OpLoadScale, OpGlueMs, OpCS2, OpAddCall, OpRemoveCall, OpSetP,
	OpScaleCount, OpSetAsync, OpMakeParallel}

// Applies reports whether this version applies an operation.
func Applies(op string) bool {
	switch op {
	case OpOwnMs, OpOwnPct, OpWorkers, OpLoadScale:
		return true
	}
	return false
}

// The labels (ARCHITECTURE.md 4.3, defs.v1 Label). Only LabelDeclared may come from a caller; the CLI or the server
// mints the others from records they made, and a label never moves up.
const (
	LabelDerived             = "derived"
	LabelMeasuredAB          = "measured-ab"
	LabelMeasuredPaired      = "measured-paired"
	LabelMeasuredUnpaired    = "measured-unpaired"
	LabelDeclared            = "declared"
	LabelEstimatedStatic     = "estimated-static"
	LabelEstimatedMicrobench = "estimated-microbench"
	LabelEstimatedJudge      = "estimated-judge"
	LabelAssumed             = "assumed"
)

// Labels lists every label, in the order of the schema's enum.
var Labels = []string{LabelDerived, LabelMeasuredAB, LabelMeasuredPaired, LabelMeasuredUnpaired, LabelDeclared,
	LabelEstimatedStatic, LabelEstimatedMicrobench, LabelEstimatedJudge, LabelAssumed}

// The signs of an operation: the direction in which a larger value moves an entry's mean (ARCHITECTURE.md 4.5).
const (
	SignIncreasing = "increasing"
	SignDecreasing = "decreasing"
	SignUnsigned   = "unsigned"
)

// SignOf returns an operation's sign as ARCHITECTURE.md 4.5 states it: increasing for own_ms, own_pct, glue_ms,
// load_scale and the added calls, call probabilities and counts; decreasing for workers; unsigned for set_async and
// make_parallel (their effect depends on the other branches); and "" for an operation whose sign is not stated yet
// (cs2, remove_call) or is unknown. The low corner of a set takes every increasing item at its Lo and every decreasing
// item at its Hi, the high corner the opposite ends; unsigned items are enumerated at every corner of their own ranges.
// That the entry mean is monotone in each item is an assumption ("monotonicity assumed (untested)").
func SignOf(op string) string {
	switch op {
	case OpOwnMs, OpOwnPct, OpGlueMs, OpLoadScale, OpAddCall, OpSetP, OpScaleCount:
		return SignIncreasing
	case OpWorkers:
		return SignDecreasing
	case OpSetAsync, OpMakeParallel:
		return SignUnsigned
	}
	return ""
}

// Range is a value range, Lo <= Hi; a point is Lo == Hi. It reads a bare number as a point (change.v1's Value is a
// number or a range) and is always written as {"lo", "hi"} (report.v2 items and entries need the object).
type Range struct {
	Lo float64 `json:"lo"`
	Hi float64 `json:"hi"`
}

// Point returns the range of one value.
func Point(v float64) Range { return Range{Lo: v, Hi: v} }

// IsPoint reports whether the range is one value.
func (r Range) IsPoint() bool { return r.Lo == r.Hi }

// UnmarshalJSON reads {"lo": L, "hi": H}, both required and nothing else, or a number N as {N, N}. It does not check
// that Lo <= Hi: Validate refuses an inverted range by name (change.range_inverted).
func (r *Range) UnmarshalJSON(b []byte) error {
	b = bytes.TrimSpace(b)
	if len(b) > 0 && b[0] != '{' {
		if string(b) == "null" {
			return errors.New("change: a range or number is null")
		}
		var v float64
		if err := json.Unmarshal(b, &v); err != nil {
			return fmt.Errorf("change: a value is a number or {\"lo\", \"hi\"}: %v", err)
		}
		*r = Point(v)
		return nil
	}
	var o struct {
		Lo *float64 `json:"lo"`
		Hi *float64 `json:"hi"`
	}
	dec := json.NewDecoder(bytes.NewReader(b))
	dec.DisallowUnknownFields()
	if err := dec.Decode(&o); err != nil {
		return fmt.Errorf("change: a range is {\"lo\", \"hi\"}: %v", err)
	}
	if o.Lo == nil || o.Hi == nil {
		return errors.New("change: a range needs both lo and hi")
	}
	*r = Range{Lo: *o.Lo, Hi: *o.Hi}
	return nil
}

// Item is one operation of a set.
type Item struct {
	Op      string `json:"op"`
	Service string `json:"service"`
	// Callee is the callee of a structural operation, or "".
	Callee string `json:"callee,omitempty"`
	Value  Range  `json:"value"`
	Label  string `json:"label"`
	// Evidence are the digests of the records a label other than declared rests on (an A/B record's Digest).
	Evidence []string `json:"evidence,omitempty"`
	// Note is the caller's words, at most MaxNoteChars; never parsed (a number in prose is change.free_text).
	Note string `json:"note,omitempty"`
	// Spec is the --patch text of an item FromPatch made ("+3ms", "3", "-10%"), kept so that report v1's
	// changes[].spec reads as the patch was typed, as `predict CAPTURE --patch` prints it; "" for an item read from a
	// change file. It is never serialized, so it is no part of the set's digest.
	Spec string `json:"-"`

	// patch is the --patch text of the item ("b=+3ms") and patchErr why its value could not be read, for an item
	// FromPatch made.
	patch    string
	patchErr error
}

// Set is a change set. Items is never nil in a set Parse or FromPatch made.
type Set struct {
	Schema string `json:"schema"`
	// Fit is the digest of the fit record the items were written against (fit.Record.Digest). FromPatch leaves it
	// "", and the CLI sets it to the fit it predicts from.
	Fit   string `json:"fit"`
	Items []Item `json:"items"`

	// parsed are the refusals Parse found in items that are not change items (a value as text, a route scope).
	parsed []issue
}

// Parse reads a change file. It checks the shape (the schema id, known keys, at most MaxItems items, the value's
// form: a whole number of at least 1 for workers, a positive number for load_scale); what the items say is checked by
// Validate. Input that is not a change item of this version is kept for Validate to refuse by name (DATA.md 11.2): a
// value given as text (change.free_text), an item restricted to a route (change.route_scope_unsupported), and an item
// whose "source" says its number is not own time per visit: "cpu-profile" (change.cpu_profile_not_own_time),
// "canary" or "histogram" (change.includes_queueing), "microbenchmark" (change.microbench_unvalidated).
func Parse(b []byte) (*Set, error) {
	var raw struct {
		Schema string            `json:"schema"`
		Fit    string            `json:"fit"`
		Items  []json.RawMessage `json:"items"`
	}
	dec := json.NewDecoder(bytes.NewReader(b))
	dec.DisallowUnknownFields()
	if err := dec.Decode(&raw); err != nil {
		return nil, fmt.Errorf("change: %v", err)
	}
	if dec.More() {
		return nil, errors.New("change: more than one JSON value")
	}
	if raw.Schema != Schema {
		return nil, fmt.Errorf("change: schema %q, want %q", raw.Schema, Schema)
	}
	if len(raw.Items) > MaxItems {
		return nil, fmt.Errorf("change: %d items, at most %d", len(raw.Items), MaxItems)
	}
	s := &Set{Schema: raw.Schema, Fit: raw.Fit, Items: make([]Item, 0, len(raw.Items))}
	for i, ri := range raw.Items {
		var keys map[string]json.RawMessage
		if err := json.Unmarshal(ri, &keys); err != nil {
			return nil, fmt.Errorf("change: item %d: %v", i, err)
		}
		var pending []issue
		if _, ok := keys["route"]; ok {
			delete(keys, "route")
			pending = append(pending, issue{code: contract.ChangeRouteScopeUnsupported,
				msg: "an item restricted to a route; give the per-visit mean (ms times the route's share of visits)"})
		}
		if src, ok := keys["source"]; ok {
			delete(keys, "source")
			var name string
			if err := json.Unmarshal(src, &name); err != nil {
				return nil, fmt.Errorf("change: item %d: source: %v", i, err)
			}
			is, ok := sources[name]
			if !ok {
				return nil, fmt.Errorf("change: item %d: source %q is not one this version reads (an A/B record is cited as "+
					"evidence of a measured-ab item)", i, name)
			}
			pending = append(pending, is)
		}
		if v, ok := keys["value"]; ok && len(bytes.TrimSpace(v)) > 0 && bytes.TrimSpace(v)[0] == '"' {
			keys["value"] = json.RawMessage("0")
			pending = append(pending, issue{code: contract.ChangeFreeText,
				msg: "a value given as text; a number in prose is never read: give it as a number or {\"lo\", \"hi\"}"})
		}
		clean, err := json.Marshal(keys)
		if err != nil {
			return nil, fmt.Errorf("change: item %d: %v", i, err)
		}
		var it Item
		dec := json.NewDecoder(bytes.NewReader(clean))
		dec.DisallowUnknownFields()
		if err := dec.Decode(&it); err != nil {
			return nil, fmt.Errorf("change: item %d: %v", i, err)
		}
		if it.Service == "" || it.Op == "" || it.Label == "" || keys["value"] == nil {
			return nil, fmt.Errorf("change: item %d: op, service, value and label are required", i)
		}
		if !slices.Contains(Ops, it.Op) {
			return nil, fmt.Errorf("change: item %d: op %q is not one of %s", i, it.Op, strings.Join(Ops, ", "))
		}
		if !slices.Contains(Labels, it.Label) {
			return nil, fmt.Errorf("change: item %d: label %q is not one of %s", i, it.Label, strings.Join(Labels, ", "))
		}
		if utf8.RuneCountInString(it.Note) > MaxNoteChars {
			return nil, fmt.Errorf("change: item %d: a note of more than %d characters", i, MaxNoteChars)
		}
		if len(pending) == 0 {
			if err := checkValue(it); err != nil {
				return nil, fmt.Errorf("change: item %d: %v", i, err)
			}
		}
		for _, p := range pending {
			p.item = len(s.Items)
			s.parsed = append(s.parsed, p)
		}
		s.Items = append(s.Items, it)
	}
	return s, nil
}

// sources are the kinds of number a change file may say its value came from (an item's "source", which change.v1
// does not define) that are never own time per visit, each refused by name (DATA.md 11.2).
var sources = map[string]issue{
	"cpu-profile": {code: contract.ChangeCPUProfileNotOwnTime,
		msg: "a CPU profile gives CPU per call, not the time a visit holds a worker; measure own time per visit (an A/B run)"},
	"canary": {code: contract.ChangeIncludesQueueing,
		msg: "a canary's latency already contains the queue; as own time it would count the queue twice"},
	"histogram": {code: contract.ChangeIncludesQueueing,
		msg: "a latency histogram already contains the queue; as own time it would count the queue twice"},
	"microbenchmark": {code: contract.ChangeMicrobenchUnvalidated,
		msg: "a microbenchmark delta is accepted for research only, until microbenchmarks are validated against measured differences"},
}

// checkValue checks the form of an item's value for its operation.
func checkValue(it Item) error {
	for _, v := range []float64{it.Value.Lo, it.Value.Hi} {
		switch it.Op {
		case OpWorkers:
			if v != math.Trunc(v) || v < 1 || v > 1<<20 {
				return fmt.Errorf("workers is a whole number of workers per pod, at least 1, not %v", v)
			}
		case OpLoadScale:
			if !(v > 0) || math.IsInf(v, 0) {
				return fmt.Errorf("load_scale multiplies the rate: a positive number, not %v", v)
			}
		}
	}
	return nil
}

// FromPatch turns today's --patch text ("svc=+3ms,other=-10%"; a bare number is ms) into a set of declared own_ms and
// own_pct items, in the order given, each keeping its text in Spec. Service names are not checked here (FromPatch has
// no topology): Validate does that. An item whose value cannot be read is kept and refused by Refusal, in the order
// `predict CAPTURE --patch` refuses (an unknown service first), with the message it has always printed.
func FromPatch(spec string) (*Set, error) {
	s := &Set{Schema: Schema, Items: []Item{}}
	for _, kv := range splitList(spec) {
		name, val, ok := strings.Cut(kv, "=")
		name, val = strings.TrimSpace(name), strings.TrimSpace(val)
		it := Item{Service: name, Label: LabelDeclared, Spec: val, patch: kv, Op: OpOwnMs}
		if !ok {
			it.Service = "" // no service named: refused as an unknown service, as --patch has always done
		}
		var v float64
		var err error
		if strings.HasSuffix(val, "%") {
			it.Op = OpOwnPct
			v, err = strconv.ParseFloat(strings.TrimSuffix(val, "%"), 64)
		} else {
			v, err = strconv.ParseFloat(strings.TrimSuffix(val, "ms"), 64)
		}
		if err != nil || math.IsNaN(v) || math.IsInf(v, 0) {
			it.patchErr = fmt.Errorf("--patch: cannot read %q (use +3ms or -10%%)", kv)
		}
		it.Value = Point(v)
		s.Items = append(s.Items, it)
	}
	return s, nil
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

// Records is the CLI's record store: the A/B records it computed, by digest.
type Records interface {
	AB(digest string) (*abdiff.Record, bool)
}

// issue is one problem of a set: a finding's code, the item it concerns (-1 for the set) and the message the text
// form prints.
type issue struct {
	code    string
	item    int
	subject string
	numbers map[string]float64
	msg     string
}

func (i issue) finding() contract.Finding {
	f := contract.NewFinding(i.code)
	if i.subject != "" {
		f = f.WithSubject(i.subject)
	}
	for _, k := range sortedKeys(i.numbers) {
		f = f.WithNumber(k, i.numbers[k])
	}
	return f
}

// Validate checks the set against the fit it is applied to and the record store, and returns its findings, sorted:
// refusals (change.unknown_service, workers included; change.negative_time; change.range_inverted;
// change.too_many_ranges; change.unsupported_op; change.label_not_minted for a label other than declared whose
// evidence is not a record in recs, or whose value is not that record's delta), then the doubts the cited records
// carry (profile.variance_changed, profile.structure_changed, profile.self_report_mismatch, and the records' own
// findings), which the report lists so the gate can hold on them. A set with a refusal is never predicted.
//
// An item FromPatch could not read has no code and no finding: a set made by FromPatch goes through Refusal first,
// which returns that error. A record that Build, FromInferred or Unmarshal did not make is a programming error and
// panics.
func (s *Set) Validate(r *fit.Record, recs Records) []contract.Finding {
	issues, _, err := s.check(r, recs)
	if err != nil {
		panic(fmt.Sprintf("change: validate against a record without its inference: %v", err))
	}
	out := make([]contract.Finding, 0, len(issues))
	for _, is := range issues {
		out = append(out, is.finding())
	}
	contract.SortFindings(out)
	return out
}

// Refusal returns the set's first refusal, in the order of its items (the order `predict CAPTURE --patch` refuses
// in, with the messages it prints for a patch's items), as an *Error; nil when Validate finds no refusal. An
// unreadable --patch value is an error with no code, as it has always been.
func (s *Set) Refusal(r *fit.Record, recs Records) error {
	issues, patchErr, err := s.check(r, recs)
	if err != nil {
		return err
	}
	if patchErr != nil {
		return patchErr
	}
	var first *issue
	for k := range issues {
		is := &issues[k]
		if is.finding().Level != contract.Refuse {
			continue
		}
		if first == nil || is.item < first.item {
			first = is
		}
	}
	if first == nil {
		return nil
	}
	return &Error{Finding: first.finding(), Err: errors.New(first.msg)}
}

// Error is a set's refusal: a refuse-level finding and the message the text form prints.
type Error struct {
	Finding contract.Finding
	Err     error
}

// Error returns the message.
func (e *Error) Error() string { return e.Err.Error() }

// Unwrap returns the message's error.
func (e *Error) Unwrap() error { return e.Err }

// check returns every issue of the set, and the first unreadable --patch value when no refusal of an earlier item comes
// before it; the error is the record's.
func (s *Set) check(r *fit.Record, recs Records) ([]issue, error, error) {
	inf, err := r.Inferred()
	if err != nil {
		return nil, nil, err
	}
	topo := inf.Topology
	targets := patchTargets(topo)
	issues := append([]issue(nil), s.parsed...)
	add := func(code string, item int, subject, msg string, numbers map[string]float64) {
		issues = append(issues, issue{code: code, item: item, subject: subject, msg: msg, numbers: numbers})
	}
	var patchErr error
	patchErrItem := -1
	// the lowest own time and glue each service reaches, over the items so far (the v1 check accumulates)
	ds, glue := map[int]float64{}, map[int]float64{}
	unsigned := 0
	seenRec := map[string]bool{}
	var doubts []issue
	shown := sanitize.Services(topo.Names())
	for k, it := range s.Items {
		i, ambiguous := nodeOf(topo, shown, it)
		if ambiguous {
			add(contract.ChangeAmbiguousService, k, it.Service, fmt.Sprintf("%s: the views show more than one service as %q",
				it.Op, it.Service), nil)
			continue
		}
		if it.Service == "" || i < 0 {
			msg := fmt.Sprintf("%s: unknown service %q (services: %s)", it.Op, it.Service, strings.Join(targets, ", "))
			if it.patch != "" {
				msg = fmt.Sprintf("--patch: unknown service in %q (services: %s)", it.patch, strings.Join(targets, ", "))
			}
			add(contract.ChangeUnknownService, k, it.Service, msg, nil)
			continue
		}
		if it.patchErr != nil {
			if patchErrItem < 0 {
				patchErr, patchErrItem = it.patchErr, k
			}
			continue
		}
		if parsedFor(s.parsed, k) {
			continue
		}
		if SignOf(it.Op) == SignUnsigned && !it.Value.IsPoint() {
			unsigned++ // counted whether or not this version applies the operation
		}
		if !Applies(it.Op) {
			add(contract.ChangeUnsupportedOp, k, it.Service, fmt.Sprintf("%s: this version cannot apply %s (it applies %s, %s, %s and %s)",
				it.Service, it.Op, OpOwnMs, OpOwnPct, OpWorkers, OpLoadScale), nil)
			continue
		}
		if it.Value.Lo > it.Value.Hi {
			add(contract.ChangeRangeInverted, k, it.Service, fmt.Sprintf("%s %s: the range %v..%v has lo above hi",
				it.Service, it.Op, it.Value.Lo, it.Value.Hi), map[string]float64{"lo": it.Value.Lo, "hi": it.Value.Hi})
			continue
		}
		sv := topo.Services[i]
		switch it.Op {
		case OpWorkers:
			if sv.Delay || inf.Stats[i].Stage {
				add(contract.ChangeUnsupportedOp, k, it.Service, fmt.Sprintf("%s has no workers to change: it is %s",
					it.Service, map[bool]string{true: "an outside delay", false: "a node of the call structure"}[sv.Delay]), nil)
				continue
			}
		case OpLoadScale:
			if _, ok := topo.Entry[i]; !ok {
				add(contract.ChangeUnsupportedOp, k, it.Service, fmt.Sprintf("load_scale scales an entry's requests; %s is not an entry",
					it.Service), nil)
				continue
			}
		case OpOwnMs:
			ds[i] += it.Value.Lo
			if sv.S+ds[i] < 0 {
				msg := fmt.Sprintf("%s: own_ms %v would make its service time negative", it.Service, it.Value.Lo)
				if it.patch != "" {
					msg = fmt.Sprintf("--patch: %s would get a negative service time", it.Service)
				}
				add(contract.ChangeNegativeTime, k, it.Service, msg, map[string]float64{"own_ms": sv.S, "change_ms": ds[i]})
			}
		case OpOwnPct:
			ds[i] += sv.S * it.Value.Lo / 100
			glue[i] += sv.Glue * it.Value.Lo / 100
			switch {
			case sv.S+ds[i] < 0:
				msg := fmt.Sprintf("%s: own_pct %v would make its service time negative", it.Service, it.Value.Lo)
				if it.patch != "" {
					msg = fmt.Sprintf("--patch: %s would get a negative service time", it.Service)
				}
				add(contract.ChangeNegativeTime, k, it.Service, msg, map[string]float64{"own_ms": sv.S, "change_ms": ds[i]})
			case sv.Glue+glue[i] < 0:
				msg := fmt.Sprintf("%s: own_pct %v would make its glue time negative", it.Service, it.Value.Lo)
				if it.patch != "" {
					msg = fmt.Sprintf("--patch: %s would get a negative glue time", it.Service)
				}
				add(contract.ChangeNegativeTime, k, it.Service, msg, map[string]float64{"glue_ms": sv.Glue, "change_ms": glue[i]})
			}
		}
		// the label
		switch it.Label {
		case LabelDeclared:
		case LabelEstimatedMicrobench:
			add(contract.ChangeMicrobenchUnvalidated, k, it.Service, fmt.Sprintf("%s: a microbenchmark delta is accepted for "+
				"research only, until microbenchmarks are validated against measured differences", it.Service), nil)
		case LabelMeasuredAB:
			named := it
			named.Service = sv.Name // the record names the service as the traces wrote it
			rec, svc, why := measured(named, recs)
			if why != "" {
				add(contract.ChangeLabelNotMinted, k, it.Service, fmt.Sprintf("%s: measured-ab %s", it.Service, why), nil)
				continue
			}
			key := it.Evidence[0] + "\x00" + sv.Name
			if seenRec[key] {
				continue
			}
			seenRec[key] = true
			if svc.CallsChanged {
				doubts = append(doubts, issue{code: contract.ProfileStructureChanged, item: k, subject: it.Service})
			}
			if svc.VarianceChanged {
				doubts = append(doubts, issue{code: contract.ProfileVarianceChanged, item: k, subject: it.Service,
					numbers: map[string]float64{"cs2_delta": svc.OwnCS2.Delta, "cs2_se": svc.OwnCS2.SE}})
			}
			if !rec.SelfReportConsistent && !seenRec[it.Evidence[0]] {
				doubts = append(doubts, issue{code: contract.ProfileSelfReportMismatch, item: k})
			}
			if !seenRec[it.Evidence[0]] {
				for _, f := range rec.Findings {
					if f.Level != contract.Refuse {
						doubts = append(doubts, issue{code: f.Code, item: k, subject: f.Subject, numbers: f.Numbers})
					}
				}
			}
			seenRec[it.Evidence[0]] = true
		default:
			add(contract.ChangeLabelNotMinted, k, it.Service, fmt.Sprintf("%s: the label %s needs a record this version "+
				"can find and recompute; only declared and measured-ab (with its A/B record) are accepted", it.Service, it.Label), nil)
		}
	}
	if unsigned > MaxUnsignedRanges {
		add(contract.ChangeTooManyRanges, -1, "", fmt.Sprintf("%d unsigned ranged items; at most %d", unsigned, MaxUnsignedRanges),
			map[string]float64{"unsigned_ranges": float64(unsigned), "limit": MaxUnsignedRanges})
	}
	issues = append(issues, doubts...)
	if patchErr != nil {
		// an unreadable value is refused before any refusal of a later item, after those of earlier items
		for _, is := range issues {
			if contract.NewFinding(is.code).Level == contract.Refuse && is.item < patchErrItem && is.item >= 0 {
				return issues, nil, nil
			}
		}
		return issues, patchErr, nil
	}
	return issues, nil, nil
}

// nodeOf is the node of the topology an item names: for an item of a change set, the node the views show by that name,
// else the one of that name as the traces wrote it (sanitize.Resolve), so that a caller can name a node whose name the
// views replace; for a --patch item, only the latter, as rhobound-cli read a patch. It returns -1 for none, and
// ambiguous true when the views show two nodes by the name.
func nodeOf(topo *model.Topology, shown map[string]sanitize.Shown, it Item) (i int, ambiguous bool) {
	if it.patch != "" {
		return topo.Index(it.Service), false
	}
	node, ok, ambiguous := sanitize.Resolve(shown, it.Service)
	if !ok {
		return -1, ambiguous
	}
	return topo.Index(node), false
}

func parsedFor(parsed []issue, item int) bool {
	for _, p := range parsed {
		if p.item == item {
			return true
		}
	}
	return false
}

// measured resolves a measured-ab item to its record and the record's row for the item's service, or says why it
// cannot: no evidence, a record the store does not hold, a service the record does not measure, another operation,
// or a value that is not the record's own-time delta.
func measured(it Item, recs Records) (*abdiff.Record, *abdiff.Service, string) {
	if len(it.Evidence) != 1 {
		return nil, nil, "must cite exactly one A/B record (evidence)"
	}
	if recs == nil {
		return nil, nil, "cites a record, and no record store is open"
	}
	rec, ok := recs.AB(it.Evidence[0])
	if !ok {
		return nil, nil, "cites " + it.Evidence[0] + ", which is not an A/B record this tool computed"
	}
	if it.Op != OpOwnMs {
		return nil, nil, "applies to own_ms only"
	}
	for k := range rec.Services {
		svc := &rec.Services[k]
		if svc.Service != it.Service {
			continue
		}
		if it.Value != Point(svc.OwnMs.Delta) {
			return nil, nil, fmt.Sprintf("value %v..%v is not the record's own-time delta %v", it.Value.Lo, it.Value.Hi, svc.OwnMs.Delta)
		}
		for _, f := range rec.Findings {
			if f.Level == contract.Refuse {
				return nil, nil, "cites a record that refused its run (" + f.Code + ")"
			}
		}
		return rec, svc, ""
	}
	return nil, nil, "cites a record that does not measure " + it.Service
}

// Resolve returns the set the engine applies to the fit r: a copy in which every item names its service as the traces
// wrote it (nodeOf: a caller may name it as the views show it), and every measured-ab item's value is its record's
// delta +-2 standard errors (the errors by batch means, as the record computed them). It expects a set Validate
// admitted.
func (s *Set) Resolve(r *fit.Record, recs Records) (*Set, error) {
	inf, err := r.Inferred()
	if err != nil {
		return nil, err
	}
	topo := inf.Topology
	shown := sanitize.Services(topo.Names())
	out := &Set{Schema: s.Schema, Fit: s.Fit, Items: make([]Item, len(s.Items))}
	for k, it := range s.Items {
		if i, _ := nodeOf(topo, shown, it); i >= 0 {
			it.Service = topo.Services[i].Name
		}
		it.Evidence = append([]string(nil), it.Evidence...)
		if it.Label == LabelMeasuredAB {
			_, svc, why := measured(it, recs)
			if why != "" {
				return nil, fmt.Errorf("change: item %d: measured-ab %s", k, why)
			}
			d := svc.OwnMs
			it.Value = Range{Lo: d.Delta - 2*d.SE, Hi: d.Delta + 2*d.SE}
		}
		out.Items[k] = it
	}
	return out, nil
}

// patchTargets are the services a patch can name, for the message that lists them: the topology's names without the
// zero-time nodes the inference adds for the call structure (stage:S:n and shape:S:n), which are not services.
func patchTargets(topo *model.Topology) []string {
	var out []string
	for _, n := range topo.Names() {
		if !strings.HasPrefix(n, "stage:") && !strings.HasPrefix(n, "shape:") {
			out = append(out, n)
		}
	}
	return out
}

func sortedKeys(m map[string]float64) []string {
	out := make([]string, 0, len(m))
	for k := range m {
		out = append(out, k)
	}
	sort.Strings(out)
	return out
}

// Digest is the set's content id, the change_hash of report v2 and of the prediction view: contract.DigestOf of the set
// as read (before Resolve widens measured items), so that one request always has one hash.
func (s *Set) Digest() (string, error) {
	return contract.DigestOf(s)
}
