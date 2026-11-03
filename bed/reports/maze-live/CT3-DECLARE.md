# Cluster test 3: declaration (written 2026-11-02 ~13:20Z, before the cluster is up and before any A/B or truth)

**The question:** does the fixed engine really work on a live cluster? The bed was made harder for this run.

## What the bed runs now (kit changes, committed before `up`)

- **The CLI:** rhobound from the private branch `maze-fix-rvar` = 91a039e2 (was bed-spec3 19baaed), both amd64 for
  tools1 and arm64 for the policy digest, from one git archive. It brings:
  - route nodes;
  - the exact M^X/PH/c batch queue;
  - the Lean findings' fixes;
  - the modelled-doubt rule;
  - per-route items;
  - payload bytes;
  - rule 10's `workers_unbounded`.
- **The policy:** `repo/policy/gate.json` adds `profile.route_heterogeneous` and `ab.payload_changed` to
  `doubts_that_hold`. RBD_POLICY_SHA256 is 0218ca48…; RBD_POLICY_DIGEST is sha256:ccfbd1e1….
- **The run's knobs** (rbd.env.local): `ROUTE_ITEMS=on` (one own_ms item per route) and `AB_LOG_BYTES=1` (abdrive
  `-log-bytes`, so `ab.payload_changed` can fire), plus the run's window settings.

## The PRs (draft, labelled rbd-plant, never merged), one at a time

| PR | plant | dose | expected bed verdict | why |
|---|---|---|---|---|
| 1 | c21 | pricing echoes a version string (no-op) | **pass** | the control for the CLI swap and the re-pin |
| 2 | c17 | catalog GET /search +6.5 ms of CPU, /item untouched | **block** | Per-route items give search-api about +5.8 to +6.0 ms (the A/B saw 0.9 of the dose on /search in CT2), and the model-band low end, about 4.5, is above 4. The old blended item would give about +1.3 and pass. |
| 3 | c18 | pricing +0.5 ms per quote (batch-fed; now the exact phase-type queue) | **inconclusive** (straddle) | Half of CT2's +1 ms, which predicted partner +6.42..+7.31 against a truth of +6.12. Expected partner about +3 to +3.5 and checkout about +1.8, with the band's high end above 4. |
| 4 | c19 | media thumbnails at 48 KiB (= c4) | **inconclusive** (`ab.payload_changed`) | The response bytes rise well over 10%, the doubt holds now, and the record shows `loadgen.response_bytes`. c4's truth was +0.9 to +1.4 ms, so a pass would not be wrong; the point is the payload pipeline end to end. |
| 5 | c20 | the Meta agent's pricing fix (PRC-77, = t-c10) | **pass** | The improvement (partner −18.8 ms true on AWS run 1). Its variance doubt is modelled by the derived `own_var_ms2`, so the doubt rule drops it. |

## Truth brackets (verify/truth.sh, 300-s B0 and C windows)

- **c17,** then **c18**, then, as time allows, **c20**.
- Noise is 2.0 ms for one bracket.
- Fit rule (unchanged): the truth is inside the change band, or within 2 × noise of it, on the touched entries
  (c17: search-api; c18 and c20: partner and checkout).
- A wrong pass is a pass on a dose whose true worst entry is over +4 ms.

## What would count as failure

- PR 1 not passing: the CLI swap or re-pin broke something.
- PR 2 passing: route items did not reach the bed.
- Any wrong pass.
- PR 4 without `ab.payload_changed` in its record: the bytes did not reach diff-fit.
- PR 5 not passing: the doubt rule did not apply live.
- A truth outside its band beyond 2 × noise.

The old model (19baaed) is not sealed this time. It cannot read the A/B's 6-column load log, and its failure modes on
these doses were measured in run 1 and CT2. Its binaries are kept in `build/old-19baaed/`.

## Amendment 1 (14:08Z, after PR 1 gated; before PR 6 opens)

PR 1 (c21, PR #17) was held at inconclusive by `ab.payload_changed` on pricing, not passed. Its A/B record shows
pricing's mean response going from 16 to 32 bytes: c21 echoes a version string, so it is a payload change and not a
byte-neutral control. The doubt fired as designed, the first live evidence for row 4.

A byte-neutral control is added:

| PR | plant | change | expected |
|---|---|---|---|
| 6 | c22 | pricing's line total written in an equal form, `t*1000 - t*d` for `t*(1000-d)`: the same integers, a different binary | **pass** |

If the compiler emits the same binary, the A/B refuses an identical image, and that is reported as is.
