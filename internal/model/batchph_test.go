// SPDX-License-Identifier: Apache-2.0

package model

import (
	"encoding/json"
	"fmt"
	"math"
	"math/rand/v2"
	"os"
	"runtime"
	"sort"
	"strconv"
	"testing"
	"time"
)

func phClose(t *testing.T, what string, got, want, tol float64) {
	t.Helper()
	if !(math.Abs(got-want) <= tol*math.Max(math.Abs(want), 1)) {
		t.Errorf("%s: got %.12g, want %.12g (diff %.3g, tolerance %.2g)", what, got, want, got-want, tol)
	}
}

// The phase laws have the mean and scv asked; the Erlangs at cs2 = 1/K and the H2 above 1 have the gamma's third
// moment (the H2 is fitted to it; balanced means would give 18 against 15 at cs2 = 2).
func TestPHPhaseLaws(t *testing.T) {
	for _, cs2 := range []float64{0.25, 0.3, 0.5, 0.7, 1, 1.0001, 1.01, 1.04, 1.11, 1.5, 2, 4} {
		for _, s := range []float64{1, 2.5} {
			ph, err := phFit(s, cs2)
			if err != nil {
				t.Fatal(err)
			}
			e1, e2, e3 := ph.moments()
			phClose(t, fmt.Sprintf("cs2 %g s %g E[S]", cs2, s), e1, s, 1e-12)
			phClose(t, fmt.Sprintf("cs2 %g s %g E[S^2]", cs2, s), e2, s*s*(1+cs2), 1e-12)
			g3 := s * s * s * (1 + cs2) * (1 + 2*cs2)
			t.Logf("cs2 %g s %g: %s, E[S^3] %.6g (gamma %.6g)", cs2, s, ph.name, e3, g3)
			if cs2 == 0.25 || cs2 == 0.5 || cs2 >= 1 {
				phClose(t, fmt.Sprintf("cs2 %g E[S^3] vs gamma", cs2), e3, g3, 1e-12)
			}
		}
	}
}

// Per state at c = 2, cs2 = 1, k = 2 (verifier_Q1_test.go): N = 0 -> 1.5; N = 1 -> 1.75; N = 2 (busy, none
// waiting) -> 2/2 + 1.25.
func TestPHPerState(t *testing.T) {
	ph, _ := phFit(1, 1)
	md, err := newPHModel(2, ph)
	if err != nil {
		t.Fatal(err)
	}
	tb := md.tails(2)
	phClose(t, "N=0: max of two services", tb.s2h1[2][0], 1.5, 1e-14)
	phClose(t, "N=1: one ahead, one member in service, one waiting", tb.s1h1[1][tb.off1[1]], 1.75, 1e-14)
	phClose(t, "N=2: two ahead in service, two members waiting", tb.s1h1[2][tb.off1[2]], 2.25, 1e-14)
	// second moments by hand: max of two Exp(1) has E[M^2] = 2 + 2 - 2/4 ... = 3.5
	phClose(t, "N=0: E[max^2]", tb.s2h2[2][0], 3.5, 1e-14)
}

// phExactMX2 is the exact MS[2] of the M^X/M/2 queue with X = 2 (per state over piM, as verifier_Q1_test.go).
func phExactMX2(t *testing.T, lam float64) float64 {
	m := &mxq{c: 2, s: 1, cs2: 1, lam: lam, q: []float64{0, 0, 1}}
	pi, err := m.piM()
	if err != nil {
		t.Fatal(err)
	}
	ex := 0.0
	for n, p := range pi {
		switch n {
		case 0:
			ex += p * 1.5
		case 1:
			ex += p * 1.75
		default:
			ex += p * (float64(n)/2 + 1.25)
		}
	}
	return ex
}

