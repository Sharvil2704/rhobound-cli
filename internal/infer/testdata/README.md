# Test data of internal/infer

| path | what it is |
|---|---|
| `fifo_golden.json`, `stage_golden.json` | golden values of the reference implementation for the queue rebuild and the stage template. Generated, not captured. |
| `counts/shipped-20s/` | 478 whole traces (6,049 spans) of the OpenTelemetry Demo: the first 20 s of the window of its own load mix |
| `hops/browse-45s/` | 824 whole traces (7,373 spans) of the OpenTelemetry Demo: the first 45 s of the window of the product-page task only |
| `nested/*/` | two or three whole traces each (4 to 100 spans) of the OpenTelemetry Demo, one set for each pattern of nested spans of one kind (Next.js, flagd, .NET's gRPC client) and one for a message consumer |
| `hops/cache-30s/` | 1,121 whole traces (7,847 spans) of this repository's own demo services (`e2e/demoapp`, not the OpenTelemetry Demo): the first 30 s of one window of the cluster test |

## The OpenTelemetry Demo traces

The traces in `counts/`, `hops/browse-45s/` and `nested/` are excerpts of traces produced by the
[OpenTelemetry Demo](https://github.com/open-telemetry/opentelemetry-demo) (the "Astronomy Shop"), release 2.2.0 (its
Kubernetes manifest, which runs the Demo's 2.1.3 service images), Copyright The OpenTelemetry Authors, licensed under the Apache License, Version 2.0, like this repository. The Demo
ran on a k3s cluster of five machines under a Locust load of 100 users, with its Collector writing the traces as
OTLP/JSON; [REAL_CLUSTER.md](../../../docs/REAL_CLUSTER.md) tells how. NOTICE at the root of this repository names
them too.

They are cut-down excerpts, not the Collector's files:

- **Whole traces only.** A trace is in a file with every span the Collector wrote for it, or not at all. The windows are
  the first 20 s and 45 s of 420 s windows; the `nested/` sets are two or three traces each. The full windows (tens of
  megabytes) are not in the repository.
- **Fields kept**, the ones the reader (`internal/otlp`) uses: on each resource, `service.name`, `k8s.deployment.name` and
  `k8s.pod.name` (the reader also takes `service.instance.id` or `host.name` as the pod when a resource has no pod name, and
  `container.image.*` as the image; every resource here has a pod name and none carried an image, so no such attribute was kept); on each scope, its `name`; on each span, `traceId`, `spanId`,
  `parentSpanId`, `name`, `kind`, `startTimeUnixNano` and `endTimeUnixNano`, and of its attributes only those that name
  the far side of a call (`peer.service`, `server.address`, `net.peer.name`, `http.host`, `server.port`,
  `net.peer.port`) or a server span's path and method (`url.path`, `http.target`, `http.route`, `http.path`,
  `http.url`, `http.request.method`, `http.method`). Everything else (other resource and span attributes, events,
  status, schema URLs, scope versions) was left out; the reader ignores all of it, and the tool's output on the one file that was
  cut down in this way (`hops/browse-45s/`) is the same before and after.
- **Not every set has every field.** `counts/shipped-20s/` carries no scope names (none of its 407 scope blocks has one) and no
  `k8s.deployment.name`, only `service.name` and `k8s.pod.name` on its resources, so the CLI warns that the nested pairs of that capture could not be
  judged by scope; `hops/cache-30s/` carries no scope names; the `nested/` sets carry scope names but no `k8s.deployment.name`;
  `hops/browse-45s/` has all of them.
- **Addresses.** The addresses of pods and services of the cluster, which appear as the far side of some calls, are
  replaced by addresses from the documentation range 192.0.2.0/24 (RFC 5737), one for each original address, so that
  two spans that named one address still do. Pod names (`frontend-554669cf7c-z98zc`) are the cluster's, and timestamps
  are as captured.
- No span was edited, added or removed, apart from what the two points above say. Tests that need other captures
  build them in memory from these (for example `longlived_test.go` adds three streams to flagd's spans).

The files are gzip streams with no file name and a zero time stamp (`.jsonl.gz`), or plain `.jsonl`; both are read by
`otlp.ReadDir` as a capture is: `CAPTURE/traces/spans.jsonl[.gz]`. The `counts/` and `hops/` sets are captures that
`rhobound predict` accepts (for example `rhobound predict internal/infer/testdata/counts/shipped-20s`). The `nested/` sets are too
small for the CLI: it refuses a capture with fewer than 100 entry requests (and the consumer set has no SERVER spans), so only the
tests read them.
