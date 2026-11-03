# verify/: the independent verifier, run from your workstation

Measures each change's real effect on production itself and scores the gate's verdict against it. Never part of the product:
it imports and runs no rhobound code; on rbd-tools1 it uses kubectl and part B's `capture.sh` only, and `score.py` reads files.

| file | runs | does |
|---|---|---|
| `truth.sh CHANGE SERVICE CAND_DIGEST [--keep\|--check]` | tools1, as rbd | B0 window, candidate rolled out of band, warm 180 s, C window, rollback (trap: always on failure unless `--keep`) |
| `aa.sh N [PREFIX]` | tools1, as rbd | N back-to-back baseline windows (`capture.sh aa-<i>`) for the A/A floor; not run on the day (see below) |
| `collect.sh run CHANGE RUN` / `collect.sh aa CAPTURE` | tools1, as rbd | copies the run's prediction.json + gate/ (or a baseline window: the refit's, a bracket's B0) into the bundle |
| `vlib.sh` | sourced | shared helpers, the lock convention |
| `score.py` | your workstation, `python3 -I` | the score: `out/score.json` (`rbd.verify-score/v1`) and `out/report.md` |
| `tests/run.sh` | your workstation | every offline test (stubs for kubectl and capture.sh) |

## On the day

From your workstation, through its helpers (JUDGES.md, tier 2): `orch/rbd.sh run CMD...` runs CMD on rbd-tools1
as rbd in /var/lib/rbd with rbd-env.sh sourced; `orch/rbd.sh bg NAME CMD...` runs it detached (setsid nohup: a dropped ssh does
not HUP the bracket, which would roll it back), output in /var/lib/rbd/logs/NAME.out; `orch/rbd.sh get REMOTE LOCAL` copies a
folder of rbd-tools1 into LOCAL. Truth brackets run for c2, c3 and c4 only (none for the no-op c1, which is then not scored).

```
# install (once; root-owned like /opt/rbd/ci)
bash orch/rbd_bootstrap.sh verify
# A/A floor, window 1: the refit's (after refit.sh prod-0)
orch/rbd.sh run /opt/rbd/verify/collect.sh aa prod-0
# per change, c2-auth-small (auth), c3-auth-mid (auth), c4-pay-wait (payments), after its gate job ended (the lock must be
# free): preflight in the foreground, then the bracket (~35 min)
orch/rbd.sh run /opt/rbd/verify/truth.sh c2-auth-small auth sha256:<cand> --check
orch/rbd.sh bg truth-c2 /opt/rbd/verify/truth.sh c2-auth-small auth sha256:<cand>
orch/rbd.sh tail truth-c2                                                     # poll: "== truth-c2: done, exit 0"
orch/rbd.sh run jq -c '{status,phase,error}' verify/truth/c2-auth-small/truth.json
orch/rbd.sh run /opt/rbd/verify/collect.sh run c2-auth-small <head sha>
orch/rbd.sh run /opt/rbd/verify/collect.sh aa truth-c2-auth-small-b0           # A/A floor: this bracket's B0
# score here, after the last bracket
orch/rbd.sh get /var/lib/rbd/verify/aa verify/data
orch/rbd.sh get /var/lib/rbd/verify/truth verify/data
python3 -I verify/score.py --bundle verify/data --out verify/out      # exit 0 none listed, 1 failures listed, 2 cannot run
```

A failed bracket keeps its files; re-run it under a new CHANGE name (`c2-auth-small-r2`, then `collect.sh run c2-auth-small-r2
<head sha>` and `collect.sh aa truth-c2-auth-small-r2-b0`); `score.py --bundle` skips the failed one and says so. When a B0's
`capture.sh` failed after its window (kept as `truth-<change>-b0.failed-<epoch>`; truth.sh uses it and warns), `collect.sh aa`
takes that window from there too.

