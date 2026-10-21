# rhobound-cli

rhobound reads OpenTelemetry traces of a microservice system and predicts the **mean latency** of every service and
of the requests users send. It also predicts what a change does: "if `checkout` did 3 ms more work per request, how
much slower would the whole request be?" It models each service as a queue, so it accounts for the extra waiting a
busier service causes, not only for the added time. It is for engineers who already collect traces and want an
answer before they deploy. It is one static Go binary with no dependencies beyond the standard library, under the
Apache-2.0 license, and a port of an unpublished Python prototype (called "the reference implementation" in the docs).

## What it does and does not do

It does:
- read traces (OTLP/JSON files) and infer the call graph, each service's own time, its worker count and its replicas;
- read the traces of real software, not only of services built for it: a framework's nested spans of one kind (Next.js, flagd's handler, .NET's gRPC
  client) are one visit or one call, a service that makes a different number of calls on different requests (a cart service that calls its
  cache 1, 2 or 3 times) enters with its mean count and a service of many endpoints as a mixture of up to 12 call shapes, a caller whose
  SDK stamps span starts on whole milliseconds (Node.js) is read by where its callees' spans are, and lost spans are named, not only counted
  ([REAL_CLUSTER.md](docs/REAL_CLUSTER.md) tells how that was found);
- predict the mean latency of every service, and compare it with what the traces measured;
- predict the effect of a change you specify (`--patch svc=+3ms` or `svc=-10%`) on every service above it;
- refuse, with a reason, when the data or the load is outside what it can model: also a capture whose server spans are gRPC streams or long
  polls (it asks for a window cut by the time its traces started).

It does not:
- predict tails (p95, p99), only the mean;
- model bursts, retries, timeouts, circuit breakers, autoscaling or CPU throttling;
- work above 85% utilization of the busiest service (`--max-rho`, at most 0.95), or for load that is not steady;
- measure a change for you: you say how much a service's time changes;
- tell round-robin or least-request balancing from a random split (it assumes random; the predicted wait is then too
  high).
- model queueing on real software, as yet **untested**: the OpenTelemetry Demo run (about 25 services) was at 1-2% utilization, so what it checked is the
  reading of real spans, and its agreement with the callers' latencies is partly fitted, not predicted ([REAL_CLUSTER.md](docs/REAL_CLUSTER.md)).

## Quick start

You need Go 1.23 or later. From a clone of this repository:

```
$ go build -o bin/rhobound ./cmd/rhobound
$ bin/rhobound predict testdata/capture-chain --patch b=+6ms
rhobound-cli: mean latency from traces
capture   testdata/capture-chain
window    120 s, 3099 entry requests (25.8 /s), 15495 spans
busiest   c at 26% utilization
model     refined: arrival variability propagated through the graph (weight 0.7), parallel branches as correlated gammas
scope     Mean latency only, for steady load below the utilization limit, assuming Poisson arrivals. No tail (p95/p99), burst, retry or timeout modelling. Worker counts marked + are lower bounds.

  service   rps  pods x w  own ms   cs2  util  wait ms  seen wait  model ms  seen ms  err %  after ms  change ms  change %
      a *  25.8    1 x 1+    7.83  1.00   20%     1.99       0.00     45.22    43.74   +3.4     52.37      +7.15     +15.8
        b  25.8    1 x 2+   19.94  1.00   26%     1.42       1.61     35.40    35.91   -1.4     42.56      +7.15     +20.2
        c  25.8    1 x 1+    9.98  1.00   26%     3.47       3.78     13.75    14.06   -2.2     13.71      -0.04      -0.3

* entry service   || parallel fan-out   w+ = workers per pod, a lower bound (too few requests waited, or too briefly, to read it from)
own ms: service time per visit (up to its first call out), without the wait for a worker inside the span. seen wait: queueing the traces show (in-span plus between client and server span).
seen ms: the mean the callers' client spans measured (entries: the server span).

change applied: b +6 ms (+6ms);

warnings:
  - no service shows enough requests waiting for a worker inside its spans to pin its worker count (none can when spans start once a worker has taken the request), so the counts are lower bounds: a 1+ (0 waited; up to 1 in a pod at once), b 2+ (0 waited; up to 2 in a pod at once), c 1+ (0 waited; up to 1 in a pod at once)
```

