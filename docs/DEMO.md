# What a result looks like

Two demos. The first runs in a minute on the capture in the repository and explains every line of the report. The
second is the Kubernetes demo in `e2e/`: real pods, a real rollout, and latency measured by a load generator. Every
output below is real; [USAGE.md](USAGE.md) has more commands and flags.

## Demo 1: the example capture

### Where the capture comes from

`testdata/capture-chain` is synthetic. A queue simulator (in `internal/infer/sim_test.go`) ran this chain for 120 s
under Poisson load at 25 requests/s and wrote its spans as OTLP/JSON:

| service | calls | workers | true service time | network per call |
|---|---|---|---|---|
| `a` (the entry) | `b` | 1 | 8 ms, exponential | |
| `b` | `c` | 2 (one pod) | 20 ms, exponential | 0.3 ms |
| `c` | | 1 | 10 ms, exponential | 0.3 ms |

Its spans start once a worker has taken the request, as is usual for HTTP server instrumentation. Because the truth
is known, you can see how close the tool reads it. To make the file again:
`WRITE_FIXTURE=../../testdata/capture-chain go test -count=1 ./internal/infer -run WriteFixture`. It came out byte for byte
the same here (Go 1.27.2 on linux/arm64); another Go version or architecture may differ in the last digits.

### Step 1: what the tool sees

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

Against the truth: the call graph `a -> b -> c` is right; the service times read 7.83, 19.94 and 9.98 ms against 8,
20 and 10 (one 120 s capture is a sample, so they are a little off); `cs2` is 1 (exponential); the hop is 0.30 ms. The
worker counts 1, 2 and 1 happen to be the true ones, but the tool cannot know that: no request waited inside a span,
so each count is only the most requests seen in a pod at once, a lower bound (the warning).

### Step 2: the prediction

