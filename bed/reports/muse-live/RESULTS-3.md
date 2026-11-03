# Experiment 2b: the rule-10 fix, a harder ticket, and how much deploy time rhobound saves: results

Written after the runs, against [DECLARE-3.md](DECLARE-3.md). That file was sealed in parts before each run: part 1 at
f302f60, part 2 at cfdde19, part 3 at 82a0090, and part 3's amendment at 11d6173. Each part is scored against its own
criteria. Both beds are the experiment-2 beds (`aws/spawn_two.sh`): bed 1 runs Muse with rhobound (arm R), bed 2 runs Muse
alone (arm C).

## The answer in short

**Part 1, the rule-10 fix: it works.**
- **The change:** a measurement-limited straddle now asks for a longer A/B, not for different code.
- **The result:** T7 was held three times in experiment 2. Now it was accepted on the first try, and production measured
  it clean.
- **The cost:** 51.4 min against arm C's 18.9 min in experiment 2, because the gate ran a 1,200-s A/B after its 300-s
  one.

**Part 2, T9 on the hottest service: rhobound did not help.**
- Both arms wrote a cheap, separable sharpen on the first try. Neither regressed: mobile, the media-heavy entry, moved
  +0.78 ms under arm R and +0.18 ms under arm C.
- By the sealed criteria that means rhobound did not help. Its time cost was +7.8 min: 24.8 min against 17.0.

**Part 3, deploy time saved, measured: it depends on the size of the change.**
- **One image (four changes):**
  - R took 7.5 to 8.0 min from a built image to production. A 5-min bake took 15.4 min (9.2 without its B0 window).
  - So R saved about 7.5 min, and production was changing for 1 to 2 s instead of 15 min.
  - A measurement-limited A/B, fraud's, made R cost 17 min more than a bake.
- **Three images:**
  - CI v2 gates one image per change, so R ran three gates one after another: 23.6 min.
  - That is **8.1 min slower** than one big-bang bake (15.5 min) and **10.4 min faster** than a staged bake (34.0 min).
  - Production was busy for 3 s.
- **A costly three-image change:**
  - R rejected it before production, with no exposure, and named the image.
  - The big-bang bake found it after users had run +38 ms for 9.2 min, and could not say which image.
  - The staged bake named it at stage 3, after 34 min and 9.3 min of +35 ms.
- **Four images including fraud:** the fraud gate could not decide, so R paid its four gates plus the fallback bake:
  46.5 min, the slowest. Production measured that change clean, so the hold was false.
- **The predictions:**
  - all six decisive verdicts in the table came true: the four single-image passes, M3's pass and M3n's block;
  - 34 of 35 entries landed in their predicted bands;
  - the one costly change was underestimated, +22 to +24 ms predicted against +38 ms measured. The gate had noted that
    the predicted utilization lay beyond its validated range.

## Part 1: the rule-10 fix and T7 again (bed 1)

**What changed:**
- **The engine** (maze-fix-rvar 643a7579): when every change item is A/B-measured, the gate reports `ab_scale` instead
  of asking for other code. That is the factor by which the A/B's visits would bring the decisive entry's band to its
  threshold, if the measured change holds.
- **CI** (`abx`, kit c02bd97): the preview runs the same predict and gate in a scratch run that is never recorded. One
  longer A/B of 2× to 4× follows, then the single recorded prediction.

**T7 attempt r3, arm R:** the same ticket, hidden tests, agent, steps and time caps as experiment 2, with muser's earlier
attempts archived first.

