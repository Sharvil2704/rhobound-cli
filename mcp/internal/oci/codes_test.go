// SPDX-License-Identifier: Apache-2.0

package oci

import "testing"

// The codes this package raises are the registry's strings (internal/contract, which this module cannot import), so a
// renamed code in either place fails here, and the registry's coverage test sees each code named by a test.
func TestCodesAreTheRegistrysStrings(t *testing.T) {
	for _, c := range []struct{ got, want string }{
		{CodeNotFound, "profile.not_found"},
		{CodeDigestUnresolvable, "profile.digest_unresolvable"},
		{CodeMediaTypeParameter, "profile.media_type_parameter"},
		{CodeBadSignature, "profile.bad_signature"},
		{CodePredicateType, "profile.predicate_type"},
		{CodeScopeNotMean, "profile.scope_not_mean"},
		{CodeNoVariance, "profile.no_variance"},
		{CodeSubjectMismatch, "profile.subject_mismatch"},
		{CodeBaselineNotRunning, "profile.baseline_not_running"},
		{CodeStale, "profile.stale"},
		{CodeTimeDisagrees, "profile.time_disagrees"},
		{CodeHardwareMismatch, "profile.hardware_mismatch"},
		{CodeLoadOutOfRange, "profile.load_out_of_range"},
		{CodeTooFewVisits, "profile.too_few_visits"},
		{CodeLevelDrift, "profile.level_drift"},
		{CodeStructureChanged, "profile.structure_changed"},
		{CodeVarianceChanged, "profile.variance_changed"},
		{CodeSelfReportMismatch, "profile.self_report_mismatch"},
		{CodeErrorsDiffer, "profile.errors_differ"},
		{CodeNoStructure, "profile.no_structure"},
		{CodeNoOutsideMeasurement, "profile.no_outside_measurement"},
		{CodeLocationsPresent, "profile.locations_present"},
	} {
		if c.got != c.want {
			t.Errorf("code %q, want %q", c.got, c.want)
		}
	}
}
