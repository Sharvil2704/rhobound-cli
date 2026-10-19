# Using rhobound, step by step

This page walks through the command line from traces to a prediction. Every command below was run from the
repository root on the example capture in `testdata/capture-chain`, and every output is the real one (long lines are
not wrapped). To build the binary first, see [BUILD.md](BUILD.md); in short: `go build -o bin/rhobound ./cmd/rhobound`.

The commands at a glance:

| command | what it does |
|---|---|
| `rhobound predict CAPTURE` | reads the traces, infers the call graph, and prints the model's mean latency per service; with `--patch`, also the latency after a change |
| `rhobound infer CAPTURE` | prints the inferred call graph as a topology JSON (no prediction) |
| `rhobound model TOPOLOGY.json --rps N` | evaluates a topology you wrote or edited, at N requests/s |
| `rhobound version` | prints the version |

`rhobound help` (or `-h`, `--help`) prints the usage text. Flags may come before or after the capture path, and both
`--flag value` and `--flag=value` work (one dash works too).

The flags, and which command reads them:

| flag | predict | infer | model | meaning |
|---|---|---|---|---|
| `--patch svc=+3ms,other=-10%` | yes | - | yes | the change to predict (section 4) |
| `--workers svc=N,...` | yes | yes | refused | workers per pod, when you know it (section 7) |
| `--kept-share F` | yes | yes | refused | the share of requests the capture holds, in (0, 1]; default 1 (section 7) |
| `--max-rho R` | yes | - | yes | refuse above this utilization, in (0, 0.95]; default 0.85 (section 7) |
| `--plain` | yes | - | yes | the basic model instead of the refined one (section 7) |
| `--json` | yes | - | yes | print the JSON report instead of the text one (section 6) |
| `--out DIR` | yes | - | yes | also write `report.txt` and `report.json` into DIR (section 6) |
| `--rps N` | - | - | required | the external request rate for a topology (section 8) |

`infer` accepts the other flags but does not use them.

## 1. Collect traces

Export OpenTelemetry traces from every service: SERVER spans, CLIENT spans for outgoing calls, W3C trace context
across services, and `service.name` plus `k8s.pod.name` (or `service.instance.id`) on the resource. Keep every
request, or note the sampling share. Capture one steady window of a few minutes. [REQUIREMENTS.md](REQUIREMENTS.md)
says what is needed and why, and has an example OpenTelemetry Collector configuration that writes the right files.

## 2. Put them in a capture folder

The tool reads OTLP/JSON: one `ExportTraceServiceRequest` per line, as the Collector's file exporter writes it, plain
or gzip-compressed. The usual layout is a folder with a `traces/` folder in it:

```
$ ls -R testdata/capture-chain
testdata/capture-chain:
traces

testdata/capture-chain/traces:
spans.jsonl.gz
```

The start of the first line (cut at 700 characters):

```
$ zcat testdata/capture-chain/traces/spans.jsonl.gz | head -c 700
{"resourceSpans":[{"resource":{"attributes":[{"key":"service.name","value":{"stringValue":"a"}},{"key":"k8s.pod.name","value":{"stringValue":"a-0"}}]},"scopeSpans":[{"spans":[{"traceId":"00000000000000000000000000000001","spanId":"0000000000000c1c","parentSpanId":"0000000000000001","kind":3,"startTimeUnixNano":"1700000000033231104","endTimeUnixNano":"1700000000080822272","attributes":[{"key":"server.address","value":{"stringValue":"b"}}]},{"traceId":"00000000000000000000000000000002","spanId":"0000000000000c1d","parentSpanId":"0000000000000002","kind":3,"startTimeUnixNano":"1700000000119402496","endTimeUnixNano":"1700000000136933376","attributes":[{"key":"server.address","value":{"stringValu
```

`CAPTURE` can also be a folder of trace files, or a single file. File names must end in `.jsonl`, `.json`,
`.jsonl.gz` or `.json.gz`; other files are ignored. Any number of files is read, in name order, on all cores.

The example capture is synthetic: 120 s of a simulated chain where `a` calls `b`, which calls `c`
([DEMO.md](DEMO.md) says how it was made).

## 3. Check the call graph with `rhobound infer`

Before predicting, check that the tool sees the services, calls and replicas you expect:

