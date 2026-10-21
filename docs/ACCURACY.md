# Accuracy at 70-80% utilization

What was measured, how, and where the tool is still wrong. Unless a line says otherwise, every number here was
measured at commit 2349b17 (Go 1.27.2, linux/arm64) on seeds 301-308, which no earlier study had used. The summary
lines behind each number are in [accuracy-logs/](accuracy-logs/) (section 11 says which file holds what). The truth
is a queue simulator written for these tests, so **none of it is a claim about your system.**

Short hashes such as 2349b17 name commits of the tool's development history. That history is not published: the
public repository's commits are squashed releases of the code, so these hashes do not resolve there. They show
which state of the code each number comes from.

## 0. Summary

**The whole pipeline.** A 400 s simulated trace goes through inference and the model. The truth is 64 paired 400 s
replications of the base and the changed system. Each seed has 36 rows (30 random scenarios with the busiest service at
70-78% and 6 parallel fan-outs), so 8 seeds give 288 rows. Median / 90th percentile / worst |error|:

| model | entry latency | change, % of the change | change, % of the latency | rows beyond 3 standard errors (level / change) |
|---|---|---|---|---|
| refined (default), pooled | **2.0 / 5.9 / 12.5%** | **5.6 / 16.3 / 35.5** | 0.42 / 2.27 / 7.52 | 3.1% / 19.4% |
| refined, range over the 8 seeds | 1.7-2.7 / 3.6-8.7 / 8.1-12.5 | 4.7-7.6 / 12.0-18.3 / 16.8-35.5 | 0.15-0.67 / 0.96-2.40 / 2.59-7.52 | 0-11% / 8-25% |
| basic (`--plain`), pooled | 3.0 / 10.5 / 29.7% | 9.1 / 24.2 / 49.7 | 0.60 / 2.55 / 7.08 | 15.6% / 37.8% |
| basic, range over the 8 seeds | 2.3-3.9 / 7.8-11.0 / 18.0-29.7 | 6.0-13.7 / 18.6-25.9 / 24.9-49.7 | 0.37-1.05 / 1.50-2.76 / 2.99-7.08 | 11-22% / 25-58% |

- **Both span modes give the same numbers.** On these rows, spans that include the wait for a worker and spans that
  start at service agree to within 0.15 point on the level and 0.08 point on the change in % of the latency (0.40
  point in % of the change). The queue rebuild recovers every wait here because the simulator builds exactly the
  first-come-first-served queue that the rebuild inverts (item 10).
- **Most large level errors are the noise of one capture**, amplified near 80%. With the true parameters, the refined
  model on the same 288 rows is 1.0 / 3.0 / 7.1% on the level. Of the 39 rows with a level error of 5% or more, 30
  have a true-parameter error under half as large. The worst row is one of the other nine: it is mostly model error
  (item 1).
- **Most change errors beyond noise come from the model.** 56 rows have a change error beyond 3 combined standard
  errors. On 50 of them the true-parameter model makes an error of the same sign and at least half the size. With true
  parameters the refined model is off by more than 3 of the truth's standard errors on 39% of the rows (level) and 46%
  (change). On those rows the median error is 2.2% of the level and 6.6% of the change (1.0% and 3.3% over all
  rows).
- **The largest model term we have identified is the second call of a sequential caller** (a calls b, then c, and the
  change is at c). Behind a smooth b the change is over-predicted: median +11.1% of the change at true parameters,
  21 rows, up to +34%. Behind a bursty b it is under-predicted: median -12.6%, 7 rows, down to -38%. A fix for it
  was tested against declared bars; it failed them and was not applied (item 2).
- **Where the refined model is no better than the basic one** (section 4.3):
  - single queues and Poisson-fed services: identical by construction;
  - the change behind a regular upstream service: refined -8.5 to -3.7%, basic -1.4 to +4.6% (TestAccuracy chains);
  - a sequential call behind a smooth service: refined +11.1%, basic +9.5% (median);
  - the structure family's level: 90th percentile 6.5% refined against 6.1% basic;
  - the worst fan-out change in % of the latency: 7.52% refined against 7.08% basic;
  - the test bed's change, where the changed service's arrivals are nearly Poisson.

  Paired over the 288 rows, the refined model is closer on 174 rows and further on 87 (level), and closer on 181 and
  further on 86 (change in % of the latency).
- **Real systems.**
  - The hardened kind runs (2026-10-19, section 7). Run 5: before the change, model 45.89 against 45.66 ms measured
    (+0.5%); a +8 ms change in `api` predicted +14.59 against +13.39 ms measured. Run 6, at the final code (53b5068):
    46.15 against 46.10 ms (+0.1%); +14.93 against +13.56 ms. Each change gap (1.2 and 1.4 ms) is about one standard
    deviation of the measurement; together they suggest the model's change runs about 1 ms high on this demo.
  - Five test-bed captures at 55-57% utilization (section 8): the model's entry latency is -0.8 to +1.4% from the
    traces. Given the change in `auth`'s service time read from the after capture, the predicted entry change is within
    1.5 standard errors of the measured one on all five.
  - The OpenTelemetry Demo on a real cluster (section 9, [REAL_CLUSTER.md](REAL_CLUSTER.md)): the CLI **refused both load mixes** as
    captured (a wrapper CLIENT span read as a lost span; a Next.js SERVER span inside another read as a service calling itself), and
    then, once those were read, its latencies were 20-31% below the callers' (a constant in the network-time estimate). All fixed; the shipped
    mix (14 services) is now within 2.3% of what its callers measured and the browse mix within 1.7%. **That agreement is partly fitted, not predicted**
    (the hold-out equals the noise floor), **at 1-1.4% utilization, so queueing was not tested on real software.** On the repository's own demo on the same
    cluster the tool passed two loads (change predicted +17.45 against +19.31 and +23.95 against +23.88 ms) and judged the third (72% busy) unstable.
- **Withdrawn.** The figures published before this round (median 1.5-2.4%, 90th percentile 2.8-5.4%, worst 5.6-10.5%;
  basic worst "16.8% on every seed") came from the old harness, not from the code. That harness used one capture seed
  (5150) for every row, shared truth seeds 1001-1016, ran 16 replications and scored the same 6 fan-outs on every seed.
  On fresh seeds the same code gave a 90th percentile of 4.6-6.6% (seeds 101-108, check round 1) and gives 3.6-8.7%
  here.

## 1. Where it is still wrong (read this first)

