# Cluster test 3: results (2026-11-02, live on AWS)

**Does the fixed rhobound work on the real bed?** Yes, with one bed bug found and fixed on the way.

The bed ran CLI 91a039e2 (`maze-fix-rvar`), the policy with two more doubts, per-route items and payload bytes. Every
outcome was declared (CT3-DECLARE.md) and every prediction sealed (SEALED-CT3.md, 1ce8c26) before any truth window.

## Timeline

| time (UTC) | step |
|---|---|
| 13:39–13:47 | Seed, core bootstrap (7 min: the images were already in ECR), verifier, runner |
| 13:53 | Production fit. Every service within ±4% (search-api −1.4%; it was −37% on the first run's bed) |
| 13:54–14:50 | Six PRs, one at a time |
| 14:51–15:44 | Three truth brackets (300-s B0 and C windows at 120 rps; 30 windows, 0 errors), each rolled back |

## Verdicts

| PR | change | declared | bed verdict | truth (worst entry) | right? |
|---|---|---|---|---|---|
| 17 | c21, pricing echoes a version | pass | inconclusive, `ab.payload_changed` | — | **Declaration wrong; the bed right.** Pricing's responses went from 16 to 32 bytes, so it was not byte-neutral (amendment 1) |
| 18 | catalog /search +6.5 ms | block | **block** (`mean_change@search-api`) | search-api **+6.37** | **yes** |
| 19 | pricing +0.5 ms | inconclusive | **inconclusive** (straddle) | checkout +2.25 | safe (a pass would have been right) |
| 20 | media thumbnails at 48 KiB | inconclusive, payload | **inconclusive**, `ab.payload_changed` (16 KiB → 48 KiB) | — (first run: +0.9 to +1.4) | as declared |
| 21 | the agent's pricing fix | pass | **pass** | partner **−17.30** | **yes** |
| 22 | pricing, an equal form (byte-neutral) | pass | **pass** | — | **yes** (the control) |

**No wrong pass and no wrong block.** Every declared verdict held, apart from row 17, where the chosen control was not
a no-op.

## Predictions against truth (one bracket each; noise 2.0 ms; fit = inside, or within 2 × noise)

| PR | entry | sealed change | truth | fit |
|---|---|---|---|---|
| 18 | search-api | +5.78..+6.60 | +6.37 | **inside the band** |
| 19 | checkout | +1.32..+1.85 | +2.25 | Y (0.4 above) |
| 19 | partner | +2.34..+3.29 | +1.16 | Y (1.2 below) |
| 21 | checkout | −7.93..−7.62 | −10.12 | Y (2.2 more negative) |
| 21 | partner | −15.75..−15.04 | −17.30 | Y (1.6 more negative) |

All 5 touched entries fit.

PR 21 under-states the improvement by about 2 ms on both entries. The first AWS run measured this same fix at −18.8 and
−9.2, so on this bed the model is consistently a little conservative on it. PR 19's partner and checkout miss in
opposite directions. With one bracket each, that is within noise, but worth a second bracket before reading anything
into it.

## The decisive comparison: PR 18 with and without per-route items

The A/B measured catalog's routes: /search +6.17 ms and /item −0.01 ms, which blend to +1.46 ms.

| what the bed sends | search-api predicted | gate | truth |
|---|---|---|---|
| one blended item (the bed before today) | +1.33..+1.63 | pass | +6.37: **a wrong pass** |
| one item per route (`ROUTE_ITEMS=on`) | +5.78..+6.60 | **block** | +6.37: right, inside the band |

The blended figure comes from the same CLI, fit and record, re-predicted on tools1 (not part of the seal).

## What broke, and was fixed live

**`sign.sh` and per-route items.**
- **What happened:** with per-route items, change.json cites the A/B record once per route. `sign.sh` compared that
  list with the A/B's record set, so PR 18's verdict (block) was computed but not signed.
- **The fix** (kit c2980cb): the evidence is compared as a set. `t_routes.sh` now signs too. The fix was re-installed
  on tools1, and PR 18 was signed at 14:14:06Z, verdict block.
- **What remains:** the GitHub commit status still reads the sign failure.
- **Why it slipped through:** the offline glue test ran predict only.

**Before up:** the CI fixture `ab-record-6ms.json` was re-made. The new CLI refuses records whose finding text is not
its own (kit debe1ad).

## What this run shows, and what it does not

- **Shown live:**
  - per-route items reach the bed and turn a would-be wrong pass into a right block, inside the band;
  - the payload doubt fires on real byte changes and on nothing else;
  - the modelled-doubt rule releases a real improvement;
  - a byte-neutral control passes;
  - the exact batch queue's predictions fit.
- **Not shown:**
  - one bracket per dose is thin (noise 2.0 ms);
  - PR 19 was held where a pass would have been right;
  - the gate's new lower-bound rule (`workers_unbounded`) was not exercised, because no lower-bound service was raised;
  - the Meta agent did not run.
- **Not made permanent:** none of the following has moved to the bed's permanent configuration.
  The machines go away with `down`.
  - The bed used the new CLI, policy and settings for this test only.
  - The bed repo's main carries the policy commit 7ccb692.
  - Planted PRs 17–22 stay open as drafts and are never merged.
