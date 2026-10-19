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
- predict the mean latency of every service, and compare it with what the traces measured;
- predict the effect of a change you specify (`--patch svc=+3ms` or `svc=-10%`) on every service above it;
- refuse, with a reason, when the data or the load is outside what it can model.

It does not:
- predict tails (p95, p99), only the mean;
- model bursts, retries, timeouts, circuit breakers, autoscaling or CPU throttling;
- work above 85% utilization of the busiest service (`--max-rho`, at most 0.95), or for load that is not steady;
- measure a change for you: you say how much a service's time changes;
- tell round-robin or least-request balancing from a random split (it assumes random; the predicted wait is then too
  high).

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
- Clocks in step (NTP), or CLIENT spans for every call.
- One steady window of at least 100 entry requests; a few minutes at 20 or more requests/s is a good start.
- OTLP/JSON files, as the OpenTelemetry Collector's file exporter writes them, in `CAPTURE/traces/`.

Nothing else: no metrics, no logs, no access to the cluster. [REQUIREMENTS.md](docs/REQUIREMENTS.md) says why each
item matters, what is refused, and has an example Collector configuration.

## How it works

1. **Read** the trace files in parallel, keeping only ids, kinds, times and a few resource attributes.
2. **Infer the call graph**: which service calls which, how often per visit, and whether the calls run one after
   another, in parallel or in stages. Health probes are dropped; calls sent after the response are kept off the
   caller's latency path.
3. **Rebuild each pod's queue** from the spans, first come first served, to read its worker count and its service time
   without the wait. A count is reported as a lower bound (`2+`) when too few requests waited to pin it.
4. **Model** each service as an M/G/c queue (Erlang C with the Allen-Cunneen correction). The burstiness of arrivals is
   carried through the graph (Whitt's QNA, damped by 0.7), and parallel calls take the expected maximum of correlated
   gamma-distributed branches. `--plain` switches both refinements off.
5. **Apply the change** (`+N ms` of work that holds the worker, or `+N%` of the service's own time) and solve again.
6. **Refuse** what it cannot model: a service above `--max-rho`, fewer than 100 requests, more than 5% broken traces,
   or call shapes it has no form for.

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

Example topologies for `rhobound model` are in [examples/](examples/).

## License

Apache License 2.0. See [LICENSE](LICENSE) and [NOTICE](NOTICE).
