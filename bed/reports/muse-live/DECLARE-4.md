# Multi-image gate and parallel A/Bs: declaration (written before any validation run)

This builds the two levers RESULTS-3 named: one gate for a multi-image change, and A/Bs of several services at
once. Both were built and tested offline, then installed on bed 1. This file fixes, before any run, what the bed
validation must show.

## What was built (kit 99c317e; on bed 1's tools1 at 15:40Z; rhobound-muse-r main d227e64)

**A multi-image change in one PR:**
- **pr-check:** admits services across images. For each image a change touches it must still list every service that
  runs it.
- **build.sh:** builds one image per image touched, in the request's order. Each service's candidate record names its
  own image's digest.
- **predict.sh and sign.sh:** check each A/B against its own service's digest. The signed predicate names every digest,
  and every distinct image carries the same attestation.
- **deploy.sh:** deploys each service to its own image, and only when every image of the change carries the same
  signed pass.
- **Single-image changes:** they write the same records as before.

**Parallel A/Bs:** `ab.sh RUN --all`, now the workflow's only A/B call.
- **What it reads:** the run's change request and candidate files, so the workflow passes no digest.
- **The parent:** holds the run lock and the cluster lock once, then runs one A/B per service.
- **Placement:** each A/B runs on its own Ready node of the A/B pool, with at most min(nodes, 3) at once. One arm pair
  of media alone saturates a 4-vCPU node, so two A/Bs never share one.
- **The children:** prove they are the parent's with a token file, inherit both locks, and name and delete only their
  own objects.
- **With one A/B node:** one A/B at a time, as before.

**Offline tests:** 405 checks pass.
- a multi-image flow through build, predict, sign and deploy, including a refused deploy when one image is unsigned;
- the parallel parent with a stand-in child: three at once, the width limit, queueing, NotReady nodes, failures and
  refusals;
- the real child's token and lock checks.

**Found and fixed in testing:** an unbound variable that let `ab.sh` continue past an early refusal.

## The validation (bed 1, once the A/B nodes have joined and the background load runs)

**Bed 1's state:** its spot load node and A/B node were reclaimed at about 15:33Z. They are re-created on demand,
with two more A/B nodes (`AB_NODE=3`, m7i.xlarge, the same type as before). The production fit stays prod-0: no
service image changed.

**The runs, in this order, each a PR on rhobound-muse-r, never merged:**
- **V1, train M3 as one PR** (`p4-m3` 6758874): rank, pricing and media, three images. Its service code is
  byte-identical to the gates `muse-r#10` to `#12` and to the train bracket `p3-m3-b1`.
- **V2, train M3n as one PR** (`p4-m3n` ae3dea8): rank, pricing and the media plant. It is byte-identical to the gates
  `#10`, `#11` and `#13` and to `p3-m3n-b1`.

**Builds are not reproducible,** so the digests will differ from earlier today. Only the code is identical.

**What must hold for "it works":**
1. **One PR for the three images:** pr-check admits it, three images are built with three distinct digests, and one
   prediction and one signed verdict cover all three, attested on all three images.
2. **The A/Bs run at once:** `ab-all.json` shows parallel 3, three different A/B nodes, and overlapping windows.
3. **The time:** CI's A/B step for the three services takes at most 640 s, which is 1.3× the longest single-service A/B
   step measured today (490 s). That is against 1,412 and 1,424 s for today's three gates run one after another. R's
   lead time for a 3-image change is then about one A/B, roughly 8 min, against a 5-min big-bang bake's 15.5.
4. **The same verdicts as today's composed ones:** V1 pass; V2 block, with media's utilization and mean_change rules.
5. **Parallel A/Bs measure what sequential ones did:** each service's own-time delta (rank, pricing, media, the plant)
   lies within 3 combined standard errors of the same code's delta in today's single-image gates. That measures
   whether arms on three nodes, with three drivers sharing the load node, distort the A/B.
6. **The single prediction against today's truth:** each entry's predicted band contains the change measured by today's
   bracket of the same code (`p3-m3-b1`, `p3-m3n-b1`).
   - **Also reported:** whether the one-model centre is closer to that truth than the additive composition of the three
     gates.
   - **For V2,** whether the model again underestimates the plant's cost near saturation.

**It does not work if any of these happens:**
- items 1 to 4 fail;
- a parallel A/B's delta falls outside its 3-SE agreement, which means parallel measurement is not trusted, and the
  report says which service;
- the A/B step is not faster.

