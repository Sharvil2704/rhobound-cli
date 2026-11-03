// SPDX-License-Identifier: Apache-2.0

package model

import (
	"errors"
	"fmt"
	"math"
	"runtime"
	"sort"
	"sync"
)

// The batch queue for c >= 2 when it fits (solve; finding Q1, lane C of the maze-kit Q1 workflow): the M^X/PH/c queue, exact for a phase-type
// service law with the mean s and the scv cs2 of mxq's gamma (phFit):
//   - cs2 <= 1: Tijms' mixture of Erlang(K-1) and Erlang(K) with a common rate, 1/K <= cs2 <= 1/(K-1); it is exactly
//     Erlang-K at cs2 = 1/K (Erlang-4 at 0.25, Erlang-2 at 0.5, the exponential at 1), and those Erlangs are the gamma.
//   - cs2 > 1: the two-phase hyperexponential with balanced means. It matches the gamma's mean and scv, not its third
//     moment (at cs2 = 2 it is 18 s^3 against the gamma's 15 s^3), so there it is a moment match, not the gamma.
//
// (1) The law an epoch finds (PASTA: the time-stationary one) is that of the chain on (n, the multiset of the phases of
// the min(n, c) busy workers). Above c it is level-independent and of M/G/1 type: down one level at a completion (the
// freed worker starts the head of the queue in a phase drawn from alpha), up k levels at an epoch of k calls (rate
// lam q_k, the configuration unchanged). G, the configuration at the first passage one level down, solves
// A_{-1} + U G = 0 with U = A_0 + sum_k lam q_k G^k (U-based iteration from a stochastic matrix). The levels 0..c
// are solved together in the chain censored to them (GTH), and the levels above by Ramaswami's recursion
// pi_n = sum_e y_{n-e} Abar_e (-U)^{-1}, Abar_e = sum_{k>=e} lam q_k G^(k-e), every term nonnegative. The law is cut
// once the last kmax levels hold less than phLevelCut of the mass so far; the tail it leaves is estimated from their
// geometric decay and reported (Tail).
//
// (2) The batch: one FIFO queue, so a call that arrives after the epoch never starts before a member and is left out.
// With w = n-c >= 0 calls waiting ahead, the configuration of the c busy workers is carried through w completions
// (each starts the next call ahead), summed over n from the top level down with its time's first two moments. Then the
// members enter one per completion, and the time to the last member's end is an absorbing chain on (members waiting,
// the phases of the workers on calls ahead, the phases of the workers on members); once every member has started only
// the members' phases matter. Completions only lower the members waiting and the phase laws here are acyclic (a
// phase only moves to a later one), so its mean and second moment take one pass in topological order, no solve.
//
// Cost: the configurations of c busy workers number D = C(c+P-1, P-1) for P phases (165 at c = 8, P = 4; 9 at c = 8,
// P = 2). The iteration for G costs about (kmax + 3) D^3 per step, the boundary C(c+P, P)^3 / 3 once, each level
// above c kmax D^2, and the makespan chain C(c+2P-1, 2P-1) kmax states. c is capped at phMaxC and D at
// phMaxConfigs.

const (
	phMaxC       = 32
	phMaxConfigs = 200
	// phMaxBoundary bounds the states of the levels 0..c, C(c+P, P), whose dense reduction dominates a solve's cost
	// (about its cube): 560 states take about 0.1 s, 969 0.4 s and 1330 0.9 s (Erlang-3 at 13, 16 and 18 workers).
	phMaxBoundary = 600
	phMaxPhases   = 8     // a configuration is packed into 8 bits per phase (a count up to 255), 64 bits in all
	phLevelCut    = 1e-16 // the last kmax levels' share of the mass at which the law is cut
	// phMaxCells is the levels times configurations kept for cs2 <= 1, about 100 bytes each: near saturation (rho 0.999
	// at 8 workers and cs2 0.25, 4.8M cells, half a gigabyte and a second) the superposition is within 0.2% there and
	// takes a few tens of MB, so solve hands it the queue. Above cs2 1 it is not (27% low at rho 0.99, its law of N is
	// the exponential's), and the two-phase H2 stays cheap, so it keeps phMaxCellsH2.
	phMaxCells   = 2e6
	phMaxCellsH2 = 4e7
	phGTol       = 1e-15 // max |G_{i+1} - G_i| at which the iteration for G stops
	phGMaxIter   = 200000
)

var errPHLimit = errors.New("ph: the queue is past the phase-type limits (c <= 32, D <= 200 configurations, 600 boundary states)")

// phLaw is an acyclic phase-type law: a service starts in phase i with probability alpha[i], moves from phase i to a
// later phase mv[i][*].to at rate mv[i][*].r and ends from phase i at rate t0[i].
type phLaw struct {
	alpha []float64
	mv    [][]phMove
	t0    []float64
	out   []float64 // the total rate out of each phase
	name  string
	hyper bool // cs2 > 1: the H2
}

