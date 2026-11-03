# Muse Code alone vs Muse Code with rhobound, experiment 2: declaration (written before any run)

This is an actual build and test. Muse codes hard tickets and deploys them to the running services. The
question is whether Muse alone or Muse with the rhobound plugin works better. Profiling must be clean, with the
services running, and no old data may be used.

## The two beds, one per arm

Two identical clusters (`aws/spawn_two.sh`), each in its own VPC. Each is the CT3 maze bed:
- 32 services on k3s;
- an OpenTelemetry Collector;
- a load node;
- 3 app nodes;
- rbd-tools1.

Bed 1 also has the A/B node. The two beds run at the same time, so neither arm meets the other's cluster state or a
warmer cluster.

| | bed 1, arm R: Muse + rhobound | bed 2, arm C: Muse alone |
|---|---|---|
| agent | Muse Code 1.4.14 as `muser`, with the rhobound plugin (skills, opt-in Stop reminder) and the rhobound MCP server against bed 1's own fresh production fit and the bed policy | Muse Code 1.4.14 as `musec`; no rhobound file exists on bed 2 |
| path to production | the PR's CI: build, A/B (300 s), predict, gate; **only a gate pass is deployed** | the PR's CI builds the image (`RBD_ARM=C`: no A/B, no gate), then it is **deployed at once** |
| after a deploy | the measured entry changes; a regression is rolled back and fed back | the same |
| after a non-pass | the verdict, its deciding rules and `decide_with` are fed back; nothing is deployed | (none) |

**Common to both arms:**
- **The agent:** the same agent and model (`muse-spark-1.3`, effort high), 150 model steps and 40 minutes per session.
- **Tickets:** the same ticket text, and the same hidden tests on a copy of the workspace (a failure is fed back and
  nothing is deployed).
- **Checks:** the same untrusted-output checks (`orch/agent_take.sh`, which counts a vet-compiled `_test.go` as checked
  since b1bf461).
- **Deploy and measure:** `verify/truthx.sh` on that bed. A 300-s B0 window at baseline, the candidate's images, a
  warm-up, a 300-s C window, then a rollback, under 120 rps of background load.
- **No merge:** the agent never pushes; its diff becomes a PR only through `agent_take.sh`, and nothing is merged.

**A working shell, this time.** Muse's own sandbox (bwrap) must run on both rbd-tools1 machines before the first
session, so that the agents can build, test and benchmark. Experiment 1's agents could not run any command.
- **The fix:** an AppArmor profile that allows user namespaces for Muse's bundled bwrap only (`tools1/muse/sandbox.sh`).
- **The check:** a sandboxed `go version` and `go test` run as each user in a probe session.
- **If the profile cannot be made to work within 20 minutes:** both beds set
  `kernel.apparmor_restrict_unprivileged_userns=0` instead, and the report says so.
- **If neither works:** the experiment does not start. It will not run without a shell again.

**The rhobound version under test** includes the two fixes found in experiment 1, made before this declaration:
- the engine at maze-fix-rvar f4852029: a variance change of a service the change does not touch is a doubt only past
  the Šidák bound for the record's untouched services;
- rhobound-mcp muse-plugin c85d37a9: an unknown environment's refusal names the configured environments and captures.

**Fresh data only.** Nothing from experiment 1 or CT3 is reused:
- new clusters and new repos (`Sharvil2704/rhobound-muse-r` and `-c`);
- bed 1's production fit is a new 600-s capture under the 120-rps background load, after the services are warm;
- the A/B records, predictions and truth windows are all new;
- an A/A bracket on each bed (the baseline deployed as the candidate) measures that bed's noise before the arms start.

## The tickets, all three in this order on both beds

Each is a real feature on a hot path whose service has a small worker pool. Each was written for the work, not around a
planted cost, and none was measured on a bed beforehand. Hidden tests check behaviour against an in-test reference;
each ticket's reference patch passes them.

