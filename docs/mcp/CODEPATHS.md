# Code paths and control-flow graphs: a staged research plan

Can rhobound be extended from services to code paths, so that a change's effect on mean latency can be estimated
before the change is deployed or measured, and so that a stronger "judge" model can reason about code paths with
rhobound's numbers? This document is a **research plan**. **Nothing in it is claimed to work**, and no output of it
feeds a gate until its stage's validation passes. Tags [V] [K] [U] [E] [D] are as in [ARCHITECTURE.md](ARCHITECTURE.md).

---

## 0. The answer in brief

- **Structure, yes; time, no.** From a diff, a static call graph and the control-flow graphs (CFGs) of the changed
  functions, a tool can tell deterministically which routes a change can reach, which remote calls it adds or removes,
  whether a new call is sequential, parallel or fire-and-forget, whether it sits in a loop or under a branch, and
  whether new work lands before the handler's first call out (it holds a worker) or after it. Those are exactly the
  structural parameters rhobound's topology already has.
- **A CFG cannot give** the time per call, a branch's probability, or a data-dependent loop's trip count. Those need
  measurement or the traces. No published work predicts absolute time from code well enough to feed a queue: the best
  learned model at large scale is deployed as a pre-filter that narrows the search, not as a predictor of the size of
  a regression [V: https://arxiv.org/abs/2208.04351].
- **Before any measurement, what can honestly be said is a sensitivity and a budget, not a latency**: leverage (entry
  milliseconds per millisecond of a service's own time per visit) and the largest per-visit addition a policy allows.
  That exists in the first build ([ARCHITECTURE.md](ARCHITECTURE.md), 4.7).
- **The judge** ranks, explains, proposes what to measure, and fills structural unknowns with labelled ranges. It never
  produces a millisecond figure that enters the model.
- **Order:** deterministic structure first, measurement second, the judge third. Go first, other languages later, each
  shipped only with its measured recall.

---

## 1. What a code change must become

The model's unit is the **service**: a mean own time per visit `S` that holds a worker (up to the first call out),
glue time after it that holds none, calls with probabilities and counts, and parallel or async markers. A code change
enters the model only in that vocabulary:

| change in code | in the model's vocabulary |
|---|---|
| more or less CPU work in the handler before its first call out | own time per visit, weighted by the share of visits on the affected routes |
| work after the first call out | glue per visit (needs the `glue_ms` operation) |
| a new remote call on some routes | a new child with probability = the routes' share of visits (times a branch probability if conditional) |
| a remote call inside a loop | a repeated child; mean count = route share times the expected trip count |
| calls moved into goroutines and joined | a parallel stage |
| a call in a goroutine that is not joined, or sent after the response | an async call |
| a removed call | a child removed, or its probability lowered |

Gaps the extension must close (each is new engine work):
- **G1, route to shape.** The fit has no per-route view: routes are read only to drop health probes. Placing "a new
  call on `POST /orders` only" needs the inference to keep each visit's route (`http.route` or `rpc.method`) and the
  call-shape distribution per route.
- **G2, a structural patch.** `--patch` cannot add a call, set a probability, repeat a call, mark one async or add
  glue. A small set of structural operations applied to the fit's topology is needed (`add_call`, `remove_call`,
  `set_p`, `scale_count`, `set_async`, `make_parallel`, `glue_ms`; [DATA.md](DATA.md), 11.2).
- **G3, variance.** A route-specific change also changes the variance of the service's time, which the model's wait
  depends on. A diff cannot give it. This is a stated approximation, and a measured variance change makes the result
  inconclusive until the engine has a variance patch.
- **G4, build identity.** The capture does not record which commit produced the traces. Without that tie, the static
  graph may describe code other than the one traced.

A structural operation on an existing callee assumes the new call costs the callee's **mean** visit. A new call may
hit a heavier endpoint, a new edge has no measured network time, and calls made at once in a loop arrive together,
which the model understates (by 0.2% to 62% in the public simulator tests). So every structural operation carries
`callee_cost: assumed-mean-visit`, is labelled `estimated-static`, and in-loop or parallel additions raise the
batch-arrival doubt.

---

## 2. Mapping spans to code: the join ladder

| rung | what the capture has | how a route maps to code | what becomes possible |
|---|---|---|---|
| J0 | service spans only | through a repository map: path globs to `service.name` (`rhobound.services.json`) | which services a diff touches; service-level leverage and budget |
| J1 | `http.route` or `rpc.method` on SERVER spans, and build identity | static extraction of router registrations (Go `net/http` patterns, gRPC service registration) maps routes to handler functions | per-route shares; diff to handler to route |
| J2 | `code.function.name` on SERVER spans | direct, cross-checked against J1 | a check of the static router extraction |
| J3 | `code.*` attributes or `code.stacktrace` on CLIENT spans | each existing call site maps to an observed edge | measured per-visit frequencies of existing call sites |
| J4 | profile samples linked to spans, with symbols | function to CPU time per request, per route | the current cost of existing functions |

Notes:
- `code.function.name`, `code.file.path` and `code.line.number` are stable semantic conventions; `http.route` is
  stable and must be a low-cardinality template; `rpc.method` is a release candidate [V:
  https://opentelemetry.io/docs/specs/semconv/registry/attributes/code/,
  https://opentelemetry.io/docs/specs/semconv/registry/attributes/http/].
- Whether any auto-instrumentation sets `code.function.name` on SERVER or CLIENT spans by default is [U]; assume it is
  absent until a capture shows it. Go's `otelhttp` sets `http.route` from the Go 1.22+ ServeMux pattern in its recent
  releases [V: https://github.com/open-telemetry/opentelemetry-go-contrib/blob/main/CHANGELOG.md].
- OpenTelemetry Profiles (public alpha in 2026) can link sample groups to trace and span ids [V:
  https://opentelemetry.io/blog/2026/profiles-alpha]; its wire format has changed during development.
- **Name normalization** is a trap: runtime names (`example.com/shop/checkout.(*Server).PlaceOrder`, `pkg.foo.func5`)
  and `go/ssa` names (`(*example.com/shop/checkout.Server).PlaceOrder`, `pkg.foo$1`) differ. One normalizer with a
  test per form (method, pointer method, closure, generic instantiation) is needed; the forms are from prior knowledge
  [K] until those tests exist.
- **Build identity**: OCI `org.opencontainers.image.revision` or SLSA provenance's source commit
  [V: https://github.com/opencontainers/image-spec/blob/main/annotations.md, https://slsa.dev/spec/v1.0/provenance].
  `service.version` alone is a label, not proof. No tie, no code-path analysis for that service; the service-level
  prediction still runs.

---

## 3. Stages

Each stage has a pass criterion fixed before it runs. A stage that fails stays research; later stages do not start on
top of it.

### Stage 0: leverage and budget (deterministic; in the first build)

- **What:** leverage by a +1 ms finite difference; the budget by bisection; the safe budget (the largest addition
  whose predicted change plus the model band stays under the threshold, by the same bisection); per visit only.
- **Validation:**
  - finite-difference leverage against the measured change on the simulator and the repository's kind demo;
  - monotonicity of the entry mean in added own time, call probability and count on the 288-scenario simulator grid
    (where it may fail: parallel branches, whose expected maximum moves with correlation, and shared callees). Until it
    passes, every budget is printed "monotonicity assumed (untested)";
  - in agent studies, the distribution of predicted changes relative to the threshold, and the false-pass rate inside
    the band: budgets pull changes toward the threshold, where the gate is least reliable.

### Stage 1: from a diff to routes (deterministic structure; Go first)

- **What:**
  1. Parse the old and the new tree (`golang.org/x/tools/go/packages`). A function is changed when its normalized
     syntax tree differs (comments and positions ignored), not when lines overlap the diff. Changed dependencies (a
     `go.mod` change) make every function of the changed module versions a candidate.
  2. Build the call graph of both programs (VTA over a CHA initial graph [V:
     https://pkg.go.dev/golang.org/x/tools/go/callgraph/vta]) and take the union, so a call removed by the change still
     counts as reaching.
  3. Reverse reachability from the changed functions to handler functions, the way `govulncheck` reaches vulnerable
     symbols [V: https://pkg.go.dev/golang.org/x/vuln/cmd/govulncheck]. Handlers come from router registrations (J1),
     cross-checked with `code.function.name` where spans carry it (J2).
  4. Report the method per edge, and every place the analysis gave up (reflection, `unsafe`, plugins, interface values
     set at init): those routes are "may be affected, unknown", never "unaffected".
- **Output:** the services and routes a change touches, with route shares from the fit.
- **Validation:**
  - **route recall** against coverage: build each service with `-cover`, drive each route with load, and read the
    functions each route executes (`GOCOVERDIR`, `go tool covdata`) [V: https://go.dev/doc/build-cover]. A route the
    analysis calls unaffected whose coverage includes a changed function is a miss. Target: **zero misses** on the test
    set;
  - precision reported, not gated;
  - mutation tests: inject a change into a known function, check the routes.
- **Cost lever even before stage 2:** `go list -deps` per service image tells which images a change can affect, so
  only those are measured.

### Stage 2: CFG facts to structural operations (deterministic, with named unknowns)

- **What:** for each path from a handler to a changed function, and every remote-call site on it (client libraries
  from a known list: `net/http.Client.Do`, gRPC `ClientConn.Invoke` and `NewStream`, `database/sql`, Redis, Kafka
  producers):
  - call sites added or removed between the old and the new program;
  - placement: before the handler's first remote call (own time), after it (glue), or after the response is written
    (async);
  - concurrency: inside a joined goroutine (`WaitGroup.Wait`, `errgroup.Wait`, a channel receive) is parallel; not
    joined is async; when the join is ambiguous, both forms are reported;
  - loops: a constant bound is a number; a range over a request field is a **named unknown** (`len(req.Items)`);
    anything else is unknown;
  - branches: a call under a condition gets a named probability unknown; a feature-flag evaluation names the flag.
  - Following the component-model literature, a loop or branch is kept only when it contains a remote call; everything
    else folds into own time [V: https://arxiv.org/pdf/2006.16953].
- **Needs:** G1 (route shares) and G2 (structural operations) in the engine.
- **Output:** a code-path card per affected route (section 4), whose structural operations are labelled
  `estimated-static`.
- **Validation:** inject structural mutations into the demo services: a call added; a call in a loop of k; a call in a
  joined goroutine; a call after the response. For each, compare the patched topology with the topology `rhobound
  infer` reads from an after-capture (edges, mean counts, parallel and async), and the predicted entry mean with the
  measured one, scored as the accuracy documents score changes today.

### Stage 3: measured time

The mean is linear: the change of a service's own time is the sum, over affected routes and changed functions, of
route share x calls per visit x change of cost per call. Structure gives which functions and routes and bounds the
counts; measurement gives the cost.

| source | what it gives | when it is trusted |
|---|---|---|
| A/B of the two images (`measured-ab`), and signed profiles later (`measured-paired`) | the whole handler, framework and allocation effects included, at the chosen load | after the transfer study ([EVALUATION.md](EVALUATION.md), M3) |
| continuous profiles linked to spans (J4) | the current cost of existing functions per route; enough for deletions and scalings | as a cross-check of the A/B |
| microbenchmarks of the changed functions, old against new, interleaved on one instance (Go benchmark format, JMH, Google Benchmark, pytest-benchmark JSON) | the cost of a pure function | only for a service class where their deltas agreed with A/B deltas within their errors on a set of changes; until then labelled `estimated-microbench`, never a gate input |
| CPU profiles alone | CPU per call | never as own time: a visit holds a worker for more than its CPU time |

Microbenchmark variability in public clouds is large; same-instance interleaving is required
[V: https://research.chalmers.se/en/publication/511491]. Pre-production A/B testing at large scale shows the noise study
is half the work [V: https://www.usenix.org/conference/osdi24/presentation/chow].

- **Validation:** per change, the microbenchmark delta, the A/B delta and the after-capture own-time delta, each with
  its standard error; agreement reported per service class.

### Stage 4: the judge model

- **Allowed roles:**
  1. fill structural unknowns that stages 1-2 named (a loop's trip count, a branch probability, a new call's target)
     with **ranges and evidence**, labelled; the prediction is evaluated at both ends of every range;
  2. rank and explain the levers using leverage and budgets ("the new per-item call is the cost; batching it keeps the
     change within budget"), returning typed operations that must be predicted again;
  3. propose the measurement plan, and write benchmark code whose results are then measured, not believed;
  4. review paths the analysis gave up on, as hypotheses for a dynamic run.
- **Forbidden:** any millisecond figure that enters the model; relaxing a verdict; removing a finding; overriding a
  refusal. An escalation makes the result inconclusive, never a block ([ARCHITECTURE.md](ARCHITECTURE.md), 7).
- **Delta estimation in milliseconds by a judge** is a separate offline research task whose output never enters the
  gate.
- **Why so narrow:** LLM judges show position, verbosity and self-enhancement biases [V:
  https://arxiv.org/abs/2306.05685]; code judges are moved by response order, variable names and misleading comments
  [V: https://arxiv.org/abs/2507.10535]; every judge tested was moved by semantics-preserving changes [V:
  https://arxiv.org/abs/2505.16222]. Models that solve contest problems fail to write code under complexity
  constraints [V: https://arxiv.org/pdf/2503.15242].
- **Validation:** a pre-registered, blind set of historical and injected changes with measured outcomes. Compare the
  judge, a static risk heuristic, leverage alone, and leverage plus measurement on ranking (AUROC) and calibration
  (Brier) for "the entry mean grows by more than the threshold". Robustness: renamed identifiers, misleading comments,
  reordered hunks must not change the answer. A judge from the coder's family is compared with one from another
  family (self-preference). Pass: better than leverage plus measurement on AUROC, with a confidence interval clear of
  zero.

### Stage 5: other languages

Python, Java and JavaScript or TypeScript analyses are markedly less complete than Go's: published call-graph recall
of about 70% for PyCG (repository archived in 2023) [V: https://arxiv.org/abs/2103.00587], 75.9% raised to 88.1% for
JavaScript with approximate interpretation [V: https://cs.au.dk/~amoeller/papers/approx], and enterprise Java
frameworks "woefully incomplete" without framework models [V: https://blog.acolyer.org/2020/09/25/jackee]. Each
language ships only with its route recall measured by the stage-1 test against that runtime's coverage tool.

---

## 4. Outputs

A code-path card per affected route (illustrative):

```json
{
  "schema": "rhobound-codepath.card/v0",
  "build": {"service": "checkout", "old": {"commit": "<sha>", "image": "sha256:<digest>"},
            "new": {"commit": "<sha>"}},
  "join_rung": "J1",
  "route": "POST /orders", "route_share": 0.31, "reach": "vta", "observed_in_capture": true,
  "changed_functions": [{"name": "example.com/shop/checkout.(*Server).PlaceOrder", "kind": "modified"}],
  "structural": [
    {"op": "add_call", "service": "checkout", "callee": "inventory", "placement": "sequential", "phase": "glue",
     "count": {"named_unknown": "K1"}, "callee_cost": "assumed-mean-visit", "label": "estimated-static"}
  ],
  "work": [{"function": "example.com/shop/checkout.validateCart", "phase": "own", "needs": "measurement"}],
  "unknowns": [{"id": "K1", "what": "trips of the loop over req.Items", "range": {"lo": 1, "hi": null}}],
  "budget": {"service": "checkout", "per": "visit", "max_own_ms": 1.9, "safe_own_ms": 1.1,
             "assumes": "monotone entry mean (untested)"},
  "measurement_needed": ["ab:checkout"],
  "gave_up": []
}
```

Rules: every card carries its join rung, its reachability method, its unknowns and the measurement still needed; no
card states a latency; an unknown without a range keeps the prediction inconclusive.

---

## 5. Data required, accepted and refused

| input | required form | accepted | refused (code) |
|---|---|---|---|
| source | git trees at the base and head commits; module root per service; build tags; GOOS/GOARCH | full trees, or a base tree plus a patch that applies cleanly | a diff without its base tree (`code.no_base_tree`); generated code missing from the tree |
| build identity | the traced image digest tied to a commit | OCI `org.opencontainers.image.revision`; SLSA provenance with a source commit | an image with no commit tie (`code.build_unbound`): code-path analysis refused for that service |
| route key | `http.route` or `rpc.method` on SERVER spans | stable and release-candidate names, and the deprecated `rpc.service` plus method | only id-bearing `url.path` (`code.route_key_missing`, doubt): falls back to J0; paths are never templated by guessing |
| call-site identity (J3) | `code.*` or `code.stacktrace` on CLIENT spans | the runtime's native stack format | truncated or symbol-less stacks |
| feature flags | the variant each request evaluated | `feature_flag.key` and `feature_flag.result.variant` | flag state known only from a dashboard |
| profiles (J4) | CPU profiles with symbols, linked to spans | pprof; OTLP Profiles at a pinned version | images or HTML flame graphs; symbol-less or unlinked profiles (unlinked ones only for service-level cost) |
| microbenchmarks | per-invocation cost, old and new, with repetitions, machine type and commit | the Go benchmark format [V: https://go.googlesource.com/proposal/+/master/design/14313-benchmark-format.md]; Google Benchmark, JMH, pytest-benchmark JSON | summaries without counts and variance; old and new from different machines |
| judge answers | structured ranges per open question, with evidence | `rhobound-mcp.judge-answer/v1` | milliseconds (`judge.ms_forbidden`); free text is commentary for humans |
| language | Go in the first research stages | | others (`code.language_unsupported`) until their recall is measured |

---

## 6. Security and placement

- The analyzer is a separate binary in its own module (it needs `golang.org/x/tools`, BSD-3-Clause), so the core CLI
  keeps no dependencies and the agent-facing server does not grow.
- **The server never holds credentials to a version-control system.** Code-path analysis runs either locally over stdio
  (on the agent's own checkout), or on source tarballs that CI uploads to a principal-bound prefix. A tool argument
  never chooses a repository: otherwise an agent working on one repository could read another's code through the
  server.
- Diff excerpts given to a judge are marked untrusted, bounded, and never echoed back to the coding agent; only typed
  operations return.
- The analyzer is a pure function of (old tree, new tree, fit summary), cached by (commit pair, fit digest). On AWS it
  fits a container job (CodeBuild) for large programs; small and medium Go modules fit a Lambda worker (up to 900 s
  and 10 GB) [V: https://docs.aws.amazon.com/lambda/latest/dg/gettingstarted-limits.html]. Microbenchmarks and A/B
  measurements never run in Lambda: they belong on the production instance type.

## 7. Prior work, and what it implies

| work | finding | implication |
|---|---|---|
| PerfScope (ICSE 2014) [V: https://web.eecs.umich.edu/~ryanph/paper/perfscope.bib] | static performance-risk triage of commits | static analysis is good at where to measure, not at the number |
| ORM anti-pattern detection (ICSE 2014) [V: https://ece.uwaterloo.ca/~wshang/pubs/peter_icse2014.pdf] | database access in loops, ranked by measured impact | "a remote call in a loop" is the pattern that matters, and needs a measured count |
| Palladio and component-model extraction [V: https://arxiv.org/pdf/2006.16953] | code structure plus measured resource demands feed performance models | the closest precedent; rhobound is the trace-built, mean-only variant |
| Learned regression prediction at Meta (AST 2023) [V: https://arxiv.org/abs/2208.04351] | deployed as a pre-filter narrowing the search by up to 43% | learned code models triage; they do not predict the size |
| ServiceLab (OSDI 2024) [V: https://www.usenix.org/conference/osdi24/presentation/chow] | pre-production A/B detects regressions as small as 0.01%, after a study of machine factors | the numbers come from measurement on matched machines |
| PerfBench [V: https://arxiv.org/abs/2509.24091] | on 81 .NET performance bugs an agent went from about 3% to about 20% with performance-aware tooling and instructions to benchmark | measurement tools and instructions help; they are the bar a prediction tool must beat |
| GSO, SWE-Perf, SWE-fficiency [V: https://arxiv.org/abs/2505.23671, https://arxiv.org/abs/2507.12415, https://arxiv.org/abs/2511.06090] | agents struggle to locate bottlenecks in repository-level optimization | localization is where help is most needed |

## 8. Not verified

- Whether OpenTelemetry auto-instrumentation sets `code.function.name` on SERVER or CLIENT spans by default.
- The exact runtime and `go/ssa` function-name forms.
- `govulncheck`'s exact call-graph algorithm.
- Which MCP clients would let a judge run inside the client in a way the server can trust (it cannot, by design: such
  answers are `client-asserted`).
- How common dynamically built routes (from configuration at start-up) are in target code bases; they defeat J1.
- The monotonicity of the entry mean that budgets rest on (stage 0).