type phMove struct {
	to int
	r  float64
}

// phFit returns the phase-type law with mean s and scv cs2 (see the header).
func phFit(s, cs2 float64) (*phLaw, error) {
	if !(s > 0) || !(cs2 > 0) || math.IsInf(s, 0) || math.IsInf(cs2, 0) {
		return nil, fmt.Errorf("ph: no phase-type law for mean %g, scv %g", s, cs2)
	}
	ph := &phLaw{hyper: cs2 > 1}
	if cs2 <= 1 {
		k := int(math.Ceil(1/cs2 - 1e-9))
		if k > phMaxPhases {
			return nil, errPHLimit
		}
		kf := float64(k)
		p := (kf*cs2 - math.Sqrt(math.Max(kf*(1+cs2)-kf*kf*cs2, 0))) / (1 + cs2)
		p = math.Min(math.Max(p, 0), 1)
		if k == 1 {
			p = 0
		}
		mu := (kf - p) / s
		ph.alpha = make([]float64, k)
		ph.alpha[0] = 1 - p
		if k > 1 {
			ph.alpha[1] += p
		}
		ph.mv = make([][]phMove, k)
		ph.t0 = make([]float64, k)
		for i := 0; i+1 < k; i++ {
			ph.mv[i] = []phMove{{i + 1, mu}}
		}
		ph.t0[k-1] = mu
		switch {
		case k == 1:
			ph.name = "exponential"
		case p == 0:
			ph.name = fmt.Sprintf("Erlang-%d", k)
		default:
			ph.name = fmt.Sprintf("Erlang-%d/%d mixture (p %.6g)", k-1, k, p)
		}
	} else if p, x1, x2, ok := h2ThreeMoments(s, cs2); ok {
		// the two-phase hyperexponential with the gamma's first three moments: the max of a batch's members depends on
		// the tail's shape beyond the scv (balanced means has E[S^3] = 18 s^3 at cs2 = 2 against the gamma's 15)
		ph.alpha = []float64{p, 1 - p}
		ph.mv = make([][]phMove, 2)
		ph.t0 = []float64{1 / x1, 1 / x2}
		ph.name = fmt.Sprintf("H2 three moments (p %.6g)", p)
	} else {
		p1 := (1 + math.Sqrt((cs2-1)/(cs2+1))) / 2
		ph.alpha = []float64{p1, 1 - p1}
		ph.mv = make([][]phMove, 2)
		ph.t0 = []float64{2 * p1 / s, 2 * (1 - p1) / s}
		ph.name = fmt.Sprintf("H2 balanced means (p1 %.6g)", p1)
	}
	ph.out = make([]float64, len(ph.t0))
	for i := range ph.out {
		ph.out[i] = ph.t0[i]
		for _, mv := range ph.mv[i] {
			if mv.to <= i {
				return nil, errors.New("ph: the phase law is not acyclic")
			}
			ph.out[i] += mv.r
		}
	}
	return ph, nil
}

// h2ThreeMoments returns the two-phase hyperexponential with the first three moments of the gamma of mean s and scv
// cs2 > 1: with a_k = E[S^k]/k!, its phase means x1, x2 are the two-point law with moments 1, a1, a2, a3 (the roots
// of x^2 + al x + be, al = (a1 a2 - a3)/(a2 - a1^2), be = -a2 - al a1) and p = (a1 - x2)/(x1 - x2). ok is false when
// they are not a law (a3 a1 <= a2^2 or a root not positive).
func h2ThreeMoments(s, cs2 float64) (p, x1, x2 float64, ok bool) {
	a1 := s
	a2 := s * s * (1 + cs2) / 2
	a3 := s * s * s * (1 + cs2) * (1 + 2*cs2) / 6
	den := a2 - a1*a1
	if !(den > 0) || !(a3*a1 > a2*a2) {
		return 0, 0, 0, false
	}
	al := (a1*a2 - a3) / den
	be := -a2 - al*a1
	disc := al*al - 4*be
	if !(disc > 0) {
		return 0, 0, 0, false
	}
	x1, x2 = (-al+math.Sqrt(disc))/2, (-al-math.Sqrt(disc))/2
	p = (a1 - x2) / (x1 - x2)
	return p, x1, x2, x2 > 0 && p > 0 && p < 1
}

// moments returns E[S], E[S^2], E[S^3] (from the phases' absorption times, last phase first).
func (ph *phLaw) moments() (float64, float64, float64) {
	P := len(ph.t0)
	m1, m2, m3 := make([]float64, P), make([]float64, P), make([]float64, P)
	for i := P - 1; i >= 0; i-- {
		q := ph.out[i]
		a1, a2, a3 := 0.0, 0.0, 0.0
		for _, mv := range ph.mv[i] {
			a1 += mv.r * m1[mv.to]
			a2 += mv.r * m2[mv.to]
			a3 += mv.r * m3[mv.to]
		}
		m1[i] = (1 + a1) / q
		m2[i] = (2*m1[i] + a2) / q
		m3[i] = (3*m2[i] + a3) / q
	}
	var e1, e2, e3 float64
	for i, a := range ph.alpha {
		e1 += a * m1[i]
		e2 += a * m2[i]
		e3 += a * m3[i]
	}
	return e1, e2, e3
}