```
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

In one sentence: today the entry `a` takes about 45 ms on average, and if every visit of `b` did 6 ms more work it
would take about 52.4 ms, 7.15 ms more, because `b` would also queue more.

### The report, line by line

**The header.**

| line | meaning |
|---|---|
| `capture` | the path you gave |
| `window` | how long the capture is (read from the spread of the entry requests' arrivals), how many entry requests it holds and their rate, and how many spans. When it applies, it also says how many traces were broken, how many probe spans were dropped, how many entries came from message consumers, or "N entry requests in M traces" (a gateway outside the capture that calls several services in one trace). |
| `busiest` | the service with the highest utilization. It decides how close the system is to the `--max-rho` limit (85%). |
| `model` | which model: `refined` (the default) or `basic` (`--plain`) |
| `scope` | what the numbers are and are not: mean latency only, steady load, Poisson arrivals, no tails or bursts |

**The table.** One row per service, then outside peers (pure delays) at the end.

| column | meaning | in this example |
|---|---|---|
| `service` | the name. `*` marks an entry (requests from outside come in here), `\|\|` a service whose calls run in parallel, `>` an entry from a message consumer, `*>` both kinds of entry | `a` is the entry |
| `rps` | visits per second | each service gets every request once: 25.8 |
| `pods x w` | pods, times workers per pod. `+`: the worker count is a lower bound. `~` after the pods: the pods took uneven shares of the visits | `b`: one pod, at least 2 workers |
| `own ms` | the service's own time per visit: from the start of service to its first call out (or its end), without any wait for a worker | 7.83 / 19.94 / 9.98 against a true 8 / 20 / 10 |
| `cs2` | how variable `own ms` is: the squared coefficient of variation (0 constant, 1 exponential, above 1 burstier) | 1.00: exponential |
| `glue ms` | (only when some service has it) own time after the first call out, which holds no worker: writing the response, client-library time between calls | not shown: no glue here |
| `util` | utilization: the share of the time the workers are busy (`rps` times `own ms`, divided by the workers) | `a`: 25.8/s x 7.83 ms / 1 = 20% |
| `wait ms` | the model's mean wait for a worker at this service | `c` (one worker at 26%): 3.47 ms |
| `seen wait` | the queueing the traces show: inside the server span, plus the gap between the caller's CLIENT span and this server span beyond the network time | `c`: 3.78 ms. For `a` it is 0.00: an entry's wait before its span starts is not visible when spans start at service |
| `model ms` | the model's mean latency of the service as its caller sees it: wait, own time, its calls, its glue, plus the network hop into it (not for an entry) | `a`: 45.22 ms |
| `seen ms` | the same latency as the traces measured it: the mean of the callers' CLIENT spans to this service (for an entry, its SERVER span) | `a`: 43.74 ms |
| `err %` | `model ms` against `seen ms`, in percent. It checks the inputs before any change | -2.2% to +3.4% |
| `after ms` | (only with `--patch`) the model's latency after the change | `a`: 52.37 ms |
| `change ms` | (only with `--patch`) `after ms` minus `model ms` | `a`: +7.15 ms |
| `change %` | (only with `--patch`) the change as a percentage of `model ms` | `a`: +15.8% |

**Why the entry's error is +3.4%.** `a`'s `seen ms` is its SERVER span, which here starts once a worker has taken the
request. So it leaves out `a`'s own wait, which the model counts (1.99 ms). Without that wait the model would read
45.22 - 1.99 = 43.23 ms, 1.2% below the span's 43.74 ms. The services below `a` are compared through their callers'
CLIENT spans, which do include their waits, and read -1.4% and -2.2%.

**Why `c` changes by -0.04 ms.** Nothing changed at `c`, but a constant +6 ms makes `b`'s service time less variable,
so `b` sends `c` a smoother stream of requests. The refined model carries that through the graph; the basic model
(`--plain`) would show +0.00.

**The footnotes** under the table explain the markers and the `own ms`, `seen wait` and `seen ms` columns. When they
apply, extra lines explain `glue ms`, `stage:S:n` rows (calls made in stages: each stage is a row of its own with no
time), `pods~` (uneven shares), `>` (consumer entries) and the async calls (calls sent after the response, which load
the callee but are not on the caller's latency path).

**`change applied`** repeats the change as the tool understood it. A percentage is shown in ms (for example
`b +1.994 ms (+10%)`), and with glue as its service-time and glue parts.

**`warnings`** list what may be off, by service. Here there is one: the worker counts are lower bounds.
[USAGE.md](USAGE.md#10-warnings) lists the others.

### Step 3: the same report as JSON

`--json` prints the same numbers at full precision. The row of `b` and the end of the report:

```
$ bin/rhobound predict testdata/capture-chain --patch b=+3ms --json
...
    {
      "name": "b",
      "rate_rps": 25.824884296355755,
      "replicas": 1,
      "workers_per_pod": 2,
      "workers_are_a_lower_bound": true,
      "own_ms": 19.94282022329798,
      "own_cs2": 1,
      "utilization": 0.25751051240484696,
      "model_wait_ms": 1.4163629798611161,
      "observed_wait_ms": 1.6107654649885483,
      "model_ms": 35.404250924636564,
      "observed_ms": 35.91041024330429,
      "error_pct": -1.4095058097034787,
      "after_ms": 38.90698195558269,
      "change_ms": 3.502731030946123,
      "change_pct": 9.893532385142757
    },
