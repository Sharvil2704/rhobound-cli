# Validation: the checks that have been run

This page lists what has been checked, what passed, and where the tool is still wrong. It used to be the
"Checks that have been run" section of the README. The method, every table and the full list are in
[ACCURACY.md](ACCURACY.md); the summary lines behind each number are in [accuracy-logs/](accuracy-logs/).

Some words used below:

- **The reference implementation** is an unpublished Python prototype that this Go tool is a port of. Where the
  two are compared, the comparison is said so.
- **True parameters** means the model fed the simulator's own service times and worker counts, instead of the
  ones read from a trace. It separates the model's error from the error of reading one capture.
- **A check round** is a set of independent checks of the code and the numbers (re-runs of the studies on
  fresh seeds, a code review, a docs check), whose failures the next commits fix. "This round" below is the round
  of 2026-10-19 ([ACCURACY.md section 3](ACCURACY.md#3-what-was-fixed) lists its commits). "The code review's
  captures" are synthetic captures that the code review built to break the inference.
- **Level** is the entry latency before any change; **change** is how much it moves after a change.
- **Short hashes** such as 2349b17 name commits of the tool's development history. That history is not published:
  the public repository's commits are squashed releases of the code, so these hashes do not resolve there.
  They show which state of the code a number comes from.

## Results

Honest status; none of this is a claim about your system. Failures and weaknesses first. Measured at 2349b17 on
seeds 301-308 (never used before) unless a row says otherwise; the inference edge cases come from the code review's
captures, re-checked at ed44f6a-d13cde7.

**Where it is wrong.**
- **On real software the tool had never been tried until 2026-10-21, and it failed** ([REAL_CLUSTER.md](REAL_CLUSTER.md)). On the OpenTelemetry Demo it refused both
  load mixes as captured (a wrapper span that looked like a lost span, a framework's span that looked like a service calling itself, then call counts that
  vary by request type) and, once those were read, its latencies were 20-31% below the callers' (one constant in the network-time estimate). All are fixed
  (rows below). **What remains:** the Demo ran at 1-1.4% utilization, so queueing was not tested on real software; the level agreement on it is partly
  fitted, not predicted (a hold-out equals the noise floor); the front end's level is 2.3% above its callers'; the repository's own demo at 72% busy was
  judged unstable (predicted change +31.35 against +18.43 ± 10.85 ms).
- **Near 80% a small input error is a large output error.** One 400 s capture limits the accuracy. On fresh seeds the
  second and third largest level errors, +12.2% and -10.7%, are +2.1% and -1.3% with the true parameters, from service
  times read within about 2% of the truth. The worst change error, 7.5% of the latency, is 0.65% with the true
  parameters, from service times and cs2 within 1.3%; it is beyond 3 standard errors of the truth and the input noise
  combined, so part of it is something the input's standard error leaves out (likely the branch correlation read
  from the capture; unverified).
- **The worst level error is mostly the model's.** It is -12.5% (a calls b, then c), and with the true parameters
  the model is already -7.1% there: b has cs2 3 behind a smooth a. The service times read within 1.2%, b's cs2 2.80
  against 3.00.
- **The model has an error beyond noise on many rows.** With the true parameters the refined model still misses the
  change by more than 3 of the truth's standard errors on 46% of the rows, by a median of 6.6% of the change on those
  rows (3.3% over all rows). It misses the level so on 39% of the rows, by a median of 2.2% there (1.0% over all).
- **The second call of a sequential caller** (a calls b, then c; the change at c) is the largest term found. The change
  is over-predicted behind a smooth b (median +11%, up to +34%) and under-predicted behind a bursty b (median -13%, down
  to -38%). A parameter-free fix was tested this round against declared holdout bars. It cut that error by half but
  made two level statistics worse beyond tolerance, so it was not applied (one of the two fails only with both span
  modes pooled, which the declaration itself notes halves the tolerance; the bar stands as declared).
- **Other known model terms:**
  - a change in a fan-out branch that is not the slowest is over-predicted, by 0.2-1.1 ms in all 128 cases;
  - staged calls pass too much of a small change through (up to 85% of changes of 0.4-5 ms);
  - several workers with cs2 4 read 2-7% high (Allen-Cunneen);
  - a regular upstream makes the change 4-9% too small, where the basic model is closer;
  - a queue behind a smooth multi-worker queue gets too much wait (about 3% of the level);
  - the damping weight 0.7 is empirical.
- **The studies use our own simulator.** Its FIFO queues release the worker at the first call out, which is what the
  queue rebuild assumes, so the two span modes agree there to 0.15 point on the level and 0.08 point on the change in
  % of the latency (0.4 point in % of the change). A server that is not FIFO, holds its worker across calls (or for
  the work after them), or slows down with concurrency was not tested.
- **Inference edge cases** that still read wrongly:
  - a first call that starts before its server span. The worker is taken as freed at the span's start. A warning
    names the clock (skew between pods, or a CLIENT span of the pod's own) and which way the reading moves: on
    the code review's capture, 8+ workers and 23.7 ms against 1 x 10 ms. The reading itself is not corrected;
  - a pool with no worker limit reads as a lower bound and is modelled at that bound. On the code review's capture
    (236+ workers at 85%) every change of +1 ms or more is refused (+20 ms as past 100%). The refusal says the count
    is only a lower bound and points to `--workers`, with which the change is predicted;
  - a caller that sends some of its calls to a callee after its response and the rest during it (between 5% and
    95%): all of them are kept on the latency path, with a warning;
  - async is decided from the calls' start times. On a link with no CLIENT span the start is on the callee's clock,
    so a callee clock running ahead (by more than the call's duration plus the caller's work after it) makes calls
    the caller waits for look async, and they are modelled so (the warning names the clock). On a test shape with
    4 ms calls, a clock 2-10 ms ahead stays on the path with a warning and one 30 ms ahead reads as async;
  - a capture with no captured top that lost more than half of the calls into one service would read those calls
    as entries.
- **Replicas and worker counts.** An uneven split over replicas under keep-alive routing is over-stated by the shares
  model; on the one real capture with one, the shares made the level worse. Worker counts are lower bounds when spans
  start at service.

| Check | Result |
|---|---|
| **Whole pipeline at 70-80% utilization** (a 400 s simulated trace in; truth 64 paired replications of 400 s; 36 rows per seed, 30 random scenarios and 6 fan-outs, 8 seeds) | Entry latency, refined: median **2.0%**, 90th percentile **5.9%**, worst **12.5%** pooled (per seed 1.7-2.7 / 3.6-8.7 / 8.1-12.5%). Basic (`--plain`): 3.0 / 10.5 / 29.7%. Change: median **5.6%** of the change, 90th percentile 16.3%, worst 35.5%; in % of the latency 0.42 / 2.27 / 7.52 (basic 9.1 / 24.2 / 49.7% of the change). Refined is closer on 174 rows and further on 87. Spans that include the wait for a worker give the same numbers, to 0.15 point on the level and 0.08 point on the change in % of the latency (0.4 point in % of the change) |
| Structure family (glue, staged calls, conditional calls, uneven splits; 96 rows) | refined level 2.0 / 6.5 / 10.4%, change 4.7 / 16.6 / 79.9% of the change, 0.17 / 1.05 / 4.61% of the latency (basic 2.3 / 6.1 / 12.8%; 10.5 / 29.0 / 92.6%) |
| The model with the true parameters (TestAccuracy, chain sweep, fan-out, holdout; and the same 288 rows) | 288 rows: level 1.0 / 3.0 / 7.1%, change 3.3 / 11.1 / 38.4% (basic 1.7 / 9.2 / 27.6%; 6.5 / 22.3 / 46.2%). Fan-outs with the measured branch correlation: level 1.3-2.0% median, 4.9% worst (basic 27-30% worst) |
| Port parity of the basic model (`--plain`) with the reference implementation (67 topologies at 3 loads, 201 cases; parallel / conditional / delay / replicas / workers / variability) | worst relative difference in the latency **4.7e-16**; after the change (a scaling with cs2 kept, as the reference computes a change, not the CLI's `+N ms` shift) within the test's 1e-10. The refined default has no reference implementation; it is checked by the studies above |
| Closed forms (M/M/1, M/G/1 exact, M/M/2, E[max], visit ratios, Burke); numerical kernels against high-precision references | pass |
| Inference against the simulator's known truth and hand-made spans (graph, rate, service times, hop, workers, glue, stages, conditional calls, lost spans, probes, upstream callers, async calls, consumers, clock skew) and against the reference's queue rebuild and stage template (golden files) | pass |
| Race detector | clean |
| Five captures of a 10-service Python demo shop on a single-node Kubernetes cluster (not published), 2026-10-16 (real Python services, 100 requests/s, **55-57% utilization**; development data, not a holdout) | Same services, edges, call probabilities, replicas, parallel flags and worker counts (with the same lower bounds) as the reference on all 10 services; service times within 0.6 of its standard error. Entry latency, model against the traces: **-0.8% to +1.4%** (basic -0.2% to +2.6%). Given the change in `auth`'s service time read from the after capture, the predicted entry change is within 1.5 standard errors of the measured one on all five (+3 ms of CPU: predicted +6.22 / +6.48 against +6.00 / +6.74 ms measured; under a CPU limit +8.49 against +9.16 ms). Does not test 70-80% |
| **Nested spans of one kind in one pod** ([REQUIREMENTS.md](REQUIREMENTS.md#nested-spans-of-one-kind-in-one-pod)): the OpenTelemetry Demo 2.2.0 on a real five-machine k3s cluster (AWS, 2026-10-21; 100 Locust users, 420 s windows), and whole traces of it as test data | Before, both mixes were refused as captured (shipped: 559 of 10468 traces miss spans, 5.3%; browse: a cycle, frontend calling itself). The shipped window holds 9,183 nested SERVER spans of the frontend, 1,117 of flagd and 559 nested CLIENT spans of the cart; the browse window 7,641 of the frontend. Merged: the browse mix is modelled (4 services, 1.4% utilization) with the numbers of the diagnostic cut that merged the spans before the CLI read them, but **20-31% below** the callers' means before the network-time rule (item 19 of the limits in [ACCURACY.md](ACCURACY.md#1-where-it-is-still-wrong-read-this-first); within 2% with the rule of the "network time of a call" row below); the shipped mix is no longer refused for lost spans; it was refused next for the cart's cache call counts (1, 2 or 3 per visit), which the next row reads. Unchanged: the 12 captures of the repository's own demo (text, JSON and warnings byte-identical), 1,973 of 1,977 older captures (the other four are captures of the same Demo from a single-machine cluster that were refused for a cycle or for a call count and are now modelled or refused for a later reason), two real captures of 550 and 277 MB (same output, same run time of 2.0 s and 1.0 s), and the seed-305 accuracy summary lines (structure family on, both span modes). The rule is tested on the simulator (byte-identical statistics with and without nested spans), on hand-made spans and on the Demo's traces; real recursion is still refused |
| **Calls per visit that vary, and visits of several call shapes** ([REQUIREMENTS.md](REQUIREMENTS.md#calls-per-visit-that-vary-and-visits-of-several-call-shapes)): the same Demo runs, and an event-driven simulator with one queue per callee | Before, the shipped mix was refused for the cart's cache calls (1, 2 or 3 per visit by endpoint), and would have been refused next for the front end's call shapes. Now it is modelled (14 services, 1% utilization): the cart's Redis calls and checkout's lines as mean counts, the front end as a mixture of call shapes (11 in the 20 s excerpt, `internal/infer/testdata/counts/shipped-20s`); the model's arrival rate equals the measured one at every service (0.1%). Latencies were still 0.1% to 48.1% below the callers' (13 services, 420 s; [accuracy-logs/hops.txt](accuracy-logs/hops.txt), section 3) before the network-time rule (the network time per call, a separate estimate: the "network time of a call" row below). In the simulator the mean count is unbiased within 2% over runs at 30-60% load, 1 and 4 workers, counts 1-4 and heavy tails (1 or 20 calls), single runs of a one-worker callee off by up to 10%; a mixture of shapes is within 0.4% when the callee is quiet (8 workers, 20% busy) and 2-10% below the simulation when calls made at once meet 4 workers at 20-40% busy, which the batch warning says; four calls at once to one worker is 62% below (also warned of). Unchanged: the repository's demo captures and the captures accepted before (text, JSON and warnings byte-identical: see the commit), and the seed-305 accuracy summary lines (structure family on, both span modes) |
| **Lost spans, named** ([REQUIREMENTS.md](REQUIREMENTS.md#spans-that-were-lost)): hand-made spans from the simulator (a call losing its callee's span below and above 5%, two edges, a hole in the middle of a trace, an entry that is also called, broken traces of one kind of request), 478 real traces of the OpenTelemetry Demo with product-catalog's SERVER spans taken out of some, the CLI's report, and the real runs | The rule of what is lost is unchanged; the refusal and the warnings now name the caller, the address, the service that answers on it and the calls lost over the calls made. Nothing else moved: the 12 Phase A captures (text, JSON, warnings) are byte-identical; of the Phase B windows only the shipped mix (as captured and `nested`) gains a warning that flagd is entered from outside and is also called by the cart (77% of its 2,416 visits have no caller in the capture: 1,299 lookups of the load generator and 558 root spans of a client that sends no context; 23% are the cart's); the other four are byte-identical. Of 1,977 older captures 1,882 are byte-identical and 95 differ in the added text only (60 refusals that now name the edge, 32 captures under 5% with a warning per callee, 7 of them with a row marked, 5 with a hole below a top named, 3 with an entry that is also called, 3 with a lost caller); no number of any of them changed. On the Demo's browse mix with product-catalog's spans taken out of 2.2% of its calls at random, and of the slowest 5.0%, the warning names `frontend -> product-catalog:8080` and the model's latencies are those of the complete capture to within 0.01 ms; at 7.8% the refusal names the edge. The captures over 60 MB give the same output |
| **The network time of a call** ([REQUIREMENTS.md](REQUIREMENTS.md#the-network-time-of-a-call), item 22 of the limits in [ACCURACY.md](ACCURACY.md#1-where-it-is-still-wrong-read-this-first)): the Demo's browse and shipped mixes and the repository's own demo (12 Phase A windows) on the real cluster, the simulator with a hop jitter, the accuracy harness (seeds 305-307, both span modes, structure family on) with and without the jitter | The hop was the quietest tenth of (client - server) per callee; with the model's wait at 0.01 ms that left every call short by the spread of the network time. Now the mean gap less the model's wait on a callee at most 30% busy, per edge. Browse: frontend / frontend-proxy / product-catalog **-21.5 / -20.2 / -31.1% to +1.7 / +1.6 / 0.0%**; shipped (13 services): worst error 48.1% to 2.3%; Phase A cache -3.6 to -2.5% to 0.0 (at one decimal) in all 12 windows, api and db unchanged. Simulator chain 3% busy with 0.05 / 0.1 / 0.2 ms of jitter per leg: -6.0 / -11.2 / -19.8% to 0.0%. Harness: every line and the log of the large rows as before without the jitter; the jittered lines in [accuracy-logs/hops.txt](accuracy-logs/hops.txt). On a leaf the new level is the callers' by construction; the independent checks are the simulator's known hop, the non-leaf rows and the unchanged harness. A wait the model does not show, at or below 30% busy, lands in the hop (warned of) |
| **Server spans that are streams** ([REQUIREMENTS.md](REQUIREMENTS.md#streams-and-other-long-server-spans)): the Demo's whole Collector files (shipped: 856 s, 267,313 spans; browse), two cuts of the 420 s before each window, hand-made spans for each of the three conditions and their edges, and a real 20 s cut with three streams added | Found by validating the fixes above, not by a first run. Before: the whole files exited 0 (flagd 53% busy, a service time of 380 ms, frontend-proxy at 1,594 ms against 6.87 ms seen, the cart +217,323%) with no warning; the pre-window cuts were refused for "flagd would pass 100% utilization (116.5%)", with the advice to set `--workers`. Now all four are refused naming flagd's `EventStream` (3 spans of 600 s in the shipped file, 6 in the browse one). The 18 saved captures (233 output files per run: infer and predict, text, JSON and warnings) and the 26 sub-window cuts are byte-identical; run time and memory on a 555 MB capture are unchanged (2.0 s, 235 MB). The thresholds rest on one case |
| **The stage-template search** (found by a review of the fixes): a generator of 300 traces in which one service calls one callee 1 to N times in a row per visit | Reading varying counts made an exponential search reachable: N = 28 took 6.5 s, 32 took 58 s, 36 did not finish in 120 s, and N = 3,000 ran for 10 minutes of CPU before it was stopped (a fixed count of 30 or more was fine, and 30 or 31 took 97 s before the change too). Now 36 takes 0.09 s, 160 0.24 s, 320 0.44 s, 3,000 2.6 s (call shapes of more than 200 stages are not fitted); the output on the real captures is byte-identical; the regression tests have time limits and fail on the old search |
| **Nested spans, the review's findings** ([REQUIREMENTS.md](REQUIREMENTS.md#nested-spans-of-one-kind-in-one-pod)): hand-made spans for each case, the Demo's four nesting patterns, 16,000-deep chains | Two SERVER spans of one scope with no CLIENT span between were silently read as a wrapper (a service that sends a request to itself counted at half its visits); now two of one scope are two visits (refused as a cycle), and a capture with no scope names gets a notice. Two nested CLIENT spans that no callee answers kept the 0.5 ms connect and not the 6 ms operation (5.4 ms moved into the caller's own time); now the outermost. A chain of 16,000 took 130 s and takes 1.1 s. Real captures: the wording of the warning only |
| **Spans on whole milliseconds** ([REQUIREMENTS.md](REQUIREMENTS.md#clocks-and-client-spans)): the Demo's shipped window, the 26 cuts, a replay of the traces, a Node.js-like caller in the simulator's writer | The front end's call shapes are read right ("cart then cart" 17.3%, was 9.7% and 7.6% apart) and the change predicted at the entry for +1 ms of the cart is 0.539 (replay with a tolerance of 1 ms: 0.539; before 0.463), of the cart's cache 0.942 (0.942; 0.817), of product-catalog 0.747 (0.692 to 0.840). The price is the front end's level: +2.3% (was -0.1%, with the misread shapes offsetting it); +1.7 to +2.7% over the cuts (+4.0% in one 60 s). The browse mix, the 12 captures of the repository's demo and every other saved capture are unchanged; the warnings that 8.4% and 9.3% of the front end's calls to the cart and ad "outlive its span" are gone |
| **The warnings and the tests that survived mutation** (review of the fixes) | The same batch warning twice, a batch of three calls or more at a lower-bound callee at a low load that was not warned of, the mean-count explanation repeated for every edge, services with no SERVER span not named, the `--patch` list of services including zero-time nodes: fixed. Of 29 mutants of the new code that the review made, four survived with no failing test (one was dead code, now removed) and a fifth was killed only by an unrelated test; tests now kill them (the hop rule's limits are pinned, an edge of fewer than 50 calls takes its callee's pooled gaps, a batch at a low load is warned of, a single-caller topology names no hop per call, the real fixtures are identical at 1, 3 and 8 cores), each checked by making the change and watching the test fail |
| **The gate**: `gofmt`, `go vet` (plain, `-tags e2e`, `-tags accuracy`), `go test -count=1`, with `TestGolden` and the numerics tests | Pass (`./...`). The accuracy harness on seed 305 (structure family on, spans start at service) gives the recorded summary lines to the digit (it exercises none of the new rules: its spans carry no scope, no caller stamps whole milliseconds, and every callee is above 30% busy); seeds 306 and 307, in both span modes (ACC_SPANQ=1), with the structure family on, give summary and row lines identical to the code before these changes (compared line by line, timings aside); the cluster tests were not run again |
| **Real Kubernetes (kind)**: 4 services, one with 2 replicas, a parallel fan-out, 30 requests/s Poisson, +8 ms in `api` rolled out with `kubectl set env`; latency measured by the load generator, not by traces | Six runs, below |

Kubernetes runs (entry latency before the change, then the change from +8 ms in `api`; model against the load
generator):

| run | design and code | level, model vs measured | change, model vs measured |
|---|---|---|---|
| 1 | one before / after pair, keep-alive on; basic model; code before the 2026-10-19 fixes | 46.15 vs 43.34 ms (+6.5%) | +15.29 vs +13.15 ms (+16%) |
| 2 | the same; refined model | 44.11 vs 43.49 ms (+1.4%) | +14.25 vs +14.59 ms (-2.3%) |
| 3 | the same; refined, earlier service-time estimator | 44.42 vs **52.15 ms (-15%): FAILED** | +14.79 vs **+3.45 ms: FAILED** |
| 4 | the same as 3 | 44.53 vs 42.75 ms (+4.2%) | +14.78 vs +13.54 ms (+9.1% as recorded; +9.2% from these values) |
| 5 | hardened test (2026-10-19 13:58 UTC, 29a7ed9): keep-alive off, every pod restarted per window, two interleaved before / after rounds, gates | **45.89 vs 45.66 ms (+0.5%)** | **+14.59 vs +13.39 ms (+9.0%)** |
| 6 | the same at the final code (2026-10-19 19:05 UTC, 53b5068) | **46.15 vs 46.10 ms (+0.1%)** | **+14.93 vs +13.56 ms (+10.1%)** |

Runs 1-4 are as recorded at the time; their test logs are not kept (run 1's captures are).

- **Run 3 failed on the measurement side.** Its "before" window read 52 ms where the others read 43; its "after" window
  was in line, and the model's numbers did not move.
  - The most likely cause is an uneven split over the two api replicas. A Kubernetes Service picks a replica per
    connection, and the frontend reused keep-alive connections; on run 1's kept captures the next call went to the same
    pod 98.5-99.2% of the time.
  - It is unproven. Run 3's captures were deleted with the test's temporary folder, the simulation behind the
    explanation does not match the passing runs, and a short node stall fits as well.
  - The hardened test turns keep-alive off, gates on a 55% share and keeps its work folder on any failure or skip.
- **Runs 5 and 6** passed every gate (run 6: api shares 49.1-50.9%, api wait 9.24 / 9.35 ms model against 8.90 / 9.12 ms
  in the traces, rounds +12.37 and +14.75 ms; details in
  [ACCURACY.md section 7](ACCURACY.md#7-a-real-cluster-kind-one-service-changed)). Run 5:
  - The api pods took 48.7-51.3% of the calls in each window.
  - The api wait was 8.77 / 9.02 ms in the model against 8.52 / 8.99 ms in the traces.
  - The node and the host were quiet (CPU stalls under 0.4%, no memory stalls, OOM kills or restarts).
  - The two rounds measured +15.15 and +11.62 ms. A simulation of the demo puts one standard deviation of the
    two-round change near 1.1 ms, so the 1.2 ms gap is about one standard deviation. It puts the true change near
    +13.8 ms, so the model's bias here is about +0.75 ms (+14.59 predicted). The simulation is approximate: it draws
    exponential service times and adds a fixed 1 ms for the network hops and HTTP overhead it leaves out, and its
    level before the change is 42.3 ms (43.3 with that 1 ms) against 45.7 ms measured.
  - Its levels are not comparable with runs 1-4: per-request routing queues more at api.
  - It ran at 29a7ed9; run 6 repeats it after every later code change, at 53b5068.
- **The cluster test is circular in one respect.** The demo services are queues of the kind the model describes, so it
  checks the whole path (collection from a cluster, inference, model, rollout), not the model's fit to real software.

**Withdrawn.** The accuracy figures published before 2026-10-19 (median 1.5-2.4%, 90th percentile 2.8-5.4%, worst
5.6-10.5%; basic worst 16.8% "on every seed") came from a harness in which every row shared one capture seed and one set
of 16 truth seeds. They do not reproduce on fresh seeds and are replaced by the numbers above.

Speed: `predict` on a 579 MB capture (552 MiB, 697k spans, 10 services) takes **1.0 s** on 8 cores (1.9 s on 3, 5.1 s on
1; peak memory about 210 MiB), at 2349b17. The reference Python implementation took 22.5 s for its fuller `predict` on
the same capture (as recorded in 4ffc358; no log is kept), so the two are not like for like. The matched maximum's
cost grows with the square of the number of distinct parallel branches: `model` on a root with 8, 16, 32 and 64
distinct children took 0.08, 0.28, 1.05 and 4.09 s in the code review (5 branches at most on that capture).

## Re-running the checks

[BUILD.md](BUILD.md#running-the-tests) shows how to run the unit tests, the race detector, the accuracy studies and
the Kubernetes test. [validation/cluster/](../validation/cluster/README.md) has the scripts for a real cluster
(k3s, or any Kubernetes cluster): the Kubernetes test at three loads (`phase-a.sh`), and the
OpenTelemetry Demo captured and given to the CLI (`otel/run.sh`). A run of these scripts on a real five-machine cluster (AWS) is described in [REAL_CLUSTER.md](REAL_CLUSTER.md), with the commands to repeat it. [ACCURACY.md section 11](ACCURACY.md#11-re-running) has the command and the run time of every
study and the switches that select seeds and modes.
