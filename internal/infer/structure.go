// SPDX-License-Identifier: Apache-2.0

package infer

// Call structure: a port of the reference implementation's rules for how many
// calls a visit makes to each callee and whether its calls run one after
// another, all at once, or in stages (for example, Sock Shop's orders call
// four services at once, then payment, then shipping when the payment went
// through). The model has a form for each of these; other shapes are not rounded
// to the nearest one: counts.go reads calls per visit that vary as a mean count,
// and visits of several shapes as a mixture of the shapes.

import (
	"fmt"
	"slices"
	"sort"
	"strconv"
	"strings"
)

// The reference's constants, unchanged.
const (
	parallelShare   = 0.95 // share of multi-call visits whose calls overlap: above -> parallel, below 1 - it -> sequential
	callAgreement   = 0.99 // share of visits showing k or k + 1 calls to a callee
	stageCandidates = 8    // the stage template is the best fit among this many of the commonest call shapes
	// maxTemplateStages: a visit that calls in more stages than this (hundreds of calls one after another: a query per
	// row) is not fitted to a stage template, and such a shape is not a candidate. A call structure that long is not
	// one the stage form is for, and the fit costs time in proportion to the stages of the shape times those of the
	// template, for every pair of shapes.
	maxTemplateStages = 200
)

// stageSig is a visit's calls in stages, in order. A stage is one call, or
// calls that overlap (each starts before the stage's earlier calls have all
// ended); the next stage starts once they have. A stage is a sorted multiset
// of callee ids.
type stageSig [][]int32

// key encodes a signature as text ("3,4|5"), to count signatures in a map.
func (s stageSig) key() string {
	var b []byte
	for i, g := range s {
		if i > 0 {
			b = append(b, '|')
		}
		for j, c := range g {
			if j > 0 {
				b = append(b, ',')
			}
			b = strconv.AppendInt(b, int64(c), 10)
		}
	}
	return string(b)
}

// parseSig is the inverse of key.
func parseSig(k string) stageSig {
	if k == "" {
		return nil
	}
	var s stageSig
	for _, g := range strings.Split(k, "|") {
		var st []int32
		for _, c := range strings.Split(g, ",") {
			v, _ := strconv.Atoi(c)
			st = append(st, int32(v))
		}
		s = append(s, st)
	}
	return s
}

// stagesOf groups a visit's calls (sorted by start) into stages by the
// reference's rule: a call that starts at or after the latest end of the
// current stage's calls begins the next stage. It returns each stage's call
// indices into cs.
func stagesOf(cs []call) [][]int {
	var out [][]int
	var cur []int
	var curEnd uint64
	for j, c := range cs {
		if len(cur) > 0 && c.start >= curEnd {
			out = append(out, cur)
			cur = nil
		}
		cur = append(cur, j)
		if len(cur) > 1 {
			curEnd = max(curEnd, c.end)
		} else {
			curEnd = c.end
		}
	}
	if len(cur) > 0 {
		out = append(out, cur)
	}
	return out
}

// sigOf is the signature of a visit's calls grouped into stages.
func sigOf(cs []call, stages [][]int) stageSig {
	s := make(stageSig, len(stages))
	for i, g := range stages {
		st := make([]int32, len(g))
		for j, x := range g {
			st[j] = cs[x].callee
		}
		slices.Sort(st)
		s[i] = st
	}
	return s
}

// callCount reads how many calls a visit makes to one callee from hist
// (calls per visit -> visits, for visits making at least one; nsp visits in
// all): a fixed count k, or k and one more with probability p (a conditional
// call). Any other distribution is an error (Run then takes the mean count, see
// counts.go), unless two adjacent counts cover callAgreement of the visits: the
// rest (a share other) is then ignored.
func callCount(hist map[int]int64, nsp int64) (k int, p, other float64, err error) {
	cnt := map[int]int64{}
	sum := int64(0)
	for n, v := range hist {
		if v > 0 {
			cnt[n] = v
			sum += v
		}
	}
	if z := nsp - sum; z > 0 {
		cnt[0] = z
	}
	vals := make([]int, 0, len(cnt))
	for n := range cnt {
		vals = append(vals, n)
	}
	slices.Sort(vals)
	switch {
	case len(vals) == 0:
		return 0, 0, 0, nil
	case len(vals) == 1:
		return vals[0], 0, 0, nil
	case len(vals) == 2 && vals[1] == vals[0]+1:
		return vals[0], float64(cnt[vals[1]]) / float64(nsp), 0, nil
	}
	// the two commonest counts (ties to the smaller count)
	top := append([]int(nil), vals...)
	sort.SliceStable(top, func(i, j int) bool { return cnt[top[i]] > cnt[top[j]] })
	a, b := min(top[0], top[1]), max(top[0], top[1])
	share := float64(cnt[a]+cnt[b]) / float64(nsp)
	if b != a+1 || share < callAgreement {
		var parts []string
		for _, n := range vals {
			parts = append(parts, fmt.Sprintf("%d: %d", n, cnt[n]))
		}
		return 0, 0, 0, fmt.Errorf("calls per visit vary as {%s}", strings.Join(parts, ", "))
	}
	return a, float64(cnt[b]) / float64(nsp), 1 - share, nil
}

