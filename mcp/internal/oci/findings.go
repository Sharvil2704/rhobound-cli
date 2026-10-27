// SPDX-License-Identifier: Apache-2.0

package oci

import (
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"regexp"
)

// The codes this package raises, from the one registry (DATA.md 9.5 and 19).
const (
	CodeNotFound           = "profile.not_found"
	CodeDigestUnresolvable = "profile.digest_unresolvable"
	CodeMediaTypeParameter = "profile.media_type_parameter"
	CodeBadSignature       = "profile.bad_signature"
	CodePredicateType      = "profile.predicate_type"
	CodeScopeNotMean       = "profile.scope_not_mean"
	CodeNoVariance         = "profile.no_variance"
	CodeSubjectMismatch    = "profile.subject_mismatch"
	CodeBaselineNotRunning = "profile.baseline_not_running"
	CodeStale              = "profile.stale"
	CodeTimeDisagrees      = "profile.time_disagrees"
	CodeHardwareMismatch   = "profile.hardware_mismatch"
	CodeLoadOutOfRange     = "profile.load_out_of_range"
	CodeTooFewVisits       = "profile.too_few_visits"
	CodeLevelDrift         = "profile.level_drift"
	CodeStructureChanged   = "profile.structure_changed"
	CodeVarianceChanged    = "profile.variance_changed"
	CodeSelfReportMismatch = "profile.self_report_mismatch"
	CodeErrorsDiffer       = "profile.errors_differ"
)

// Codes for three field rules of DATA.md 9.2 that the registry does not name yet. They are drafts: the registry
// (and DATA.md 19) must list them before the predicate is frozen.
const (
	CodeNoStructure          = "profile.no_structure"           // calls per visit missing for an arm
	CodeNoOutsideMeasurement = "profile.no_outside_measurement" // client latency or CPU per visit missing
	CodeLocationsPresent     = "profile.locations_present"      // an ARN, account id, bucket or URL in the predicate
)

// Finding is a finding of the data contract (defs.v1.json Finding).
type Finding struct {
	Code             string             `json:"code"`
	Level            string             `json:"level"`
	Subject          string             `json:"subject,omitempty"`
	SubjectUntrusted bool               `json:"subject_untrusted,omitempty"`
	Numbers          map[string]float64 `json:"numbers,omitempty"`
	Examples         []string           `json:"examples,omitempty"`
	Fix              string             `json:"fix"`
}

// CodedError is a refusal: a finding of level refuse with its reason.
type CodedError struct {
	Finding Finding
	Reason  string
}

func (e *CodedError) Error() string { return e.Finding.Code + ": " + e.Reason }

// RefusalJSON returns the refusal as a defs.v1.json Refusal object.
func (e *CodedError) RefusalJSON() []byte {
	b, _ := json.Marshal(struct {
		Code    string             `json:"code"`
		Reason  string             `json:"reason"`
		Fix     string             `json:"fix"`
		Subject string             `json:"subject,omitempty"`
		Numbers map[string]float64 `json:"numbers,omitempty"`
	}{e.Finding.Code, e.Reason, e.Finding.Fix, e.Finding.Subject, e.Finding.Numbers})
	return b
}

func refusal(code, reason, fix string) *CodedError {
	return &CodedError{Finding: Finding{Code: code, Level: "refuse", Fix: fix}, Reason: reason}
}

var nameRE = regexp.MustCompile(`^[A-Za-z0-9._:/@-]{1,128}$`)

// name sanitizes a name for a finding's subject or examples (ARCHITECTURE.md 5.9): a string outside the Name
// charset, or longer than 128, becomes svc_<first 8 hex of its sha256>, flagged as untrusted.
func name(s string) (string, bool) {
	if nameRE.MatchString(s) {
		return s, false
	}
	sum := sha256.Sum256([]byte(s))
	return "svc_" + hex.EncodeToString(sum[:4]), true
}
