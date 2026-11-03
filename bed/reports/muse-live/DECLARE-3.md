# Experiment 2b: the rule-10 fix, T7 again, and a harder ticket (written before these runs)

This run fixes the range_straddles gate, reruns T7, and adds a harder example where rhobound should help.

## Part 1: the fix and the T7 rerun (bed 1, arm R only)

**The fix** (engine maze-fix-rvar 643a7579; kit c02bd97).
- **The engine:** a rule-10 straddle is measurement-limited when every change item is measured by A/B, and a zero-width
  range around the same centre would pass. The gate then reports `ab_scale`: how many times the A/B's visits would put
  the decisive entry's band at or under its threshold, if the measured change holds. Its `decide_with` names that
  longer A/B, not another change.
- **CI (a new `abx` step, single-service changes):** after the A/B, `ab.sh … preview` runs the same predict and gate in
  a scratch run that is never recorded.
  - If that gate is inconclusive with an `ab_scale`, `ab.sh` runs one longer A/B: `ab_scale` × 1.2, at least 2× and at
    most 4× (300 s becomes 600 to 1,200 s). The first A/B is moved aside, as for any re-run.
  - Then `predict.sh` decides once, as before. A recorded verdict is still never re-rolled.
- **What it costs:** two chances to pass instead of one. The first A/B can only pass outright or ask for the longer
  one, and the longer one decides on its own data. So the chance of passing a bad change at most doubles. That is
  stated here and in the report.

**The rerun.**
- **What runs:** T7 on bed 1 as a new attempt (`r3`), with muser's earlier workspaces and sessions archived first, so
  the agent cannot read its earlier T7 attempts. The same agent, ticket, hidden tests (fa9f37b), step cap, time cap and
  3-iteration limit as experiment 2.
- **What it is compared with:** experiment 2's arm C T7, accepted on try 1 in 18.9 min (headline). Arm C is not rerun;
  the agent's own variability is not controlled.
- **The fix works** if arm R reaches an accepted deploy of a change that measures clean.
- **It does not work** if every head is still held:
  - when the holds are measurement-limited, the extension is too small;
  - when they are not, the band's centre and model band are over the limit, and the model, not the measurement,
    decides. The report says which.

## Part 2: a harder ticket (both beds; added in a dated section below before it runs)

**The target: media, the hottest and most shared service.**
- It has 4 workers and takes about 515 calls/s: batches of 4 to 12 per mobile `/feed`, plus one per web `/browse`
  through layout. That is about 45% busy at 3.5 ms of work per thumbnail.
- **Why it is the right test:** a change that adds a few ms of CPU per thumbnail looks small in a local benchmark. It
  pushes media toward saturation under production load, and `/feed`'s batch waits for its slowest thumbnail. A model of
  production load can see that before a deploy; a local benchmark cannot.
- **What is declared:** the ticket, its hidden tests and the criteria are added below, dated, before either bed runs it.

---

**Part 2, added 2026-11-03 10:28Z, before either bed runs T9.**

**T9 (MED-44), "Thumbnails should be sharpened"** (`tools1/muse/tickets/T9`).
- **What it asks:** an exact-integer unsharp mask on each 128×128 thumbnail. The blur is a 7×7 binomial
  [1 6 15 20 15 6 1]², with edges clamped; the result is floor((20480·p − 3·S + 4096) / 8192), limited to 0..255.
  The media.thumb hook serves `Sharpen(Thumb(seed))`.
- **What the hidden tests check:**
  - exact equality with an in-test reference, on random images, thumbnails, a flat image, stripes and corners;
  - that the input is not modified;
  - that Thumb is unchanged;
  - concurrent use;
  - the live hook, found by seed whatever the package's own tests did first.
- **The checks of the tests themselves:** the reference patch (separable, integer) passes them, and a no-rounding
  mutant fails four of them.

**The production effect was not measured beforehand.** The task text states only the general SLO.

