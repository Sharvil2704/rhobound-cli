# The real cluster run: the OpenTelemetry Demo and the repository's demo

On 2026-10-21 the tool was run, for the first time, on software that nobody had shaped for it: the OpenTelemetry Demo 2.2.0
(about 25 services in a dozen languages) on a real five-machine cluster, next to the repository's own demo services
(the Kubernetes test of [DEMO.md](DEMO.md)) on the same cluster. This page says what was run and how to repeat it, what the tool did, what was
wrong, what was changed and what the result is now. Failures come first, and the limits at the end are part of the result.

**In one paragraph.** On the repository's own demo the tool passed at two of three loads (a third was judged unstable) and
needed no change. On the OpenTelemetry Demo it **refused both load mixes as captured**: for a wrapper span of the .NET gRPC
client that looked like a lost span, for Next.js spans that looked like a service calling itself, and then for call counts that
vary by request type. Once those were read, its latencies were 20-31% (browse mix) and up to 48% (shipped mix) below what the
callers measured, because of one constant in the network-time estimate. All of that is fixed now (section 5), and so are the
problems the review of the fixes found: a capture holding gRPC streams was read as nonsense, and one family of call counts made the
tool run for hours. What is not shown is queueing on real software: the Demo ran at 1-2% utilization.

## 1. What was run

- **The cluster.** k3s on AWS: five machines in one private network, one control-plane machine and one load machine of 2 vCPUs,
  three application machines of 4 vCPUs (16 vCPUs in all), all x86-64. The load machine was tainted so that only load generators
  ran there. The cluster was built for the run, by the person who ran it, with a script of their own (it is not in this repository),
  and torn down after four hours. The scripts of this repository ran on a sixth machine outside the cluster, which reached the
  cluster's API with `kubectl` and the machines with `ssh`. [Section 2](#2-how-to-reproduce-it) gives the same layout for any cluster.
- **Phase A: the repository's cluster test** ([DEMO.md](DEMO.md), Demo 2) on this cluster: frontend, api (2 pods of 1 worker), db and cache
  with configured service times, three loads, two rounds each; each round measures the load generator's mean latency before and after a
  change of `api`'s service time, and the tool is given the *before* capture and the change. The truth is the load generator's own measurement.
  It measures what the earlier, single-node runs could not: calls that cross machines, and the model's level and its predicted change at 35%, 58%
  and 72% busy.
- **Phase B: the OpenTelemetry Demo 2.2.0** (its Kubernetes manifest runs the Demo's 2.1.3 service images), 100 Locust users, two load mixes: `shipped` (the load generator's nine tasks) and `browse` (the
  product-page task only). Each mix: a warm-up, then a 420 s window; the Collector wrote OTLP/JSON with its file exporter (no dropped lines,
  no restarts, no memory-limiter or exporter errors in the window), the traces that started in the window were cut out
  (`otelcap cut`, in `validation/cluster/otel/`: whole traces, so a request that straddles the start is not broken), and `rhobound infer` and
  `predict` ran on them. The load: 23.8 requests/s at the entry (shipped) and 18.2 (browse); the busiest service was **1.0% and 1.4% busy**.
  It measures whether the tool can read the traces of software nobody shaped for it: structure, rates, call counts and the time of each call.
- No change was made to a Demo service, so Phase B measures level and structure only.

## 2. How to reproduce it

