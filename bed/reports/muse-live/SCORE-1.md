# Muse Code with and without rhobound: scoreboard

Generated 2026-11-03T02:49:23Z by orch/muse_score.py from state/muse/*/timeline.json. One agent sample per ticket and arm: illustrative, not a statistical comparison (DECLARE.md). Single-window noise is about +-2 ms; a worst entry between 2 and 6 ms is marked (noisy).

## Per ticket and arm

| ticket | arm | outcome | iterations | lead time | lead time - B0 | - lock queue | agent | CI | checks | measure | deploys | regressions | errors up | exposure (ms x min) | rollbacks | gate verdicts | hidden | steps | tool calls | tokens | MCP calls | Stop reminders |
|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|
| T4 | C | accepted at 1 | 1/3 | 29.9 min | 23.6 min | 16.4 min | 5.1 min | 1.1 min | 1.0 min | 24.8 min | 1 | 0 | 0 | 0.0 | 0 | (counterfactual) 1:pass | 1:pass | 19 | 22 | 886337 | 0 (none) | - |
| T4 | R | accepted at 2 | 2/3 | 59.7 min | 53.5 min | 53.5 min | 24.9 min | 17.3 min | 2.0 min | 17.8 min | 1 | 0 | 0 | 0.0 | 0 | 1:inconclusive, 2:pass | 1:pass, 2:pass | 120 | 121 | 8983217 | 26 (budget 4, context 9, explain 4, fit_start 1, job_status 1, predict 7) | 0 |
| T5 | C | accepted at 1 | 1/3 | 31.8 min | 25.6 min | 18.4 min | 7.1 min | 1.1 min | 1.0 min | 24.8 min | 1 | 0 | 0 | 0.0 | 0 | (counterfactual) 1:pass | 1:pass | 20 | 23 | 885807 | 0 (none) | - |
| T5 | R | accepted at 3 | 3/3 | 63.1 min | 56.9 min | 56.9 min | 27.9 min | 17.3 min | 2.3 min | 17.7 min | 1 | 0 | 0 | 0.0 | 0 | 2:inconclusive, 3:pass | 1:-, 2:pass, 3:pass | 138 | 166 | 8386459 | 13 (budget 2, context 5, explain 3, predict 3) | 1 |

CI is arm R's PR-open-to-verdict time and arm C's PR-open-to-image time. Lead time runs from the arm's start to the end of the accepted deploy's C window; '- B0' removes every bracket's B0 window (measurement overhead); '- lock queue' also removes the time the brackets waited for the cluster lock (arm C waits behind its own counterfactual gate's A/B). Every bracket rolls back after its C window by protocol; 'rollbacks' counts the deploys rolled back because they regressed.

## Per iteration

| ticket | arm | iter | change | PR | outcome | hidden | gate verdict | measured | worst entry | lock queue | exposure | steps | tokens | MCP | Stop |
|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|
| T4 | C | 1 | c29-muse | #28 | accepted | pass | (cf) pass (mean_change@checkout) | clean | partner +2.41 ms (noisy) | 7.2 min | 0.0 | 19 | 886337 | 0 | - |
| T4 | R | 1 | c27-muse | #26 | gate_inconclusive | pass | inconclusive (doubt_holds:profile.variance_changed) | not deployed | - | - | - | 48 | 3105103 | 11 | 0 |
| T4 | R | 2 | c28-muse | #27 | accepted | pass | pass (mean_change@checkout) | clean | partner +0.23 ms | 0.0 min | 0.0 | 72 | 5878114 | 15 | 0 |
| T5 | C | 1 | c23-muse | #23 | accepted | pass | (cf) pass (mean_change@checkout) | clean | mobile +0.23 ms | 7.2 min | 0.0 | 20 | 885807 | 0 | - |
| T5 | R | 1 | c24-muse | - | refused | - | - | not deployed | - | - | - | 34 | 1981446 | 6 | 0 |
| T5 | R | 2 | c25-muse | #24 | gate_inconclusive | pass | inconclusive (doubt_holds:profile.variance_changed) | not deployed | - | - | - | 64 | 3832518 | 0 | 1 |
| T5 | R | 3 | c26-muse | #25 | accepted | pass | pass (mean_change@checkout) | clean | checkout +3.44 ms (noisy) | 0.0 min | 0.0 | 40 | 2572495 | 7 | 0 |

## Arm C: what the gate would have said (computed by CI anyway) against the measured truth

| ticket | iter | head | counterfactual verdict | measured | worst entry | reading |
|---|---|---|---|---|---|---|
| T4 | 1 | 83f6f1d90b80 | pass (mean_change@checkout) | clean | partner +2.41 ms (noisy) | right: passed a clean change (a reading inside the noise band: no evidence either way, DECLARE.md) |
| T5 | 1 | 7b716e3d6ea1 | pass (mean_change@checkout) | clean | mobile +0.23 ms | right: passed a clean change |

## R against C, per ticket (of several attempts, the latest that ran to an end)

| ticket | accepted (R / C) | **lead time - B0 - queue, R - C** (headline) | lead time R - C | lead time - B0, R - C | regressions in production (R / C) | exposure (R / C, protocol-bound: one 300-s window per deploy) |
|---|---|---|---|---|---|---|
| T4 | yes / yes | +37.0 min | +29.8 min | +29.9 min | 0 / 0 | 0.0 / 0.0 |
| T5 | yes / yes | +38.5 min | +31.3 min | +31.3 min | 0 / 0 | 0.0 / 0.0 |
