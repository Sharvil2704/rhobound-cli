# Scripts of the real-cluster run

These scripts ran the CLI on a real cluster of five machines (k3s on AWS) on 2026-10-21. They work on any k3s or Kubernetes
cluster whose nodes carry the labels `rbv/role=app` (application nodes) and `rbv/role=load` (the load node, tainted
`rbv/role=load:NoSchedule`). [docs/REAL_CLUSTER.md](../../docs/REAL_CLUSTER.md) tells what was found, and
[its section 2](../../docs/REAL_CLUSTER.md#2-how-to-reproduce-it) has the commands from an unlabelled cluster to the results.

| file | what it does |
|---|---|
| `phase-a.sh` | Phase A: the repository's cluster test (`e2e/e2e_test.go`, [DEMO.md](../../docs/DEMO.md) Demo 2) at three loads, 35%, 58% and 72% busy, with a change of `api`'s service time at each. Reports the model against the load generator's own measurement. `RBV_DRYRUN=1` prints the plan and stops. |
| `otel/run.sh` | Phase B: deploys the [OpenTelemetry Demo](https://github.com/open-telemetry/opentelemetry-demo) 2.2.0 with its load generator, copies its Collector's trace file back, cuts steady windows and runs `rhobound infer` and `rhobound predict` on them. `plan` renders the manifests and stops (no cluster). |
| `otel/collector-rhobound.yaml` | the extra Collector configuration that writes the traces as OTLP/JSON |
| `otel/locustfile_browse.py` | the load generator's `browse` mix: only its product-page task |
| `otel/otelcap/` | `otelcap cut` takes a window out of a Collector file as whole traces; `otelcap stats` describes a capture |

Each script's header lists every setting. The scripts build the CLI from this tree (`go build ./cmd/rhobound`) and write all their files
under `RBV_RESULTS`.
