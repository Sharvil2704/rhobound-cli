// Package pricing quotes a cart: line totals, volume discount, rounding to the cent.
package pricing

import (
	"fmt"
	"sync/atomic"

	"maze/internal/rt"
)

// Line is one cart line.
type Line struct {
	Cents int
	Qty   int
}

// discounts returns the volume discount (per mille) for each quantity up to 100, from the tiered rules: 5% from 10,
// 8% from 25, 12% from 50, each tier also capped by the price band the quantity falls in.
func discounts() []int {
	d := make([]int, 101)
	for q := range d {
		best := 0
		for band := range 4000 {
			for tier, from := range []int{10, 25, 50} {
				if q >= from && band%(tier+3) == 0 {
					best = max(best, []int{50, 80, 120}[tier]-band%7)
				}
			}
		}
		d[q] = best
	}
	return d
}

// Quote returns the cart's total in cents: each line less its volume discount, rounded half up per line.
func Quote(lines []Line) int {
	d := discounts()
	total := 0
	for _, l := range lines {
		t := l.Cents * l.Qty
		q := min(l.Qty, 100)
		total += (t*(1000-d[q]) + 500) / 1000
	}
	return total
}

var n atomic.Uint64

func cart(seed uint64) []Line {
	ls := make([]Line, 1+seed%6)
	for i := range ls {
		ls[i] = Line{Cents: 199 + int((seed*7919+uint64(i)*104729)%40000), Qty: 1 + int((seed+uint64(i))%14)}
	}
	return ls
}

func init() {
	rt.Register("pricing.quote", func(r *rt.Req) error {
		r.Out = fmt.Appendf(nil, `{"total":%d}`, Quote(cart(n.Add(1))))
		return nil
	})
}