| ticket | what it asks | the service and its callers |
|---|---|---|
| T6 (RANK-41) | diversify the reranked top 10 with maximal marginal relevance | rank: 1 worker, about 54 calls/s at 9 ms of work, from feed (mobile /feed) and search-api (/q) |
| T7 (FRAUD-12) | velocity rules for fraud scoring: per-card sliding windows, bounded memory, safe for concurrent use | fraud: 1 worker, about 18 calls/s at 18 ms, from checkout through order and payment |
| T8 (PRICE-88) | apply the best combination of 12 promotions (5 exclusivity groups, 384 combinations) to each quote | pricing: 2 workers, about 114 calls/s (checkout, and partner's batches of 4 to 12) |

**Every ticket states the same latency SLO:** no user-facing entry's mean may rise more than 4 ms. It does not say
where a cost lies.

**The time box.** Each ticket gets at most 3 iterations. The arms start together at T0, after both beds pass their
checks. No new iteration starts after T0 + 3 h 30 min, and no new ticket after T0 + 3 h. An iteration in flight at
the cut is finished if it can be, and recorded as it stands if it cannot.

## Definitions

- **Regression:** an entry's mean in the C window exceeds B0 by more than 4.0 ms (the bed policy).
- **Decision rule:** one bracket decides. A reading of 2 to 6 ms is flagged as within noise; it is not evidence either
  way. Each bed's A/A gives its own noise; if a bed's A/A reads beyond ±2 ms, the report says so.
- **Accepted:** the hidden tests pass, the change is deployed, and no regression is measured.
- **Lead time:** from the ticket's start to the end of the accepted deploy's C window. The headline leaves out the B0
  windows, which are measurement overhead.
- **Shipped regression:** a deploy that measured a regression. Production ran it for its warm-up and C window, then it
  was rolled back. Its size is the worst entry's ms over 4.
- **Also recorded, per iteration:**
  - agent time, steps and tokens;
  - shell commands run and completed;
  - MCP calls and their refusals;
  - Stop reminders;
  - CI time, gate verdicts, A/B deltas and the deciding rules;
  - hidden-test results, measured entry changes and exposure.

## What would mean which arm works better

Over the three tickets:
- **Arm R (with rhobound) works better** if it ships fewer regressions than arm C, and accepts at least as many
  tickets.
- **Arm C (Muse alone) works better** if either holds:
  - arm R ships as many regressions or more, and takes longer to its accepted deploys;
  - arm R accepts fewer tickets.
- **Otherwise the result is mixed.** The report says what each arm gained and what it paid. For example, fewer
  regressions bought with more time, or the same outcome reached faster.

Each gate hold is checked after the run against what production measured: a hold of a candidate that never deployed
gets a post-hoc bracket if time allows, labelled post-hoc.

**Limits, stated now:**
- One agent sample per ticket and arm: three tickets, two arms.
- The beds are identical by construction, not by measurement. Each deploy is measured against its own bed's B0, so a
  constant offset between the beds cancels.
- The results are illustrative, not a statistical comparison.

---

**Added 2026-11-03 07:15Z, after T0 (07:01:38Z); no criterion above is changed.** A harness fault spoiled bed 2's
first T6 attempt.
- **What happened:** `task.sh` (run as root) created `/var/lib/rbd/tmp` root-owned. CI's `pr-check`, run as rbd, could
  then not make its scratch folder, and the arm C driver read that as a build failure and fed it back. Iteration 2 was
  coding on that false feedback when the arm was stopped at 07:07Z.
- **The fix:** the folder was given back to rbd on both beds before bed 1's first PR. `task.sh` and `hidden.sh` now keep
  root's scratch in `muse/tmp` (6c9175e).
- **The re-run:** bed 2's T6 restarted at 07:10:20Z as a new attempt (tag `r2`), after musec's home was archived, under
  the same T0 and time box. The spoiled attempt (`state/muse/T6-C`, PR rhobound-muse-c#1, closed) is kept on record and
  not scored.
- **Bed 1 was not affected:** its first PR's `pr-check` ran after the fix.

**Added 2026-11-03 07:45Z; no criterion is changed.** A second harness fault, this time in my hidden tests, spoiled
bed 1's first T7 attempt.
- **What happened:** T7's hidden test declared a helper type `charge` in package fraud. The agent's change also named a
  type `charge`, so the tests did not compile against a change that may well have been correct.
- **What the agent got:** that compile error, as feedback. It named a line of the hidden test file.
- **The fix:** the T7 and T8 hidden-test helpers were renamed (`hid` prefix) at 07:42Z on both beds, before bed 2's T7
  reached its hidden tests. Re-checked against the reference patches, and with a `charge` type added to fraud.
- **The re-run:** bed 1's T7 restarted at 07:42:44Z as attempt `r2`, with the spoiled attempt's workspace, runs and
  sessions archived. The spoiled attempt (`state/muse/T7-R`) is kept on record and not scored.
- **T6 is unaffected:** its tests compiled in both arms.

**Added 2026-11-03 07:50Z; no criterion is changed.** A third harness fault, again in a hidden test, spoiled bed 2's
first T7 attempt.
- **What happened:** T7's hook test assumed the process's Velocity was empty. The package's own tests run first in
  the same process, and bed 2's agent's tests had charged cards there, so the velocity rule rightly fired. A change
  that passed every other hidden test failed this one, and the failure was fed back.
- **The fix:** the hook test now checks that each answer is consistent: known reasons, in order, and
  R = min(99, Score + 30·velocity + 25·amount) for consecutive seeds, whatever state the agent's tests left. It was
  installed on both beds at 07:45:49Z, before bed 1's T7 r2 reached its hidden tests.
- **T8 hardened the same way:** its hook seed search is widened (the agent's tests may call the hook first).
- **The re-run:** bed 2's T7 restarted at 07:46:45Z as attempt `r2`, with the spoiled attempt archived and kept on
  record, not scored.
- **Both arms' T7 are now attempt `r2`,** run against the same final hidden tests.

**Added 2026-11-03 07:55Z, before either bed reached T8: the tickets are frozen.**
- **T8's hidden tests are final as of fa9f37b.**
- **A fault found later in a ticket's tests may be patched mid-run only if both hold:**
  - the patch removes a false failure for correct implementations, so it is strictly more permissive;
  - no arm has yet passed that ticket's tests under the old version.
- **Otherwise:** either both arms re-run that ticket, if the time box allows, or it is scored as it ran, with a note.
- **No further intervention** unless a harness fault is confirmed from the logs.
- **Bed 2 (Muse alone) has no gate,** so its "counterfactual" column (the CI verdict the gate would have given) does not
  apply. The scoreboard's `error` there means "no gate on this bed", not a failure.