**Not run on the bed:** `deploy.sh` of a signed multi-image pass. It would move production off the fit the comparison
uses. Its multi-image logic is tested offline only, which the report states.

**Side load:** three A/Bs at once put three A/Bs' calls on production's callees for about 6 minutes. Own time does not
include callee time, but production entries measured in that window would carry the extra load. No truth bracket runs
during an A/B: they share the cluster lock.

**If time allows:** a truthx bracket of V1's three new images (about 18 min). It is a fresh truth for the new digests,
and a third reading of M3 after `p3-m3-b1` (bed 1) and `p3-m3-b2` (bed 2). It runs only after V1 and V2 are done.

---

**Added 2026-11-03 16:09Z, after V1 and before any further change or run: V1's result, and V1b declared.**

**V1** (rhobound-muse-r#15, CI run 41669019855):
- **Criteria 1, 2, 3, 5 and 6 held:**
  - three images (three digests, all attested);
  - parallel 3 on rbd-d-ab1, ab2 and ab3, the three 300-s windows overlapping fully;
  - CI's A/B step 572 s, against 1,400 s for the same three services' gates run one after another;
  - every own-time delta within its 3-SE agreement with its sequential gate (\|z\| at most 1.57);
  - all 5 entries' bands contain `p3-m3-b1`'s truth.
- **Criterion 4 failed as sealed:** the verdict was **inconclusive** (rule 10, `range_straddles`), not pass.
  - **Where:** mobile's band [−2.08, +4.19], 0.19 ms over the 4-ms threshold.
  - **Why:** rank and media both lie on mobile's /feed path. The single prediction combines both A/Bs' uncertainty
    there; separately, each gate's mobile band stayed under 4 (3.73 and 3.31).
  - **What it means:** Part 3's composition rule, a train passes if every image's gate passes, was optimistic for M3 by
    0.19 ms. RESULTS-3 is amended to say so.
  - **What the gate asked for:** `ab_scale` 1.5, a longer A/B of all three services. `abx` extends only
    single-service changes, so no extension ran.

**V1b, declared now:** `abx` is extended to multi-service changes, then M3 is gated again as a new commit, `p4-m3b`,
with the same tree as `p4-m3`.
- **The change:**
  - `ab.sh RUN --all [SECONDS]` gives every child the longer A/B;
  - the workflow's `abx` previews any change (the preview already reads every A/B of the run), then runs
    `ab.sh RUN --all N`.
- **Expected:** preview inconclusive with `ab_scale` about 1.5. One 2× (600-s) A/B of all three runs in parallel, and
  then a pass if the measured centres hold: mobile's half-width falls by √2, putting its band near +3.9.
- **The time, also expected:** about 572 s plus about 640 s, some 20 min of A/B. That is slower than a 5-min big-bang
  bake again, and it is stated now as a live outcome.
- **For comparison:** a clean 3-image change that needs no extension costs about 9.6 min, the A/B step plus predict,
  sign and the rollout. That is the first case where R beats a 5-min big-bang bake (15.5 min) on a multi-image change.
- **Ordering:** V1b runs only after V2 and V3 have released the cluster lock, so its A/B times hold no lock wait.
- **The time box:** if the extension is not installed and tested by 17:00Z, V1b is not run, and V1 stands as the
  result.

---

**Added 2026-11-03 16:50Z, after V1b (inconclusive; its preview declined) and before V4: V4 declared.**

No multi-image change has passed on the bed. M3 sits at the bar at mobile, where rank and media share the /feed path.
V4 measures whether a clean multi-image change that does not stack two services on one entry's path passes, and how fast.

**V4** (`p4-m2` 90c7e09, one PR): pricing T8 (c36) + media T9 (c41, separable). These are two images, with the same
code as the gates `muse-r#11` and `#12`; rank stays at production. Only media touches mobile, and its gate's mobile
band alone was +3.31.

**Expected:**
- one PR, two images, two attested;
- the two A/Bs at once on two nodes;
- an A/B step of at most 640 s;
- verdict **pass**;
- each delta within 3 combined SEs of its sequential gate;
- R's own CI time about 9.6 min.

**Then V5,** a truthx bracket of V4's two images: every entry must lie in its predicted band, and production must be
clean.

**V4 fails if:** the verdict is not pass, the A/B step exceeds 640 s, or a band misses V5's truth. The report states
any of these as measured.

**Also stated now:** the path where `abx` launches a parallel longer A/B of every service has run only in the offline
tests. On the bed it ran only in its declining branch (V1b). V4's preview may decline too.