// phSets are the multisets of b phases (the phases of b busy workers), sorted by potential (sum of phase indices)
// so that every internal move goes to a later one.
type phSets struct {
	n   int
	cnt []uint8 // P counts per configuration
	key map[uint64]int32
	add []int32   // P per configuration: one more in phase j, in the sets of size b+1 (-1 at the top size)
	rem []int32   // P per configuration: one fewer in phase i, in the sets of size b-1 (-1 if none there)
	out []float64 // the total rate out of the configuration
	pot []int
}

func phKey(c []uint8) uint64 {
	var k uint64
	for i, v := range c {
		k += uint64(v) << (8 * i) // the same arithmetic as add and rem's k +- 1<<(8*i)
	}
	return k
}

func phNewSets(P, b int) *phSets {
	var all [][]uint8
	cur := make([]uint8, P)
	var rec func(i, left int)
	rec = func(i, left int) {
		if i == P-1 {
			cur[i] = uint8(left)
			all = append(all, append([]uint8(nil), cur...))
			return
		}
		for v := left; v >= 0; v-- {
			cur[i] = uint8(v)
			rec(i+1, left-v)
		}
	}
	rec(0, b)
	pot := func(c []uint8) int {
		s := 0
		for i, v := range c {
			s += i * int(v)
		}
		return s
	}
	sort.SliceStable(all, func(a, b int) bool { return pot(all[a]) < pot(all[b]) })
	s := &phSets{n: len(all), cnt: make([]uint8, 0, len(all)*P), key: make(map[uint64]int32, len(all)), pot: make([]int, len(all))}
	for i, c := range all {
		s.cnt = append(s.cnt, c...)
		s.key[phKey(c)] = int32(i)
		s.pot[i] = pot(c)
	}
	return s
}

// maxCells is the levels times configurations the stationary law may keep (phMaxCells, phMaxCellsH2).
func (md *phModel) maxCells() float64 {
	if md.ph.hyper {
		return phMaxCellsH2
	}
	return phMaxCells
}

// phModel is the phase law with the configurations of up to c busy workers.
type phModel struct {
	c, P  int
	ph    *phLaw
	sets  []*phSets   // by size 0..c
	fresh [][]float64 // fresh[r] over sets[r]: the law of the phases of r services that start together
	// the configurations of c busy workers (sets[c]) with a queue: internal moves into each, completions with a restart
	inB   [][]phArc
	compB [][]phArc
}

type phArc struct {
	j int32
	r float64
}

func newPHModel(c int, ph *phLaw) (*phModel, error) {
	P := len(ph.t0)
	if c < 1 || c > phMaxC || P > phMaxPhases {
		return nil, errPHLimit
	}
	if D := phBinom(c+P-1, P-1); D > phMaxConfigs {
		return nil, fmt.Errorf("%w: %d configurations of %d workers over %d phases", errPHLimit, D, c, P)
	}
	if S := phBinom(c+P, P); S > phMaxBoundary {
		return nil, fmt.Errorf("%w: %d boundary states of %d workers over %d phases", errPHLimit, S, c, P)
	}
	md := &phModel{c: c, P: P, ph: ph, sets: make([]*phSets, c+1)}
	for b := 0; b <= c; b++ {
		md.sets[b] = phNewSets(P, b)
	}
	for b := 0; b <= c; b++ {
		s := md.sets[b]
		s.add = make([]int32, s.n*P)
		s.rem = make([]int32, s.n*P)
		s.out = make([]float64, s.n)
		for x := 0; x < s.n; x++ {
			cn := s.cnt[x*P : (x+1)*P]
			k := phKey(cn)
			for i := 0; i < P; i++ {
				s.add[x*P+i], s.rem[x*P+i] = -1, -1
				if b < c {
					y, ok := md.sets[b+1].key[k+1<<(8*i)]
					if !ok { // a missing key would read as configuration 0
						return nil, errors.New("ph: a configuration's neighbour has no key")
					}
					s.add[x*P+i] = y
				}
				if cn[i] > 0 {
					y, ok := md.sets[b-1].key[k-1<<(8*i)]
					if !ok {
						return nil, errors.New("ph: a configuration's neighbour has no key")
					}
					s.rem[x*P+i] = y
					s.out[x] += float64(cn[i]) * ph.out[i]
				}
			}
		}
	}
	md.fresh = make([][]float64, c+1)
	md.fresh[0] = []float64{1}
	for r := 1; r <= c; r++ {
		md.fresh[r] = md.addOne(r-1, md.fresh[r-1])
	}
	B := md.sets[c]
	md.inB = make([][]phArc, B.n)
	md.compB = make([][]phArc, B.n)
	for x := 0; x < B.n; x++ {
		md.moves(c, x, func(y int, r float64) { md.inB[y] = append(md.inB[y], phArc{int32(x), r}) })
		cn := B.cnt[x*P : (x+1)*P]
		for i := 0; i < P; i++ {
			if cn[i] == 0 || ph.t0[i] == 0 {
				continue
			}
			r := float64(cn[i]) * ph.t0[i]
			y := B.rem[x*P+i]
			for j, a := range ph.alpha {
				if a > 0 {
					md.compB[x] = append(md.compB[x], phArc{md.sets[c-1].add[int(y)*P+j], r * a})
				}
			}
		}
	}
	return md, nil
}

