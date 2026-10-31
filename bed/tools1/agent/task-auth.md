Ticket AUTH-142: auth got slower with library 1.1

Since the shared library moved to 1.1 (build tag kshop_v11, kshop/app/internal/work/lib_v11.go), auth's VerifyToken
re-derives a PBKDF2-SHA256 key on every request: about 3 ms of CPU per request. auth has few workers and sits on the
request path of storefront and checkout, so the whole shop pays for it.

Make token verification cheaper without weakening it: the same derivation (PBKDF2-SHA256, 2500 iterations, the same
salt, 32-byte keys) and the same accept/reject answer for every token, safe under concurrent requests, with bounded
memory. Change the kshop_v11 code path only.

How to work:
1. rhobound_context with {"env": "prod"}: where latency is tight, auth's utilization and leverage, and the fit_id.
2. rhobound_budget with that fit_id and service "auth": how much own time auth may add or must lose.
3. Read the code, then write the change (write_file, complete files).
4. rhobound_predict with {"env": "prod"} and the own_ms change you expect for auth (a negative number for a saving; a
   {lo, hi} range when unsure): its preview verdict is advisory and never says pass; note its numbers.
5. submit_change with service "auth", a short title, and a summary with the expected effect.
