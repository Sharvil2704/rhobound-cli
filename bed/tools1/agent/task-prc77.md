Ticket PRC-77: Partner bulk quotes are slow: make pricing.Quote faster without changing a total

Partners send /bulk requests that ask pricing for 4 to 12 quotes at once, and checkout asks for one on every purchase.
pricing (maze/app/internal/svc/pricing/pricing.go) is one of the busiest services. Make Quote cheaper per call.

Acceptance criteria:
1. Same totals: for every cart Quote returns exactly the cents it returns today (the discount rules and the rounding,
   half up per line, stay as they are).
2. Safe for concurrent use.
3. Nothing else changes: every exported name and signature. Standard library only; change only maze/app/internal/svc/pricing/.

How it is judged: hidden tests (never shown to you) check 1-3 against today's totals; BenchmarkQuote measures the time per call; the change
is then measured on the running service before it ships.

How to work:
1. rhobound_context with {"env": "prod"}: pricing's utilization and leverage, and the fit_id.
2. rhobound_budget with that fit_id and service "pricing".
3. Read the code, then write the change (write_file, complete files).
4. rhobound_predict with {"env": "prod"} and the own_ms change you expect for pricing (a {lo, hi} range when unsure):
   its preview is advisory and never says pass; note its numbers.
5. submit_change with service "pricing", a short title, and a summary with the expected effect.
