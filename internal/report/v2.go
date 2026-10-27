// SPDX-License-Identifier: Apache-2.0

package report

import (
	"io"
	"math"

	"github.com/Sharvil2704/rhobound-cli/internal/change"
	"github.com/Sharvil2704/rhobound-cli/internal/contract"
	"github.com/Sharvil2704/rhobound-cli/internal/fit"
)

// VersionV2 is the version of report v2.
const VersionV2 = "rhobound-cli.report/v2"

// V2 is report v2 (docs/mcp/schemas/report.v2.json; docs/mcp/ARCHITECTURE.md 4.1-4.8): what `rhobound predict --fit F`
// prints, written by the pure engine (engine.Predict) from a fit record, a change set and a load point.
//
// It is additive over report v1. The embedded Report holds every v1 key with its v1 name, type and meaning; Version is
// VersionV2 and Capture is the capture name stored in the fit; each row may carry the two v2 row keys (Row's
// UtilizationAfter and ChangeRangeMs). V1 projects it back: `predict --fit F --patch P --report v1 --json` and
// `predict CAPTURE --patch P --json` print the same bytes, on one architecture, for a fit of that capture with the same
// options.
//
// The report holds no policy: thresholds, verdicts and the policy's band fractions belong to the gate, which reads the
// report. Its JSON is canonical (Canonical; WriteJSON adds a newline). The slices are never nil in a report the engine
// wrote, so that the required arrays serialize as [] rather than null. WriteText is the embedded report's, the v1 text;
// the v2 text form is not built yet.
type V2 struct {
	Report

	// FitDigest is the digest of the fit record (fit.Record.Digest), the fit_digest every view carries.
	FitDigest string `json:"fit_digest"`
	// ManifestDigest is the digest of the capture manifest the fit was made from.
	ManifestDigest string `json:"manifest_digest"`
	// FitWindow is the fit's window; the gate measures the fit's age from its end (rule 3, fit_stale).
	FitWindow fit.Window `json:"fit_window"`
	// ChangeHash is the change set's digest (change.Set.Digest).
	ChangeHash string `json:"change_hash"`
	// RecordDigests are the digests of the records whose numbers entered as measured items (A/B records; later,
	// verified profiles), sorted; omitted when there are none.
	RecordDigests []string `json:"record_digests,omitempty"`
	Tool          fit.Tool `json:"tool"`
	// EvidenceClass is one of the EvidenceClass constants (ARCHITECTURE.md 4.6).
	EvidenceClass string `json:"evidence_class"`
	// UtilizationLimit is the --max-rho the engine solved under.
	UtilizationLimit float64 `json:"utilization_limit"`
	Load             Load    `json:"load"`
	// Items are the change items as applied, in the change set's order: a measured item's value is its delta +-2
	// standard errors. Labels[].Item indexes this list.
	Items []Applied `json:"items"`
	// Corners is the number of solves made for the corners of the ranges (at most 128).
	Corners int `json:"corners"`
	// Monotonicity is always Monotonicity until the simulator test of the signs passes.
	Monotonicity string `json:"monotonicity"`
	// Entries has one row per entry service.
	Entries []Entry `json:"entries"`
	// ModelBand is the model band the entries' ModelBandMs and BandMs were computed with: the defaults, for display
	// (DefaultModelBand); the gate recomputes the band with its policy's fractions.
	ModelBand ModelBand  `json:"model_band"`
	Labels    []LabelRef `json:"labels"`
	// WeakestLabel is the weakest label among the items, "" (omitted) without items.
	WeakestLabel string `json:"weakest_label,omitempty"`
	// Findings are the fit's findings, the change set's (its doubts: Validate's findings below refuse level), and the
	// engine's own, sorted (contract.SortFindings).
	Findings []contract.Finding `json:"findings"`
	// Assumptions is the assumptions list (ARCHITECTURE.md 4.8), in a fixed order.
	Assumptions []Assumption `json:"assumptions"`
}

// Monotonicity is V2.Monotonicity: the signs of the operations (change.SignOf) are assumed, not yet tested.
const Monotonicity = "assumed (untested)"

// The evidence classes (ARCHITECTURE.md 4.6).
const (
	// EvidenceSimulated: the model's documented error comes from the simulator only.
	EvidenceSimulated = "simulated-70-80"
	// EvidenceQueueLike: the busiest service on the path is at or below the highest load at which a change was judged
	// on a real cluster (58%, on the repository's own queue-like demo).
	EvidenceQueueLike = "queue-like-real-cluster-le-0.58"
	// EvidenceRealUntested: the services are third-party software, whose queueing has not been tested publicly.
	EvidenceRealUntested = "real-software-queueing-untested"
)