func phBinom(n, k int) int {
	if k < 0 || k > n {
		return 0
	}
	r := 1
	for i := 1; i <= k; i++ {
		r = r * (n - k + i) / i
	}
	return r
}

// moves calls f for each internal phase move of configuration x of size b: the configuration it goes to and the rate.
func (md *phModel) moves(b, x int, f func(y int, r float64)) {
	if b == 0 {
		return
	}
	P := md.P
	s := md.sets[b]
	lower := md.sets[b-1]
	for i := 0; i < P; i++ {
		ci := s.cnt[x*P+i]
		if ci == 0 {
			continue
		}
		y := int(s.rem[x*P+i])
		for _, mv := range md.ph.mv[i] {
			f(int(lower.add[y*P+mv.to]), float64(ci)*mv.r)
		}
	}
}

// ends calls f for each phase that can end in configuration x of size b: the configuration without it and the rate.
func (md *phModel) ends(b, x int, f func(y int, r float64)) {
	P := md.P
	s := md.sets[b]
	for i := 0; i < P; i++ {
		ci := s.cnt[x*P+i]
		if ci == 0 || md.ph.t0[i] == 0 {
			continue
		}
		f(int(s.rem[x*P+i]), float64(ci)*md.ph.t0[i])
	}
}

// addOne returns the law over sets[b+1] after one more service starts on a law v over sets[b].
func (md *phModel) addOne(b int, v []float64) []float64 {
	P := md.P
	s := md.sets[b]
	w := make([]float64, md.sets[b+1].n)
	for x, p := range v {
		if p == 0 {
			continue
		}
		for j, a := range md.ph.alpha {
			if a > 0 {
				w[s.add[x*P+j]] += p * a
			}
		}
	}
	return w
}

// place returns the law over sets[b+r] after r services start on a law v over sets[b].
func (md *phModel) place(b, r int, v []float64) []float64 {
	for i := 0; i < r; i++ {
		v = md.addOne(b+i, v)
	}
	return v
}

// nmul returns u (-A0)^{-1} over sets[c], A0 the sub-generator of the busy configuration until the next completion.
func (md *phModel) nmul(u []float64) []float64 {
	B := md.sets[md.c]
	v := make([]float64, B.n)
	for j := 0; j < B.n; j++ { // internal moves go up in potential
		acc := u[j]
		for _, a := range md.inB[j] {
			acc += v[a.j] * a.r
		}
		v[j] = acc / B.out[j]
	}
	return v
}

// comp returns u A_{-1}: completions with the next call started.
func (md *phModel) comp(u []float64) []float64 {
	w := make([]float64, len(u))
	for x, p := range u {
		if p == 0 {
			continue
		}
		for _, a := range md.compB[x] {
			w[a.j] += p * a.r
		}
	}
	return w
}

// step carries a measure over the busy configurations, with its time's first two moments, to the next completion.
func (md *phModel) step(x, y, z []float64) ([]float64, []float64, []float64) {
	xN := md.nmul(x)
	xN2 := md.nmul(xN)
	xN3 := md.nmul(xN2)
	yN := md.nmul(y)
	yN2 := md.nmul(yN)
	zN := md.nmul(z)
	y1 := make([]float64, len(x))
	z1 := make([]float64, len(x))
	for i := range y1 {
		y1[i] = yN[i] + xN2[i]
		z1[i] = zN[i] + 2*yN2[i] + 2*xN3[i]
	}
	return md.comp(xN), md.comp(y1), md.comp(z1)
}

// --- dense helpers (row-major n x n) ---

func phMul(dst, a, b []float64, n int) {
	work := func(r0, r1 int) {
		for i := r0; i < r1; i++ {
			di := dst[i*n : (i+1)*n]
			clear(di)
			for k, av := range a[i*n : (i+1)*n] {
				if av == 0 {
					continue
				}
				for j, bv := range b[k*n : (k+1)*n] {
					di[j] += av * bv
				}
			}
		}
	}
	nw := runtime.GOMAXPROCS(0)
	if n < 48 || nw < 2 {
		work(0, n)
		return
	}
	var wg sync.WaitGroup
	chunk := (n + nw - 1) / nw
	for r0 := 0; r0 < n; r0 += chunk {
		wg.Add(1)
		go func(r0 int) {
			defer wg.Done()
			work(r0, min(n, r0+chunk))
		}(r0)
	}
	wg.Wait()
}