| step | result |
|---|---|
| agent | 7.6 min, 46 steps, 6 MCP calls (budget 2, context 1, fit_start 1, job_status 1, predict 1), 1 Stop reminder |
| hidden tests | pass |
| first A/B (300 s, 4,576 requests per arm) | fraud's own time +0.05 ± 0.55 ms |
| preview | inconclusive (rule 10), `ab_scale` 17.1: about 17× the visits would decide if +0.05 held. CI's cap is 4×, so it asked for 1,200 s |
| longer A/B (1,200 s, 18,180 requests per arm) | fraud's own time −0.28 ± 0.27 ms (the standard error halved, as 4× the visits should) |
| verdict | **pass** (`mean_change@checkout`). Checkout band [−4.86, +3.37] against the 4-ms threshold |
| production (truth bracket) | **clean**: checkout +1.11, mobile +0.51, partner +1.38, search-api +0.17, web +0.85 ms. Every entry inside its predicted band |
| lead time − B0 | **51.4 min** (CI 33.5 min of it) against arm C's 18.9 min in experiment 2 |

**What the pass rests on:**
- It came from the longer A/B's own data: a smaller standard error and a centre below zero. It did not come from reaching
  the 17× precision the preview asked for.
- That is the declared cost of the fix: two chances to pass instead of one. Here the pass was true, because production
  measured clean.
- On a noisy one-worker service, rule 10 is now satisfiable, at about 25 min of extra A/B.

## Part 2: T9, the hottest service (both beds)

**The ticket:** T9 (MED-44) asks for an exact-integer 7×7 unsharp mask on every thumbnail. Media takes about 515 calls/s
on 4 workers and is about 45% busy, so a costly implementation would push it toward saturation.

| | arm R, bed 1 (Muse + rhobound) | arm C, bed 2 (Muse alone, attempt r2) |
|---|---|---|
| outcome | accepted at iteration 1 | accepted at iteration 1 |
| implementation | separable: a 7-tap horizontal pass, then a 7-tap vertical pass with the mask folded in, exact integers | separable, exact integers |
| agent | 5.6 min, 35 steps, 44 tool calls, 5 MCP calls (budget 1, context 2, explain 1, predict 1) | 5.6 min, 35 steps, 37 tool calls |
| hidden tests | pass | pass |
| CI | gate 8.9 min, **pass** (`mean_change@mobile`) | build 1.1 min, deployed at once |
| production | **clean**: checkout +2.05, mobile +0.78, partner +0.22, search-api +0.25, web +0.37; every entry inside its predicted band | **clean**: checkout +2.44, mobile +0.18, partner −1.35, search-api −1.08, web +1.17 |
| lead time − B0 | 24.8 min | 17.0 min |

**Against the sealed criteria:** both arms wrote a cheap implementation first time and neither regressed. That is the
declared "rhobound does not help on T9" case. rhobound's time cost on T9 was **+7.8 min**: the gate's 8.9 min against
arm C's 1.1-min build.

**Why T9 did not separate the arms:** both agents found the separable form without measuring anything. A local
benchmark is enough to see that a direct 7×7 sum costs about 10× as much, so production load was never the deciding
fact. Part 3's train M3n uses that direct sum, the plant declared in DECLARE-3, to measure what rhobound does with a
costly media change.

