// SPDX-License-Identifier: Apache-2.0

package infer

import (
	"fmt"
	"slices"
	"testing"
	"time"
)

// seqSig is n stages of one call each, all to callee c.
func seqSig(n int, c int32) stageSig {
	s := make(stageSig, n)
	for i := range s {
		s[i] = []int32{c}
	}
	return s
}

// A shape of n calls one after another fits a template of m >= n stages of the same callee (n of its stages ran), and
// not one of fewer. The search for the stages that ran is bounded by the product of the two lengths: a shape that
// does not fit used to take time exponential in the length (about a minute at 32 calls, hours at 40).
func TestFitStagesIsFastOnLongSequentialShapes(t *testing.T) {
	done := make(chan struct{})
	go func() {
		defer close(done)
		tmpl := seqSig(40, 1)
		for n := 1; n <= 40; n++ {
			got, ok := fitStages(seqSig(n, 1), tmpl)
			want := make([]int, n)
			for i := range want {
				want[i] = i
			}
			if !ok || !slices.Equal(got, want) {
				t.Errorf("%d calls in a template of 40: fit %v %v, want the first %d stages", n, ok, got, n)
			}
		}
		// shapes that do not fit, each of them a long way down the search
		for _, n := range []int{41, 60, 120} {
			if _, ok := fitStages(seqSig(n, 1), seqSig(40, 1)); ok {
				t.Errorf("%d calls fit a template of 40", n)
			}
		}
		if _, ok := fitStages(append(seqSig(39, 1), []int32{2}), seqSig(40, 1)); ok {
			t.Error("a call to another callee fits a template that does not have it")
		}
	}()
	select {
	case <-done:
	case <-time.After(20 * time.Second):
		t.Fatal("fitStages took over 20 s on shapes of up to 120 stages")
	}
}

// The first match is the one the unmemoised search finds: stages are taken as early as they fit.
func TestFitStagesKeepsTheFirstMatch(t *testing.T) {
	// the template is a, (b + c), a: the shape a, c, b, a runs it whole; the shape a, a skips the group
	tmpl := stageSig{{1}, {2, 3}, {1}}
	if got, ok := fitStages(stageSig{{1}, {2}, {3}, {1}}, tmpl); !ok || fmt.Sprint(got) != "[0 1 2]" {
		t.Errorf("a, b, c, a: %v %v, want stages [0 1 2]", ok, got)
	}
	if got, ok := fitStages(stageSig{{1}, {1}}, tmpl); !ok || fmt.Sprint(got) != "[0 2]" {
		t.Errorf("a, a: %v %v, want stages [0 2]", ok, got)
	}
	if _, ok := fitStages(stageSig{{1}, {1}, {1}}, tmpl); ok {
		t.Error("a, a, a fits a template with two a's")
	}
}

// A service that calls one callee 1 to 400 times in a row per visit: the stage template is not tried for shapes of
// more than maxTemplateStages stages, so the work stays bounded, and shapes within the limit are still fitted.
func TestStageTemplateSkipsVeryLongShapes(t *testing.T) {
	sigs := map[string]int64{}
	var nsp int64
	for n := 1; n <= 400; n++ {
		sigs[seqSig(n, 1).key()] = 3
		nsp += 3
	}
	done := make(chan struct{})
	var tmpl stageSig
	var fit float64
	var ok bool
	go func() {
		defer close(done)
		tmpl, _, fit, ok = stageTemplate(sigs, nsp)
	}()
	select {
	case <-done:
	case <-time.After(30 * time.Second):
		t.Fatal("stageTemplate took over 30 s on shapes of 1 to 400 stages")
	}
	if !ok || len(tmpl) > maxTemplateStages {
		t.Fatalf("template of %d stages (ok %v), want one of at most %d", len(tmpl), ok, maxTemplateStages)
	}
	// the shapes of 201 to 400 stages do not fit it, those of up to its own length do
	if want := float64(len(tmpl)) / 400; fit < want-1e-9 || fit > want+1e-9 {
		t.Errorf("fit %.4f of the visits, want %.4f (the shapes of up to %d stages)", fit, want, len(tmpl))
	}

	// only very long shapes: no template
	only := map[string]int64{seqSig(maxTemplateStages+1, 1).key(): 10}
	if _, _, _, ok := stageTemplate(only, 10); ok {
		t.Error("a template was read from a shape of more stages than the limit")
	}
}
