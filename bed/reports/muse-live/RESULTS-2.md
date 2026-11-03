# Muse Code alone vs Muse Code with rhobound, experiment 2: results

The declaration was sealed before any run: [DECLARE-2.md](DECLARE-2.md), at 23686b3, with dated notes added during the
run. The data is in data2/ (a folder of the experiment kit, not in this repository; the scoreboard is in [SCORE-2.md](SCORE-2.md)):
- the scoreboard, made by `orch/muse_score.py` over both beds' timelines;
- each arm's timeline;
- the per-iteration agent, PR, hidden-test, gate-summary and regress files;
- both beds' A/A runs;
- the post-hoc brackets.

Two identical maze clusters ran side by side on 2026-11-03, from 07:01:38Z (T0) to 09:50Z:
- **bed 1, arm R:** Muse Code with the rhobound plugin, its MCP server and the gate in front of every deploy;
- **bed 2, arm C:** Muse Code alone, every change deployed as soon as its image was built.

## The answer in short

**By the criteria sealed before the first run, Muse alone worked better in this experiment.** Both arms shipped no
production regression. Muse alone accepted all three tickets, each on the first try of its scored attempt. Muse with
rhobound accepted two, and took longer for each.

**How quickly, overall:**
- **Muse alone** finished all three tickets at 08:42Z, 101 min after T0. That includes about 17 min lost to two harness
  re-runs.
- **Muse with rhobound** finished at 09:50Z, 169 min after T0, with T7 never shipped. That includes about 7 min lost to
  one harness re-run.

| | T6 rank diversify | T7 fraud velocity | T8 promotions | tickets accepted |
|---|---|---|---|---|
| Muse + rhobound (bed 1) | try 1, 25.4 min | **not accepted** (3 gate holds) | try 2, 30.7 min | **2 of 3** |
| Muse alone (bed 2) | try 1, 19.5 min | try 1, 18.9 min | try 1, 19.5 min | **3 of 3** |
| rhobound − alone | **+5.9 min** | (rhobound never shipped) | **+11.2 min** | |
| regressions in production (R / C) | 0 / 0 | 0 / 0 | 0 / 0 | 0 / 0 |

The times are the declared headline time (DECLARE-2): from the start of the ticket's scored attempt to the end of the
accepted deploy's C window, less its B0 window.

- **Neither arm ever shipped a slow change.** All six deploys measured under the 4-ms limit. Both T8 deploys made
  production much faster: checkout −11.1 ms (R) and −10.7 ms (C), partner −22.4 ms (R) and −16.3 ms (C).
- **rhobound's gate passed the two changes it should have passed** (T6 and T8; both measured clean).
- **It held all three of bed 1's T7 changes, and each was safe. Run post-hoc, it also held Muse-alone's T7 change,
  which had shipped clean.** Deployed post-hoc on the idle, identical bed 2, the
  three held candidates measured checkout −1.66, −0.77 and −0.33 ms, every entry under 4 ms. Those holds cost bed 1 the
  ticket that Muse alone shipped in one try.
- **With a working shell, the agents in both arms built, tested and benchmarked their code,** and wrote fast designs
  without rhobound's help. Bed 2's T8 agent found and removed the pricing table rebuild on its own.

## What ran

| | bed 1, arm R | bed 2, arm C |
|---|---|---|
| agent | Muse Code 1.4.14, `muse-spark-1.3`, effort high, as `muser`, with the rhobound plugin and MCP server | the same Muse, as `musec`; no rhobound file on the bed |
| path to production | CI build, A/B (300 s), predict, gate; **only a pass is deployed** | CI build only (`RBD_ARM=C`), **deployed at once** |
| production fit | fresh: a 600-s capture at 120 rps, fit `prod-0` = `sha256:7940aa3e…` | none (not needed) |
| A/A noise (two 300-s windows at baseline) | worst entry partner +1.83 ms | worst entry checkout −2.08 ms |

**Common to both arms:**
- **The agent:** 150 model steps and 40 minutes per session.
- **Tickets:** the same ticket text, the same hidden tests on a copy of the workspace, and the same untrusted-output
  checks.
- **Deploy and measure:** the same truth bracket (`verify/truthx.sh`): a 300-s B0 window, the candidate, a warm-up, a
  300-s C window and a rollback, under 120 rps.
- **Machines:** the same machine types (m7i app nodes in both beds).

**The rhobound version under test** includes experiment 1's fixes:
- the engine at f4852029, which bounds the doubt from untouched services' variance;
- the MCP server at c85d37a9, whose refusal of an unknown environment lists the configured names.

No `profile.variance_changed` hold occurred in experiment 2's five gate runs.

