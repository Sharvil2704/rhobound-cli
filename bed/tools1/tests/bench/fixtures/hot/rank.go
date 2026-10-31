// Package hot is a stand-in of kshop-hot's package (SPEC2 1) for the bench tests: only its shape matters here.
package hot

// canned: main

// Rank counts the runes of q (the real Rank scores a catalog).
func Rank(q string) int {
	n := 0
	for range q {
		n++
	}
	return n
}