...
  "changes": [
    {
      "service": "b",
      "delta_ms": 3,
      "spec": "+3ms"
    }
  ],
  "warnings": [
    "no service shows enough requests waiting for a worker inside its spans to pin its worker count (none can when spans start once a worker has taken the request), so the counts are lower bounds: a 1+ (0 waited; up to 1 in a pod at once), b 2+ (0 waited; up to 2 in a pod at once), c 1+ (0 waited; up to 1 in a pod at once)"
  ],
  "scope": "Mean latency only, for steady load below the utilization limit, assuming Poisson arrivals. No tail (p95/p99), burst, retry or timeout modelling. Worker counts marked + are lower bounds.",
  "model": "refined: arrival variability propagated through the graph (weight 0.7), parallel branches as correlated gammas"
}
```

(`...` marks the lines left out: the header fields and the rows of `a` and `c`.)

### Step 4: different changes

The change is yours to choose. The entry's `change ms` for a few of them, from the same capture:

| `--patch` | entry `a`: after ms | change ms | change % |
|---|---|---|---|
| `b=+3ms` | 48.72 | +3.50 | +7.7 |
| `b=+6ms` | 52.37 | +7.15 | +15.8 |
| `b=+10%` (1.994 ms) | 47.71 | +2.49 | +5.5 |
| `b=+3ms,c=-10%` | 46.98 | +1.76 | +3.9 |
| `c=+25ms` | refused: `c` would run at 90.3% | | |

The last one is refused because `c` would pass the 85% limit; [USAGE.md](USAGE.md#9-exit-codes-and-refusals) shows
the message and what to do.

## Demo 2: Kubernetes (kind)

The end-to-end test in `e2e/` checks the whole path on a real cluster: collecting spans from pods, inference, the
model, and a rollout. Its "measured" latency comes from the load generator, not from traces.

### What it deploys

| service | pods x workers | work per request | calls |
|---|---|---|---|
| `frontend` (the entry) | 1 x 4 | 3 ms | `api` and `cache`, in parallel |
| `api` | 2 x 1 | 20 ms | `db` |
| `db` | 1 x 1 | 8 ms | |
| `cache` | 1 x 2 | 5 ms | |

Each service is the small Go program in `e2e/demoapp`: it sleeps for an exponentially distributed time on at most
WORKERS requests at once (requests wait for a worker before their server span starts), calls its downstream
services, and writes one OTLP/JSON line per span to its standard output, with W3C trace context. Every call uses a
new connection, so a Kubernetes Service splits `api`'s load at random per request. The load generator
(`e2e/loadgen`) runs as a Job and sends an open-loop Poisson stream of 30 requests/s.

### What it does

1. Builds the CLI, the demo services and the load generator; creates a kind cluster (`rb-oss-e2e`) with its own
   kubeconfig; deploys the services.
2. Measures four 150 s windows in turn: before, after, before, after. Before each window every deployment is
   restarted, so each capture holds one window only. "After" means `EXTRA_MS=8` in `api`, rolled out with
   `kubectl set env`: 8 ms more work on every request.
3. For each window it collects the spans from the pods' logs. On each "before" capture it runs
   `rhobound predict CAPTURE --patch api=+8ms --json`.
4. Checks that every window was steady: the load generator's lag and worst 10-s window, each `api` pod's share of the
   calls (at most 55%), lost spans, pod restarts, memory pressure and OOM kills in the node, and that the two windows
   of each kind agree within 10%. If not, it logs why and skips instead of judging the model.
5. Judges the model: the entry latency within 10% of the measured one, and the predicted change within 15% of the
   measured change plus 1.5 ms.

### How to run it

```
RHOBOUND_E2E=1 go test -tags e2e -v -count=1 -timeout 40m ./e2e
```

It needs `docker`, `kind` and `kubectl`, takes about 13 minutes, and deletes its cluster at the end.
[BUILD.md](BUILD.md#the-kubernetes-end-to-end-test-kind) lists its settings. To try the same services without a
cluster, run the loopback smoke test (`go test -tags e2e -count=1 -run TestLoopbackSmoke -v ./e2e`, about 35 s; its output is
in BUILD.md).

### The last passing run (run 6)

It was not re-run for this page. These are the log lines of run 6, on 2026-10-19 19:05-19:17 UTC at commit 53b5068
(a commit of the unpublished development history; the published code differs from it only in comments), as kept in
[accuracy-logs/kind.txt](accuracy-logs/kind.txt):

```
    e2e_test.go:895: work folder $HOME/.cache/rb-e2e-work/<run>
    e2e_test.go:957: kubelet containerLogMaxSize 100Mi; the frontend writes about 4.9 MiB per window
    e2e_test.go:989: before1  extra 0ms: load generator 46.06 ms (4367 req, 0 err, lag 1 ms, worst 10-s x1.06); traces: entry 45.84 ms over 4512 spans, api 8zxd4 49.5% wait 9.54 ms, rm2xz 50.5% wait 9.35 ms
    e2e_test.go:989: before1  node: 0.21 cores, 760 MiB, stall cpu 0.23% mem 0.00%, oom kills 0; host stall cpu 0.36% mem 0.00%; largest log 4.5 MiB; restarts 0
    e2e_test.go:993: before1 model: entry 46.30 ms, change +14.88 ms; api wait: model 9.24 ms, traces 8.90 ms
    e2e_test.go:997: after1   extra 8ms: load generator 58.43 ms (4235 req, 0 err, lag 1 ms, worst 10-s x1.06); traces: entry 58.22 ms over 4393 spans, api 9mwtn 50.1% wait 14.63 ms, w4p6g 49.9% wait 16.13 ms
    e2e_test.go:997: after1   node: 0.21 cores, 787 MiB, stall cpu 0.23% mem 0.00%, oom kills 0; host stall cpu 0.36% mem 0.00%; largest log 4.4 MiB; restarts 0
    e2e_test.go:989: before2  extra 0ms: load generator 46.14 ms (4369 req, 0 err, lag 2 ms, worst 10-s x1.20); traces: entry 45.92 ms over 4524 spans, api b2zwg 50.9% wait 10.14 ms, qtxbv 49.1% wait 9.15 ms
    e2e_test.go:989: before2  node: 0.21 cores, 800 MiB, stall cpu 0.23% mem 0.00%, oom kills 0; host stall cpu 0.35% mem 0.00%; largest log 4.5 MiB; restarts 0
    e2e_test.go:993: before2 model: entry 46.00 ms, change +14.97 ms; api wait: model 9.35 ms, traces 9.12 ms
    e2e_test.go:997: after2   extra 8ms: load generator 60.89 ms (4315 req, 0 err, lag 1 ms, worst 10-s x1.16); traces: entry 60.67 ms over 4476 spans, api 8wwqn 49.8% wait 16.15 ms, dm27p 50.2% wait 17.43 ms
    e2e_test.go:997: after2   node: 0.23 cores, 807 MiB, stall cpu 0.23% mem 0.00%, oom kills 0; host stall cpu 0.35% mem 0.00%; largest log 4.4 MiB; restarts 0
    e2e_test.go:1037: before: measured 46.10 ms (2 windows), model 46.15 ms; change in api of +8 ms: predicted +14.93 ms, measured +13.56 ms
    e2e_test.go:906: passed: removed the captures and the image from $HOME/.cache/rb-e2e-work/<run>; result.json and the load generator outputs are kept
