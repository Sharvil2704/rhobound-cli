# Muse Code with and without rhobound: scoreboard

Generated 2026-11-03T09:50:54Z by orch/muse_score.py from state/muse/*/timeline.json. One agent sample per ticket and arm: illustrative, not a statistical comparison (DECLARE.md). Single-window noise is about +-2 ms; a worst entry between 2 and 6 ms is marked (noisy).

## Per ticket and arm

| ticket | arm | outcome | iterations | lead time | lead time - B0 | - lock queue | agent | CI | checks | measure | deploys | regressions | errors up | exposure (ms x min) | rollbacks | gate verdicts | hidden | steps | tool calls | tokens | MCP calls | Stop reminders |
|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|
| T6 | C | died | 2/3 | - | - | - | 6.2 min | 0.6 min | 1.0 min | - | 0 | 0 | 0 | 0.0 | 0 | (counterfactual) 1:error | 1:pass, 2:- | 35 | 39 | 1457802 | 0 (none) | - |
| T6 (r2) | C | accepted at 1 | 1/3 | 25.7 min | 19.5 min | 19.5 min | 8.1 min | 1.1 min | 1.0 min | 17.7 min | 1 | 0 | 0 | 0.0 | 0 | (counterfactual) 1:error | 1:pass | 34 | 34 | 1552237 | 0 (none) | - |
| T6 | R | accepted at 1 | 1/3 | 31.5 min | 25.4 min | 25.3 min | 6.6 min | 8.4 min | 1.1 min | 17.8 min | 1 | 0 | 0 | 0.0 | 0 | 1:pass | 1:pass | 42 | 48 | 2440251 | 7 (budget 1, context 3, explain 2, predict 1) | 0 |
| T7 | C | died | 2/3 | - | - | - | 5.6 min | - | 0.8 min | - | 0 | 0 | 0 | 0.0 | 0 | - | 1:fail, 2:- | 36 | 38 | 1939129 | 0 (none) | - |
| T7 (r2) | C | accepted at 1 | 1/3 | 25.1 min | 18.9 min | 18.9 min | 7.6 min | 1.1 min | 1.0 min | 17.8 min | 1 | 0 | 0 | 0.0 | 0 | (counterfactual) 1:error | 1:pass | 36 | 37 | 1913046 | 0 (none) | - |
| T7 | R | died | 2/3 | - | - | - | 4.1 min | - | 0.8 min | - | 0 | 0 | 0 | 0.0 | 0 | - | 1:fail, 2:- | 20 | 19 | 969357 | 0 (none) | 1 |
| T7 (r2) | R | not_accepted | 3/3 | - | - | - | 59.8 min | 25.8 min | 3.1 min | - | 0 | 0 | 0 | 0.0 | 0 | 1:inconclusive, 2:inconclusive, 3:inconclusive | 1:pass, 2:pass, 3:pass | 229 | 243 | 5342869 | 16 (budget 4, context 6, explain 3, predict 3) | 1 |
| T8 | C | accepted at 1 | 1/3 | 25.7 min | 19.5 min | 19.5 min | 8.1 min | 1.1 min | 1.0 min | 17.7 min | 1 | 0 | 0 | 0.0 | 0 | (counterfactual) 1:error | 1:pass | 32 | 34 | 1975113 | 0 (none) | - |
| T8 | R | accepted at 2 | 2/3 | 36.9 min | 30.7 min | 30.6 min | 10.7 min | 8.9 min | 1.8 min | 17.8 min | 1 | 0 | 0 | 0.0 | 0 | 2:pass | 1:fail, 2:pass | 56 | 60 | 3586990 | 0 (none) | 2 |

CI is arm R's PR-open-to-verdict time and arm C's PR-open-to-image time. Lead time runs from the arm's start to the end of the accepted deploy's C window; '- B0' removes every bracket's B0 window (measurement overhead); '- lock queue' also removes the time the brackets waited for the cluster lock (arm C waits behind its own counterfactual gate's A/B). Every bracket rolls back after its C window by protocol; 'rollbacks' counts the deploys rolled back because they regressed.

## Per iteration

| ticket | arm | iter | change | PR | outcome | hidden | gate verdict | measured | worst entry | lock queue | exposure | steps | tokens | MCP | Stop |
|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|
| T6 | C | 1 | c30-muse | #1 | build_failed | pass | (cf) error | not deployed | - | - | - | 15 | 592453 | 0 | - |
| T6 | C | 2 | c31-muse | - | died | - | - | not deployed | - | - | - | 20 | 865349 | 0 | - |
| T6 (r2) | C | 1 | c32-muse | #2 | accepted | pass | (cf) error | clean | checkout +3.36 ms (noisy) | 0.0 min | 0.0 | 34 | 1552237 | 0 | - |
| T6 | R | 1 | c30-muse | #1 | accepted | pass | pass (mean_change@mobile) | clean | partner +0.96 ms | 0.0 min | 0.0 | 42 | 2440251 | 7 | 0 |
| T7 | C | 1 | c33-muse | - | hidden_fail | fail | - | not deployed | - | - | - | 36 | 1939129 | 0 | - |
| T7 | C | 2 | c34-muse | - | died | - | - | not deployed | - | - | - | - | - | - | - |
| T7 (r2) | C | 1 | c35-muse | #3 | accepted | pass | (cf) error | clean | mobile +1.07 ms | 0.0 min | 0.0 | 36 | 1913046 | 0 | - |
| T7 | R | 1 | c31-muse | - | hidden_fail | fail | - | not deployed | - | - | - | 20 | 969357 | 0 | 1 |
| T7 | R | 2 | c32-muse | - | died | - | - | not deployed | - | - | - | - | - | - | - |
| T7 (r2) | R | 1 | c33-muse | #2 | gate_inconclusive | pass | inconclusive (range_straddles) | not deployed | - | - | - | 32 | 1764255 | 0 | 1 |
| T7 (r2) | R | 2 | c34-muse | #3 | gate_inconclusive | pass | inconclusive (range_straddles) | not deployed | - | - | - | 144 | - | 8 | 0 |
| T7 (r2) | R | 3 | c35-muse | #4 | gate_inconclusive | pass | inconclusive (range_straddles) | not deployed | - | - | - | 53 | 3578614 | 8 | 0 |
| T8 | C | 1 | c36-muse | #4 | accepted | pass | (cf) error | clean | search-api +0.95 ms | 0.0 min | 0.0 | 32 | 1975113 | 0 | - |
| T8 | R | 1 | c36-muse | - | hidden_fail | fail | - | not deployed | - | - | - | 37 | 2740293 | 0 | 1 |
| T8 | R | 2 | c37-muse | #5 | accepted | pass | pass (mean_change@mobile) | clean | web +0.40 ms | 0.0 min | 0.0 | 19 | 846697 | 0 | 1 |

## Arm C: what the gate would have said (computed by CI anyway) against the measured truth

| ticket | iter | head | counterfactual verdict | measured | worst entry | reading |
|---|---|---|---|---|---|---|
| T6 | 1 | 61e02860dbce | error | not deployed | - | no truth (not deployed) |
| T6 (r2) | 1 | 9c621e6a0781 | error | clean | checkout +3.36 ms (noisy) | no verdict (CI error) |
| T7 (r2) | 1 | 5fd8126893cc | error | clean | mobile +1.07 ms | no verdict (CI error) |
| T8 | 1 | 9ba98b7144b5 | error | clean | search-api +0.95 ms | no verdict (CI error) |

## R against C, per ticket (of several attempts, the latest that ran to an end)

| ticket | accepted (R / C) | **lead time - B0 - queue, R - C** (headline) | lead time R - C | lead time - B0, R - C | regressions in production (R / C) | exposure (R / C, protocol-bound: one 300-s window per deploy) |
|---|---|---|---|---|---|---|
| T6 (R first, C r2) | yes / yes | +5.8 min | +5.8 min | +5.9 min | 0 / 0 | 0.0 / 0.0 |
| T7 (R r2, C r2) | no / yes | - | - | - | 0 / 0 | 0.0 / 0.0 |
| T8 | yes / yes | +11.2 min | +11.2 min | +11.2 min | 0 / 0 | 0.0 / 0.0 |
