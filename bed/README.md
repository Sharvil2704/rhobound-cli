# bed: the deploy gate on AWS

A complete, runnable setup of rhobound as a CI deploy gate with a coding agent: 8 AWS machines, a k3s cluster running
the demo shop kshop, an OpenTelemetry Collector, a GitHub self-hosted runner, the rhobound CLI and MCP server, a
KMS-signed verdict, and Meta models for the agent and the judge. Results: [docs/mcp/RESULTS.md](../docs/mcp/RESULTS.md).

```
ticket -> agent (Meta muse-spark, MCP: context/budget/predict) -> PR -> gate.yml on the runner:
  pr-check -> build image -> A/B per changed service (isolated node, 300 s) -> diff-fit -> predict --fit --changes
  -> gate (policy) -> judge (advisory) -> KMS sign -> PR comment
signed pass -> automerge -> deploy.yml: verify signature -> roll out -> refit production
```

| Folder | Runs on | What |
|---|---|---|
| [aws/](aws/) | AWS CloudShell | `spawn_demo.sh`: machines, network, roles, ECR, KMS key, secrets, a self-delete timer |
| [orch/](orch/) | your workstation (the orchestrator) | connect over ssh, bootstrap the cluster, drive runs, publish the app repo, MCP over a tunnel |
| [tools1/](tools1/) | the tools machine | CI steps (`ci/`), A/B driver (`abdrive/`), agent (`agent/`), judge (`judge/`), approaches bench (`bench/`), kshop manifests and load (`kshop/`, `k8s/`), setup (`setup/`) |
| [repo/](repo/) | GitHub | the app repository the agent changes: kshop source, `policy/gate.json`, `.github/workflows/{gate,deploy}.yml` |
| [verify/](verify/) | the tools machine | `truth.sh`: deploy a candidate to production for one window between two baseline windows, then roll back |
| [changes/](changes/) | your workstation | ready-made changes (`plant.py`) and `make_prs.sh` to open them as PRs |

## Run it

Needs: an AWS account (34 vCPU on-demand in one region), a GitHub account with `gh` logged in (scopes `repo`, `workflow`),
Go 1.26+, `jq`, `python3`, and a Meta Model API key. The orchestrator never runs `aws`; it reaches the machines by ssh.

1. **Build and test locally**
   ```bash
   bash orch/rbd_bootstrap.sh build          # rhobound + rhobound-mcp for linux/amd64 from this commit -> build/linux-amd64/
   go build -o build/rhobound-arm64 ../cmd/rhobound   # the orchestrator's own CLI (any arch; the name is fixed)
   bash tools1/abdrive/build.sh
   bash orch/tests/run_all.sh --quick
   ```
2. **Publish the app repository** (private, merge commits only): `bash orch/publish_main.sh` (`RBD_GH_REPO=owner/name`).
3. **Machines, in CloudShell** ([aws/STEPS.md](aws/STEPS.md)): `ORCH_IP=<orchestrator public IP> bash spawn_demo.sh plan`,
   then `up`, then `inventory`; save the printed block as `state/paste-1.txt`.
4. **Connect and bootstrap** (~45 min, idempotent; re-run a failed step alone):
   ```bash
   bash orch/rbd_connect.sh seed state/paste-1.txt && bash orch/rbd_connect.sh test
   bash orch/rbd_bootstrap.sh core           # tools1 k3s kubeconfig ecr-secret images collector kshop bgload
   bash orch/rbd_bootstrap.sh verify mcp runner
   ```
5. **Baseline fit**: `bash orch/rbd.sh bg refit0 /opt/rbd/ci/refit.sh prod-0`, then `bash orch/rbd.sh tail refit0`.
6. **Model key** (CloudShell): `bash spawn_demo.sh secret <name>`; only the tools machine can read it.

## Use it

| Task | Command |
|---|---|
| Open a change as a PR (the gate runs on it) | `bash changes/make_prs.sh c42-plant` |
| Run the agent on a ticket | `bash orch/rbd.sh run python3 -I /opt/rbd/agent/agent.py --out /var/lib/rbd/agent/r1 --task /opt/rbd/agent/task-pricing.md`, then `bash orch/agent_take.sh r1 c5-model` and `bash changes/make_prs.sh c5-model` |
| Ask the MCP server | `bash orch/rbd.sh mcp budget '{"fit_id": "<fit_id>", "service": "pricing"}'` (tools: `context`, `budget`, `predict`, `explain`, `fit_start`, `job_status`), or `bash orch/rbd.sh tunnel` for `http://127.0.0.1:8765/mcp` |
| A gate's result | `bash orch/rbd.sh run sed -n 1,40p runs/<head sha>/summary.md` |
| Predict two changes together | `rhobound predict --fit FIT --changes C` with both PRs' `change.json` items |
| What-if at another load | `rhobound predict --fit FIT --changes C --load-scale 1.2` |
| Measure the truth of a change | `bash orch/rbd.sh bg t1 /opt/rbd/verify/truth.sh c42 catalog,pricing <digest>[,<digest>]` |
| Load level | `bash orch/rbd.sh run /opt/rbd/kshop/load.sh set --rps 120` / `reset` |
| Merge signed passes automatically | `bash orch/automerge.sh watch` (planted changes never merge; `state/automerge.stop` stops it) |
| Status, lock | `bash orch/rbd.sh status`, `bash orch/rbd.sh lock` |
| Stop everything (CloudShell) | `bash spawn_demo.sh down` |

A change request (`rhobound-change.json`, schema `rbd.change-request/v2`) names 1 to 5 services built from one image and an
optional base image key (`tools1/kshop/bases.json`); the gate runs one A/B per service and one prediction for all.

## Knobs

| Knob | Where | Default |
|---|---|---|
| Entry limit, block rule | `repo/policy/gate.json` (`max_entry_mean_change_ms`, `block_band`) | 4.0 ms, `model` |
| A/B length | `AB_SECONDS` in `/opt/rbd/etc/rbd.env.local` | 600 s (300 s in the published run) |
| Truth window, warm-up | `RBD_WINDOW_S`, `RBD_WARM_C`, `RBD_WARM_B0` | 300, 180, 120 s |
| Judge | `JUDGE_CMD`, `JUDGE_MODE` (`gate` or `advisory`) | off |
| Agent | `RBD_AGENT_PROVIDER`, `RBD_AGENT_MODEL`, `RBD_AGENT_SECRET` | `meta`, `muse-spark-1.3` |

The full day, step by step with expected output and fixes: [orch/RUNBOOK.md](orch/RUNBOOK.md).

## Tests

Offline, no AWS or GitHub calls (fakes for `aws`, `gh`, `kubectl`, `ssh`). Some need a dev root `$HOME/rbd-dev`
(`capped.sh` -> `orch/capped.sh`, `tmp/` as a real directory, a baseline capture `capture/`, `rhobound`, a gate fixture `leaf/`):
```bash
bash aws/tests/run_tests.sh;  bash orch/tests/run_all.sh;  bash verify/tests/run.sh
bash tools1/tests/ci/run_tests.sh;  bash tools1/tests/agent/t_agent.sh;  bash tools1/tests/ab/run_all.sh
```