Any k3s or Kubernetes cluster with at least two application nodes and one load node will do. The run above used three application
nodes of 4 vCPUs and one load node of 2 vCPUs; the memory limits of the Demo's workloads add up to 7,284 MiB on the application
nodes and 1,500 MiB on the load node (`RBV_RESULTS=$PWD/results/run1 bash validation/cluster/otel/run.sh plan` prints the list). The machine that runs the scripts needs
Go (1.23 or later), `kubectl`, `jq`, `awk`, `curl` and `sha256sum`, the cluster's kubeconfig as one file, and, for Phase B, access to
GitHub (it downloads the Demo's manifest and checks its sha256). The nodes pull the Demo's images from ghcr.io, docker.io and quay.io;
when they all leave through one public address (a NAT), Docker Hub's anonymous pull limit counts them as one client, and a `docker.io`
mirror in each node's `/etc/rancher/k3s/registries.yaml` avoids it (the header of `validation/cluster/otel/run.sh` says more).

**1. Name the nodes.** Phase A finds the nodes by two labels, and the load node must carry the taint with the same key. Phase B
uses only the load label (for the load generator). `NODE1` to `NODE3` and `LOADNODE` are your node names (`kubectl get nodes`):

```
kubectl label node NODE1 NODE2 NODE3 rbv/role=app
kubectl label node LOADNODE rbv/role=load
kubectl taint node LOADNODE rbv/role=load:NoSchedule
```

Other labels work: set `RBV_APP_SELECTOR` (Phase A only) and `RBV_LOAD_SELECTOR` to your `key=value` (the taint must be
`key=value:NoSchedule`).

Phase B puts only its load generator on the load node. The rest of the Demo goes wherever the scheduler puts it, on any node
that is not tainted, so on k3s it can land on the control-plane machine. If you do not want that, cordon that node
(`kubectl cordon CONTROLPLANE`) before Phase B.

**2. Let the kubelets keep a long container log.** Phase A reads the demo's spans from the container logs, and the kubelet's default
(10 Mi) rotates them inside a window. The script refuses to start when the limit is too small. On k3s, on every application node and on
the load node (agents; on a server the service is `k3s`, not `k3s-agent`):

```
printf 'kubelet-arg:\n  - "container-log-max-size=100Mi"\n' | sudo tee -a /etc/rancher/k3s/config.yaml
sudo systemctl restart k3s-agent
```

(If the file has a `kubelet-arg` key already, add the line to it.) Phase B does not need this.

**3. Put the demo image on the nodes.** Phase A runs the repository's own demo services and load generator from one image,
`rhobound-demo:e2e`, which `go run ./e2e/imagetar` writes as a docker-archive tar for any architecture, without docker. Load it on every
application node and on the load node (`-arch arm64` for Arm machines):

```
go run ./e2e/imagetar -arch amd64 -o rhobound-demo-amd64.tar
scp rhobound-demo-amd64.tar NODE:                      # for each application node and the load node
ssh NODE sudo k3s ctr images import rhobound-demo-amd64.tar
```

(On a cluster that is not k3s, import the tar into the node's containerd namespace `k8s.io` with `ctr -n k8s.io images import`.)

**4. Phase A**, the repository's cluster test at three loads (about 45 minutes; the dry run prints the loads it chose and does not touch the cluster):

```
export KUBECONFIG=/path/to/kubeconfig       # one file
export RBV_RESULTS=$PWD/results/run1        # the run's folder
RBV_DRYRUN=1 bash validation/cluster/phase-a.sh
bash validation/cluster/phase-a.sh
```

It writes `$RBV_RESULTS/phase-a/summary.md` (one row per level: measured and modelled latency, measured and predicted change, a verdict of PASS,
FAIL, UNSTABLE or ERROR), `summary.json`, and a folder `L1`, `L2`, `L3` with the test's log, `result.json` and the load generator's outputs.
`RBV_LEVELS="1"` runs one level only; `RHOBOUND_E2E_ROUNDS=3` adds rounds. The header of `phase-a.sh` lists every setting.

**5. Phase B**, the OpenTelemetry Demo with its own load, captured and given to the CLI (about 25 minutes of load, plus the deploy, which
is up to 15 minutes, mostly image pulls):

```
RBV_RESULTS=$PWD/results/run1 bash validation/cluster/otel/run.sh plan     # fetch and render the manifest, print what runs where: no cluster needed
KUBECONFIG=/path/to/kubeconfig RBV_RESULTS=$PWD/results/run1 bash validation/cluster/otel/run.sh   # deploy, capture both mixes, analyze, then remove the demo
```

`RBV_KEEP_NS=1` keeps the demo running afterwards. The subcommands `deploy`, `capture`, `analyze` and `down` run the steps one at a time, and
`analyze` needs no cluster: it cuts each window out of the copied Collector file and runs `rhobound infer` and `rhobound predict` on it. It writes
`$RBV_RESULTS/phase-b/summary.md` and `summary.json`: for each mix the window, the CLI's exit status, its refusal or its table, and the services'
model latencies against what their callers measured. Useful settings: `RBV_OTEL_MIXES` (default `shipped browse`), `RBV_OTEL_USERS` (100),
`RBV_OTEL_WINDOW_S` (420), `RBV_OTEL_MANIFEST` (a local copy of the release's manifest, still checked against the pinned sha256), and `RBV_SSH`
(an ssh command that reaches the nodes as `w1` to `wN` and `load`, for `prepull`, which pulls the images ahead of the deploy). The header of
`otel/run.sh` lists the rest, and says what was changed in the Demo's manifest: the Collector gets a file exporter, the load generator
runs on the load node with 100 users and no browser users, and two memory limits are raised.

Both phases write under `RBV_RESULTS` (here `results/` in the clone, which `.gitignore` leaves out). Expect numbers of the kind in sections 3 to 6,
not the same digits: the load generator is random, and your machines are not these. The checks that do not depend on the cluster are the tests:
`go test ./...` runs the real captures of section 8 through the same code.

## 3. Phase A: the repository's demo on the real cluster

| level | load | change in `api` | model against measured (before) | change predicted against measured | verdict |
|---|---|---|---|---|---|
| 1 | 35 requests/s (`api` 35% busy) | +8 ms | 49.95 against 49.8 ms (+0.3%) | +17.45 against +19.31 ± 2.98 ms | pass |
| 2 | 58 requests/s (58% busy) | +4 ms | 72.86 against 73.51 ms (-0.9%) | +23.95 against +23.88 ± 6.5 ms | pass |
| 3 | 72 requests/s (72% busy) | +2 ms | 105.55 against 105.54 ms (0.0%) | +31.35 against +18.43 ± 10.85 ms | **unstable**: not judged |

The ± is two standard errors of the measurement. The numbers are the ones the tool gave on the day; the tool's output on the 12 captures is
unchanged by everything below, except one row: the cache's latency was 2.5-3.6% low in all 12 windows ([accuracy-logs/hops.txt](accuracy-logs/hops.txt) holds 6 of them, at 3.0-3.6%) and is now 0.0% at
one decimal (section 5, the network time).

Level 3 is not a result. Its two before windows read 97.8 and 113.3 ms (more than 10% apart), so a steadiness gate stopped it. Per round, the
predicted change against the measured one: round 1 +28.08 against +28.16 ms (0.0 standard errors); round 2 +34.61 against +8.70 ms
(+3.7 standard errors), whose before window was the slow one. The after windows are over-predicted by +6.4% and +6.6% with `api` 79%
busy, where the model's own error is largest ([ACCURACY.md](ACCURACY.md#1-where-it-is-still-wrong-read-this-first)). Level 1's first round
is -1.8 standard errors (+17.48 predicted, +22.10 measured). The model run on the demo's true topology gives +26.64 ms at level 3, 1.5 standard errors above the
measured: a third of the gap is the estimate from the capture (+4.7 ms over the true topology's), the rest is what the model gives
with the true parameters at 72% busy, and the measurement's noise. Level 3 needs longer or more windows. Read 70-80% as the stated limit.

## 4. Phase B: what the tool said, as captured

| mix | traces | the refusal |
|---|---|---|
| `shipped` | 10,468 | `559 of 10468 traces miss spans (5.3%): 559 have a call to a service with no span of that service under it` (the limit is 5%) |
| `browse` | 7,683 | `the inferred call graph is not usable: the call graph has a cycle; the model needs a DAG` (frontend calls frontend) |

Two diagnostic variants of each window followed (made by `otelcap cut` before the tool read the file; not the tool's result): the nested spans of
one kind in one pod made INTERNAL (`nested`), and also flagd's spans left out (`nested-drop`). With them the browse mix was modelled
(4 services, frontend 1.4% busy) but its latencies were **20-31% below** what the callers' client spans measured (frontend 1.95 against 2.48 ms,
frontend-proxy 2.11 against 2.64, product-catalog 0.71 against 1.03). The shipped mix was still refused:
`cart -> ext:valkey-cart: calls per visit vary as {1: 3098, 2: 559, 3: 1731}; the model has a fixed count or one conditional call per visit, not this`.

## 5. What was wrong, what was changed

Each cause was checked on the captured traces before it was fixed; the status is that of this repository now.

| # | symptom | cause | fix | status |
|---|---|---|---|---|
| 1 | shipped mix refused: 559 of 10,468 traces (5.3%) "miss spans" | **Not lost spans.** The cart's calls to flagd go through .NET's gRPC client, which opens a CLIENT span around the HTTP client's; flagd's SERVER span hangs under the inner one. The outer span has nothing under it, so it read as a call that nobody answered. One per PlaceOrder trace: 559 of 559. | Nested CLIENT spans are one call: the span the callee's SERVER span is under is kept, the wrapper becomes INTERNAL. No trace is broken any more | fixed |
| 2 | browse mix refused: frontend calls frontend | Next.js opens a SERVER span for its handler inside the HTTP instrumentation's SERVER span (7,641 pairs in the browse window, 9,183 in the shipped one); flagd's handler does the same inside the Connect interceptor's (1,117). A service calling itself, and every request counted as two visits | Nested SERVER spans of one pod are one visit (the outer is kept), unless both come from one instrumentation scope, which is a request the service sent to itself | fixed |
| 3 | shipped mix refused for the cart's cache calls (1, 2 or 3 per visit) | The count is a property of the request type: GetCart 1, EmptyCart 2, AddItem 3; checkout calls once per cart line; the front end serves a dozen endpoints of different shapes. No retries, duplicates or errors are behind them. The model had a fixed count (or one more on some visits) and one stage template per service | A varying count enters as its mean; a service that fits the stage template carries it in a stage; otherwise the service is a mixture of up to 12 call shapes. The callee's load is exact (the model's arrival rate equals the measured one at every service, to 0.1%) | fixed |
| 4 | levels 20-31% (browse) and 0.1-48% (shipped) below the callers | The network time of a call was read as the quietest tenth of (client span time less server span time). It has a right-skewed spread, so that tenth lies 0.2-0.3 ms below the mean on every call; at 1% utilization the model's wait is 0.01 ms and nothing else makes up the difference. The same constant put the repository's own demo's cache edge 2.5-3.6% low in all 12 windows | Per edge, the mean gap less the model's wait on a callee at most 30% busy; the quietest tenth above that | fixed; **partly fitted**, see section 7 |
| 5 | the front end's call shapes wrong: "cart x2" and "cart then cart" were one shape split in two (44% of the visits of POST /api/cart) | Node.js stamps its span starts on whole milliseconds: the second of two calls 1.2 ms after the first ended is stamped before it ended, and reads as made at once | The calls of such a caller are ordered by where their callees' spans are; the stages are cut where the callee spans leave a gap of at least a quarter of the round trip's overhead; the end of the visit allows a millisecond (8.4% of its cart calls and 9.3% of its ad calls end more than 0.25 ms after its span, by up to 0.8 ms, and were taken for calls it did not wait for) | fixed. The price: the front end's level is now 2.3% above its callers' (it was within 0.1% because the misread shapes were too fast and offset a charge that is too high: section 7) |
| 6 | a capture of the Collector's whole file exited 0 with frontend-proxy at 1,594 ms against the 6.9 ms its callers measured (found when the fixes were validated) | Three gRPC server streams of flagd (`EventStream`, 600 s each) were read as visits of 600 s: all of flagd's busy time. A window cut by span time holds them too | A capture whose server spans include streams (a second or more, a tenth of the capture, a thousand times its service's median) holding 5% or more of a service's busy time is refused, naming the stream | fixed |
| 7 | a service calling one callee 1 to 36 times in a row per visit ran for minutes, and 1 to 3,000 for hours (found by the review of the fixes) | The search for the stages of the template that a visit ran was exponential, and reading varying counts made it reachable | The search remembers the pairs that failed (36 calls: 0.09 s; 3,000: 2.6 s); a call shape of more than 200 stages is not fitted | fixed |
| 8 | smaller findings of the review: a service that sends a request to itself with a client that opens no span was counted at half its visits; two nested CLIENT spans nobody served kept the 0.5 ms connect and not the 6 ms operation; the same batch warning twice; no batch warning for a callee of unknown worker count at a low load; services with no SERVER span not named; the hop rule read the wait with the refined model under `--plain` | small defects in the rules above and in their warnings, one cause for each symptom | see [USAGE.md](USAGE.md#10-warnings) and [REQUIREMENTS.md](REQUIREMENTS.md#nested-spans-of-one-kind-in-one-pod) | fixed |
| 9 | Phase A level 3 unstable: predicted change +31.35 against +18.43 ms | `api` at 72-79% busy, before windows 10% apart, one round's change +8.7 against +34.6 predicted | none: more or longer windows at this load | **open** |
| 10 | queueing on real software | not tested: the Demo ran at 1-2% utilization | none possible with this load | **open** |
| 11 | `rust/` (rbfast) matches the Go output only as of the first release (commit 6841f9f of this repository) | it does not have these rules | [rust/README.md](../rust/README.md) says so | **open** |

## 6. Before and after on the real captures

**Which captures are read.** Of the six Phase B captures (both mixes, as captured and the two diagnostic variants) the earlier code read two (the browse
variants, 20-31% low) and refused four; now it reads all six. The 26 cuts of the two windows (for each mix 7 of 60 s, 3 of 140 s, 2 of 210 s and the 180 s
warm-up) were refused as well (0 of 26 read); now 26 of 26 are. The 12 captures of the repository's demo were read before and are read now, with unchanged numbers
except the cache. The Collector's whole file of each mix, and the cut of the 420 s before the window (which holds flagd's gRPC streams), are refused,
naming flagd's `EventStream`.

**The shipped mix as captured** (11,890 entry requests in 10,468 traces over 420 s; 14 services, the busiest at 0.95% busy;
13 with a measured latency): model against what the callers' client spans measured.

| service | rps | busy | model ms | seen ms | error |
|---|---|---|---|---|---|
| ad | 1.92 | 0.19% | 1.775 | 1.780 | -0.3% |
| cart | 12.83 | 0.11% | 1.401 | 1.399 | +0.1% |
| checkout | 1.33 | 0.02% | 18.367 | 18.797 | -2.3% |
| currency | 3.88 | 0.29% | 1.683 | 1.683 | 0.0% |
| email | 1.33 | 0.44% | 4.178 | 4.206 | -0.7% |
| flagd (also an entry) | 5.75 | 0.05% | 0.086 | 0.086 | -0.1% |
| frontend | 23.79 | 0.95% | 4.287 | 4.192 | +2.3% |
| frontend-proxy (entry) | 23.79 | 0.12% | 4.435 | 4.340 | +2.2% |
| payment | 1.33 | 0.07% | 1.514 | 1.514 | 0.0% |
| product-catalog | 24.64 | 0.05% | 1.113 | 1.115 | -0.2% |
| quote | 1.33 | 0.04% | 1.864 | 1.864 | 0.0% |
| recommendation | 1.89 | 0.05% | 3.538 | 3.537 | 0.0% |
| shipping | 2.66 | 0.01% | 1.395 | 1.395 | 0.0% |

The frontend and frontend-proxy rows are after the whole-millisecond rule (item 5 of section 5); [accuracy-logs/hops.txt](accuracy-logs/hops.txt),
section 3, was taken before it and has them at 4.187 ms (-0.1%) and 4.336 ms (-0.1%); its other 11 rows are the same as here.

The browse mix: frontend 2.525 against 2.482 ms (+1.7%), frontend-proxy 2.684 against 2.642 (+1.6%), product-catalog 1.034 against 1.034 (0.0%),
the busiest at 1.4%. Before the network-time rule these were -21.5, -20.2 and -31.1%.

**The change a patch predicts**, +1 ms of one service's time, at the entry (frontend-proxy), against a replay of the traces: each trace is replayed with
1 ms more work at every SERVER span of the service, the shift is propagated through the span tree (a span ends when the calls that ended before its
end have ended), and the entry spans' shift is averaged. The replay has no model in it; it has a tolerance for how far apart in time two spans may be and
still follow one another, and the answers for 0 and for 1 ms bracket what the traces allow.

| +1 ms on | replay, tolerance 0 to 1 ms | tool before the whole-millisecond rule | tool now |
|---|---|---|---|
| cart | 0.446 to 0.539 | 0.463 | **0.539** |
| ext:valkey-cart (the cart's calls to its cache) | 0.806 to 0.942 | 0.817 | **0.942** |
| product-catalog | 0.692 to 0.840 | 0.717 | 0.747 |
| frontend | 1.000 | 1.000 | 1.000 |
| checkout / currency / ad | 0.041-0.056 / 0.147-0.163 / 0.081 | 0.056 / 0.164 / 0.081 | 0.056 / 0.164 / 0.081 |

The calls that follow one another within a millisecond are what the bracket is about, and the tool's reading is now at the top of it for the cart,
where the callee's spans show the calls are in a row on 99.9% of the visits.

**The front end's shapes** (shipped mix): "cart then cart" 17.3% of its visits (9.7% and "cart x2" 7.6% before), "recommendation then product-catalog x4" 7.9%
(4.2% and "product-catalog x4 + recommendation" 3.6% before), "cart x2" 0.01%.

## 7. What this run does not show, and what is still wrong

- **Queueing was not tested on real software.** The busiest Demo service was 1.0-1.4% busy, where the model's wait is 0.01 ms and the latency of a service is its
  own time plus its callees' and the network's. Phase A is at 35-79% but its services are the repository's own sleeps and queues. What this run tests on real
  software is the reading of spans: structure, rates, call counts, per-call times.
- **The level agreement on the Demo is partly fitted, not predicted.** At 1% utilization the hop is the mean client-minus-server gap, so a callee's latency equals what
  its callers saw by construction (the report says so under the table: "hop from the mean"). What is independent: the arrival rates (equal to the measured ones to 0.1%), the
  call structure, the change propagation against the replay (above), Phase A, and a hold-out. The hold-out: the model fitted on one window against what the callers measured in
  *another* window of the same capture gives the same mean error as one window's callers' means give against another's, the noise floor of the capture (shipped, 210 s windows:
  5.8% against 5.8%; 140 s: 6.6% against 6.4%; 60 s: 7.1% against 6.4%; browse, 210 s: 4.6% against 4.5%). So the model carries no information beyond the window's means at this load;
  its in-sample agreement (0.6-1.1%) is not a prediction accuracy. Do not quote "within 3%" for the Demo as a prediction.
- **The front end's level is 2.3% above its callers' on the shipped mix** (+1.7 to +2.7% over the cuts, +4.0% in one 60 s window). Reading the call shapes right removed a
  misreading that had been offsetting it. The cause is only partly known. The part that was checked: the model charges every call on an edge the edge's mean network time, and the
  time of a call is not the same alone and in a group. From the front end to the catalogue, a lone call's client time less its server time averages 0.96 ms (4,241 calls) and each of four
  calls made together 1.27 ms (3,364 calls), against 1.10 ms for the edge; that accounts for about half of the 0.10 ms. The rest is not attributed (the early start of Node's client
  spans, which makes them read long, is a likely part: not separated out). The browse mix, which has no such mix of shapes at the front end, is within 1.7%.
- **What a user sees is higher than the entry's latency.** The load generator's own client spans read 6.57 ms (shipped) and 4.16 ms (browse) against the entry's server spans' 4.34 and
  2.64 ms: the ingress hop and the client's time, outside the model.
- **Large errors remain in small windows.** Over the 26 cuts, 147 of 152 service-windows of at least 200 visits are within 3% (the median |error| is 0.2% on the shipped mix and 1.5%
  on the browse mix). The five outside: currency +11.3% in one 60 s cut (a heavy tail with few samples), the front end and frontend-proxy +4.0% and +3.9% in that cut, and
  the same two at -4.2% and -4.0% in the browse mix's 180 s warm-up (their wait there is 0.2 ms and the model's 0.00). In the validated windows the worst is checkout at
  -2.3% (cause not found).
- **No change was measured on the Demo,** so the predicted changes are checked against the traces' own structure, not against a deployment.
- **One cluster, one run per mix.** The rules were found on one version of one demo, by one run; the nested-span rule has been checked against two real frameworks'
  spans, and the whole-millisecond rule against one runtime's (Node.js).
- **An edge whose callee spans are all missing is external by design.** If every SERVER span of a callee is lost, the calls to it are an outside delay; nothing says a
  service is missing. The tool names what it can tell from partial loss ([REQUIREMENTS.md](REQUIREMENTS.md#spans-that-were-lost)).
- **Streams are refused, not repaired.** A capture with a stream must be cut by the time its traces started, or the spans dropped.

## 8. The data

The traces behind the tests are in the repository, cut down to what the reader uses (service and pod, ids, kind, times, span name,
instrumentation scope, peer and port), in `internal/infer/testdata/`: whole traces of the Demo as `nested/` (four nesting patterns and a
consumer's spans), `counts/shipped-20s/` (the first 20 s of the shipped window: the cart's counts, checkout's lines, the front end's shapes)
and `hops/` (the first 45 s of the browse window, and 30 s of the repository's own demo). The Demo's traces are excerpts of
[OpenTelemetry Demo](https://github.com/open-telemetry/opentelemetry-demo) output (Apache-2.0); the folder's
[README](../internal/infer/testdata/README.md) says what was kept and what was changed, and NOTICE credits them. The whole windows (tens of
megabytes) are not in the repository.

**What you can and cannot check from this repository.** The excerpts reproduce the structure, count and hop tests: `go test ./internal/infer`
reads them through the same code, and `rhobound predict internal/infer/testdata/counts/shipped-20s` prints the model against what the callers
measured for the first 20 s of the shipped mix (the `hops/` sets work with `predict` too; the `nested/` sets are too small for the CLI,
and only the tests read them). [accuracy-logs/hops.txt](accuracy-logs/hops.txt) has the per-service rows of section 6 and the model's side of the
Phase A table, to 0.02 ms (the mean of the two front-end rows of each level). The rest comes from the run of section 1, on a cluster that was torn down afterwards, and its whole captures are not published, so
those numbers are reported, not reproducible from this tree: the load generator's measurements and the ± values of Phase A (section 3); the
refusal counts of section 4 and the nested-pair counts of section 5; the replay table and the hold-out table (the replay is a script that is not
in the repository); the statistics over the 26 cuts (147 of 152 service-windows); the user-visible 6.57 and 4.16 ms; the 0.96 / 1.27 / 1.10 ms split of
the front end's hops; and every mean over a whole window quoted elsewhere (for example the wrapper's 925 µs in REQUIREMENTS.md, which the two or three
traces of each `nested/` set cannot recompute).

`validation/cluster/` has the scripts: `phase-a.sh`, and `otel/` with the Collector's configuration, the load, `run.sh` and `otelcap`, which cuts a
Collector file into whole-trace windows and describes a capture ([README](../validation/cluster/README.md); the commands are in section 2).
