// SPDX-License-Identifier: Apache-2.0

package state

import (
	"bytes"
	"encoding/json"
	"errors"
)

// Codes the server raises itself (DATA.md 19). The root module's registry (internal/contract) is the one place codes
// are defined; the server cannot import it, so these constants repeat the ones it raises and a test keeps them to the
// code pattern. All but the last two have trigger runtime; those two are raised by the CLI too, and the server raises
// them only for inputs the CLI never sees (a profile reference, structural assumptions).
const (
	CodeHandleUnknown   = "handle.unknown"
	CodeHandleExpired   = "handle.expired"
	CodeFitExpired      = "fit.expired"
	CodeFitNoBaseline   = "fit.no_baseline"
	CodePolicyNotNamed  = "policy.not_named"
	CodePolicyUnknown   = "policy.unknown"
	CodeJobTimeout      = "job.timeout"
	CodeJobFailed       = "job.failed"
	CodeRateLimited     = "rate.limited"
	CodeEngineMismatch  = "server.engine_mismatch"
	CodeProfileNotFound = "profile.not_found"
	CodeUnsupportedOp   = "change.unsupported_op"
)

// Refusal is the Refusal object of ARCHITECTURE.md 5.4. The server returns refusals it raises itself in the same
// envelope the CLI prints, {"error": Refusal}; Reason and Fix are fixed text, never derived from data.
type Refusal struct {
	Code    string             `json:"code"`
	Reason  string             `json:"reason"`
	Fix     string             `json:"fix"`
	Subject string             `json:"subject,omitempty"`
	Numbers map[string]float64 `json:"numbers,omitempty"`
}

// JSON is the refusal as canonical JSON (sorted keys, no insignificant whitespace, no HTML escaping).
func (r Refusal) JSON() json.RawMessage {
	var b bytes.Buffer
	enc := json.NewEncoder(&b)
	enc.SetEscapeHTML(false)
	// A struct's fields encode in declaration order; go through a map so the keys come out sorted.
	m := map[string]any{"code": r.Code, "reason": r.Reason, "fix": r.Fix}
	if r.Subject != "" {
		m["subject"] = r.Subject
	}
	if len(r.Numbers) > 0 {
		m["numbers"] = r.Numbers
	}
	if err := enc.Encode(m); err != nil {
		panic(err) // strings and finite floats always encode
	}
	return json.RawMessage(bytes.TrimSuffix(b.Bytes(), []byte("\n")))
}

// Envelope is {"error": Refusal}, as refusal.v1.json defines it.
func (r Refusal) Envelope() json.RawMessage {
	return json.RawMessage(`{"error":` + string(r.JSON()) + `}`)
}

// HandleRefusal maps a Resolve or GetJob error to its refusal; ok is false for any other error.
func HandleRefusal(err error) (Refusal, bool) {
	switch {
	case errors.Is(err, ErrHandleUnknown):
		return Refusal{Code: CodeHandleUnknown, Reason: "no such handle for this caller",
			Fix: "use a handle this server returned to you; start a fit with fit_start or use an env"}, true
	case errors.Is(err, ErrHandleExpired):
		return Refusal{Code: CodeHandleExpired, Reason: "the handle is past its expiry",
			Fix: "start a new fit with fit_start, or use an env's baseline"}, true
	}
	return Refusal{}, false
}
