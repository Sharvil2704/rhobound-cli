Title: Search results should show the bulk price

Business customers buy in volume, but they only see the volume discount once their cart is priced at checkout. Every
search result should also carry its bulk price: what one unit costs when 50 are bought, exactly as pricing charges it.

In catalog (maze/app/internal/svc/catalog/catalog.go):
- add `type Hit struct { ID int; BulkCents int }` and `func SearchHits(terms []string, k int) []Hit`, which returns
  Search's results in Search's order, each with its bulk price: pricing.Quote (maze/app/internal/svc/pricing) for a
  line of 50 units of the product, divided by 50 and rounded to the nearest cent (half up);
- the /search hook (catalog.search) answers with SearchHits(query(), 20), written as [id:cents id:cents ...] (today it
  writes [id id ...]).

Acceptance criteria:
1. SearchHits returns exactly the ids Search returns, in the same order, each with the bulk price defined above.
2. The catalog.search hook answers with the hits of its query as [id:cents id:cents ...].
3. Nothing else changes: Search, /item, the merge, pricing, and every existing exported name and signature. Safe for
   concurrent use. Standard library and the module's own packages only; change only files under
   maze/app/internal/svc/catalog/ (pricing belongs to another team).

Latency SLO: no user-facing entry's mean latency (web /browse, mobile /feed, search-api /q, checkout /buy,
partner /bulk) may rise more than 4 ms.

How it is judged: hidden tests check 1-3, and the change must meet the latency SLO on the running services.
