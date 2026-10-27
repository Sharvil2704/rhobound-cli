// SPDX-License-Identifier: Apache-2.0

package oci

import (
	"bytes"
	"encoding/json"
	"fmt"
	"regexp"
	"sort"
	"time"
)

// The statement's types, compared as exact strings (DATA.md 9.2).
const (
	StatementType = "https://in-toto.io/Statement/v1"
	PredicateType = "https://github.com/Sharvil2704/rhobound-cli/blob/perf-profile-v0.1/docs/mcp/DATA.md#perf-profile-v0.1"
)

// DigestSet is an in-toto digest set; only sha256 is read.
type DigestSet struct {
	SHA256 string `json:"sha256"`
}

// Profile is a perf-profile/v0.1 statement (DATA.md 9.2, perf-profile.v0.1.json).
type Profile struct {
	Type    string `json:"_type"`
	Subject []struct {
		Name   string    `json:"name"`
		Digest DigestSet `json:"digest"`
	} `json:"subject"`
	PredicateType string    `json:"predicateType"`
	Predicate     Predicate `json:"predicate"`
}

// Predicate is the profile itself.
type Predicate struct {
	Scope struct {
		Statistic      string   `json:"statistic"`
		Load           string   `json:"load"`
		MaxUtilization float64  `json:"max_utilization"`
		NotCovered     []string `json:"not_covered"`
	} `json:"scope"`
	Service string `json:"service"`
	Arms    []struct {
		Role   string    `json:"role"`
		Digest DigestSet `json:"digest"`
	} `json:"arms"`
	Pairing struct {
		Mode  string `json:"mode"`
		RunID string `json:"run_id"`
	} `json:"pairing"`
	Tool struct {
		Name    string    `json:"name"`
		Version string    `json:"version"`
		Digest  DigestSet `json:"digest"`
		GOARCH  string    `json:"goarch"`
	} `json:"tool"`
	Harness struct {
		Image        DigestSet `json:"image"`
		Config       DigestSet `json:"config"`
		Loadgen      DigestSet `json:"loadgen"`
		Collector    DigestSet `json:"collector"`
		Arrivals     string    `json:"arrivals"`
		WarmupS      float64   `json:"warmup_s"`
		Dependencies string    `json:"dependencies"`
	} `json:"harness"`
	Environment Environment `json:"environment"`
	Sizing      struct {
		MarginMs float64 `json:"margin_ms"`
		Rule     string  `json:"rule"`
		SEMethod string  `json:"se_method"`
	} `json:"sizing"`
	Levels         []Level `json:"levels"`
	LoadDependence struct {
		Test           string  `json:"test"`
		MarginPctOfOwn float64 `json:"margin_pct_of_own"`
		FlatShown      bool    `json:"flat_shown"`
	} `json:"load_dependence"`
	HarnessAA struct {
		FalseDeltaQ95Ms float64   `json:"false_delta_q95_ms"`
		Record          DigestSet `json:"record"`
	} `json:"harness_aa"`
	Captures struct {
		Manifest DigestSet `json:"manifest"`
	} `json:"captures"`
	MeasuredAt   time.Time `json:"measured_at"`
	ValidForDays int       `json:"valid_for_days"`
}

// Environment is where a profile was measured, or production's environment record to compare it with.
type Environment struct {
	Platform           string    `json:"platform"`
	InstanceType       string    `json:"instance_type"`
	CPUModel           string    `json:"cpu_model"`
	Kernel             string    `json:"kernel"`
	CPULimitMillicores int       `json:"cpu_limit_millicores"`
	MemoryLimitMiB     int       `json:"memory_limit_mib"`
	ContainerSpec      DigestSet `json:"container_spec"`
}

// Level is one load level, measured in both arms.
type Level struct {
	PodRPS    float64  `json:"pod_rps"`
	Baseline  ArmLevel `json:"baseline"`
	Candidate ArmLevel `json:"candidate"`
	Delta     struct {
		OwnMs                float64 `json:"own_ms"`
		OwnSEMs              float64 `json:"own_se_ms"`
		OwnCS2               float64 `json:"own_cs2"`
		OwnCS2SE             float64 `json:"own_cs2_se"`
		GlueMs               float64 `json:"glue_ms"`
		GlueSEMs             float64 `json:"glue_se_ms"`
		CallsChanged         bool    `json:"calls_changed"`
		SelfReportConsistent bool    `json:"self_report_consistent"`
	} `json:"delta"`
}

