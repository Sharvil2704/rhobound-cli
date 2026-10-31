Title: Build the kshop image with Go 1.27

Platform is moving every Go service to Go 1.27. kshop's image is built by CI with a pinned Go builder (today
golang 1.26.9); the allowlisted Go 1.27 builder has the key "go127" in CI's base-image list.

Do not change any application code: a pull request never carries a Dockerfile. Ask for the new builder in the change
request, `rhobound-change.json` at the repository root:

    {"schema": "rbd.change-request/v2", "services": ["catalog", "pricing"], "summary": "<one paragraph>", "base": "go127"}

Acceptance criteria:

1. The pull request changes only `rhobound-change.json`, as above (catalog and pricing are the services gated; the
   image is shared by every service).
2. With the Go 1.27 builder the code behaves exactly as today: the existing and hidden tests pass unchanged.
3. The summary says what changes (the compiler and runtime, not the source) and what to watch (CPU per request of
   catalog's search and pricing's quote).

How it is judged: the hidden tests and the benchmarks of `Rank` and `Quote` run under both toolchains; the change is
then measured on the running services before it ships. No measurable difference is a valid outcome.
