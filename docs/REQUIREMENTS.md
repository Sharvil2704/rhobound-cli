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
- [ ] The window is cut by the time its **traces started**, whole, so that it holds no gRPC stream or long poll that began before it ([Streams and other long server spans](#streams-and-other-long-server-spans)).
- [ ] The load is steady during the window, roughly Poisson, and the busiest service is below 85% utilization.
- [ ] The traces are OTLP/JSON files, one `ExportTraceServiceRequest` per line (the Collector's file exporter).

## 1. The telemetry

### Spans and trace context

- **SERVER spans from every service.** A service is something that emits SERVER spans. Its visits, its rate, its
  service time and its worker count are all read from them.
- **CLIENT spans for outgoing calls.** They tell which service a call went to, how long the caller waited for it, and
  the network time of each hop ([The network time of a call](#the-network-time-of-a-call)). A CLIENT span to a peer that
  has no SERVER spans in the capture (a managed database, an outside API) becomes a pure delay: it adds its mean time
  to the caller and has no queue.
- **Parent links across services.** Propagate W3C trace context (`traceparent`), as the OpenTelemetry SDKs and
  auto-instrumentation do by default. Without it each service's spans start traces of their own, and there is no
  call graph across services.
- **Lost spans.** A trace that lost a span is left out of the entries and the call structure but kept in the queues
  and the rates. Up to 5% of the traces may be broken (with a warning); above 5% the capture is **refused**, with the
  causes counted and named (see [Spans that were lost](#spans-that-were-lost)). Check the exporters' queues and that
  the capture holds whole requests.

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

### Spans that were lost

A trace is **broken** when it shows a span lost, in one of three ways: a SERVER span names a parent that is not in the
capture, in a service that the capture's services call (a lost caller; it is not an entry from outside, above); another
span names a parent that is not in the capture (a hole below a top that is in the capture, or on a client or internal
span); or a call has no span of its callee under it. The last one is a CLIENT span to an address (peer and port) that
some service answers on elsewhere in the capture, with no SERVER span under it. A call to an address nobody answers
on (a managed database) is an outside delay, not a lost span. A CLIENT span wrapped around the one the callee answered
is no call at all (see the next section: on the OpenTelemetry Demo it read as a lost span, in every checkout trace, and was the reason the
shipped mix was refused for "5.3% of the traces miss spans").

What the tool does with a broken trace, and tells:

- The trace is out of the entries and the call structure, and its visits stay in the queues and the rates. The external
  rate is scaled up by the traces over the complete traces, so the model counts the requests of the broken traces and
  gives them the calls of the others.
- The warning (up to 5%) and the refusal (above it) name what was lost: for a call without its callee's span, the caller,
  the address, the service that answers on it, and the calls lost over the calls made on that edge, for the three edges
  with the most; for a hole in the middle of a trace, the services and kinds of the spans whose parent is gone.
- **The callee's own figures are read from the visits captured**: its service time, its queue and its worker count. They
  are off if the lost spans are not typical, for example the slow ones or those of the busiest moments (an exporter that
  drops when its queue is full does that). The row is marked `!` in the text report, and has `lost_visits` and
  `lost_share` in the JSON, once the service lost 1% of its visits.
- A service with a quarter or more of its visits in broken traces is warned about and marked: its calls are read from
  the other visits, or from none. This is the case the 5% limit misses: broken traces that are all of one kind of request
  (all the checkouts, 5% of the traces and every visit of the services behind them) leave that request out of the model
  with no refusal.
- A service that is **entered from outside the capture and is also called by a captured service** (at least 5% of its
  visits) is warned about. The Demo's flagd is one: the cart calls it, and its other lookups arrive with no caller (a
  client that sends no trace context, or whose spans are not exported). They are entries and the load on the service is
  right, but their senders are not in the model, so a change of the service's time reaches the captured callers only.

An edge whose callee has **no SERVER span anywhere in the capture** is an outside delay by design, not a loss: if every SERVER span of a service is
dropped (an exporter that never ran, a filter), the calls to it become `ext:` delays with only the count of "calls to services without server spans"
to say so, and a service whose outer entry spans are all dropped becomes an entry (its callers' calls go to an unnamed outside peer). The naming above
works on partial loss. Look at the services in the report against the ones you run.

What the tool cannot tell: why the span is missing. A span dropped by an exporter, a span left out by sampling, and a
trace context that did not reach the callee look the same. A capture that loses more than half of the calls into one
service, with no top above them, is not detected (see above).

### Nested spans of one kind in one pod

Some frameworks open a second span of the same kind inside the span of the HTTP or RPC instrumentation, in the same
process, for one and the same unit of work. The OpenTelemetry Demo has three of them: Next.js opens a SERVER span for
its request handler inside the HTTP instrumentation's SERVER span (the frontend); flagd's flag-evaluation handler does
the same inside its Connect RPC interceptor's SERVER span; and .NET's gRPC client opens a CLIENT span around the HTTP
client's CLIENT span (the cart's calls to flagd). Read as they stand, the first two are a service calling itself (a
cycle the model cannot hold, and every request counted as two visits, the first of which frees its worker at once),
and the third is one call counted twice: the outer CLIENT span has no SERVER span under it, so it looks like a call
that nobody answered, and the trace counts as having lost a span.

The tool reads each nested pair as one:

- A SERVER (or CLIENT) span is **nested** when the nearest SERVER or CLIENT span above it (looking up through INTERNAL
  and PRODUCER spans, and stopping at a CONSUMER span) is of the same kind and from the same pod of the same service,
  and it lies inside that span's time to within 2 ms. Node.js and nginx write span start times on whole milliseconds,
  so two spans of one process can be up to a millisecond away from where they were; 2 ms is twice that. In the
  Demo's Next.js spans the inner span started 0 to 3 ms after the outer one and, on 17-22% of the pairs, ended up to
  0.89 ms after it.
- Two **SERVER** spans of one **named instrumentation scope** are not nested, whatever their times: they are two visits. A framework's
  span comes from another library than the instrumentation's (in the Demo's data every pair differs: the HTTP instrumentation and
  `next.js`; the Connect interceptor and flagd's own scope), where a service that sends a request to itself with a client that opens no
  span, and passes the trace context on, would show two spans of one scope; that is a call, and the capture is refused as a service calling
  itself. A span with no scope name in the capture is judged on the other conditions, and the warning then counts the pairs for which no scope
  was known: if the service does call itself without a CLIENT span, its visits are counted once. Spans from exporters that write no scope name
  need that care.
- Of two nested **SERVER** spans the **outer** one is kept: it is the one the caller's CLIENT span is the parent of,
  it starts when the request reached the process and ends when the response left it. The inner one is made INTERNAL.
- Of two nested **CLIENT** spans the one with a **callee's SERVER span under it** is the call (the inner one in the Demo)
  and the wrapper is made INTERNAL; a wrapper is never kept over a span with a SERVER span under it, and two CLIENT spans that each have
  one are two calls. A wrapper around several attempts keeps each attempt that a SERVER span answers, and an attempt with none
  beside one with one is a call of its own (a token fetch, a failed try). When **no span of the nest** has a SERVER span under it (a
  database, a cache or a service that sends no spans, with a connect inside a GET), the
  **outermost** is kept: it is the operation the caller waited for, and what is nested in it is part of it. A kept span with no peer of its own takes
  the peer and port of the nearest span of its nest that has one.
- Chains of three or more are handled the same way: a chain of SERVER spans keeps only the outermost. A chain of more than 64 nested
  spans, or a parent cycle in malformed data, is left alone (the walk is bounded) and read as the spans stand.
- What is under a span that was made INTERNAL stays under the span that was kept (INTERNAL spans are looked through),
  so no work is lost, and the visit's total time is unchanged. The kept CLIENT span is the inner one where a SERVER span is under it, so the call's
  time is the inner span's; the wrapper's own overhead moves from the call to the caller's own time, or to its glue after the first call (the cart's
  calls to flagd: a mean of 925 µs for the wrapper against 823 µs for the call under it).

A warning names the services and how many spans of each kind were made INTERNAL, and the JSON report lists them as
`nested_spans_merged` ([USAGE.md](USAGE.md#10-warnings)).

What is **not** merged: real recursion (a SERVER span, then a CLIENT span, then a SERVER span of the same service, in
this pod or another: the call goes over the network, and the capture is still refused as a call graph with a cycle);
a SERVER span below a SERVER span of another pod of the same service; spans of different services; two SERVER spans of one
instrumentation scope; CONSUMER and PRODUCER spans (a message consumer's "receive" and "process" spans are a hand-off, not a wrapper). A pair
whose inner span starts or ends more than 2 ms after the outer span's end is work that outlives the request and is not merged;
the refusal then names the service and says so. **The pod is the identity the capture gives** (`k8s.pod.name`, else `service.instance.id`, else
`host.name`): a capture whose resources name none has one pod per service, and then two spans on different replicas count as one pod.

This is a deviation from the reference implementation, which has no such rule. It does not fix a service whose
visits differ by the endpoint they serve, or a framework whose spans sit more than 2 ms apart.

### Calls per visit that vary, and visits of several call shapes

A service that serves several kinds of request makes a different number of calls for each: the OpenTelemetry Demo's cart
calls its Redis once to read a cart (GetCart), three times to add to it (AddItem) and twice to empty it (EmptyCart); its
checkout calls the product catalogue and the currency service once per line of the order; its front end serves a dozen
endpoints, one calling the cart twice in a row, another a recommendation service and then four catalogue lookups at once,
another the checkout and then one lookup per line. The count of calls and their shape belong to the kind of request;
the service-level histogram is only the mix of kinds. Nothing in the spans is wrong: the Demo has no retries, no
duplicated spans and no errors behind these counts (one call count per cart size, the same count on three edges). The
model has, for each callee, a fixed count or one more call on some visits, and one stage template per service; the
captures were refused for it ("calls per visit vary as {1: 3098, 2: 559, 3: 1731}").

They are read in three steps, each only where the rules of the reference would refuse the service (what is accepted
without them is read as before):

1. **The mean count.** A callee whose calls per visit are neither a fixed count nor a fixed count and one more (99% of
   the visits), called by a service that makes its calls one after another, enters with its mean: k calls on every visit
   and one more with probability p, where k + p is the mean calls per visit over all of the service's visits (those
   with none included). The load on the callee is then exactly the caller's visits times the mean (the model's rate
   equals the measured one on every service of the Demo cut, to 0.1%), and so is the caller's mean time, the sum of its
   calls' times. What is lost is the spread of the counts: the calls of one visit reach the callee close together, where
   the model has independent arrivals. In simulations with 1 to 20 calls per visit and the callee 30-60% busy
   ([ACCURACY.md](ACCURACY.md#63-variable-counts-and-mixed-call-shapes)) the mean latency was within 2% on average and,
   against a callee with one worker and heavy tails, single runs were off by up to 10%. The warning lists the counts.
2. **The stages.** If the service's visits fit the reference's stage template (95% of them), the stages carry the
   count: a repeated stage that runs on some visits only. The report says "stages".
3. **A mixture of call shapes.** Otherwise (calls that overlap on 5-95% of the visits in a shape that is not the
   template, calls made at once with a varying count, a branch of a fan-out called on some visits only) the service's
   visits take several shapes, and it is a mixture: it calls each shape with the share of its visits that took it. A
   shape is one call, calls made at once (a zero-time parallel node), or several of these one after another (a zero-time
   node); they are the `stage:S:j.n` and `shape:S:j` rows of the report. A shape is the visit's stages as the reference
   reads them (calls that overlap are at once), so a shape is as exact as the timing of the spans. The mixture keeps the
   12 commonest shapes; the rarer ones may hold 5% of the calling visits at most and enter as mean counts, one after
   another. A callee whose calls the shapes do not account for (calls that start after the visit's span has ended, on an
   edge with too few of them to be async) is topped up with mean-count calls, so that its load is the observed one, and
   the warning says so. The visits of a service with more shapes than that are still refused, by name.

Each is reported: the JSON report's `variable_calls` per service (the callee, the mean per visit, the visits by calls per
visit, and how it was modelled: `mean count`, `stages` or `mixture of call shapes`) and `call_shapes` (the shapes, in
words, with the share of visits that took each), a line under the table of the text report, and warnings.

Limits, stated plainly:

- **Calls that arrive together are not modelled.** Calls made at once (a fan-out, a shape of a mixture) reach the callee
  together, and the model takes them as independent arrivals, so the callee's wait, and the latency of whoever waits
  for it, is understated: 0.1% to 60% in simulations, the more the fewer its workers and the busier it is (about 60% at one
  worker at any load; at 4 workers, 4-16% at 20-40% busy; at 8 workers and 20% busy, under 0.5%). A warning is given when the
  batch is larger than the callee's workers (when the count is only a lower bound, for a batch of 3 or more: the calls were served one
  after another, so the callee was never seen with more workers than that, and a pair may have a second worker that was never needed) or when the callee's
  utilization times the batch over its workers reaches 15%. Several shapes of one service that each call one callee N times at once are one warning, with
  their shares added. It is given for the fixed fan-outs read as before too (a warning only: their
  numbers are unchanged). The Demo's callees are at 1-2% utilization, where the effect is under 0.05 ms.
- **The mean count is only as good as the capture's calls.** A call count that varies because CLIENT spans were lost or
  sampled out looks the same as one that varies for a reason; the warning says to check the exporters when it should be fixed.
- **A mixture is as good as the shapes it is given.** Spans whose start times are whole milliseconds (Node.js, which the
  Demo's front end is) can make two calls that follow each other within a millisecond look like calls at once. The tool reads
  such a caller by where its callees' spans are ([Clocks and CLIENT spans](#clocks-and-client-spans)), which the callee's finer clock
  gives; a callee without a SERVER span, or a caller whose spans start on whole milliseconds but are not found as such (fewer than 100
  spans, or under 99% of them), is read by the stamps as before. The callee's load is unaffected either way.
- **A service that calls one callee dozens or hundreds of times in a row per visit** (a query per row) is read as a mean count, as any
  varying count is. A call shape of more than 200 stages is not fitted to a stage template. The search for the stages a visit ran
  grows with the product of the two shapes' lengths; it used to grow exponentially and ran for minutes at 36 calls in a row.
- **Calls that start after the visit's span has ended** on an edge that is not async (5-95% of them) are, in a service that
  fits the stage template, left out of the callee's load, as before; in a mixture and in the mean count they are in it.

### Streams and other long server spans

A gRPC server stream, a watch or a long poll is one SERVER span that lasts as long as the client stays connected, minutes or hours. The model reads a
SERVER span as a visit, one request that holds a worker, and would read the stream as a visit that long. In the OpenTelemetry Demo three flagd
`EventStream` spans of 600 s were all of flagd's busy time (its other 6,824 visits lasted 0.07 ms at the median): a service time of 380 ms and 53%
utilization, and the callers' latencies ten to a thousand times too high, with no warning, until the tool learned to look for them.

A SERVER span is taken for one when it lasts **at least a second, a tenth of the time over which the capture's server spans start, and a thousand times
its service's median**. If such spans hold **5% or more of a service's busy time** the capture is **refused**, before anything else is read, with the
service, the number of spans, the longest (its name when it lasted a second or more, and its trace id), the median visit and the share of the busy
time. Below 5% a warning names them and they stay in the means. A stream shows up in a capture that is the Collector's whole file, or is cut by the time spans ended
(a stream that began before the window is still open in it); a window cut by the time its **traces started** does not hold it. Cut the window that way (the
repository's `otelcap cut`, in `validation/cluster/otel/`), or drop long SERVER spans with a filter in the Collector. A legitimate request that is slow, but a small part
of the capture's duration or of its service's time, is not a stream.

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
on the callee's clock. Two things then depend on the clocks being in step, and a third on how finely they stamp:

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

- **Spans that start on whole milliseconds.** The OpenTelemetry JavaScript SDK (Node.js) stamps the start of its spans, CLIENT and SERVER alike,
  on a whole millisecond and reads the end from a finer clock; so the start lies before the work began, by up to a millisecond, and the span reads
  longer than the call took (the callees' spans start 1.05 ms after such a caller's CLIENT spans on the Demo, against 0.2-0.4 ms after a Go caller's). In the Demo 100% of the front end's span starts are whole milliseconds, against
  0.0-0.3% for the other services. A pod whose spans start on a whole millisecond in at least 99% of them (and at least 100 of them) is found from its own
  spans, and the calls of its visits are then read differently:
  - Calls that follow one another within a millisecond overlap in the spans though not in time (the second is stamped before the first has
    ended). They are **ordered by where their callees' spans start**, and two calls are in one stage unless the callees' spans leave a gap of at least a
    quarter of the round trip's overhead (the client span's time less the server span's, the two calls' mean) between them; the stages' time is counted
    stage by stage. Calls to a callee that has no SERVER span, and every other caller, are read by their own starts.
  - The end of a CLIENT span may follow the end of the visit's span by up to a millisecond (a quarter of a millisecond otherwise) and the call still be
    taken as one the visit waited for: such a caller closes its span before the last client span's end is read (on the Demo, 8.4% of the front end's calls to the
    cart and 9.3% of its calls to the ad service end more than a quarter of a millisecond after its span, by up to 0.8 ms; the tool took them for calls it did not wait
    for, and warned of it, before this allowance).
  On the Demo this turned "cart x2" (7.6% of the front end's visits) and "cart then cart" (9.7%) into one shape, "cart then cart" (17.3%), where
  the callee's spans show the calls in a row on 99.9% of the visits. A stamp that starts early also makes the client span longer, so the hop of such a caller
  ([The network time of a call](#the-network-time-of-a-call)) holds that half millisecond.

So export CLIENT spans for calls, or keep the clocks in step.

### The network time of a call

The time between a call's CLIENT span and the SERVER span under it, the client span's duration less the server
span's, is the network time of the call plus any wait outside the callee's span (for a worker, when the span starts
once one has taken the request). The model adds a **hop** for each call, and reads it per edge (caller to callee): the
same service can be reached over links of different speeds, a Go caller and a Node.js caller (on the Demo,
product-catalog is 0.39 ms from checkout and 1.10 ms from the front end), so the front end's calls are not charged the
checkout's time or the reverse. A callee with several callers has the mean of its edges' hops by the calls each made.

- **A callee at most 30% busy** (by the model) **with 50 calls or more on the edge**: the hop is the mean gap less the
  wait the model predicts outside the callee's span. A network time has a spread (on the Demo 0.2-0.3 ms between its
  quietest tenth and its mean, the top 1% of the gaps being 28% of the mean), and at this load the model's wait is a few
  hundredths of a millisecond, so the rest is network, not queueing. Spans that start at arrival hold the wait
  inside them and the gap is the network alone.
- **Otherwise**, a busy callee, or an edge the model's wait explains most of (above three quarters of the gap's excess over
  its quietest tenth), or fewer than 50 calls (then the pooled gaps of the callee): the hop is the quietest tenth of the
  gaps, which holds no queue when a tenth of the calls find a free worker. The queue is then the model's own, and
  the report's `seen wait` checks it.

What the first branch cannot tell is waiting that the model does not show (calls made at once that reach a one-worker
callee together, a stall) from network time: it lands in the hop, a warning says so when the hop is more than 1 ms and
three times the quietest tenth, and the report marks the services that took it ("hop from the mean" under the table; `hop_from_mean`
in the JSON), because their `seen wait`, and the hop's part of their `seen ms`, are then set by the hop and no longer
check the model. Above 30% busy the hop stays the quietest tenth and the spread of the network time (0.1-0.3 ms per call on
the Demo) stays unmodelled.

A caller whose SDK stamps span starts on whole milliseconds (Node.js's does, [Clocks and CLIENT spans](#clocks-and-client-spans)) reads its CLIENT
spans longer than the calls took, probably by about half a millisecond on average (the start is early and the end is not; not separated out from the event loop's own delay); its hop holds that (on the Demo the
front end's is 1.10 ms to product-catalog against 0.39 ms from the Go checkout). That is what the callers measured, and what the model gives back; it is not all network time.
One hop per edge also charges a lone call and each of several calls made together the same time, though they differ (on the Demo, from the front end to the catalogue:
0.96 ms alone, 1.27 ms for each of four made together, 1.10 ms the edge's mean): with the call shapes read right this is part of why the front end's level is 2.3% above its callers' on
the Demo's shipped mix ([ACCURACY.md](ACCURACY.md#9-real-software-on-a-real-cluster-the-opentelemetry-demo); about half of the 0.10 ms is this, the rest is not attributed).

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
| more than 5% broken traces | the queue rebuild needs every request, and the call structure whole requests; the message names the edges and services that lost spans |
| no SERVER spans, or no usable spans | nothing to infer from (check the path, and that the files are traces) |
| a service above `--max-rho` at the observed load, or after the change | the model covers steady load below the limit only; past 100% there is no steady state |
| visits that take more than 12 call shapes, the rarer ones holding more than 5% of the calling visits | the model has a fixed count, a mean count, sequential, parallel and staged calls, and a mixture of up to 12 call shapes ([above](#calls-per-visit-that-vary-and-visits-of-several-call-shapes)) |
| a negative mean service time after the queue rebuild | the spans contradict a first-come-first-served queue: clock skew between pods, or a `--workers` count below the real one |
| SERVER spans that are streams or other calls that stay open, holding 5% or more of a service's busy time | read as visits they would be the service's time and utilization ([above](#streams-and-other-long-server-spans)) |
| a call graph with a cycle | the model needs a directed acyclic graph (a service that calls itself over the network; nested spans of one pod are read as one first, see above) |

[USAGE.md](USAGE.md#9-exit-codes-and-refusals) shows the exact messages and what to do about each.
