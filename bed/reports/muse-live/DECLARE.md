# Muse Code, with and without rhobound: declaration (written before any run)

**The question:** Muse codes a task and deploys it to the services. How much does rhobound really help, and how
quickly does a change deploy, compared with deploying without rhobound ("chaotic" deployment)?

## The arms

The two arms use the same agent: Muse Code 1.4.14 with `muse-spark-1.3` at effort `high`. Each gets the same step cap,
the same ticket text (which states the SLO) and the same deployment and measurement. They differ only in what rhobound
gives them.

| | arm R (rhobound) | arm C (chaotic) |
|---|---|---|
| agent user on tools1 | `muser`: the rhobound plugin (skills, opt-in Stop reminder) and the rhobound MCP server (context, budget, predict, ...) against the bed's production capture and policy | `musec`: no plugin, no MCP |
| before deploying | the bed's CI: build, A/B (300 s), predict, gate, sign; only a gate **pass** is deployed | the images are built, then deployed at once (no A/B, no gate) |
| when it goes wrong | a non-pass verdict is fed back (verdict, deciding rules, `decide_with`); the agent revises | a measured production regression is rolled back and fed back (the entry changes); the agent revises |

**Common to both arms:**
- **Deploy and measure:** `verify/truthx.sh`. A 300-s B0 window on production at baseline, then the candidate's images
  for every service it changes, a warm-up, a 300-s C window, and a rollback. The background load runs at 120 rps.
- **Iterations:** at most 3 per ticket and arm (1 + 2 revisions).
- **Hidden tests:** run on a copy of the workspace. A failure is fed back and nothing is deployed.
- **Untrusted output:** the agent never pushes. Its diff becomes a PR only through `orch/agent_take.sh`.
- **No merge:** nothing is merged to main, and production returns to baseline after every run.

## The tickets, and the order

| ticket | what it asks | why it is here | order |
|---|---|---|---|
| T5 (SRCH-27) | search results show each hit's bulk price (`pricing.Quote` for 50 units, divided by 50) | a trap: `Quote` looks cheap but costs about 2.4 ms of CPU a call. The obvious one-call-per-hit version (20 hits a search) adds about +50 ms at `search-api` and regresses production; a memoised or precomputed one stays at noise | C first, then R |
| T4 (SRCH-19) | typo-tolerant search | near the threshold: the obvious per-word edit distance sits on the 4-ms SLO at `search-api` on this bed (about +3.85 ms true); a precomputed one is noise (about +0.1). Shows what rhobound costs, and how both arms treat a change that a single bracket cannot place | R first, then C |

The order runs the trap first. Each ticket alternates which arm goes first, so neither arm always meets the warmer
cluster. Each arm runs in a fresh workspace (a copy of the bed's main tree) under its own user. Between tickets the
users' homes are archived (sessions, workspaces, previews), so nothing an agent wrote for one ticket is there for the next.
The model keeps no memory between sessions.

**Time limit.** The machines stop at about 05:20Z. An arm is started only if its 3 iterations could finish before then.
If time runs short, the order of what is dropped is: arm C's counterfactual wait, then T4's second arm, then T4.

## Definitions

- **Regression:** an entry's mean latency in the C window exceeds the B0 window by more than 4.0 ms, the bed
  policy's `max_entry_mean_change_ms`. Single-bracket noise is about ±2 ms.
- **Decision rule:** one bracket per deploy, and its reading decides (roll back, or accept). There is no second bracket
  for a close reading. Every reading within 2 ms of the threshold (2 to 6 ms) is flagged in the report as within noise:
  the arm acted on it, but it is not evidence that the change did or did not regress.
- **Accepted:** deployed, the hidden tests pass, and no regression in the measurement.
- **Lead time:** wall time from the ticket's start to the end of the accepted deploy's measurement.
- **Headline time:** the lead time minus (a) every B0 window and its settle, which is measurement overhead a real deploy
  would not have, and (b) the time a deploy waited for the cluster lock while arm C's counterfactual CI (which a chaotic
  pipeline would not run) held it. Both raw lead time and headline time are reported.
- **Exposure:** for every deploy that regressed, the minutes production ran the candidate times the ms over the
  threshold (the worst entry). It is bound by this protocol: here a regressed deploy runs only for its warm-up and C
  window, then rolls back. In a real chaotic pipeline it would run until someone noticed. So this exposure is a floor,
  not an estimate of real exposure.
- **Also recorded:**
  - iterations, deploys, rollbacks;
  - agent wall time, model steps and tokens;
  - CI time (build; A/B, predict, gate);
  - rhobound MCP calls and Stop reminders (arm R);
  - for arm C, the verdict the CI gate computed for each head anyway (the counterfactual).

## What would mean rhobound helped, and what would mean it did not

**It helped if, on T5:**
- arm R reaches an accepted deploy with fewer production regressions than arm C (0 vs at least 1);
- arm R takes no more wall time than arm C plus the A/B and gate cost of one iteration;
- the gate holds or blocks every candidate that regresses in production (counterfactual on arm C), and passes the one
  that does not.

**It did not help if any of these holds:**
- arm R deploys a change that regresses (a wrong pass);
- arm R never reaches an accepted deploy on a change that does not regress (a false hold that costs the ticket);
- on T5, arm C's agent writes a good implementation first time and arm R's extra time buys nothing;
- on T4, arm R takes longer for the same outcome (expected: the A/B and gate cost, about 15 to 20 minutes). If the agent
  writes the naive version, which sits on the threshold, either arm may hold or roll back on a reading inside the noise.
  That is reported as such, not as a win for either arm.

That last case is rhobound's price, and it is reported as such.

**Agent settings, both arms:**
- 80 model steps per session and an hour of wall time;
- no approvals, no questions to a user;
- offline Go (`GOPROXY=off`, the module cache made before the session);
- the IMDS endpoint is rejected for both users;
- neither user can read the tickets' hidden tests, the runner's or the bed's credentials, or the other user's home;
- arm C's user also cannot see rhobound: the plugin, the MCP server, the capture and the engine are hidden from its
  sessions.

The hidden tests check the behaviour the ticket asks for. A hard-coded discount would also pass T5's tests. Any such
shortcut is reported, not scored as a good implementation.

**Limits, stated now:** two tickets, one agent sample per ticket and arm. The agent's own variability may be as large
as the arms' difference. These results are illustrative, not a statistical comparison, and the report says so.

---

**Added 2026-11-02 23:15Z, after T5 C and during T5 R (no criterion above is changed).** An unplanned condition: the
agents could not run shell commands. Muse's bundled sandbox (bwrap) fails on rbd-tools1 with
`loopback: Failed RTM_NEWADDR: Operation not permitted`, because Ubuntu 24.04 sets
`kernel.apparmor_restrict_unprivileged_userns = 1`. With `--disable-approval`, an unsandboxed command is refused, not
approved. So no agent could run `go build`, `go test` or a benchmark; both arms edit by reading. The rhobound MCP tools
are started by Muse outside that sandbox and are not affected. The condition is kept identical for all four arms (tools1
is not changed mid-experiment). RESULTS.md counts each session's refused commands and discusses what this does to the
comparison.