```

How to read the last result line:

| | model | measured by the load generator | difference |
|---|---|---|---|
| entry latency before the change | 46.15 ms | 46.10 ms | +0.1% |
| change from +8 ms of work in `api` | +14.93 ms | +13.56 ms | +1.37 ms (+10.1%) |

8 ms more work in `api` costs the user about 14 ms, not 8. `api` runs at about 30% on each of its two pods, so more
work also means more queueing there. And `api` is the slower of the frontend's two parallel calls, so nearly all of
its change reaches the user.

### Honest notes on this result

- **The measured change is noisy.** The two rounds measured +12.37 and +14.75 ms. A simulation of this demo puts one
  standard deviation of the two-round change near 1.1 ms, so the 1.4 ms gap is about one standard deviation.
- **The model's change runs about 1 ms high here.** The same simulation puts the true change near +13.8 ms. Run 5
  (the same test at an earlier commit) predicted +14.59 against +13.39 ms measured; run 6 predicted +14.93. Together
  they suggest a bias of about +1 ms on this demo. The simulation is approximate: it draws exponential service times
  and adds a fixed 1 ms for the network and HTTP overhead it leaves out.
- **Not every run passed.** Of six recorded runs, run 3 (an older test design, with keep-alive connections) failed:
  its before window read 52.15 ms against about 43 ms in the other runs of that design. The likely cause, an uneven split over the two `api` pods,
  is unproven. The test now turns keep-alive off and checks the split. All six runs are in
  [VALIDATION.md](VALIDATION.md#results).
- **The test is circular in one respect.** The demo services are queues of the kind the model describes. So it checks
  the whole path (collection from a cluster, inference, model, rollout), not the model's fit to real software. For
  that, see the test-bed captures of real Python services in [ACCURACY.md section 8](ACCURACY.md#8-real-services-at-lower-load-the-five-test-bed-captures),
  at 55-57% utilization.
