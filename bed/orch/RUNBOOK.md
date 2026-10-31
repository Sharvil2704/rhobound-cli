# Runbook: the operator's day

Everything below runs on this box (the orchestrator) from `bed/`, and reaches the machines by ssh only:
`orch/rbd_connect.sh` (seed, ssh), `orch/rbd_bootstrap.sh` (install, idempotent: run a step again after fixing what failed),
`orch/rbd.sh` (helpers on rbd-tools1 as user `rbd`), `orch/publish_main.sh` (GitHub main, once). This box never runs `aws`,
`kubectl` or `docker`, and never probes an outside service; `orch/rbd.sh kubectl ...` runs kubectl on rbd-tools1. ssh config:
`~/.ssh/rbd_aws_config` (`ssh -F ~/.ssh/rbd_aws_config rbd-tools1`), known hosts `~/.ssh/rbd_known_hosts`; `~/.ssh/config` is
never written. Seed, main sha and logs: `state/` (real IPs and the account id: never commit it).

**Core path first** (SPEC 0b): nothing else until bootstrap -> bgload -> one production window -> check/fit -> one A/B ->
diff-fit -> predict -> gate works, with images from ECR by digest (steps 3 to 4b). The runner, cosign and the GitHub jobs come
after it.

**Long steps run detached.** A tool call on this box is capped at 10 min. Here: `setsid nohup CMD > state/logs/NAME.log 2>&1
< /dev/null &` and poll the log. On rbd-tools1: `orch/rbd.sh bg NAME CMD...` (survives a dropped ssh), poll `orch/rbd.sh tail
NAME`. The cluster lock (`/var/lib/rbd/lock`) lets one job at a time touch the cluster: `orch/rbd.sh lock`. A gate job's A/B waits
for it up to 50 min (`AB_LOCK_WAIT=3000` in rbd.env), then fails.

