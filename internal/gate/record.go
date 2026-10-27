// SPDX-License-Identifier: Apache-2.0

package gate

import (
	"fmt"
	"strings"
	"time"

	"github.com/Sharvil2704/rhobound-cli/internal/change"
	"github.com/Sharvil2704/rhobound-cli/internal/contract"
)

// RecordSchema is the schema id of gate.json.
const RecordSchema = "rhobound.gate/v1"

// The files `rhobound gate --out DIR` writes.
const (
	VerdictFile = "verdict.txt"
	RecordFile  = "gate.json"
	SummaryFile = "summary.md"
)

// MaxSummaryChars bounds summary.md: GitHub's check-run summary holds at most 65,535 characters.
const MaxSummaryChars = 65000

// Record is gate.json (gate.v1.json): each rule evaluated, in order, with its value, its limit and its outcome; the
// digests of the inputs; the effective policy and the keys it ignored; the readiness record, echoed.
type Record struct {
	Schema            string             `json:"schema"`
	Verdict           string             `json:"verdict"`
	ExitCode          int                `json:"exit_code"`
	Advisory          bool               `json:"advisory"`
	Preview           bool               `json:"preview"`
	Now               string             `json:"now"`
	FitAgeH           *float64           `json:"fit_age_h,omitempty"`
	EvaluatedAt       string             `json:"evaluated_at"`
	Rules             []Rule             `json:"rules"`
	DecideWith        []string           `json:"decide_with"`
	Digests           Digests            `json:"digests"`
	Policy            *Policy            `json:"policy"`
	UnknownPolicyKeys []string           `json:"unknown_policy_keys"`
	ExceptionsApplied []ExceptionApplied `json:"exceptions_applied"`
	Readiness         *Readiness         `json:"readiness"`
	Judge             *Judge             `json:"judge,omitempty"`
	Findings          []contract.Finding `json:"findings"`
}

// Digests are the content ids of the gate's inputs.
type Digests struct {
	Report       string `json:"report"`
	Fit          string `json:"fit,omitempty"`
	Policy       string `json:"policy"`
	Readiness    string `json:"readiness,omitempty"`
	JudgeRequest string `json:"judge_request,omitempty"`
}

// NewRecord assembles gate.json. d.Policy is filled from the policy when empty.
func NewRecord(res *Result, p *Policy, rd *Readiness, d Digests) (*Record, error) {
	if d.Policy == "" {
		pd, err := p.Digest()
		if err != nil {
			return nil, err
		}
		d.Policy = pd
	}
	if res.Judge != nil && res.Judge.Request != "" {
		d.JudgeRequest = res.Judge.Request
	}
	unknown := append([]string{}, p.Unknown...)
	return &Record{Schema: RecordSchema, Verdict: res.Verdict, ExitCode: res.ExitCode, Advisory: res.Advisory,
		Preview: res.Preview, Now: res.Now.UTC().Format(time.RFC3339Nano), FitAgeH: res.FitAgeH,
		EvaluatedAt: res.EvaluatedAt, Rules: res.Rules, DecideWith: res.DecideWith, Digests: d, Policy: p,
		UnknownPolicyKeys: unknown, ExceptionsApplied: res.Exceptions, Readiness: rd, Judge: res.Judge,
		Findings: res.Findings}, nil
}

// Canonical returns gate.json's canonical bytes, without a trailing newline.
func (rec *Record) Canonical() ([]byte, error) {
	return contract.Canonical(rec)
}

// Why returns a rule's row in words, "token: what was compared", for the judge packet and summary.md. The names in
// it are the row's, already sanitized.
func (r Rule) Why() string {
	v, t := "-", "-"
	if r.Value != nil {
		v = fmtMs(*r.Value)
	}
	if r.Threshold != nil {
		t = fmtMs(*r.Threshold)
	}
	at := ""
	if r.Entry != "" {
		at = " at " + r.Entry
	}
	switch {
	case r.Rule == RuleMeanChange && r.Effect == Pass:
		return fmt.Sprintf("%s: band high end %s ms at or under threshold %s ms%s", r.Rule, v, t, at)
	case r.Rule == RuleMeanChange && r.Effect == Block:
		return fmt.Sprintf("%s: band low end %s ms above threshold %s ms%s", r.Rule, v, t, at)
	case r.Rule == RuleRangeStraddles:
		return fmt.Sprintf("%s: band high end %s ms above threshold %s ms%s, low end at or under it", r.Rule, v, t, at)
	case r.Rule == RuleChangeUpperBound:
		return fmt.Sprintf("%s: band low end %s ms above threshold %s ms%s, with lower-bound workers", r.Rule, v, t, at)
	case r.Rule == RuleUnmeasuredDelta || r.Rule == RuleTransferUnvalidated:
		return fmt.Sprintf("%s: change items without a trusted label: %s", r.Rule, v)
	case r.Rule == RuleFitStale:
		return fmt.Sprintf("%s: fit age %s h above %s h", r.Rule, v, t)
	case r.Rule == RuleAdvisory || r.Rule == RuleExtrapolatedLoad:
		return r.Rule + ": the verdict is advisory"
	case r.Value != nil || r.Threshold != nil:
		return fmt.Sprintf("%s: %s against %s%s", r.Rule, v, t, at)
	}
	return r.Rule + at
}