```
$ bin/rhobound infer testdata/capture-chain
{
  "name": "inferred",
  "services": [
    {
      "name": "a",
      "s": 7.831813534688614,
      "children": [
        "b"
      ],
      "servers": 1,
      "cs2": 1,
      "routing": "pooled"
    },
    {
      "name": "b",
      "s": 19.94282022329798,
      "children": [
        "c"
      ],
      "servers": 2,
      "cs2": 1,
      "routing": "pooled",
      "hop": 0.2997760000000014
    },
    {
      "name": "c",
      "s": 9.979986194256064,
      "servers": 1,
      "cs2": 1,
      "routing": "pooled",
      "hop": 0.3000319999999981
    }
  ],
  "entry": {
    "a": 1
  }
}
warning: no service shows enough requests waiting for a worker inside its spans to pin its worker count (none can when spans start once a worker has taken the request), so the counts are lower bounds: a 1+ (0 waited; up to 1 in a pod at once), b 2+ (0 waited; up to 2 in a pod at once), c 1+ (0 waited; up to 1 in a pod at once)
external load 25.82 requests/s over 120 s
```

How to read it:

- `services` lists every service that emits SERVER spans, plus outside peers (as delays). `children` are the calls
  each visit makes, in order; a child written as `{"name": ..., "p": 0.3}` is called on 30% of the visits.
- `s` is the own service time per visit in ms (until the first call out, without any wait for a worker). `cs2` is
  its squared coefficient of variation (1 for exponential).
- `servers` and `routing`: `"pooled"` is one shared queue of `servers` workers (one pod); `"random"` is `servers`
  pods with `workers` each, the load split at random between them. Here `b` is one pod with 2 workers.
- `hop` is the network time added to each call into the service, in ms.
- `entry` says where outside traffic comes in, with each entry's share.
- The JSON goes to standard output; the warnings and the `external load` line go to standard error. So you can save
  the topology (here in `bin/`, which git ignores), edit it, and evaluate it with `model` (section 8):

```
$ bin/rhobound infer testdata/capture-chain > bin/chain.json
warning: no service shows enough requests waiting for a worker inside its spans to pin its worker count (none can when spans start once a worker has taken the request), so the counts are lower bounds: a 1+ (0 waited; up to 1 in a pod at once), b 2+ (0 waited; up to 2 in a pod at once), c 1+ (0 waited; up to 1 in a pod at once)
external load 25.82 requests/s over 120 s
```

