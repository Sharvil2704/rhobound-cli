# Muse Code, with and without rhobound: results

The declaration was sealed before any run: [DECLARE.md](DECLARE.md), kit commit 67c1be5. A dated note was added in
173a184, committed 2026-11-02 23:07:42Z during T5 R's first agent session. The note's own stamp, "23:15Z", is wrong: it
is later than the commit.

**Data.** Copies are in data/ (a folder of the experiment kit, not in this repository; the scoreboard is in [SCORE-1.md](SCORE-1.md)):
- the scoreboard, made by `orch/muse_score.py`;
- each arm's `timeline.json`;
- the per-iteration agent, PR, hidden-test, gate-summary and regress files;
- the post-hoc brackets;
- `variance-z.txt`;
- the shell and MCP table, made by `orch/muse_extra.py`.

The full per-iteration folders are in the kit's git-ignored `state/muse/` on the workstation. Not kept in the kit:
the `ab-record.json` files behind the z table, and the agents' full closing notes. Both are on rbd-tools1, which stops
with the bed.

All four arms ran on 2026-11-02/03 on the CT3 maze bed, with Muse Code 1.4.14-R7309.1 using `muse-spark-1.3` at effort
high.

## The answer in short

**Both arms reached an accepted deploy on both tickets (four accepted changes, two per arm) with no production
regression, and rhobound made the deploys slower.**

