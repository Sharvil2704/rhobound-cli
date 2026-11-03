Title: Search should forgive typos

Customers who type "lanp" or "chaor" find nothing. In catalog.Search (maze/app/internal/svc/catalog/catalog.go), a
title word one edit away from a query term (one letter changed, added or dropped) must count as a match, scored like an
exact one. Exact matching and the scoring otherwise stay as they are.

Acceptance criteria:
1. A query word one edit from a title word matches that title; two edits away does not.
2. A query with only exact words still finds every product it finds today.
3. Safe for concurrent use; change only maze/app/internal/svc/catalog/; standard library only.

Latency SLO: no user-facing entry's mean latency (web /browse, mobile /feed, search-api /q, checkout /buy,
partner /bulk) may rise more than 4 ms.

How it is judged: hidden tests check 1-3, and the change must meet the latency SLO on the running services.