// phSolveLU overwrites b (n x m) with a^{-1} b; a is destroyed. Partial pivoting.
func phSolveLU(a, b []float64, n, m int) error {
	for k := 0; k < n; k++ {
		p := k
		for i := k + 1; i < n; i++ {
			if math.Abs(a[i*n+k]) > math.Abs(a[p*n+k]) {
				p = i
			}
		}
		if a[p*n+k] == 0 {
			return errors.New("ph: singular block")
		}
		if p != k {
			for j := 0; j < n; j++ {
				a[k*n+j], a[p*n+j] = a[p*n+j], a[k*n+j]
			}
			for j := 0; j < m; j++ {
				b[k*m+j], b[p*m+j] = b[p*m+j], b[k*m+j]
			}
		}
		piv := a[k*n+k]
		for i := k + 1; i < n; i++ {
			f := a[i*n+k] / piv
			if f == 0 {
				continue
			}
			a[i*n+k] = 0
			for j := k + 1; j < n; j++ {
				a[i*n+j] -= f * a[k*n+j]
			}
			for j := 0; j < m; j++ {
				b[i*m+j] -= f * b[k*m+j]
			}
		}
	}
	for k := n - 1; k >= 0; k-- {
		piv := a[k*n+k]
		for j := 0; j < m; j++ {
			v := b[k*m+j]
			for i := k + 1; i < n; i++ {
				v -= a[k*n+i] * b[i*m+j]
			}
			b[k*m+j] = v / piv
		}
	}
	return nil
}

// phGTH returns the stationary law (unnormalized, pi[0] = 1) of the generator whose off-diagonal rates are in
// p (n x n, destroyed; the diagonal is ignored).
func phGTH(p []float64, n int) ([]float64, error) {
	for k := n - 1; k >= 1; k-- {
		s := 0.0
		for j := 0; j < k; j++ {
			s += p[k*n+j]
		}
		if !(s > 0) {
			return nil, errors.New("ph: a boundary state cannot move down")
		}
		for i := 0; i < k; i++ {
			f := p[i*n+k]
			if f == 0 {
				continue
			}
			f /= s
			p[i*n+k] = f
			for j := 0; j < k; j++ {
				if i != j {
					p[i*n+j] += f * p[k*n+j]
				}
			}
		}
	}
	pi := make([]float64, n)
	pi[0] = 1
	for j := 1; j < n; j++ {
		v := 0.0
		for i := 0; i < j; i++ {
			v += pi[i] * p[i*n+j]
		}
		pi[j] = v
	}
	return pi, nil
}

// phSol is the solved queue, times in the unit of s (ms).
type phSol struct {
	W0, W0sq, Wbar float64
	MS, MSsq       []float64 // by batch size k (index k)
	// diagnostics
	Phase    string
	D        int     // configurations of c busy workers
	Boundary int     // states of the levels 0..c
	Levels   int     // levels kept (0..Levels-1)
	States   int     // states of the stationary law kept
	Member   int     // states of the makespan chain
	GIter    int     // steps of the iteration for G
	GRowErr  float64 // max |G 1 - 1|
	Tail     float64 // estimated mass above the top level
	Busy     float64 // E[busy workers]: lam E[X] s if the law is right
	pi       [][]float64
	md       *phModel
	tab      *phTail
}

// phSolve is the lane-C solution of the queue m (see the header) for batches of the given sizes.
func (m *mxq) phSolve(sizes []int) (*phSol, error) {
	ph, err := phFit(m.s, m.cs2)
	if err != nil {
		return nil, err
	}
	md, err := newPHModel(m.c, ph)
	if err != nil {
		return nil, err
	}
	kq := len(m.q) - 1 // the largest batch of the law
	kmax := kq
	for _, k := range sizes {
		kmax = max(kmax, k)
	}
	var ex float64
	for k := 1; k <= kq; k++ {
		ex += float64(k) * m.q[k]
	}
	if !(m.lam*ex*m.s < float64(m.c)) {
		return nil, errors.New("ph: the queue is not stable")
	}
	sol := &phSol{Phase: ph.name, md: md}
	if err := md.stationary(m.lam, m.q, sol); err != nil {
		return nil, err
	}
	sol.tab = md.tails(kmax)
	md.makespan(m.q, kmax, sizes, sol)
	return sol, nil
}