// ArmLevel is one arm at one level.
type ArmLevel struct {
	Visits                  int64   `json:"visits"`
	Utilization             float64 `json:"utilization"`
	UtilizationIsUpperBound bool    `json:"utilization_is_upper_bound"`
	OwnMs                   float64 `json:"own_ms"`
	OwnSEMs                 float64 `json:"own_se_ms"`
	OwnCS2                  float64 `json:"own_cs2"`
	OwnCS2SE                float64 `json:"own_cs2_se"`
	GlueMs                  float64 `json:"glue_ms"`
	GlueSEMs                float64 `json:"glue_se_ms"`
	Calls                   []Call  `json:"calls"`
	Workers                 struct {
		Value      int  `json:"value"`
		LowerBound bool `json:"lower_bound"`
	} `json:"workers"`
	ErrorShare        float64 `json:"error_share"`
	ClientLatencyMs   float64 `json:"client_latency_ms"`
	ClientLatencySEMs float64 `json:"client_latency_se_ms"`
	CPUMsPerVisit     float64 `json:"cpu_ms_per_visit"`
}

// Call is a call per visit to one callee.
type Call struct {
	Callee   string  `json:"callee"`
	PerVisit float64 `json:"per_visit"`
	Parallel bool    `json:"parallel"`
	Async    bool    `json:"async"`
}

// the keys an arm at a level must carry, by the rule that requires them (DATA.md 9.2)
var (
	varianceKeys = []string{"own_cs2", "own_cs2_se"}
	outsideKeys  = []string{"client_latency_ms", "client_latency_se_ms", "cpu_ms_per_visit"}
	armKeys      = []string{"visits", "utilization", "utilization_is_upper_bound", "own_ms", "own_se_ms", "glue_ms",
		"glue_se_ms", "workers", "error_share"}
	deltaKeys = []string{"own_ms", "own_se_ms", "glue_ms", "glue_se_ms", "calls_changed", "self_report_consistent"}
	predKeys  = []string{"scope", "service", "arms", "pairing", "tool", "harness", "environment", "sizing", "levels",
		"load_dependence", "harness_aa", "captures", "measured_at", "valid_for_days"}
)

