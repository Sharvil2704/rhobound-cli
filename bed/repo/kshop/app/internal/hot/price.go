package hot

import (
	"unicode"
	"unicode/utf8"
)

// Promotion codes and their percent off every line of a cart. Codes are compared after Fold.
var promotions = []struct {
	Code string
	Pct  int64
}{
	{"SAVE10", 10}, {"SPRING15", 15}, {"QUARTER", 25}, {"HALF", 50},
	{"ÉTÉ25", 25}, {"NOËL50", 50}, {"ＶＩＰ２０", 20},
}

var promoFolded [7]string

func init() {
	for i, p := range promotions {
		promoFolded[i] = Fold(p.Code)
	}
}

func promoPercent(code string) int64 {
	lo, hi := trimIndices(code, 0, len(code))
	if lo >= hi {
		return 0
	}
	isASCII := true
	for i := lo; i < hi; i++ {
		if code[i] >= 0x80 {
			isASCII = false
			break
		}
	}
	if isASCII {
		l := hi - lo
		switch l {
		case 6:
			if asciiMatch(code, lo, hi, promoFolded[0]) {
				return promotions[0].Pct
			}
		case 8:
			if asciiMatch(code, lo, hi, promoFolded[1]) {
				return promotions[1].Pct
			}
		case 7:
			if asciiMatch(code, lo, hi, promoFolded[2]) {
				return promotions[2].Pct
			}
		case 4:
			if asciiMatch(code, lo, hi, promoFolded[3]) {
				return promotions[3].Pct
			}
		}
		return 0
	}
	for i := range promoFolded {
		if foldEqual(code, lo, hi, promoFolded[i]) {
			return promotions[i].Pct
		}
	}
	return 0
}

func asciiMatch(s string, lo, hi int, key string) bool {
	if hi-lo != len(key) {
		return false
	}
	for i := 0; i < len(key); i++ {
		c := s[lo+i]
		if 'A' <= c && c <= 'Z' {
			c += 'a' - 'A'
		}
		if c != key[i] {
			return false
		}
	}
	return true
}

func foldEqual(s string, lo, hi int, folded string) bool {
	i := lo
	j := 0
	for i < hi && j < len(folded) {
		r1, sz1 := utf8.DecodeRuneInString(s[i:hi])
		r2, sz2 := utf8.DecodeRuneInString(folded[j:])
		r1 = unicode.ToLower(r1)
		if r1 != r2 {
			return false
		}
		i += sz1
		j += sz2
	}
	return i == hi && j == len(folded)
}

func trimIndices(s string, lo, hi int) (int, int) {
	for lo < hi {
		c := s[lo]
		if c < 0x80 {
			if c == ' ' || c == '\t' || c == '\n' || c == '\v' || c == '\f' || c == '\r' {
				lo++
				continue
			}
			break
		}
		r, size := utf8.DecodeRuneInString(s[lo:hi])
		if unicode.IsSpace(r) {
			lo += size
			continue
		}
		break
	}
	for hi > lo {
		c := s[hi-1]
		if c < 0x80 {
			if c == ' ' || c == '\t' || c == '\n' || c == '\v' || c == '\f' || c == '\r' {
				hi--
				continue
			}
			break
		}
		r, size := utf8.DecodeLastRuneInString(s[lo:hi])
		if unicode.IsSpace(r) {
			hi -= size
			continue
		}
		break
	}
	return lo, hi
}

func parseNum(s string, lo, hi int) (int, bool) {
	if lo >= hi {
		return 0, false
	}
	p := lo
	neg := false
	if s[p] == '+' || s[p] == '-' {
		neg = s[p] == '-'
		p++
		if p >= hi {
			return 0, false
		}
	}
	v := 0
	for i := p; i < hi; i++ {
		c := s[i]
		if c < '0' || c > '9' {
			return 0, false
		}
		v = v*10 + int(c-'0')
		if v > 1000000 {
			return 0, false
		}
	}
	if neg {
		v = -v
	}
	return v, true
}

// Quote returns a cart's total in cents.
//
// A cart is "ID:QTY,ID:QTY,...", optionally followed by ";CODE" (a promotion code). ID is a catalog document ID
// (1..NumDocs), QTY 1..99; an item that does not parse or is out of range is ignored. An unknown code gives no
// discount. A known code takes its percent off every line. Each line's amount is unit cents x QTY x (100 - percent)
// / 100, rounded to whole cents; the total is the sum of the rounded lines.
func Quote(cart string) int64 {
	semi := -1
	for i := 0; i < len(cart); i++ {
		if cart[i] == ';' {
			semi = i
			break
		}
	}
	itemsEnd := len(cart)
	codeStart := len(cart)
	if semi >= 0 {
		itemsEnd = semi
		codeStart = semi + 1
	}
	var pct int64
	if codeStart < len(cart) {
		pct = promoPercent(cart[codeStart:])
	} else if semi >= 0 {
		pct = promoPercent("")
	} else {
		pct = promoPercent("")
	}
	mult := 100 - pct
	docs := Catalog()
	n := len(docs)
	var total int64
	start := 0
	for {
		end := itemsEnd
		for i := start; i < itemsEnd; i++ {
			if cart[i] == ',' {
				end = i
				break
			}
		}
		a, b := trimIndices(cart, start, end)
		if a < b {
			colon := -1
			for i := a; i < b; i++ {
				if cart[i] == ':' {
					colon = i
					break
				}
			}
			if colon >= 0 {
				id, ok1 := parseNum(cart, a, colon)
				qty, ok2 := parseNum(cart, colon+1, b)
				if ok1 && ok2 && id >= 1 && id <= n && qty >= 1 && qty <= 99 {
					base := docs[id-1].Cents * int64(qty) * mult
					q := base / 100
					r := base % 100
					switch {
					case r < 50:
						total += q
					case r > 50:
						total += q + 1
					default:
						if q&1 == 1 {
							total += q + 1
						} else {
							total += q
						}
					}
				}
			}
		}
		if end == itemsEnd {
			break
		}
		start = end + 1
	}
	return total
}
