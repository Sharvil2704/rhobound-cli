// SPDX-License-Identifier: Apache-2.0

package gate

import (
	"fmt"
	"regexp"
)

// ReadinessSchema is the schema id of a readiness record.
const ReadinessSchema = "rhobound.readiness/v1"

// Readiness is an environment's readiness record (rhobound.readiness/v1; ARCHITECTURE.md 6.6): the four conditions
// under which enforcement is earned. Each condition is meant to be recomputed from ledger records, never typed in, and
// this version has no ledger: the gate parses the record, checks its shape, echoes it in gate.json and uses only its
// A/A floor, which can only make a verdict stricter (rule 12). Every verdict stays advisory whatever it says.
type Readiness struct {
	Schema         string         `json:"schema"`
	Env            string         `json:"env"`
	AAFloor        AAFloor        `json:"aa_floor"`
	Seeded         Seeded         `json:"seeded"`
	Transfer       Transfer       `json:"transfer"`
	RateCrossCheck RateCrossCheck `json:"rate_cross_check"`
}

// AAFloor is the A/A noise floor: pairs of the same image rebuilt and redeployed, and the false-delta floor by entry.
type AAFloor struct {
	Pairs   int                `json:"pairs"`
	FloorMs map[string]float64 `json:"floor_ms"`
	Records []string           `json:"records"`
}

// MinAAPairs is the number of A/A pairs from which the floor counts (ARCHITECTURE.md 6.6).
const MinAAPairs = 10

// Seeded is the seeded-regression result.
type Seeded struct {
	N           int      `json:"n"`
	Exceedances int      `json:"exceedances"`
	NominalRate float64  `json:"nominal_rate"`
	PValue      float64  `json:"p_value"`
	Passed      bool     `json:"passed"`
	Records     []string `json:"records"`
}

// Transfer is the transfer study's result, for gates fed by measured labels.
type Transfer struct {
	Required bool   `json:"required"`
	Passed   bool   `json:"passed"`
	Record   string `json:"record,omitempty"`
}

// RateCrossCheck compares the trace-derived entry rate with an outside count on every gated window.
type RateCrossCheck struct {
	Windows    int     `json:"windows"`
	MaxDiffPct float64 `json:"max_diff_pct"`
	Passed     bool    `json:"passed"`
}

var (
	envRE    = regexp.MustCompile(`^[a-z0-9-]{1,40}$`)
	digestRE = regexp.MustCompile(`^sha256:[0-9a-f]{64}$`)
)

// ParseReadiness reads a readiness record and checks its shape (readiness.v1.json). A record that does not match is
// a tool error: the gate cannot run on it.
func ParseReadiness(b []byte) (*Readiness, error) {
	var w struct {
		Schema  *string `json:"schema"`
		Env     *string `json:"env"`
		AAFloor *struct {
			Pairs   *int               `json:"pairs"`
			FloorMs map[string]float64 `json:"floor_ms"`
			Records []string           `json:"records"`
		} `json:"aa_floor"`
		Seeded *struct {
			N           *int     `json:"n"`
			Exceedances *int     `json:"exceedances"`
			NominalRate *float64 `json:"nominal_rate"`
			PValue      *float64 `json:"p_value"`
			Passed      *bool    `json:"passed"`
			Records     []string `json:"records"`
		} `json:"seeded"`
		Transfer *struct {
			Required *bool  `json:"required"`
			Passed   *bool  `json:"passed"`
			Record   string `json:"record"`
		} `json:"transfer"`
		RateCrossCheck *struct {
			Windows    *int     `json:"windows"`
			MaxDiffPct *float64 `json:"max_diff_pct"`
			Passed     *bool    `json:"passed"`
		} `json:"rate_cross_check"`
	}
	if err := strict(b, &w); err != nil {
		return nil, fmt.Errorf("readiness: %v", err)
	}
	bad := func(what string) error { return fmt.Errorf("readiness: %s", what) }
	switch {
	case w.Schema == nil || *w.Schema != ReadinessSchema:
		return nil, bad("schema must be " + ReadinessSchema)
	case w.Env == nil || !envRE.MatchString(*w.Env):
		return nil, bad("env must match ^[a-z0-9-]{1,40}$")
	case w.AAFloor == nil || w.AAFloor.Pairs == nil || w.AAFloor.FloorMs == nil || w.AAFloor.Records == nil:
		return nil, bad("aa_floor needs pairs, floor_ms and records")
	case w.Seeded == nil || w.Seeded.N == nil || w.Seeded.Exceedances == nil || w.Seeded.NominalRate == nil ||
		w.Seeded.PValue == nil || w.Seeded.Passed == nil || w.Seeded.Records == nil:
		return nil, bad("seeded needs n, exceedances, nominal_rate, p_value, passed and records")
	case w.Transfer == nil || w.Transfer.Required == nil || w.Transfer.Passed == nil:
		return nil, bad("transfer needs required and passed")
	case w.RateCrossCheck == nil || w.RateCrossCheck.Windows == nil || w.RateCrossCheck.MaxDiffPct == nil ||
		w.RateCrossCheck.Passed == nil:
		return nil, bad("rate_cross_check needs windows, max_diff_pct and passed")
	}
	r := &Readiness{Schema: *w.Schema, Env: *w.Env,
		AAFloor: AAFloor{Pairs: *w.AAFloor.Pairs, FloorMs: w.AAFloor.FloorMs, Records: w.AAFloor.Records},
		Seeded: Seeded{N: *w.Seeded.N, Exceedances: *w.Seeded.Exceedances, NominalRate: *w.Seeded.NominalRate,
			PValue: *w.Seeded.PValue, Passed: *w.Seeded.Passed, Records: w.Seeded.Records},
		Transfer: Transfer{Required: *w.Transfer.Required, Passed: *w.Transfer.Passed, Record: w.Transfer.Record},
		RateCrossCheck: RateCrossCheck{Windows: *w.RateCrossCheck.Windows, MaxDiffPct: *w.RateCrossCheck.MaxDiffPct,
			Passed: *w.RateCrossCheck.Passed}}
	switch {
	case r.AAFloor.Pairs < 0 || r.Seeded.N < 0 || r.Seeded.Exceedances < 0 || r.RateCrossCheck.Windows < 0:
		return nil, bad("counts cannot be negative")
	case !(r.Seeded.NominalRate >= 0 && r.Seeded.NominalRate <= 1) || !(r.Seeded.PValue >= 0 && r.Seeded.PValue <= 1):
		return nil, bad("nominal_rate and p_value are in [0, 1]")
	case !(r.RateCrossCheck.MaxDiffPct >= 0):
		return nil, bad("max_diff_pct cannot be negative")
	case r.Transfer.Record != "" && !digestRE.MatchString(r.Transfer.Record):
		return nil, bad("transfer.record must be a sha256: digest")
	}
	for e, v := range r.AAFloor.FloorMs {
		if !(v >= 0) {
			return nil, bad(fmt.Sprintf("aa_floor.floor_ms of %s cannot be negative", safe(e)))
		}
	}
	for _, d := range append(append([]string{}, r.AAFloor.Records...), r.Seeded.Records...) {
		if !digestRE.MatchString(d) {
			return nil, bad("records must be sha256: digests")
		}
	}
	return r, nil
}
