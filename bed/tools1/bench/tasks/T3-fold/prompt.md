Title: Search and promo codes must ignore accents and full-width characters

Customers who type "cafe" do not find products titled "Café"; phones with Japanese keyboards send full-width letters
("ＴＶ") that match nothing; promotion code "ETE25" is refused because the printed code is "ÉTÉ25". Search (catalog,
`hot.Rank`) and pricing (`hot.Quote`) both normalise text with one shared helper, `hot.Fold`
(kshop/app/internal/hot/text.go). Change `Fold` so that, for valid UTF-8 input:

1. Full-width ASCII forms U+FF01..U+FF5E become the ASCII characters U+0021..U+007E ("ＴＶ" folds to "tv").
2. Each letter in U+00C0..U+017F (Latin-1 Supplement and Latin Extended-A) whose Unicode canonical decomposition
   (NFD) is an ASCII letter followed only by combining marks becomes that ASCII letter (é -> e, Ç -> c, Ő -> o,
   İ -> i). Every other code point of that range is left as it is (æ, ð, ø, þ, ß, đ, ħ, ı, ĳ, ĸ, ŀ, ł, ŉ, ŋ, œ, ŧ, ſ,
   ×, ÷ ...) and lower-cased as today.
3. Combining marks U+0300..U+036F are removed (a decomposed "cafe" + U+0301 folds like "café").
4. Everything is lower-cased exactly as today: Unicode simple case mapping, rune by rune (as `strings.ToLower`).
   Text without any of the above folds exactly as today; in particular every ASCII string folds to
   `strings.ToLower` of it, and other scripts (Greek, Cyrillic, CJK ...) are unchanged.

Acceptance criteria:

- `Fold` behaves as 1-4. `Rank` and `Quote` keep using `Fold` where they do today, so search treats "cafe", "CAFÉ"
  and "Café" alike (scores follow the documented rule over the folded text) and promotion codes match across
  accents, case and width. The ranking rule, the order of equal scores and the cart rules are unchanged.
- Safe for concurrent use (the tests run with `-race`). Standard library only (no golang.org/x/text).
- Change only files under kshop/app/internal/hot/; the catalog, the query log, the input generators and every
  exported name and signature stay as they are; the existing tests keep passing.

How it is judged: hidden tests of `Fold`, `Rank` and `Quote`; benchmarks of `Rank` and `Quote` against today's code
(both services run this code on every request); the change is then measured on both running services before it
ships.