| | T5 (bulk price) | T4 (typo search) |
|---|---|---|
| chaotic (arm C), headline time | 18.4 min, accepted on iteration 1 | 16.4 min, accepted on iteration 1 |
| rhobound (arm R), headline time | 56.9 min, accepted on iteration 3 | 53.5 min, accepted on iteration 2 |
| R − C | **+38.5 min** (+30.1 min without the harness's false refusal) | **+37.0 min** |
| regressions in production, R / C | 0 / 0 | 0 / 0 |

The headline time runs from the ticket's start to the end of the accepted deploy's C window. It leaves out the B0
windows and arm C's wait behind its own counterfactual CI. The declaration says "the end of the measurement"; counting
to the C window leaves out the rollback and settle after it, about 2.2 min in every arm. That moves the R − C
differences by at most 0.2 min.

- **Rhobound had nothing to catch.** Every agent, in both arms, read the code, found the expensive path itself, and
  wrote the fast design first time. The tickets give only a general 4-ms SLO, not where the cost lies; T5 names
  `pricing.Quote` only as the call to use. No naive version reached CI.
- **What rhobound did add:**
  - its CI gate, 8.4 to 8.9 minutes per head;
  - on each ticket, one hold of a change whose A/B was clean (+0.02 ms and −0.35 ms). The hold came from a variance test
    on a downstream shard the change does not touch, and it cost a whole extra iteration. In post-hoc brackets after the
    run (not declared, outside the scoring), neither held change crossed the threshold when deployed: T4's worst entry
    was partner +0.81 ms, and T5's was checkout +2.71 ms, inside the noise band;
  - longer agent sessions: arm R's accepted T4 session ran 15.7 min, against arm C's 5.1 min.

  Had the gate passed first time, an estimate from the measured phases puts rhobound's price at about +11 to +12 min
  per ticket.
- **Against the sealed criteria, rhobound did not help in this experiment.** On T5, arm C wrote a good implementation
  first time and arm R's extra time bought nothing. On T4, arm R took longer for the same outcome.
- **What the experiment could not test:** whether rhobound catches a regression before production. No agent produced
  one.
- **Two confounds, both disclosed below:**
  - no agent could run a shell command. This held in every arm, and it slightly flatters rhobound;
  - the harness falsely refused T5 R's first iteration. It was fixed mid-run, and an adjusted figure is given.
- **What it found that is worth fixing:** the gate's `profile.variance_changed` doubt fires by chance on services a
  change does not touch (see "What this says about rhobound").

## What ran

| | arm R (rhobound) | arm C (chaotic) |
|---|---|---|
| agent | Muse as `muser`: the rhobound plugin (skills, opt-in Stop reminder) and the rhobound MCP server against the bed's production capture and policy | Muse as `musec`: no plugin, no MCP, rhobound hidden from its sessions |
| path to production | build, A/B (300 s), predict, gate; only a gate **pass** is deployed | build, then deploy at once; roll back on a measured regression |
| feedback | a non-pass verdict and its rules | the measured entry changes, on a regression |

**Common to both arms:**
- the same ticket text;
- the same step cap (80) and hour of wall time per session;
- the same hidden acceptance tests (run on a copy, never in the agent's workspace);
- the same untrusted-output checks (`orch/agent_take.sh`);
- the same deploy measurement: `verify/truthx.sh`, a 300-s B0 window, the candidate, a warm-up, a 300-s C window and a
  rollback, under 120 rps of background load.

A deploy regresses when an entry's mean latency rises by more than 4.0 ms (the bed policy). One bracket decides, and a
reading of 2 to 6 ms is flagged as within noise (single-bracket noise is about ±2 ms). Nothing was merged. Every PR is
labelled `rbd-muse`; superseded ones were closed and the last of each arm is left open for the record.

| ticket | what it asks | the trap |
|---|---|---|
| T5 (SRCH-27) | search hits carry each product's bulk price (`pricing.Quote` for 50 units, divided by 50) | `Quote` rebuilds a discount table on every call (about 2.4 ms of CPU); one call per hit (20 a search) adds about +50 ms at `search-api` |
| T4 (SRCH-19) | typo-tolerant search (one edit) | the obvious per-word edit distance sits on the 4-ms threshold (about +3.85 ms) |

Order: T5 C, then T5 R, then T4 R, then T4 C, one at a time. Both users' homes were archived between the tickets.

## Two things that went differently from the plan

**1. No agent could run a shell command (all four arms).** Muse's bundled sandbox (bwrap) fails on rbd-tools1, an
Ubuntu 24.04 host with `kernel.apparmor_restrict_unprivileged_userns = 1`, at `loopback: Failed RTM_NEWADDR: Operation
not permitted`. With `--disable-approval`, Muse refuses an unsandboxed command; it does not run it. So every agent wrote
code by reading only, and no `go build`, `go test` or benchmark ran in any session. Found after T5 C, from that agent's
closing note. It was kept identical for all arms; tools1 was not changed mid-experiment. The note is in DECLARE.md
(173a184).

What it does to the comparison:
- **Correctness:** still checked the same way for both arms, by the hidden tests and the compile in CI.
- **Latency:** here the condition is not symmetric. Arm C lost its only pre-deploy latency signal, a local benchmark.
  Arm R's MCP tools are started by Muse outside the sandbox, so the sandbox did not block them. Still, 11 of their 39
  calls failed on the agent's first try at that input (section 2 gives the reasons), and the agents' later calls
  completed. So the comparison is "rhobound's signals against no pre-deploy signal at all", which flatters rhobound
  compared with a developer who can run a benchmark.

**2. A harness bug cost arm R one iteration on T5.** `orch/agent_take.sh` refuses a changed file that no build
compiled. It listed only each package's `.GoFiles`, so a changed `_test.go` counted as unchecked, although
`go vet -tags maze_v11` compiles it. T5 R's first change extended `catalog_test.go` with two tests and was refused
before any build. The refused diff is not kept in the kit: `changes/c24-muse` holds only a reservation marker. The
description of it here comes from the archived session on rbd-tools1.
- Fixed in b1bf461 while T5 R's iteration 2 agent was still running, before its take step. There is a test for the fix.
- From then on, T4 R and T4 C both carried test files and were taken.
- The refusal is the harness's fault, not rhobound's or the agent's. It also changed what came next: told it was
  refused, iteration 2's agent reverted its tests.
- T5 R is scored as it ran. A harness-adjusted time, without iteration 1, is given beside it.

## Results

### Per ticket and arm

| ticket | arm | outcome | iterations | lead time | lead time - B0 | - lock queue | agent | CI | checks | measure | deploys | regressions | errors up | exposure (ms x min) | rollbacks | gate verdicts | hidden | steps | tool calls | tokens | MCP calls | Stop reminders |
|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|
| T4 | C | accepted at 1 | 1/3 | 29.9 min | 23.6 min | 16.4 min | 5.1 min | 1.1 min | 1.0 min | 24.8 min | 1 | 0 | 0 | 0.0 | 0 | (counterfactual) 1:pass | 1:pass | 19 | 22 | 886337 | 0 (none) | - |
| T4 | R | accepted at 2 | 2/3 | 59.7 min | 53.5 min | 53.5 min | 24.9 min | 17.3 min | 2.0 min | 17.8 min | 1 | 0 | 0 | 0.0 | 0 | 1:inconclusive, 2:pass | 1:pass, 2:pass | 120 | 121 | 8983217 | 26 (budget 4, context 9, explain 4, fit_start 1, job_status 1, predict 7) | 0 |
| T5 | C | accepted at 1 | 1/3 | 31.8 min | 25.6 min | 18.4 min | 7.1 min | 1.1 min | 1.0 min | 24.8 min | 1 | 0 | 0 | 0.0 | 0 | (counterfactual) 1:pass | 1:pass | 20 | 23 | 885807 | 0 (none) | - |
| T5 | R | accepted at 3 | 3/3 | 63.1 min | 56.9 min | 56.9 min | 27.9 min | 17.3 min | 2.3 min | 17.7 min | 1 | 0 | 0 | 0.0 | 0 | 2:inconclusive, 3:pass | 1:-, 2:pass, 3:pass | 138 | 166 | 8386459 | 13 (budget 2, context 5, explain 3, predict 3) | 1 |

CI is arm R's PR-open-to-verdict time and arm C's PR-open-to-image time. Lead time runs from the arm's start to the end of the accepted deploy's C window; '- B0' removes every bracket's B0 window (measurement overhead); '- lock queue' also removes the time the brackets waited for the cluster lock (arm C waits behind its own counterfactual gate's A/B). Every bracket rolls back after its C window by protocol; 'rollbacks' counts the deploys rolled back because they regressed.

### Head to head

| ticket | accepted (R / C) | **lead time - B0 - queue, R - C** (headline) | lead time R - C | lead time - B0, R - C | regressions in production (R / C) | exposure (R / C, protocol-bound: one 300-s window per deploy) |
|---|---|---|---|---|---|---|
| T4 | yes / yes | +37.0 min | +29.8 min | +29.9 min | 0 / 0 | 0.0 / 0.0 |
| T5 | yes / yes | +38.5 min | +31.3 min | +31.3 min | 0 / 0 | 0.0 / 0.0 |

T5 R without the harness's false refusal: its iteration 1 (23:02:45 to 23:11:11, 8.4 min) removed gives a headline time
of 48.5 min, which is +30.1 min over arm C. That adjustment is an estimate: the agent's later iterations had seen the
refusal.

**Where arm R's extra time went (T4, headline):**

| component | R − C |
|---|---|
| agent sessions (two, against one; arm R's first was also longer, with 11 MCP calls) | +19.8 min |
| CI: A/B, predict and gate, against arm C's image build | +16.3 min |
| checks | +1.0 min |
| measurement up to the C window's end, without B0 and queue | −0.0 min |
| gaps between phases | +0.1 min |

The rows are rounded. In seconds: 1186 + 976 + 57 − 2 + 4 = 2221 s = 37.0 min.

Split another way:
- **The held iteration 1** (00:08:12 to 00:27:15): 19.1 min, about half.
- **The other 18.0 min:**
  - 7.4 min is the passing head's gate against arm C's image build (505 s against 64 s);
  - 10.6 min is arm R's second agent session running longer than arm C's only one (15.7 against 5.1 min).

**An estimate, not observed:** had the gate passed iteration 1, arm R's T4 would have taken about 28.3 min. That is
9.1 + 1.0 + 8.9 + 9.3, the last term being the measurement up to the C window's end without B0 and queue, as in the
headline. It comes to about +12 min over arm C.

**Tokens:** arm R used about 10 times arm C's: 8.4 to 9.0 M against 0.89 M per ticket.
- On T5, most of the excess is the extra iterations: 5.8 of the 7.5 M.
- On T4, the held session took 3.1 M, and the accepted revision alone took 5.9 M.
- Each arm-R session was larger than arm C's: 2.0 to 5.9 M against 0.89 M.

### Per iteration

| ticket | arm | iter | change | PR | outcome | hidden | gate verdict | measured | worst entry | lock queue | exposure | steps | tokens | MCP | Stop |
|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|
| T4 | C | 1 | c29-muse | #28 | accepted | pass | (cf) pass (mean_change@checkout) | clean | partner +2.41 ms (noisy) | 7.2 min | 0.0 | 19 | 886337 | 0 | - |
| T4 | R | 1 | c27-muse | #26 | gate_inconclusive | pass | inconclusive (doubt_holds:profile.variance_changed) | not deployed | - | - | - | 48 | 3105103 | 11 | 0 |
| T4 | R | 2 | c28-muse | #27 | accepted | pass | pass (mean_change@checkout) | clean | partner +0.23 ms | 0.0 min | 0.0 | 72 | 5878114 | 15 | 0 |
| T5 | C | 1 | c23-muse | #23 | accepted | pass | (cf) pass (mean_change@checkout) | clean | mobile +0.23 ms | 7.2 min | 0.0 | 20 | 885807 | 0 | - |
| T5 | R | 1 | c24-muse | - | refused | - | - | not deployed | - | - | - | 34 | 1981446 | 6 | 0 |
| T5 | R | 2 | c25-muse | #24 | gate_inconclusive | pass | inconclusive (doubt_holds:profile.variance_changed) | not deployed | - | - | - | 64 | 3832518 | 0 | 1 |
| T5 | R | 3 | c26-muse | #25 | accepted | pass | pass (mean_change@checkout) | clean | checkout +3.44 ms (noisy) | 0.0 min | 0.0 | 40 | 2572495 | 7 | 0 |

In this table, "clean" means no entry over the threshold. A worst entry inside the 2-to-6-ms band is marked (noisy):
by the declared rule, such a reading is not evidence either way. T5 R iteration 3 had a second noisy entry that the
table does not show, partner +3.12 ms. Neither checkout nor partner calls catalog. Search-api, which does, read
−0.89 ms on that deploy.

The shell column below counts Muse's `tool.bash` tasks: proposed, failed in the sandbox, refused unsandboxed, completed.

| ticket | arm | iter | change | files | shell: proposed / sandbox-failed / refused / completed | MCP calls | Stop exits |
|---|---|---|---|---|---|---|---|
| T4 | C | 1 | c29-muse | catalog.go, catalog_test.go | 3 / 2 / 1 / 0 | none | - |
| T4 | R | 1 | c27-muse | catalog.go, typo_test.go | 3 / 2 / 1 / 0 | budget 2, context 4, explain 2, predict 3 | [0, 0] |
| T4 | R | 2 | c28-muse | catalog.go, typo_test.go | 8 / 6 / 2 / 0 | budget 2, context 5, explain 2, fit_start 1, job_status 1, predict 4 | [0, 0, 0, 0, 0, 0, 0] |
| T5 | C | 1 | c23-muse | catalog.go | 3 / 2 / 1 / 0 | none | - |
| T5 | R | 1 | c24-muse | (refused at take) | 4 / 3 / 1 / 0 | budget 1, context 3, explain 1, predict 1 | [0, 0] |
| T5 | R | 2 | c25-muse | catalog.go | 3 / 2 / 1 / 0 | none | [2, 0, 0] |
| T5 | R | 3 | c26-muse | catalog.go | 5 / 4 / 1 / 0 | budget 1, context 2, explain 2, predict 2 | [0, 0, 0] |

### Arm C: what the gate would have said (its CI ran anyway) against the measured truth

| ticket | iter | head | counterfactual verdict | measured | worst entry | reading |
|---|---|---|---|---|---|---|
| T4 | 1 | 83f6f1d90b80 | pass (mean_change@checkout) | clean | partner +2.41 ms (noisy) | right: passed a clean change (a reading inside the noise band: no evidence either way, DECLARE.md) |
| T5 | 1 | 7b716e3d6ea1 | pass (mean_change@checkout) | clean | mobile +0.23 ms | right: passed a clean change |

### Each agent's implementation

| ticket | arm | iter | design | gate | production |
|---|---|---|---|---|---|
| T5 | C | 1 | the 50-unit discount probed once with a single `Quote` call; every product's bulk price filled in at start-up; a lookup per hit | (counterfactual) pass | clean, worst mobile +0.23 ms |
| T5 | R | 1 | the discount computed once at start-up and each product's bulk price cached; two tests added to `catalog_test.go` | none: refused by the harness | not deployed |
| T5 | R | 2 | the same design, tests reverted | inconclusive: variance doubt at `index-a` (A/B catalog +0.02 ms) | not deployed (post-hoc below) |
| T5 | R | 3 | the same, plus an unasked cache of `Search` results per query and `fmt`-free formatting | pass | no entry over the threshold: checkout +3.44 ms and partner +3.12 ms (both noisy) |
| T4 | R | 1 | a one-time inverted index (`sync.Once`) and an allocation-free one-edit check over the vocabulary; `typo_test.go` | inconclusive: variance doubt at `index-d` (A/B catalog −0.35 ms) | not deployed (post-hoc below) |
| T4 | R | 2 | the same, plus precomputed IDF, one-edit neighbour lists and per-term score rows ("removes per-request variance") | pass | clean, worst partner +0.23 ms |
| T4 | C | 1 | a one-time inverted index with IDF, and an allocation-free one-edit check; tests in `catalog_test.go` | (counterfactual) pass | clean, worst partner +2.41 ms (noisy) |

## Against the sealed criteria

**It helped if, on T5, all of these held:**

| criterion | result |
|---|---|
| arm R reaches an accepted deploy with fewer production regressions than arm C (0 against at least 1) | **no**: 0 against 0 |
| arm R takes no more wall time than arm C plus the A/B and gate cost of one iteration | **no**, whichever figure is used for that cost: +38.5 min headline (+30.1 without the harness's refusal), +31.3 min raw. The declaration gives no figure here; the measured gate took 8.4 to 8.9 min, and its T4 criterion expected 15 to 20 min |
| the gate holds or blocks every candidate that regresses in production, and passes the one that does not | **not testable for the first half**: no candidate regressed. For the second, the counterfactual gate passed arm C's T5 head, which measured clean. The real gate held arm R's iteration 2, which was not deployed in the run. An undeclared post-hoc bracket, not part of the scoring, later read no entry of it over the threshold (worst checkout +2.71 ms, inside the noise band) |

**It did not help if any of these held:**

| criterion | result |
|---|---|
| arm R deploys a change that regresses (a wrong pass) | **no**: both of arm R's deploys read below the threshold. T5 R iteration 3 read two entries inside the noise band, checkout +3.44 ms and partner +3.12 ms; by the declared rule they are not evidence either way. Neither entry calls catalog, and search-api read −0.89 ms |
| arm R never reaches an accepted deploy on a change that does not regress (a false hold that costs the ticket) | **no**: arm R reached an accepted deploy on both tickets. Its holds cost time, not the ticket |
| on T5, arm C's agent writes a good implementation first time and arm R's extra time buys nothing | **yes** |
| on T4, arm R takes longer for the same outcome (expected: about 15 to 20 minutes) | **yes**: +37.0 min, about twice the expected price. The held iteration accounts for 19.1 min and arm R's longer agent sessions for 10.6 min; the gate's own time beyond arm C's build is 7.4 min |

So, by the criteria sealed before the first run: **rhobound did not help in this experiment.** The case it is built for,
an agent shipping a hidden latency regression, never arose. What was measured is its price when nothing is wrong:
- about +37 minutes per ticket as run;
- about +11 to +12 minutes per ticket when the gate passes first time. That is an estimate from the measured phase
  times, counted to the C window's end as the headline is: T4 +11.9 min; T5 +10.9 min with iteration 2's session, the
  first to reach the gate.

## What this says about rhobound

### 1. The variance doubt held safe changes, and no code change could address it

On each ticket, arm R's first change that reached the gate was held as **inconclusive** by
`doubt_holds:profile.variance_changed`. The A/B measured the changed service, catalog, at +0.02 ms (T5) and −0.35 ms
(T4). The doubt fired at an index shard (`index-a`, then `index-d`) that the change does not touch, and `decide_with`
was empty.

On this bed, rhobound's gate ran advisory: the policy has `enforce: false`, and the finding `gate.enforce_not_earned`
says "none: the verdict is advisory". The inconclusive verdicts held the changes because the declared protocol deploys
only a pass, not because rhobound enforced them.

The mechanism, from the seven catalog A/B records on the bed:
- Each A/B tests the own-time variance of six services. The changed one is catalog. Its variance change is modelled and
  never raises the doubt: T5 R iteration 3's catalog z = −2.06 passed, and CT3's +6.5-ms plant had z = +10.91.
- That leaves five untouched services, each held at |z| > 2 with no correction for testing five at once. Their 35
  z-scores (five services × seven A/Bs) scatter like a standard normal.
- Two of the 35 crossed 2: index-a −2.27 and index-d −2.11, both *lower* variance in the candidate. That is the rate
  chance gives.
- If the five tests were independent, about 1 A/B in 5 (1 − 0.954⁵ ≈ 21%) would be held for no reason. They share one
  A/B's windows and may move together, which would lower that rate. Here, 2 of the 6 gated A/Bs were held.

| A/B | catalog | index-a | index-b | index-c | index-d | inventory | gate |
|---|---|---|---|---|---|---|---|
| T5 C i1 (counterfactual) | −1.03 | +0.35 | +1.00 | +1.36 | −0.02 | +0.62 | pass |
| T5 R i2 | −0.01 | **−2.27** | +0.21 | +0.13 | −0.83 | −1.55 | inconclusive |
| T5 R i3 | −2.06 | +0.84 | −0.30 | −0.66 | −1.95 | −0.47 | pass |
| T4 R i1 | −1.36 | −1.80 | −0.33 | −1.40 | **−2.11** | +0.59 | inconclusive |
| T4 R i2 | −1.82 | −0.34 | +0.89 | −0.07 | +0.18 | −0.10 | pass |
| T4 C i1 (counterfactual) | −0.54 | −0.52 | −0.23 | −0.78 | −0.42 | −0.20 | pass |
| CT3's planted +6.5-ms change (11-02 14:12) | +10.91 | −0.57 | +0.49 | +1.78 | −0.97 | −0.87 | (CT3) |

The z values are each service's own-time variance difference (candidate − baseline) over its standard error, from
`ab-catalog/record/ab-record.json` of each head on rbd-tools1.

**Were the holds false? A post-hoc check.** This was not declared before the runs and is not in the scoring. After the
last arm, each held candidate was deployed through the same truth bracket every arm used. The script is
`orch/muse_posthoc.sh`; it ran 01:42 to 02:17Z. The data is in `data/posthoc/`.

| held candidate | search-api | worst entry | production |
|---|---|---|---|
| T5 R iteration 2 (PR 24, catalog `9a790e98…`) | −0.70 ms | checkout +2.71 ms (noisy) | no entry over the threshold |
| T4 R iteration 1 (PR 26, catalog `885be08b…`) | −1.44 ms | partner +0.81 ms | clean |

- **T4 R iteration 1's held candidate:** no entry read near the threshold (worst partner +0.81 ms), so that hold was
  false.
- **T5 R iteration 2's:** the worst entry was checkout +2.71 ms, inside the 2-to-6-ms noise band, which by the declared
  rule is not evidence either way. Search-api, the entry the change reaches, read −0.70 ms, and checkout does not call
  catalog.

So one hold is shown false, and the other is consistent with a false hold. Each rests on one bracket (about ±2 ms), as
every other deploy in this experiment does.

**What each hold cost:** a whole iteration, about 20 minutes (T5 R iteration 2: 23:11 to 23:31; T4 R iteration 1:
00:08 to 00:27).

**What the agents did with a hold no code change could address** (the driver's feedback told them: "revise the change so that the gate can
pass it"):
- They optimised code the ticket did not ask them to touch.
- T5 R iteration 3 added a per-query cache of `Search` results.
- T4 R iteration 2 precomputed neighbour lists and score rows, to "remove per-request variance". It also started a fit
  (`fit_start`).

Both then passed. Whether because of those changes or because a new A/B simply drew new z-scores, one run cannot tell.
Either way, the hold turned a clean ticket into unrequested scope.

**Suggested fixes:**
- **In rhobound:** correct the doubt for the number of services it tests. |z| > 2.6 for five tests keeps the overall
  rate at about 4.5%, that of one test at |z| > 2; 2.58 gives about 4.8%. Or raise it only on services the change touches or calls differently: `profile.structure_changed`
  already covers changed calls.
- **When the doubt sits on an untouched service:** `decide_with` should say "re-run the A/B", not leave the agent to
  change code.
- **In this harness:** the feedback line for an inconclusive verdict should not ask for a code change when the deciding
  rule is a doubt about the measurement.

### 2. The agent-side integration was reachable; it did not change any design

- In all five arm-R sessions the six rhobound tools were offered, and four of the five called them:
  - on T4: context 9, budget 4, explain 4, predict 7, fit_start 1, job_status 1;
  - on T5: context 5, budget 2, explain 3, predict 3.
- Those are calls made. 28 of the 39 completed. The 11 that failed are the server refusing an input, each with a code
  and a fix, after which the agent's next call completed:
  - "unknown environment" ×5: the agent guessed an environment name; `prod` is the only one;
  - schema mismatch on `context` ×2;
  - budget asked for `extra_calls` (`change.unsupported_op`: "use own_ms, own_pct, workers or load_scale");
  - predict asked for −5 ms and −4 ms on an own time of 4.8 ms and 2.6 ms (`change.negative_time`);
  - explain with an unknown handle.

  Usability point: about a quarter of first tries were refused, most of them on finding the environment name.
- The agents quoted rhobound's budget for catalog (2.635 ms a visit) in their design notes.
- Arm C's agents, with no rhobound, reached the same designs from the ticket's SLO sentence and by reading `pricing.Quote`
  and `Search`.
- The opt-in Stop reminder blocked once (T5 R iteration 2, the one session with no predict). The agent then stopped
  without predicting: the hook blocks once by design, and the reminder did not change what it did. In the other sessions
  the agents called predict without being reminded.

### 3. Nothing the gate passed measured over the threshold

- **Arm C's two heads:** the counterfactual gate passed both, and neither read over the threshold. T5's worst was
  mobile +0.23 ms. T4's was partner +2.41 ms, inside the noise band: by the declared rule, not evidence either way.
- **Arm R's two passes:** neither read over the threshold. T4's worst was partner +0.23 ms. T5's were checkout
  +3.44 ms and partner +3.12 ms, both inside the noise band.
- Every noisy reading is at checkout or partner, which do not call catalog. Search-api, which does, read −1.42 ms (T4 C)
  and −0.89 ms (T5 R).
- **What it never had:** no regressing candidate reached it, so its block side was not exercised here. CT3 measured that:
  its +6.5-ms /search plant was blocked.

### 4. What this says about the tickets

- Both tickets state a general latency SLO and say nothing about where a cost lies. T5 names `pricing.Quote` only as
  the call to use. In all four arms, the agent read the code it would call and found the cost itself.
- None of the naive implementations, the ones each ticket was designed around, was written.
- To test whether rhobound catches what an agent misses, a ticket must hide the cost better:
  - in a dependency the ticket does not name;
  - in a cost that only shows under load;
  - or with no SLO sentence at all, so the agent has no prompt to look for a cost.

## Limits

- **Sample size:** two tickets, and one agent sample per ticket and arm. These results are illustrative, not a
  statistical comparison. The agent's run-to-run variability is unmeasured, and may be as large as the difference
  between the arms.
- **Tickets:** both name a general latency SLO, and in all four arms the agent read the code, found the expensive path
  and avoided it. Neither ticket's trap was sprung. These two tickets therefore cannot show rhobound catching a regression,
  only what it costs when nothing regresses.
- **No shell:** see above.
- **Exposure:** a floor here. A regressed deploy runs only for its warm-up and C window. None regressed.
- **The bed:** one catalog service, AB_SECONDS = 300, and the CT3 production fit (digest 7a84bb1c, 9.6 h old at T5 R's
  gate).
