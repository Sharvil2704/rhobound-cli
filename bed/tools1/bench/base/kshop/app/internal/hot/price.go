package hot

import (
	"math"
	"strconv"
	"strings"
	"sync"
)

// Promotion codes and their percent off every line of a cart. Codes are compared after Fold.
var promotions = []struct {
	Code string
	Pct  int64
}{
	{"SAVE10", 10}, {"SPRING15", 15}, {"QUARTER", 25}, {"HALF", 50},
	{"ÉTÉ25", 25}, {"NOËL50", 50}, {"ＶＩＰ２０", 20},
}

var (
	promoOnce sync.Once
	promoPct  map[string]int64
)

func promoPercent(code string) int64 {
	promoOnce.Do(func() {
		promoPct = make(map[string]int64, len(promotions))
		for _, p := range promotions {
			promoPct[Fold(p.Code)] = p.Pct
		}
	})
	return promoPct[Fold(strings.TrimSpace(code))]
}

// Quote returns a cart's total in cents.
//
// A cart is "ID:QTY,ID:QTY,...", optionally followed by ";CODE" (a promotion code). ID is a catalog document ID
// (1..NumDocs), QTY 1..99; an item that does not parse or is out of range is ignored. An unknown code gives no
// discount. A known code takes its percent off every line. Each line's amount is unit cents x QTY x (100 - percent)
// / 100, rounded to whole cents; the total is the sum of the rounded lines.
func Quote(cart string) int64 {
	items, code, _ := strings.Cut(cart, ";")
	pct := promoPercent(code)
	docs := Catalog()
	var total int64
	for _, it := range strings.Split(items, ",") {
		ids, qs, ok := strings.Cut(strings.TrimSpace(it), ":")
		if !ok {
			continue
		}
		id, err1 := strconv.Atoi(ids)
		qty, err2 := strconv.Atoi(qs)
		if err1 != nil || err2 != nil || id < 1 || id > len(docs) || qty < 1 || qty > 99 {
			continue
		}
		line := float64(docs[id-1].Cents*int64(qty)*(100-pct)) / 100
		total += int64(math.Round(line))
	}
	return total
}