// stationary fills sol.pi with the law an epoch finds.
func (md *phModel) stationary(lam float64, q []float64, sol *phSol) error {
	c := md.c
	B := md.sets[c]
	D := B.n
	kq := len(q) - 1
	// A0 (without arrivals) and A_{-1}, dense
	A0 := make([]float64, D*D)
	Am1 := make([]float64, D*D)
	for x := 0; x < D; x++ {
		A0[x*D+x] = -B.out[x]
		md.moves(c, x, func(y int, r float64) { A0[x*D+y] += r })
		for _, a := range md.compB[x] {
			Am1[x*D+int(a.j)] += a.r
		}
	}
	// G from the configuration after one completion with no arrivals (stochastic)
	G := make([]float64, D*D)
	tmp := make([]float64, D*D)
	for i := range tmp {
		tmp[i] = -A0[i]
	}
	copy(G, Am1)
	if err := phSolveLU(tmp, G, D, D); err != nil {
		return err
	}
	abar := make([][]float64, kq+2)
	for e := 1; e <= kq+1; e++ {
		abar[e] = make([]float64, D*D)
	}
	GA := make([]float64, D*D)
	negU := make([]float64, D*D)
	build := func() { // abar[e], GA = G abar[1], negU = -(A0 - lam I + GA)
		clear(abar[kq])
		for i := 0; i < D; i++ {
			abar[kq][i*D+i] = lam * q[kq]
		}
		for e := kq - 1; e >= 1; e-- {
			phMul(abar[e], G, abar[e+1], D)
			for i := 0; i < D; i++ {
				abar[e][i*D+i] += lam * q[e]
			}
		}
		phMul(GA, G, abar[1], D)
		for i := range negU {
			negU[i] = -A0[i] - GA[i]
		}
		for i := 0; i < D; i++ {
			negU[i*D+i] += lam
		}
	}
	Gn := make([]float64, D*D)
	it := 0
	for ; ; it++ {
		if it >= phGMaxIter {
			return errors.New("ph: the iteration for G did not converge")
		}
		build()
		copy(tmp, negU)
		copy(Gn, Am1)
		if err := phSolveLU(tmp, Gn, D, D); err != nil {
			return err
		}
		diff := 0.0
		for i := range G {
			diff = math.Max(diff, math.Abs(Gn[i]-G[i]))
		}
		G, Gn = Gn, G
		if diff < phGTol {
			break
		}
	}
	sol.GIter = it + 1
	for i := 0; i < D; i++ {
		s := 0.0
		for j := 0; j < D; j++ {
			s += G[i*D+j]
		}
		sol.GRowErr = math.Max(sol.GRowErr, math.Abs(s-1))
	}
	build()
	inv := make([]float64, D*D)
	for i := 0; i < D; i++ {
		inv[i*D+i] = 1
	}
	copy(tmp, negU)
	if err := phSolveLU(tmp, inv, D, D); err != nil {
		return err
	}
	R := make([][]float64, kq+1) // R[e] = abar[e] (-U)^{-1}
	for e := 1; e <= kq; e++ {
		R[e] = make([]float64, D*D)
		phMul(R[e], abar[e], inv, D)
	}
	// the levels 0..c, censored: offsets and the dense generator's off-diagonal rates
	off := make([]int, c+2)
	for n := 0; n <= c; n++ {
		off[n+1] = off[n] + md.sets[n].n
	}
	S := off[c+1]
	Pm := make([]float64, S*S)
	for n := 0; n <= c; n++ {
		sn := md.sets[n]
		for x := 0; x < sn.n; x++ {
			r := off[n] + x
			row := Pm[r*S : (r+1)*S]
			md.moves(n, x, func(y int, rt float64) { row[off[n]+y] += rt })
			if n >= 1 {
				md.ends(n, x, func(y int, rt float64) { row[off[n-1]+y] += rt })
			}
			if n == c {
				for y := 0; y < D; y++ {
					if y != x {
						row[off[c]+y] += GA[x*D+y]
					}
				}
				continue
			}
			v := make([]float64, sn.n)
			v[x] = 1
			for k := 1; k <= c-n; k++ {
				v = md.addOne(n+k-1, v)
				if k > kq {
					break
				}
				if k < c-n {
					if q[k] > 0 {
						for y, p := range v {
							row[off[n+k]+y] += lam * q[k] * p
						}
					}
					continue
				}
				// k = c-n: every batch of c-n calls or more fills the free workers and returns to level c by G
				ab := abar[k]
				for y, p := range v {
					if p == 0 {
						continue
					}
					for z := 0; z < D; z++ {
						row[off[c]+z] += p * ab[y*D+z]
					}
				}
			}
		}
	}
	for i := 0; i < S; i++ {
		Pm[i*S+i] = 0
	}
	pb, err := phGTH(Pm, S)
	if err != nil {
		return err
	}
	var pi [][]float64
	var ys [][]float64
	var mass []float64
	cum := 0.0
	for n := 0; n <= c; n++ {
		p := append([]float64(nil), pb[off[n]:off[n+1]]...)
		pi = append(pi, p)
		ys = append(ys, md.place(n, c-n, p))
		s := 0.0
		for _, v := range p {
			s += v
		}
		mass = append(mass, s)
		cum += s
	}
	// Ramaswami above c
	for n := c + 1; ; n++ {
		if float64(n*D) > md.maxCells() {
			return errors.New("ph: the law does not settle within the level limit")
		}
		p := make([]float64, D)
		for e := 1; e <= kq && e <= n; e++ {
			y := ys[n-e]
			Re := R[e]
			for i, yv := range y {
				if yv == 0 {
					continue
				}
				for j, rv := range Re[i*D : (i+1)*D] {
					p[j] += yv * rv
				}
			}
		}
		s := 0.0
		for _, v := range p {
			s += v
		}
		pi = append(pi, p)
		ys = append(ys, p)
		mass = append(mass, s)
		cum += s
		if n >= c+2*kq {
			b1, b0 := 0.0, 0.0
			for i := n - kq + 1; i <= n; i++ {
				b1 += mass[i]
				b0 += mass[i-kq]
			}
			if b1 <= phLevelCut*cum {
				r := b1 / b0
				if r < 1 {
					sol.Tail = b1 * r / (1 - r) / cum
				} else {
					sol.Tail = math.Inf(1)
				}
				break
			}
		}
	}
	busy := 0.0
	for n, p := range pi {
		for i := range p {
			p[i] /= cum
		}
		busy += float64(min(n, c)) * mass[n] / cum
	}
	sol.pi = pi
	sol.Busy = busy
	sol.D, sol.Boundary, sol.Levels = D, S, len(pi)
	sol.States = S + (len(pi)-c-1)*D
	return nil
}