**Expected, not measured:**
- a direct 2-D convolution is about 800k multiply-adds per thumbnail, about 1 to 2 ms of CPU;
- media takes about 515 calls/s on 4 workers, so that cost should push it toward saturation;
- a separable or integer implementation should cost several times less.

**The runs.**
- **Both arms:** T9 at most 3 iterations each, with the same agent settings as experiment 2.
- **Arm C (bed 2):** starts as soon as the ticket is installed. Bed 2 is idle, and its musec home is archived first.
- **Arm R (bed 1):** starts after its T7 rerun, with the fixed gate (643a7579 and the `abx` step).
- **The two arms run at different times on their own beds.** Each deploy is measured against its own bed's B0.

**Criteria for T9.**
- **rhobound helps on T9** if arm C ships at least one regression (a deploy with an entry over 4 ms) and arm R ships
  none, while arm R reaches an accepted deploy within its iterations.
- **rhobound does not help on T9** if any of these holds:
  - both arms write a cheap implementation first time and neither regresses (the report then gives rhobound's time
    cost);
  - arm R ships a regression (a wrong pass);
  - arm R never accepts a change that measures clean (a false hold that costs the ticket).
- **Exposure,** for any regression arm C ships: its warm-up and C window (about 8 min) times the worst entry's ms over
  4, as a protocol floor.

---

**Added 2026-11-03 11:18Z; no criterion is changed.** A fourth harness fault, in the infrastructure this time, spoiled bed 2's
first T9 attempt.
- **What happened:** bed 2's load node was a spot machine, and AWS reclaimed it at about 10:42Z. T9-C's first iteration
  had passed its hidden tests (an efficient separable implementation) and its image was built. Its bracket then failed
  in the B0 window, so it never deployed: production stayed at baseline, and nothing was fed back to the agent.
- **The fix:** bed 2's load node was re-created on demand (m6a.xlarge, 11:02:37Z). It was joined to k3s and the
  120-rps background load restarted at 11:07:37Z. A fresh A/A (`aa3-bed2`, two 300-s windows at baseline) measures
  bed 2's noise with the new load node before T9-C runs again.
- **The re-run:** T9 arm C restarts as attempt `r2` under the same rules, with musec's T9 workspace, runs and sessions
  archived first (`archive/T9-C-attempt1` on bed 2). The spoiled attempt (`state/muse/T9-C`, PR rhobound-muse-c#5,
  closed unmerged) is kept on record and not scored.
- **Bed 1 was not affected:** its load node is in its own VPC.

**Added 2026-11-03 11:28Z: bed 2's A/A with the new load node.** `aa3-bed2` (11:14 to 11:26Z, two 300-s windows at
baseline) reads checkout −2.99, partner −2.27, mobile +0.65, search-api +0.53, web +0.01 ms. Checkout and partner are
beyond ±2 ms, so the report says so: on bed 2, a checkout or partner reading within about ±3 ms is noise. Experiment 2's
A/A on bed 2 read checkout −2.08. T9-C r2 started at 11:27:18Z.

---

## Part 3: how much deploy time rhobound saves when its predictions hold (added 2026-11-03 11:28Z, before any of its runs)

**The question:** how much time does rhobound save when its predictions come true? Faster rollouts and less deployment
time were a main promise. It is measured on changes of several images.

**Three ways to take a built change to production.** The build (about 64 s) is common to all three and left out.
- **R, with rhobound:**
  - CI runs one A/B per listed service, one after another on the A/B node, 300 s each. A single-service straddle may
    also get `abx`'s longer A/B.
  - Then one prediction and the gate decide:
    - **a pass:** every listed service is rolled out at once, with no bake;
    - **a block:** nothing is deployed, and the gate names the services that cost;
    - **an inconclusive verdict:** R falls back to B and pays for both.
- **B, a big-bang bake, no prediction:** a 300-s B0 window, every listed service rolled out at once, a 180-s warm-up and a
  300-s C window. A regression is rolled back, but B cannot say which service caused it.
- **S, a staged bake, no prediction:** a B0 window, then one service at a time in the change request's order, each with
  its own 180-s warm-up and 300-s window. It stops and rolls back at the first stage that regresses against B0, and that
  stage names the culprit.