// EvidenceClasses lists the evidence classes, in the order of the schema's enum.
var EvidenceClasses = []string{EvidenceSimulated, EvidenceQueueLike, EvidenceRealUntested}

// Load is the load point the report was solved at.
type Load struct {
	// EvaluatedAt is EvaluatedAtFitWindow, or EvaluatedAtWhatIf for a load scale other than 1. The engine never
	// evaluates at a busiest window: that is the gate's question.
	EvaluatedAt string `json:"evaluated_at"`
	// LoadScale multiplies the fit's external rate (1 at the fit's window).
	LoadScale float64 `json:"load_scale"`
	// MaxUtilizationBefore is the highest utilization at the load point before the change; MaxUtilizationAfter its
	// range over the corners after it, nil without a change.
	MaxUtilizationBefore float64       `json:"max_utilization_before"`
	MaxUtilizationAfter  *change.Range `json:"max_utilization_after,omitempty"`
}

// The values of Load.EvaluatedAt.
const (
	EvaluatedAtFitWindow = "fit_window"
	EvaluatedAtWhatIf    = "what_if"
)

// Applied is one change item as the engine applied it.
type Applied struct {
	Op      string `json:"op"`
	Service string `json:"service"`
	Callee  string `json:"callee,omitempty"`
	// Value is the range applied; a point is Lo == Hi, a measured item its delta +-2 standard errors.
	Value    change.Range `json:"value"`
	Label    string       `json:"label"`
	Evidence []string     `json:"evidence,omitempty"`
	// Sign is change.SignOf(Op).
	Sign string `json:"sign"`
}

// Entry is the prediction for one entry service. The ranges are over the corners of the change set's ranges; each is
// nil (null) when a corner leaves some service on the entry's path without a finite mean (it saturates), and when
// there is no change.
type Entry struct {
	Name string `json:"name"`
	// BeforeMs is the entry's model mean before the change (its row's model_ms), the base of change_pct and of the
	// model band's latency term.
	BeforeMs  float64       `json:"before_ms"`
	AfterMs   *change.Range `json:"after_ms"`
	ChangeMs  *change.Range `json:"change_ms"`
	ChangePct *change.Range `json:"change_pct"`
	// ModelBandMs is the model band at V2.ModelBand's fractions: ModelBand.Ms(max(|lo|, |hi|) of ChangeMs, BeforeMs),
	// the latency term alone when ChangeMs is nil.
	ModelBandMs float64 `json:"model_band_ms"`
	// BandMs is ChangeMs widened on each side by the model band at that end's change (ModelBand.Ms(ChangeMs.Lo,
	// BeforeMs) below, ModelBand.Ms(ChangeMs.Hi, BeforeMs) above), then by each biased construct on its side: the
	// construct widening on each side is what is left beyond the model band there.
	BandMs *change.Range `json:"band_ms"`
	// Biased are the constructs with a documented, directional error on the path to this entry (ARCHITECTURE.md
	// 4.5, item 3). Never nil.
	Biased []Biased `json:"biased"`
}

// Biased is one construct with a documented, directional model error on an entry's path.
type Biased struct {
	Construct string `json:"construct"`
	// Service is the service whose call structure holds the construct.
	Service string `json:"service"`
	// Direction is the side the documented error lies on.
	Direction string `json:"direction"`
}

// The biased constructs, with the side of their documented error (docs/ACCURACY.md, docs/VALIDATION.md).
const (
	ConstructSecondSequentialCall = "second_sequential_call" // both: over behind a smooth caller, under behind a bursty one
	ConstructNonSlowestBranch     = "non_slowest_branch"     // over-predicted
	ConstructStagedCalls          = "staged_calls"           // over-predicted for small changes
	ConstructRegularUpstream      = "regular_upstream"       // under-predicted
)

// The directions of Biased.Direction.
const (
	DirectionBoth  = "both"
	DirectionOver  = "over"
	DirectionUnder = "under"
)

// ModelBand is the model's own error added to an entry's change range on both sides (ARCHITECTURE.md 4.5, item 2):
// max(ChangeFrac x |change|, LatencyFrac x the entry's mean before the change). The defaults are the simulator's 90th
// percentile change errors, with the worst case printed beside them; it is a floor, not a bound.
type ModelBand struct {
	ChangeFrac  float64   `json:"change_frac"`
	LatencyFrac float64   `json:"latency_frac"`
	Source      string    `json:"source"`
	Label       string    `json:"label"`
	WorstCase   BandFracs `json:"worst_case"`
}

// BandFracs are the two fractions of a model band.
type BandFracs struct {
	ChangeFrac  float64 `json:"change_frac"`
	LatencyFrac float64 `json:"latency_frac"`
}