// phTail holds the mean and second moment of the time to the last member's end, from each state of the makespan
// chain. Stage 2 (every member has started): s2[r][x] for the r members' phases x. Stage 1: s1[mw][i] for mw members
// waiting and i = off1[o] + xO*sets[c-o].n + xM, o workers on calls ahead in phases xO, c-o on members in phases xM.
type phTail struct {
	s2h1, s2h2 [][]float64
	s1h1, s1h2 [][]float64
	off1       []int
}

func (md *phModel) tails(kmax int) *phTail {
	c, P := md.c, md.P
	t := &phTail{s2h1: make([][]float64, c+1), s2h2: make([][]float64, c+1)}
	t.s2h1[0], t.s2h2[0] = []float64{0}, []float64{0}
	for r := 1; r <= c; r++ {
		s := md.sets[r]
		h1, h2 := make([]float64, s.n), make([]float64, s.n)
		for x := s.n - 1; x >= 0; x-- {
			var a1, a2 float64
			md.moves(r, x, func(y int, rt float64) {
				a1 += rt * h1[y]
				a2 += rt * h2[y]
			})
			md.ends(r, x, func(y int, rt float64) {
				a1 += rt * t.s2h1[r-1][y]
				a2 += rt * t.s2h2[r-1][y]
			})
			q := s.out[x]
			h1[x] = (1 + a1) / q
			h2[x] = (2*h1[x] + a2) / q
		}
		t.s2h1[r], t.s2h2[r] = h1, h2
	}
	t.off1 = make([]int, c+2)
	for o := 0; o <= c; o++ {
		t.off1[o+1] = t.off1[o] + md.sets[o].n*md.sets[c-o].n
	}
	L := t.off1[c+1]
	type st struct {
		o, xo, xm int32
		pot       int
	}
	order := make([]st, 0, L)
	for o := 0; o <= c; o++ {
		for xo := 0; xo < md.sets[o].n; xo++ {
			for xm := 0; xm < md.sets[c-o].n; xm++ {
				order = append(order, st{int32(o), int32(xo), int32(xm), md.sets[o].pot[xo] + md.sets[c-o].pot[xm]})
			}
		}
	}
	sort.SliceStable(order, func(a, b int) bool { return order[a].pot > order[b].pot })
	alpha := md.ph.alpha
	t.s1h1 = make([][]float64, kmax+1)
	t.s1h2 = make([][]float64, kmax+1)
	for mw := 1; mw <= kmax; mw++ {
		h1, h2 := make([]float64, L), make([]float64, L)
		for _, sv := range order {
			o, xo, xm := int(sv.o), int(sv.xo), int(sv.xm)
			nm := md.sets[c-o].n
			idx := t.off1[o] + xo*nm + xm
			var a1, a2 float64
			md.moves(o, xo, func(y int, rt float64) {
				j := t.off1[o] + y*nm + xm
				a1 += rt * h1[j]
				a2 += rt * h2[j]
			})
			md.moves(c-o, xm, func(y int, rt float64) {
				j := t.off1[o] + xo*nm + y
				a1 += rt * h1[j]
				a2 += rt * h2[j]
			})
			// a call ahead ends: the next member starts on its worker
			if o > 0 {
				sm := md.sets[c-o]
				md.ends(o, xo, func(y int, rt float64) {
					for j, a := range alpha {
						if a == 0 {
							continue
						}
						xm2 := int(sm.add[xm*P+j])
						if mw == 1 {
							a1 += rt * a * t.s2h1[c-o+1][xm2]
							a2 += rt * a * t.s2h2[c-o+1][xm2]
						} else {
							k := t.off1[o-1] + y*md.sets[c-o+1].n + xm2
							a1 += rt * a * t.s1h1[mw-1][k]
							a2 += rt * a * t.s1h2[mw-1][k]
						}
					}
				})
			}
			// a member ends: the next member starts on its worker
			if c-o > 0 {
				lower := md.sets[c-o-1]
				md.ends(c-o, xm, func(y int, rt float64) {
					for j, a := range alpha {
						if a == 0 {
							continue
						}
						xm2 := int(lower.add[y*P+j])
						if mw == 1 {
							a1 += rt * a * t.s2h1[c-o][xm2]
							a2 += rt * a * t.s2h2[c-o][xm2]
						} else {
							k := t.off1[o] + xo*nm + xm2
							a1 += rt * a * t.s1h1[mw-1][k]
							a2 += rt * a * t.s1h2[mw-1][k]
						}
					}
				})
			}
			q := md.sets[o].out[xo] + md.sets[c-o].out[xm]
			h1[idx] = (1 + a1) / q
			h2[idx] = (2*h1[idx] + a2) / q
		}
		t.s1h1[mw], t.s1h2[mw] = h1, h2
	}
	return t
}

