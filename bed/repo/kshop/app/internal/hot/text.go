package hot

import "strings"

// Fold is the text normalisation shared by search and pricing: Rank folds the query and every title before it
// tokenizes them, Quote folds promo codes before it looks them up. A change here changes both services.
//
// Today it only lower-cases (strings.ToLower: Unicode simple case mapping, rune by rune).
func Fold(s string) string {
	return strings.ToLower(s)
}
