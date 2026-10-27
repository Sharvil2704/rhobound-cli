// SPDX-License-Identifier: Apache-2.0

package oci

import (
	"context"
	"math"
	"sort"
	"time"
)

// Expect is what a profile is checked against: the image about to run, the image the fit saw running, the
// clock, and production's environment and load. A zero field is not checked.
type Expect struct {
	Candidate Digest       // the candidate's platform manifest (the attestation's subject)
	Baseline  Digest       // the platform manifest the fit saw running
	Now       time.Time    // freshness
	Witness   time.Time    // the time of the witness row written at signing
	Env       *Environment // production's environment record (from the cluster dump)
	PodRPS    float64      // production's per-pod rate after the change
	MaxRho    float64      // the utilization limit; 0 means 0.85
	MarginMs  float64      // the gate's margin, for sizing; 0 means the profile's own sizing.margin_ms
}

// Thresholds of the checks [D].
const (
	// TimeTolerance is how far the measured time may lie from the witness row, or ahead of the clock.
	TimeTolerance = 10 * time.Minute
	// RateSlack widens the measured levels' per-pod rates on each side.
	RateSlack = 0.10
	// CallsTolerance is the difference in calls per visit read as a change of structure.
	CallsTolerance = 0.05
	// ErrorShareTolerance is one point of error share.
	ErrorShareTolerance = 0.01
)

// Check runs the checks of DATA.md 9.5 that need no signature, in its order: subject and baseline binding (#7),
// freshness (#8), hardware (#9), the operating point (#10), sizing (#12), load dependence (#13), structure (#14),
// variance (#15), the outside measurement (#16) and error shares (#18). Refusals come first in the result;
// doubts make a profile's delta inconclusive. Signature, signer and allow-list checks (#3-#6) belong to a
// Verifier.
func Check(p *Profile, e Expect) []Finding {
	pr := &p.Predicate
	if len(p.Subject) != 1 || len(pr.Levels) == 0 {
		// ParseProfile never returns such a profile
		return []Finding{{Code: CodePredicateType, Level: "refuse", Fix: "check profiles that ParseProfile returned"}}
	}
	subject, untrusted := name(pr.Service)
	var out []Finding
	add := func(code, level, fix string, numbers map[string]float64, examples ...string) {
		out = append(out, Finding{Code: code, Level: level, Subject: subject, SubjectUntrusted: untrusted,
			Numbers: numbers, Examples: examples, Fix: fix})
	}
	arm := func(role string) string {
		for _, a := range pr.Arms {
			if a.Role == role {
				return a.Digest.SHA256
			}
		}
		return ""
	}

	// #7 the subject is the candidate about to run; the baseline arm is what the fit saw running
	if e.Candidate != "" && (p.Subject[0].Digest.SHA256 != e.Candidate.Hex() || arm("candidate") != e.Candidate.Hex()) {
		add(CodeSubjectMismatch, "refuse", "profile the candidate's platform manifest, the digest about to run", nil)
	}
	if e.Baseline != "" && arm("baseline") != e.Baseline.Hex() {
		add(CodeBaselineNotRunning, "refuse", "profile against the digest that runs in production now", nil)
	}
	// #8 freshness, and agreement with the witness row
	if !e.Now.IsZero() {
		if age := e.Now.Sub(pr.MeasuredAt); age > time.Duration(pr.ValidForDays)*24*time.Hour {
			add(CodeStale, "refuse", "measure again", map[string]float64{"age_days": math.Floor(age.Hours() / 24),
				"valid_for_days": float64(pr.ValidForDays)})
		}
		if pr.MeasuredAt.Sub(e.Now) > TimeTolerance {
			add(CodeTimeDisagrees, "refuse", "the measured time lies in the future: check the harness clock", nil)
		}
	}
	if !e.Witness.IsZero() && math.Abs(pr.MeasuredAt.Sub(e.Witness).Seconds()) > TimeTolerance.Seconds() {
		add(CodeTimeDisagrees, "refuse", "the measured time disagrees with the witness row written at signing",
			map[string]float64{"seconds_apart": math.Round(math.Abs(pr.MeasuredAt.Sub(e.Witness).Seconds()))})
	}
	// #9 hardware: instance type, CPU model, CPU limit, container spec, platform
	if e.Env != nil {
		var differ []string
		m, w := pr.Environment, *e.Env
		for _, f := range []struct {
			field string
			same  bool
		}{
			{"platform", m.Platform == w.Platform},
			{"instance_type", m.InstanceType == w.InstanceType},
			{"cpu_model", m.CPUModel == w.CPUModel},
			{"cpu_limit_millicores", m.CPULimitMillicores == w.CPULimitMillicores},
			{"container_spec", m.ContainerSpec.SHA256 == w.ContainerSpec.SHA256},
		} {
			if !f.same {
				differ = append(differ, f.field)
			}
		}
		if len(differ) > 0 {
			add(CodeHardwareMismatch, "refuse", "profile on production's instance type with its CPU limit and container spec",
				map[string]float64{"fields": float64(len(differ))}, differ[:min(len(differ), 3)]...)
		}
	}
	// #10 the operating point lies within the measured levels (matched on per-pod rate) and below the limit
	levels := append([]Level(nil), pr.Levels...)
	sort.Slice(levels, func(i, j int) bool { return levels[i].PodRPS < levels[j].PodRPS })
	if e.PodRPS > 0 {
		lo, hi := levels[0].PodRPS*(1-RateSlack), levels[len(levels)-1].PodRPS*(1+RateSlack)
		maxRho := e.MaxRho
		if maxRho <= 0 {
			maxRho = 0.85
		}
		near := nearest(levels, e.PodRPS)
		if e.PodRPS < lo || e.PodRPS > hi || near.Candidate.Utilization >= maxRho {
			add(CodeLoadOutOfRange, "refuse", "measure a level at production's per-pod rate, below the utilization limit",
				map[string]float64{"pod_rps": e.PodRPS, "measured_lo": levels[0].PodRPS,
					"measured_hi": levels[len(levels)-1].PodRPS, "candidate_utilization": near.Candidate.Utilization})
		}
	}
	// #12 visits per arm per level for a +-2 SE band of half-width m: n = 8 cs2 S^2 / m^2 (DATA.md 9.3)
	m := e.MarginMs
	if m <= 0 {
		m = pr.Sizing.MarginMs
	}
	if m > 0 {
		short, worst := 0, 0.0
		for _, l := range levels {
			for _, a := range []ArmLevel{l.Baseline, l.Candidate} {
				need := 8 * a.OwnCS2 * a.OwnMs * a.OwnMs / (m * m)
				if float64(a.Visits) < need {
					short++
					worst = math.Max(worst, math.Ceil(need))
				}
			}
		}
		if short > 0 {
			add(CodeTooFewVisits, "refuse", "measure each level longer: n = 8 cs2 S^2 / m^2 visits per arm",
				map[string]float64{"arm_levels_short": float64(short), "visits_needed": worst, "margin_ms": m})
		}
	}
	// #13 load dependence: pooling across levels needs flatness shown; else the nearest level only
	if len(levels) > 1 && !pr.LoadDependence.FlatShown {
		add(CodeLevelDrift, "doubt", "use the level nearest production's per-pod rate, or show flatness by an equivalence test",
			map[string]float64{"levels": float64(len(levels))})
	}
	var structure, variance, selfReport, errs int
	for _, l := range levels {
		d := l.Delta
		// #14 structure: calls per visit equal between arms
		if d.CallsChanged || !sameCalls(l.Baseline.Calls, l.Candidate.Calls) {
			structure++
		}
		// #15 the cs2 difference within 2 SE
		if math.Abs(d.OwnCS2) > 2*d.OwnCS2SE {
			variance++
		}
		// #16 the outside measurement agrees with the spans: the harness's own judgement, and no significant
		// difference of opposite sign between the client's latency and the span-derived times
		client := l.Candidate.ClientLatencyMs - l.Baseline.ClientLatencyMs
		clientSE := math.Hypot(l.Candidate.ClientLatencySEMs, l.Baseline.ClientLatencySEMs)
		spans, spansSE := d.OwnMs+d.GlueMs, math.Hypot(d.OwnSEMs, d.GlueSEMs)
		if !d.SelfReportConsistent || (client > 2*clientSE && spans < -2*spansSE) || (client < -2*clientSE && spans > 2*spansSE) {
			selfReport++
		}
		// #18 error shares within one point
		if math.Abs(l.Candidate.ErrorShare-l.Baseline.ErrorShare) > ErrorShareTolerance {
			errs++
		}
	}
	levelsN := func(n int) map[string]float64 { return map[string]float64{"levels": float64(n)} }
	if structure > 0 {
		add(CodeStructureChanged, "doubt", "the change is structural: describe it as a structural change; its own-time delta is never applied alone", levelsN(structure))
	}
	if variance > 0 {
		add(CodeVarianceChanged, "doubt", "the service time's variability changed: inconclusive until the engine has a variance patch", levelsN(variance))
	}
	if selfReport > 0 {
		add(CodeSelfReportMismatch, "doubt", "the candidate's spans disagree with its latency measured at the load generator: check its instrumentation", levelsN(selfReport))
	}
	if errs > 0 {
		add(CodeErrorsDiffer, "doubt", "fix the errors, or compare arms with equal error shares", levelsN(errs))
	}
	sort.SliceStable(out, func(i, j int) bool { return out[i].Level == "refuse" && out[j].Level != "refuse" })
	return out
}

