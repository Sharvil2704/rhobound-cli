// SPDX-License-Identifier: Apache-2.0

package infer

// Refusal is a refusal of the inference with its registered code: the capture cannot be read into a model (too few
// entry requests, a cycle, too many call shapes, a negative service time, too many broken traces, ...). Code is one of
// the contract package's constants; Subject is the service or edge it concerns, as the traces name it (whoever prints
// it sanitizes it), or ""; Numbers are the values read, by name. Err is the message rhobound-cli has always printed:
// Error returns it unchanged, so the text output and its goldens do not move, and the --json form prints it as the
// refusal's reason beside the code and the code's fix.
type Refusal struct {
	Code    string
	Subject string
	Numbers map[string]float64
	Err     error
}

// Error returns the message, unchanged.
func (r *Refusal) Error() string { return r.Err.Error() }

// Unwrap returns the message's error.
func (r *Refusal) Unwrap() error { return r.Err }
