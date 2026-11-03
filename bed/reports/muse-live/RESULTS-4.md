# Multi-image gate and parallel A/Bs: results

Written after the runs, against [DECLARE-4.md](DECLARE-4.md): sealed at 4904a79 before any run, with V1's note and V1b
declared at 498c700, before V1b. Bed 1 ran every run, with three A/B nodes (m7i.xlarge, on demand) from 15:55Z.

## The answer in short

**Both features work, and a multi-image change now passes faster than a bake.**
- **V4** (pricing + media, two images, one PR) **passed in 9.2 min** of R's own CI time, against a 5-min big-bang bake's
  15.5 min: a measured saving of 6.3 min, with production touched only for the rollout.
  - Its bracket of its own images (V5) measured production clean, and every entry landed inside its predicted band.
  - V4 passes all six sealed checks.
- **The costly train was caught faster than a bake,** with no exposure.
- **What was not reached:** a pass for the clean train M3, which sits right at the bar. V1 and V1b were both
  inconclusive, while production measured M3 clean.
- **Why:** the gate's mobile band rides on a widening of 2.4 to 2.8 ms (the model band's 1.65-ms floor plus a construct's
  widening), and M3's true mobile effect is about
  +1.4 ms. So each A/B's noise in rank's delta decides whether a longer A/B could still settle it (V1: yes, 1.5×) or not
  (V1b: no).
- **The longer A/B for multi-service changes** was built and installed. On the bed it ran only its declining branch: on
  V1b it correctly declined, since no length could decide. The branch that launches a parallel longer A/B of every
  service has run only in the offline tests.

- **A multi-image change is now one PR.**
  - CI built the three images in 46 s and ran the three A/Bs at once on three nodes, their 300-s windows overlapping
    fully.
  - It made one prediction over all three and signed one verdict on all three images.
- **The A/B step took 572 to 581 s,** against 1,400 to 1,413 s when the same three services were gated one after
  another this morning: about 2.4× faster. R's own CI time, from the first A/B to the signature, was 9.6 to 9.7 min.