`testdata/capture-chain` is a small synthetic capture in the repository: 120 s of a simulated chain where `a` calls
`b`, which calls `c`. How to read the key columns:

- `own ms`: each service's own work per request, read from the spans (the simulator used 8, 20 and 10 ms).
- `model ms` and `seen ms`: the model's mean latency and the one the traces measured; `err %` compares them.
- `after ms` and `change ms`: the latency after the change. Here +6 ms of work in `b` makes the entry `a` 7.15 ms
  slower, because `b` also queues more.
- `+` after a worker count: only a lower bound. Give the real count with `--workers b=N` if you know it.

[DEMO.md](docs/DEMO.md) explains every line and column. To install the binary instead,
`go install github.com/Sharvil2704/rhobound-cli/cmd/rhobound@latest`; [BUILD.md](docs/BUILD.md) has the details.

## The CLI at a glance

| command | what it does |
|---|---|
| `rhobound predict CAPTURE [--patch svc=+3ms,...]` | infer the call graph from traces and predict the mean latency, before and after a change |
| `rhobound infer CAPTURE` | print the inferred call graph as a topology JSON |
| `rhobound model TOPOLOGY.json --rps N` | evaluate a topology you wrote or edited, at N requests/s |
| `rhobound version` | print the version |

Common flags: `--workers svc=N`, `--kept-share F`, `--max-rho R`, `--plain`, `--json`, `--out DIR`. See
[USAGE.md](docs/USAGE.md) for every flag, exit code, refusal and warning.

## What you need to supply

- Traces from every service: SERVER spans, and CLIENT spans for outgoing calls, with W3C trace context across
  services.
- `service.name` and `k8s.pod.name` (or `service.instance.id`) on each span's resource.
- Every request, or a known head-sampling share (`--kept-share`).
- A window cut by the time its traces started (not by the time its spans ended), so that it holds no stream or long poll that began earlier.
- Clocks in step (NTP), or CLIENT spans for every call.
- One steady window of at least 100 entry requests; a few minutes at 20 or more requests/s is a good start.
- OTLP/JSON files, as the OpenTelemetry Collector's file exporter writes them, in `CAPTURE/traces/`.

Nothing else: no metrics, no logs, no access to the cluster. [REQUIREMENTS.md](docs/REQUIREMENTS.md) says why each
item matters, what is refused, and has an example Collector configuration.

## How it works

1. **Read** the trace files in parallel, keeping only ids, kinds, times and a few resource attributes.
2. **Infer the call graph**: which service calls which, how often per visit, and whether the calls run one after
   another, in parallel or in stages (a service whose calls vary by request type is a mean count or a mixture of
   shapes). Health probes are dropped, a framework's nested spans of one kind are made one, and calls sent after the response are
   kept off the caller's latency path.
3. **Rebuild each pod's queue** from the spans, first come first served, to read its worker count and its service time
   without the wait. A count is reported as a lower bound (`2+`) when too few requests waited to pin it.
