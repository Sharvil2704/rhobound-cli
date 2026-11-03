# Cluster test 2: results (2026-11-02)

Three planted PRs on the AWS maze cluster were scored against measured truth, using the rule fixed in CT2-DECLARE.md:
- PR 14: catalog `/search` +5 ms;
- PR 15: pricing +1 ms;
- PR 16: a no-op.

Every prediction was sealed in commit 90960c7 (SEALED-CT2.md) before the first truth window started at 04:57Z.

## Truth

There were five `verify/truth.sh` brackets, run back to back from 04:57Z to 06:25Z:
- PR 14: two brackets;
- PR 15: two brackets;
- PR 16: one bracket.

Each window ran 300 s at 120.0 req/s with zero errors in all 10 windows. Every bracket rolled back, and the live
catalog and pricing images are the baseline digests (`72a23f0a…` and `eb8734e9…`, both 1/1 ready).

Truth is the mean over brackets of C − B0. Noise is 2.0 ms for one bracket and 1.41 ms for two.

| PR | dose | true worst entry | per bracket |
|---|---|---|---|
| 14 | catalog /search +5 ms | search-api **+5.36** | +5.73, +5.00 |
| 15 | pricing +1 ms | partner **+6.12** (checkout +4.49) | +4.94, +7.29 (checkout +2.94, +6.04) |
| 16 | no-op | search-api −0.12 (all entries ≤ 0) | — |

PRs 14 and 15 are both over the 4 ms limit, so the right verdict for each is **block**. PR 16 should **pass**.

## Fits on the touched entries (truth within the band, or within 2 × noise of it)

| model | PR 14 search-api | PR 15 partner | PR 15 checkout | PR 16 partner | PR 16 checkout | total |
|---|---|---|---|---|---|---|
| old (bed, 19baaed) | +0.87..+1.19 ✗ | +1.47..+1.66 ✗ | +1.16..+1.30 ✗ | ✓ | ✓ | 2/5 |
| effbb804, route set | +3.88..+4.93 ✓ | +6.42..+7.31 ✓ | +3.66..+4.16 ✓ | ✓ | ✓ | 5/5 |
| effbb804, blend set | +0.74..+1.16 ✗ | ✓ | ✓ | ✓ | ✓ | 4/5 |
| route nodes, route set | +3.95..+4.95 ✓ | +6.42..+7.31 ✓ | +3.66..+4.16 ✓ | ✓ | ✓ | **5/5** |
| route nodes, blend set | +0.82..+1.18 ✗ | ✓ | ✓ | ✓ | ✓ | 4/5 |

- **PR 15:** the old model under-predicted by about 4×. Both new models came within about 1 ms, because the batch term
  sees pricing's quotes as one batch per checkout.
- **PR 14:** the route set came in about 0.4 to 1.4 ms low, but fits. The blend set was 4.5 to 6.5× low, the same
  failure as c1.

## Gate verdicts against the truth (bed policy)

| model | PR 14 (should block) | PR 15 (should block) | PR 16 (should pass) |
|---|---|---|---|
| old | inconclusive (misfit) | inconclusive (misfit) | inconclusive (misfit) |
| effbb804, either set | inconclusive | **block** ✓ | inconclusive (misfit) |
| route nodes, route set | inconclusive (band +0.94..+8.58 straddles 4) | **block** ✓ | **pass** ✓ |
| route nodes, blend set | inconclusive (`profile.structure_changed` doubt) | **block** ✓ | **pass** ✓ |

- **Wrong passes:** none, for any model.
- **Wrong holds**, as declared (a no-op not passed by a model that is not misfit): none. effbb804's hold on PR 16 comes
  from rule 4 misfit at search-api, which is the fault route nodes removes.
- **PR 14 was held, not blocked, by every model.** That is safe, but the block was missed.

The route nodes model is the first one that got all three verdicts right or held them safely. It blocks the 1 ms pricing
change, which really cost the partner path +6.1 ms. It passes the no-op. It holds the /search change rather than passing
it.

## Against the declared expectations

- **PR 15, as declared:** old about +1.75 and new about +7.7 at partner. The truth is +6.1.
- **PR 16, as declared:** about 0 for every model.
- **PR 14, partly wrong.** The route set came out as expected (about +5.0 declared, +4.45 sealed mid-band, +5.36 true).
  The declaration also said the route nodes blend set would wrongly pass PR 14. It did not pass: catalog's
  `profile.structure_changed` doubt held it. Its prediction was still about 5× low (+1.0 against +5.36). Only the doubt
  stopped a wrong pass, and the doubt is a coincidence of this dose: the extra spin changed /search's own-time shape. A
  /search change that leaves the shape alone would get through. **The bed glue that sends one own_ms item per route is
  still required before the route-node binary goes into the bed.**

## Side observations (untouched entries; no bearing on the scoring)

- **PR 14 checkout:** +1.80 (+2.25, +1.35), where every model predicts 0. Checkout does not call /search. This is within
  2 × noise of 0, but it was positive in both brackets.
- **PR 16:** every entry came out slightly negative (−0.12 to −1.52), which is consistent with drift between windows in
  a single bracket.

## Files

- Scoring: `state/ct2_score.py` (local). Its output is `reports/maze-live/ct2/score.txt`.
- Truth inputs: `state/truth/t-c14{,-r2}`, `t-c15{,-r2}`, `t-c16` (`b0.load.json`, `c.load.json`, `truth.log`).
- Sealed predictions: `SEALED-CT2.md` (90960c7) and `ct2/{eff-all,rn-all}.json`.