// fitStages is the reference's stage-fit rule: which of the template's stages a
// visit's signature ran, or false if it does not fit. It fits when its stages
// are the template's with whole stages left out, where one stage of the
// template may show as several in turn (calls launched together need not
// overlap: a fast one can end before the next starts).
//
// The search tries, for the signature's stage i and the template's stage j, to
// match stage j to the next stages of the signature and, failing that, to leave
// stage j out. A pair (i, j) that failed fails again whenever it is reached
// by another route, so it is remembered: without that the search is
// exponential in the number of stages (a service that calls one callee 1 to 30
// times in a row per visit took minutes), and with it at most
// len(sig) * len(tmpl) pairs are tried. The first match found is the same.
func fitStages(sig, tmpl stageSig) ([]int, bool) {
	dead := make([]bool, (len(sig)+1)*(len(tmpl)+1)) // (i, j) known not to fit
	var fit func(i, j int) ([]int, bool)
	try := func(i, j int) ([]int, bool) {
		need := map[int32]int{}
		for _, c := range tmpl[j] {
			need[c]++
		}
		acc := map[int32]int{}
		for k := i; k < len(sig); k++ {
			over := false
			for _, c := range sig[k] {
				acc[c]++
				over = over || acc[c] > need[c]
			}
			if over {
				break
			}
			if equalCounts(acc, need) {
				if rest, ok := fit(k+1, j+1); ok {
					return append([]int{j}, rest...), true
				}
				break
			}
		}
		return fit(i, j+1)
	}
	fit = func(i, j int) ([]int, bool) {
		if i == len(sig) {
			return []int{}, true
		}
		if j == len(tmpl) || dead[i*(len(tmpl)+1)+j] {
			return nil, false
		}
		res, ok := try(i, j)
		if !ok {
			dead[i*(len(tmpl)+1)+j] = true
		}
		return res, ok
	}
	return fit(0, 0)
}

func equalCounts(a, b map[int32]int) bool {
	if len(a) != len(b) {
		return false
	}
	for k, v := range a {
		if b[k] != v {
			return false
		}
	}
	return true
}

// stageTemplate is the reference's stage template: the call shape that most
// visits fit (fitStages), the coarsest on a tie, among the stageCandidates
// commonest shapes. sigs counts the visits per signature key (visits making
// no call are left out of it: they fit any shape). It returns the template,
// the share of the fitting visits that ran each of its stages and the share
// of all nsp visits that fit; ok is false when no visit makes a call. Ties
// between equally common shapes go to the smaller key (the reference takes
// the first seen, which a parallel read does not keep). Shapes of more than maxTemplateStages
// stages are not fitted (they count among the visits that do not fit), and a template of
// that many is not tried; ok is false when no shape is left to try.
func stageTemplate(sigs map[string]int64, nsp int64) (tmpl stageSig, ran []float64, fit float64, ok bool) {
	keys := make([]string, 0, len(sigs))
	for k, n := range sigs {
		if k != "" && n > 0 {
			keys = append(keys, k)
		}
	}
	if len(keys) == 0 || nsp <= 0 {
		return nil, nil, 0, false
	}
	sort.Slice(keys, func(i, j int) bool {
		if sigs[keys[i]] != sigs[keys[j]] {
			return sigs[keys[i]] > sigs[keys[j]]
		}
		return keys[i] < keys[j]
	})
	all := make([]string, len(keys))
	copy(all, keys)
	slices.Sort(all) // the fits are summed in a fixed order
	parsed := map[string]stageSig{}
	for _, k := range all {
		parsed[k] = parseSig(k)
	}
	cands := make([]string, 0, stageCandidates)
	for _, k := range keys {
		if len(cands) == stageCandidates {
			break
		}
		if len(parsed[k]) <= maxTemplateStages {
			cands = append(cands, k)
		}
	}
	if len(cands) == 0 {
		return nil, nil, 0, false
	}
	var none int64 = nsp // visits making no call
	for _, k := range all {
		none -= sigs[k]
	}
	type best struct {
		cover, count int64
		stages       int
		tmpl         string
		fits         map[string][]int
	}
	var b *best
	for _, tk := range cands {
		tm := parsed[tk]
		fits := map[string][]int{}
		cover := none
		for _, k := range all {
			if len(parsed[k]) > maxTemplateStages {
				continue
			}
			if f, ok := fitStages(parsed[k], tm); ok {
				fits[k] = f
				cover += sigs[k]
			}
		}
		better := b == nil || cover > b.cover ||
			(cover == b.cover && (len(tm) < b.stages || (len(tm) == b.stages && sigs[tk] > b.count)))
		if better {
			b = &best{cover, sigs[tk], len(tm), tk, fits}
		}
	}
	tmpl = parsed[b.tmpl]
	ran = make([]float64, len(tmpl))
	for j := range tmpl {
		var n int64
		for _, k := range all {
			if f, ok := b.fits[k]; ok && slices.Contains(f, j) {
				n += sigs[k]
			}
		}
		ran[j] = float64(n) / float64(b.cover)
	}
	return tmpl, ran, float64(b.cover) / float64(nsp), true
}