// The default model band.
const (
	DefaultChangeFrac  = 0.163
	DefaultLatencyFrac = 0.0227
	WorstChangeFrac    = 0.355
	WorstLatencyFrac   = 0.0752
	ModelBandSource    = "simulated-p90"
	ModelBandLabel     = "simulated p90 floor; real software untested"
)

// DefaultModelBand returns the default model band.
func DefaultModelBand() ModelBand {
	return ModelBand{ChangeFrac: DefaultChangeFrac, LatencyFrac: DefaultLatencyFrac, Source: ModelBandSource,
		Label: ModelBandLabel, WorstCase: BandFracs{ChangeFrac: WorstChangeFrac, LatencyFrac: WorstLatencyFrac}}
}

// Ms is the model band in entry milliseconds for a change of changeMs at an entry whose mean before the change is
// beforeMs: max(ChangeFrac x |changeMs|, LatencyFrac x beforeMs). The budget's safe value and the gate's band use the
// same formula, with the policy's fractions.
func (b ModelBand) Ms(changeMs, beforeMs float64) float64 {
	return math.Max(b.ChangeFrac*math.Abs(changeMs), b.LatencyFrac*beforeMs)
}

// LabelRef is the label of one item of V2.Items.
type LabelRef struct {
	Item  int    `json:"item"`
	Label string `json:"label"`
	// TransferValidated is true when the label's transfer to production is validated for the environment (the gate
	// knows; the engine never sets it). Absent means not validated.
	TransferValidated bool `json:"transfer_validated,omitempty"`
}

// Assumption is one modelling assumption and how it was checked (ARCHITECTURE.md 4.8): every report and every tool
// result carries the list. "Admitted" never means "accurate".
type Assumption struct {
	ID     string `json:"id"`
	Status string `json:"status"`
	How    string `json:"how,omitempty"`
}

// The statuses of an assumption.
const (
	CheckedOK    = "checked-ok"
	CheckedDoubt = "checked-doubt"
	NotCheckable = "not-checkable"
	NotChecked   = "not-checked"
)

// AssumptionStatuses lists the statuses, in the order of the schema's enum.
var AssumptionStatuses = []string{CheckedOK, CheckedDoubt, NotCheckable, NotChecked}

// The assumption ids the engine lists (docs/mcp/DATA.md 3.12, 3.13; ARCHITECTURE.md 7.1 shows balancing_random). The
// ones before AssumeSteadyPoisson are always not-checkable from traces alone; the monotonicity of the entry mean in
// the change items has its own key (V2.Monotonicity).
const (
	AssumeBalancingRandom      = "balancing_random"       // round-robin or least-request balancing, modelled as random
	AssumeWorkerFreedAtCall    = "worker_freed_at_call"   // no server holds its worker after its first call out
	AssumeClientsInstrumented  = "clients_instrumented"   // every outbound client library is instrumented
	AssumeNoUntracedRetries    = "no_untraced_retries"    // no retry or timeout that leaves no span
	AssumeNoCPUThrottling      = "no_cpu_throttling"      // CPU throttling, unless resource metrics are supplied
	AssumeEntriesNotLostCalls  = "entries_not_lost_calls" // entries are not calls whose caller's span was lost
	AssumeTailSamplingDeclared = "tail_sampling_declared" // any tail sampling was declared
	AssumeSteadyPoisson        = "steady_poisson_load"    // steady, roughly Poisson arrivals (trace.load_trend, ...)
	AssumeServiceTimeFlat      = "service_time_flat"      // service time does not depend on load
)

// V1 returns the v1 projection of the report: the embedded Report with Version set to report v1's and the v2 row keys
// cleared; every other v2 key is dropped by construction. Capture is already the name stored in the fit. The rows are
// copied; the other slices are shared with v.
func (v *V2) V1() *Report {
	r := v.Report
	r.Version = Version
	r.Rows = make([]Row, len(v.Rows))
	for i, row := range v.Rows {
		row.UtilizationAfter, row.ChangeRangeMs = nil, nil
		r.Rows[i] = row
	}
	return &r
}

// Canonical returns the report's canonical JSON (contract.Canonical), with no trailing newline.
func (v *V2) Canonical() ([]byte, error) {
	return contract.Canonical(v)
}

// Digest is the report's content id, contract.Digest of its canonical JSON: the report digest gate.json records.
func (v *V2) Digest() (string, error) {
	return contract.DigestOf(v)
}

// WriteJSON writes the report's canonical JSON and a newline: `predict --fit F --json`.
func (v *V2) WriteJSON(w io.Writer) error {
	b, err := v.Canonical()
	if err != nil {
		return err
	}
	_, err = w.Write(append(b, '\n'))
	return err
}
