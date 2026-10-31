Ticket INV-88: inventory must reject malformed stock requests

inventory's StockCheck (library 1.1: build tag kshop_v11, kshop/app/internal/work/lib_v11.go) accepts any item id. Ops
wants it to reject an item id that is not 1 to 64 characters of [A-Za-z0-9_-], and to keep in-process counters of the
rejected ids per reason (empty, too long, bad character) that a later change will export. Every id that is valid today
and matches that rule must still be accepted (the load generator sends path tails such as "stock" and "reserve"), the
check must be safe under concurrent requests, memory must stay bounded, and inventory's latency must stay within its
budget: inventory runs this on every stock and reserve request.

How to work:
1. rhobound_context with {"env": "prod"}: inventory's utilization and leverage, and the fit_id.
2. rhobound_budget with that fit_id and service "inventory".
3. Read the code, then write the change (write_file, complete files). Keep the kshop_v11 build constraint as it is.
4. rhobound_predict with {"env": "prod"} and the own_ms change you expect for inventory (a {lo, hi} range when unsure):
   its preview is advisory and never says pass; note its numbers.
5. submit_change with service "inventory", a short title, and a summary with the expected effect.
