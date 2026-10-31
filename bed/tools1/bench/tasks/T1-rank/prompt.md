Title: Product search is too slow: make hot.Rank faster without changing its answers

The catalog service answers every /item request with one search: `hot.Rank(hot.NextQuery())`
(kshop/app/internal/hot/rank.go). Profiles show `Rank` is most of the service's CPU time, and catalog sits on the
storefront's critical path. Make `Rank` cheaper per call on the production query stream (`hot.NextQuery()`).

Acceptance criteria:

1. Same answers. For every query, `Rank(q)` returns exactly what it returns today: the same document IDs in the same
   order, scores equal within 1e-9 (relative), the same number of hits (at most 10; fewer when fewer documents match;
   none for a query without terms). The scoring rule and the order of equal scores are documented on `Rank`.
2. Safe for concurrent use: the service calls `Rank` from several goroutines at once. The tests run with `-race`.
3. Memory: whatever `Rank` keeps between calls may add at most 64 MB to the process's heap.
4. Nothing else changes: the catalog, the query log and the input generators (load.go), `Fold` (text.go, also used
   by pricing), `Quote`, and every exported name and signature of the package stay as they are.
5. Standard library only. Change only files under kshop/app/internal/hot/. The existing tests keep passing.

How it is judged: hidden tests check 1-4; a benchmark measures `Rank`'s time per call on the production query
distribution against today's code; the change is then measured on the running service before it ships.