**The A/A floor** (no `aa.sh` on the day): the refit's window `prod-0` plus each bracket's B0, all production at one baseline:
4 windows, 6 pairs after c2..c4. Per entry (storefront = `/browse`, checkout = `/buy/card` + `/buy/wallet` weighted by ok, from
maze-load's own client-side means), the floor is the p90 (nearest rank) of |mean_i - mean_j| over all pairs; with 6 pairs that
is the largest difference. Pairs share windows, so they are not independent. Each B0 is also its own change's B0: a B0 that
drifted from the other baseline windows widens the floor, which is what the floor is for. A truth class is unresolved when
|observed - T| < floor. Score after the last bracket: before the second bracket there is at most one pair (score.py lists it).
Never mix windows of two baselines: merge nothing before the last bracket ran, and never add a later refit's window (after a
deploy, `deploy.sh` runs `refit.sh` on a new baseline). More windows when time allows: `orch/rbd.sh bg aa /opt/rbd/verify/aa.sh
N` (about 11 min each, under the lock, before any merge).

`--keep` is for inspecting the candidate only: production then differs from baseline.json, so `deploy.sh` ("fix the drift first")
and the next `truth.sh`/`aa.sh` refuse until the service is set back (truth.sh prints the command).

## Contracts it relies on (part B)

- `/opt/rbd/lib/rbd-env.sh` exports `RBD_HOME`, `RBD_ECR`, `KUBECONFIG`; `$RBD_HOME/baseline.json` `.services[SVC]`, `.image_ref`.
- The lock: flock on `$RBD_HOME/lock`, held by the verifier for its whole run through part B's `rbd_lock WAIT_S WHAT`
  (`tools1/lib/lock.sh`: fd 9, exports `RBD_LOCK_HELD`); `capture.sh` (and `bgload.sh` under it) see `RBD_LOCK_HELD` plus fd 9 open
  on the lock file and do not lock again. Without `rbd_lock` the verifier flocks fd 9 itself, the same way. It then probes that a
  second open is refused, and stops a `capture.sh` that waits on the lock anyway (`/proc/locks`) at once, instead of deadlocking.
  `RBD_LOCK_WAIT` [60 s]: the verifier fails fast when a gate job holds the cluster. The other way round, a gate job's `ab.sh`
  waits up to `AB_LOCK_WAIT` [3000 s] for a running bracket.
- `capture.sh NAME SECONDS SEED` writes `$RBD_HOME/captures/NAME/meta/load.json` (maze-load's log) and starts the background
  load again before it returns. When it fails after the window finished (e.g. `rhobound check` refused), part B keeps the folder
  as `NAME.failed-<epoch>`: the verifier uses that load.json and records a warning (it needs only load.json).
- Deployment `SERVICE` in namespace `maze` has a container named `SERVICE`; images are `RBD_ECR@sha256:...`.

## What score.py reads (nothing else)

- **load.json** (maze-load's job log): JSON lines `{url, ok, errors, mean_ms}` matched by URL path (`/browse`, `/buy/card`,
  `/buy/wallet`; `mean_ms` is over ok requests, so checkout = card and wallet weighted by `ok`), the line
  `maze-load: N requests over S s (R rps), seed K` (start, seed, the request total cross-check) and `maze-load: done in`.
- **prediction.json** (`rhobound-cli.report/v2`): `version`, `fit_digest`, `items[].service`,
  `entries[].{name, before_ms, change_ms.lo/hi, band_ms.lo/hi}`; a refusal `{"error": {"code"}}`.
- **gate/gate.json** (`rhobound.gate/v1`): `schema`, `verdict`, `exit_code`, `advisory`, `digests.fit`,
  `policy.{max_entry_mean_change_pct, max_entry_mean_change_ms}`, `rules[].{number, rule, effect, entry, value, threshold}`.
- **gate/verdict.txt**: the verdict word. **truth.json** (`rbd.truth/v1`): `status`, `service`, `base_digest`, `cand_digest`, `keep`,
  `warnings` (listed as problems); `--bundle` skips a bracket whose status is not `ok`/`ok-kept` and says so.

T is computed as the gate does (`internal/gate/policy.go` Threshold: the smaller of the ms limit and pct of the prediction's
`before_ms`) because gate.json's rule 10 names only the deciding entry; it is checked against that row's `threshold`.
Truth classes: unresolved if |observed - T| < A/A floor, else regression if observed > T, else clean; a change takes its worst entry.
