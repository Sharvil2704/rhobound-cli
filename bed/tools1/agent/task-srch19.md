Ticket SRCH-19: Search should forgive typos

Customers who type "lanp" or "chaor" find nothing. In catalog.Search (maze/app/internal/svc/catalog/catalog.go), a title word
one edit away from a query term (one letter changed, added or dropped) must count as a match, scored like an exact
one. Exact matching and the scoring otherwise stay as they are.

Acceptance criteria:
1. A query word one edit from a title word matches that title; two edits away does not.
2. A query with only exact words still finds every product it finds today.
3. Safe for concurrent use; change only maze/app/internal/svc/catalog/; standard library only.

How it is judged: hidden tests (never shown to you) check 1-3; BenchmarkSearch measures the time per call; the change is then measured on
the running service before it ships.

How to work:
1. rhobound_context with {"env": "prod"}: catalog's utilization and leverage, and the fit_id.
2. rhobound_budget with that fit_id and service "catalog".
3. Read the code, then write the change (write_file, complete files).
4. rhobound_predict with {"env": "prod"} and the own_ms change you expect for catalog (a {lo, hi} range when unsure):
   its preview is advisory and never says pass; note its numbers.
5. submit_change with service "catalog", a short title, and a summary with the expected effect.