The topology does not record which worker counts are lower bounds; the warning does. Here every count is a lower
bound, because the spans of this capture start once a worker has taken the request (see
[REQUIREMENTS.md](REQUIREMENTS.md#spans-and-the-wait-for-a-worker)).

## 4. Predict with `rhobound predict`

Without a change, `predict` gives the model's mean latency per service and compares it with what the traces show:

```
$ bin/rhobound predict testdata/capture-chain
rhobound-cli: mean latency from traces
capture   testdata/capture-chain
window    120 s, 3099 entry requests (25.8 /s), 15495 spans
busiest   c at 26% utilization
model     refined: arrival variability propagated through the graph (weight 0.7), parallel branches as correlated gammas
scope     Mean latency only, for steady load below the utilization limit, assuming Poisson arrivals. No tail (p95/p99), burst, retry or timeout modelling. Worker counts marked + are lower bounds.

  service   rps  pods x w  own ms   cs2  util  wait ms  seen wait  model ms  seen ms  err %
      a *  25.8    1 x 1+    7.83  1.00   20%     1.99       0.00     45.22    43.74   +3.4
        b  25.8    1 x 2+   19.94  1.00   26%     1.42       1.61     35.40    35.91   -1.4
        c  25.8    1 x 1+    9.98  1.00   26%     3.47       3.78     13.75    14.06   -2.2

* entry service   || parallel fan-out   w+ = workers per pod, a lower bound (too few requests waited, or too briefly, to read it from)
own ms: service time per visit (up to its first call out), without the wait for a worker inside the span. seen wait: queueing the traces show (in-span plus between client and server span).
seen ms: the mean the callers' client spans measured (entries: the server span).

warnings:
  - no service shows enough requests waiting for a worker inside its spans to pin its worker count (none can when spans start once a worker has taken the request), so the counts are lower bounds: a 1+ (0 waited; up to 1 in a pod at once), b 2+ (0 waited; up to 2 in a pod at once), c 1+ (0 waited; up to 1 in a pod at once)
```

With `--patch`, it also predicts the latency after a change in one or more services' time:

```
$ bin/rhobound predict testdata/capture-chain --patch b=+3ms
rhobound-cli: mean latency from traces
capture   testdata/capture-chain
window    120 s, 3099 entry requests (25.8 /s), 15495 spans
busiest   c at 26% utilization
model     refined: arrival variability propagated through the graph (weight 0.7), parallel branches as correlated gammas
scope     Mean latency only, for steady load below the utilization limit, assuming Poisson arrivals. No tail (p95/p99), burst, retry or timeout modelling. Worker counts marked + are lower bounds.

  service   rps  pods x w  own ms   cs2  util  wait ms  seen wait  model ms  seen ms  err %  after ms  change ms  change %
      a *  25.8    1 x 1+    7.83  1.00   20%     1.99       0.00     45.22    43.74   +3.4     48.72      +3.50      +7.7
        b  25.8    1 x 2+   19.94  1.00   26%     1.42       1.61     35.40    35.91   -1.4     38.91      +3.50      +9.9
        c  25.8    1 x 1+    9.98  1.00   26%     3.47       3.78     13.75    14.06   -2.2     13.73      -0.02      -0.1

* entry service   || parallel fan-out   w+ = workers per pod, a lower bound (too few requests waited, or too briefly, to read it from)
own ms: service time per visit (up to its first call out), without the wait for a worker inside the span. seen wait: queueing the traces show (in-span plus between client and server span).
seen ms: the mean the callers' client spans measured (entries: the server span).

change applied: b +3 ms (+3ms);

warnings:
  - no service shows enough requests waiting for a worker inside its spans to pin its worker count (none can when spans start once a worker has taken the request), so the counts are lower bounds: a 1+ (0 waited; up to 1 in a pod at once), b 2+ (0 waited; up to 2 in a pod at once), c 1+ (0 waited; up to 1 in a pod at once)
```

+3 ms of work in `b` makes the entry `a` 3.50 ms slower: the 3 ms itself, plus about half a millisecond more waiting
at `b`, which is now busier (and 0.02 ms less at `c`; section 7 says why).

The forms of `--patch`:

| form | meaning |
|---|---|
| `b=+3ms` | every visit of `b` does 3 ms more work, which holds the worker. The mean moves; the variance stays. |
| `b=-2ms` | 2 ms less work per visit (refused if it would make the service time negative) |
| `b=3` | a bare number is read as ms: the same as `b=+3ms` |
| `b=+10%` | `b`'s whole own time per visit grows by 10%: the service time and the glue (time after its first call, which holds no worker) alike |
| `b=+3ms,c=-10%` | several changes at once, comma-separated |

The `change applied` line says what was applied. A percentage is shown in ms:

```
$ bin/rhobound predict testdata/capture-chain --patch b=+10%
...
change applied: b +1.994 ms (+10%);
```

```
$ bin/rhobound predict testdata/capture-chain --patch b=+3ms,c=-10%
...
  service   rps  pods x w  own ms   cs2  util  wait ms  seen wait  model ms  seen ms  err %  after ms  change ms  change %
      a *  25.8    1 x 1+    7.83  1.00   20%     1.99       0.00     45.22    43.74   +3.4     46.98      +1.76      +3.9
        b  25.8    1 x 2+   19.94  1.00   26%     1.42       1.61     35.40    35.91   -1.4     37.16      +1.76      +5.0
        c  25.8    1 x 1+    9.98  1.00   26%     3.47       3.78     13.75    14.06   -2.2     11.98      -1.76     -12.8
...
change applied: b +3 ms (+3ms); c -0.998 ms (-10%);
```

(`...` marks lines left out here; they are the same as in the full output above.)

The tool does not measure a change for you. You say how much a service's time changes, from a benchmark, a profile
or a guess, and it predicts what that does to every service above it.

## 5. Read the report

What to look at first:

1. **`busiest`**: the busiest service and its utilization. Far below `--max-rho` (85%) the queues are short and the
   prediction is easier; near 80% small errors grow ([REQUIREMENTS.md](REQUIREMENTS.md#2-how-much-data)).
2. **`err %`**: the model against the traces, before any change. A few percent is normal. A large error means the
   inputs are off (a wrong `--workers` or `--kept-share`, lost spans, unsteady load) or the system is outside what the
   model covers. Fix that before trusting a change.
3. **`wait ms` against `seen wait`**: the model's queueing against the queueing the traces show. They should be close.
   The exception is an entry whose spans start once a worker has taken the request: its wait before the span is not
   visible (`a` shows 0.00 above).
4. **`change ms`** on the entry row: the predicted change of the latency your users see.
5. **The warnings**: each one names a service and what may be off (section 10).

Markers: `*` an entry service; `||` its calls run in parallel; `+` after a worker count, a lower bound; `~` after a pod
count, pods with uneven shares; `>` an entry from a message consumer. Some columns and lines appear only when they
apply: `glue ms` when some service has work after its first call, `stage:S:n` rows for staged calls, and a line that
lists async calls.

[DEMO.md](DEMO.md#the-report-line-by-line) explains every header line and every column with these numbers.

## 6. JSON output and report files

`--json` prints the same report as JSON (the format is `rhobound-cli.report/v1`). The start of it (`...` marks the
rest):

```
$ bin/rhobound predict testdata/capture-chain --patch b=+3ms --json
{
  "version": "rhobound-cli.report/v1",
  "capture": "testdata/capture-chain",
  "window_s": 120.00053763792899,
  "requests": 3099,
  "spans": 15495,
  "traces": 3099,
  "broken_traces": 0,
  "external_rps": 25.824884296355755,
  "kept_share": 1,
  "max_utilization": 0.25773198874589065,
  "busiest_service": "c",
  "services": [
    {
      "name": "a",
      "entry": true,
      "rate_rps": 25.824884296355755,
      "replicas": 1,
      "workers_per_pod": 1,
      "workers_are_a_lower_bound": true,
      "own_ms": 7.831813534688614,
      "own_cs2": 1,
      "utilization": 0.20225567836396643,
      "model_wait_ms": 1.985634640469737,
      "observed_wait_ms": 0,
      "model_ms": 45.22169909979492,
      "observed_ms": 43.742223777992905,
      "error_pct": 3.382259048627405,
      "after_ms": 48.72443013074104,
      "change_ms": 3.502731030946123,
      "change_pct": 7.745686475017936
    },
...
```

The JSON keys match the text columns: `rate_rps` (rps), `replicas` and `workers_per_pod` (pods x w),
`workers_are_a_lower_bound` (the `+`), `own_ms`, `own_cs2`, `glue_ms`, `utilization`, `model_wait_ms` (wait ms),
`observed_wait_ms` (seen wait), `model_ms`, `observed_ms` (seen ms), `error_pct`, `after_ms`, `change_ms`,
`change_pct`. Keys that do not apply are left out. After `services` come `changes`, `warnings`, `scope` and `model`.

`--out DIR` writes both forms into a folder (it is created if needed) and still prints the text report. The note
about the files goes to standard error:

```
$ bin/rhobound predict testdata/capture-chain --out bin/report-b3 --patch b=+3ms
wrote bin/report-b3/report.txt and report.json
rhobound-cli: mean latency from traces
...
$ ls bin/report-b3
report.json
report.txt
```

With `--json --out DIR` the files are written the same way and the JSON is printed.

## 7. The other flags

### `--workers svc=N`: when you know the pool size

A worker count shown with `+` is only a lower bound, and the model uses that bound. If you know the real number of
workers per pod (threads, processes, connections), give it. Check the result: the model's `wait ms` should stay close
to `seen wait`. In this capture `b` really has 2 workers. Telling the tool 4 is wrong, and the report shows it:

```
$ bin/rhobound predict testdata/capture-chain --workers b=4
...
  service   rps  pods x w  own ms   cs2  util  wait ms  seen wait  model ms  seen ms  err %
      a *  25.8    1 x 1+    7.83  1.00   20%     1.99       0.00     43.82    43.74   +0.2
        b  25.8     1 x 4   19.94  1.00   13%     0.01       1.61     34.00    35.91   -5.3
        c  25.8    1 x 1+    9.98  1.00   26%     3.47       3.78     13.75    14.06   -2.2
```

`b`'s wait drops to 0.01 ms against 1.61 seen, and its error grows to -5.3%. (The entry `a` gets closer only because
two errors cancel: `b`'s missing wait, and `a`'s own wait, which the model counts and `a`'s seen time leaves out.) A
name that is not a service is ignored.

### `--kept-share F`: when the traces are sampled

If you head-sampled the traces, say at 50%, pass `--kept-share 0.5`, and every rate is divided by it. Sampling is not
detected. Passing a wrong share is like claiming twice the load; the `err %` column shows it:

```
$ bin/rhobound predict testdata/capture-chain --kept-share 0.5
rhobound-cli: mean latency from traces
capture   testdata/capture-chain
window    120 s, 3099 entry requests (51.6 /s), 15495 spans
busiest   c at 52% utilization
...
  service   rps  pods x w  own ms   cs2  util  wait ms  seen wait  model ms  seen ms  err %
      a *  51.6    1 x 1+    7.83  1.00   40%     5.32       0.00     61.49    43.74  +40.6
        b  51.6    1 x 2+   19.94  1.00   52%     7.20       1.61     48.34    35.91  +34.6
        c  51.6    1 x 1+    9.98  1.00   52%    10.62       3.78     20.90    14.06  +48.7
```

This capture holds every request, so the right value is the default, 1.

### `--max-rho R`: the utilization limit

The model covers steady load below a limit: 0.85 by default, at most 0.95. A capture whose busiest service is above
it is refused, and so is a change that would take any service above it. A lower limit makes the tool stricter:

```
$ bin/rhobound predict testdata/capture-chain --max-rho 0.2
rhobound: refusing to predict: at the observed load a would run at 20.2% utilization, b would run at 25.8% utilization, c would run at 25.8% utilization, above the limit of 20.0% (--max-rho; the model covers steady load below it only). The worker count of a (1 x 1+), b (1 x 2+), c (1 x 1+) is only a lower bound: too few of its requests waited for a worker, or too briefly, to tell its pool from a larger one or from one with no limit, so that utilization is an upper bound. If the pool is larger, or has no limit, set its size with --workers (for example --workers a=N with N its workers per pod)
```

### `--plain`: the basic model

By default the model is **refined**: it carries the burstiness of the arrivals through the call graph, and it takes
parallel branches as correlated gamma laws. `--plain` switches both off (Poisson arrivals at every queue, exponential
branches). It is there for comparison; the refined model was more accurate at 70-80% utilization
([ACCURACY.md](ACCURACY.md#0-summary)).

```
$ bin/rhobound predict testdata/capture-chain --patch b=+3ms --plain
...
model     basic: Poisson arrivals at every queue, exponential parallel branches
...
  service   rps  pods x w  own ms   cs2  util  wait ms  seen wait  model ms  seen ms  err %  after ms  change ms  change %
      a *  25.8    1 x 1+    7.83  1.00   20%     1.99       0.00     45.22    43.74   +3.4     48.74      +3.52      +7.8
        b  25.8    1 x 2+   19.94  1.00   26%     1.42       1.61     35.40    35.91   -1.4     38.93      +3.52      +9.9
        c  25.8    1 x 1+    9.98  1.00   26%     3.47       3.78     13.75    14.06   -2.2     13.75      +0.00      +0.0
```

In this capture every service time is exponential (cs2 1.00) and there is no fan-out, so the two models agree before
the change. After it they differ a little: a constant +3 ms makes `b`'s service time less variable, the refined model
passes `b`'s smoother output on to `c` (-0.02 ms there), and the entry moves by +3.50 ms instead of +3.52 ms.

### `RHOBOUND_ESTIMATOR=rise`: the earlier estimator

An environment variable selects the earlier way of reading service times and worker counts (from the visits that
found a free worker), instead of the default queue rebuild (`fifo`). It is kept for comparison only
([ACCURACY.md](ACCURACY.md#45-spans-that-include-the-wait-the-earlier-estimator-against-the-queue-rebuild-rows-0-35-pooled)
shows it is noisier). Any other value is refused:

```
$ RHOBOUND_ESTIMATOR=x bin/rhobound predict testdata/capture-chain
rhobound: unknown estimator "x" (want "fifo" or "rise")
```

## 8. Evaluate a topology you wrote with `rhobound model`

`model` takes a topology file instead of traces: the form `infer` writes, by hand or edited. Use it to ask "what if"
questions the traces cannot answer: another load, another worker count, a service you have not deployed yet.

[`examples/chain-topology.json`](../examples/chain-topology.json) is the chain behind the example capture, with the
simulator's own values (8, 20 and 10 ms; `b` has 2 workers):

```json
{
  "name": "chain",
  "services": [
    {"name": "a", "s": 8, "children": ["b"], "servers": 1, "cs2": 1},
    {"name": "b", "s": 20, "children": ["c"], "servers": 2, "cs2": 1, "hop": 0.3},
    {"name": "c", "s": 10, "servers": 1, "cs2": 1, "hop": 0.3}
  ],
  "entry": {"a": 1}
}
```

```
$ bin/rhobound model examples/chain-topology.json --rps 25
rhobound-cli: mean latency of a topology
topology  examples/chain-topology.json
load      25.0 requests/s
busiest   b at 25% utilization
model     refined: arrival variability propagated through the graph (weight 0.7), parallel branches as correlated gammas
scope     Mean latency only, for steady load below the utilization limit, assuming Poisson arrivals. No tail (p95/p99), burst, retry or timeout modelling. Worker counts marked + are lower bounds.

  service   rps  pods x w  own ms   cs2  util  wait ms  seen wait  model ms  seen ms  err %
      a *  25.0     1 x 1    8.00  1.00   20%     2.00          -     45.27        -      -
        b  25.0     1 x 2   20.00  1.00   25%     1.33          -     35.27        -      -
        c  25.0     1 x 1   10.00  1.00   25%     3.33          -     13.63        -      -

* entry service   || parallel fan-out   w+ = workers per pod, a lower bound (too few requests waited, or too briefly, to read it from)
own ms: service time per visit (up to its first call out). seen wait, seen ms: a topology has no traces to compare with.
```

There are no traces, so the `seen` columns are `-`. `--patch`, `--max-rho`, `--plain`, `--json` and `--out` work as
for `predict`. The same file at a higher load:

```
$ bin/rhobound model examples/chain-topology.json --rps 60
...
  service   rps  pods x w  own ms   cs2  util  wait ms  seen wait  model ms  seen ms  err %
      a *  60.0     1 x 1    8.00  1.00   48%     7.38          -     72.23        -      -
        b  60.0     1 x 2   20.00  1.00   60%    11.25          -     56.85        -      -
        c  60.0     1 x 1   10.00  1.00   60%    15.00          -     25.30        -      -
```

and at a load the model does not cover:

```
$ bin/rhobound model examples/chain-topology.json --rps 90
rhobound: refusing to evaluate: at 90 requests/s b would run at 90.0% utilization, c would run at 90.0% utilization, above the limit of 85.0% (--max-rho; the model covers steady load below it only)
```

The inferred topology from section 3 gives `predict`'s numbers back (to the rounding of `--rps`):

```
$ bin/rhobound model bin/chain.json --rps 25.82
...
  service   rps  pods x w  own ms   cs2  util  wait ms  seen wait  model ms  seen ms  err %
      a *  25.8     1 x 1    7.83  1.00   20%     1.99          -     45.22        -      -
        b  25.8     1 x 2   19.94  1.00   26%     1.42          -     35.40        -      -
        c  25.8     1 x 1    9.98  1.00   26%     3.46          -     13.74        -      -
```

[`examples/fanout-topology.json`](../examples/fanout-topology.json) has the shape and the true service times of the
Kubernetes demo (frontend calls api and cache in parallel; api has 2 pods and calls db), with a guessed 0.5 ms network
hop. It is not fitted to any capture:

```
$ bin/rhobound model examples/fanout-topology.json --rps 30
...
        service   rps  pods x w  own ms   cs2  util  wait ms  seen wait  model ms  seen ms  err %
  frontend * ||  30.0     1 x 4    3.00  1.00    2%     0.00          -     43.37        -      -
            api  30.0     2 x 1   20.00  1.00   30%     8.57          -     40.10        -      -
             db  30.0     1 x 1    8.00  1.00   24%     2.53          -     11.03        -      -
          cache  30.0     1 x 2    5.00  1.00    8%     0.03          -      5.53        -      -
```

### The topology file

| field | meaning | default |
|---|---|---|
| `name` | a label | |
| `services` | the list of services | |
| `entry` | `{"service": weight}`: where outside traffic enters; the weights are each entry's share | required |
| `services[].name` | the service's name; `children` and `entry` refer to it | |
| `services[].s` | mean own service time per visit, ms (until the first call out) | 0 |
| `services[].cs2` | squared coefficient of variation of `s` (1 = exponential, 0 = constant) | 1 |
| `services[].children` | the calls of a visit, in order: a name, or `{"name": ..., "p": 0.3, "async": true}`; `p` is the share of visits that make the call, `async` a call the service does not wait for (it loads the child but is not on the service's latency path); a repeated name is a repeated call | none |
| `services[].parallel` | `true`: the calls run at once and the service waits for the slowest | `false` |
| `services[].branch_corr` | the correlation between parallel branches' latencies, in [-1, 1] (values of 0 or less are independent). Measured from traces by `infer`; in a file you write it is 0 unless you set it, and a fan-out's level can then read up to 17-20% high ([ACCURACY.md](ACCURACY.md#1-where-it-is-still-wrong-read-this-first), item 14) | 0 |
| `services[].servers` | with `"routing": "pooled"`: the workers of one shared queue (one pod); with `"random"`: the number of pods | 1 |
| `services[].workers` | workers per pod; more than 1 needs `"routing": "random"` | 1 |
| `services[].routing` | `"pooled"` or `"random"` (`round_robin` and `p2c` are refused) | `"pooled"` |
| `services[].shares` | with `"random"`: each pod's share of the visits (one per pod, summing to 1); absent is an even split | even |
| `services[].hop` | network time added to every call into this service, ms | 0 |
| `services[].glue`, `glue_cs2` | own time per visit after the first call out, which holds no worker, ms, and its cs2 | 0 |
| `services[].delay` | `true`: a pure delay (no queue), such as an outside API | `false` |

The file is checked when it is read. A few of the messages:

```
$ bin/rhobound model rr.json --rps 25
rhobound: b: routing "round_robin" is not supported (pooled and random are)
$ bin/rhobound model cycle.json --rps 25
rhobound: the call graph has a cycle; the model needs a DAG
$ bin/rhobound model examples/chain-topology.json --rps 25 --workers b=4
rhobound: model does not take --workers (they apply to a capture: predict and infer)
$ bin/rhobound model examples/chain-topology.json
rhobound: usage: rhobound model TOPOLOGY.json --rps N [--patch svc=+3ms] [--max-rho 0.85] [--out DIR] [--json]
```

(`rr.json` and `cycle.json` were copies of the chain file with `"routing": "round_robin"` on `b`, and with `c`
calling `a`.)

## 9. Exit codes and refusals

| exit code | meaning |
|---|---|
| 0 | success: the report was printed (warnings do not change the exit code) |
| 1 | an error or a refusal: one line on standard error, starting with `rhobound:` |
| 2 | no command, or an unknown command: the usage text on standard error |

A refusal means the tool will not give a number it cannot stand behind. Each message says why. The common ones, as
the tool prints them, and what to do:

**A service is too busy.**

```
$ bin/rhobound predict testdata/capture-chain --patch c=+25ms
rhobound: refusing the change: after it c would run at 90.3% utilization, above the limit of 85.0% (--max-rho; the model covers steady load below it only). The worker count of c (1 x 1+) is only a lower bound: too few of its requests waited for a worker, or too briefly, to tell its pool from a larger one or from one with no limit, so that utilization is an upper bound. If the pool is larger, or has no limit, set its size with --workers (for example --workers c=N with N its workers per pod)
$ bin/rhobound predict testdata/capture-chain --patch c=+40ms
rhobound: refusing the change: after it c would pass 100% utilization (129.1%: no steady state, the model is unstable), above the limit of 85.0% (--max-rho; the model covers steady load below it only). The worker count of c (1 x 1+) is only a lower bound: too few of its requests waited for a worker, or too briefly, to tell its pool from a larger one or from one with no limit, so that utilization is an upper bound. If the pool is larger, or has no limit, set its size with --workers (for example --workers c=N with N its workers per pod)
```

The change would overload `c`. If `c` really has more workers than the traces could show, give the count with
`--workers c=N` and the change is predicted. If it does not, the answer is that `c` would be saturated: the model
cannot say by how much. The same message with "refusing to predict: at the observed load" means the capture itself
is too busy; with `model` it says "refusing to evaluate: at N requests/s".

**Not enough data, or broken data.**

```
$ bin/rhobound predict few
rhobound: only 50 entry requests in the capture; need at least 100
$ bin/rhobound predict lost
rhobound: 309 of 3099 traces miss spans (10.0%): 309 have a call to a service with no span of that service under it. The queue reconstruction needs every request and the call structure whole requests, so above 5% the result is not trustworthy -- check the exporters' queues and the sampling, and that the capture holds whole requests (not the end of one window and the start of another)
$ bin/rhobound predict noserver
rhobound: the capture holds no SERVER spans: nothing to infer
$ bin/rhobound predict badjson
rhobound: bad OTLP/JSON: unexpected end of JSON input
```

(`few`, `lost`, `noserver` and `badjson` were copies of the example capture cut down to 50 traces, with `c`'s spans
removed from every tenth trace, with only the CLIENT spans, and a truncated line.) Capture a longer window; check
the exporters' queues, the sampling and the trace context; check that the file is OTLP/JSON.

**The wrong path.**

```
$ bin/rhobound predict missing-folder
rhobound: stat missing-folder: no such file or directory
$ bin/rhobound predict examples
rhobound: the capture holds no usable spans
$ bin/rhobound predict testdata
rhobound: no trace files (*.jsonl, *.json, *.gz) under testdata
```

**A call shape the model does not have.** These come from the inference; their text, from the source code:

- `X -> Y: calls per visit vary as {...}; the model has a fixed count or one conditional call per visit, not this`
- `X: its calls overlap in N% of its visits with two or more calls (most common shape: ...); neither all at once, one
  after another nor in stages, the shapes the model has`
- `X: calls in parallel, and calls to Y only on some visits; the model's expected maximum needs every branch on every
  visit`
- `refusing to infer: the rebuilt queues give a negative mean service time (...)`: the spans contradict a
  first-come-first-served queue. Synchronize the clocks (NTP) or export CLIENT spans, and check `--workers`.

**A flag out of range.**

```
$ bin/rhobound predict testdata/capture-chain --max-rho 0.99
rhobound: --max-rho must be in (0, 0.95]
$ bin/rhobound predict testdata/capture-chain --kept-share 0
rhobound: --kept-share must be in (0, 1], got 0
$ bin/rhobound predict testdata/capture-chain --workers b=0
rhobound: --workers: "b=0" is not svc=N with N >= 1
$ bin/rhobound predict testdata/capture-chain --patch x=+3ms
rhobound: --patch: unknown service in "x=+3ms" (services: a, b, c)
$ bin/rhobound predict testdata/capture-chain --patch b=fast
rhobound: --patch: cannot read "b=fast" (use +3ms or -10%)
$ bin/rhobound predict testdata/capture-chain --patch b=-30ms
rhobound: --patch: b would get a negative service time
$ bin/rhobound predict testdata/capture-chain --bogus
rhobound: usage: rhobound predict CAPTURE [--patch svc=+3ms] [--workers svc=N] [--out DIR] [--json]
```

## 10. Warnings

Warnings do not stop the report. They are printed at its end (and on standard error by `infer`). Each names a service
and what may be off. The two below come from real runs; the others are quoted from the source code, with `X` and `Y`
for service names and `N` for numbers.

**Worker counts are lower bounds** (seen on every run above):

```
  - no service shows enough requests waiting for a worker inside its spans to pin its worker count (none can when spans start once a worker has taken the request), so the counts are lower bounds: a 1+ (0 waited; up to 1 in a pod at once), b 2+ (0 waited; up to 2 in a pod at once), c 1+ (0 waited; up to 1 in a pod at once)
```

The spans start once a worker has taken the request, so no request is seen waiting inside a span. Each count is the
most requests seen in a pod at once: a floor. If you know a pool is bigger, use `--workers`. A variant says "too few
requests waited for a worker, or too briefly" when some waits are visible but too short to pin a count (a pool with
no limit looks like that).

**Some traces lost a span** (a copy of the example capture with `c`'s spans removed from every 50th trace):

```
$ bin/rhobound predict lost2
rhobound-cli: mean latency from traces
capture   lost2
window    120 s, 3038 entry requests (25.8 /s), 15434 spans, 61 of 3099 traces broken
...
warnings:
  - 61 of 3099 traces miss a span (1.97%): left out of the entries and the call structure, kept in the queues and the rates (the external rate is scaled up by 1.0201 to count them)
  - no service shows enough requests waiting for a worker inside its spans to pin its worker count (none can when spans start once a worker has taken the request), so the counts are lower bounds: a 1+ (0 waited; up to 1 in a pod at once), b 2+ (0 waited; up to 2 in a pod at once), c 1+ (0 waited; up to 1 in a pod at once)
```

Under 5% the capture is used. Over 5% it is refused (section 9).

The others, from the source:

| warning (start of the text) | what it means |
|---|---|
| `N spans were skipped (a missing id, service name, start or end time)` | those spans are not used; check the exporter |
| `X: only N visits; its estimates are rough` | fewer than 30 visits in the window: capture longer |
| `X: too few visits to rebuild its queue; its service time includes any queueing in the span` | too few spans to rebuild the queue; its time may be high |
| `X: N% of reconstructed service times are negative (clock or ordering jitter)` | small timing noise; large shares point to clock skew |
| `X: its N pods took uneven shares of its visits: ...` | the replicas did not share the load evenly (often keep-alive connections behind a Kubernetes Service); each pod is modelled with its measured share |
| `X: on N% of its visits ... the first call starts before the visit's own span ...` | clock skew between pods, or a server span that starts late; the warning says which way the reading moves |
| `calls the caller does not wait for ... are modelled as async: ...` | calls sent after the response (fire and forget): they load the callee but are off the caller's latency path |
| `X -> Y: N% of the calls start after X's span has ended or outlive it ... and the rest within it; all are modelled as on its latency path` | a mix of waited and not-waited calls (5-95%); if it says the calls are timed by the callee's clock, suspect clock skew |
| `X -> Y: N% of visits show another call count; ignored` | a few visits made another number of calls |
| `X: calls Y on some visits only, all of them or none` | a group of calls made on some visits: modelled as one conditional stage |
| `X: calls in N stages, each after the last ends: ...` | staged calls: a group at once, then the next |
| `X: N% of its visits call in another shape than its stages; modelled as the stages` | a few visits did not follow the stages |
| `N client calls to services without server spans were treated as external delays` | outside peers (a managed database, an external API): their mean time is added, with no queue |
| `N client calls made under message consumers ..., to services without server spans, are on no request's path and were left out` | a consumer's calls to outside peers |