4. **Model** each service as an M/G/c queue (Erlang C with the Allen-Cunneen correction). The burstiness of arrivals is
   carried through the graph (Whitt's QNA, damped by 0.7), and parallel calls take the expected maximum of correlated
   gamma-distributed branches. `--plain` switches both refinements off.
5. **Apply the change** (`+N ms` of work that holds the worker, or `+N%` of the service's own time) and solve again.
6. **Refuse** what it cannot model: a service above `--max-rho`, fewer than 100 requests, more than 5% broken traces,
   server spans that are streams, a call graph with a cycle, or call shapes it has no form for.

[ACCURACY.md section 6](docs/ACCURACY.md#6-how-a-capture-is-read) gives the rules of steps 2 and 3 in full.

## Accuracy

Measured, with failures stated first, in [ACCURACY.md](docs/ACCURACY.md):

- **Simulated, 70-80% utilization** (288 scenarios, one 400 s capture each): the entry latency is off by a median of
  **2.0%**, 5.9% at the 90th percentile and **12.5%** at worst (basic `--plain` model: 3.0 / 10.5 / 29.7%). The change
  is off by 5.6 / 16.3 / 35.5% of the change. Even given the true parameters, the model misses the change by more
  than three standard errors of the simulated truth on 46% of the rows.
- **Kubernetes (kind), run 6**: entry 46.15 ms against 46.10 ms measured; +8 ms of work in one service predicted
  +14.93 ms against +13.56 ms measured. That gap is about one standard deviation of the measurement; with run 5 it
  suggests the predicted change runs about 1 ms high on that demo.
- **Real Python services at 55-57%** (five captures): the entry latency within -0.8% to +1.4% of the traces.
- **The OpenTelemetry Demo on a real cluster** (about 25 services, 1-1.4% utilization): the tool **refused both load mixes** as first captured and was
  wrong by 20-31% (browse mix) and up to 48% (shipped mix) once they were read; both are fixed, and it now reads them, within 2.3% of what the callers measured. That agreement is partly fitted: the model
  fitted on one window is as far from another window as the windows are from each other, so do not read it as a prediction accuracy, and queueing was not
  tested ([REAL_CLUSTER.md](docs/REAL_CLUSTER.md)). The repository's own demo on the same cluster: two of three loads passed, the third (72% busy) was unstable.
- The simulated studies' truth is our own simulator, and the cluster demo's services are queues of the kind the model
  describes, so none of this is a claim about your system. [VALIDATION.md](docs/VALIDATION.md) lists every check.

## Documentation

| document | contents |
|---|---|
| [BUILD.md](docs/BUILD.md) | requirements, building, cross-compiling, installing, running the tests, CI, troubleshooting |
| [USAGE.md](docs/USAGE.md) | the command line step by step: capture, infer, predict, model, flags, exit codes, refusals, warnings |
| [REQUIREMENTS.md](docs/REQUIREMENTS.md) | what the traces must contain, how much data, load conditions, a Collector configuration |
| [DEMO.md](docs/DEMO.md) | what a result looks like: the example capture line by line, and the Kubernetes demo's result |
| [ACCURACY.md](docs/ACCURACY.md) | the full accuracy study: method, tables, where it is still wrong |
| [VALIDATION.md](docs/VALIDATION.md) | every check that has been run, failures first |
| [REAL_CLUSTER.md](docs/REAL_CLUSTER.md) | the run on a real cluster: the OpenTelemetry Demo and the repository's demo, what failed, the causes, the fixes, before and after, what is still open |
| [validation/cluster/](validation/cluster/README.md) | the scripts of the real-cluster runs (Phase A and Phase B); how to run them on your own cluster is in [REAL_CLUSTER.md](docs/REAL_CLUSTER.md#2-how-to-reproduce-it) |

Example topologies for `rhobound model` are in [examples/](examples/).

## rbfast: an optional Rust build

[rust/](rust/) holds rbfast, a parallel Rust port of the reader, the inference, the model and the report. It takes
the same `predict`, `infer` and `model` commands and flags and prints the same output: byte-identical to the Go
binary on linux/arm64 on every input compared (2,677 comparisons), and about 6-7x faster on large captures (a
579 MB capture in 0.15 s instead of 1.0 s at 8 threads; less on a single gzipped file). It adds a `sweep` command
for many what-ifs at once. The Go binary stays the reference: where the two disagree, the Go binary is right.
Other architectures than linux/arm64 were not tested. [rust/README.md](rust/README.md) has the build, the tests,
the parity runs and the benchmarks.

**Those figures are for the Go code of the first release (commit 6841f9f of this repository). rbfast has not been
updated since and does not have what the Go binary now does:** nested spans of one kind in one pod, calls per visit
that vary and visits of several call shapes, the named lost spans, the network time of a call per edge (the mean on a
quiet callee, where rbfast takes the quietest tenth per callee), the refusal of streams, the reading of callers that
stamp whole milliseconds, and the warnings and `--plain` handling that came with them. So its output differs from the
Go binary's wherever those apply: it refuses a capture with nested spans or varying counts (the OpenTelemetry Demo's),
and on any capture with a callee at most 30% busy and an edge of 50 calls or more, which is most captures, its
latencies differ (by under 0.1% on the older test-bed captures, by 2.6-3.8% on the repository's demo's cache row, by
20-31% on the Demo's browse mix once its nested spans are made one before the file is read). Use the Go binary
when it matters; byte parity holds only against the first release's code.

## License

Apache License 2.0. See [LICENSE](LICENSE) and [NOTICE](NOTICE). The Rust port in [rust/](rust/) also contains
code derived from the Go standard library under the BSD-3-Clause licence ([rust/LICENSE-GO](rust/LICENSE-GO));
see NOTICE.