**What is measured for each change.**
- **Lead time:** from the built image to every listed service in production with a decision, or to rejected with
  production at baseline.
  - R: CI's step times, from the first A/B's start to the signature's end, plus the rollout's own seconds.
  - B: its bracket's phases (B0, rollout, warm-up, C). It is also given without B0, for a team that always has a recent
    window.
  - S: its phases, up to the stop.
- **Production occupancy:** how long production is changing or under watch, so that no other change may ship. For R that
  is the rollout only; for B and S it is their windows.
- **Exposure,** for a change that regresses: the minutes users run it × its worst entry's change, as in DECLARE-2.
- **Attribution:** whether the strategy names the costly service.
- **Whether the prediction came true:**
  - **verdict level:** a pass is true if B's bracket shows no entry over 4 ms; a block is true if it shows one. An
    inconclusive verdict makes no claim; it is the fallback row.
  - **magnitude level:** each entry's measured change lies inside its predicted band.
- **How savings are counted:**
  - only for changes whose verdict was true;
  - a wrong pass saves nothing: R would have shipped the measured regression with no watch;
  - a wrong block costs the change.

**Where each strategy runs.**
- **Bed 1:** each change is a PR on rhobound-muse-r. CI gates it, which is R. A `truthx` bracket of all its services
  follows right after whatever the verdict. That bracket is B, and the truth for R's prediction (the bed of the fit).
- **Bed 2:**
  - `verify/stagedx.sh` (65c4266) measures S on M3n, where staged detection and attribution matter. Its stop is applied
    when the windows are scored: every stage runs, and S's time counts up to the stop.
  - For the other changes, S's time is computed from the measured per-stage phases, and labelled computed.
- **Order:** Part 3 touches bed 1 only after T9 R has finished, and bed 2 only after T9-C r2 has finished. That way
  neither arm's CI, lock wait or timings are disturbed.

**The changes, in priority order, as many as the caps allow (about 18:00Z).** The branches are on the workstation and
unpushed until their bed is free.
1. **M3** (`p3-m3`, c24ca9c): a release train of three of arm C's changes, real agent code: rank T6 (c32-muse), pricing
   T8 (c36-muse) and media T9 (c41-muse, attempt 1, separable). Each passed its hidden tests. Rank and pricing measured
   clean alone today; media's production effect is unmeasured.
2. **M3n** (`p3-m3n`, 08d4da0): rank and pricing as in M3, with a costly media change.
   - **The media change:** the first T9 candidate of either arm in this experiment that measures as a regression in its
     arm's bracket, or that bed 1's gate blocks.
   - **If there is none when both T9 runs finish:** the plant at fdfacbf, the direct 7×7 sum per pixel. It is the spec
     as written, with no separable pass, and it passes T9's hidden tests. It costs 1.72 ms per thumbnail against the
     separable version's 0.16 ms (the workstation, arm64; production is amd64).
3. **M4** (`p3-m4`, a190409): M3 plus fraud T7 (c35-muse).
   - **Expected:** fraud's A/B straddles rule 10 at checkout, as muse-r#6 did, and `abx` does not extend a
     multi-service change. So the gate is inconclusive, and R pays for the gate and then B. This is the row where
     rhobound costs time.
4. **One-service rows:** today's arm R deploys on bed 1 (T6, T8, T7 r3, T9). Each has its gate phases and its bracket,
   and for one service S = B.

**Expected, from today's measured phases, written down before the runs.**
- **The phases:** an A/B about 400 s per service with its ready and flush; predict and sign about 40 s; a B0 or C window
  about 372 s with its settle; a 180-s warm-up; a rollout of 1 to 3 s.

| services | R | B | B without B0 | S (no stop) |
|---|---|---|---|---|
| 1 | 7.3 min | 15.4 min | 9.2 min | 15.4 min |
| 3 | 20.7 min | 15.4 min | 9.2 min | 33.9 min |
| 4 | 27.3 min | 15.4 min | 9.2 min | 43.1 min |

