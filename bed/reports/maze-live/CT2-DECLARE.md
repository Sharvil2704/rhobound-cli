# Cluster test 2: declaration (written 2026-11-02 ~04:41Z, before any of its A/B results or truths were read)

Three planted doses on the running maze cluster, as draft
PRs on Sharvil2704/rhobound-maze-bed (never merged), gated by the bed as before (CLI 19baaed, policy unchanged):

| PR | plant | dose (rhobound-maze branch) |
|---|---|---|
| 14 | c14-plant | catalog GET /search +5.0 ms of CPU; /item untouched (c14-search-slow) |
| 15 | c15-plant | pricing +1.0 ms of CPU per quote (c15-pricing-slow) |
| 16 | c16-plant | pricing echoes a version string: no-op control (c16-noop) |

Models scored, each on the PR's own 300-s A/B (no declared numbers):
- old: the bed's sealed prediction (19baaed, fit prod-0 e853e305);
- effbb804: batch + per-route own time + variance/structure/payload (reports/maze-live/FIXES.md), refit of prod-0;
- route nodes f1506f58: effbb804 plus route nodes in the topology (pre-registration
  a local pre-registration file, sha256 5828a997...).
Each new model in two change sets: "route" (one own_ms item per route when the A/B record has routes; the bed glue the
route lane asks for) and "blend" (one own_ms item per service: what the bed sends today).

Sealing: every model's bands and gate verdicts (bed policy, and W1 = bed with rule 4 lifted) are committed to
reports/maze-live/SEALED-CT2.md before the first truth window starts.

Truth: verify/truth.sh brackets (300-s B0 and C windows at 120 rps), one per dose in the order c14, c15, c16; then, as
time allows before the 08:53Z cap, a second bracket of c15 and c14. Truth per entry = mean over brackets of C - B0; noise
2.0 ms for one bracket (the AWS no-op spread), 2.0/sqrt(n) for n.

Scoring (fixed now):
- fit: truth within the change band or within 2 x noise of it, per touched entry (entries whose expected visits reach the
  dosed service: c14 search-api only; c15/c16 partner and checkout).
- wrong pass: a pass (bed or W1) on a dose whose true worst entry is over +4 ms. Wrong hold: a no-op that is not passed
  under the bed policy by a model whose fit is not misfit.
- Expected beforehand (from the dose predictions in fix/integrated/dose/, made on the prod-0 fits):
  c14 search-api: old about +1.2, new about +5.0 (route set); c15 partner: old about +1.75, new about +7.7;
  c16: about 0 for all. The blend set of the new models is expected to under-predict c14 by about 4x and, under
  route nodes (rule 4 no longer firing), to PASS it: the wrong pass the route glue exists to prevent.