// The GRID.md anchors at c = 2, cs2 = 1, X = 2; and at cs2 = 1 the level masses equal piM's for every c of the grid.
func TestPHAnchors(t *testing.T) {
	grid := map[float64]float64{0.1: 1.57143, 0.25: 1.72222, 0.4: 1.95833, 0.5: 2.2}
	for _, lam := range []float64{0.1, 0.25, 0.4, 0.5} {
		m := &mxq{c: 2, s: 1, cs2: 1, lam: lam, q: []float64{0, 0, 1}}
		sol, err := m.phSolve([]int{2})
		if err != nil {
			t.Fatal(err)
		}
		ex := phExactMX2(t, lam)
		t.Logf("lam %.2f: MS[2] %.10f, per-state exact %.10f (diff %.2g), GRID %.5f; tail %.2g, levels %d",
			lam, sol.MS[2], ex, sol.MS[2]-ex, grid[lam], sol.Tail, sol.Levels)
		phClose(t, fmt.Sprintf("lam %g MS[2] vs per-state exact", lam), sol.MS[2], ex, 1e-9)
		if math.Abs(sol.MS[2]-grid[lam]) > 5e-6 {
			t.Errorf("lam %g: MS[2] %.7f is not the GRID anchor %.5f to its 5 decimals", lam, sol.MS[2], grid[lam])
		}
	}
	laws := phGridLaws()
	for _, c := range []int{2, 3, 4, 8} {
		for _, lw := range laws {
			for _, rho := range []float64{0.3, 0.85} {
				lam := rho * float64(c) / lw.ex
				m := &mxq{c: c, s: 1, cs2: 1, lam: lam, q: lw.q}
				sol, err := m.phSolve(lw.sizes)
				if err != nil {
					t.Fatal(err)
				}
				pM, err := m.piM()
				if err != nil {
					t.Fatal(err)
				}
				worst := 0.0
				for n := 0; n < max(len(pM), len(sol.pi)); n++ {
					var a, b float64
					if n < len(pM) {
						a = pM[n]
					}
					if n < len(sol.pi) {
						b = sol.pi[n][0]
					}
					worst = math.Max(worst, math.Abs(a-b))
				}
				if worst > 1e-12 {
					t.Errorf("c %d %s rho %g: level masses differ from piM by %.3g", c, lw.name, rho, worst)
				}
				// solveSup's waits are exact for exponential services (up to its quadrature)
				sup, err := m.solve(lw.sizes)
				if err != nil {
					t.Fatal(err)
				}
				phClose(t, fmt.Sprintf("c %d %s rho %g W0 vs solveSup", c, lw.name, rho), sol.W0, sup.W0, 1e-5)
				phClose(t, fmt.Sprintf("c %d %s rho %g Wbar vs solveSup", c, lw.name, rho), sol.Wbar, sup.Wbar, 1e-5)
			}
		}
	}
}

// At c = 1 the closed forms of solveOne are exact; the Erlangs at 0.25, 0.5 and the exponential are the gamma, so
// every output must match. At cs2 = 2 the H2 has another third moment: MS, W0 and Wbar match, MSsq does not.
func TestPHOneWorker(t *testing.T) {
	for _, cs2 := range []float64{0.25, 0.5, 1, 2} {
		for _, lw := range phGridLaws() {
			for _, rho := range []float64{0.3, 0.6, 0.85} {
				m := &mxq{c: 1, s: 1, cs2: cs2, lam: rho / lw.ex, q: lw.q}
				sol, err := m.phSolve(lw.sizes)
				if err != nil {
					t.Fatal(err)
				}
				one := m.solveOne(len(lw.q) - 1)
				tag := fmt.Sprintf("c 1 cs2 %g %s rho %g", cs2, lw.name, rho)
				phClose(t, tag+" W0", sol.W0, one.W0, 1e-9)
				phClose(t, tag+" Wbar", sol.Wbar, one.Wbar, 1e-9)
				for _, k := range lw.sizes {
					phClose(t, fmt.Sprintf("%s MS[%d]", tag, k), sol.MS[k], one.MS[k], 1e-9)
					if cs2 <= 1 {
						phClose(t, fmt.Sprintf("%s MSsq[%d]", tag, k), sol.MSsq[k], one.MSsq[k], 1e-9)
						phClose(t, tag+" W0sq", sol.W0sq, one.W0sq, 1e-9)
					} else if k == lw.sizes[0] && rho == 0.85 {
						t.Logf("%s: MSsq[%d] H2 %.6f, gamma closed form %.6f (third moment 18 vs 15)", tag, k, sol.MSsq[k], one.MSsq[k])
					}
				}
			}
		}
	}
}

// phSample draws one service of the phase law.
func phSample(ph *phLaw, rng *rand.Rand) float64 {
	u := rng.Float64()
	i := 0
	for acc := ph.alpha[0]; u > acc && i+1 < len(ph.alpha); acc += ph.alpha[i] {
		i++
	}
	t := 0.0
	for {
		t += rng.ExpFloat64() / ph.out[i]
		v := rng.Float64() * ph.out[i]
		if v < ph.t0[i] {
			return t
		}
		v -= ph.t0[i]
		next := -1
		for _, mv := range ph.mv[i] {
			if v < mv.r {
				next = mv.to
				break
			}
			v -= mv.r
		}
		if next < 0 {
			return t
		}
		i = next
	}
}