// ParseProfile reads a perf-profile/v0.1 statement and applies the field rules of DATA.md 9.2: variance required
// (profile.no_variance), calls per visit required per arm (profile.no_structure), the outside measurement required
// (profile.no_outside_measurement), no storage location, account id, ARN or URL anywhere in the predicate
// (profile.locations_present), a mean-only scope (profile.scope_not_mean); anything else that is not this
// predicate, in this version, is profile.predicate_type. Every finding refuses; the profile is returned only when
// there is none. Signatures are not this function's concern.
func ParseProfile(b []byte) (*Profile, []Finding) {
	bad := func(code, fix string, examples ...string) []Finding {
		return []Finding{{Code: code, Level: "refuse", Examples: examples, Fix: fix}}
	}
	const fixType = "write an in-toto Statement v1 with the perf-profile/v0.1 predicate, every field as DATA.md 9.2 lists it"
	var raw struct {
		Type          string         `json:"_type"`
		PredicateType string         `json:"predicateType"`
		Predicate     map[string]any `json:"predicate"`
	}
	if err := json.Unmarshal(b, &raw); err != nil || raw.Predicate == nil {
		return nil, bad(CodePredicateType, fixType)
	}
	if raw.Type != StatementType || raw.PredicateType != PredicateType {
		return nil, bad(CodePredicateType, "the predicate type must be exactly "+PredicateType)
	}
	var findings []Finding
	add := func(code, fix string, where []string) {
		if len(where) == 0 {
			return
		}
		f := Finding{Code: code, Level: "refuse", Numbers: map[string]float64{"fields": float64(len(where))}, Fix: fix}
		for _, w := range where[:min(len(where), 3)] {
			n, _ := name(w)
			f.Examples = append(f.Examples, n)
		}
		findings = append(findings, f)
	}
	add(CodeLocationsPresent, "remove storage locations, account ids, ARNs and URLs from the predicate: anyone who can pull the image can read it",
		locations(raw.Predicate, "predicate"))
	missing := missingKeys(raw.Predicate, "predicate", predKeys)
	var noVariance, noCalls, noOutside []string
	levels, _ := raw.Predicate["levels"].([]any)
	for i, l := range levels {
		lv, _ := l.(map[string]any)
		at := fmt.Sprintf("predicate.levels.%d", i)
		for _, role := range []string{"baseline", "candidate"} {
			arm, ok := lv[role].(map[string]any)
			if !ok {
				missing = append(missing, at+"."+role)
				continue
			}
			where := at + "." + role
			noVariance = append(noVariance, missingKeys(arm, where, varianceKeys)...)
			noOutside = append(noOutside, missingKeys(arm, where, outsideKeys)...)
			if calls, ok := arm["calls"]; !ok || calls == nil {
				noCalls = append(noCalls, where+".calls")
			}
			missing = append(missing, missingKeys(arm, where, armKeys)...)
		}
		if d, ok := lv["delta"].(map[string]any); ok {
			noVariance = append(noVariance, missingKeys(d, at+".delta", varianceKeys)...)
			missing = append(missing, missingKeys(d, at+".delta", deltaKeys)...)
		} else {
			missing = append(missing, at+".delta")
		}
	}
	add(CodeNoVariance, "measure and report own_cs2 and own_cs2_se for each arm and level: a mean-only profile cannot be checked for a variance change", noVariance)
	add(CodeNoStructure, "report calls per visit per callee for each arm and level: a structural change must be seen", noCalls)
	add(CodeNoOutsideMeasurement, "report client_latency_ms from the harness-owned load generator and cpu_ms_per_visit from cgroup accounting for each arm and level", noOutside)
	if s, _ := raw.Predicate["scope"].(map[string]any); s != nil && s["statistic"] != "mean" {
		add(CodeScopeNotMean, "profiles are of the mean only", []string{"predicate.scope.statistic"})
	}
	add(CodePredicateType, fixType, missing)
	if len(findings) > 0 {
		return nil, findings
	}
	var p Profile
	dec := json.NewDecoder(bytes.NewReader(b))
	dec.DisallowUnknownFields()
	if err := dec.Decode(&p); err != nil {
		return nil, bad(CodePredicateType, fixType)
	}
	if len(p.Subject) != 1 || !hex64.MatchString(p.Subject[0].Digest.SHA256) || len(p.Predicate.Arms) != 2 ||
		len(p.Predicate.Levels) == 0 || p.Predicate.ValidForDays < 1 || p.Predicate.MeasuredAt.IsZero() {
		return nil, bad(CodePredicateType, fixType)
	}
	roles := map[string]bool{}
	for _, a := range p.Predicate.Arms {
		roles[a.Role] = hex64.MatchString(a.Digest.SHA256)
	}
	if !roles["baseline"] || !roles["candidate"] {
		return nil, bad(CodePredicateType, fixType, "predicate.arms")
	}
	if u := p.Predicate.Scope.MaxUtilization; !(u > 0 && u <= 0.85) {
		return nil, bad(CodePredicateType, "the scope's max_utilization must be above 0 and at most 0.85", "predicate.scope.max_utilization")
	}
	return &p, nil
}

var hex64 = regexp.MustCompile(`^[0-9a-f]{64}$`)

func missingKeys(m map[string]any, at string, keys []string) []string {
	var out []string
	for _, k := range keys {
		if v, ok := m[k]; !ok || v == nil {
			out = append(out, at+"."+k)
		}
	}
	return out
}

var (
	// what a storage location, an account or a cluster looks like in a string
	locationRE = regexp.MustCompile(`(?i)\barn:aws|\bs3://|[a-z][a-z0-9+.-]*://|\bamazonaws\.com\b|\.dkr\.ecr\.|\b[0-9]{12}\b`)
	uuidRE     = regexp.MustCompile(`(?i)\b[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\b`)
)

// locations walks every string of the predicate, keys included, and returns where one looks like a location.
// UUIDs are removed first: their last group can be twelve digits.
func locations(v any, at string) []string {
	var out []string
	switch x := v.(type) {
	case string:
		if locationRE.MatchString(uuidRE.ReplaceAllString(x, "")) {
			out = append(out, at)
		}
	case []any:
		for i, e := range x {
			out = append(out, locations(e, fmt.Sprintf("%s.%d", at, i))...)
		}
	case map[string]any:
		for _, k := range sortedKeys(x) {
			where := at + "." + k
			if n, untrusted := name(k); untrusted || locationRE.MatchString(k) {
				out = append(out, at+"."+n)
				continue
			}
			out = append(out, locations(x[k], where)...)
		}
	}
	return out
}

func sortedKeys(m map[string]any) []string {
	keys := make([]string, 0, len(m))
	for k := range m {
		keys = append(keys, k)
	}
	sort.Strings(keys)
	return keys
}
