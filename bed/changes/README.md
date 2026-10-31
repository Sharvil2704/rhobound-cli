# The four prepared changes (SPEC 6)

| change | edit (in `kshop/app/internal/work/lib_v11.go`) | service | source |
|---|---|---|---|
| `c1-noop` | a comment reworded (the control: the A/B should read ~0) | auth | - |
| `c2-auth-small` | `verify_token` PBKDF2 iterations 2500 -> 6927 | auth | rs2 `images/variants/1.1-n6927.diff` |
| `c3-auth-mid` | 2500 -> 20780 | auth | rs2 `1.1-n20780.diff` |
| `c4-pay-wait` | `risk_check` card hold 6 ms -> 15 ms | payments | rs2 `1.1-wait15ms.diff` |

Each folder: `change.patch` (against `repo/` main: the code edit plus a new `rhobound-change.json`, made with git, applies
with `git apply`) and `rhobound-change.json` (the same request on its own).

`make_prs.sh NAME...` (on the orchestrator, `gh` logged in) opens one PR per change from the CURRENT main: branch
`rbd/NAME`, the patch's code part applied, `rhobound-change.json` written fresh, pushed (never forced), `gh pr create`.
It refuses a repo that is not private or that allows squash/rebase merges, and a change that touches anything but
`kshop/app/**` and `rhobound-change.json` against main (so no patch, prepared or model-written, reaches `.github/` or
`policy/`). Every PR writes `rhobound-change.json`, so of several open PRs only one can be merged: the day keeps c1..c4
open, merges exactly one and closes the rest (`orch/RUNBOOK.md` step 7); a second change is re-cut from the new main with
`make_prs.sh` (a new gate run).
`DRYRUN=1` applies and commits in a temp clone without pushing.

Tests: `bash tools1/tests/ci/t_patches.sh` (apply checks, pr-check, linux/amd64 compile, make_prs.sh against a local bare
repo with a stub `gh`, including patches that touch `.github/` and `policy/`).

## Planted changes (SPEC3 F9): `cN-plant`, never merged

`python3 -I changes/plant.py cN-plant --service S --mechanism M [--dose D] [--replace] [--title T] [--summary TEXT]`
writes `changes/cN-plant/` in the layout above (plus `title.txt` and `manifest.json`), cut from the CURRENT `repo/` (the
frozen main). The hold is the FIRST statement of the service's hooked function, before any cache lookup or early return:

| service | hook | file |
|---|---|---|
| auth | `VerifyToken` | `kshop/app/internal/work/lib_v11.go` (library 1.1, production's `LIB=kshop_v11`) |
| payments | `RiskCheck` | same |
| inventory | `StockCheck` | same |
| catalog | `Rank` | `kshop/app/internal/hot/rank.go` |
| pricing | `Quote` | `kshop/app/internal/hot/price.go` |

| mechanism | `--dose` | what it plants |
|---|---|---|
| `sleep` | ms | `time.Sleep(D)`: the worker held, no CPU |
| `spin` | ms of CPU | a dependent xorshift64 loop, iterations calibrated once per process at the first call (fastest of 7 probes); never sleeps |
| `mutex` | ms | a package-level `sync.Mutex` held across `time.Sleep(D)` (the pod's calls serialised) |
| `bimodal` | `A:P:B` | sleep A ms w.p. P else B ms; mean and cs2 recorded. `--replace` (payments): replaces the 6 ms card hold, mean must be 6 (variance only, T1g: `101:0.05:1`) |
| `alloc` | MB | allocate, touch every 4 KiB page, drop (lib_v15's pattern) |
| `noop` | - | one comment line (control) |
| `refactor` | - | a rename of one parameter/local inside the hook (behaviour-preserving) |
| `improve` | payments: ms; auth: iterations | the card hold 6 -> D ms, or PBKDF2 2500 -> D iterations (a speed-up) |

The helper lives in a new `plant.go` in the hook's package; the patch must apply to a fresh copy of `repo/` and compile with
`orch/gocheck.sh` (agent_take.sh's capped, offline go build under the default tags and kshop_v11 and go vet). `manifest.json`
(`rbd.plant-change/v1`) records the mechanism, the knob, the placement, the intended effect and the dose rule: **the
registered dose is the A/B-measured own-time delta of the service, never the knob** (`dose.value_ms`, filled from the A/B
record). `--no-compile` is for tests: make_prs.sh refuses a plant whose manifest says `compiled: false`, and any plant whose
`change.patch` no longer has the manifest's `patch_sha256` (edited after plant.py wrote and compiled it: re-run plant.py).

`make_prs.sh cN-plant` opens a **draft** PR labelled **`rbd-plant`** (created when missing; `DRYRUN=1` says the label and
the draft state). A name is one patch: when `rbd/cN-plant` already has an open PR, make_prs.sh rebuilds the folder's change
on that PR's base and accepts it only when the trees are identical; after `plant.py --force` rewrote the folder it refuses
(close the PR, delete the branch, use a new name), so a gate never measures an old patch against a new manifest.
`orch/automerge.sh` refuses every PR labelled `rbd-plant` or with a head branch `rbd/cN-plant`, whatever its verdict (exit
3, recorded as `plant-refused`; also in merge_one on the facts re-read under the lock, before the variance guard; labels or
a branch it cannot tell are refused the same way): a planted regression never reaches deploy.yml through a merge.

Tests: `bash tools1/tests/bench/t_plant.sh` (every mechanism generates, applies and compiles; refusals),
`t_make_prs_plant.sh` (the label, draft, DRYRUN, the compiled and patch checks, a reused name) and `t_automerge.sh` (the
rbd-plant refusal in pr, once and merge_one; fail closed); all in `run_s8.sh`.