**The shell works this time.** Muse's sandbox is built into the `muse` binary (backend `linux_embedded`), and Ubuntu
24.04 restricts unprivileged user namespaces.
- **The fix:** an AppArmor profile that allows user namespaces for `/opt/muse/bin/muse` only.
  The system-wide restriction stays on.
- **Go's cache:** the sandbox makes the home folder read-only, so Go's cache and temp folders were moved into the
  workspace.
- **Checked before T0, inside Muse's sandbox:**
  - bed 2's probe session ran `go build`, `go test` and `go vet`;
  - bed 1's ran `go build`, `go test` and a rhobound MCP call.
- **Across all scored sessions:** the agents ran 12 to 107 shell commands per session, and most of them completed.

## Harness faults, and how both arms were kept equal

Three faults in my harness spoiled a first attempt. Each time:
- the arm was stopped;
- the spoiled attempt was archived (workspace, runs, sessions) and kept on record, not scored;
- its PR, if any, was closed unmerged;
- the ticket re-ran as attempt `r2` under the same T0 and time box.

| fault | arm and ticket | what happened |
|---|---|---|
| a root-owned `/var/lib/rbd/tmp` (made by `task.sh`) | C, T6 | CI's `pr-check` could not make its scratch folder, and the driver read that as a build failure |
| a hidden-test helper named `charge` | R, T7 | the agent's own type `charge` collided, so the tests did not compile. The feedback named a line of the hidden test file; the attempt was archived |
| T7's hook test assumed an empty Velocity | C, T7 | the agent's own tests, run first in the same process, charged cards, so the velocity rule rightly fired and the test failed |

- **Fixes:** 6c9175e, a7820f3 and fa9f37b. The tickets were frozen at 2e2fe87, before T8.
- **Every scored attempt ran against the same final tests:** T6 in both arms against the original version, and T7 r2
  in both arms against the fixed one (installed before either reached its hidden phase).
- **Time lost to these faults:** bed 2 about 9 + 8 min, bed 1 about 7 min. That is outside the scored times above, which
  start at each attempt's own start.
- **Agent-side failure, not a harness fault:** bed 1's T8 try 1 failed a hidden test by one cent (471333 against
  471332, which an independent computation from the ticket's wording confirmed). That cost bed 1 an iteration.

## Per iteration

The gate column is bed 1's verdict. For bed 2 it does not apply: there is no gate on that bed.

| ticket | arm | try | hidden | gate (rule; A/B) | production (worst entry) | shell run / completed | rhobound MCP calls |
|---|---|---|---|---|---|---|---|
| T6 | R | 1 | pass | pass (mean_change@mobile; rank +0.05 ms) | clean (partner +0.96) | 21 / 21 | budget 1, context 3, explain 2, predict 1 |
| T6 | C | 1 (r2) | pass | (no gate) | clean (checkout +3.36, noise band) | 21 / 19 | - |
| T7 | R | 1 (r2) | pass | inconclusive (range_straddles at checkout 7.64 vs 4; fraud +0.12 ms) | not deployed; post-hoc clean (checkout −1.66) | 16 / 12 | none |
| T7 | R | 2 (r2) | pass | inconclusive (range_straddles 4.48; fraud −0.40 ms) | not deployed; post-hoc clean (checkout −0.77) | 107 / 104 | budget 2, context 3, explain 2, predict 1 |
| T7 | R | 3 (r2) | pass | inconclusive (range_straddles 7.66; fraud +0.26 ms) | not deployed; post-hoc clean (checkout −0.33) | 26 / 26 | budget 2, context 3, explain 1, predict 2 |
| T7 | C | 1 (r2) | pass | (no gate) | clean (mobile +1.07) | 21 / 17 | - |
| T8 | R | 1 | **fail** (one cent off) | - | - | 18 / 17 | none |
| T8 | R | 2 | pass | pass (mean_change@mobile; pricing −2.61 ms) | clean, faster (checkout −11.05, partner −22.35) | 12 / 9 | none |
| T8 | C | 1 | pass | (no gate) | clean, faster (checkout −10.71, partner −16.27) | 16 / 16 | - |

The post-hoc brackets were run on bed 2, the identical cluster that was idle by then, with bed 1's own held images (the
two beds share one image repository). They are labelled post-hoc and are outside the scoring. Each verdict rests on
one bracket (about ±2 ms).

