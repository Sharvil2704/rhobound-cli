# rhobound-demo

A one-day live demo of **rhobound** gating code changes by their effect on **mean latency**, on a real cluster.

`maze`, a 32-service app built into 28 Go images and instrumented with standard OpenTelemetry, is the client's
production: it runs on a k3s cluster in AWS (one AZ) under steady Poisson load (120 rps over five entries: `/browse` on
web, `/feed` on mobile, `/q` on search-api, `/buy` on checkout, `/bulk` on partner). Services call each other in
sequence, in parallel, in batches (a fan-out of N calls to one callee) and asynchronously after the reply; several
services share one image (the four index shards). Every pull request to `main` is built, measured in the cluster,
predicted and gated before it can reach production. Images live in ECR and are deployed by digest only.

Mean latency only: rhobound says nothing about tails.

## The pipeline (`.github/workflows/gate.yml`, self-hosted runner `rbd-demo`)

| step | what it does |
|---|---|
| `pr-check.sh` | the PR may change only `maze/app/**` and `rhobound-change.json`, and must add or update a valid change request naming every service of exactly one image |
| `build.sh` | builds the changed image (`maze/app/cmd/<image>`, the service's `image` in `maze/spec.json`) with the runner host's own Dockerfile (never the PR's), pushes it to ECR, reads its digest back from the registry |
| `ab.sh` | an A/B in the cluster: the production image (arm a) and the candidate (arm b) side by side on a dedicated node, the same Poisson schedule sent to both, traces split per arm, `rhobound diff-fit` -> an A/B record (the service's own-time delta +- SE) |
| `predict.sh` | the record's delta as a measured change on production's fit (`rhobound predict`), then `rhobound gate` with `policy/gate.json`: **pass**, **block** or **inconclusive** |
| `sign.sh` | the verdict as a signed in-toto attestation on the candidate image (cosign, key in AWS KMS), and one write-once ledger row in S3 |
| `report.sh` | the job summary: the verdict first, the rule that decided it, each entry's predicted band against its threshold, the A/B delta, the digests, how to verify |

The job passes only on `pass`; `block` and `inconclusive` fail it with the verdict as the error title. The commit status
`rhobound/verdict` reads `pass|block|inconclusive: <rule>`.

`policy/gate.json`: an entry may get at most 4 ms slower on average, judged on the band widened by the model's documented
error; the listed doubts (unmodelled batch arrivals, a changed variance or call structure, ...) hold a change as
inconclusive.

## The change request (`rhobound-change.json`, one per PR)

```json
{"schema": "rbd.change-request/v1", "services": ["pricing"], "summary": "what the change does, in one or two sentences"}
```

v1 names one service; v2 (`rbd.change-request/v2`) lists every service that runs the changed image (index: index-a,
index-b, index-c, index-d). The summary is shown in the job summary.

## Where it is enforced: `deploy.sh`, not branch protection

Required status checks on a private repository need a paid GitHub plan, so the commit status is informational and a
blocked PR can still be merged. That deploys nothing:

- `deploy.yml` runs on every push to `main`. The repository allows **merge commits only** (squash and rebase merging are
  off: `gh repo edit --enable-merge-commit --enable-squash-merge=false --enable-rebase-merge=false`), so the merged PR's
  head is the merge commit's second parent; its gate run names the image.
- `deploy.sh` runs `cosign verify-attestation` with the KMS key, and deploys the image only if every verified verdict
  for that digest says `pass`, for that service, measured against the production image that is running now. Anything
  else is refused (exit 1) and production is untouched. A block is never retried into a pass.
- The steps live on the runner host in `/opt/rbd/ci/` (root-owned) and run as a separate user through `sudo`; the runner
  may call only the pipeline's steps. A step cannot be changed by a PR: the image is built from the commit's git objects
  with the host's Dockerfile, the prediction uses only an A/B record of the run's own two images, and only `sign.sh`
  signs, from the gate's own output, the image that A/B measured. The policy is pinned on the host
  (`RBD_POLICY_SHA256`, the sha256 of `main`'s `policy/gate.json`): any other policy is refused by `pr-check.sh`,
  `predict.sh`, `sign.sh` and `deploy.sh`.
- What is enforced: no image is deployed without a KMS-signed `pass` that was measured (A/B) on that exact digest under
  the pinned policy. What is not claimed: on a free private repository a PR's own edited workflow runs on the
  self-hosted runner, so the merge is not a control against a PR that edits `.github/`; read workflow changes before
  merging.

After a deploy, a new production window is captured and refitted, so the next PR is gated against the new production.

## Verify a verdict by hand (on the tools machine, as `rbd`)

```bash
. /opt/rbd/etc/rbd.env
IMG="$RBD_ECR@sha256:<candidate digest from the job summary>"
cosign verify-attestation --key "$RBD_KMS" --type https://rhobound.dev/attestations/gate-verdict/v1 \
  --insecure-ignore-tlog=true "$IMG" | jq -r .payload | base64 -d | jq .predicate
```

The predicate (`rbd.gate-verdict/v1`) holds the verdict, the evaluated rules, and the digests of the candidate and
production images, the fit, the A/B record, the prediction and the policy (the gate's digest of the effective policy,
and `policy_sha256`, the pinned file's sha256), the commit and the time of the decision.
The attestation is not in a public transparency log (`--tlog-upload=false`): it is checked against the KMS key only.

The ledger row: `aws s3 cp "s3://$RBD_BUCKET/demo1/ledger/<prediction digest>.json" - | jq .`, where the key is the
gate's prediction digest, `sha256` of `prediction.json` without its final newline:
`head -c -1 /var/lib/rbd/runs/<commit>/prediction.json | sha256sum`.

## Layout

```
maze/app/          the shop's Go source (cmd/maze-svc, cmd/maze-load, internal/work: lib_v11.go is library 1.1)
maze/Dockerfile    one image per service (context maze/); the golang base pinned by digest
maze/spec.json     the services, their workers and calls, the load mix (ground truth; rhobound never reads it)
maze/render.py     spec.json -> Kubernetes manifests
policy/gate.json    the gate's policy
.github/workflows/  gate.yml (every PR), deploy.yml (every push to main)
```

## Not in this demo

- A judge model: a pluggable step exists on the runner host (`judge.sh`: rhobound's bounded packet -> a provider
  command -> `rhobound judge-check`), not wired into `gate.yml`.
- Enforcing mode: rhobound marks every verdict `advisory` until an environment has earned enforcement (A/A floor,
  seeded regressions, ...). The pipeline still deploys only a signed `pass`.
- Tail latency, bursts, retries and timeouts.