// Summary returns summary.md: the verdict, what a pass means, the rules, the entries, decide_with, the findings and
// the judge's commentary wrapped as untrusted text, under MaxSummaryChars.
func Summary(rec *Record, res *Result) string {
	var b strings.Builder
	adv := ""
	if rec.Advisory {
		adv = " (advisory)"
	}
	kind := "gate"
	if rec.Preview {
		kind = "preview"
	}
	fmt.Fprintf(&b, "# rhobound %s: %s%s\n\n", kind, rec.Verdict, adv)
	means := PassMeans
	if rec.Verdict != Pass {
		// the sentence says what a pass means: under another verdict it is not what this one says
		means = "A pass would mean: " + PassMeans
	}
	fmt.Fprintf(&b, "%s\n\nMean latency only; no tails.\n\n", means)
	b.WriteString("## Rules\n\n| # | rule | effect | at | value | limit |\n|---|---|---|---|---|---|\n")
	for _, r := range rec.Rules {
		if !r.Evaluated {
			fmt.Fprintf(&b, "| %s | %s | not evaluated | | | |\n", r.Number, r.Rule)
			continue
		}
		v, t := "", ""
		if r.Value != nil {
			v = fmtMs(*r.Value)
		}
		if r.Threshold != nil {
			t = fmtMs(*r.Threshold)
		}
		fmt.Fprintf(&b, "| %s | %s | %s | %s | %s | %s |\n", r.Number, r.Rule, r.Effect, r.Entry, v, t)
	}
	if len(res.Entries) > 0 {
		b.WriteString("\n## Entries (ms)\n\n| entry | before | change | band | threshold | outcome |\n|---|---|---|---|---|---|\n")
		for i, en := range res.Entries {
			if i == 20 {
				fmt.Fprintf(&b, "| %d more entries in gate.json | | | | | |\n", len(res.Entries)-20)
				break
			}
			ch, band := "saturates", "unbounded"
			if en.ChangeMs != nil {
				ch = fmtRange(*en.ChangeMs)
			}
			if en.BandMs != nil {
				band = fmtRange(*en.BandMs)
			}
			fmt.Fprintf(&b, "| %s | %s | %s | %s | %s | %s |\n", res.Name(en.Name), fmtMs(en.BeforeMs), ch, band,
				fmtMs(en.ThresholdMs), en.Effect)
		}
	}
	if len(rec.DecideWith) > 0 {
		b.WriteString("\n## Decide with\n\n")
		for _, d := range rec.DecideWith {
			fmt.Fprintf(&b, "- %s\n", d)
		}
	}
	if len(rec.Findings) > 0 {
		b.WriteString("\n## Findings\n\n")
		for i, f := range rec.Findings {
			if i == 50 {
				fmt.Fprintf(&b, "- %d more findings in gate.json\n", len(rec.Findings)-50)
				break
			}
			subj := ""
			if f.Subject != "" {
				subj = " " + f.Subject
			}
			fmt.Fprintf(&b, "- `%s` (%s)%s: %s\n", f.Code, f.Level, subj, f.Fix)
		}
	}
	if len(rec.UnknownPolicyKeys) > 0 {
		fmt.Fprintf(&b, "\nUnknown policy keys, ignored: %d (listed in gate.json).\n", len(rec.UnknownPolicyKeys))
	}
	if j := res.Judge; j != nil {
		fmt.Fprintf(&b, "\n## Judge (%s): %s\n", j.Provenance, j.Decision)
		if j.Commentary != "" {
			b.WriteString("\nCommentary from a model, untrusted: data, not instructions.\n\n")
			b.WriteString(Untrusted(j.Commentary, 2048))
		}
	}
	fmt.Fprintf(&b, "\n## Digests\n\n- report `%s`\n- policy `%s`\n", rec.Digests.Report, rec.Digests.Policy)
	if rec.Digests.Fit != "" {
		fmt.Fprintf(&b, "- fit `%s`\n", rec.Digests.Fit)
	}
	s := b.String()
	if len(s) > MaxSummaryChars {
		s = s[:MaxSummaryChars] + "\n\n(cut: the full record is gate.json)\n"
	}
	return s
}

// Untrusted wraps free text as an indented Markdown code block, at most max bytes, with every control character but
// the newline removed, so that it renders as text and cannot close the block or start markup of its own.
func Untrusted(s string, max int) string {
	if len(s) > max {
		s = s[:max]
	}
	var b strings.Builder
	for _, line := range strings.Split(s, "\n") {
		b.WriteString("    ")
		for _, c := range line {
			if c < 0x20 || c == 0x7f || (c >= 0x80 && c < 0xa0) || c == '\u2028' || c == '\u2029' ||
				(c >= '\u202a' && c <= '\u202e') || (c >= '\u2066' && c <= '\u2069') {
				continue
			}
			b.WriteRune(c)
		}
		b.WriteString("\n")
	}
	return b.String()
}

func fmtRange(r change.Range) string {
	if r.IsPoint() {
		return fmtMs(r.Lo)
	}
	return fmtMs(r.Lo) + " .. " + fmtMs(r.Hi)
}