**What the demo enforces** (the scope the SPEC states): `deploy.sh` deploys no image without a KMS-signed pass that was measured
(A/B) on that exact digest under the pinned policy: `RBD_POLICY_SHA256` in rbd.env = sha256 of `repo/policy/gate.json` (the bytes
pr-check.sh and predict.sh accept) and `RBD_POLICY_DIGEST` = the effective-policy digest the CLI writes as gate.json
`digests.policy` for it (predict.sh checks the gate's, sign.sh signs only that value, deploy.sh checks the signed one). Not
claimed: on a free private repo a PR's own edited workflow runs on the self-hosted runner, so "a PR cannot deploy even by editing
the workflow" is not a claim. Day-1 PRs are the owner's and the orchestrator's.

**rbd.env and the owner's knobs.** `rbd_bootstrap.sh tools1` (re)writes `/opt/rbd/etc/rbd.env` from the seed (+ the two policy
pins, `AB_LOCK_WAIT=3000`). Knobs (`JUDGE_CMD` later, ...) go in `/opt/rbd/etc/rbd.env.local`, read after rbd.env and never written
by the bootstrap: `bash orch/rbd_connect.sh ssh rbd-tools1 'echo KEY=VALUE | sudo tee -a /opt/rbd/etc/rbd.env.local'` (root, 0644).
Every step refuses a .local that is not root-owned, is group/other-writable, or changes one of `RBD_POLICY_SHA256
RBD_POLICY_DIGEST RBD_KMS RBD_HOME RBD_ECR RBD_REGION RBD_ACCOUNT RBD_BUCKET KUBECONFIG RHOBOUND_STATE` (rbd.env's only). Keep
`AB_SECONDS` at its 600 (300 s widens the A/B's SE by about 1.4x): do not set it.

## 0. Before the machines exist (here, ~20 min)

| do | expect | if it fails |
|---|---|---|
| `bash orch/rbd_bootstrap.sh build` | `built from <commit>...: <sha256> rhobound <sha256> rhobound-mcp` (build/linux-amd64/) | RBD_SRC_SHA pins another commit; Go errors: the module cache (`~/go/pkg/mod`) |
| `bash tools1/abdrive/build.sh` (part C) | `bin/abdrive` sha256 | part C's |
| `bash orch/tests/run_all.sh` | `== run_all: ALL PASSED` | read the failing test's lines; nothing on AWS or GitHub is touched |
| ORCH_IP: the owner reads this box's **Public IPv4 in the EC2 console** (this instance > Details) | the address for `spawn_demo.sh` | nothing here asks an outside service for it (SPEC 0) |
| `gh auth status` | logged in; `Token scopes:` lists `'repo'` and `'workflow'` (the first push holds `.github/workflows/`) | `gh auth refresh -h github.com -s repo,workflow` |
| `DRYRUN=1 bash orch/publish_main.sh` | `repo/: N files scanned clean`, `DRYRUN: would create ... / would push main ...` | the leak scan names `file:line: IPv4 ...` or `12-digit number`: part D fixes `repo/`; nothing was created |
| `bash orch/publish_main.sh` (BEFORE any `rbd_bootstrap.sh images` / `core`) | `created Sharvil2704/rhobound-demo (private)`, `pushed main <sha12>`, last line the main sha, also in `state/main.sha`; the repo allows merge commits only and its workflow token is read-only. This first push of main triggers ONE deploy.yml run with no runner yet: it shows red or queued, and once the runner registers (step 6) it ends `nothing to deploy` (the root commit is not a merge). Expected, a no-op | `GitHub main ... is not repo/ ... never a force-push`: someone pushed another main; compare, never force. A re-run with the same repo/ pushes nothing and only rewrites `state/main.sha` |

`rbd_bootstrap.sh images` builds production from exactly `state/main.sha` (a fresh clone of GitHub main, `git archive` of that
commit) and refuses without it: production == main by construction, and the c1..c4 PRs are cut from the same commit. On
rbd-tools1 the tree is `/var/lib/rbd/src/main` and `src/main.sha` names that commit (build.sh builds the plain tree only as it).

The workflows' `actions/checkout` pin `fbc6f3992d24b796d5a048ff273f7fcc4a7b6c09` (`# v5.1.0`, gate.yml and deploy.yml) was
verified against GitHub (tag v5.1.0) by the orchestrator on 2026-10-30: nothing to do for it here.

## 1. Owner, in CloudShell (~15 min)

`bash spawn_demo.sh plan`, `up`, then `inventory` (aws/STEPS.md). The owner pastes the block between the `# ---- paste` and
`# ---- end` lines; save it as `state/paste-1.txt`.

## 2. Connect (~3 min)

| do | expect | if it fails |
|---|---|---|
| `bash orch/rbd_connect.sh seed state/paste-1.txt` | `seed: 8 machine(s) of demo1 in ap-south-1; ...` and the table (cp, edge, load, app x3, ab, tools) | exit 2 names the bad line (an ecr_repo of another account, two tools machines, ...): ask for a fresh `inventory` |
| `bash orch/rbd_connect.sh test` | 8 lines `base=<time> cloud-init=done type=m6a... cpus=... clock=... via 169.254.169.123` | `base=NOT-YET`: cloud-init still running, wait 3-5 min. `Connection timed out`: `rbd_connect.sh myip` prints the address the machines allow; if the EC2 console's Public IPv4 differs, the owner runs `spawn_demo.sh allow-ip <ip>` |

## 3. Bootstrap (~45 min, detached)

`core` runs tools1 .. bgload in one go. Run it detached and poll (a killed foreground run would hang up images.sh mid-build):

```
mkdir -p state/logs
setsid nohup bash -c 'echo $$ > state/logs/core.pid; exec bash orch/rbd_bootstrap.sh core' > state/logs/core.log 2>&1 < /dev/null &
kill -0 "$(cat state/logs/core.pid)" 2> /dev/null && echo running || echo ended; tail -n 5 state/logs/core.log   # poll
```

Done: `[..] rbd_bootstrap: done: core`. A line `rbd_bootstrap: <message>` without a time is the failure; fix it and run the
failed step alone (`bash orch/rbd_bootstrap.sh STEP`; `images` again detached), then the remaining ones.

| step | time | expect (last lines) | if it fails |
|---|---|---|---|
| `tools1` | 5 min | `kit-install: /opt/rbd updated; bin: abdrive rhobound rhobound-mcp ...`, `RBD_POLICY_DIGEST sha256:67fdf7dc... (this box's CLI and rbd-tools1's agree)`, `tools1-setup: ok (aws 2.37.13, kubectl v1.36.5, cosign v2.6.5; users rbd, ghrunner; IMDS blocked for ghrunner; sudoers checked; the runner comes with rbd_bootstrap.sh runner)` | `sha256 of ... is not the pinned`: a changed download, stop and look (tools1/setup/pins.env). `the AWS CLI zip's signature does not verify`: AWS rotated its key; compare the docs' key and replace setup/awscli-pubkey.asc. apt lock: re-run. `ghrunner can still reach IMDS`: `rbd_connect.sh ssh rbd-tools1 sudo iptables -S OUTPUT`. `WARNING: cosign ... is NOT installed`: the core path goes on; re-run `tools1` before step 6 (sign.sh refuses without it). `no .../policy/gate.json to pin`: repo/ is incomplete. `computed no policy digest` / `no .../build/rhobound-arm64`: this box's CLI (committed in the kit) is missing or fails: nothing was written. `the installed rhobound on rbd-tools1 does not write RBD_POLICY_DIGEST ...: rbd.env not written`: the uploaded binary is not this box's source: `rbd_bootstrap.sh build tools1` |
| `k3s` | 5 min | `rbd-d-...: joined (edge/load/app/ab)`, `7 nodes Ready` | `rbd_connect.sh ssh NODE tail -20 /tmp/k3s-install.log`; re-run `k3s` (active nodes are skipped) |
| `kubeconfig` | 1 min | `kubectl get nodes` table with POOL edge/load/app/ab | `rbd cannot reach the cluster`: cp1's private IP / security group between members |
| `ecr-secret` | 1 min | the timer line of `rbd-ecr-secret.timer` | `journalctl -u rbd-ecr-secret` lines printed: the tools role (ECR GetAuthorizationToken) |
| `images` | 10-20 min | `main <sha12> -> rbd-tools1:/var/lib/rbd/src/main` (state/main.sha's, also in src/main.sha there), `{"step":"images","ok":true,"main_sha":...,"load":"...@sha256:...","collector":...,"busybox":...,"abdrive":...}` | `no GitHub main: run orch/publish_main.sh first`: step 0's publish was skipped: run it, then `images` again. `... is not a commit on ...'s main` / `cannot clone`: run `orch/publish_main.sh` (gh logged in here). `policy/gate.json at ... is not repo/'s`: GitHub main and the pin differ, stop and look. `build.sh SVC failed`: `orch/rbd.sh run tail -40 runs/.images-build-SVC.log`. `docker pull ... failed (Docker Hub limit?)`: wait or re-run (done tags are skipped). `no /opt/rbd/abdrive/...`: part C's bin, then `rbd_bootstrap.sh kit images` |
| `collector` | 2 min | `collector-config.yaml validated by ...`, `Collector (...@sha256:...) and spans-reader ready; /var/lib/rbd/traces owned by 10001` | `the Collector image (...) rejects collector-config.yaml`: its own message is printed above (a key 0.162.0 does not know): fix tools1/k8s/collector-config.yaml, `rbd_bootstrap.sh kit collector`. `did not become ready`: its last 20 log lines are printed; `orch/rbd.sh kubectl -n kshop-obs describe pod -l app=otel-collector`; ImagePullBackOff: `rbd_bootstrap.sh ecr-secret` |
| `kshop` | 2 min | `kshop ready: 11 pods running` | `orch/rbd.sh kubectl -n kshop get pods -o wide`, `... describe pod POD` |
| `bgload` | 1 min | `kshop-bgload: running` | `orch/rbd.sh kubectl -n kshop logs job/kshop-bgload` |
| `status` | | nodes, pods per namespace, baseline (no fit yet), images, lock `free`, timers active | |

The pins: `bash orch/rbd.sh run sh -c 'sha256sum src/main/policy/gate.json; grep -E "^RBD_POLICY_(SHA256|DIGEST)=" /opt/rbd/etc/rbd.env'`
prints the same 64 hex twice (today `ebacfca8...56f`) and `RBD_POLICY_DIGEST=sha256:67fdf7dc...d633` (the effective policy; the
offline proof's gate.json `digests.policy`). pr-check.sh, predict.sh, sign.sh and deploy.sh refuse any other policy.

### 3a. Smoke window before the real one (~5 min)

`bash orch/rbd.sh bg smoke1 /opt/rbd/ci/capture.sh smoke1 120 7`, then poll `bash orch/rbd.sh tail smoke1` (detached: usually
~4 min, close to 10 with the bgload stop/start and the check, longer while something holds the lock) -> `== smoke1: done, exit 0`
and the last line `{"step":"capture","ok":true,...,"verdict":"admitted"...}`; `"verdict":"admitted-with-doubts"` is fine too. Look
at `orch/rbd.sh run jq -c '{verdict, counts}' captures/smoke1/meta/check.json`: **no `trace.image_digest_missing` in `counts`**
(k8sattributes adds `container.image.repo_digests`). If it is still there: `orch/rbd.sh run sh -c 'head -c 2500 captures/smoke1/raw/traces/spans*.jsonl'`
and look for `k8s.container.name` / `container.image.repo_digests` on the resources. A capture that fails is kept as
`captures/NAME.failed-<epoch>`; its `meta/check.json` / `check.err` say why (`count.*`: the window or the count; no spans: the
Collector; `the kshop-load Job failed`: `orch/rbd.sh kubectl -n kshop logs job/kshop-load`).

## 4. Baseline: the production fit, the verifier, the first A/A window (~15 min)

| do | expect | if it fails |
|---|---|---|
| `bash orch/rbd.sh bg refit0 /opt/rbd/ci/refit.sh prod-0`, poll `orch/rbd.sh tail refit0` | `== refit0: done, exit 0` and `{"step":"refit","ok":true,"fit_digest":"sha256:...","mcp_env":"prod"...}` (mcp_env `skipped` until step 5 installed the server; `rbd_bootstrap.sh mcp` registers it then) | `production does not run baseline.json's images`: a rollout drifted, `orch/rbd.sh kubectl -n kshop get deploy -o wide`. `capture.sh failed`: as 3a |
| `bash orch/rbd_bootstrap.sh verify` (part E's scripts -> /opt/rbd/verify, root-owned) | `aa.sh collect.sh truth.sh vlib.sh` | |
| `bash orch/rbd.sh run /opt/rbd/verify/collect.sh aa prod-0` | the refit's window is A/A window 1 | |

No extra A/A windows (`aa.sh` is not run): the A/A floor is the refit's window plus each truth bracket's B0 window
(`collect.sh aa truth-<change>-b0`, step 6), four baseline windows of one baseline. The verifier is driven only through the
`orch/rbd.sh` forms in this runbook (verify/README.md "On the day" shows the same forms); never by ssh to tools1 directly.

**The fit's age.** The policy's `max_fit_age_h` is 24: every gate of step 6 must finish within 24 h of this step's refit, or it
says inconclusive (`fit_stale`). If the day slips past that, refit (`bash orch/rbd.sh bg refit1 /opt/rbd/ci/refit.sh prod-1`)
before the next gate; that is a new baseline: do not mix A/A windows (prod-0, the B0 windows) across baselines.

## 4b. The core path end to end, before any GitHub job (~30 min)

An A/A of production's own auth digest through `ab.sh` (arms, abdrive, copy and split, two checks, diff-fit), then predict and
gate by hand with the CLI. This proves the core path on the cluster before the runner, sudo, the build and cosign exist.

```
B=$(bash orch/rbd.sh run jq -r .services.auth baseline.json)          # production's auth digest, sha256:...
bash orch/rbd.sh bg core-aa /opt/rbd/ci/ab.sh core-aa auth "$B" "$B"
bash orch/rbd.sh tail core-aa                                          # poll (~18 min)
```

Expect `== core-aa: done, exit 0` and the last line `{"step":"ab","ok":true,...,"own_ms_delta":D,"own_ms_se":SE,...}` with D near
0 (|D| within about 2 SE). A failure names its `stage` and `error`; the arms are torn down by ab.sh's trap; the files are in
`runs/core-aa/ab/` (`orch/rbd.sh run jq -c '{stage: .stage, check, diff_fit: .diff_fit.exit}' runs/core-aa/ab/ab.json`).
Fix and re-run under the SAME name (`core-aa`): ab.sh moves the earlier `runs/core-aa/ab` aside (`ab.old-<time>`), so the lines
below read the new record. Then predict and gate on that record (SPEC 0b rule 3; the run name is the script's argument `$1`):

```
RUN=core-aa
bash orch/rbd.sh run bash -c '
R=runs/$1/ab; F=$(jq -r .fit.dir baseline.json)/fit.json
python3 -I - "$R" "$F" << "PY" || exit 1
import hashlib, json, sys
r, f = sys.argv[1:3]
raw = open(r + "/record/ab-record.json", "rb").read()
d = [s for s in json.loads(raw)["services"] if s["service"] == "auth"][0]["own_ms"]["delta"]
c = {"schema": "rhobound.change/v1", "fit": "sha256:" + hashlib.sha256(open(f, "rb").read()).hexdigest(),
     "items": [{"op": "own_ms", "service": "auth", "value": d, "label": "measured-ab",
                "evidence": ["sha256:" + hashlib.sha256(raw).hexdigest()]}]}
open(r + "/change.json", "w").write(json.dumps(c, indent=1) + "\n")
print("own_ms.delta", d)
PY
rhobound predict --fit "$F" --changes $R/change.json --json > $R/prediction.json; echo "predict exit $?"
rhobound gate $R/prediction.json --policy src/main/policy/gate.json --now $(date -u +%FT%TZ) --out $R/gate --json; echo "gate exit $?"
[ "$(jq -r .digests.policy $R/gate/gate.json)" = "$RBD_POLICY_DIGEST" ] && echo "policy digest ok" || echo "policy digest DIFFERS"' core-aa-4b "$RUN"
```

Expect `predict exit 0`, a band around 0 ms at storefront and checkout, `gate exit 0` (pass, advisory) and `policy digest ok`
(the gate on the cluster used the effective policy rbd.env pins; `DIFFERS`: stop, predict.sh would refuse every gate). `gate exit 3`
(inconclusive): `orch/rbd.sh run jq -c '{verdict, rules: [.rules[] | {rule, effect, entry, value, threshold}]}' runs/core-aa/ab/gate/gate.json`
says which rule.
A predict refusal (`{"error": {"code": ...}}` in prediction.json) names what the CLI did not accept (the record digest must be in
RHOBOUND_STATE: diff-fit and predict share it). Only when this passes: step 5, then the runner.

## 5. MCP on the baseline fit (~10 min)

| do | expect | if it fails |
|---|---|---|
| `bash orch/rbd_bootstrap.sh mcp` | `mcp-setup: rhobound-mcp up on 127.0.0.1:8765 (401 without a token, 200 with it)` | `journalctl -u rhobound-mcp` lines printed; `server.engine_mismatch`: re-run (the config takes the binary's sha256 again) |
| `bash orch/rbd.sh mcp list` | budget context explain fit_start job_status predict | `cannot reach`: the tunnel; HTTP 401: the token file changed, re-run `mcp` |
| `bash orch/rbd.sh mcp context '{"env": "prod"}'` | entries storefront/checkout with model ms, services with leverage; note `fit_id` | `fit.no_baseline`: refit.sh did not register (run `rbd_bootstrap.sh mcp`); `fit.expired`: refit |
| `bash orch/rbd.sh mcp budget '{"fit_id": "<fit_id>", "service": "auth"}'` | max_value / safe_value per entry | |
| `bash orch/rbd.sh mcp predict '{"env": "prod", "changes": [{"op": "own_ms", "service": "auth", "value": 1}], "repo": "Sharvil2704/rhobound-demo", "branch": "demo"}'` | a band per entry, preview `block` or `inconclusive` (declared changes never preview as pass) | |

For an interactive session: `bash orch/rbd.sh tunnel` (port 8765) in one terminal; the token: `orch/rbd.sh run cat mcp/token`
into a variable, never a file here. Static tokens are read-only: `fit_start` is refused (the CI makes the A/B, not the agent).

## 6. The runner, then four gate runs; truth brackets for c2, c3, c4 (~3.7 h)

| do | expect | if it fails |
|---|---|---|
| `bash orch/rbd_bootstrap.sh runner` | `runner-register: runner 2.338.0 unpacked in /opt/actions-runner (sha256 checked)`, `... active as ghrunner (after rbd-imds-block.service), labels self-hosted,linux,x64,rbd-demo`; the runner shows Idle in the repo's settings | `download failed` / `sha256 ... is not the pinned`: the GitHub release, re-run. `installdependencies.sh failed`: its tail is printed. `gh could not mint a registration token`: admin on the repo; `config.sh failed`: the tail of /var/tmp/rbd-runner-config.log is printed (an hour-old token: re-run) |
| `bash orch/rbd.sh run cosign version` | `v2.6.5` | not installed (the WARNING of step 3): `bash orch/rbd_bootstrap.sh tools1` |
| `gh run list -R Sharvil2704/rhobound-demo --workflow deploy.yml --limit 3 --json databaseId,status,conclusion` | step 0's deploy.yml run for main's first commit runs on the new runner and ends `nothing to deploy` (green, a no-op) | expected; only a merged PR deploys |

ghrunner may sudo exactly pr-check, build, ab, predict, sign, report and deploy as rbd (not refit, capture or judge). Then the four
changes, ONE AT A TIME, in this order: c1-noop (auth; the control: its gate pass is the control, no truth bracket), c2-auth-small
(auth), c3-auth-mid (auth), c4-pay-wait (payments). The lock is shared: open the next PR only after the previous gate job
finished AND (c2..c4) its bracket's truth.json says `status` `ok`.

| per change `<c>` | expect | if it fails |
|---|---|---|
| `bash changes/make_prs.sh <c>` (part D) | a PR from branch `rbd/<c>`; the gate job starts on the runner | `gh pr list -R Sharvil2704/rhobound-demo` |
| `H=$(gh pr view rbd/<c> -R Sharvil2704/rhobound-demo --json headRefOid -q .headRefOid)` | the PR head, 40 hex: the run's name on tools1 (`runs/$H/`) | |
| the gate run of THIS head: `ID=$(gh run list -R Sharvil2704/rhobound-demo --workflow gate.yml --commit "$H" --limit 1 --json databaseId -q '.[0].databaseId')`; `[[ $ID =~ ^[0-9]+$ ]]` or wait ~10 s and ask again (a fresh push has no run for a few seconds; `--commit` never returns an older head's run), then every few minutes `gh run view "$ID" -R Sharvil2704/rhobound-demo --json status,conclusion` (~20 min: build, A/B 660 s, predict, sign, report). Never a bare `gh run watch` (no run id fails at once, and it blocks past the 10-min cap); to watch, detached: `setsid nohup gh run watch "$ID" -R Sharvil2704/rhobound-demo --exit-status > state/logs/gate-<c>.log 2>&1 < /dev/null &` | `status` `completed`; `conclusion` `success` on `pass`, `failure` (titled `block`/`inconclusive`) otherwise; commit status `rhobound/verdict` | `gh run view "$ID" -R Sharvil2704/rhobound-demo --log-failed`: a step's last JSON line names the refusal; on tools1 `runs/$H/` holds candidate.json, ab/, prediction.json, gate/. To run it again: **Re-gate** below |
| candidate digest: `C=$(bash orch/rbd.sh run jq -r .digest runs/$H/candidate.json)` | `sha256:...` (use it exactly as printed) | |
| c2..c4 only, after the gate job ended: `bash orch/rbd.sh run /opt/rbd/verify/truth.sh <c> <service> "$C" --check`, then `bash orch/rbd.sh bg truth-<c> /opt/rbd/verify/truth.sh <c> <service> "$C"`; poll `bash orch/rbd.sh run jq -c '{status,phase,error}' verify/truth/<c>/truth.json` (~33 min) | status `ok`; production rolled back to baseline | verify/README.md; a failed bracket: re-run under `<c>-r2` |
| c2..c4: `bash orch/rbd.sh run /opt/rbd/verify/collect.sh run <c> "$H"` and `bash orch/rbd.sh run /opt/rbd/verify/collect.sh aa truth-<c>-b0` | the run's prediction.json + gate/ in the bundle; the bracket's B0 joins the A/A floor | |

**Re-gate.** A gate run may be re-run as it is, after the cause is gone, exactly when neither `runs/$H/predict.json` nor
`runs/$H/gate/` exists (it failed in pr-check, build, the A/B or predict.sh before the gate: waiting on the lock while a bracket
ran, a build or A/B failure). Check first: `bash orch/rbd.sh run ls -d runs/$H/predict.json runs/$H/gate` must print two
`cannot access` lines and nothing else (exit 2); then `gh run rerun "$ID" -R Sharvil2704/rhobound-demo`. Every step takes `runs/$H/.lock` and fails
at once when it is held, so a rerun started while a cancelled job's ab.sh is still tearing down its arms (up to ~3 min) fails in
pr-check with `another step of runs/$H is running (runs/$H/.lock is held)`: wait for the teardown, then rerun again.
Once the gate has run for a head sha (any verdict; e.g. inconclusive -> refit -> again), that sha is not gated again: build.sh,
ab.sh and predict.sh refuse when `runs/$H/predict.json` or `runs/$H/gate/` exists. A `gh run rerun` of such a head passes
pr-check (it rewrites pr.json and policy.json with the same pinned bytes) and fails at `build the candidate image`:
`runs/$H already holds a prediction: its candidate.json is not rebuilt (push a new commit to gate a new build)`.
Only sign.sh may be retried by hand on the same head, when it failed for a passing cause (S3, KMS, cosign: c1 is the day's first
live signature): `bash orch/rbd.sh step sign.sh "$H"` (the verdict is not re-decided; sign.sh signs predict.json's verdict, and a
rerun with the same prediction is a no-op for the ledger). The job stays red on GitHub; deploy.sh needs only the attestation.
Any other job that failed once the gate wrote gate/ (predict.sh after the gate, report) needs a NEW commit, which the
orchestrator pushes to the PR branch (never forced; pr-check sees the same diff). git has no identity on this box, so the
commit takes the gh account's, as make_prs.sh and publish_main.sh do; `set -e` stops before the push if the commit fails. The
push starts a new gate run: re-read `H` (the new head) and `ID` (`--commit "$H"`) as above; the bracket and collect.sh use the
new `H` and its candidate digest:

```
( set -euo pipefail
  D=$HOME/rbd-dev/tmp/regate-<c>; rm -rf "$D"
  read -r gid glogin < <(gh api user -q '"\(.id) \(.login)"')
  git -c credential.helper= -c 'credential.helper=!gh auth git-credential' clone -q --branch rbd/<c> https://github.com/Sharvil2704/rhobound-demo.git "$D"
  git -C "$D" -c user.name="$glogin" -c user.email="$gid+$glogin@users.noreply.github.com" commit -q --allow-empty -m "regate <c>"
  git -C "$D" -c credential.helper= -c 'credential.helper=!gh auth git-credential' push -q origin rbd/<c> )
```

c1 is not scored (no bracket); c2..c4 are. Do not merge any PR before c4's bracket ran: the A/A windows and every B0 share one
baseline. The PRs stay open meanwhile (only one will be merged, so their rhobound-change.json never conflict).

## 7. Merge exactly ONE passing PR (~25 min)

1. Pick: c2-auth-small if its gate passed, else c1-noop. If neither c2 nor c1 passed, skip step 7 (nothing deploys) and say so
   in the report. Merge it with a merge commit: `gh pr merge <n> -R Sharvil2704/rhobound-demo --merge`. deploy.yml runs
   `deploy.sh --run <head sha>` (verifies the signed verdict under the pinned policy: the predicate's `policy_digest` must be
   `RBD_POLICY_DIGEST`; rolls out, updates baseline.json, runs refit.sh). Its run is the merge commit's (never step 0's no-op deploy run): `M=$(gh pr view <n> -R Sharvil2704/rhobound-demo --json
   mergeCommit -q .mergeCommit.oid)`, then `ID=$(gh run list -R Sharvil2704/rhobound-demo --workflow deploy.yml --commit "$M"
   --limit 1 --json databaseId -q '.[0].databaseId')` (numeric, else wait ~10 s and ask again), polled with `gh run view "$ID"`
   as in step 6.
   Expect it green and `bash orch/rbd.sh run jq -c '{capture, fit: .fit.digest}' baseline.json` to show the new capture.
2. Close the others: `gh pr close -R Sharvil2704/rhobound-demo <n> --delete-branch`. Their verdicts were measured against the
   production that ran before the merge: deploy.sh refuses them as stale, and their rhobound-change.json conflicts with main's.
   A refused stale verdict is the expected refusal of an out-of-date measurement, NOT "the enforcement working".
3. A second passing change can deploy only after it is re-cut from the new main: `bash changes/make_prs.sh <c>` (its old branch
   deleted in 2), a new gate run (~20 min) against the new production, merged only on that new pass.

## 8. Score (~10 min)

`bash orch/rbd.sh get /var/lib/rbd/verify/aa verify/data`, `bash orch/rbd.sh get /var/lib/rbd/verify/truth verify/data`, then
`python3 -I verify/score.py --bundle verify/data --out verify/out` -> `verify/out/report.md` (failures first).

## 9. Later

The model-written change (an agent with the MCP tools through the tunnel; its key via `spawn_demo.sh secret NAME` in CloudShell,
never on this box), then the judge (`ci/judge.sh`, part D: not in ghrunner's sudoers and not part of day 1; `JUDGE_CMD` goes in
rbd.env.local).

## Time budget (machine time, nothing failing)

| phase | min |
|---|---|
| 1-2 CloudShell `up`, cloud-init, seed, test | 20 |
| 3 bootstrap `core` (detached) | 45 |
| 3a smoke window | 5 |
| 4 refit prod-0 (600-s window, copy, check, fit), verify install, `collect.sh aa prod-0` | 15 |
| 4b core A/A (`ab.sh`: rollout, 60 + 600 s, teardown, copy, split, checks, diff-fit) + predict and gate by hand | 30 |
| 5 MCP | 10 |
| 6 runner + cosign check | 5 |
| 6 c1-noop: gate job 20 + turnaround 10 (no bracket) | 30 |
| 6 c2, c3, c4: gate job 20 + truth bracket 33 + turnaround 10, each 63 | 189 |
| 7 merge one: deploy + refit; close the others | 25 |
| 8 score | 10 |
| **after the bootstrap (3a to 8)** | **319 (5.3 h)** |
| **from `up`** | **384 (6.4 h)** |

About 1.6 h of slack against an 8-h day: one failed A/B costs ~20 min, one failed bracket ~33 min (everything is serialized by
the lock). The machines' cap is 16 h (`rb-deadline extend` below).

## When things go wrong

| symptom | look | fix |
|---|---|---|
| ssh times out everywhere | `orch/rbd_connect.sh myip` (the address the machines allow) against the EC2 console's Public IPv4 of this box | the owner: `spawn_demo.sh allow-ip <ip>` |
| the time cap is near | `orch/rbd_connect.sh exec all 'rb-deadline show'` | `orch/rbd_connect.sh exec all 'sudo rb-deadline extend 4'` (never past the hard ceiling) |
| a step waits on the lock | `orch/rbd.sh lock` (holder, pid, since) | wait; a holder that died frees it by itself (flock). A background child of a holder keeps fd 9: `orch/rbd.sh run fuser -v /var/lib/rbd/lock` |
| pods ImagePullBackOff | `orch/rbd.sh kubectl -n NS get events --sort-by=.lastTimestamp \| tail` | `rbd_bootstrap.sh ecr-secret` (token 12 h, refreshed every 4 h) |
| background load stopped | `orch/rbd.sh run /opt/rbd/kshop/bgload.sh status` | `orch/rbd.sh run /opt/rbd/kshop/bgload.sh start` (the timer restarts it within 5 min when the lock is free) |
| a window or the background load at another rate/mix (SPEC3 F6a) | `orch/rbd.sh run /opt/rbd/kshop/load.sh show`; `orch/rbd.sh run /opt/rbd/kshop/bgload.sh status` (the setting, and a running Job at another load); a capture's `meta/capture.json` `.load` and the last line of its `meta/load.json` | `orch/rbd.sh run /opt/rbd/kshop/load.sh set --rps 130` (or `--mix browse=0.7,card=0.18,wallet=0.12`, or `--rates browse=91,card=18,wallet=12`; 10..400 rps), `... load.sh reset` for spec.json's 100 rps: one file, `/var/lib/rbd/load.env`, under the lock, the background load restarted at it (a refused `set` changes nothing: the old file and the running Job stay); capture.sh windows and every bgload restart (its trap, the 5-min ensure) follow it. `the load setting is refused`: the reason follows (owner/mode, a hand edit, or `RBD_LOAD_RPS`/`RBD_LOAD_MIX` in rbd.env.local disagreeing with the file): `load.sh set` again or `load.sh reset` |
| no Collector file covers a window | `orch/rbd.sh kubectl -n kshop-obs exec spans-reader -c reader -- ls -l /data` | the Collector's log; the janitor deletes rotated files older than 6 h |
| `a rotation during the copy ... again` in an A/B log | | normal: the Collector rotated spans.jsonl while it was copied; the copy was done again |
| a kit file changed here (any part) | | `bash orch/rbd_bootstrap.sh kit` (files replaced by rename; running steps keep their copy) |
| an owner knob (`JUDGE_CMD`, ...) | `orch/rbd.sh run cat /opt/rbd/etc/rbd.env.local` | rbd.env.local, never rbd.env (`rbd_bootstrap.sh tools1` rewrites rbd.env) |
| every step says `rbd-env: .../rbd.env.local ... refused` | `bash orch/rbd_connect.sh ssh rbd-tools1 'ls -l /opt/rbd/etc; cat /opt/rbd/etc/rbd.env.local'` | `sudo chown root:root` and `sudo chmod 0644` it; remove any line that sets a pin or path of rbd.env (`RBD_POLICY_*`, `RBD_KMS`, `RBD_HOME`, ...) |
| disk on tools1 | `orch/rbd_bootstrap.sh status` (last line) | old `captures/*/raw/` can go once a capture's cut/ exists (the CLI reads cut/) |

Teardown: the owner runs `spawn_demo.sh down` (then `destroy`) in CloudShell. Nothing here needs cleaning but `state/`.
