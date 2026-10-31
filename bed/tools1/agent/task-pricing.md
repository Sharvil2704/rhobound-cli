Ticket PRC-41: pricing must apply bulk-quantity tiers

pricing's Quote (kshop/app/internal/hot/price.go) prices every line at unit cents x QTY, less the promotion percent. Sales
wants bulk tiers on top of the promotion: a line with QTY 10 to 49 gets 5 percent off and a line with QTY 50 to 99 gets
10 percent off, taken after the promotion percent on that line's amount (so a 20 percent code and the 10-to-49 tier give
76 percent of the list amount). Rounding stays exactly as today: whole cents per line, half to even, the total being the
sum of the rounded lines. A line below QTY 10 and a cart without tiers must price exactly as today, the existing tests
must still pass, and pricing's latency must stay within its budget: pricing runs Quote on every checkout.

How to work:
1. rhobound_context with {"env": "prod"}: pricing's utilization and leverage, and the fit_id.
2. rhobound_budget with that fit_id and service "pricing".
3. Read the code, then write the change (write_file, complete files). Keep any build constraint a file has as it is.
4. rhobound_predict with {"env": "prod"} and the own_ms change you expect for pricing (a {lo, hi} range when unsure):
   its preview is advisory and never says pass; note its numbers.
5. submit_change with service "pricing", a short title, and a summary with the expected effect.