// phDES simulates the FIFO M^X/PH/c queue and returns the mean and second moment of the makespan of batches of size
// k, the mean first-member wait, and their batch-means standard errors.
func phDES(c int, ph *phLaw, lam float64, q []float64, k int, n int, seed uint64) (ms, ms2, w0, seMS, seMS2 float64) {
	rng := rand.New(rand.NewPCG(seed, seed^0x51ed270b))
	free := make([]float64, c)
	cum := make([]float64, len(q))
	for i := 1; i < len(q); i++ {
		cum[i] = cum[i-1] + q[i]
	}
	const blocks = 50
	var b1, b2 [blocks]float64
	var bn [blocks]int
	tm := 0.0
	warm := n / 20
	cnt := 0
	for b := 0; b < warm+n; b++ {
		tm += rng.ExpFloat64() / lam
		u := rng.Float64()
		x := 1
		for x < len(q)-1 && u > cum[x] {
			x++
		}
		end, first := 0.0, 0.0
		for j := 0; j < x; j++ {
			w := 0
			for i := 1; i < c; i++ {
				if free[i] < free[w] {
					w = i
				}
			}
			st := math.Max(tm, free[w])
			if j == 0 {
				first = st - tm
			}
			free[w] = st + phSample(ph, rng)
			end = math.Max(end, free[w])
		}
		if b < warm {
			continue
		}
		w0 += first
		cnt++
		if x == k {
			d := end - tm
			bi := (b - warm) * blocks / n
			b1[bi] += d
			b2[bi] += d * d
			bn[bi]++
		}
	}
	w0 /= float64(cnt)
	tot := 0
	for i := range bn {
		ms += b1[i]
		ms2 += b2[i]
		tot += bn[i]
	}
	ms /= float64(tot)
	ms2 /= float64(tot)
	var v1, v2 float64
	for i := range bn {
		d1 := b1[i]/float64(bn[i]) - ms
		d2 := b2[i]/float64(bn[i]) - ms2
		v1 += d1 * d1
		v2 += d2 * d2
	}
	return ms, ms2, w0, math.Sqrt(v1 / blocks / (blocks - 1)), math.Sqrt(v2 / blocks / (blocks - 1))
}

// The PH solution against a simulation of the same PH queue, away from the exponential.
func TestPHAgainstDES(t *testing.T) {
	cases := []struct {
		c   int
		cs2 float64
		rho float64
		law int // index in phGridLaws
		k   int
	}{
		{2, 0.5, 0.6, 0, 2}, {3, 0.25, 0.6, 3, 8}, {3, 2, 0.6, 2, 4}, {4, 0.5, 0.85, 1, 4},
	}
	laws := phGridLaws()
	for i, cs := range cases {
		lw := laws[cs.law]
		lam := cs.rho * float64(cs.c) / lw.ex
		m := &mxq{c: cs.c, s: 1, cs2: cs.cs2, lam: lam, q: lw.q}
		sol, err := m.phSolve(lw.sizes)
		if err != nil {
			t.Fatal(err)
		}
		ph, _ := phFit(1, cs.cs2)
		ms, ms2, w0, se, se2 := phDES(cs.c, ph, lam, lw.q, cs.k, 1500000, uint64(11+i))
		z, z2 := (sol.MS[cs.k]-ms)/se, (sol.MSsq[cs.k]-ms2)/se2
		t.Logf("c %d cs2 %g rho %g %s k %d: MS %.5f DES %.5f +- %.5f (%.1f SE); MSsq %.4f DES %.4f +- %.4f (%.1f SE); W0 %.5f DES %.5f",
			cs.c, cs.cs2, cs.rho, lw.name, cs.k, sol.MS[cs.k], ms, se, z, sol.MSsq[cs.k], ms2, se2, z2, sol.W0, w0)
		if math.Abs(z) > 4.5 || math.Abs(z2) > 4.5 {
			t.Errorf("c %d cs2 %g %s k %d: the PH solution is %.1f / %.1f SE from its simulation", cs.c, cs.cs2, lw.name, cs.k, z, z2)
		}
	}
}

type phGridLaw struct {
	name  string
	q     []float64
	sizes []int
	ex    float64
}

