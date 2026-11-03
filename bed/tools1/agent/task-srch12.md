Ticket SRCH-12: Search is slow: make catalog.Search faster without changing its answers

search-api's /q spends most of its time in catalog's /search, and profiles of catalog show Search
(maze/app/internal/svc/catalog/catalog.go) doing most of the CPU work on every query. Make Search cheaper per call.

Acceptance criteria:
1. Same answers: for every query Search returns exactly the ids it returns today, in the same order.
2. Safe for concurrent use: the service calls Search from several goroutines at once.
3. Nothing else changes: /item, the catalogue, the merge, every exported name and signature.
4. Standard library only. Change only files under maze/app/internal/svc/catalog/.

How it is judged: hidden tests (never shown to you) check 1-3 against today's answers; BenchmarkSearch measures the time per call; the
change is then measured on the running service before it ships.

How to work:
1. rhobound_context with {"env": "prod"}: catalog's utilization and leverage, and the fit_id.
2. rhobound_budget with that fit_id and service "catalog".
3. Read the code, then write the change (write_file, complete files).
4. rhobound_predict with {"env": "prod"} and the own_ms change you expect for catalog (a {lo, hi} range when unsure):
   its preview is advisory and never says pass; note its numbers.
5. submit_change with service "catalog", a short title, and a summary with the expected effect.
