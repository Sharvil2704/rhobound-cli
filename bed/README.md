# bed: rhobound as a deploy gate on AWS, with the experiments that measured it

A complete, runnable bed. It holds the infrastructure, the gate, the measurement and the experiments:
- **the app:** the maze, a 32-service app on k3s, built to break rhobound's queueing model while keeping its stated
  assumptions (fan-out batches, routes of different cost, payloads, shared images, asynchronous calls);
- **production-like conditions:** a 120 req/s background load and an OpenTelemetry Collector;
- **the gate:** rhobound running in GitHub Actions on a self-hosted runner;
- **the measurement:** the scripts that measured every prediction against production;
- **the experiments:** the Muse Code arms and the deploy-time comparisons.

The results are in [../docs/RESULTS.md](../docs/RESULTS.md), and the reports are in [reports/](reports/). How to run it
is in [../JUDGES.md](../JUDGES.md), tier 2.

```
PR (rhobound-change.json lists the services) -> gate.yml on the bed's runner:
  pr-check -> build (one image per image the change touches) -> ab.sh --all (one A/B per service, at once, one per A/B node)
  -> abx (a longer A/B, when the gate's preview says more measurement would decide) -> predict + gate (policy/gate.json)
  -> sign (KMS, every image) -> report
a signed pass -> deploy.sh (each service to its own image, only if every image carries the same pass) -> refit production
```

| folder | runs on | what |
|---|---|---|
| [aws/](aws/) | AWS CloudShell | `spawn_two.sh`: two beds in their own VPCs (`BED=1` with up to three A/B nodes, `BED=2` for the "agent alone" arm): roles, ECR, KMS key, secrets, a self-stop timer. Tests: `aws/tests/run_tests.sh` (a fake AWS) |
| [orch/](orch/) | your workstation | ssh to the machines (`rbd_connect.sh`), bootstrap (`rbd_bootstrap.sh`), helpers on the tools machine (`rbd.sh`), the app repo (`publish_main.sh`), the live demo (`demo_live.sh`), the Muse arms (`muse_arm.sh`, `muse2_chain.sh`), the scorers (`muse_score.py`, `p3_score.py`, `p4_score.py`) |
| [tools1/](tools1/) | the tools machine | the CI steps (`ci/`: pr-check, build, ab, predict, sign, report, deploy, refit, capture), the A/B driver (`abdrive/`), the maze's manifests and load (`maze/`), the Collector (`k8s/`), setup (`setup/`), the MCP server's setup (`mcp/`), the Muse harness (`muse/`: install, sandbox, tickets T6-T9 with hidden tests) |
| [repo/](repo/) | GitHub | the app repository: the maze source, `policy/gate.json` (4-ms limit), `.github/workflows/{gate,deploy}.yml` |
| [verify/](verify/) | the tools machine | measurement outside the product: `truthx.sh` (a change deployed between two baseline windows, then rolled back), `stagedx.sh` (one service per stage), `aa.sh` (A/A noise), `regress.py` (scores a bracket) |
| [changes/](changes/) | your workstation | `demo/`: the live demo's changes as patches (agent-written code from the experiments, and the media plant); `make_prs.sh`, `plant.py` for planted changes |
| [reports/](reports/) | none | every declaration (written before its run) and result: `muse-live/` (the Muse experiments, deploy time, multi-image gate), `maze-live/` (cluster tests 2 and 3) |

**Three rules hold throughout:**
- **No AWS on the workstation.** It never runs `aws`, and reaches the machines by ssh only.
- **No secrets in the bed's files.** Real IPs, the account id and the pasted inventory go only to the git-ignored
  `state/`.
- **Agents never merge.** A change reaches production only through a signed pass, and the demo's and experiments' PRs
  are never merged.

## Tests (offline; stubs stand in for ssh, aws, kubectl, docker, cosign and gh)

```bash
bash tools1/tests/ci/run_tests.sh       # the CI steps end to end with the real CLI (it builds one from this repository)
bash verify/tests/run.sh && bash verify/tests/truthx/run.sh
bash orch/tests/run_all.sh --quick      # the bootstrap as a dry run (it builds the binaries first when they are missing)
bash aws/tests/run_tests.sh             # spawn_two.sh against a fake AWS
bash orch/demo_live.sh --dry pass block # the demo's changes checked against the code that was gated
```

Scratch goes under `$RBD_SCRATCH`, default `$TMPDIR/rbd`. Builds go through `orch/capped.sh`, which caps memory with a
systemd scope where one is available.

## Third-party

`orch/third_party/k3s-install-v1.36.5_k3s1.sh` is the k3s install script, Apache License 2.0
([third_party/README.md](orch/third_party/README.md)). The bootstrap checks its sha256 before it runs it.