func phGridLaws() []phGridLaw {
	u := make([]float64, 7)
	for k := 1; k <= 6; k++ {
		u[k] = 1.0 / 6
	}
	x18 := make([]float64, 9)
	x18[1], x18[8] = 0.5, 0.5
	return []phGridLaw{
		{"X2", []float64{0, 0, 1}, []int{2}, 2},
		{"X4", []float64{0, 0, 0, 0, 1}, []int{4}, 4},
		{"U16", u, []int{1, 2, 3, 4, 5, 6}, 3.5},
		{"X18", x18, []int{1, 8}, 4.5},
	}
}

type phCase struct {
	C    int                `json:"c"`
	CS2  float64            `json:"cs2"`
	Rho  float64            `json:"rho"`
	Law  string             `json:"law"`
	Lam  float64            `json:"lam"`
	MS   map[string]float64 `json:"MS"`
	MSsq map[string]float64 `json:"MSsq"`
	W0   float64            `json:"W0"`
	Wbar float64            `json:"Wbar"`
	Ms   float64            `json:"ms"`
}

type phFile struct {
	Lane  string   `json:"lane"`
	Cases []phCase `json:"cases"`
}

// The grid of GRID.md, written to $PH_OUT (merged with what is there, one case per (c, cs2, rho, law)). Each c is
// a subtest, so the c = 8 cases can run in a command of their own: -run 'TestPHGrid/c=8'.
func TestPHGrid(t *testing.T) {
	out := os.Getenv("PH_OUT")
	if out == "" {
		t.Skip("PH_OUT is not set")
	}
	laws := phGridLaws()
	lawIdx := map[string]int{}
	for i, lw := range laws {
		lawIdx[lw.name] = i
	}
	for _, c := range []int{2, 3, 4, 8} {
		t.Run(fmt.Sprintf("c=%d", c), func(t *testing.T) {
			var got []phCase
			for _, cs2 := range []float64{0.25, 0.5, 1, 2} {
				for _, rho := range []float64{0.3, 0.6, 0.85} {
					for _, lw := range laws {
						lam := rho * float64(c) / lw.ex
						m := &mxq{c: c, s: 1, cs2: cs2, lam: lam, q: lw.q}
						t0 := time.Now()
						sol, err := m.phSolve(lw.sizes)
						el := float64(time.Since(t0).Microseconds()) / 1000
						if err != nil {
							t.Fatalf("c %d cs2 %g rho %g %s: %v", c, cs2, rho, lw.name, err)
						}
						cs := phCase{C: c, CS2: cs2, Rho: rho, Law: lw.name, Lam: lam, MS: map[string]float64{},
							MSsq: map[string]float64{}, W0: sol.W0, Wbar: sol.Wbar, Ms: el}
						for _, k := range lw.sizes {
							cs.MS[strconv.Itoa(k)] = sol.MS[k]
							cs.MSsq[strconv.Itoa(k)] = sol.MSsq[k]
						}
						got = append(got, cs)
						t.Logf("c %d cs2 %g rho %.2f %-3s: %s, D %d, boundary %d, levels %d, states %d, member %d, G iters %d (|G1-1| %.1g), tail %.1g, busy err %.1g, %.1f ms",
							c, cs2, rho, lw.name, sol.Phase, sol.D, sol.Boundary, sol.Levels, sol.States, sol.Member, sol.GIter,
							sol.GRowErr, sol.Tail, sol.Busy-lam*lw.ex, el)
						if sol.Tail > 1e-12 || math.Abs(sol.Busy-lam*lw.ex) > 1e-9 || sol.GRowErr > 1e-12 {
							t.Errorf("c %d cs2 %g rho %g %s: tail %.2g, busy %.12g vs %.12g, |G1-1| %.2g", c, cs2, rho, lw.name,
								sol.Tail, sol.Busy, lam*lw.ex, sol.GRowErr)
						}
						if lw.sizes[0] == 1 {
							phClose(t, fmt.Sprintf("c %d cs2 %g rho %g %s MS[1] = W0 + s", c, cs2, rho, lw.name), sol.MS[1], sol.W0+1, 1e-10)
						}
					}
				}
			}
			// merge into the file
			var f phFile
			if b, err := os.ReadFile(out); err == nil {
				if err := json.Unmarshal(b, &f); err != nil {
					t.Fatalf("%s: %v", out, err)
				}
			}
			f.Lane = "C"
			key := func(x phCase) string { return fmt.Sprintf("%d/%g/%g/%s", x.C, x.CS2, x.Rho, x.Law) }
			byKey := map[string]phCase{}
			for _, x := range f.Cases {
				byKey[key(x)] = x
			}
			for _, x := range got {
				byKey[key(x)] = x
			}
			f.Cases = f.Cases[:0]
			for _, x := range byKey {
				f.Cases = append(f.Cases, x)
			}
			sort.Slice(f.Cases, func(i, j int) bool {
				a, b := f.Cases[i], f.Cases[j]
				if a.C != b.C {
					return a.C < b.C
				}
				if a.CS2 != b.CS2 {
					return a.CS2 < b.CS2
				}
				if a.Rho != b.Rho {
					return a.Rho < b.Rho
				}
				return lawIdx[a.Law] < lawIdx[b.Law]
			})
			b, err := json.MarshalIndent(f, "", " ")
			if err != nil {
				t.Fatal(err)
			}
			if err := os.WriteFile(out, append(b, '\n'), 0o644); err != nil {
				t.Fatal(err)
			}
			t.Logf("wrote %d cases to %s", len(f.Cases), out)
		})
	}
}

