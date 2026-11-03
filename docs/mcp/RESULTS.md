# Results on AWS (2026-10-30 / 31)

> **History.** This page records the October 2026 demo on the kshop bed. That bed has been replaced in `bed/` by the maze
> bed, and its files are in this branch's history (commit 04ea0e9). The current results are in
> [docs/RESULTS.md](../RESULTS.md).

The full loop ran on a live bed: a coding agent (Meta `muse-spark-1.3`) changes a microservice app through the MCP server,
the CI gate measures the new image in an isolated A/B and predicts its effect on every user-facing request, and only a
KMS-signed pass deploys. Each prediction below was hashed and committed before production was measured.

**Bed** ([bed/](../../bed/README.md)): 8 machines in AWS (k3s; 3 app nodes, an isolated A/B node, a load node, a
Collector node, a tools node with the CI runner), the demo shop kshop (10 Go services, OpenTelemetry), 100 req/s of
open-loop load (storefront 70, checkout 30). Policy: block when an entry's mean latency rises more than 4 ms.

**Truth** = the change deployed to production for a 300-s window between two production windows, then rolled back
(`bed/verify/truth.sh`); the entry's mean latency change, averaged over 2-3 runs per change.

## Prediction against production

| Change | Services | Entry | rhobound predicted (ms) | Production measured (ms) |
|---|---|---|---|---|
| Search ranking rewrite (agent, deployed) | catalog | catalog own time | -2.02 (A/B) | **-1.92** |
| A latency-heavy search approach (held by the gate) | catalog | storefront | +9.3 .. +10.5 | **+10.00** |
| payments +1.5 ms, asked at peak load (1.2x) | payments | checkout | +13.45 .. +19.26 | **+16.27** |
| catalog +10 ms CPU in a parallel fan-out | catalog | storefront | +7.21 .. +8.18 | **+8.17** |
| payments improvement (card hold 6 -> 2 ms) | payments | checkout | -7.38 .. -5.88 | **-4.22** |
| Security-hardened shared library, one image | auth, payments, inventory, catalog, pricing | storefront | +4.54 .. +6.55 | **+5.32** |
| (same) | | checkout | +12.80 .. +18.09 | **+14.28** |
| Two images at once: catalog +8 ms and pricing +4 ms CPU | catalog, pricing | storefront | +10.55 .. +13.20 | **+11.87** |
| (same) | | checkout | +9.72 .. +12.58 | **+9.43** |

- **One image in five services** is predicted as one change: five A/Bs (one per service) feed one prediction per entry.
- **Two images changed together** are predicted from their two separate A/Bs (`rhobound predict --fit F --changes C`
  with both measured items); no joint A/B is needed.
- **Fan-outs:** adding each service's measured delta overshoots a parallel fan-out (storefront: +13.7 against +8.2 for
  the 10-ms change, +21.2 against +11.9 for the two-image change). rhobound reads the call graph from the traces and lands
  on the measured value.
- **Peak load without a peak test:** `--load-scale 1.2` turns a today's-load A/B into the peak answer (+16.35 midpoint
  against +16.27 measured); the today's-load A/B alone says +9.55.

## The gate

| Verdict | Changes |
|---|---|
| **block** (kept out of production) | payments +1.5 ms, payments +3.0 ms, catalog +10 ms, shared library in 5 services, pricing +4 ms, catalog + pricing together |
| **pass** (signed, deployable) | the agent's pricing change (ticket PRC-41), cart rounding fix, text-folding fix in 2 services, search ranking rewrite, catalog no-op, three back-to-back no-op PRs |
| **held for review** (inconclusive) | the band crosses the 4 ms limit: catalog +8 ms alone, the latency-heavy search approach, Go 1.26.9 -> 1.27.3 rebuilds of 2 and of 5 services; the change altered its service's variance: the payments improvement, a first run of the search rewrite |

Each deployed pass moved the entries it reaches within its predicted band in production. A held change waits for a person or a
second gate run; the band narrows with a longer A/B (`AB_SECONDS`) and the block rule is set by the policy's
`block_band` ([USAGE.md](../USAGE.md)).

## Meta in the loop: automatic orchestration

- **Agent** (`bed/tools1/agent/agent.py`, Meta Model API `muse-spark-1.3`): takes a ticket, calls the MCP tools
  `context` -> `budget` -> `predict`, edits the code, and opens a PR that quotes its latency budget (e.g. 0.81 ms safe
  for pricing) and the predicted effect. 7 tool turns from ticket to PR; the PR passed the gate.
- **Approaches and review** (`bed/tools1/bench/`): the agent writes 4 competing approaches per task in a sandbox; hidden
  tests and a microbenchmark cut the wrong ones; Meta `muse-wonder-1.0` reviews the code; the best survivor becomes the PR.
- **Judge** (`bed/tools1/judge/meta-judge.py`): a second Meta model reads the gate's packet (`rhobound judge-packet`) and
  answers; `rhobound judge-check` admits only a typed answer, recorded with the verdict.
- **From ticket to production:** PR -> image build -> 300-s A/B per affected service -> predict + gate -> KMS-signed
  verdict -> automatic merge on a signed pass -> deploy (verifies the signature) -> refit. Ticket text to a
  production-checked change: 41 min (search rewrite), 65 min (2-service fix). No person in the loop.

## Time

| Step | Time |
|---|---|
| Prediction from a stored fit + a measured change (`predict --fit --changes`) | 27 ms |
| The same at another load (`--load-scale`) | 32 ms |
| Gate decision | 3.5 ms |
| MCP pre-check an agent runs while it edits (`context` / `budget` / `predict`) | 0.15 / 0.44 / 0.46 s |
| Fit from a 300-s capture (347,715 spans), 4 threads | 1.2 s (rbfast reads it 7-10x faster) |
| Full gate on AWS: build, A/B, predict, signed verdict | 7.2 min |

| Instead of | With rhobound | Saved per change |
|---|---|---|
| A peak-rate A/B (406 s + a peak-capable environment) | `--load-scale` what-if, 32 ms | ~7 min and the environment, for every load level asked |
| Deploy-and-measure in production (17 min, users exposed) | the gate, 7.2 min, isolated | ~10 min and no user exposure |
| A gate round trip before an agent knows its budget (~7 min) | MCP pre-check, under 0.5 s | ~7 min per edit |
| Gating all 4 agent approaches of each of 3 tasks (~137 min) | pre-gate selection + one gate per task (~34 min) | ~100 min over the 3 tasks |

## Scope

Mean latency of every service and entry, at steady load below the utilization limit, for changes that add or remove
time in a service (CPU, waits, locks, shared libraries, base images). Tails (p95 / p99), bursts, retries and autoscaling
are out of scope of this branch.
