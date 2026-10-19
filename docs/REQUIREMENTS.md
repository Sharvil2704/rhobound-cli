# What you need to get a result

rhobound reads trace files and nothing else. This page says what those traces must contain, how much of them you
need, and under which load the result means something. If a requirement is not met, the tool usually refuses with a
message that says why ([USAGE.md](USAGE.md#9-exit-codes-and-refusals) lists them). Some gaps it cannot see; those
are marked **not detected**.

## Checklist

- [ ] Every service exports **SERVER** spans, and **CLIENT** spans for the calls it makes.
- [ ] Trace context (W3C `traceparent`) is passed on every call, so a callee's span names its caller's span as parent.
- [ ] Each span's resource has `service.name`, and `k8s.pod.name` (or `service.instance.id`, or `host.name`).
- [ ] Every request is kept, or you know the head-sampling share and pass it as `--kept-share`.
- [ ] The clocks of the machines are in step (NTP), or every call has a CLIENT span.
- [ ] One continuous window with at least 100 entry requests; a few minutes at 20 or more requests/s is a good start.
- [ ] The load is steady during the window, roughly Poisson, and the busiest service is below 85% utilization.
- [ ] The traces are OTLP/JSON files, one `ExportTraceServiceRequest` per line (the Collector's file exporter).

## 1. The telemetry

### Spans and trace context

- **SERVER spans from every service.** A service is something that emits SERVER spans. Its visits, its rate, its
  service time and its worker count are all read from them.
- **CLIENT spans for outgoing calls.** They tell which service a call went to, how long the caller waited for it, and
  the network time of each hop (the quietest tenth of client time minus server time). A CLIENT span to a peer that
  has no SERVER spans in the capture (a managed database, an outside API) becomes a pure delay: it adds its mean time
  to the caller and has no queue.
- **Parent links across services.** Propagate W3C trace context (`traceparent`), as the OpenTelemetry SDKs and
  auto-instrumentation do by default. Without it each service's spans start traces of their own, and there is no
  call graph across services.
- **Lost spans.** A trace that lost a span is left out of the call structure but kept in the queues and the rates.
  Up to 5% of the traces may be broken (with a warning); above 5% the capture is **refused**, with the causes counted.
  Check the exporters' queues and that the capture holds whole requests.

### Callers outside the capture

A caller outside the capture is fine: requests may arrive with a `traceparent` from an ingress, an API gateway or a
browser whose spans are not exported here. A SERVER span whose parent is absent is an entry if more than half of its
service's server spans have no caller in the capture. That covers a gateway that calls several captured services, or
retries one, in one trace, and a service that the capture calls on a few of its visits. A CONSUMER span whose
producer is outside the capture is an entry the same way.

Any other absent parent means a span was lost: one below a top that is in the capture (a SERVER span with no parent),
one on a client or internal span, or one of a service that the capture calls on half or more of its visits.

Two limits follow:
- A capture with no captured top that lost more than half of the calls into one service would pass those losses off
  as entries (**not detected**).
- The header counts entries, so a gateway that calls several services in one trace shows more entry requests than
  user requests (it then says "N entry requests in M traces").

### Resource attributes

Of each span the reader keeps its trace, span and parent ids, its kind and its start and end times. The only
attributes it reads are:

- on the resource: `service.name` (or `k8s.deployment.name` when that is missing), `k8s.pod.name` (or
  `service.instance.id`, or `host.name`), and `container.image.name` and `container.image.tag` (listed in the JSON
  report, not modelled);
- on a client span: the peer (`peer.service`, `server.address`, `net.peer.name` or `http.host`, the first one set)
  and its port (`server.port` or `net.peer.port`), to tell which service, or which outside peer, a call went to;
- on a server span: its path (`url.path`, `http.target`, `http.route`, `http.path` or `http.url`, else the span
  name) and its method (`http.request.method` or `http.method`), only to drop health and readiness probes
  (`/healthz`, `/health`, `/readyz`, `/livez`, `/ready`, `/ping`, `/_health` and gRPC `grpc.health.v1.Health/`).

The pod attribute is how replicas are told apart. Without any of the three, all spans of a service count as one pod.
A span with no ids, no service name, or no start or end time is skipped, with a warning that counts them.

### Clocks and CLIENT spans

A call with a CLIENT span is timed on the caller's own clock. A call without one is timed by the callee's SERVER span,
on the callee's clock. Two things then depend on the clocks being in step:

- **Calls the caller does not wait for** (a notification sent after the response, fire and forget) are recognised
  by their timing: the call starts at or after the end of the caller's span, or its CLIENT span ends after that span.
  When at least 95% of a caller's calls to one callee are of this kind, the edge is **async**: the calls load the
  callee but are off the caller's latency path, and the report lists them. Between 5% and 95% all of them stay on the
  path, with a warning. A callee clock running ahead of the caller's looks like a call sent after the response: a few
  milliseconds of skew over-predict the caller (+15% to +59% on a probe), more makes the edge async with the callee's
  time read as the caller's own. The warnings say when the calls are timed by the callee's clock.
- **A first call that seems to start before its own server span** (more than 0.25 ms before, on more than 1% of a
  service's visits) gets a warning that names the cause (clock skew between pods, or a CLIENT span on the pod's own
  clock) and which way the reading moves. The reading itself is not corrected.

So export CLIENT spans for calls, or keep the clocks in step.

### Message consumers

CONSUMER spans are their own work, not part of the request that produced the message. The services a consumer
calls get those visits as entries, counted apart in the header ("+ N from message consumers"; in the JSON
`requests` is still the total and `consumer_requests` the consumers' part). A consumer's calls to peers with no
server spans are counted in a warning and left out.

### Spans and the wait for a worker

A service has a pool of workers (threads, processes, connections). A request that finds them all busy waits. Where
the SERVER span starts decides what the traces can show:

| the server span starts | what the tool can read |
|---|---|
| when the request arrives (it includes the wait for a worker) | each pod's first-come-first-served queue is rebuilt from the spans; the wait is known and the worker count can be **identified** |
| once a worker has taken the request (usual for HTTP server instrumentation) | no visit waits inside its span, so worker counts are **lower bounds** (shown as `2+`) and the model uses the bound; the wait between a caller's CLIENT span and the callee's SERVER span is still seen (`seen wait`), but an entry service's own wait before its span is never visible |

A count is identified only when at least 100 visits waited at it and their mean wait is at least 10% of the service
time and 3 standard errors. Otherwise it is a lower bound. A pool with no limit (an event loop, a thread per request)
also reads as a lower bound. When you know the real pool size, give it with `--workers svc=N` (workers per pod). A
load that takes a lower-bound service past `--max-rho` is refused with a message that says so.

Work after a service's first call out (writing the response, client-library time between calls) is read as **glue**:
time that holds no worker. A server that keeps its worker for that work (an event loop, CPU-bound response writing)
is **not detected**; the model would then under-state its utilization and wait.

### Sampling

Keep every request, or head-sample at a known share and pass it as `--kept-share F` (for example `0.25`). Rates and
utilizations are divided by that share. Sampling is **not detected**: a wrong share moves every utilization and the
`err %` column shows it (see [USAGE.md](USAGE.md#7-the-other-flags)). The share must apply to whole traces and to
every request alike; a tail sampler that keeps slow or failed requests does not.

## 2. How much data

| what | the rule |
|---|---|
| entry requests | at least **100**, or the capture is refused ("only N entry requests in the capture; need at least 100") |
| window | one continuous stretch; its length is read from the spread of the entry requests' arrivals |
| broken traces | up to 5% (warning); above 5% refused |
| visits per service | under 30 visits gives a warning that the service's estimates are rough |
| pods | a pod with fewer than 20 server spans has no queue rebuild |
| worker count | identified from 100 or more visits that waited (see above), else a lower bound |

The hard floor is 100 entry requests, but more data gives a steadier reading. A few minutes at 20 or more requests/s
is a good start. For reference: the repository's example capture is 120 s at 25.8 requests/s (3,099 requests); the
Kubernetes demo reads 150 s windows at 30 requests/s (about 4,400 requests); the test-bed captures were 300-600 s at
100 requests/s; the accuracy studies read one 400 s capture per row.

**Near 80% utilization a small input error is a large output error.** The wait grows like 1 / (1 - utilization), so
at 76-78% a 1% error in a service time is 3-4.5% of the latency and 6-10% of a change. On 400 s captures at 70-80% the
entry latency was within 5.9% on nine rows in ten, and off by up to 12.5% on the worst row
([ACCURACY.md](ACCURACY.md#0-summary)). Near that load a longer capture helps more than anything else.

## 3. Load conditions

- **Steady load.** The arrival rate is roughly constant over the window: no ramp, no burst, no deploy, restart or
  autoscaling event inside it. A pod that was up for only part of the window is not modelled.
- **Roughly Poisson arrivals from outside.** Requests from many independent clients arrive roughly like that. A
  batch job, a fixed-interval sender or a closed loop of a few users does not. Burstiness is **not detected**.
- **Below the utilization limit.** `predict` refuses a capture whose busiest service is above `--max-rho` (default
  0.85, at most 0.95), and a change that would take a service above it or past 100%. Accuracy has been studied at
  70-80%, where it is hardest.
- **No retries, timeouts, circuit breakers, CPU throttling or held thread pools** in the window. They are not
  modelled.
- **Routing.** A service with one pod is one queue of its workers. A service with several pods is a random split
  over them (what a Kubernetes Service does). Round-robin, least-request and power-of-two-choices balancing (an Envoy
  or Istio sidecar, for example) look the same in traces and are modelled as a random split too, with no warning;
  such a balancer spreads load more evenly, so the predicted wait is then too high. When the traces show the
  replicas took significantly uneven shares (p < 1e-6), the tool warns and models each replica fed its measured
  share.

## 4. The trace files

```
CAPTURE/
  traces/
    spans.jsonl            one ExportTraceServiceRequest (OTLP/JSON) per line
    more-spans.jsonl.gz    gzip is fine
```

- `CAPTURE` is a folder with a `traces/` folder in it, or a folder of trace files, or a single trace file.
- File names must end in `.jsonl`, `.json`, `.jsonl.gz` or `.json.gz`. A `.jsonl` file holds one request per line; a
  `.json` file holds any number of JSON values, one after another.
- `zstd` compression and protobuf files are not read.

### An example OpenTelemetry Collector configuration

This writes what rhobound reads. It is an example and was not run as part of this repository; check the field names
against the documentation of your Collector version. The `file` exporter and the `k8sattributes` processor are in
the Collector's contrib distribution (`otelcol-contrib`).

```yaml
receivers:
  otlp:
    protocols:
      grpc:
        endpoint: 0.0.0.0:4317
      http:
        endpoint: 0.0.0.0:4318

processors:
  # Adds k8s.pod.name (and the deployment name) to each span's resource.
  # It needs RBAC permission to read pods (and replicasets, for the deployment
  # name); see the processor's documentation.
  k8sattributes:
    extract:
      metadata: [k8s.pod.name, k8s.deployment.name, k8s.namespace.name]
  batch: {}

exporters:
  file:
    path: /data/capture/traces/spans.jsonl
    format: json        # OTLP/JSON, one request per line (the default)
    # no "compression: zstd": rhobound does not read zstd; gzip the file afterwards if you like

service:
  pipelines:
    traces:
      receivers: [otlp]
      processors: [k8sattributes, batch]
      exporters: [file]
```

Then point the tool at the folder: `rhobound predict /data/capture`. If your services already set
`service.instance.id` or `k8s.pod.name` themselves, the `k8sattributes` processor is not needed.

## 5. What it does not need

- No metrics, no logs, no profiles.
- No access to the cluster or the services: it reads files.
- No sidecar, agent or code change beyond ordinary OpenTelemetry tracing.
- No network: the binary has no dependency outside the Go standard library and makes no connections.

## 6. What it refuses, and why

| refusal | why |
|---|---|
| fewer than 100 entry requests | too few to read a rate and a service time from |
| more than 5% broken traces | the queue rebuild needs every request, and the call structure whole requests |
| no SERVER spans, or no usable spans | nothing to infer from (check the path, and that the files are traces) |
| a service above `--max-rho` at the observed load, or after the change | the model covers steady load below the limit only; past 100% there is no steady state |
| calls per visit that are neither a fixed count nor a fixed count plus one on some visits (covering 99% of visits) | the model has a fixed count or one conditional call per visit |
| calls that overlap on 5-95% of visits in a shape that is not stages (a group at once, then the next) | the model has sequential, parallel and staged calls only |
| a parallel fan-out where some branch is called on some visits only | the expected maximum needs every branch on every visit |
| a negative mean service time after the queue rebuild | the spans contradict a first-come-first-served queue: clock skew between pods, or a `--workers` count below the real one |
| a call graph with a cycle | the model needs a directed acyclic graph |

[USAGE.md](USAGE.md#9-exit-codes-and-refusals) shows the exact messages and what to do about each.
