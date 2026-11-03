Title: Quotes should apply the best promotions

Marketing runs promotions, and a quote ignores them today. The /quote endpoint should apply the best combination of
the active promotions to the cart.

In pricing (maze/app/internal/svc/pricing/pricing.go):
- add `type Promotion struct { Code, Group, Kind string; MinQty, MinTotal, Value int }` and
  `var Promotions = []Promotion{...}`, holding exactly these, in this order:

  | Code | Group | Kind | MinQty | MinTotal | Value |
  |---|---|---|---|---|---|
  | SPRING10 | season | pct_line | 1 | 0 | 100 |
  | SUMMER15 | season | pct_line | 5 | 0 | 150 |
  | FLASH20 | season | pct_line | 12 | 0 | 200 |
  | BULK5 | volume | pct_line | 10 | 0 | 50 |
  | FREE1 | volume | free_unit | 6 | 0 | 1 |
  | FREE2 | volume | free_unit | 12 | 0 | 2 |
  | OFF500 | cart | fixed_cart | 0 | 10000 | 500 |
  | OFF2000 | cart | fixed_cart | 0 | 40000 | 2000 |
  | OFF5000 | cart | fixed_cart | 0 | 90000 | 5000 |
  | LOYAL3 | loyalty | pct_line | 1 | 0 | 30 |
  | WELCOME | loyalty | fixed_cart | 0 | 0 | 300 |
  | STACK7 | stack | pct_line | 3 | 0 | 70 |

- a combination is a set of promotions with at most one per Group. It is applied to a cart like this:
  1. start from each line's total as Quote computes it today: the line less its volume discount, rounded half up;
  2. for each pct_line promotion of the combination, in table order, each line with Qty >= MinQty loses Value per mille
     of its current total, rounded half up to the cent;
  3. for each free_unit promotion, in table order, each line with Qty >= MinQty loses Value units at its unit price
     (Cents), but never goes below 0;
  4. the cart's subtotal is the sum of the lines. For each fixed_cart promotion, in table order, the subtotal loses
     Value cents if it is at least MinTotal, but never goes below 0.

  The result is the cart's total.
- add `func QuotePromo(lines []Line) (total int, applied []string)`: the lowest total over all combinations, the empty
  one included, and the codes of the combination that gives it, sorted. Ties go to the combination with fewer
  promotions, then to the lexicographically smallest sorted list of codes.
- the /quote hook (pricing.quote) answers {"total":T,"promos":[...]} for its cart, with T and the codes from
  QuotePromo. Today it answers {"total":N} with N from Quote.

Acceptance criteria:
1. Promotion, Promotions and QuotePromo are as defined.
2. The pricing.quote hook answers as defined.
3. Nothing else changes: Quote keeps its meaning (the total without promotions), and every existing exported name and
   signature stays as it is. The code is safe for concurrent use, uses the standard library and the module's own
   packages only, and changes only files under maze/app/internal/svc/pricing/.

Latency SLO: no user-facing entry's mean latency (web /browse, mobile /feed, search-api /q, checkout /buy,
partner /bulk) may rise more than 4 ms.

How it is judged: hidden tests check 1-3, and the change must meet the latency SLO on the running services.