1. **Near 80% a small input error is a large output error, and one 400 s capture limits the accuracy.** The wait
   grows like 1/(1 - rho), so at rho 0.76-0.78 a 1% error in a service time is 3-4.5% of the latency and 6-10% of a
   change.
   The worst rows (pooled.txt, section 9):
   - Level -12.5% on seed 305, row 10 (a calls b, then c; change at b) is **mostly model error**, not this kind. The
     service times are within 1.2% of the truth, but b's cs2 reads 2.80 against 3.00 (a's 0.57 against 0.60), and the
     true-parameter model is already -7.1% there (z -7.7 against the truth's standard error): b has cs2 3 behind a
     smooth a. The whole error is within the noise of one capture there (z -2.4 against the truth's and the input's
     standard errors combined, 5.3% of the latency), but most of it does not come from that noise.
   - Level +12.2% (seed 307, row 6) and -10.7% (seed 304, row 0) are of this kind: +2.1% and -1.3% at true
     parameters, from service times within 2.1% and cs2 within 4% of the truth.
   - Change +27.4% of the change, 7.5% of the latency, on seed 306, row 33 (two-branch fan-out at rho 0.78). The
     service times and cs2 are within 1.3%, and the true-parameter model gives +2.4% (0.65% of the latency). But the
     error is beyond 3 combined standard errors (z +3.8), so the input noise that standard error covers does not
     explain all of it. The likely cause is what it leaves out: the branch correlation, read from the one capture
     (section 11). That is unverified.
   - All 21 rows with a change error of 2.5% of the latency or more change the loaded service itself (the slowest
     branch of a fan-out, or a service behind or across replicas). At true parameters 20 of them are within 1.5% of
     the latency, so their error comes from the inputs; 18 are within 3 combined standard errors, and the other three
     are fan-outs like the row above (z +3.2 to +3.8). The remaining one, seed 304 row 11 (a calls b, then c; change
     at b), is -3.55% inferred against -2.40% at true parameters: mostly model error.

   The input standard error used for z is a linearisation; at rho 0.76 and above it likely understates the spread a
   little, so the |z| shares there lean high.
2. **Sequential calls: the arrivals at the second call.** In the simulator, as in a real service, a caller sends its
   second call when the first returns, so the second callee sees the first callee's departures. The model gives every
   call the caller's own departure stream. This is the sign pattern in item 0: over-prediction behind a smooth first
   callee, under-prediction behind a bursty one.
   - A parameter-free fix was tested: each later sequential call carries the previous call's return stream. It was
     declared before any run, with fixed bars, on 1487 holdout rows (seeds 201-206 and earlier families).
   - The fix cut the change error where it was aimed: the median |change error| on rows whose changed service is a
     later sequential call fell from 8.14% to 4.17% at true parameters. It changed nothing on rows without a sequential
     caller, as declared.
   - It was **not applied**. It made two level statistics worse beyond their declared tolerances:
     - one holdout family, 90th percentile |level error| 2.44% to 2.90% (tolerance 0.36);
     - inferred rows with a sequential caller, both span modes pooled, 90th percentile |level error| 4.39% to 4.61%
       (tolerance 0.19). Each mode alone passed (+0.21 and +0.22 against a tolerance of 0.27). The declaration itself
       notes that pooling the two modes counts nearly identical topologies twice and halves the tolerance, a flaw in
       the declaration; the bar stands as declared.
   - The declaration, the verdict and the code are kept outside the repository. An earlier attempt at a load-dependent
     weight also failed its declared holdout bars.
3. **The percentage error of a small change is large.** Pooled, the 90th percentile is 16.3% of the change and the
   worst 35.5%. Most of the large percentages are changes of a few ms, under 1% of the latency. The z shares flag
   errors that are real but small: with 64 paired replications the truth of a change is often known to a few tenths of
   a percent.
4. **A change in a fan-out branch that is not the slowest is over-predicted**, in all 128 such cases of the fan-out
   family (8 seeds x 16), by 0.20 to 1.09 ms (up to 1.7% of the latency, 26-30% of the change in median). A change in
   the slowest branch is within -0.50 to +1.88 ms.
5. **Staged calls pass too much of a branch's change through.** At true parameters the staged rows' change error is
   7.5 / 38.0 / 85.5% of the change (median / 90th percentile / worst). These are changes of 0.4-5 ms, at most 2% of the
   latency. Validation measured the cause on one row: at the stage's maximum the model passes 0.565 of the changed
   branch's increase through to the latency, where the simulator passes 0.43. Neither the arrival weight nor the branch
   correlation closes the gap.
6. **A queue behind a smooth multi-worker queue gets too much wait.** On one validation row, a single worker behind a
   smooth 2-worker queue at rho 0.74 has a model wait of 22.96 ms against 18.15 simulated. Even the simulator's own
   inter-arrival variability, fed to the Allen-Cunneen formula, gives about 21.5 ms. This is a pacing effect of the
   departure process that no two-moment form here closes. The glue rows, which have such chains, are off beyond the
   truth's noise on 58% of rows at true parameters, by up to 3.2% of the level.
7. **Several workers with a very variable service time are too high.** For M/G/c with cs2 4 and c of 2-8 the level is
   over-predicted by 2.4-7.1% and the change by up to 9.1% (c = 8). This is the Allen-Cunneen approximation itself; the
   refinements do not touch it.
8. **A regular upstream service makes the change too small**, and a bursty one makes the level too low:
   - after a gamma 0.25 upstream, the refined change is -8.5 to -3.7%, where the basic model gives -1.4 to +4.6%;
   - after an h2 cs2 4 upstream, the refined level is -7.0 to -6.2% (basic -16.2 to -15.5%).

   The arrival weight 0.7 is an empirical constant. The best constant differs by where the change is (section 5.2), and
   the exact two-queue model shows that the share of upstream variability a queue sees falls with its own load.
9. **An uneven split over replicas.**
   - From traces, the tool measures each replica's share. When an even split is ruled out (p < 1e-6), it models each
     replica fed its share and keeps the shares for the change.
   - On the simulator, which draws the split per request, this is right. A fixed 75 / 25 split gives an entry of 36.99
     ms against 36.52 simulated, where an even split gives 28.97.
   - On the one real capture with an uneven split (keep-alive connections, kind run 1's kept captures, read after
     cutting the after capture to its own window), the shares made the level worse: the error went from +6.6% (even
     split) to +6.9% (shares) before the change, and from +5.6% to +10.1% after. Under keep-alive each pod holds only
     its connections' requests, so its arrivals are smoother than the Poisson-thinned stream the model feeds it. The
     shares model is an upper-side estimate there.
   - No multi-pod service in the end-to-end rows is flagged: 0 of 170 on seeds 301-308 (both span modes; the test
     run with its seed list replaced, on a copy) and 0 of 152 on the development seeds 31337 and 1-7 (the test as
     committed). The smallest p values are 0.0065 and 0.0045.
10. **The truth is our own simulator.** It has FIFO queues, service laws (gamma, hyperexponential, lognormal) that do
    not depend on concurrency, and a release of the worker at the first call out. The queue rebuild assumes exactly
    that, which is why the two span modes agree to 0.15 point on the level. A server that is not FIFO, that holds its
    worker across its calls, or whose service time grows with concurrency (CPU sharing, throttling, GC) was not
    tested. The real-cluster test (section 7) is made of queues of the same kind; the test bed (section 8) runs real
    software, but at 55-57%.
11. **Inference edge cases that remain** (from the code review's captures, re-checked after the fixes at ed44f6a and
    22e1886; the unbounded pool's refusals at d13cde7, in checks.txt):
    - Client spans of fe's own pod that start 1 ms before its server span on 5% of visits: read as 8+ workers and
      23.66 ms against 1 x 10 ms, so a +3 ms change is predicted as +3.00 against about +23. The warning now says this
      is not clock skew (one pod's clock) and that the reading is high. It also gives the reading with those calls
      skipped (1 worker, 9.99 ms), but the reading itself is not corrected. Skipping them would fix this capture, but
      the code review found that the same rule makes the skew captures below worse.
    - Callee clocks 2 ms behind on server-to-server links: the capture predicts, but the caller's service time reads
      0.14 ms against about 1 ms, with level +15.7%. The warning names the skew and says the service time reads low.
    - A pod with no worker limit and about 200 requests in flight reads 236+ (a lower bound), and the model uses 236.
      Its base reads 84.75%, so every change of +1 ms or more takes it past `--max-rho` and is refused (+1 ms: 85.6%;
      +10 ms: 93.2%; +20 ms: past 100%). The refusal names the service and its utilization, says the count is only a
      lower bound, so the utilization is an upper bound, and points to `--workers`, with which the change is
      predicted (`--workers fe=400`: +20.00 ms at 50%).
    - A call the caller does not wait for is recognised by its timing: it starts after the caller's span has ended,
      or its CLIENT span, on the caller's own clock, ends after that span (fire and forget sent just before the
      response). When at least 95% of a caller's calls to one callee are of this kind, the edge is async: those calls
      load the callee and are off the caller's path. Each call is still judged by itself, so on an async edge the
      few calls a visit did wait for stay on its path with their own probability and release its worker. Between 5%
      and 95% every call stays on the path, with a warning. On the code review's async-int capture (30% of fe's
      visits call a 200 ms service 50 ms after the response) fe's level went from +260.8% to -1.8%, and a change at
      the callee no longer moves fe (it moved fe by +34.92 ms for +100 ms). 53b5068 closed two gaps the round-3
      review found: fire and forget sent just before the response (ff-pre-0.05: +214.7% to -2.7%; ff-pre-3: the
      +3 ms change at fe +5.80 to +26.85 ms, truth about +26) and waited calls on an async edge (mixedb-0.96: fe read
      1 x 2 at 7.83 ms and is now 1 x 1 at 6.06 ms, the change +3.21 to +4.81 ms, truth +4.6 to +4.9). kind.txt
      lists these rows.
    - A call with no CLIENT span is timed by the callee's server span, on the callee's clock, and is judged by its
      start only. A callee clock that runs ahead of the caller's by more than the call's duration plus the caller's
      work after it makes a call the caller waits for look as if it started after the response.
      - When that holds for at least 95% of an edge's calls, the edge is modelled as async. The caller's level then
        reads about right, because the callee's time is folded into the caller's own service time (on the probe
        below, 6.04 ms against about 1 ms). A change at the callee does not reach the caller. The async warning says
        what share of the calls is timed by the callee's clock.
      - Between 5% and 95% (a few milliseconds of skew) the edge stays on the path. The skewed starts shorten the
        caller's own time less than they lengthen the calls, and the level is over-predicted. The warning names the
        callee's clock when it times the calls (since 53b5068).
      - The doc check's probe on the tests' skew shape (the callee's span exponential, 4 ms mean; 1 ms of the
        caller's work after the call; a scratch test, output in kind.txt) put 21.7%, 63.3% and 89.4% of the calls
        after the caller's end with the callee's clock 2, 5 and 10 ms ahead. Those stay on the path, with the level
        +14.7%, +42.1% and +59.3%. At 30 ms the edge reads as async and the level is -0.1%.
      - So export CLIENT spans, or keep the clocks in step (NTP).
    - After the clip, the refusal for a negative mean service time is reachable only with a `--workers` count below the
      real one, or with times that fit no FIFO queue.
12. **Worker counts are lower bounds when spans start at service.** In that mode no visit can wait inside its span. Of
    1150 service readings, none was read from queueing, 1102 equal the true capacity anyway, and none is above it. The
    48 below it are all the fan-out root (8 workers at about 1% utilization, read as 2+ or 3+). When spans include the
    wait, 1078 were read from queueing. An entry service's own wait before its span starts is never visible.
13. **Work after the first call out is read as glue that holds no worker.** That is how the simulator works (tested in
    both span modes). On a server that keeps its worker for it (an event loop, CPU-bound response writing), the model
    would under-state the utilization and the wait. This was not tested on such software.
14. **A hand-written topology needs the branch correlation.** From traces the tool measures it. In a topology you write
    for `rhobound model`, `branch_corr` is 0 unless set, and a fan-out level is then up to 17-20% high (section 5.3,
    `matched` against `matched+r`).
15. **The parity tests (`testdata/golden`) check the basic model only.** The refined default has no independent
    reference implementation. It is checked by the simulator studies and by closed-form limits (Burke). Its kernels are
    checked against high-precision references (`testdata/numerics`), which shows the arithmetic is right, not that the
    model is.
16. **The Python reference is not an oracle** (section 2.4).
17. **The trace-structure rules were checked against the reference's code, on the simulator and on hand-made spans.**
    Probes, lost spans, staged and conditional calls, upstream callers, async calls and consumers have not been seen
    together in a real capture. The test-bed captures have none of them (their inference is byte-identical before
    and after the upstream, async and consumer rules), and the kind captures have no probes and no stages. A span
    whose parent is outside the capture is an entry when most of its service's server spans have no caller in the
    capture. So a capture that loses more than half of the calls into one service, with no captured top above
    them, would pass those losses off as entries; a trace whose top is in the capture never does.
    - The header counts entries, not user requests: a gateway outside the capture that calls several services, or
      retries one, in one trace shows "N entry requests in M traces". A message consumer's calls are entries of the
      services it calls, counted apart in the text header; in the JSON report `requests` is still the total and
      `consumer_requests` the consumers' part.
18. **Routing is never detected from traces.** A service with several pods is modelled as a random split over them
    (or, when an even split is ruled out, each pod fed its measured share). A round-robin, least-request or
    power-of-two-choices balancer (an Envoy or Istio sidecar, for example) is read the same way, with no warning. Such
    a balancer feeds each pod a smoother stream than the Poisson thinning the model assumes, so the predicted wait is
    too high there, by the mechanism of item 9's keep-alive split. Not measured. In a topology file `round_robin` and
    `p2c` are refused; only `pooled` and `random` are accepted.
19. **Nested spans of one kind in one pod are read as one** ([REQUIREMENTS.md](REQUIREMENTS.md#nested-spans-of-one-kind-in-one-pod)).
    The rule was found on the OpenTelemetry Demo 2.2.0 on a real cluster (2026-10-21), where it was the reason the
    capture was refused, and it is tested on the simulator (a nested SERVER and CLIENT span added to every span: the
    statistics and the topology come out byte-identical to the capture without them, in both span modes), on
    hand-made spans, and on whole traces of the Demo. It has not been checked against a service that is
    not the Demo's. Limits:
    - A pair whose spans are more than 2 ms apart is not merged and the capture is refused as a service calling
      itself (the message says so). The Demo's Next.js spans, on whole-millisecond clocks, are within 0.89 ms.
    - **Two SERVER spans of one instrumentation scope are not merged** (a request the service sent to itself with a client that opens
      no span would look like a wrapper), and that rests on one observation: in the Demo's data every nested pair is from two scopes (the HTTP
      instrumentation and `next.js`, the Connect interceptor and flagd's handler). A framework that opens both spans from one scope would be
      refused as a service calling itself, with the message naming the scope case. An exporter that writes no scope name is judged on the times
      alone, and the warning counts the pairs it could not judge.
    - **The pod is what the capture's resources say.** With no pod, instance or host attribute a service is one pod, and two replicas' spans
      look like one process's.
    - **Two nested CLIENT spans that nothing serves keep the outermost** (a database or cache call with a connect inside it): the 6 ms operation, not
      the 0.5 ms connect. If the outer span is an umbrella over several independent operations it reads as one call.
    - Chains of more than 64 nested spans are left alone (the walk is bounded; 16,000 deep took 130 s before, 1.1 s now).
    - Merging does not make the Demo's captures right, only readable. The Demo's browse mix (4 services, 1.4%
      utilization) gave the same numbers as the diagnostic cut that merged the spans before the CLI read
      them, and they were 20-31% below what the callers' client spans measured (frontend 1.95 against 2.48 ms,
      frontend-proxy 2.11 against 2.64, product-catalog 0.71 against 1.03). The shortfall was the size of the
      report's `seen wait` column (0.26-0.32 ms per hop; 0.71 + 0.32 = 1.03 for product-catalog). It is not queueing
      (the model's wait is 0.01 ms there): it is the spread of the network time, which the hop, taken as the
      quietest tenth of the gaps, left out. Item 22 reads it, and the same captures are now within 2% (+1.7, +1.6,
      0.0%). The shipped mix is no longer refused for lost spans; the cart's calls to its cache vary with the endpoint
      (1, 2 or 3 per visit) and are read as in item 20.
20. **Calls per visit that vary, and visits of several call shapes, are read as a mean count or a mixture of shapes**
    ([REQUIREMENTS.md](REQUIREMENTS.md#calls-per-visit-that-vary-and-visits-of-several-call-shapes), section 6.3). The
    reference refuses them. The rules were found on the Demo's shipped mix (cart, checkout, front end), where they
    were the reason it was refused after item 19, and they are tested on an event-driven simulator, on hand-made spans and
    on 20 s of the Demo's traces. Limits:
    - **Calls made at once arrive together, and the model has them as independent arrivals.** The callee's wait, and the
      latency of whoever waits for it, is understated: 0.2% to 62% in the simulator (section 6.3: the warning speaks at
      every row of the table whose error is above 1.5% and is silent at the rows below 0.5%). It is warned of, for
      fixed fan-outs read as before too (a warning only), when the batch is larger than the callee's workers (when the count is a lower bound, for
      a batch of 3 or more, at any load: four calls at once to a one-worker callee at 3% busy left the caller 22% too fast with the hop reading the batch's
      queue as network time) or when its utilization times the batch over its workers reaches 15%. The model itself is not changed; batch arrivals
      (an M^X/G/c queue) are the way to remove the error, and it has not been done.
    - **A mean count is the mean.** Exact for the callee's load and the caller's mean time, not for the spread of the
      counts (section 6.3: unbiased within 2% over runs, single runs of a one-worker callee with heavy tails off by up to 10%).
      A count that varies because CLIENT spans were lost or sampled out looks the same as one that varies by request type.
    - **A mixture is exact in how many calls and as good as the spans in how they run.** Node.js writes span start times
      on whole milliseconds, so two calls that follow each other within a millisecond read as calls at once when read by the
      stamps; on the Demo's front end that made 44% of the visits of one endpoint (POST /api/cart, two calls in a row) look
      parallel. Such a caller is now read by where its callees' spans are (item 25); a callee with no spans, or a caller whose spans are not found to start
      on whole milliseconds, is read by the stamps, and the shape is then wrong in how the calls run, not in how many there are.
    - **More than 12 call shapes**, the rarer ones holding more than 5% of the calling visits, are still refused by name.
    - **In a service that fits the stage template, calls that start after the visit's span has ended on an edge that is
      not async (5-95% of them) are left out of the callee's load** (the template reads the calls within the span). This is
      how the template has always worked; in a mixture and in a mean count they are counted.
21. **Lost spans are told, not repaired.** The tool names what was lost and where (caller, address, service, share of the
    calls on the edge; [REQUIREMENTS.md](REQUIREMENTS.md#spans-that-were-lost)); it does not stitch a trace back together
    or guess a lost span. Limits:
    - **The 5% limit is on traces, not on a service's visits.** Broken traces that are all of one kind of request pass it
      while taking every visit of the services behind that request. On the Demo's shipped mix, before the nested spans
      were merged, 559 of 10,468 traces (5.3%: all the checkouts, a false alarm of the wrapper CLIENT span, item 19) held
      100% of the visits of checkout, payment, email, shipping and quote; a real loss of the same shape at 4.9% would
      have been used, and the model would have had no checkout at all. The tool now warns of, and marks, a service
      with a quarter or more of its visits in broken traces. It does not refuse (the 5% limit is the reference's and is
      kept). The size of the error such a capture gives is not measured.
    - **The callee of lost calls is read from the visits that were captured.** Its service time, queue and worker count
      are off if the lost spans are not typical. On the Demo's browse mix, with product-catalog's SERVER spans taken out
      of 2.2% of its calls at random, and of the slowest 5.0% (diagnostic cuts), the model's latencies moved by at most 0.01 ms
      (frontend 1.95, frontend-proxy 2.10-2.11, product-catalog 0.71 ms, as without the cut) and the callers' means they are
      compared with by at most 0.02 ms. That says little: the
      service is at 1.4% utilization with a 0.09 ms mean, where a lost span is worth nothing. At a busy service whose
      lost spans are its slow visits the error is not measured.
    - **An edge whose callee spans are all lost is an outside delay, not a loss.** The tool names what it can see of partial loss; when a callee has no SERVER
      span anywhere in the capture, calls to it are an `ext:` delay (with only the count of calls to services without server spans to say so), and when
      every outer span of a service is dropped the service becomes an entry. With 100% of a callee's spans dropped the Demo's shipped mix gave exit 0,
      `ext:currency`, and only that count; with the outer Next.js spans all dropped, 21,059 entry requests in 10,461 traces and 50.2 requests/s external (28.3 true).
    - **A lost span, a sampled-out span and a trace context that did not reach the callee look the same.** The message
      says which, as far as the traces allow, and no further.
    - **An entry that is also called.** A service most of whose visits have no caller in the capture is an entry, and a
      share of at least 5% called by captured services is warned about (the Demo's flagd: 77% of its visits come with no
      caller, 23% from the cart). The senders of the rest are not in the model, so a change of the service's time reaches
      the captured callers only. The rule that makes it an entry (most of its server spans have no caller in the
      capture) is the reference's and is kept; a span with no parent is a root, and nothing says whose call it was.

22. **The network time of a call (the hop) is read per edge, as the mean gap on a quiet callee and as the quietest tenth on a
    busy one** ([REQUIREMENTS.md](REQUIREMENTS.md#the-network-time-of-a-call)). The browse mix and the shipped mix of the
    Demo (item 19) gave levels 3-48% below what the callers' client spans measured (median 12% on the shipped mix), with the model's wait at 0.01 ms:
    the network time of a call has a spread (right-skewed: on frontend-proxy -> frontend, 7,641 calls, the gap is
    0.18 / 0.26 / 0.42 / 0.44 ms at the 10th percentile, the median, the 90th percentile and the mean; the top 1% of the gaps is 28% of
    the mean), the quietest tenth of the gaps lies one spread's mean below the mean network time on every call, and
    at 1% utilization nothing else carries the difference. The same constant is the repository's own demo's cache edge, which was
    2.5-3.6% low in all 12 windows of the Phase A runs (0.23 ms of excess that the model's wait does not explain, standard deviation 0.025, at 10-20% utilization;
    [accuracy-logs/hops.txt](accuracy-logs/hops.txt), section 3, holds 6 of the 12 windows, at 3.0-3.6% low).
    The rule is in `hops.go`: for each edge with 50 calls or more (else the callee's pooled calls) whose callee the model puts at
    most 30% busy, and whose model wait outside the span is at most three quarters of (mean gap - quietest tenth), the hop is the
    mean gap less that wait; otherwise it is the quietest tenth, as before. So the hop is never below the quietest tenth
    nor above the mean. Each call carries its edge's hop and a callee reached from several callers has the mean of its edges' hops by the calls
    each made (on the Demo, product-catalog is 0.39 ms from checkout, 1.10 from the front end and 1.08 from recommendation; one
    hop for the callee would charge checkout 0.6 ms too much).

    | capture (real, 2026-10-21) | service | err % before | err % now |
    |---|---|---|---|
    | browse mix, 420 s | frontend / frontend-proxy / product-catalog | -21.5 / -20.2 / -31.1 | +1.7 / +1.6 / 0.0 |
    | shipped mix, 420 s (13 services, 1% busy at most) | median / worst of the 13, absolute | 12.3 / 48.1 (product-catalog) | 0.1 / 2.3 (checkout) |
    | Phase A, 12 windows | cache (10-20% busy) | -3.6 to -2.5 | 0.0 (at one decimal) in all 12 |
    | Phase A, 12 windows | api, db, frontend (35-80% busy) | | unchanged to 0.01 point; the hop stays the quietest tenth |

    On the simulator with a hop jitter (each network leg 0.15 ms plus 0.05 / 0.1 / 0.2 ms of a gamma-distributed extra), a chain of three
    services 3% busy has its level -6.0 / -11.2 / -19.8% off before and 0.0% now, with the hop found within 1% of the true mean. The
    accuracy harness (TestEndToEndAccuracy, ACC_STRUCT=1, seeds 305-307, both span modes, 64 paired replications of the truth;
    its busiest service is at 70-80% utilization and every callee is more than 30% busy: on seed 305, 91 edges, the least busy callee
    at 31%) gives every line, and the whole log of its large rows, as it did before (`accuracy-logs/hops.txt`), with the constant network time and with a hop
    jitter of 0.1 ms per leg (ACC_HOPJIT=0.1) alike, because the rule does not engage on any of its edges. It engages on callees of a
    millisecond or two at low load, as on the Demo; the harness does not cover them, the chain above does.
    Limits:
    - **The agreement on the Demo is fitted, not predicted.** A model fitted on one window and set against what the callers measured in
      another window of the same capture is as far off as one window's callers' means are from another's, the noise floor
      (shipped mix, 210 s windows: 5.8% against 5.8%; 140 s: 6.6% against 6.4%; 60 s: 7.1% against 6.4%; browse, 210 s: 4.6% against 4.5%):
      at 1% utilization the model adds nothing to the window's means. Do not quote the in-sample 0.1-1% as a prediction accuracy. What is independent is in
      section 9.
    - **The mean branch is not a check.** On a leaf the model's latency plus this hop equals the callers' client-span mean by
      construction (hop = mean gap - model wait), so the err % of a service that took it ("hop from the mean" under the table) says
      nothing about the model there; what is independent is the hop itself where the truth is known (the simulator's), the
      non-leaf rows (the front end, checkout) and the rows that did not take the branch.
    - **Above 30% utilization the hop stays the quietest tenth** and the spread of the network time (0.1-0.3 ms per call on the
      Demo) stays unmodelled. The limit is the guard against a wait the model does not show being read as network: without it, in the
      accuracy harness (seeds 305-307, both span modes, 48 rows each, true network time 0.3 ms), 8 of the 288 inferences took a mean-based
      hop more than 1 ms above the quietest tenth at a callee 32-77% busy, up to 17.7 ms (that is queueing), and the change error rose
      in 4 of the 6 runs (the structure family on seed 306: 90th percentile 20.9 to 25.2% of the change; the worst structure row on seed 307:
      23.5 to 28.8%; some other lines improved, the worst refined level on seed 305 went from 12.5 to 6.8%, which is the hop absorbing a wait the
      model understates); with the limit the 6 runs are unchanged.
    - **At or below 30% a wait the model does not show lands in the hop.** Four calls at once to a one-worker callee at 29% utilization
      (the batch of item 20) gave a hop of 20.6 ms (the simulator's network time is 0.3 ms): the model reads the caller 20% too fast
      instead of 60%, and a warning says that the hop holds more than a network's spread. A change of that callee's service time does not move the
      part of the wait that is in the hop.
    - **A change is not helped by this.** The hop is added to a call, so the predicted change of a service's latency does not depend on it
      except through the maximum of a parallel fan-out; the change rows of the harness are the same to the digit (the predictions of a +3 ms change at `api` on five of the six Phase A windows before it differ by at most 0.004 ms at the entry; the sixth is past the
      utilization limit with it).
    - **The utilization is the model's, from the worker count.** A count that is a lower bound (spans that start at service) overstates it, which
      only keeps the quietest tenth.
    - **The 0.75 share and the 30% limit are hard switches, set on these captures.** On the 12 Phase A windows the cache edge has the model's
      wait at 0.16-0.53 of the excess, the browse edges at 0.00-0.03 and the loaded edges (api, db) at 0.95-1.41. A smooth switch (the excess less twice the
      wait) did worse on the cache edge (-0.7 to -3.0%). Callers over a network with a much larger spread (a wide-area link) have not been seen. The switch at 30% is a cliff
      (a chain at 29% busy reads 0.0% off, at 35% 2.9% off, as before the rule); a ramp between 25% and 35% was considered and not made.
    - **rbfast (`rust/`) does not have it:** its hops are the shipped quietest tenth, per callee, so on a quiet capture it reads 20-48% low, as the Go
      binary did.

23. **After a change of a service's time, the next service's wait is over-predicted on the real cluster, and item 22 does not touch it.** In the
    repository's demo on the real cluster (2026-10-21; the three levels of the validation, two windows each, before and after +ms of CPU in `api`), the
    model reads `db` +3.8 to +8.7% high in all six windows after the change (L1 +8.7 / +3.8, L2 +4.8 / +4.0, L3 +7.6 / +4.2) and -1.1 to +1.6% in the six before
    it. `api` is +5.5 / +7.8% in the two L3 windows after it, but +4.6% in L3's first window before it, so that one is the level's load (75% busy), not the
    change. These rows take the hop as the quietest tenth, before and after item 22 (their errors moved by at most 0.025 point), so the hop is not the cause. A
    service after a slowed `api` sees a smoother stream than the model's (the arrival weight of 0.7 is an empirical damping: item 8 and section 5.2), which would
    explain part of it; how much is not attributed here. It is why the predicted change of a downstream service on this cluster is read with the error of its level
    in the after state in mind.

24. **Server spans that are streams are refused, not repaired** ([REQUIREMENTS.md](REQUIREMENTS.md#streams-and-other-long-server-spans)). A SERVER span that lasts
    at least a second, a tenth of the capture's duration and a thousand times its service's median is taken for one, and a capture in which such spans hold 5% or more of
    a service's busy time is refused. The three thresholds were set on one case (flagd's `EventStream`, 600 s against a median of 0.07 ms, 100% of its busy time), with the Demo's whole shipped
    file (856 s) as the check that nothing else trips them (no other service has a SERVER span above 0.2% of it; the longest is 1.99 s); no study of what else
    stays open in other systems has been made. A real request that is slow, one in a capture, holds a share of its service's busy time that grows with how many such
    requests there are: one that is a tenth of the capture and a thousand medians long passes the test, and is refused when it is 5% of the service's time. The refusal has no override: the window is cut again, or the spans dropped.
    Below 5% the spans stay in the means (and are warned of): a stream that is 4% of a service's busy time moves its mean by about 4%. Streams that are not SERVER spans (a long CLIENT span) are not looked for.
25. **Calls of a caller whose spans start on whole milliseconds are read by where their callees' spans are** ([REQUIREMENTS.md](REQUIREMENTS.md#clocks-and-client-spans)).
    Found on the Demo's front end (Node.js: 100% of the span starts are whole milliseconds). The change a +1 ms patch predicts at the entry, against a replay of the traces that
    has no model in it (tolerance 0 to 1 ms for how far apart two spans may be and still follow one another): cart 0.463 before, 0.539 now (replay 0.446 to 0.539), the cart's cache calls 0.817 and
    0.942 (0.806 to 0.942), product-catalog 0.717 and 0.747 (0.692 to 0.840); the other services' changes are unchanged. Limits:
    - **The front end's level moved from -0.1% to +2.3%** (+1.7 to +2.7% over the Demo's cuts of 60 to 210 s, +4.0% in one 60 s cut). The misread shapes (calls in a row read as at once)
      were too fast, and had been offsetting a charge that is too high. Part of that is checked: one hop per edge charges a lone call and each call of a group the same mean time, and from the
      front end to the catalogue a lone call's client time less its server time is 0.96 ms (4,241 calls), each of four made together 1.27 ms (3,364), the edge's mean 1.10 ms; that is about
      half of the 0.10 ms. The rest is not attributed (a likely part: Node's client spans read about half a millisecond long because their starts are early; not separated out). The shapes
      are right now and the level is not; the predicted *change* is the quantity the tool is for.
    - **The calls are told apart by a gap of a quarter of the round trip's overhead between the callees' spans.** The quarter is the knee of a sweep on this data (at 0.25, 1,730 of 1,731 "cart, cart" visits and 786 of 794 recommendation
      visits are read in a row; at 0.5, 1,722 and 784; at 1.0, 490 and 55). It was set on one runtime and one Demo.
    - **A callee that stamps on whole milliseconds too** (a Node.js callee) has a start that is up to a millisecond early, so the gap between two calls to it is read too short. The Demo has no such pair of calls. A callee without a SERVER span is read by the stamps.
    - **The pod must be found from its spans:** at least 100 spans, at least 99% on whole milliseconds. A Node.js pod that is quiet, or whose exporter rounds some spans another way, is not found, and is read as before.

## 2. Where the error came from: the diagnosis, step by step

On 2026-10-19 six independent diagnoses, each checked again by a second, independent review, followed the error through each
step of the pipeline. Two rounds of fixes and checks followed. A check round is a set of independent checks
of the code and the numbers (re-runs of the studies on fresh seeds, a code review, a docs check) whose failures the
next commits fix; section 3 lists each round's commits.

### 2.1 Model arithmetic: no error

An independent hand calculation (math, numpy, scipy) reproduces the Go model to 5.7e-14 ms or better (1.1e-6 ms for the
correlated maximum). The reference's basic model equals Go's basic model exactly on the true topologies.
Validation repeated this with glue and replica shares: 1.1e-13 ms or better, except the correlated gamma maximum at a
stage node, which agrees to 1.3e-7 ms (check round 2).

### 2.2 Inference

- **Spans that start at service (the old default figures).** Go read each capture's own sample exactly: on all 240
  holdout rows the model on the inferred topology was within 0.11% (level) and 0.25% (change) of the model on the
  capture's realized sample. The large errors were:
  - the sampling noise of one 400 s capture, amplified 2-7 times at rho 0.76-0.84;
  - noise in the harness's truth (item 2.3);
  - the model term of item 2.5.
- **Spans that include the wait: a real inference defect.** The earlier estimator (`rise`) read the service time
  and cs2 only from visits that found a free worker. At rho 0.70-0.78 that is 22-30% of the visits, which made the
  entry latency about 1.8 times noisier. The worst row (-18.3%) was this: the loaded service's time was read 3.4% low,
  cs2 2.73 against 2.96 in the capture. The reference rebuilds each pod's FIFO queue and reads every visit. The port of
  that rebuild (section 6) took that row to -3.2%.
  - Over 8 fresh seeds (check round 1), the refined level went from 2.7 / 9.3 / 35.1% to 2.0 / 5.9 / 14.4%.
  - Here, over 288 rows, the earlier estimator gives 3.0 / 8.6 / 16.6% and a worst change of 14.7% of the latency,
    against 2.0 / 5.9 / 12.5% and 7.5% with the rebuild (section 4.5).
- **Spans that start at service: no change.** The round-1 commits moved the default-mode numbers by nothing measurable:
  236 of 288 rows were within 0.05 point.

### 2.3 The harness

The old harness gave numbers that were both noisier and more favourable than the code deserved:
- every row used capture seed 5150 (its arrival count is +0.38% high on average) and truth seeds 1001-1016, so the
  "8 seeds" were not independent;
- 16 replications put the truth's standard error at up to 3.2% (level) and 6.5% (change); the -18.3% row's truth alone
  read 1.8-1.9 standard errors high;
- the fan-out rows were the same 6 on every seed, which is where "basic worst 16.8% on every seed" came from.

The harness now gives each row its own block of seeds, runs 64 paired replications (the base and the change on the
same seeds), measures the branch correlation in the truth's runs, and prints z against the truth's and the capture's
noise combined (section 11).

### 2.4 The Python reference's own limits

The reference was ported where it is right: the queue rebuild, glue, broken traces, probes, the stage template, the
thresholds and the cs2 snap. Go keeps its own way where the reference is measurably worse:
- **Spans that start at service.** On such captures the reference books the worker wait as network time, counts it
  twice and reads random routing as power-of-two-choices: +30 to +50% on the level and -35 to -45% on the change.
- **The model.** The reference's model has Poisson arrivals everywhere (Go's `--plain`), which
  is worse at 70-80% (level 90th percentile 6.3% against 2.7% at true parameters).
- **The change.** Its change computation keeps cs2, so it treats a constant extra time as a scaling. That
  over-predicts a constant change: by 8-32% against the same model with a constant shift (one diagnosis and the
  summary of all six), by +14 to +29% on check round 2's rows, and by +14 to +50% against the simulator's truth
  (another diagnosis).
- **What it has no form for.** It cannot express replica shares (row 39 of check round 1: an even split gives
  -16%), branch correlation, or a constant-shift change.
- **Design differences, neither side wrong.** The reference trims 2% of the window at each end; Go reads every visit,
  which moved one row's level by 2.5% within the trim's noise. Go took the hop as the 10th percentile of the
  client-minus-server time; the reference takes the mean (0.02-0.09 ms per call on the test bed). Go now takes the mean less
  the model's wait on a callee that is at most 30% busy, per edge, and the 10th percentile above that (item 22 of section 1).

### 2.5 What is left is mostly the model

With the true parameters the refined model still misses beyond the truth's noise on many rows (section 4.3). The terms
found are items 2 and 4-8 of section 1. A constant arrival weight cannot fit both a change at the upstream and one at
the loaded service, nor both a smooth and a bursty upstream. Two attempts tried to replace it or correct the stream
(item 2 of section 1); neither passed its declared bars.

## 3. What was fixed

Round 1 is 15 commits, d33e41c..29a7ed9; round 2 is 7 commits, 02826cb..2349b17. Round 2's regression tests are
built from the failing inputs of the validation checks, and each fails at 29a7ed9. The code review of round 2 led to
three more commits (ed44f6a, 22e1886, d13cde7; last rows of the table), and the review of those (check round 3:
a code review and a docs check) to one more (53b5068: async calls).
On what was re-run after them, nothing moved: TestEndToEndAccuracy on seeds 305 and 306 (both span modes, at 53b5068)
gives every line of the 2349b17 logs, and the test-bed reports are byte-identical. The other studies were not re-run;
their scenarios have none of the shapes these commits touch.

| area | what changed | measured effect |
|---|---|---|
| Queue rebuild (77e6b8d) | each pod's FIFO queue rebuilt from the spans; workers and service time from every visit | spans that include the wait: section 2.2; the worst row -18.3% to -3.2% |
| Glue (6171ceb) | own time after the first call out holds no worker; modelled as a delay after the calls | glue 3 ms: before the fix +3.8% level and +58.5% change at the service with glue; now as without glue (section 6.1) |
| Broken traces, upstream callers (42bc598, 42ad960, a1ca086) | a lost span leaves its trace out of the call structure; above 5% the capture is refused; an entry whose caller is outside the capture (ingress, gateway, browser) is an entry | before: a lost caller made its callee an entry (db at 14.8/s on a real capture); a capture with an upstream caller is no longer refused (3000 of 3000 traces read as broken before) |
| Probes (42bc598) | health and readiness spans dropped by the reference's rule | 26 routes decided as the reference does |
| Stages, call counts (42bc598) | 95% / 5% overlap thresholds, the reference's stage template, exact k or k + 1 calls | a staged service read as one fan-out was off by -28% to +17% on the level (section 6.2) |
| cs2 snap (0412f1f) | cs2 within 3 standard errors of 1 taken as 1 | medians moved by at most 0.4 point |
| Uneven split (fc08cb9) | shares per replica when an even split is ruled out | item 9 of section 1 |
| Release clip, consumers (02826cb) | the worker release is clipped to the span; a CONSUMER span's calls are its own; clock skew named | an async call after the response: 1 x 5 workers and +54% level before, 1 x 1 and +2.6% now; a message consumer read as 1 x 4 and +95% before |
| Worker identification and search (4bc2fd7) | identified only when the waits are long enough to show a shortfall; search jumps refuted counts | an unbounded pool: 236 identified became 236+ (a lower bound); the CLI on that capture 2.18 s to 0.86 s |
| Numerics (d33e41c, f8f39fb, 21113f8, 8cb7c0b, 2349b17) | kernels in `internal/mathx` with reference values; Erlang C overflow; normal quantile tail; a matched maximum that resolves every branch; weights outside [0, 1] refused | E[max] error 5.0e-9 to 7.3e-15 on realistic cases; a heavy branch beside a narrow one 5.7e-4 to 1.2e-12; no NaN reported as stable |
| Reproducibility (00342f3, cce7d3c) | deterministic order; sums grouped by the capture, not the core count | `infer` byte-identical at GOMAXPROCS 1 and 8 on the test-bed capture |
| CLI (9a03301, 2b1d843) | non-finite flags refused; `+N%` scales the glue too; `--workers` used on a rare service; write errors fail | `predict > /dev/full` exited 0 before |
| Harness (9920f80) | own seeds per row, 64 paired replications, measured branch correlation, z | section 2.3 |
| Kind test (5543352, 29a7ed9) | no keep-alive, every pod restarted per window, interleaved rounds, gates | section 7 |
| Async calls (ed44f6a, 22e1886, 53b5068) | a call is not waited for when it starts after the caller's span has ended or, on the caller's clock, ends after it; an edge where at least 95% are not waited for is async (it loads the callee, off the caller's path), and its waited calls stay on the path; 5-95% stay on it with a warning; the warnings name the callee's clock when it times the calls | the code review's async-int capture: fe's level +260.8% to -1.8%; +100 ms at the callee moved fe by +34.92 ms, now 0; ff-pre-0.05 +214.7% to -2.7%; mixedb-0.96 workers 2 to 1 and the change +3.21 to +4.81 ms (truth +4.6 to +4.9) (item 11 of section 1) |
| Upstream callers, consumers (ed44f6a) | a SERVER span with no parent in the capture is an entry when more than half of its service's server spans have no captured caller (and no captured top is in the trace); CONSUMER spans likewise, counted apart in the header; the refusal counts its causes | a gateway calling two services or retrying one, and a service called on a few of its visits, were refused as lost spans and now read; up-lost still counts its 64 of 2000 traces (item 17) |
| Lower-bound refusals (ed44f6a), `model` (d13cde7) | a load past `--max-rho` or 100% is refused naming the service, its utilization and, for a lower-bound worker count, `--workers`; `model` applies `--max-rho` and `--out` | the code review's unbounded pool: "the change makes the system unstable" (+20 ms) and a refusal with no hint (+10 ms) became messages that name fe and its utilization (85.6% at +1 ms to 101.7% at +20 ms) and point to `--workers` (item 11) |
| Matched maximum (ed44f6a) | capped at the sum of the branch means | 91 of the code review's 2016 grid cases (branch scv of 1e6 or more) and one CLI patch (9.905 against 8.75) passed it before |

## 4. The whole pipeline, seeds 301-308

`TestEndToEndAccuracy` (summary lines) and `TestEndToEndAB` (per row: both span modes, both estimators and the true
parameters), 64 paired replications of 400 s per row. Median / 90th percentile / worst |error|; the change in % of
the change and in % of the latency; "z" is the share of rows whose error exceeds 3 combined standard errors.

### 4.1 Per seed (spans that start at service; the other mode gives the same lines to 0.1)

| seed | refined: level | change | % of latency | z level / change | basic: level | change | % of latency | z level / change |
|---|---|---|---|---|---|---|---|---|
| 301 | 1.9 / 6.3 / 9.4 | 6.6 / 18.3 / 34.0 | 0.64 / 2.03 / 4.73 | 3 / 25% | 2.9 / 7.8 / 19.6 | 13.7 / 23.9 / 41.2 | 0.91 / 2.17 / 5.26 | 11 / 39% |
| 302 | 1.8 / 5.6 / 9.4 | 4.7 / 14.0 / 35.5 | 0.49 / 2.00 / 3.37 | 0 / 25% | 3.0 / 8.3 / 22.7 | 9.4 / 23.2 / 32.4 | 0.66 / 2.60 / 3.04 | 17 / 39% |
| 303 | 2.6 / 4.8 / 9.1 | 6.1 / 12.7 / 33.0 | 0.37 / 2.34 / 3.09 | 3 / 14% | 3.3 / 10.1 / 18.0 | 9.1 / 18.6 / 49.7 | 1.05 / 2.05 / 2.99 | 22 / 36% |
| 304 | 1.7 / 3.6 / 10.7 | 4.9 / 15.2 / 20.7 | 0.15 / 0.96 / 3.55 | 3 / 19% | 2.3 / 9.5 / 26.6 | 11.9 / 25.9 / 39.3 | 0.39 / 1.50 / 3.79 | 14 / 58% |
| 305 | 2.1 / 5.1 / 12.5 | 4.9 / 12.5 / 16.8 | 0.31 / 2.00 / 2.59 | 3 / 25% | 3.9 / 10.5 / 27.1 | 7.8 / 21.0 / 24.9 | 0.37 / 1.96 / 3.32 | 14 / 42% |
| 306 | 2.4 / 4.9 / 9.8 | 7.6 / 17.6 / 27.4 | 0.58 / 2.40 / 7.52 | 3 / 19% | 3.2 / 11.0 / 19.3 | 9.4 / 25.2 / 43.6 | 0.79 / 2.50 / 7.08 | 11 / 33% |
| 307 | 2.7 / 8.7 / 12.2 | 6.2 / 16.8 / 21.6 | 0.67 / 2.10 / 6.38 | 11 / 19% | 3.3 / 10.4 / 29.7 | 8.4 / 23.1 / 30.2 | 0.67 / 2.76 / 5.25 | 14 / 31% |
| 308 | 2.1 / 4.2 / 8.1 | 5.3 / 12.0 / 18.7 | 0.45 / 2.30 / 3.56 | 0 / 8% | 3.3 / 10.6 / 27.1 | 6.0 / 20.9 / 27.0 | 0.59 / 1.85 / 4.09 | 22 / 25% |

No row was skipped or left unscored, in either mode or model.

### 4.2 Pooled, by family, against the same rows with the true parameters

| family (rows) | model | inferred: level | change | % of latency | true parameters: level | change | % of latency |
|---|---|---|---|---|---|---|---|
| holdout (240) | refined | 1.9 / 5.6 / 12.5 | 5.9 / 16.2 / 35.5 | 0.29 / 2.01 / 5.96 | 0.8 / 3.1 / 7.1 | 3.5 / 12.4 / 38.4 | 0.20 / 0.86 / 2.40 |
| | basic | 2.6 / 7.3 / 12.5 | 9.8 / 24.4 / 49.7 | 0.52 / 2.05 / 6.81 | 1.2 / 5.1 / 11.5 | 7.4 / 24.0 / 46.2 | 0.34 / 1.14 / 4.16 |
| fan-out (48) | refined | 2.4 / 6.0 / 9.4 | 5.4 / 18.7 / 34.0 | 0.96 / 2.87 / 7.52 | 1.6 / 2.8 / 3.5 | 2.5 / 5.7 / 7.4 | 0.46 / 0.79 / 1.33 |
| | basic | 10.4 / 22.7 / 29.7 | 5.7 / 17.8 / 41.2 | 1.18 / 2.99 / 7.08 | 10.0 / 26.1 / 27.6 | 3.3 / 9.5 / 14.6 | 0.72 / 1.38 / 1.89 |
| structure (96) | refined | 2.0 / 6.5 / 10.4 | 4.7 / 16.6 / 79.9 | 0.17 / 1.05 / 4.61 | 0.9 / 2.7 / 6.6 | 3.3 / 13.9 / 85.5 | 0.14 / 0.52 / 1.95 |
| | basic | 2.3 / 6.1 / 12.8 | 10.5 / 29.0 / 92.6 | 0.37 / 1.42 / 4.71 | 1.1 / 4.0 / 10.0 | 7.1 / 25.1 / 85.9 | 0.30 / 0.76 / 2.60 |

The structure family's 12 rows per seed are 3 each of glue, staged calls, conditional calls and an uneven split over
2-3 replicas. Each kind is run in both span modes, and each row is read in its own mode. Refined, by kind (24 rows
each):

| kind | inferred: level | change | % of latency | true parameters: level | change |
|---|---|---|---|---|---|
| glue | 1.9 / 4.3 / 9.3 | 3.6 / 8.7 / 16.3 | 0.13 / 0.31 / 0.71 | 1.1 / 2.2 / 3.2 | 4.8 / 9.7 / 18.6 |
| staged | 2.8 / 7.2 / 9.0 | 10.4 / 39.1 / 79.9 | 0.27 / 0.87 / 2.24 | 1.2 / 3.1 / 6.6 | 7.5 / 38.0 / 85.5 |
| conditional | 2.5 / 5.6 / 10.4 | 6.9 / 14.0 / 17.1 | 0.15 / 0.78 / 1.94 | 0.6 / 2.4 / 3.6 | 3.3 / 6.9 / 15.8 |
| uneven | 1.4 / 5.8 / 8.8 | 4.2 / 10.9 / 17.9 | 0.43 / 2.05 / 4.61 | 0.8 / 2.1 / 4.2 | 1.6 / 5.2 / 6.0 |

### 4.3 Where the refined model is and is not better

- **Paired on the 288 rows.** Refined is closer than basic on 174 rows and further on 87 (level, ties within 0.05
  point). For the change in % of the latency it is closer on 181 and further on 86. With true parameters it is closer on
  197 and further on 76 (change, ties within 0.1 point).
- **Better.** Fan-outs (level 10.4 to 2.4% median), the change in general (median 9.1 to 5.6% of the change), and the
  level tail (worst 29.7 to 12.5%).
- **Not better.**
  - Single queues and Poisson-fed services: identical by construction.
  - The change behind a regular upstream (item 8 of section 1).
  - A later sequential call behind a smooth first callee: median +11.1% (refined) against +9.5% (basic) at true
    parameters. Behind a bursty one it is better: -12.6% against -16.8%.
  - The structure family's level 90th percentile: 6.5% against 6.1%.
  - The worst fan-out change in % of the latency: 7.52% against 7.08%.
  - The test bed's change, where `auth`'s arrivals are nearly Poisson (section 8): identical.
- **The model's own error is real but small.** With true parameters the refined model exceeds 3 of the truth's
  standard errors on 38.9% of the rows (level) and 45.5% (change); the basic model on 52.8% and 60.1%. On the refined
  model's missed rows the median error is 2.2% of the level and 6.6% of the change (1.0% and 3.3% over all rows). The
  truth's standard error is often a few tenths of a percent, so read z next to the error.

### 4.4 Rows to look at

- **Change error beyond 3 combined standard errors: 56 of 288 rows.** On 50 of them the true-parameter model makes an
  error of the same sign and at least half the size. Six are 1% of the latency or more:
  - four fan-outs at rho 0.70-0.78 (+2.5 to +7.5% of the latency; true parameters +0.3 to +0.9%). Their error comes
    from the inputs, but by more than the input noise the standard error covers. The likely cause is the branch
    correlation read from the one capture, which that standard error leaves out (section 11) and the PAR lines do
    not print; this is unverified. On one of them (seed 307, row 34) the true-parameter model is itself beyond 3 of
    the truth's standard errors (+0.89% of the latency, z +5.4);
  - two later sequential calls (seed 302 row 14 and seed 306 row 8: -2.0% and -1.5% of the latency, the same at true
    parameters), which are model error (item 2 of section 1).
- **Level error beyond 3 combined standard errors: 9 rows**, all over-predictions (+5.1 to +12.2%). On five the
  true-parameter model is already +3.1 to +4.7% off (three later sequential calls, a chain, a fan-out). On the other
  four it is -1.3 to +2.1%, so most of their error comes from the inputs, though by more than the input noise the
  standard error covers (three of the four are the fan-outs above).
- **Change error of 2.5% of the latency or more: 21 rows**, every one a change at the loaded service (a fan-out's
  slowest branch, or a service behind or across replicas), from +7.5% to -6.0% of the latency. At true parameters 20
  of them are within 1.5% of the latency. The remaining one, seed 304 row 11, is -2.40% there against -3.55%
  inferred, so it is mostly model error. 18 of the 21 are within 3 combined standard errors; the other three are
  fan-outs of the first item above.

### 4.5 Spans that include the wait: the earlier estimator against the queue rebuild (rows 0-35, pooled)

| estimator | model | level | change | % of latency | z level / change |
|---|---|---|---|---|---|
| `rise` (free-worker visits) | refined | 3.0 / 8.6 / 16.6 | 7.0 / 20.7 / 61.7 | 0.49 / 3.17 / 14.72 | 8.0 / 22.2% |
| queue rebuild (default) | refined | 2.0 / 5.9 / 12.5 | 5.6 / 16.3 / 35.5 | 0.42 / 2.26 / 7.52 | 3.1 / 19.4% |
| `rise` | basic | 4.0 / 12.5 / 30.4 | 10.5 / 26.3 / 63.8 | 0.60 / 3.48 / 15.22 | 21.9 / 41.3% |
| queue rebuild | basic | 3.1 / 10.5 / 29.7 | 9.1 / 24.2 / 49.8 | 0.60 / 2.55 / 7.08 | 15.3 / 37.8% |

## 5. The model given the true parameters

These tests use fixed scenario families. `ACC_SEED` only draws the truth's replications (and, for TestHoldout, the
family). The spread over seeds 301-308 is therefore the truth's own noise. Each cell gives the range over the 8 seeds.

### 5.1 TestAccuracy: 32 scenarios at about 70%

Most scenarios run the busiest service at 0.70 and the changed one at 0.77 after the change. The fan-outs run at 0.66
(0.75 after), and one chain's busiest service is at 0.60, with the change at a service at 0.40 (the test's own header
line says ".70 and .77"). Truth: 64 x 500 s. Median / worst |error| %, with both load levels pooled for the level.

| group | level, basic | level, refined | change, basic | change, refined |
|---|---|---|---|---|
| chains (4) | 3.1-5.4 / 17.0-18.0 | 0.5-1.2 / 6.2-7.0 | 1.9-4.6 / 24.0-26.7 | 3.7-5.5 / 4.8-8.5 |
| fan-out (3) | 7.7-10.1 / 18.8-20.0 | 0.8-2.1 / 2.2-3.2 | 7.5-12.3 / 11.0-15.4 | 2.1-5.9 / 5.0-9.7 |
| replicas (2) | 0.1-0.5 / 0.1-0.8 | same | 0.2-1.8 / 0.2-1.8 | same |
| single c = 1 | 0.3-0.9 / 0.8-3.1 | same | 0.6-1.5 / 1.4-5.5 | same |
| single c = 2 | 0.5-1.1 / 2.7-6.1 | same | 0.3-1.5 / 0.8-2.9 | same |
| single c = 4 | 0.7-1.1 / 5.4-7.1 | same | 0.7-1.3 / 2.1-5.4 | same |
| single c = 8 | 0.6-0.8 / 4.6-5.9 | same | 1.6-2.1 / 6.5-9.1 | same |
| shifted exponential | 0.2-0.8 / 0.3-1.4 | same | 0.5-1.2 / 0.7-2.6 | same |
| **all 32** | 0.5-0.9 / 18.8-20.0 | **0.5-0.8 / 6.4-7.1** | 0.9-1.5 / 24.0-26.7 | **0.8-1.5 / 7.4-9.7** |

A single queue sees Poisson arrivals, so the refinements change nothing there. In the chains the refined change has a
higher median than the basic one (3.7-5.5 against 1.9-4.6) and a far lower worst (4.8-8.5 against 24.0-26.7).

### 5.2 TestChainDamping: 360 chains a -> b, the arrival weight swept

Truth: 64 x 400 s. Median / 90th percentile / worst |error| %.

| change in | w | level | change |
|---|---|---|---|
| first service | 0 (basic) | 2.3-2.4 / 7.7-8.3 / 16.7-18.6 | 17.3-18.3 / 31.6-32.6 / 56.4-59.0 |
| | 0.50 | 1.2-1.4 / 4.4-5.0 / 9.8-11.7 | 8.9-9.6 / 16.7-17.4 / 33.0-35.1 |
| | 0.65 | 1.0-1.2 / 3.4-3.9 / 7.8-9.6 | 6.5-7.2 / 13.3-14.0 / 25.9-28.0 |
| | 0.80 | 0.9-1.1 / 2.9-3.2 / 6.1-7.6 | 4.7-5.1 / 10.2-10.9 / 18.9-20.8 |
| | 1.00 | 0.8-0.9 / 2.4-2.7 / 4.8-5.7 | 4.4-4.9 / 9.7-10.3 / 13.5-15.3 |
| second service | 0 (basic) | 2.3-2.4 / 8.5-9.2 / 20.2-21.6 | 2.5-2.7 / 16.7-18.8 / 45.9-47.0 |
| | 0.50 | 0.9-1.1 / 4.4-4.9 / 10.1-11.6 | 1.4-1.8 / 5.6-6.8 / 18.2-19.4 |
| | 0.65 | 0.9-1.1 / 3.2-3.5 / 8.0-9.1 | 1.9-2.3 / 4.8-5.7 / 10.5-12.3 |
| | 0.80 | 0.8-1.0 / 2.6-3.0 / 6.0-7.0 | 2.5-2.8 / 6.1-6.9 / 10.0-12.3 |
| | 1.00 | 0.8-0.9 / 2.5-2.8 / 6.1-7.1 | 4.5-5.0 / 10.3-10.9 / 14.8-18.0 |

The sweep has no 0.70 column; the default sits between 0.65 and 0.80. A change in the first service wants a weight near
1, and a change in the second 0.5-0.8. The median change error in the second service is about the same with no
weight at all (2.5-2.7%); the gain is in the tail.

### 5.3 TestFanOut: 32 fan-outs (2-3 branches, four service laws, 70% and 78%)

The change is in the slowest branch (b) or a shorter one (c). Median / 90th percentile / worst |error| %. For c the
percentages are of a small change; the absolute errors are in item 4 of section 1.

| model | level, b | level, c | change, b | change, c |
|---|---|---|---|---|
| basic | 7.4-8.7 / 17.0-18.2 / 26.8-27.6 | 8.9-10.0 / 19.0-19.9 / 29.0-30.1 | 3.5-5.9 / 7.0-9.9 / 8.4-13.7 | 61.5-65.4 / 113.9-123.6 / 153.1-163.0 |
| gamma maximum | 6.4-7.1 / 12.1-13.3 / 16.8-18.0 | 7.4-8.0 / 13.3-14.6 / 18.9-20.1 | 2.1-3.3 / 4.2-6.5 / 5.7-8.3 | 44.7-48.4 / 93.6-102.2 / 120.6-129.3 |
| + measured correlation (default) | **1.3-1.8 / 2.3-3.1 / 3.0-4.0** | **1.5-2.0 / 3.2-3.5 / 4.2-4.9** | **2.1-3.3 / 3.6-5.9 / 5.0-7.2** | 25.6-30.2 / 45.1-48.7 / 51.3-57.7 |

### 5.4 TestHoldout: 60 random scenarios per seed

Three-service chains, a service calling two others one after the other, and a chain into two replicas. Six service
laws, 70-78%, no fan-out. The family is drawn by the seed. Its first 30 rows are the end-to-end holdout rows of the same
seed, with the same truth. The weight was chosen on the chain sweep, not on this table. Median / 90th percentile / worst
|error| %; the level pools the base and the changed state.

| w | level | change | change, % of latency | z level / change |
|---|---|---|---|---|
| 0 | 0.9-1.9 / 3.6-7.7 / 8.3-19.0 | 5.3-9.5 / 20.7-26.1 / 32.5-69.6 | 0.25-0.50 / 0.81-1.22 / 1.75-4.16 | 37-58 / 57-68% |
| 0.50 | 0.7-1.3 / 2.5-4.5 / 4.1-8.7 | 3.1-4.9 / 9.8-15.3 / 22.3-43.7 | 0.12-0.29 / 0.63-0.94 / 1.34-2.21 | 23-48 / 43-63% |
| 0.65 | 0.7-1.2 / 2.2-3.6 / 3.9-8.6 | 2.8-5.9 / 9.3-14.2 / 18.4-43.7 | 0.13-0.26 / 0.66-0.91 / 1.45-2.59 | 18-42 / 43-65% |
| **0.70 (default)** | **0.7-1.1 / 2.1-3.5 / 4.2-8.6** | **2.5-5.7 / 9.5-14.9 / 20.1-43.7** | **0.14-0.25 / 0.66-0.96 / 1.48-2.72** | 20-43 / 45-63% |
| 0.80 | 0.7-1.1 / 2.3-3.2 / 4.6-8.8 | 3.0-5.6 / 11.0-15.9 / 21.7-43.7 | 0.16-0.29 / 0.70-1.05 / 1.51-2.98 | 22-43 / 45-62% |
| 1.00 | 0.8-1.2 / 2.7-3.8 / 4.6-9.3 | 3.0-6.7 / 12.7-21.0 / 28.1-43.7 | 0.18-0.31 / 0.76-1.45 / 1.72-3.82 | 32-47 / 47-70% |

Between 0.5 and 0.8 the error is flat, so the choice of 0.7 is not sharp, but it is not derived either.

## 6. How a capture is read

### 6.1 Workers, service time and glue

Each pod's first-come-first-served queue is rebuilt from the spans, as in the reference (`internal/infer/fifo.go`):
- A visit arrives at its span's start and frees its worker at its first call out, clipped to the span, or at its end.
  A call sent after the response frees nothing before the end. One that seems to start before the span frees it at
  the start. Above 1% of a service's visits a warning names the cause (clock skew between pods, or a CLIENT span on
  the pod's own clock) and which way the reading moves, from a rebuild with those calls skipped (item 11 of
  section 1).
- For c workers, that fixes when each visit started service, so its wait is known.
- The count is the smallest c whose queue passes two tests. First, no more contradictions (service times below -0.25
  ms) than 2% of the visits it makes wait (at least 3). Second, no shortfall: the visits it makes wait must not have
  service times significantly (z < -3) and materially (> 10%) shorter than the others'.
- The count is **identified** once at least 100 visits waited at it (the reference's rule) and their mean wait would
  fail that shortfall test had it been invented: at least 10% of the others' mean service time and 3 standard errors.
  The second condition is not the reference's. Otherwise the count is a lower bound.
- The search jumps over counts the contradictions alone refute. Contradictions and waits only fall as workers are
  added, so it gives the reference's count without a rebuild at every count.
- One test is added to the reference's. When fewer than 30 visits wait longer than 0.25 ms, the shortfall test also
  runs over every visit that waited at all. Without it, a service faster than 0.25 ms reads as one worker with its time
  30% low.

The service time and cs2 are those of the release minus the start of service, over every visit. A cs2 within 3
standard errors of 1 is taken as 1, as in the reference.

Own time after the first call out is **glue**: it holds no worker and is modelled as a delay after the calls (after
the maximum, for a parallel service). The test is `TestGlueEndToEnd`: a (12 ms, then 3 ms after its call with the worker
free) calls b (20 ms), at 37.5 requests/s, with a no-glue control. Over seeds 301-308:
- glue reads 3.00 ms every time, and a's service time 11.8-12.3 ms (11.75-12.22 in the control without glue);
- at true parameters the level is -1.7 to +1.3% and the change -2.3 to +3.4%;
- inferred, the level is -7.2 to +3.3% and the change at b -19.0 to +8.7%; the control without glue spreads as much
  (-8.9 to +6.0%, -24.5 to +13.3%), so the spread is capture noise at b's 75%, not glue;
- both span modes give the same numbers;
- when the 3 ms still counted as service time (77e6b8d), the change at a was +58.5% off.

The earlier estimator, `rise`, stays selectable (`RHOBOUND_ESTIMATOR=rise`). It reads the service time from the visits
that found a free worker, and the workers from where the own time rises with the number already busy (section 4.5).

### 6.2 Trace structure

The rules are the reference implementation's, ported in `internal/infer/structure.go`, `infer.go` and
`internal/otlp`:

- **Probes.** A server span whose route matches the reference's health rule is dropped (`/healthz`, `/health`,
  `/readyz`, `/livez`, `/ready`, `/ping`, `/_health`, and gRPC `grpc.health.v1.Health/`). The route is `METHOD path`,
  from `url.path`, `http.target`, `http.route`, `http.path` or `http.url`, or else the span name. Spans under a dropped
  probe become roots. On 26 test routes the decisions equal the reference's.
- **Broken traces.** A trace is broken in two cases (three causes are counted: a lost caller of a service the capture calls, a
  hole below a top, and the call without its callee's span, each named in the warning and the refusal):
  - a span names a parent that is not in the capture, and the span is not an entry whose caller (an ingress, a
    gateway, a browser, a message producer) is outside the capture. A span is such an entry when the trace has no
    captured top (no SERVER span without a parent) and it is a SERVER span of a service more than half of whose
    server spans have no caller's visit in the capture, or a CONSUMER span of a consumer more than half of whose
    CONSUMER spans have no captured parent. The reference counts every such trace as broken. (This is ed44f6a's
    rule; before it, only a trace's single top, of a service no captured span called, was an entry.)
  - a call to an address (peer and port) that some service answers on has no server span under it. A CLIENT span nested
    in another CLIENT span of the same pod is one call, not a lost callee (item 19).

  A broken trace stays in the queues and the rates. It is left out of the entries, calls, glue and network times.
  Above 5% of the traces the capture is refused, with the causes counted and the edges and services named. The external
  rate is scaled up by traces over complete traces (the reference reads it from complete traces only). The limit of the
  half rule is in item 17 of section 1; the limits of the 5% rule are in item 21.
- **Consumers.** The owner walk stops at a CONSUMER span. What a message consumer calls is its own work, not a call of
  the request that produced the message: the services it calls get those visits as entries, counted apart in the
  header and marked `>` in the report. Its calls to peers with no server spans are counted in a warning and left
  out.
- **Async calls.** When at least 95% of a caller's calls to one callee start at or after the caller's span has ended,
  the edge is async: the calls count in the visit ratios and the callee's arrivals, but not in the caller's latency,
  its worker release, its own time, its stages or its branch correlation. Between 5% and 95% they stay on the path,
  with a warning. A call that starts after the span is never a stage. The limit (a callee's clock running ahead) is
  in item 11 of section 1.
- **Calls per visit.** Per callee, a fixed count k, or k and one more with probability p, read exactly. Any other
  distribution (the reference refuses it unless k and k + 1 cover 99% of the visits) enters as its mean count, k calls
  and one with probability p, in a service that makes its calls one after another (section 6.3).
- **How the calls run.** Parallel when at least 95% of the visits with two or more calls overlap, and sequential when at
  most 5% do. In between, the reference's stage template decides: groups at once, then the next group. Each group is a
  zero-time parallel node. One case is added to the reference's: a single group called on some visits, all of it or none, is
  one stage with that probability. Where the reference refuses (calls that overlap on some visits in a shape that is not
  the template, a parallel service with a branch called on some visits only, a varying count of calls made at once), the
  service is a mixture of up to 12 call shapes (section 6.3); more shapes than that are refused by name. The template
  equals the reference's on 13 golden shape sets.

`TestStructureEndToEnd`, over seeds 301-308 (both span modes give the same numbers, to 0.01 ms; the lines of the
second mode are at the end of true-parameters.txt). The busiest service is at 66-70%; the change is +8% of the named
service's mean.

| shape (change at) | true parameters: level / change | inferred: level / change | read as one parallel fan-out (before the port) |
|---|---|---|---|
| {b c} at once, then d (d) | +1.9..+3.2% / +0.6..+4.0% | -4.1..+5.9% / -10.9..+12.0% | -28.0..-21.0% / -38.0..-19.7% |
| {b c} at once, then d on 60% (b) | +1.2..+2.0% / +1.4..+6.1% | -3.6..+5.4% / -13.4..+19.4% | +3.9..+16.6% / -29.7..-3.5% |
| b, then {c d e} at once (c) | -0.4..+0.2% / +3.9..+10.8% | -4.0..+2.7% / -8.0..+9.7% | -18.7..-13.0% / -9.5..+8.6% |
| d, then e on 30%, then f on 5% (e) | -0.3..+0.4% / -1.8..+0.8% | +0.6..+4.0% / -9.2..+12.8% | (sequential; read the same before) |

The change at c in "b, then {c d e}" is in a branch of a group that is not the slowest. It is over-predicted at true
parameters on every seed (items 4 and 5 of section 1).

### 6.3 Variable counts and mixed call shapes

Rules that the reference refuses and this tool does not (REQUIREMENTS.md, "Calls per visit that vary, and visits of
several call shapes"): the mean count (k calls and one with probability p) for a callee whose calls per visit vary, in a
service that calls one after another; the stage template's repeated stage; a mixture of up to 12 call shapes. What is
exact, and what is not, is checked against an event-driven simulator, `counts_sim_test.go`, in which the callee has one
first-come, first-served queue for all calls (the batch simulator of the other tests gives each call of a node its own
queue). A is a service with many workers and 3 request types; B has 1, 4 or 8 workers and exponential service times. The
columns are the model's mean latency against the simulation's, in percent: the mean of the runs and, in brackets, the
worst runs (8 runs of 200 s for one worker, 4 runs of 100-200 s for the others; the model is inferred from each run's
spans, as always).

| calls of A to B (request types) | B workers, busy | A: mean (range) | B as A saw it: mean (range) | batch warning |
|---|---|---|---|---|
| 1, 3, or 2 or 4, one after another (`seq`) | 1, 30% | -0.8 (-2.5..+1.0) | -0.8 (-2.5..+1.0) | no |
| | 1, 60% | -1.6 (-6.4..+2.7) | -1.6 (-6.5..+2.7) | no |
| | 4, 30% | -0.0 (-0.3..+0.3) | -0.0 (-0.3..+0.3) | no |
| | 4, 60% | +0.6 (-0.5..+1.3) | +0.6 (-0.5..+1.4) | no |
| 1 on 90%, 20 on 10% (`heavy`) | 1, 30% | -0.8 (-7.4..+5.2) | -0.9 (-7.5..+5.2) | no |
| | 1, 60% | +0.3 (-6.1..+9.6) | +0.3 (-6.1..+9.7) | no |
| | 4, 30% | -0.0 (-1.5..+0.7) | -0.0 (-1.5..+0.7) | no |
| | 4, 60% | +0.6 (-1.9..+2.9) | +0.6 (-2.0..+2.9) | no |
| 1 on 70%, 8 on 30% (`heavy2`) | 1, 30% | -0.7 (-5.8..+3.1) | -0.8 (-5.9..+3.1) | no |
| | 1, 60% | +1.9 (-5.4..+7.8) | +1.9 (-5.4..+7.9) | no |
| | 4, 30% | +0.3 (+0.0..+0.4) | +0.3 (+0.0..+0.4) | no |
| | 4, 60% | +0.3 (-0.8..+1.2) | +0.3 (-0.8..+1.2) | no |
| 1, three in a row, or four at once (`mix`, a mixture of 3 shapes) | 8, 20% | -0.2 (-0.4..-0.1) | -0.3 (-0.4..-0.2) | no |
| | 8, 40% | -1.6 (-1.9..-1.4) | -2.2 (-2.3..-2.0) | yes |
| | 4, 20% | -2.2 (-2.5..-1.9) | -3.6 (-3.8..-3.2) | yes |
| | 4, 40% | -7.1 (-7.8..-6.3) | -9.8 (-10.5..-8.9) | yes |
| also a run of 2-4, a fan-out of 2-5, none (`mixvar`, 8 shapes) | 8, 20% | -0.2 (-0.4..+0.0) | -0.4 (-0.4..-0.3) | no |
| | 8, 40% | -1.6 (-2.0..-1.2) | -2.3 (-2.9..-2.0) | yes |
| | 4, 20% | -2.5 (-2.7..-2.1) | -4.5 (-4.7..-4.3) | yes |
| | 4, 40% | -7.2 (-7.6..-6.8) | -10.3 (-10.8..-9.8) | yes |
| four at once, always (a fixed fan-out, read as before; `fan4`) | 1, 30% | -61.9 (-63.7..-61.0) | -58.9 (-60.0..-58.3) | yes |
| | 4, 30% | -13.4 (-14.1..-12.2) | -16.0 (-16.7..-14.9) | yes |

The reading of the table:

- **One after another, the mean count is unbiased.** The mean of the runs is within 2% of the simulation at every setting,
  and the callee's load is the observed one to the last digit (the tests check it to 1e-9). A single run of a one-worker
  callee with 20 calls on one request in ten is off by up to 10%: the estimate of a queue with bursts of 20 is noisy, not
  biased (16 runs of one such setting: mean -0.6%, spread 4%).
- **Calls made at once are understated** at the callee, by what the batch warning says. The model takes the calls of a
  batch as independent arrivals; they arrive together. The error grows with the batch and the load and shrinks with the
  workers; it is under 0.5% when the callee is quiet (8 workers, 20%), and the warning is silent there and speaks at every
  setting above where the error is above 1.5%. A fixed fan-out accepted before (`fan4`) has the same error and now
  has the warning; its numbers are not changed.
- **The change** (B's service time +20% with its arrival rate kept; the simulator run again with the slower B on the same
  seeds; mean of 6 runs of 200 s; `TestVariableCountsChangeAgainstTheSimulator` runs two of these rows with 4 runs of
  100 s and a 12% limit). The model's change against the simulator's, in percent of the change, A / B as A saw it:
  `seq`, 4 workers, 50% busy: -0.8 / -1.4; `seq`, 1 worker, 40%: +7.6 / +6.4; `heavy`, 4 workers, 50%: +4.6 / +4.9; `mix`, 8
  workers, 30%: -5.1 / -6.0; `mixvar`, 8 workers, 30%: -4.3 / -6.2. A's change is a mean count's worth of B's (about
  twice, for `seq`) or a mixture's.
- **A caller with one worker at 70% busy** (three kinds of request: one call, two calls, a long stretch of own work and
  no call, with own times of 3, 6 and 60 ms; `TestVariableCountsOfABusyCaller`): the model's latency of A is +2.0% on
  average over 3 runs (-0.5..+3.5%). The caller's own queue is the model's, fed by the pooled own time of the three kinds.
- **A real cluster.** The first 20 s of the OpenTelemetry Demo under its shipped load mix
  (`internal/infer/testdata/counts/shipped-20s`, 478 traces, 6,049 spans) is read with the cart's Redis calls as a mean count
  (1, 2 or 3 per visit; 1.72 on average), checkout's lines as mean counts, and the front end as a mixture of 11 call shapes.
  The model's arrival rate equals the measured one at every service to 0.1%. The latencies are within -11.0% to +6.7% of what
  the callers measured (several services have only 20 visits in 20 s, so single rows are rough). Before the per-edge network
  time rule (item 22), when the tool took the network time of a call as the 10th percentile of client span minus server span
  per callee, which lies 0.09-0.53 ms below the mean-based hop at the Demo's callees (the hop columns of the shipped-mix rows in accuracy-logs/hops.txt, section 3), they were 2.0% to 44.8% below
  at 12 of the 13 services with a measurement (the quietest tenth is what `hopMaxRho = -1` in `internal/infer/hops.go` gives
  back). On the 420 s shipped capture the same change took the worst row from -48.1% to -2.3%
  ([accuracy-logs/hops.txt](accuracy-logs/hops.txt), section 3).

## 7. A real cluster (kind), one service changed

Four services: frontend calls api (2 replicas, which calls db) and cache in parallel. The load is 30 requests/s
Poisson, and the change is +8 ms of constant work in `api`, rolled out with `kubectl set env`. Latency is measured by
the load generator, not by traces (`make e2e`).

| run | design and code | entry latency: model vs measured | change: model vs measured |
|---|---|---|---|
| 1 | single before / after pair, keep-alive on; basic model | 46.15 vs 43.34 ms (+6.5%) | +15.29 vs +13.15 ms (+16%) |
| 2 | the same; refined model | 44.11 vs 43.49 ms (+1.4%) | +14.25 vs +14.59 ms (-2.3%) |
| 3 | the same; refined, `rise` estimator | 44.42 vs **52.15 ms: FAILED** | +14.79 vs **+3.45 ms: FAILED** |
| 4 | the same as 3 | 44.53 vs 42.75 ms (+4.2%); traces' entry 42.42 ms | +14.78 vs +13.54 ms (+9.1% as recorded; +9.2% from these values) |
| 5 (2026-10-19 13:58 UTC, 29a7ed9) | hardened: keep-alive off, every pod restarted per window, B1 A1 B2 A2 | **45.89 vs 45.66 ms (+0.5%)** | **+14.59 vs +13.39 ms (+9.0%, +1.2 ms)** |
| 6 (2026-10-19 19:05 UTC, 53b5068) | the same as 5, at the final code | **46.15 vs 46.10 ms (+0.1%)** | **+14.93 vs +13.56 ms (+10.1%, +1.4 ms)** |

Runs 1-4 used code from before the 2026-10-19 fixes and the old test design. Their test logs are not kept (run 1's
captures are); their numbers are as recorded at the time (kind.txt copies them). Runs 5 and 6 passed every gate.

**Run 3 failed, and its cause is unproven.** Its before window read 52 ms where the other runs read 43; its after window
was normal (55.6 ms). So the measured change collapsed to +3.45 ms, while the model's numbers did not move.
- The most likely cause is an uneven split over the two api replicas. A Kubernetes Service picks a replica per
  connection. The frontend reused keep-alive connections, and Go takes the most recently used idle one, so on run 1's
  kept captures the next call went to the same pod 98.5-99.2% of the time. The api shares were 53.7 / 46.3% before and
  61.6 / 38.4% after, with 15-s windows up to 80 / 20.
- It is unproven for three reasons. Run 3's captures were deleted with the test's temporary folder. The simulation of
  the connection pool that supports it does not match the real runs: the passing keep-alive runs' tight windows are
  about 300 times likelier under per-request routing than under the simulated pool. And a short node stall fits the
  evidence equally well.
- The host logs for the window are quiet: no OOM, no timers, the kind node's CPU and memory as in the passing runs.
- The hardened test removes the mechanism (keep-alive off, a 55% share gate) and keeps its work folder on any failure.

**Run 5 in detail** (each window 150 s, about 4,400 requests, 0 errors, schedule lag at most 2 ms, the worst 10-s window
at most 1.20 times the median):

| window | load generator | traces' entry | model entry | model change | api pods: share, wait in traces | api wait, model / traces |
|---|---|---|---|---|---|---|
| before 1 | 45.24 ms | 45.02 ms | 45.59 ms | +14.38 ms | 50.3% 9.22 ms, 49.7% 8.89 ms | 8.77 / 8.52 ms |
| after 1 | 60.39 ms | 60.17 ms | | | 49.1% 16.54 ms, 50.9% 17.14 ms | |
| before 2 | 46.09 ms | 45.84 ms | 46.19 ms | +14.80 ms | 49.5% 10.49 ms, 50.5% 8.59 ms | 9.02 / 8.99 ms |
| after 2 | 57.71 ms | 57.47 ms | | | 48.7% 14.31 ms, 51.3% 15.32 ms | |

The node used 0.21-0.23 cores and 797-897 MiB. CPU pressure stalls were 0.23-0.24% on the node and 0.35-0.36% on the
host, with no memory stalls, no OOM kills, no restarts and no lost spans.

The levels of runs 1-4 and run 5 are not comparable. With keep-alive off the split is per request, so api queues more
(the before windows read 45.2-46.1 ms against 42.8-43.5 ms).

**The noise floor of the measured change.** The two rounds measured +15.15 and +11.62 ms, around +13.39 ms. The
before windows were 0.85 ms apart and the after windows 2.68 ms apart.
- A simulation of the demo's queues with per-request routing gives each 150 s window's mean a standard deviation of
  about 0.9 ms before and 1.2 ms after the change. That makes about 1.1 ms for the two-round change.
- The simulation is approximate. It draws exponential service times and adds a fixed 1 ms for the network hops and
  HTTP overhead it leaves out. Its level before the change is 42.3 ms (43.3 with that 1 ms), against 45.7 ms
  measured, so its standard deviations and its truth are estimates for a demo like this one, not for this run.
- The same simulation puts the true change near +13.8 ms (+13.84). Against it, the run's predicted change of +14.59 ms
  is a model bias of +0.75 ms. (The simulation's own model value, +14.80, would be +0.96 ms.)
- The 1.2 ms gap is therefore about one standard deviation of the measurement, and of the size of that bias.
- In the same simulation the test's change gate (15% of the measured change + 1.5 ms) fails 2.15% of runs with a bias
  of about +1 ms (the +14.80 model value), and 0.08% with none (kind.txt).

**Run 6** repeats run 5 at 53b5068, after every later code change (release clip, upstream callers, identification,
async calls, uneven split, `model` limits). Each window 150 s, about 4,300 requests, 0 errors, schedule lag at most
2 ms, the worst 10-s window at most 1.20 times the median; the node used 0.21-0.23 cores and 760-807 MiB, with CPU
stalls of 0.23% (node) and 0.35-0.36% (host), no memory stalls, OOM kills, restarts or lost spans.

| window | load generator | traces' entry | model entry | model change | api pods: share, wait in traces | api wait, model / traces |
|---|---|---|---|---|---|---|
| before 1 | 46.06 ms | 45.84 ms | 46.30 ms | +14.88 ms | 49.5% 9.54 ms, 50.5% 9.35 ms | 9.24 / 8.90 ms |
| after 1 | 58.43 ms | 58.22 ms | | | 50.1% 14.63 ms, 49.9% 16.13 ms | |
| before 2 | 46.14 ms | 45.92 ms | 46.00 ms | +14.97 ms | 50.9% 10.14 ms, 49.1% 9.15 ms | 9.35 / 9.12 ms |
| after 2 | 60.89 ms | 60.67 ms | | | 49.8% 16.15 ms, 50.2% 17.43 ms | |

The two rounds measured +12.37 and +14.75 ms (+13.56 ms together). Against the simulated true change of about
+13.8 ms, run 6's +14.93 ms is a bias of about +1.1 ms, in line with run 5's +0.75 ms; the level is within 0.1%.

The cluster test is circular in one respect: its services are queues of the kind the model describes. It checks the
whole path (collection, inference, model, rollout), not the fit to real software.

## 8. Real services at lower load: the five test-bed captures

The test bed is a 10-service Python demo shop (11 pods, two entries) on a single-node Kubernetes cluster (not
published). Its five captures were taken on 2026-10-16 under 100 requests/s Poisson, at 55-57% utilization in the
busiest service (pricing). They were used while building the tool, so they are development data, not a holdout. They
do not test 70-80%. Re-run at 2349b17. The runs are named A/A and run 1 to run 4 here.

- **Structure and inputs against the reference's own inference** (its inference output for each capture, not
  published). All 10 services on all five runs agree on:
  - replicas, routing, call order, parallel flags and call probabilities;
  - worker counts, including which are lower bounds (checkout, product and storefront at 2+ or 3+, all others
    identified);
  - service times within 0.6 of the reference's standard error;
  - cs2 within 0.006.
- **Level**: the model's entry latency against the entry span mean in the same capture.

| run | storefront: seen / refined / basic | checkout: seen / refined / basic |
|---|---|---|
| A/A (300 s) | 67.74 / 67.88 (+0.21%) / 69.14 (+2.07%) | 89.65 / 89.81 (+0.18%) / 89.82 (+0.19%) |
| run 1 (300 s) | 68.29 / 67.74 (-0.81%) / 69.19 (+1.32%) | 89.90 / 89.83 (-0.08%) / 89.84 (-0.07%) |
| run 2 (600 s) | 67.49 / 67.46 (-0.04%) / 68.80 (+1.93%) | 88.81 / 88.65 (-0.17%) / 88.66 (-0.16%) |
| run 3 (600 s) | 66.85 / 67.27 (+0.62%) / 68.60 (+2.61%) | 87.57 / 88.76 (+1.36%) / 88.77 (+1.36%) |
| run 4, CPU limit (600 s) | 67.79 / 67.64 (-0.21%) / 68.93 (+1.69%) | 89.14 / 89.14 (+0.00%) / 89.15 (+0.01%) |

  Storefront's path includes product's parallel fan-out; that is where the refined model gains (+1.3 to +2.6% basic,
  -0.8 to +0.6% refined). Checkout's calls are sequential and its callees see nearly Poisson arrivals, so the two
  models agree.
- **Change, given the measured change in the changed service.** Each run deployed a new `auth` image with about 3 ms of
  CPU work per call. Run 4 also had a 400m CPU limit on `auth`; A/A is a run with no change.
  - The input `--patch auth=+dS ms` is the change in `auth`'s service time that 2349b17 reads from the two after
    captures against the before capture. A user would not have it before deploying, so this tests how the
    model carries a known change through the graph, not how the change in `auth` is predicted.
  - The observed change is the entry span mean after minus before. Its standard error is from the reference's own
    verification output (not published).

| run | dS | storefront: observed / predicted | checkout: observed / predicted |
|---|---|---|---|
| A/A | +0.00 ms | -0.19 ± 0.65 / +0.00 | -1.16 ± 1.15 / +0.00 |
| run 1 | +0.35 ms | -0.27 ± 0.59 / +0.59 (+1.5 se) | +0.04 ± 1.01 / +0.59 |
| run 2 | +3.05 ms | +6.00 ± 0.36 / +6.22 (+0.6 se) | +5.27 ± 0.87 / +6.22 (+1.1 se) |
| run 3 | +3.09 ms | +6.74 ± 0.40 / +6.48 (-0.7 se) | +6.63 ± 0.54 / +6.48 (-0.3 se) |
| run 4 (CPU limit) | +3.84 ms | +9.16 ± 0.58 / +8.49 (-1.2 se) | +8.56 ± 0.89 / +8.49 (-0.1 se) |

  The refined and basic predictions are identical here (auth's arrivals are nearly Poisson). Under the CPU limit
  `auth`'s own time grew by 3.84 ms instead of about 3.07; given that, the model is close. The earlier statement
  ("18% low where CPU throttling dominated") came from an earlier version with an input that is not recorded, and is
  withdrawn.

## 9. Real software on a real cluster: the OpenTelemetry Demo

On 2026-10-21 the tool was run on the OpenTelemetry Demo 2.2.0 (about 25 services in a dozen languages; the shipped load mix and a browsing-only mix, 100
Locust users, windows of 420 s) on a real five-machine cluster, next to the repository's own demo ([REAL_CLUSTER.md](REAL_CLUSTER.md) tells the whole
run). This is the first real software that was not shaped for the model, and the first run in which the tool *refused* both load mixes. **What it tests
and what it does not:** the Demo ran at **1.0% (shipped) and 1.4% (browse) utilization in its busiest service**, so this section tests what the tool reads
from real spans (the call structure, the rates, the number and shape of calls, the time per call) and **does not test queueing on real software**. The change
of a service's time was not measured on the Demo.

**What was wrong** (the table of causes, with the fix and its status, is in [REAL_CLUSTER.md](REAL_CLUSTER.md#5-what-was-wrong-what-was-changed)): a CLIENT span that wraps
another read as a lost span (the shipped mix was refused for 5.3% of its traces "missing spans", which were none); a SERVER span inside another read as a
service calling itself (the browse mix was refused); call counts that vary by request type (refused, then the front end's twelve call shapes would have been);
the network time of a call (the quietest tenth of the gaps) 0.2-0.3 ms below its mean on every call, which at 1% utilization was the whole error (20-31% on the browse mix, up to
48% on the shipped one); span starts on whole milliseconds that made calls in a row read as made at once; and, found when the fixes were validated and reviewed, gRPC streams
read as visits of 600 s and a search that ran for minutes on a service that calls one callee dozens of times in a row.

**Before and after.** The shipped mix was refused (5.3% of the traces), then refused (call counts), and is now read: 14 services, 11,890 entry requests in 10,468 traces,
the arrival rate equal to the measured one at every service to 0.1%. Model against what the callers' client spans measured (13 services with a measured latency;
median |error| 0.1%, worst 2.3%):

| service (shipped mix, 420 s) | rps | busy | model ms | seen ms | error |
|---|---|---|---|---|---|
| frontend (Node.js) | 23.79 | 0.95% | 4.287 | 4.192 | +2.3% |
| frontend-proxy (entry) | 23.79 | 0.12% | 4.435 | 4.340 | +2.2% |
| cart (.NET) | 12.83 | 0.11% | 1.401 | 1.399 | +0.1% |
| checkout | 1.33 | 0.02% | 18.367 | 18.797 | -2.3% |
| product-catalog | 24.64 | 0.05% | 1.113 | 1.115 | -0.2% |
| the other 8 | | at most 0.44% | | | -0.7 to 0.0% |

The browse mix (refused, then 20-31% low): frontend +1.7%, frontend-proxy +1.6%, product-catalog 0.0%. The repository's own demo on the same cluster
(Phase A, 35-79% busy): unchanged to 0.01 point except its cache (10-20% busy), -3.6 to -2.5% before and 0.0% (at one decimal) now in all 12 windows.

**What is independent of the fit.** At 1% utilization the hop is the mean gap, so a callee's latency equals what its callers saw by construction, and the level
agreement above is **fitted, not predicted** (item 22). Four things are not:
- *The rates.* The model's arrival rate equals the capture's at every service, to 0.1%.
- *The call structure.* The front end's shapes read as "cart then cart" 17.3%, "recommendation then product-catalog x4" 7.9%, a catalogue call alone 42.4%, and so on; the cart's
  cache calls as a mean of 1.72 per visit (1: 57.5%, 2: 10.4%, 3: 32.1%); checkout's calls once per cart line.
- *The change a patch predicts*, against a replay of the traces that has no model in it (+1 ms at one service, effect at the entry; the replay has a tolerance for how far apart in time two spans may be and
  still follow one another, and 0 and 1 ms bracket the answer): frontend 1.0004 (replay 1.000), cart 0.539 (0.446 to 0.539), the cart's cache 0.942 (0.806 to 0.942), product-catalog 0.747 (0.692 to
  0.840), currency 0.164 (0.147 to 0.163), ad 0.081 (0.081), checkout 0.056 (0.041 to 0.056). The replay and the tool share the traces; they do not share a model or an estimate.
- *A hold-out*: the model fitted on one window against what the callers measured in another window of the same capture. It is as far off as one window's callers' means are from another's
  (the noise floor), to within 0.1-0.6 point:

| windows | pairs | model of window i against seen in window j: mean / median / max | seen in i against seen in j (noise floor): mean / median / max | in sample |
|---|---|---|---|---|
| shipped, 60 s (7) | 282 | 7.08 / 2.60 / 141% | 6.44 / 2.69 / 117% | 1.00 / 11.3% |
| shipped, 140 s (3) | 60 | 6.57 / 1.83 / 60% | 6.42 / 1.44 / 58% | 0.59 / 2.4% |
| shipped, 210 s (2) | 28 | 5.82 / 2.31 / 45% | 5.76 / 2.57 / 45% | 0.57 / 2.4% |
| browse, 60 s (7) | 126 | 8.63 / 5.06 / 38% | 8.52 / 4.03 / 36% | 1.13 / 2.1% |
| browse, 140 s (3) | 18 | 5.16 / 3.45 / 14% | 5.07 / 1.89 / 12% | 1.12 / 1.8% |
| browse, 210 s (2) | 6 | 4.62 / 4.88 / 9% | 4.51 / 6.34 / 7% | 1.12 / 1.8% |

  The in-sample column is what a report's `err %` shows; the hold-out says it carries no information beyond the window's means at this load.
  Do not quote "within 3%" as a prediction accuracy on the Demo; it describes the three validated windows (147 of 152 service-windows of at least 200 visits in the 26 cuts are within 3%).

**What still fails, and why** (limits; the rest of this page's items apply as they were):
- *Queueing on real software is not tested* (above). Level 3 of Phase A (72-79% busy) was judged unstable: predicted +31.35 against +18.43 ± 10.85 ms measured (2.4 standard errors), with before
  windows of 97.8 and 113.3 ms; per round +28.08 against +28.16 and +34.61 against +8.70. Treat 70-80% as the stated limit. Item 23 is the one place on the repository's demo where a downstream
  service is over-predicted after a change, and is not explained.
- *The front end's level is 2.3% above its callers'* (item 25): about half of it is one hop per edge charging a lone call and each call of a group the same time (0.96 ms alone, 1.27 ms in a group of four, 1.10 ms the edge's mean); the rest is not attributed.
- *The largest errors are in small windows*: currency +11.3% in one 60 s cut (a heavy tail on 114 squared coefficient of variation, with few samples), the front end -4.2% in the browse mix's 180 s warm-up.
- *What a user sees is higher than the entry's latency*: the load generator's client spans read 6.57 ms (shipped) and 4.16 ms (browse) against the entry's server spans 4.34 and 2.64 ms: the
  ingress hop and the client's own time are outside the model.
- *One cluster, one run per mix, one version of one demo.* The nested-span rule rests on three patterns of two frameworks, the whole-millisecond rule on one runtime.

## 10. Speed

`rhobound predict --json` on the 579 MB (552 MiB) before capture of test-bed run 3 (696,949 spans, 10 services), page
cache warm, at 2349b17:

| GOMAXPROCS | wall | CPU (user) | peak memory |
|---|---|---|---|
| 8 | 1.01-1.02 s | 5.0-5.1 s | 213-228 MiB |
| 3 | 1.94-1.95 s | 4.9 s | 200-204 MiB |
| 1 | 5.06-5.09 s | 4.8 s | 208-210 MiB |

The code review measured 0.97 s at 094b99a and 0.99 s at 29a7ed9 on 8 cores. The reference implementation took 22.5 s
for its fuller `predict` on the same capture (as recorded in 4ffc358; no log is kept); the two are not like for like.

## 11. Re-running

```
go test ./...                                                    # fast; includes the estimator and refined-vs-basic checks
go test -tags accuracy -run TestHarnessPlumbing -v ./internal/infer   # the harness's own arithmetic (about 1 s)
go test -tags accuracy -run TestAccuracy -v ./internal/infer     # section 5.1 (about 20 s)
go test -tags accuracy -run TestChainDamping -v ./internal/infer # section 5.2 (about 100 s)
go test -tags accuracy -run TestFanOut -v ./internal/infer       # section 5.3 (about 50 s; ACC_WORST=1 prints each case)
go test -tags accuracy -run TestHoldout -v ./internal/infer      # section 5.4 (about 20 s)
ACC_SEED=301 ACC_WORST=1 ACC_STRUCT=1 go test -tags accuracy -run 'TestEndToEndAccuracy$' -v ./internal/infer  # section 4 (about 40 s)
ACC_SEED=301 ACC_SPANQ=1 go test -tags accuracy -run 'TestEndToEndAccuracy$' -v ./internal/infer   # spans include the wait (about 27 s)
ACC_SEED=301 ACC_STRUCT=1 go test -tags accuracy -run TestEndToEndAB -v ./internal/infer   # both modes, both estimators,
                                                                 # true parameters; ROW / ROWTRUE / PAR lines (about 55 s)
go test -tags accuracy -run TestGlueEndToEnd -v ./internal/infer        # section 6.1 (about 2 s)
go test -tags accuracy -run TestStructureEndToEnd -v ./internal/infer   # section 6.2 (about 8 s)
go test -tags accuracy -run TestNoUnevenSplitInScenarios -v ./internal/infer   # section 1 item 9 (about 2 min)
go test -run TestUnevenReplicaSplit -v ./internal/infer          # section 1 item 9: a fixed uneven split (about 1 s)
go test -tags e2e -v ./e2e   (RHOBOUND_E2E=1)  or  make e2e      # section 7; needs docker, kind, kubectl
```

The times are wall times at 64 replications on the 8-core arm64 machine at `GOMAXPROCS=3`. The truth's replications
run in parallel, so more cores make them shorter.

Switches (environment variables) of the accuracy tests:

| switch | effect |
|---|---|
| `ACC_SEED` (31337; TestHoldout 4242) | draws the random families (the holdout rows; which 6 of the 16 fan-outs changed in their slowest branch the end-to-end tests score; the structure family) and every row's seeds |
| `ACC_TRUTH_REPS` (64) | replications of the truth, 400 s each (500 s in TestAccuracy); the base and the changed state run on the same seed (common random numbers), so the change's standard error is that of the paired differences |
| `ACC_SPANQ=1` | the spans include the wait for a worker (TestEndToEndAccuracy; the structure rows keep their own mode) |
| `RHOBOUND_ESTIMATOR=rise` | the earlier estimator |
| `ACC_WORST=1` | TestEndToEndAccuracy lists the LARGE rows (level error over 8%, change error over 3% of the latency, or \|z\| over 3) with the truth's and the input's standard errors, z, and the inferred and true parameters |
| `ACC_STRUCT=1` | the end-to-end tests add the structure family (12 rows after the others: glue, staged calls, conditional calls, an uneven split over 2-3 replicas; each kind with both span modes). Its rows are summarised as `ALL struct` and per kind, apart from the `ALL` line of the original families. TestEndToEndAB's SUM lines then pool all 48 rows |
| `ACC_HOPJIT=X` (0) | test-only: each network leg of the simulated captures and truths takes 0.15 ms plus X ms more on average (a gamma draw of shape 0.7, from a random stream of its own, so the requests and service times of a seed do not change), and the true topology's hop is 2 x (0.15 + X). Default 0: a constant network time, as in the older logs. Used by the jittered lines of [accuracy-logs/hops.txt](accuracy-logs/hops.txt) (X = 0.1) |
| `ACC_ROWS=3,17` | the end-to-end tests run those rows only (a row's seeds do not depend on which rows run) |
| `ACC_DUMP=DIR` | the recorder: each row run is written to `DIR/seed<S>-row<NN>/`: `capture/` (the 400 s trace, as `rhobound infer` reads it), `true_base.json` and `true_after.json`, `inferred.json`, and `truth.json`. About 16 MB per row |
| `ACC_NOISE=K` | TestEndToEndAccuracy also infers K more captures of each row and prints the spread of their predictions next to the input standard error, and their mean error with its z |
| `ACC_ONLY` | TestAccuracy: the scenarios whose name or group contains it |

**Seeds.** Each row of a test owns a block of 2^16 seeds. Its capture is at offset 0, truth replication r at offset r,
and extra capture j (ACC_NOISE) at 2^15 + j. Where the blocks start comes from ACC_SEED. No two rows of a run, and no
capture and truth replication, share a seed. Seeds 301-308 were first used for this file; 101-108 (check round 1),
201-206 and 613-614 (model research and fix checks), 31337 and 1-7 (development), and the seeds of earlier studies
are spent.

**Order statistics.** The harness's median is y[n/2] (the upper median) and its 90th percentile y[int(0.9 (n - 1))].
Pooled numbers here are computed the same way from the per-row lines.

**z.** For each scored row, z = error / sqrt(truth SE^2 + input SE^2), for the base level and for the change. The input
standard error is the noise one 400 s capture puts into the prediction, by the delta method around the true parameters.
It covers each service's sample mean and cs2, each call probability below 1, an uneven split's shares and the request
rate. It leaves out worker counts, branch correlations and the cs2 of exponential services. ROWTRUE lines and the
true-parameter tables use the truth's standard error alone. Checked at 9920f80 on seed 31337 (48 rows, 16 truth
replications), the spread of 24 extra captures' predictions over the input standard error had a median of 1.00 for the
level (0.77 to 1.44) and 1.03 for the change.

**Branch correlation.** The true-parameter topologies carry the branch correlation of each parallel group, measured in
the truth's own runs the way the inference measures it from a capture. TestFanOut's `matched` line is the matched
maximum without it.

The simulations use fixed seeds, so the tables reproduce on the same Go version and architecture. The accuracy tests are
behind a build tag because they take minutes and report numbers instead of asserting them (TestHarnessPlumbing does
assert).

**Where the numbers are** ([accuracy-logs/](accuracy-logs/), summary lines only; the full logs with every row are kept
outside the repository):

| file | contents |
|---|---|
| `e2e-accuracy.txt` | TestEndToEndAccuracy summary lines, seeds 301-308, both span modes (sections 0, 4.1, 4.2) |
| `e2e-ab-sum.txt` | TestEndToEndAB SUM lines (48 rows each, both estimators) |
| `pooled.txt` | the pooled, per-family, true-parameter, paired and worker-count tables computed from the ROW, ROWTRUE and PAR lines (sections 0, 1, 4); its section 9, added with the docs fix, has the medians on the missed rows, the largest level rows with their PAR lines, and the 21 rows with a change error of 2.5% of the latency or more |
| `true-parameters.txt` | TestAccuracy, TestChainDamping, TestFanOut, TestHoldout, TestGlueEndToEnd and TestStructureEndToEnd, ranges and per-seed lines (sections 5, 6); at the end, every TestStructureEndToEnd line, both span modes |
| `testbed.txt` | the five test-bed captures (section 8) |
| `hops.txt` | the network time of a call, per edge (item 22): the harness's summary lines before and after the rule, with and without a hop jitter (`ACC_HOPJIT`), the model against what the callers' client spans measured on the real captures (browse and shipped mixes, the repository's demo), the jitter sweep of a chain of services under a millisecond, and the variant without the 30% limit (sections 1-5) |
| `kind.txt` | runs 5 and 6's log lines and results, runs 1-4 as recorded, the gate simulation's lines behind the noise floor (section 7), the doc check's skew probe and 53b5068's async rows (section 1, item 11) |
| `checks.txt` | TestHarnessPlumbing, TestNoUnevenSplitInScenarios, golden parity, the loopback smoke test, speed (sections 1, 9); at the end, the unbounded pool's refusals and the async probe against a callee clock running ahead (section 1 item 11), and the README's example output |