- **At this protocol's 300-s windows, R is expected to save lead time:**
  - against a one-service bake;
  - against S at every size (about 13 min at 3 services, 16 at 4).
- **R is expected to be slower than a big-bang bake from 2 services on.** Its A/Bs run one after another, so it is
  about 5 min slower at 3 services and 12 min at 4 (11 and 18 min against B without B0). That outcome is live, and the
  report will state it if it happens.
- **R's expected clear gains:**
  - production occupancy of seconds, against 9 to 43 min;
  - no exposure for a blocked change;
  - the culprit named without staging.
- **A sensitivity table, computed only:** bakes of 5, 15, 30 and 60 min (a B0 of the same length, and a 3-min warm-up)
  against R's measured times. A longer bake detects smaller regressions, so these are not equal-power comparisons, and
  the report says so.
- **Limits:**
  - each change runs once;
  - one A/B node;
  - B's and S's windows are this experiment's own truth protocol;
  - the rollout is fast because every service here is one small image on warm nodes.

**Added 2026-11-03 11:33Z, before any part 3 run; no criterion is changed.** Bed 2 is idle between T9-C r2 and M3n's
build on bed 1, so S is also measured on M3 there (`stagedx`, order rank, pricing, media), instead of being computed.
That also gives M3 a second truth, on the other bed. M3n's S follows as declared.

**Amended 2026-11-03 12:01Z, before any part 3 measurement: one PR per image.** CI refused M3's PR at
pr-check, rhobound-muse-r#9, now closed unmerged. Nothing was built and nothing measured.
- **Why:** CI v2 gates one image per change. In this maze, rank, pricing, media and fraud are four images (each its own
  `cmd/<image>` binary), so M3, M3n and M4 cannot be one PR.
- **What rhobound does with a multi-image change today:** one gate per image, one after another. That is now R, and the
  report states this product limit as part 3's first result. Gating a multi-image change as one is a feature CI v2
  lacks, and it is not built today.

**The gates:** five single-image PRs on bed 1, each with the same service code as the train branches (identical trees):
- `p3-g-rank` f0014bf (c32);
- `p3-g-pricing` 04e7491 (c36);
- `p3-g-media` cfc4635 (c41);
- `p3-g-plant` 775db47 (the plant);
- `p3-g-fraud` 1754fb8 (c35).

**Reuse:** a gate of an identical tree is the same measurement, so the rank, pricing and media gates serve every train
they belong to: five gates in all, not ten.

**A train's R, composed offline (not a product feature):**
- **Verdict:** a pass if every image's gate passes; a block if any one blocks; otherwise inconclusive, and R falls back
  to B.
- **Lead time:** the sum over its images of CI's A/B start to signature end, plus one rollout. The n builds are common to
  all strategies and left out.
- **Prediction:** per entry, the train's centre is the sum of each gate's `change_ms` midpoints. Its band is the sum
  of the gates' `band_ms` lows and highs (an interval sum, conservative). It is additive: interactions are not
  modelled. The train's own bracket (B) tests that directly, at the verdict and magnitude levels as declared.

**M4's expectation changes:** a single-image fraud PR does get `abx`'s longer A/B. M4 is therefore expected either to
pass after a longer A/B (fraud's gate about 33 min, as T7 r3's) or to be inconclusive. Either way it is the row where
rhobound costs time.

**B and S:** unchanged, with each service on its own image's digest (`truthx` and `stagedx` take one digest per
service).

**Order on bed 1**, so that M3 finishes first:
1. the rank, pricing and media gates;
2. B(M3);
3. the plant's gate;
4. B(M3n);
5. the fraud gate;
6. B(M4).

**Serialization:** each PR is pushed only after the previous step has ended, so no gate's A/B waits on a bracket's lock.

**Bed 2:** S(M3), then S(M3n), each once its images exist.

**Fit age:** the gate's default limit is 24 h, and the policy sets none of its own. The prod-0 fit (about 06:44Z) cannot
hold a late gate.
