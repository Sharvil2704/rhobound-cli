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

**Cut a window by the time its traces started.** A Collector's file holds everything it wrote since it started, warm-up included. Take
the traces whose first span started inside the window, whole (the repository's `otelcap cut`, in `validation/cluster/otel/`, does it), not
the spans that ended in it: a cut by span time leaves the requests that straddle its start without their first spans (broken traces),
and holds the gRPC streams and long polls that began earlier and are still open, which the tool refuses ([section 9](#9-exit-codes-and-refusals)).

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
- `hop` is the network time added to each call into the service, in ms. A service called from several callers over links
  of different speeds (a Go client and a Node.js one) has a hop per call: its calls then read
  `{"name": ..., "hop": 0.5}`, and the service's own `hop` is the mean of them by the calls observed (what the report adds
  to its latency). A call that names no hop has the service's. A file you write needs neither.
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
   visible (`a` shows 0.00 above). A line under the table, "hop from the mean", names the services whose network time is
   the mean client-minus-server time less the model's wait (a service at most 30% busy: [REQUIREMENTS.md](REQUIREMENTS.md#the-network-time-of-a-call));
   for them `seen wait` is set by the hop, and so is the hop's part of `seen ms`, so they do not check the model.
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
`change_pct`, and `hop_from_mean` (the "hop from the mean" line). Keys that do not apply are left out. After `services` come `changes`, `warnings`, `scope` and `model`,
and then `nested_spans_merged` when nested spans of one kind in one pod were read as one: a list of `service`,
`server_spans` and `client_spans`, the numbers of SERVER and CLIENT spans that were made INTERNAL, and
`server_spans_without_scope` (left out when 0), how many of the SERVER spans had no instrumentation scope to judge the pair by
([REQUIREMENTS.md](REQUIREMENTS.md#nested-spans-of-one-kind-in-one-pod)).

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
to `seen wait`, except on the callees that the "hop from the mean" line under the table names: their seen wait is set by
the network-time rule and checks nothing. In this capture `b` really has 2 workers. Telling the tool 4 is wrong, and the
report shows it, but not in the `err %` column:

```
$ bin/rhobound predict testdata/capture-chain --workers b=4
...
  service   rps  pods x w  own ms   cs2  util  wait ms  seen wait  model ms  seen ms  err %
      a *  25.8    1 x 1+    7.83  1.00   20%     1.99       0.00     45.42    43.74   +3.8
        b  25.8     1 x 4   19.94  1.00   13%     0.01       0.01     35.60    35.91   -0.9
        c  25.8    1 x 1+    9.98  1.00   26%     3.47       3.78     13.75    14.06   -2.2
...
hop from the mean: the network time of the calls into b is the mean client-minus-server span time less the model's wait (not its quietest tenth, which lies below the mean by the spread of the network time). Their seen wait, and the hop's part of their seen ms, are set by it, so they do not check it.

warnings:
...
  - a -> b: a call takes 1.91 ms on average between its client span and the server span under it, and 0.30 ms for the quietest tenth of the calls; the model's wait for b outside its spans (0.01 ms at 13% utilization) explains little of the difference. The hop is taken as that mean less the wait, 1.90 ms, so what the model does not show (calls that reach b together, a stall) is in the hop, and a change of b's time will not move it
```

`b`'s model wait drops to 0.01 ms, but its error is only -0.9%: `b` is now 13% busy, so the tool takes the network time of the
calls into `b` as the mean gap less the model's wait, and the queueing that `b` really has (1.61 ms seen) moves into that
network time. A wrong `--workers` value therefore does not show in `err %` when the callee is at most 30% busy. What shows it
is the "hop from the mean" line naming `b` and the warning under it: a call takes 1.91 ms on average and 0.30 ms for the
quietest tenth, and the model's wait explains almost none of the difference. After a `--workers` override, read those two
too. ([ACCURACY.md](ACCURACY.md#1-where-it-is-still-wrong-read-this-first), item 22, gives the limit: at or below 30% busy a wait
the model does not show lands in the hop.) The entry `a` is further from its seen time (+3.8%) because its own wait, which the
model counts and `a`'s seen time leaves out, is no longer offset by `b`'s missing one. A name that is not a service is ignored.

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

`--plain` reaches the inference too: the network time of a call is cut against the wait the model predicts outside the callee's
spans ([REQUIREMENTS.md](REQUIREMENTS.md#the-network-time-of-a-call)), and that wait is the basic model's under `--plain` (the hops
move in the sixth decimal on a quiet capture).

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
| `services[].children` | the calls of a visit, in order: a name, or `{"name": ..., "p": 0.3, "async": true, "hop": 0.5}`; `p` is the share of visits that make the call, `async` a call the service does not wait for (it loads the child but is not on the service's latency path), `hop` the network time of this call in ms when it is not the child's `hop` (`infer` writes it for a child reached over links of different speeds); a repeated name is a repeated call | none |
| `services[].parallel` | `true`: the calls run at once and the service waits for the slowest | `false` |
| `services[].branch_corr` | the correlation between parallel branches' latencies, in [-1, 1] (values of 0 or less are independent). Measured from traces by `infer`; in a file you write it is 0 unless you set it, and a fan-out's level can then read up to 17-20% high ([ACCURACY.md](ACCURACY.md#1-where-it-is-still-wrong-read-this-first), item 14) | 0 |
| `services[].servers` | with `"routing": "pooled"`: the workers of one shared queue (one pod); with `"random"`: the number of pods | 1 |
| `services[].workers` | workers per pod; more than 1 needs `"routing": "random"` | 1 |
| `services[].routing` | `"pooled"` or `"random"` (`round_robin` and `p2c` are refused) | `"pooled"` |
| `services[].shares` | with `"random"`: each pod's share of the visits (one per pod, summing to 1); absent is an even split | even |
| `services[].hop` | network time added to every call into this service, ms, unless the call names its own | 0 |
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
rhobound: 309 of 3099 traces miss spans (10.0%): 309 have a call to a service with no span of that service under it (b -> c: 309 of 3099 calls (10.0%)). The queue reconstruction needs every request and the call structure whole requests, so above 5% the result is not trustworthy -- check the exporters' queues and the sampling, and that the capture holds whole requests (not the end of one window and the start of another)
$ bin/rhobound predict noserver
rhobound: the capture holds no SERVER spans: nothing to infer
$ bin/rhobound predict badjson
rhobound: bad OTLP/JSON: unexpected end of JSON input
```

(`few`, `lost`, `noserver` and `badjson` were copies of the example capture cut down to 50 traces, with `c`'s spans
removed from every tenth trace, with only the CLIENT spans, and a truncated line.) Capture a longer window; check
the exporters' queues, the sampling and the trace context; check that the file is OTLP/JSON.

The parenthesis in the refusal for lost spans names where they were lost: the caller, the address its calls went to
(and the service that answers on it, when the address is an IP or a name of another form: `checkout ->
192.0.2.9:8080 (answered by cart)`), and how many of the calls on that edge had no span of the callee under them.
The three edges with the most lost calls are named. A hole below a top of a trace names the services and the kinds
of the spans whose parent is gone (`the spans, by service and kind: b CLIENT 819`), and a lost caller of a service
that the capture calls names the service. Look at the exporter (queue, sampling, restarts) of the service named.

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

- `X: its calls overlap in N% of its visits with two or more calls, and its visits take more than 12 call shapes, so
  that the commonest 12 leave N% of its visits that make calls out (the limit is 5%); the model has sequential, parallel and staged
  calls, or a mixture of up to 12 shapes (most common shape: ...)`: the visits of X take more different shapes than a
  mixture holds (for example a fan-out of 14 different widths, each on 1/14 of the visits). Calls per visit that vary
  (`X -> Y: calls per visit vary as {...}`), a branch called on some visits only in a parallel fan-out, and calls that
  overlap on some visits only used to be refused here; they are read now, as the mean count or as a mixture of call
  shapes, and warned about (section 10, [REQUIREMENTS.md](REQUIREMENTS.md#calls-per-visit-that-vary-and-visits-of-several-call-shapes)).
- `the inferred call graph is not usable: the call graph has a cycle; the model needs a DAG (a service calling itself: X;
  nested spans of one pod are read as one, so this is a call over the network, SERVER spans of one instrumentation scope inside
  one another (read as a call), or nested spans more than 2 ms apart)`: X calls X over the network (a request that comes back
  to the same service), which the model cannot hold; or two SERVER spans of X from one instrumentation scope sit one inside the
  other (a request the service sent to itself with a client that opens no span: they are two visits, where a framework's span
  inside the HTTP instrumentation's comes from another scope and is merged); or two spans of X that should be one are more than 2
  ms apart. Without the part in brackets the cycle is between two or more services.
- `refusing to infer: the rebuilt queues give a negative mean service time (...)`: the spans contradict a
  first-come-first-served queue. Synchronize the clocks (NTP) or export CLIENT spans, and check `--workers`.

**Server spans that are not requests.**

```
rhobound: the capture holds server spans that are streams or other calls that stay open, not request visits (a span of at least a
second, a tenth of the capture's duration and 1000 times its service's median is taken for one): flagd: 3 of its server spans last up
to 600 s (flagd.evaluation.v1.Service/EventStream, trace 8e9010d9683ad2597227a7963c2ec1e4) against a median of 0.0686 ms, and hold 100%
of its busy time. A visit is one request that holds a worker; read as visits, these would be most of the service's busy time, and its mean
time and utilization would be theirs. A stream that began before the window is still open in it, so cut the capture by the time its
traces started, not by the time its spans ended, or drop these spans (for example with a filter in the Collector), and run again
```

A gRPC server stream, a watch or a long poll is one SERVER span that lasts as long as the client stays connected. A SERVER span is taken for
one when it lasts at least a second, a tenth of the time over which the capture's server spans start, and a thousand times the median of
its service; when such spans hold 5% or more of a service's busy time the capture is refused (the numbers would be theirs), before
anything else is read. The message names the service, how many spans, the longest (its span name, when it lasted a second or more, and its
trace id), the median visit and the share of the busy time. Below 5% the spans stay in the means and a warning names them. A window cut by the
time its traces *started* does not hold a stream that began earlier; the Collector's whole file does, and so does a cut by the time spans ended.

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
  - c: 61 calls to it lost its span (2.0% of its visits): b -> c: 61 of 3099 calls (2.0%). Their traces are out of the entries and the call structure and stay in the queues and the rates. The model counts their requests (the external rate is scaled up) and gives them the calls of the others, but the service time, the queue and the worker count of c are read from the visits whose spans were captured, so they are off if the lost spans are not typical (the slow ones, or those of the busiest moments, as when an exporter's queue is full); the row is marked !. The span was dropped (an exporter's full queue, sampling, a pod that went away) or the trace context did not reach it
  - no service shows enough requests waiting for a worker inside its spans to pin its worker count (none can when spans start once a worker has taken the request), so the counts are lower bounds: a 1+ (0 waited; up to 1 in a pod at once), b 2+ (0 waited; up to 2 in a pod at once), c 1+ (0 waited; up to 1 in a pod at once)
```

Under 5% the capture is used. Over 5% it is refused (section 9). The row of `c` is marked `!` in the table (and has
`lost_visits` and `lost_share` in the JSON report) once a service lost 1% of its visits; a line under the table says
how many. The model counts the requests of the broken traces, but `c`'s service time, queue and worker count are read
from the visits that were captured.

The others, from the source:

| warning (start of the text) | what it means |
|---|---|
| `N spans were skipped (a missing id, service name, start or end time)` | those spans are not used; check the exporter |
| `X: only N visits; its estimates are rough` | fewer than 30 visits in the window: capture longer |
| `X: too few visits to rebuild its queue; its service time includes any queueing in the span` | too few spans to rebuild the queue; its time may be high |
| `X: N% of reconstructed service times are negative (clock or ordering jitter)` | small timing noise; large shares point to clock skew |
| `X: its N pods took uneven shares of its visits: ...` | the replicas did not share the load evenly (often keep-alive connections behind a Kubernetes Service); each pod is modelled with its measured share |
| `X: on N% of its visits ... the first call starts before the visit's own span ...` | clock skew between pods, or a server span that starts late; the warning says which way the reading moves |
| `X: N calls to it lost its span (P% of its visits): A -> B:port: n of m calls (q%); ...` | calls to an address that X answers on elsewhere in the capture had no span of X under them: the span was dropped, or the trace context did not reach X. The traces holding them are out of the entries and the call structure; X's service time, queue and worker count are read from the visits captured. The three edges with the most calls are named |
| `N traces hold spans whose parent is not in the capture below a top that is ...` | a hole in the middle of a trace; the spans are named by service and kind |
| `X: N traces hold a SERVER span of it whose parent is not in the capture, and services in the capture call X on P% of its visits` | a caller of X lost its span (X is not read as an entry from outside because the capture calls it too often) |
| `X: P% of its N visits are in traces that miss a span, ...` | broken traces that are mostly one kind of request: X's call structure comes from the other visits only (or from none, and X is then modelled without calls); the row is marked `!` |
| `X is entered from outside the capture and is also called by A, B: P% of its N visits have no caller's visit in the capture ...` | most of X's visits have no caller in the capture (read as requests from outside) and a share of at least 5% do. Those may be requests from a service whose spans are not in the capture, or that does not pass the trace context on; X's load is right, and a change of X's time reaches the captured callers and not those senders |
| `calls the caller does not wait for ... are modelled as async: ...` | calls sent after the response (fire and forget): they load the callee but are off the caller's latency path |
| `X -> Y: N% of the calls start after X's span has ended or outlive it ... and the rest within it; all are modelled as on its latency path` | a mix of waited and not-waited calls (5-95%); if it says the calls are timed by the callee's clock, suspect clock skew |
| `X -> Y: a call takes N ms on average between its client span and the server span under it, and M ms for the quietest tenth ...` | the hop into Y is the mean gap less the model's wait (Y is at most 30% busy), and it is more than a network's spread (above 1 ms and three times the quietest tenth): waiting the model does not show (calls that reach Y together, a stall) is in the hop, and a change of Y's time will not move it; "(and part of it may be the calls of one group, made to Y at once, queueing behind each other)" is added when Y is called several times at once by a service |
| `X -> Y: N% of visits show another call count; ignored` | a few visits made another number of calls |
| `X -> Y: calls per visit vary as {1: a, 2: b, ...}; only their mean (M per visit) enters the model, as K call(s) made on every visit and one more with probability P. That is exact for ...` | X calls Y a different number of times on different visits (a cart service that makes 1, 2 or 3 Redis calls by request type) and makes them one after another: the model takes the mean count. Y's load and X's mean time are exact; the spread of the counts is not modelled (the calls of one visit reach Y close together, the model takes them as independent arrivals; in simulations with 1 to 20 calls per visit and Y 30-60% busy the mean latency was within 2% on average, and single runs against a one-worker Y with heavy tails were off by up to 10%). A count that varies because CLIENT spans were lost or sampled out looks the same: check the exporters if it should be fixed. The long explanation is given in full on the first such line only; the later ones say "As for the callees above, ..." |
| `X -> Y: calls per visit vary as {...}; the stages below carry them (M per visit on average)` | the same, in a service whose visits fit one stage template (see below): a repeated stage that runs on some visits only carries the count |
| `X: its visits take N call shapes, modelled as a mixture (it calls each shape with the share of visits that took it): ...` | X's visits take several shapes (a front end: a cart call, two in a row, a recommendation and then four catalogue lookups at once): X calls each shape with the share of visits that took it, and a shape is a call, a group of calls at once, or stages one after another (the `shape:` and `stage:` rows of the report, zero-time delays). Up to 12 shapes; the rarer ones may hold 5% of the visits at most |
| `X: N% of its visits that make calls take rarer shapes; their calls enter as mean counts, one after another` | the shapes beyond the 12 commonest hold N% of the visits that make calls |
| `X -> Y: calls per visit vary as {...}; the call shapes carry them (M per visit on average)` | Y's varying count is carried by X's mixture of shapes |
| `X -> Y: the call shapes hold A of the M calls per visit that the visits made ...; the rest enter as mean counts, one after another` | calls that the shapes do not hold (calls that start after the visit's span has ended, and are not async because too few of them are) are added as mean-count calls, so that Y's load is the observed one |
| `X calls Y N times at once (on P% of its visits); Y has W workers and is U% busy. The model takes the N calls as independent arrivals ...` | calls made at once reach Y together and queue behind each other; the model has them as independent arrivals, so Y's wait and the latency of whoever waits for it is understated, in simulations by up to 60% of Y's latency (batches of 4: one worker about 60% at any load; 4 workers at 20-40% busy, 4% to 16%; 8 workers at 20% busy, under 0.5%). Given when the batch is larger than Y's workers (for a worker count that is only a lower bound, "at least W workers", when the batch is 3 or more), or when Y's utilization times the batch over its workers reaches 15%, for a group of at least 1% of X's visits; "a group larger than the workers waits for itself at any load" ends the warning when the batch is larger than the workers. Shapes of X that each hold a group of N calls to Y are one warning, with their shares added. Not modelled |
| `X: calls Y on some visits only, all of them or none` | a group of calls made on some visits: modelled as one conditional stage |
| `X: calls in N stages, each after the last ends: ...` | staged calls: a group at once, then the next |
| `X: N% of its visits call in another shape than its stages; modelled as the stages` | a few visits did not follow the stages |
| `nested spans of one kind in one pod ... were read as one: ...: X N SERVER (the outer span kept), Y M CLIENT (the span the callee's SERVER span is under kept, else the outermost)` | a framework opened a span of the same kind inside another one (Next.js, flagd's handler, .NET's gRPC client); the inner SERVER spans and the wrapping CLIENT spans were made INTERNAL, so that a request is one visit and a call one call; the numbers are of spans ([REQUIREMENTS.md](REQUIREMENTS.md#nested-spans-of-one-kind-in-one-pod)). When the SERVER spans carry no instrumentation scope the warning adds "Of the SERVER pairs, these name no instrumentation scope on one or both spans, so a framework's wrapper could not be told from a request the service sent to itself ...: X N"; if X does call itself that way without a CLIENT span, its visits are counted once |
| `N services emit no SERVER span, so they are not in the model ...: A (CLIENT, CONSUMER spans), B (CLIENT spans)` | a message consumer, a load generator or a batch job that only calls out has no visit that holds a worker, so it is not a service of the model and `--patch` cannot name it; the kinds of span it emits are listed |
| `X: N of its server spans last up to T (name, trace ID) against a median of M ms, and hold P% of its busy time. They are read as visits ...` | streams or other long server spans that hold under 5% of a busy service's time: they are in its mean time as the visits they are; drop them and run again if they are not requests (at 5% or more the capture is refused: section 9) |
| `N client calls to services without server spans were treated as external delays` | outside peers (a managed database, an external API): their mean time is added, with no queue |
| `N client calls made under message consumers ..., to services without server spans, are on no request's path and were left out` | a consumer's calls to outside peers |