**Harness:** bed 2's spot load node was reclaimed at about 10:42Z and spoiled arm C's first T9 attempt. That attempt is
archived, its PR (rhobound-muse-c#5) closed and the attempt not scored. The node was re-created on demand.
`aa3-bed2`, two 300-s baseline windows, then read checkout −2.99 and partner −2.27 ms. So on bed 2 a checkout or partner
reading within about ±3 ms is noise, and arm C's checkout +2.44 is within it.

## Part 3: how much deploy time rhobound saves when its predictions hold

**The question:** how much deploy time does rhobound save when its predictions come true, including on
changes of several images? "Deploy time" is measured two ways:
- **lead time:** from a built image to every changed service in production with a decision;
- **production occupancy:** how long production is changing or under watch, so that nothing else can ship.

**The three strategies** (DECLARE-3 part 3):
- **R, rhobound:** CI's A/B of each changed service, then one prediction and the gate; on a pass, one rollout and no
  bake.
- **B, a big-bang bake:** a 300-s B0 window, every image rolled out together, a 180-s warm-up and a 300-s C window.
- **S, a staged bake:** one image at a time, each with its own warm-up and window, stopping at the first stage that
  regresses.

The build (about 41 s per image) is common to all three and left out.

### First result: CI v2 cannot gate a multi-image change

- **What happened:** the first train's PR (rhobound-muse-r#9) was refused at pr-check: "services rank, pricing, media
  run 3 images … one image per change".
- **Why:** in this maze every service but index (4 services) and notify (2) is its own image.
- **What R is for a multi-image change today:** one PR and one gate per image, one after another. That was declared at
  11d6173 before any measurement, and it is what R means in every train below.
- **How a train is scored:**
  - **verdict:** a pass if every gate passes, a block if any one blocks, inconclusive otherwise;
  - **prediction:** per entry, the sum of the gates' centres and bands. This is an additive composition done offline,
    not a product feature.
- **Reuse:** each gate was reused across the trains it belongs to. There were 5 gates in all: `muse-r#10` to `#14`.
- **Amended 2026-11-03, after DECLARE-4's V1:** the multi-image gate later gated M3 as one change with a single
  prediction. It was inconclusive, because mobile's band reached +4.19, where rank and media share the /feed path. So
  this section's additive "pass if every gate passes" was optimistic for M3 by 0.19 ms. M3's truth was clean, so the
  verdict below still came true, but by a narrower margin than separate gates suggest. See RESULTS-4.

### The measurements

Times are in minutes.
- **R:** CI's steps from the first A/B to the signature, plus the rollout.
- **B:** the bed 1 bracket of the whole change, which is also the truth for R's prediction.
- **S:** `verify/stagedx.sh` on bed 2 for M3 and M3n; computed from B's phases for the others.

**Which code each row uses:**
- **The single-image rows** are arm R's accepted changes from today, each with its own gate and bracket.
- **The trains' component gates** (`muse-r#10` to `#14`) are arm C's code (c32, c36, c41, c35) and the plant, with trees
  identical to the trains'.

| change | images | R verdict | came true? | entries in band | R | B (without B0) | S | R occupancy | B occupancy | R vs B | R vs S |
|---|---|---|---|---|---|---|---|---|---|---|---|
| T6 rank (arm R's code) | 1 | pass | yes | 5/5 | 7.5 | 15.4 (9.2) | 15.4 computed | 1 s | 15.4 | −7.9 | −7.9 |
| T8 pricing | 1 | pass | yes | 5/5 | 7.6 | 15.4 (9.2) | 15.4 computed | 1 s | 15.4 | −7.9 | −7.9 |
| T9 media | 1 | pass | yes | 5/5 | 8.0 | 15.5 (9.2) | 15.5 computed | 1 s | 15.5 | −7.5 | −7.5 |
| T7 r3 fraud (with abx) | 1 | pass | yes | 5/5 | 32.5 | 15.4 (9.2) | 15.4 computed | 2 s | 15.4 | **+17.1** | +17.1 |
| **M3**: rank + pricing + media | 3 | pass (3 passes) | yes | 5/5 | 23.6 | 15.5 (9.3) | **34.0 measured** | 3 s | 15.5 | **+8.1** | **−10.4** |
| **M3n**: rank + pricing + media plant | 3 | block (pass, pass, block) | yes | 4/5 composed* | 23.7 to reject | 15.5 (9.3) to detect | **34.1 measured**, stopped at stage 3 | 0 | 15.5 | +8.2 | −10.3 |
| **M4**: M3 + fraud | 4 | inconclusive (3 passes, then fraud) | n/a: a false hold | 5/5 | 46.5 (31.0 of gates + B) | 15.5 (9.3) | 43.3 computed | 15.5 min | 15.5 | +31.0 | +3.2 |

\* **M3n's composed band:** mobile is inside it and web is 0.23 ms over its high end.
- **The plant's own effect,** from bed 2's stage 3 minus stage 2: mobile +33.50 and web +35.04 ms.
  - Both are inside the plant gate's own bands (10.22 to 37.33, and 9.71 to 35.53), but in their top tenth.
  - The gate's measured change ranges (+22.0 to +24.2, and +21.0 to +23.0) were 10 to 12 ms low.
- **So:** the verdict was right and the band just held, but the centre underestimated the costly change by about a third.

A negative "R vs" means R was faster. The full table, with every entry, is in `data3/p3/score.md` and `score.json`
(`orch/p3_score.py`).

**Each gate costs the same:** R's unit of time is one A/B per image, 446 to 490 s. That is 300 s of A/B, 60 s of
warm-up, then the arms' readiness and the Collector's flush. Predict and sign took 2 to 3 s.
- **One image:** one A/B is about half of a 5-min bake with its B0. R wins.
- **Three images:** three A/Bs in a row are longer than one big-bang bake. R loses to B and beats S.

### What each strategy did with the costly change (M3n)

Train M3n is rank, pricing and the media plant: the T9 spec as written, a direct 7×7 sum per pixel. The plant passes
T9's hidden tests.

| | R (rhobound) | B (big-bang bake) | S (staged bake) |
|---|---|---|---|
| verdict | **block**: the media gate predicts mobile +22.0 to +24.2 and web +21.0 to +23.0 ms, with media's utilization rising to 0.80 (rule 9, `utilization_after`, and rule 10) | regression: mobile **+38.01**, web **+38.36** ms | regression at stage 3 (media): mobile **+34.92**, web **+35.20** ms (bed 2) |
| time to the decision | 23.7 min with the gates in train order. About 8.2 min had media's gate run first (490 s) | 15.5 min | 34.1 min |
| users exposed | **none**: nothing deployed | 9.2 min at web +38 ms | 9.3 min at web +35 ms |
| culprit named | **yes**: the media gate's own A/B (media's own time +2.05 ± 0.02 ms per call) | no: every image went out together | yes: stage 3 |

**The verdict was true, the magnitude underestimated.**
- The gate predicted about +23 ms at mobile and web; production measured +38 ms on bed 1 and +35 ms on bed 2.
- Summed with the other gates' bands, mobile landed inside its band; web overshot the band's high end by 0.23 ms.
- The gate had said this was an extrapolation: a `beyond_validated` note at media, predicted utilization 0.80 against a
  validated 0.58. Close to saturation, the queueing was steeper than the model's.

### When the gate cannot decide (M4)

The fraud gate (arm C's T7 code, c35) was inconclusive at checkout (rule 10, `range_straddles`, band +6.97), and `abx`
did not ask for a longer A/B (`ab_scale` null).
- **Why there was no extension** (`data3/p3/gates/fraud/abscale-diagnosis.txt`): checkout's band carries a fixed 2.19-ms
  model band, plus a 1.32-ms widening from the `second_sequential_call` construct. That leaves 0.50 ms of headroom for
  the change itself. The measured centre was +0.66 ms, from fraud's own time +0.36 ms.
- **What that means:** no A/B length can pass this change while its measured centre holds. So the engine refused to
  promise one, which is correct, and asked for "an A/B of fraud" again.
- **The contrast:** T7 r3's first A/B centred near +0.1 ms, left room, and got `ab_scale` 17.1.

**What it cost:** M4 measured clean in production (checkout −10.26, mobile +1.56, partner −17.77, search-api −1.01, web
+1.16 ms). So R's fallback was a false hold:
- 31.0 min of gates, plus the bake R then needs;
- 46.5 min in all, against B's 15.5 and S's computed 43.3.

This is the same weakness as experiment 2: on fraud, a one-worker service with a 1.3-ms construct widening at checkout,
rule 10 can still hold a clean change. The longer A/B fixes the measurement-limited case only.

### The predictions against the truth

- **Verdicts:** 6 of 6 decisive verdicts were true (T6, T8, T9, T7 r3 and M3 passes; the M3n block). The one
  inconclusive verdict (M4) was a false hold.
- **Bands:** 34 of 35 entries landed inside their predicted bands. The miss is M3n's web, 0.23 ms over the summed
  band's high end.
- **Centres:** the additive centres were within 1.8 ms of the truth at every entry of M3 and M4. Additivity held for
  these trains. M3n's mobile and web centres were 14 to 16 ms low, as above.
- **On the other bed:** bed 2 agreed with bed 1 on both measured trains.
  - M3, final stage: checkout −6.69, mobile +2.16, partner −18.10 ms, against bed 1's −9.15, +1.35 and −17.54.
  - M3n: mobile and web +35, against +38.

### If a team bakes longer (computed only)

This repeats R's measured lead time against B and S at longer bakes: a B0 of the bake's length, a 3-min warm-up, and
S with no stop. A longer bake detects smaller regressions, so these are not equal-power comparisons.

| change | images | R (measured) | B / S, 5-min bakes | B / S, 15-min bakes | B / S, 30-min bakes | B / S, 60-min bakes |
|---|---|---|---|---|---|---|
| T6, T8, T9 | 1 | 7.5–8.0 | 13 / 13 | 33 / 33 | 63 / 63 | 123 / 123 |
| T7 r3 (fraud, longer A/B) | 1 | 32.5 | 13 / 13 | 33 / 33 | 63 / 63 | 123 / 123 |
| M3, M3n | 3 | 23.6–23.7 | 13 / 29 | 33 / 69 | 63 / 129 | 123 / 249 |
| M4 (inconclusive: R includes its 5-min fallback) | 4 | 46.5 | 13 / 37 | 33 / 87 | 63 / 162 | 123 / 312 |

- **With 15-min bakes or longer,** R's lead time is shorter than a big-bang bake's for every decisive change measured
  here. At 15 min the saving runs from 0.5 min (T7 r3, with its longer A/B) to about 25 min (one image).
- **With 5-min bakes, as measured,** R saves time only on single-image changes.

### What this says about the promise of faster rollouts

- **Production occupancy, the time production is changing or under watch:** this is where rhobound saves time
  everywhere it decides.
  - Its rollout takes seconds, because the measurement happens on the A/B node, off production.
  - Every bake holds production for 15 to 34 min per change, so a bed that ships through bakes takes one change per
    bake at most.
- **Lead time, with this protocol's 5-min windows:**
  - R saves about 7.5 min per single-image change;
  - it is slower than one big-bang bake for a multi-image train, because CI v2 gates one image at a time and the A/Bs run
    one after another;
  - it beats a staged bake by about 10 min at three images.
- **The levers, none of them built:**
  - one gate for a multi-image change (CI v2 refuses one today);
  - A/Bs of different images in parallel on separate A/B nodes;
  - shorter A/Bs for services whose standard errors allow it.
- **A bad change:** R's clearest gain is no exposure, together with the culprit named, at a time cost similar to a
  bake's.
- **When the gate cannot decide:** R is the slowest strategy, because it pays the gates and then the bake. That happened
  on 1 of 7 changes here, the noisy one-worker fraud, and it was a false hold.

## The PRs (none merged)

- **rhobound-muse-r:**
  - #7: T7 r3, accepted.
  - #8: T9 R, accepted.
  - #9: M3 as one PR, refused at pr-check and closed.
  - #10 to #14: part 3's five single-image gates (rank, pricing, media, the plant, fraud).
- **rhobound-muse-c:**
  - #5: T9 C attempt 1, spoiled by the spot loss and closed.
  - #6: T9 C r2, accepted.

## Limits

- **Each change ran once.** Parts 1 and 2 have one agent sample per ticket and arm, so the results are illustrative.
- **One A/B node, and each image's A/B runs alone.** R's multi-image times would fall with parallel A/B nodes, which
  were not tested.
- **The windows are this experiment's truth protocol:** 300-s B0 and C windows with a 180-s warm-up. Real bakes are often
  longer, which favours R (see the sensitivity table), and some teams do not bake at all.
- **The rollout is seconds** because every service here is one small image on warm nodes. A heavier rollout adds the
  same time to every strategy.
- **Measurement on the trains:** S was measured for M3 and M3n only, and computed for the others. A train's R prediction
  is an additive composition, not one model run.
- **The plant was written for this test, and declared before it ran:** it is the T9 spec as written. Neither agent wrote
  a costly T9 change.