- **The costly train (V2) was blocked in 9.7 min,** with no exposure and the cause named (media's utilization 0.80).
  - A 5-min big-bang bake needs 15.5 min to detect it, while users run +38 ms for 9 minutes, and cannot say which
    image did it.
  - This morning's one-gate-per-image path took 23.7 min.
  - So on a multi-image change, R is now faster than a bake, as well as safer.
- **One prediction is more honest than adding the gates.** V1 (the clean train M3) came back inconclusive, not the
  declared pass.
  - Rank and media both lie on mobile's /feed path, and the single model combines their uncertainty there: mobile's
    band reached +4.19, 0.19 ms over the bar. Gated separately, each had passed.
  - So this morning's additive rule, pass if every gate passes, had been optimistic. RESULTS-3 is amended.
  - V1's own images then measured clean in production (V3: mobile +1.52), so V1's hold was false.
- **Parallel A/Bs measured what sequential ones did, with one exception.** Five of six service comparisons agree with
  this morning's sequential gates (|z| ≤ 1.6).
  - The exception is the plant: +2.145 against +2.049 ms of media own time, z = 3.8, which fails the sealed 3-SE
    agreement.
  - It is not node speed: the baseline arm ran 0.9% faster on its node.
  - It is consistent with CPU saturation of the A/B node: own time × rate is about 4.5 cores on 4 vCPU, in sequential
    and parallel runs alike. That arithmetic is partly circular, since own time already includes queueing, and the
    node's CPU was not recorded.
  - The verdict is the same either way (block), and the difference is 4.7%.
- **The single prediction's centres were closer to the truth than the additive composition** at 4 of 5 entries in V1,
  5 of 5 in V2, and 4 of 5 in V1b (mobile was the exception in V1 and V1b).
  - Every one of the 25 entries checked landed inside its band:
    - V1, V2 and V1b against this morning's brackets;
    - V1 against V3's fresh bracket;
    - V4 against V5's.
  - The plant's cost near saturation was still underestimated: mobile's centre +26 against +38 measured, although the
    band, up to +43, held it.

## What ran

| run | PR | change | A/B nodes | A/B step | verdict | production truth |
|---|---|---|---|---|---|---|
| V1 | muse-r#15 | M3: rank T6 + pricing T8 + media T9 (separable), three images | ab1, ab2, ab3 | 572 s | **inconclusive**: mobile band +4.19 (rule 10), `ab_scale` 1.5 | clean (V3: checkout −10.39, mobile +1.52, partner −21.74, search-api +0.31, web +0.87) |
| V2 | muse-r#16 | M3n: rank + pricing + the media plant (direct 7×7), three images | ab1, ab2, ab3 | 581 s | **block**: `utilization_after` (media 0.80) and `mean_change` (mobile, web) | regression (morning bracket: mobile +38.0, web +38.4) |
| V3 | none | truthx bracket of V1's three new images | none | none | none | clean, as above |
| V1b | muse-r#17 | M3 again, with the multi-service longer A/B | ab1, ab2, ab3 | 575 s (+11 s preview) | **inconclusive**: mobile band +5.73; preview: `ab_scale` null, no longer A/B | V3 (clean) |
| V4 | muse-r#18 | pricing T8 + media T9 (separable), two images; only media touches mobile | ab1, ab2 | 544 s (+4 s preview) | **pass**: mobile band +2.87, every entry under 4 | clean (V5, a bracket of V4's own two images: checkout −7.71, mobile +1.44, partner −22.30, search-api +0.55, web +1.13) |

**How the code compares:** every run's service code is byte-identical to the morning's single-image gates (muse-r#10
to #13) and train brackets (`p3-m3-b1`, `p3-m3n-b1`). Builds are not reproducible, so the digests differ.

## Against the sealed criteria (DECLARE-4)

| criterion | V1 | V2 | V1b | V4 |
|---|---|---|---|---|
| 1. one PR, one image per service, one verdict on all of them | ok (3 digests, 3 attested) | ok | ok | ok (2, 2) |
| 2. the A/Bs at once, one node each | ok (common window 300 s) | ok (299 s) | ok (298 s) | ok (300 s, 2 nodes) |
| 3. A/B step ≤ 640 s | ok (572 s, against 1,400 s sequential) | ok (581 s, against 1,413 s) | ok (575 s) | ok (544 s, against 941 s) |
| 4. the verdict | **FAIL**: inconclusive, not pass | ok: block, `utilization_after` + `mean_change` | **FAIL**: inconclusive, no extension possible | ok: pass |
| 5. each delta within 3 combined SEs of its sequential gate | ok (rank z −0.46, pricing +0.36, media −1.57) | **FAIL** for the plant (z +3.83); rank −0.09, pricing +0.60 ok | ok (rank +1.14, pricing +0.74, media −0.75) | ok (pricing +0.46, media −1.24) |
| 6. every band contains the truth | ok, 5/5 (and 5/5 against V3) | ok, 5/5 | ok, 5/5 | ok, 5/5 against V5 |

**On the sealed bar, V4 passes all six, and V1, V2 and V1b each fail one criterion.** None of the failures is in the new
machinery:
- the builds, the parallel scheduling, the timing and the signing all held;
- V1's and V1b's failures are the single model being more conservative than this morning's composition rule, on a
  change that sits at the bar;
- V2's is a measurement on an A/B node too small for that arm pair.

## Per service: parallel against sequential (own time, ms, ± SE)

| service | morning, one gate at a time | V1 (parallel) | V2 (parallel) |
|---|---|---|---|
| rank | +0.195 ± 0.106 | +0.124 ± 0.114 | +0.181 ± 0.107 |
| pricing | −2.708 ± 0.028 | −2.694 ± 0.030 | −2.685 ± 0.028 |
| media (separable) | +0.132 ± 0.018 | +0.092 ± 0.018 | none |
| media (plant) | +2.049 ± 0.019 | none | **+2.145 ± 0.017** |

V1b (parallel): rank +0.361 ± 0.099, pricing −2.678 ± 0.029, media +0.112 ± 0.019.

**Why the plant's two readings differ:**
- **Absolute arm times:** baseline 4.146 ms on ab3 (V2) against 4.183 on ab1 (morning); candidate 6.291 against 6.232.
- **So not node speed:** the baseline arm ran faster on V2's node.
- **Saturation:**
  - each arm takes about 429 calls/s;
  - 4.15 and 6.29 ms of own time are about 1.8 + 2.7 cores of demand on a 4-vCPU node;
  - consistent with both runs being CPU-saturated, where own time includes run-queue wait (partly circular, as above;
    node CPU not recorded).
- **The product lesson:**
  - an A/B whose arm pair needs more cores than its node has measures queueing as well as code;
  - the gate should check the A/B node's CPU headroom before trusting such a delta;
  - or the A/B pool should use bigger nodes for hot services.

## The time a multi-image change takes now

| | R this morning (one gate per image) | R now (one gate, parallel A/Bs) | big-bang bake (B) | staged bake (S) |
|---|---|---|---|---|
| clean 2-image change (V4: pricing + media) | 2 gates in a row: 15.8 min (the morning's two gates, summed) | **9.2 min, pass** (measured), plus a rollout of seconds | 15.5 min (9.3 without B0) | about 24.7 min (computed) |
| clean 3-image change (M3) | 23.6 min to a composed pass | 9.6 min **to a verdict**, inconclusive both times: M3 sits at the bar (below) | 15.5 min (9.3 without B0) | 34.0 min |
| costly 3-image change | 23.7 min to reject | **9.7 min to reject**, no exposure, culprit named | 15.5 min to detect, 9.2 min of users at +38 ms, culprit unknown | 34.1 min, 9.3 min at +35 ms |
| clean change near the bar (V1) | not applicable (the composition said pass) | V1: 9.6 min, then inconclusive (a false hold): R falls back to a bake, so about 25 min in all; with a 1.5× longer A/B, about 20 min. V1b: 9.8 min, then the same fallback | 15.5 min | 34.0 min |

**What R's time is now:** one A/B (about 9.5 min, set by the 300-s A/B and its readiness and flush) plus 46 s of builds.
- It no longer grows with the number of images, up to the number of A/B nodes (3 here; the load node's drivers allow
  about 3).
- The production change window stays seconds, the rollout only.

## V1b: the longer A/B of a multi-service change

**What V1b was** (declared at 498c700, after V1): `abx` was extended to any service count. `ab.sh RUN --all SECONDS`
gives every child the longer A/B at once, and the preview reads every A/B of the run. M3 was then gated again as a new
commit with the same tree (muse-r#17).

**What happened:**
- **The first parallel A/B** (575 s) measured rank's own time at +0.361 ± 0.099 ms.
  - That is within noise of the morning's +0.195 ± 0.106 (z 1.14) and V1's +0.124 ± 0.114.
  - It is enough to move mobile's centre from +0.76 (V1) to +1.92 (V1b): rank feeds /feed with fan-out.
- **The preview's gate (11 s)** found that a zero-width range at that centre still crosses 4 ms: centre +1.92, plus the
  model band's 1.65 ms, plus the construct's 1.13 ms, is about 4.7. So `ab_scale` was null, no longer A/B ran, and the verdict was
  inconclusive.
- **This is the engine behaving as designed:** it does not promise that more measurement will decide a change whose
  measured centre leaves no room under the bar.
- **The widening, run by run:** 2.35 ms in V1 (model 1.65 + construct 0.70), 2.78 ms in V1b (1.65 + 1.13).

**Against the sealed criteria:** 1, 2, 3, 5 and 6 held. 4 failed (inconclusive, not pass).

**What the three M3 gates show together:**

| M3 gated as | rank's delta | mobile's centre | mobile's band high end | verdict |
|---|---|---|---|---|
| three single-image gates (morning) | +0.195 | none (each gate alone) | 3.73 (rank's gate) | pass, composed |
| one PR, V1 | +0.124 | +0.76 | 4.19 | inconclusive, `ab_scale` 1.5 |
| one PR, V1b | +0.361 | +1.92 | 5.73 | inconclusive, no extension |
| production | none | +1.35 (morning), +1.52 (V3) | none | clean |

- **Every band contained the truth.** M3's true mobile effect, about +1.4 ms, plus the model band's fixed part at
  mobile, 0.0227 × 72.8 ms ≈ 1.65 ms plus the construct widening, lands within a few tenths of 4 ms.
- **So whether the gate passes M3 depends on that run's A/B noise.** Neither feature changes that; a narrower model band
  at mobile would. Today it is the simulated p90 floor.
- **The one thing the extension could have done** was V1's case: there a 1.5× longer A/B of all three, run at once
  (about 10 more minutes), would probably have passed it.


## Limits

- **Each change ran once.**
- **A real multi-image `deploy.sh` was not run on the bed.** It would have moved production off the fit the
  comparisons use. Its multi-image logic is tested offline only (the signed pass on every image, each service to its
  own image, refusal when any image lacks it).
- **Parallel width is bounded** by the A/B nodes and by the load node, which hosts every A/B's driver.
- **Three A/Bs at once put three A/Bs' side load on production callees** for about 6 minutes.
- **The A/B node is too small for media's plant pair** (above).

## The PRs (none merged)

- rhobound-muse-r#15 (V1), #16 (V2), #17 (V1b) and #18 (V4).
- muse-r main moved twice by push_main: d227e64 (the multi-image workflow) and 8bd5421 (abx for any service count).