// The cost at the cap: c = 8 with Erlang-4 services (165 configurations per level), the heaviest load and batch law.
func TestPHCostAtCap(t *testing.T) {
	lw := phGridLaws()[3]
	for _, cs2 := range []float64{0.25, 0.5, 2} {
		m := &mxq{c: 8, s: 1, cs2: cs2, lam: 0.85 * 8 / lw.ex, q: lw.q}
		t0 := time.Now()
		sol, err := m.phSolve(lw.sizes)
		if err != nil {
			t.Fatal(err)
		}
		t.Logf("c 8 cs2 %g rho 0.85 X18: %s, D %d, boundary %d, levels %d, law states %d, makespan states %d, G iters %d, tail %.1g: %.0f ms",
			cs2, sol.Phase, sol.D, sol.Boundary, sol.Levels, sol.States, sol.Member, sol.GIter, sol.Tail,
			float64(time.Since(t0).Microseconds())/1000)
	}
}

// Just above cs2 = 1 (media's fitted 1.04-1.11) the three-moment H2 is a law and the makespan is continuous through the
// exponential: no NaN, and within 0.5% of cs2 = 1 at cs2 1.0001.
func TestPHContinuousAtOne(t *testing.T) {
	for _, c := range []int{2, 4, 8} {
		var ms1 float64
		for _, cs2 := range []float64{1, 1.0001, 1.01, 1.04, 1.11} {
			m := &mxq{c: c, s: 1, cs2: cs2, lam: 0.6 * float64(c) / 1.5, q: []float64{0, 0.5, 0.5}}
			ps, err := m.phSolve([]int{1, 2})
			if err != nil || math.IsNaN(ps.MS[2]) || math.IsNaN(ps.W0) {
				t.Fatalf("c %d cs2 %v: %v", c, cs2, err)
			}
			if cs2 == 1 {
				ms1 = ps.MS[2]
			}
			if cs2 == 1.0001 && math.Abs(ps.MS[2]-ms1) > 0.005*ms1 {
				t.Errorf("c %d: MS[2] %v at cs2 1.0001 against %v at 1", c, ps.MS[2], ms1)
			}
		}
	}
}

// The parallel multiply splits rows, each summed in the same order: the solution is bit-identical at any GOMAXPROCS,
// as sealed predictions need (8 workers at cs2 0.25: 165 configurations, past the 48 rows where it goes parallel).
func TestPHDeterministic(t *testing.T) {
	m := &mxq{c: 8, s: 1, cs2: 0.25, lam: 0.6 * 8 / 1.5, q: []float64{0, 0.5, 0.5}}
	prev := runtime.GOMAXPROCS(1)
	defer runtime.GOMAXPROCS(prev)
	a, err := m.phSolve([]int{1, 2})
	if err != nil {
		t.Fatal(err)
	}
	runtime.GOMAXPROCS(8)
	b, err := m.phSolve([]int{1, 2})
	if err != nil {
		t.Fatal(err)
	}
	if a.W0 != b.W0 || a.W0sq != b.W0sq || a.Wbar != b.Wbar || a.MS[2] != b.MS[2] || a.MSsq[2] != b.MSsq[2] {
		t.Errorf("GOMAXPROCS 1 and 8 differ: %v %v / %v %v", a.MS[2], a.W0, b.MS[2], b.W0)
	}
}