**Tokens per ticket (scored attempt), R / C:**
- T6: 2.44 / 1.55 M;
- T7: 5.34 / 1.91 M (R's count misses try 2, whose session hit its 40-minute cap);
- T8: 3.59 / 1.98 M.

**Model steps, R / C:**
- T6: 42 / 34;
- T7: 229 / 36;
- T8: 56 / 32.

## Against the sealed criteria

From DECLARE-2:

| criterion | result |
|---|---|
| **Arm R works better:** it ships fewer regressions than arm C, and accepts at least as many tickets | **no**: 0 against 0 regressions; 2 against 3 tickets |
| **Arm C works better:** arm R ships as many regressions or more and takes longer, **or** arm R accepts fewer tickets | **yes, on both counts**: 0 = 0 regressions with arm R slower (+5.9 and +11.2 min), and 2 < 3 tickets |

**Muse alone worked better in this experiment.** As declared, this is one agent sample per ticket and arm, three
tickets: illustrative, not a statistical comparison.

## What this says about rhobound

1. **The block side was never exercised.** No agent in either arm wrote a change that slowed production, so this run
   cannot show rhobound catching one.
   - With a working shell, the agents benchmarked their own code.
   - Both T8 agents found the existing pricing table rebuild and removed it.
   - The tickets stated only a general SLO, and nothing pointed at a cost.
2. **The new failure mode is `range_straddles` on a noisy, single-worker service.**
   - **Why the band is wide:** fraud has 1 worker and very variable work. In bed 1's A/B records
     (`data2/t7-fraud-ab.txt`), fraud's own time was about 18.9 ms, and the three deltas were +0.12, −0.40 and
     +0.26 ms. Their standard errors were 0.63, 0.53 and 0.57 ms, with about 4,600 visits per arm in 300 s; no variance
     doubt fired.
   - **How that noise became a hold:** each delta sits inside its own ±2 SE. Carried through fraud's single-worker
     queue to checkout, that noise became a change range of about ±3.2 ms (−2.51 to +3.95, −3.84 to +1.66, −2.37 to
     +3.97). The model band on top put the upper end at 7.64, 4.48 and 7.66 ms against the 4-ms limit.
   - **What the gate did:** rule 10 held every one as inconclusive. All three measured clean when deployed.
   - **No code passes it: a post-hoc counterfactual.** Muse-alone's accepted T7 change went through bed 1's gate as
     PR rhobound-muse-r#6, labelled post-hoc and never merged. On bed 2 it had shipped clean (worst mobile +1.07 ms). The
     gate held it too: fraud −0.45 ms, SE 0.60; checkout band upper end 5.41 ms; inconclusive `range_straddles`.
     All four T7 implementations the gate saw were held, three from arm R and one from arm C, and all four measured
     clean in production.
   - **Why the agent could not escape:** `decide_with` asked for "an A/B of fraud", which had just run. The agent spent
     its second try's full 40 minutes and 144 steps, running 107 shell commands, and could not narrow a band set by
     measurement noise.
   - **The fix to look at:** when the band is wide because the A/B's standard error is large, rather than because the
     change is large, the gate should ask for a longer or repeated A/B, not a code change. A gate that cannot be satisfied
     by any code is a hold that only time or more measurement can clear.
3. **Experiment 1's fix worked:** no variance-doubt hold appeared in five gate runs.
4. **The agent-side integration was used in part:**
   - bed 1's agents called rhobound in T6 and in T7's later tries, but never in T8;
   - the Stop reminder fired in three scored sessions (and one spoiled attempt), and each time the agent stopped
     without predicting;
   - the MCP refusals that do occur (about two per session) were corrected on the next call.
5. **What rhobound cost when nothing was wrong:**
   - about 8.4 to 8.9 minutes of gate CI per head;
   - a much larger share of tokens and steps;
   - on T7, the whole ticket.

## The PRs

Nothing was merged in either repository.
- **Open for the record:**
  - rhobound-muse-r #1 (T6), #4 (T7 try 3), #5 (T8 try 2) and #6 (the post-hoc counterfactual below);
  - rhobound-muse-c #2 (T6 r2), #3 (T7 r2) and #4 (T8).
- **Closed:** rhobound-muse-r #2 and #3 (superseded T7 tries), and rhobound-muse-c #1 (the spoiled T6 attempt).

## Limits

- **Sample size:** one agent sample per ticket and arm, and three tickets.
- **Agent variability:** bed 1's T8 rounding slip, an agent-side failure, is the kind of variability that one sample per
  arm cannot average out.
- **The beds:** identical by construction, not by measurement. Each deploy was measured against its own bed's B0, so a
  constant offset cancels. The post-hoc brackets ran on bed 2, not on bed 1.
- **The A/A noise:** bed 2's reached −2.08 ms (checkout), so readings from 2 to 6 ms are within noise there (T6 C's
  checkout +3.36).
- **Exposure is a floor:** a regressed deploy would run only its warm-up and C window. None regressed.