func nearest(levels []Level, rps float64) Level {
	best := levels[0]
	for _, l := range levels[1:] {
		if math.Abs(l.PodRPS-rps) < math.Abs(best.PodRPS-rps) {
			best = l
		}
	}
	return best
}

func sameCalls(a, b []Call) bool {
	key := func(cs []Call) map[string]Call {
		m := map[string]Call{}
		for _, c := range cs {
			m[c.Callee] = c
		}
		return m
	}
	ma, mb := key(a), key(b)
	if len(ma) != len(mb) {
		return false
	}
	for k, x := range ma {
		y, ok := mb[k]
		if !ok || x.Parallel != y.Parallel || x.Async != y.Async || math.Abs(x.PerVisit-y.PerVisit) > CallsTolerance {
			return false
		}
	}
	return true
}

// Verifier verifies a signed envelope and returns the statement it carries.
type Verifier interface {
	Verify(ctx context.Context, envelope []byte) (statement []byte, err error)
}

// RefuseUnsigned is the only Verifier of this version: signature verification comes with the profile harness,
// after the transfer study (DATA.md 9), so every envelope is refused as profile.bad_signature and no profile
// becomes a measured-paired change.
var RefuseUnsigned Verifier = refuseUnsigned{}

type refuseUnsigned struct{}

func (refuseUnsigned) Verify(ctx context.Context, envelope []byte) ([]byte, error) {
	return nil, refusal(CodeBadSignature, "signature verification is not built in this version; no profile is accepted",
		"use an A/B measurement (fit_start with ab) until verified profiles are supported")
}