// makespan fills the waits and the makespans from the law and the tail tables.
func (md *phModel) makespan(q []float64, kmax int, sizes []int, sol *phSol) {
	c := md.c
	D := md.sets[c].n
	t := sol.tab
	pi := sol.pi
	sol.Member = (len(t.s1h1) - 1) * t.off1[c+1]
	for r := 1; r <= c; r++ {
		sol.Member += md.sets[r].n
	}
	// the calls ahead that wait: from the top level down to c
	x, y, z := make([]float64, D), make([]float64, D), make([]float64, D)
	for n := len(pi) - 1; n >= c; n-- {
		if n < len(pi)-1 {
			x, y, z = md.step(x, y, z)
		}
		for i, p := range pi[n] {
			x[i] += p
		}
	}
	// the starts of the members: E[V_j], j = 1..kmax
	ev, ev2 := make([]float64, kmax+1), make([]float64, kmax+1)
	sum := func(v []float64) float64 {
		s := 0.0
		for _, a := range v {
			s += a
		}
		return s
	}
	{
		a, b, d := x, y, z
		for j := 1; j <= kmax; j++ {
			a, b, d = md.step(a, b, d)
			ev[j] += sum(b)
			ev2[j] += sum(d)
		}
	}
	for n := 0; n < c; n++ {
		f := c - n
		if f >= kmax {
			continue
		}
		a := md.place(n, f, pi[n])
		b, d := make([]float64, D), make([]float64, D)
		for j := f + 1; j <= kmax; j++ {
			a, b, d = md.step(a, b, d)
			ev[j] += sum(b)
			ev2[j] += sum(d)
		}
	}
	sol.W0, sol.W0sq = ev[1], ev2[1]
	var ex, wsum float64
	for k := 1; k < len(q); k++ {
		if q[k] == 0 {
			continue
		}
		ex += float64(k) * q[k]
		acc := 0.0
		for j := 1; j <= k; j++ {
			acc += ev[j]
		}
		wsum += q[k] * acc
	}
	if ex > 0 {
		sol.Wbar = wsum / ex
	}
	// the makespans
	sol.MS, sol.MSsq = make([]float64, kmax+1), make([]float64, kmax+1)
	for _, k := range sizes {
		if k < 1 {
			continue
		}
		var ms, ms2 float64
		// busy: c workers on calls ahead, none waiting, k members waiting
		h1, h2 := t.s1h1[k], t.s1h2[k]
		base := t.off1[c] // o = c, xM = the empty set (sets[0].n = 1)
		for i := 0; i < D; i++ {
			ms += y[i] + x[i]*h1[base+i]
			ms2 += z[i] + 2*y[i]*h1[base+i] + x[i]*h2[base+i]
		}
		for n := 0; n < c; n++ {
			f := c - n
			sn := md.sets[n]
			if k <= f { // every member starts at once: the largest of k fresh services
				fr := md.fresh[k]
				m1, m2 := 0.0, 0.0
				for xm, p := range fr {
					m1 += p * t.s2h1[k][xm]
					m2 += p * t.s2h2[k][xm]
				}
				mass := sum(pi[n])
				ms += mass * m1
				ms2 += mass * m2
				continue
			}
			fr := md.fresh[f]
			nm := md.sets[f].n
			for xo := 0; xo < sn.n; xo++ {
				p := pi[n][xo]
				if p == 0 {
					continue
				}
				for xm, pf := range fr {
					if pf == 0 {
						continue
					}
					i := t.off1[n] + xo*nm + xm
					ms += p * pf * t.s1h1[k-f][i]
					ms2 += p * pf * t.s1h2[k-f][i]
				}
			}
		}
		sol.MS[k], sol.MSsq[k] = ms, ms2
	}
}
