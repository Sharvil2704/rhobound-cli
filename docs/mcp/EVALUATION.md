# rhobound-mcp: evaluation plan

What must be measured before rhobound-mcp claims anything, how to test whether its gate helps a coding agent, how to
run that test with Meta's Muse Spark models, which open-world tests use real systems and real changes, what it costs,
and what runs on which hardware. Status: **a plan. No study described here has been run.** Every result, whatever it
shows, is to be published with its pre-registration. Tags [V] [K] [U] [E] [D] are as in
[ARCHITECTURE.md](ARCHITECTURE.md); [S] marks a secondary source.

---

## 0. The order of evidence

The gate is a product claim stacked on three scientific claims. They are tested in this order, and each later step
waits for the earlier one:

1. **The model's own accuracy on real software under load** (section 2, the stress study). Today queueing has been
   judged on real clusters only on the repository's own queue-like demo, up to 58% utilization, and not at all on
   third-party software.
2. **That a measured difference transfers to production** (section 2, the transfer study). Every measured label rests
   on it.
3. **That the gate is calibrated in an environment** (seeded regressions, the A/A floor, the rate cross-check).
   Enforcement is earned per environment ([ARCHITECTURE.md](ARCHITECTURE.md), 6.6).
4. **Only then: whether it helps an agent** (sections 4-5) and **whether it speeds up delivery** (section 6, field
   trial).

---

## 1. "Meta's Spark models": what they are

### 1.1 Identification

"Spark" plus "Meta" names Meta Superintelligence Labs' **Muse Spark** family. The only other "Spark" coding model found
is OpenAI's GPT-5.3-Codex-Spark (2026-02-12), which is not Meta's [V: https://openai.com/index/introducing-gpt-5-3-codex-spark/].

| date | release | source |
|---|---|---|
| 2026-04-08 | Muse Spark, closed, in the Meta AI app; API in private preview to selected partners | [V: https://about.fb.com/news/2026/04/introducing-muse-spark-meta-superintelligence-labs/] |
| 2026-07-08 | Muse Spark 1.1 on the Meta Model API, public preview in the US, from $1.25 input / $4.25 output per million tokens | [V: https://dev.meta.ai/resources/blog/build-with-muse-spark/] |
| 2026-08-05 | Muse Spark 1.2 and Muse Code (beta), a terminal coding agent | [V: https://research.meta.ai/blog/introducing-muse-code-and-muse-spark-1-2] |
| 2026-09-02 | Muse Spark 1.3 | [V: https://research.meta.ai/blog/introducing-muse-spark-1-3] |
| 2026-10-15 | **Muse Spark Open**: open weights, 816B total / 42B active mixture of experts, 1M-token context; "shares the same base model as Muse Spark 1.3", with additional safety post-training | [V: https://research.meta.ai/blog/muse-spark-open, https://pytorch.org/blog/muse-spark-open/, https://huggingface.co/meta-models/Muse-Spark-open-816B-A42B] |

For a reproducible study the relevant member is **Muse Spark Open**: its weights can be pinned. The API models (1.3
and earlier) share its base but change on the server.

### 1.2 Access, on AWS first

- **Amazon SageMaker JumpStart**, since 2026-10-15, in us-east-1 and us-east-2: the NVFP4 variant on
  `ml.p5e.48xlarge`, the BF16 variant on `ml.p6-b300.48xlarge`, an OpenAI-compatible chat payload, billed per
  instance-hour while the endpoint runs [V:
  https://aws.amazon.com/blogs/machine-learning/metas-muse-spark-open-now-available-in-amazon-sagemaker-jumpstart/].
  `ml.p5e.48xlarge` costs about $73 per hour [S: a third-party price list; not checked on an AWS page]. GPU endpoint
  quotas are commonly zero by default [K]: request the quota when the study is approved. Native Amazon Bedrock
  availability was not found [U].
- **Meta Model API** (`https://api.meta.ai/v1`): `muse-spark-1.3` and earlier, OpenAI-, Anthropic- and
  Responses-compatible, with parallel and streamed tool calls [V: https://dev.meta.ai/docs/]. The docs also list
  `-contributor` model ids in a "discounted Contributor mode"; what that mode does with prompts is not stated [U].
  **Contributor ids are never used for held-out tasks or judges.**
- **Hosted providers** for Muse Spark Open (Together, Fireworks, OpenRouter and others) suit pilots; they choose their
  own quantization, and routers may switch provider between calls [K].
- **Self-hosting** needs at least 700 GB of GPU memory for NVFP4 and 2 TB for BF16 (model card).

### 1.3 Tool use and MCP

- Tool calling: yes. The API supports parallel and streamed tool calls, and the model card says the open model was
  trained for "tool use, sequential tool invocation, and failure recovery" [V].
- **The tool-call wire format and chat template are not documented** for self-hosting with vLLM or SGLang [V: the
  model card]. A wrong parser causes malformed tool calls, which would hurt tool-heavy arms more than the baseline. A
  **tool-calling smoke test, fixed in advance**, therefore decides whether the model is included (section 4.2).
- MCP is not mentioned on any Meta page read [V]. It is not needed on Meta's side: OpenHands and Inspect turn MCP tools
  into the model's function calls. Bash-only harnesses (mini-swe-agent) use the `rhobound` CLI twins, which print the
  same JSON. Whether Muse Code speaks MCP is [U].
- Settings from the model card: reasoning effort `low | medium | high | xhigh`, default xhigh; temperature 1.0,
  top_p 1.0. Temperature 1.0 makes runs vary: at least 3 seeds per cell.

### 1.4 Licence

The Muse Model License is not an open-source licence. Use, research and embedding are allowed; a group with more
than USD 20 million in yearly revenue must sign a separate agreement before offering the model as a service; an
acceptable use policy applies; results built with the model carry the attribution "Built with Muse Spark Open"
[V: the model card]. The licence has no clause on publishing evaluations. A model trained or distilled on its outputs
would be a derivative under the licence, so a judge distilled from Muse outputs could not ship under Apache-2.0.
rhobound-mcp only calls a model; the licence does not reach its code, and weights are never redistributed.

### 1.5 Published scores, and what they are

| model | benchmark | score | who measured |
|---|---|---|---|
| Muse Spark Open | Terminal-Bench 2.1 | 76.4 | Meta, self-reported, harness Terminus 2 (model card) |
| Muse Spark Open | DeepSWE 1.1 | 60 | Meta, self-reported, "preferred harness" |
| Muse Spark Open | MCP-Atlas | 89.2 | Meta, self-reported |
| Muse Spark 1.1 | SWE-Bench Pro (public) | 61.50 ± 3.10 | Scale, mini-swe-agent, 250 turns [V: https://labs.scale.com/leaderboard/swe_bench_pro_public] |

Not verified: secondary reports of Muse Spark 1.3 scores (chart images only on Meta's page), and the training cutoff
of Muse Spark Open, which is not stated [V]. Our runs would be the first third-party agentic latency numbers for the
open model; they are presented as such, never as a model ranking.

---

## 2. Accuracy validation before any claim

Each study has a pass criterion fixed before it runs, and is published whatever it shows.

| id | study | pass criterion | unlocks |
|---|---|---|---|
| M1 | **Stress study** on real software: the OpenTelemetry Demo with load and CPU limits raised into the band, and DeathStarBench Hotel Reservation (through a Collector). Injections of +1, +3 and +10 ms of CPU work or sleep in one service, and **one variance-only injection** (the same mean, more spread). Busiest utilization about 30, 55 and 75%; open-loop (constant arrival rate) and closed-loop load; steady and ramped. ABAB interleaving; at least 10 A/A pairs per level | the change error at each load within the simulator's p90 (16.3% of the change, 2.27% of the latency); otherwise the documentation changes | moves `max_utilization_validated` (up or down); any public accuracy claim about real software |
| M2 | **Harness A/A**: the same digest in both arms, per service class | the false-delta 95% quantile no wider than the paired band | the paired measurement's band |
| M3 | **Transfer study**: 10-20 real changes (seeded injections and real merged pull requests); a paired A/B of old vs new image (one pod per arm, side by side) against the change measured in production after-captures | agreement within 2 combined standard errors or 0.2 ms on at least 80% of changes | `transfer_validated` for the environment; the signed-profile path; enforcement of measured labels |
| M4 | **Load independence** of service time, by an equivalence test (TOST) against a declared margin (3% of own time [D]), per language and runtime | the share of services where flatness is shown is reported | pooling load levels |
| M5 | **Variance transfer**: the `cs2` difference in the A/B against production | as M3 | a variance patch in the engine |
| M6 | **Per-environment seeded regressions** at the gated load: `n_seeded` = 40 by default, the four injection kinds (+1, +3, +10 ms and variance-only) 10 times each [E: an exact one-sided binomial test against a nominal 10% exceedance rate then rejects at 8 or more exceedances (size 4.2%) and detects a true rate of 25% with about 82% power] | band exceedance not above its nominal rate (that binomial test); errors within the band | enforcement in that environment |
| M7 | **Rate cross-check**: the trace entry rate against a load balancer, API Gateway, ingress or load-generator count | within 5% [D] on every gated window | utilization-based verdicts in enforce mode |
| M8 | **Monotonicity** of the entry mean in added own time, call probability and call count, on the simulator grid | no violation beyond numerical tolerance | range corners and budgets without the "assumed" label |
| M9 | **Judge**: structural ranges and rankings against measured outcomes; robustness to renamed identifiers, misleading comments and reordered hunks | better than leverage plus measurement on AUROC, with a confidence interval clear of zero; the precision of its escalations reported | judge ranges influencing anything beyond `estimated-judge` |
| M10 | **Tail-only share** in every study: regressions with the mean within threshold and p99 beyond | reported, not gated | the gate's stated ceiling |
| M11 | **Budget clustering**: predicted changes relative to the threshold, per arm, and the false-pass rate inside the band | reported | any claim that budgets let changes go closer to a limit safely |

The transfer study (M3) comes **before** any signing, registry or harness machinery is built: if transfer fails, that
machinery would protect numbers that can never pass.

---

## 3. Which benchmarks a mean-latency gate can act on

| benchmark | what it scores | can the gate act on it? |
|---|---|---|
| SWE-bench Verified, Pro, Live, Multimodal; Terminal-Bench; LiveCodeBench | issue resolution, terminal tasks, programming problems | **no**: no services, no load. Used only as no-harm controls |
| SWE-Perf, GSO, SWE-fficiency, EffiBench-X, KernelBench | single-process or single-kernel speed-ups | **no**. A replay audit found 11 of 140 SWE-Perf, 39 of 102 GSO and 411 of 498 SWE-fficiency reference speed-ups valid on cross-machine replay [V: https://arxiv.org/abs/2607.01211] |
| AIOpsLab, ITBench, SREGym | detecting and mitigating injected faults | not code changes; reusable for workloads and telemetry |
| **MicroPerf-Bench** | average end-to-end request latency of microservice systems under a mixed workload after the agent's repair | **the one that fits**, with the caveats below |

### 3.1 MicroPerf-Bench, as published

[V: https://arxiv.org/html/2610.29695v1; repository https://github.com/zyzcjnb/microperf, MIT; paper CC BY 4.0]

- 65 instances on 7 open microservice systems (DeathStarBench Social Network, Media Service and Hotel Reservation;
  Robot Shop; Spring PetClinic Microservices; MartianBank; Pitstop), 9 anti-patterns (8 instantiated). The labels are
  mostly call-graph changes: chatty service 24, nano-service 21, hub-like dependency 17, service chain 11. An
  instance may carry several labels (35 carry one, 30 combine two or three), so the per-pattern counts add up to more
  than 65.
- Score per instance: `S = clamp(100 x (L_D - L_O) / (L_D - L_R), 0, 100)`, with `L_D` the degraded latency, `L_R`
  the reference and `L_O` the agent's. Gates: all functional tests pass, and the error rate is at most 1 point above
  the degraded version's.
- **Bed:** Docker Compose on one dedicated dual-socket server (Intel Xeon Platinum 8562Y+, 384 GB), fixed CPU and
  memory limits per container; `L_D` and `L_R` measured three times, then frozen; requests at a fixed rate with a fixed
  endpoint mix; timed-out requests count as errors and are excluded from the latency average; 90 s warm-up, three
  averaged measurements, 3 runs per configuration; 2 h per instance and 20 minutes per command.
- **Load:** the paper calls its workloads non-saturated and gives no utilization.
- **Results:** best configuration 42.0 (OpenHands with GLM). Full-score rates 9.2-22.6%. Hub-like dependency scored
  21.6, explained by agents relieving only part of the serialization or moving the bottleneck, depending on whether
  the hub is on the critical path; service chain scored 31.3, its zero scores dominated by correctness errors (38.9%).
  23.1-50.8% of instances are flaky across runs.
- **A profiling aid** (distributed trace extraction) reached 47.7 against 39.4 for the same configuration, in one run,
  with one system (Pitstop) regressing. That is evidence that a trace breakdown helps, which is the arm rhobound must
  beat, not evidence for a queueing model.
- **Tracing:** several systems run Jaeger with a configured sampling rate, and the agent's prompt forbids disabling it
  or lowering the rate. rhobound needs unsampled traces or a known share, so each system's sampler is checked first,
  and Jaeger spans are converted to OTLP through a Collector.
- **Contamination:** the authors sanitized identifiers, comments, documentation and git history, and ran a
  memorization probe with low overlap.

---

## 4. The agentic-coding study

### 4.1 Design rules

- **Run MicroPerf as published.** Docker Compose on one dedicated x86 host per concurrent trial, the same CPU and
  memory limits, nothing else running during measurement. Re-measure `L_D` and `L_R` three times on our host. Report
  only differences between arms inside the study, never a comparison with the published 42.0. Which AWS instance class
  best matches the paper's host is [U]; a bare-metal x86 instance avoids a hypervisor; whether all seven systems build
  on arm64 is [U], so Graviton is not used for this study.
- **A separate "MicroPerf under load" variant** raises the load so that the busiest service is at 40-75%. It is a
  different benchmark, published with its load script, measured utilization and A/A floor.
- **Measurement access is a condition of the study, not an accident.** In MicroPerf the agent may run the scored
  workload itself, so a baseline agent already has the end-to-end truth. Two conditions, fixed in advance:
  - **M-full**: the agent may run the scored workload (MicroPerf's default). The gate can then add only localization
    and speed.
  - **M-low**: the agent may run only a low-rate smoke load (20-30% of the scored rate) or a per-service A/B. This
    mirrors production, where nobody load-tests at production scale per commit, and is where a queueing model can
    earn its keep.
  A **measurement-matched control** gives the no-gate arm a "measure" action with the same minutes and machine-hours as
  the gate arm's measurements.
- **Expressibility census.** Before the study, each of the 65 instances is classified by whether its reference fix
  can be expressed as an own-time change, as a structural change (once structural operations exist), or not at all
  (merging services, database contention). Gate arms run only on the expressible subset, and the subset's size is a
  result.
- **Bench mode.** No human exists in a benchmark. The server runs with the bench profile (`"profile": "bench"` in its
  configuration; ARCHITECTURE.md 5.3), which is recorded in every run record: inconclusive counts as not passing; the
  agent receives `decide_with` and may act on it inside its budget; measurement requests are pre-authorized and their
  time is charged to the arm; prompts never say "ask a human". A single bench-only action, `submit_candidate`, builds
  the candidate from the agent's tree, measures it on the bed's host while the system is otherwise idle, and returns
  once (a single blocking wait under the harness's command limit); polls and turns are recorded.
- **Score the change, not the filter.** Every arm's final change is scored by the same full-load measurement,
  whatever its verdict. The frozen gate is also run offline on the no-gate arm's final changes (the filter effect,
  with no extra trials). Two reference policies, block-all and pass-all, are reported, with joint outcomes: success
  with no regression, success with a regression, abstention, failure. Task success must be non-inferior within a
  margin set in advance (5 points).
- **Reward-hacking guards.** The agent cannot write to the load generator, the Collector, sampling, resource limits or
  replica counts (outside its writable tree, diff-filtered); the harness, load generator and Collector are pinned by
  digest; breaking tracing makes rhobound refuse, which counts as not passing; each arm is also measured from outside
  its own spans (client-side latency at the load generator).

### 4.2 Phase 0: no agents

| step | what | go criterion |
|---|---|---|
| P0a bed | MicroPerf as published on dedicated x86 hosts; `L_D` and `L_R` re-measured three times per instance | every admitted instance builds; the degraded latency is stable across the three runs |
| P0b readiness | Jaeger to OTLP through a Collector; `rhobound check` on the degraded and reference systems at the scored workload; utilization; sampling share known | at least 20 admissible instances; the admission rate reported (the open-world intake measure of DATA.md, section 17) |
| P0c expressibility | the census above | a pre-registered subset list |
| P0d calibration | seeded +1, +3 and +10 ms injections and a variance-only injection on admissible systems; A/A floor; **inconclusive rate** at the busy band | A/A detectable effect below the regression threshold; inconclusive rate under 30% on expressible changes; errors within the documented band. If this fails, the policy or the inputs are fixed, not the agent prompt |
| P0e model | tool-calling smoke test of each candidate model through the MCP bridge: schema-valid call rate, parallel calls | at least a pre-set rate of valid calls; the provider, quantization and reasoning effort recorded; provider fallback disabled |

### 4.3 Phase 1: localization (needs only the first build)

The cheapest thing that might raise MicroPerf scores is telling the agent where latency is tight before it writes
code: per-service utilization, leverage, calls per visit per edge and own time (the `context` and `budget` tools).

- Task: MicroPerf repair on the admissible subset, condition M-full.
- **Primary cell**: one model that passed P0e, OpenHands with the bench profile (at most 5 tools).
- Arms:
  - **A0i**: the same latency instructions, budget statement and loop advice as the tool arms, and no tool. This
    controls for instructions, which another performance benchmark credits for part of its gain (PerfBench: about 3%
    to about 20% on 81 .NET tasks with performance-aware tooling **and** instructions [V: https://arxiv.org/abs/2509.24091]);
  - **A-trace**: a plain per-service trace summary of the same capture (mean span duration, calls per request, no
    model), which is what a trace UI or MicroPerf's own profiling aid gives;
  - **A-ctx**: rhobound's `context` and `budget`.
- Primary comparisons, pre-registered in a fixed sequence: first A-ctx against A0i on the score; only if that
  succeeds, A-ctx against A-trace. A win over A0i alone shows only that traces help. "rhobound's model helps" needs
  the second comparison too; at native (non-saturated) load A-trace is expected to tie.
- Three seeds per instance.

### 4.4 Phase 2: the gate (after structural operations, bench mode and the transfer study exist)

- Tasks: **T1, regression avoidance built as "reverse MicroPerf"**: feature tasks on the cleaned reference systems
  whose naive implementation re-injects an anti-pattern, reusing MicroPerf's functional tests; and **T2**, MicroPerf
  repair on the expressible subset.
- Conditions: M-full and M-low.
- Arms: **A0i**; **A3-additive**, a sham with the identical tool interface whose `predict` is a naive additive model
  (the sum of deltas along the call graph, no queueing); **A3**, the product (preview loop plus the CI gate with
  measured deltas, with up to N bounded revision rounds after a CI verdict, N fixed in advance).
- **Primary comparison**: A3 against A3-additive on the full-load measurement of the final change, regardless of
  verdict. This is the cleanest live test of "the queueing model matters to agent outcomes".
- Exploratory arms, under the multiplicity rules of 4.6: A4 (A3 plus a judge from a different model family), A4s (a
  same-family judge, the self-preference test), A5 (the judge alone). In the product the judge gives structural ranges
  only; delta estimation in milliseconds by a judge (task T5) is offline research whose output never enters the gate.
  Judges are blind to the arm and to the agent's self-assessment; their escalations are scored on a confusion matrix
  against the measured outcome, false blocks counted against them.

### 4.5 Metrics

- **Primary:** the recovery score (MicroPerf's formula, on our bed) for T2; for T1, regressions shipped judged by the
  full-load measurement of the final change, with a threshold above the A/A detectable effect; task success
  (functional tests and the error-rate gate).
- **Gate quality:** predicted against measured change, in % of the change and % of the latency; the verdict confusion
  matrix (pass, block, inconclusive against regression or not), **inconclusive counted as a non-pass, never dropped**;
  the inconclusive rate and its codes.
- **Agent loop:** the share of runs that call `budget` before writing code; previews per change and the
  declared-delta trajectory; pull requests opened after a preview block with no revision; whether judge suggestions
  survive re-prediction; protocol compliance (malformed tool calls per 1,000).
- **Cost:** tokens in and out, tool-definition tokens per turn, dollars, agent and gate wall-clock, machine-hours,
  endpoint hours.
- **The honest ceiling:** p95 and p99 recorded, not scored; the share of shipped regressions that were tail-only.
- **Not in the benchmark:** delivery speed (DORA). A 2-hour synthetic trial with one deploy cannot measure change
  failure rate or recovery time. The benchmark reports only time to an accepted change and the gate's own wall-clock;
  delivery is tested in the field trial (section 6, OW4).

### 4.6 Statistics

- **One primary cell and one primary comparison per phase**, pre-registered; every other comparison exploratory, under
  Holm's correction or a fixed-sequence gatekeeping order.
- **Clustering.** Runs nest in instances, and many instances are flaky. With a design effect of 1 + (m - 1) x ICC at m
  = 3 seeds, the detectable effect on 65 instances is about +8 to +10 points at an ICC of 0.3, and +8.8 to +11.3 at
  0.5 [E], not the +6 to +8 a calculation treating 195 pairs as independent gives. The ICC is taken from the pilot.
- **Zero-inflated scores**: a hurdle (two-part) model, with full recovery as a binary co-primary.
- **Intention to treat**: a run that crashes or misses a field counts as a failure of its arm; exclusions are reported
  by arm and cause. Tool arms have more ways to crash, so excluding them would bias toward the tool.
- **No-harm controls** (SWE-bench Pro public tasks, a pinned Terminal-Bench version, with the tools offered but
  irrelevant): 100 paired tasks can rule out only about 11 points of harm at 80% power [E]; a 5-point margin needs
  about 500. The no-harm hypothesis is therefore stated as token and tool-call overhead, which can be measured
  precisely, unless the study affords about 500 tasks.

### 4.7 Contamination and leakage

- Our own injected forks of the OpenTelemetry Demo and Online Boutique get MicroPerf's treatment: a cleaned
  reference; sanitized identifiers, comments and git history; a verbatim-overlap probe. Renaming alone is not enough.
- Sandbox egress to source forges is blocked; package mirrors only.
- Standard model ids only (never contributor modes) for tasks and judges.
- The date boundary for "after the model" is Muse Spark Open's release (2026-10-15), with the note that a base shared
  with 1.3 (2026-09-02) puts the true cutoff earlier.
- Reviewers and scorers see changes with every rhobound artifact stripped.

### 4.8 Running the models

- Pilots on hosted per-token APIs; pinned JumpStart weights only for the main study, co-located with the bed in
  us-east-1 or us-east-2 so that model latency does not differ by arm.
- Recorded per run: provider, quantization (NVFP4 or BF16), reasoning effort, rate-limit waits and API latency
  (excluded from or capped in the wall-clock budget).
- Muse Spark 1.3 and Muse Spark Open are separate cells, never pooled.
- Every arm's model calls go through one recording proxy, so tokens are measured the same way everywhere.
- Published results carry "Built with Muse Spark Open".

---

## 5. Run records

Every trial writes a `rhobound.run-record/v1`: the captures before and after with their manifest digests; the load
specification (generator, version, arrival process, rate, mix, warm-up); the measured utilization; image digests; the
source and values of every change input with its label; the gate output (tool version, policy digest, report digest,
verdict, codes); the measured truth (per-entry mean, A/A noise, p95 and p99 recorded); the environment (instance type,
CPU model, kernel, orchestrator version, CPU limits, replicas, placement); the agent trace (model id or weight hash,
harness and version, tokens, tool calls, wall-clock, polls, bench-mode flag); task metadata (id, family, source and
date, split, expressibility class). A record with a missing field counts as a failure of its arm. Predictions are
registered in the Object Lock ledger, with the tool version and policy digest, before the after-capture is opened.

---

## 6. Open-world tests: real systems, real changes, no tuning

Rules for all four: one frozen binary, policy and threshold set, recorded by hash; no per-system parameters; every
refusal, inconclusive and failure reported; raw captures published where licences allow.

| test | what | measures | conditions |
|---|---|---|---|
| **OW1** retrospective pull-request replay | merged pull requests of the OpenTelemetry Demo and Online Boutique dated after the freeze: build both images, measure the difference, gate, then measure the deployed change at the busy band | **specificity**: false blocks and inconclusives on real, mostly null changes | the yield of eligible service-code pull requests is estimated from the repositories' merge history before committing; **paired with seeded injections** for sensitivity |
| **OW2** prospective agent work | agents (no-gate and gate arms) work real open issues in forks; changes deploy to a staging copy at the busy band through the gate | whether changes are mergeable and how they move latency | a written rubric, two raters, an agreement statistic, rhobound artifacts stripped |
| **OW3** third-party submissions | teams send a capture, a change and a measured outcome in the format of [DATA.md](DATA.md) | prediction error on systems we did not build; the intake share | each prediction's hash registered in the ledger (or a signed git tag) **before** the after-capture is opened |
| **OW4** field trial | volunteer teams run the stdio server in their own agents in advisory mode for several weeks | whether the loop is used; whether previews predicted CI verdicts; delivery metrics (lead time, change failure rate, recovery time, rework) | consent terms; telemetry limited to counts, latencies and verdicts (no traces, no code); a note that volunteers are a selected sample. **The delivery hypothesis lives here**: if instability metrics do not fall by more than the gate's added time, the report says the gate made delivery slower |

---

## 7. Cost, and what runs on which hardware

| where | what runs there |
|---|---|
| any laptop or CI runner, either architecture, no cloud | unit tests, the simulator accuracy studies, contract tests, the scripted-agent test (block, revise, inconclusive, A/B record, pass, with no model and a canned judge answer, on `testdata/mcp/loop`), the CLI-twin parity test, the monotonicity study (M8; not built yet: the budget tests check bisection monotonicity on the test captures only) |
| one Linux host with Docker | the repository's kind end-to-end test (about 13 minutes) |
| AWS, x86 dedicated or bare-metal hosts | MicroPerf as published, one host per concurrent trial |
| AWS, EKS or EC2 with fixed, non-burstable instance types | the stress study (M1), the transfer study (M3), OW1-OW3; a separate node for the load generator and for the Collector |
| AWS, SageMaker JumpStart in us-east-1/2 | Muse Spark Open for the main study |
| hosted APIs | pilots |

Cost sketch [E], prices [K] or [S]:
- **Phase 1** (about 20 instances x 3 arms x 3 seeds = 180 trials; at most 2 h of agent time plus about 0.5 h of build
  and scoring per trial, on a 64-vCPU x86 host at about $3.2 per hour): hosts about $1.4k; tokens about $0.2-0.5k at
  0.5-2 million tokens per trial (MicroPerf reports a session at about 0.8 million) and the Muse Spark 1.1 API price.
  A JumpStart endpoint instead: about 45 endpoint-hours at about $73 per hour, about $3.3k, so pilots use per-token
  APIs.
- **Phase 2**: about 120-290 runs per arm (more once clustering is counted) x 3 arms x 2 conditions, roughly
  700-1,700 trials: about $6-14k of hosts plus $1-5k of tokens, plus about 10-15 minutes of scoring per final change.
- **Transfer study (M3)**: 10-20 changes, each a paired A/B of 25-60 minutes on 2-3 nodes plus two after-capture
  windows: tens of dollars of compute; the cost is engineering time.
- **Stress study (M1)**: 2 systems x 3 loads x (10 A/A pairs + 4 injections x 3 repeats) x 2 load shapes x 2 loop
  types: about 1,000 runs of about 15 minutes on a 5-node cluster of 4-vCPU arm64 instances, about $250-400 of EC2 [E],
  plus a node for the load generator.
- Endpoint hours, host hours and token counts go into every run record; the concurrency assumption (how many
  trajectories at once, and so how many dedicated hosts) is stated in the pre-registration.

## 8. What this programme cannot show

- Anything about tails, bursts, retries, timeouts, autoscaling, throttling, cold starts, or load above 0.85.
- Whether a change is correct or secure.
- Gains on SWE-bench, Terminal-Bench or the single-repository speed-up suites.
- A ranking of models: the design compares arms within one model and one harness.
- Queueing accuracy on real software in general: M1 tests two systems.

## 9. Not verified

- Which AWS instance class best matches MicroPerf's host, and whether its systems build on arm64.
- Which MicroPerf systems sample in Jaeger, and at what rate; whether its load tools are open-loop.
- Muse Spark Open's tool-call wire format, its training cutoff, its hosted prices, and Bedrock availability.
- What the Meta Model API's contributor mode does with prompts.
- The `ml.p5e.48xlarge` hourly price and default GPU quotas.
- The yield of eligible OW1 pull requests after 2026-10-15.
- The intra-class correlations assumed in 4.6: illustrations, to be replaced by the pilot's.

## 10. Sources

- MicroPerf-Bench: https://arxiv.org/abs/2610.29695, https://arxiv.org/html/2610.29695v1,
  https://github.com/zyzcjnb/microperf
- Replay audit of performance benchmarks: https://arxiv.org/abs/2607.01211
- SWE-bench Pro: https://arxiv.org/abs/2509.16941; Scale leaderboard: https://labs.scale.com/leaderboard/swe_bench_pro_public
- SWE-Perf https://arxiv.org/abs/2507.12415; GSO https://arxiv.org/abs/2505.23671; SWE-fficiency
  https://arxiv.org/abs/2511.06090; Terminal-Bench https://arxiv.org/abs/2601.11868; SREGym https://arxiv.org/abs/2605.07161;
  AIOpsLab https://arxiv.org/abs/2501.06706
- PerfBench: https://arxiv.org/abs/2509.24091
- Muse Spark: https://about.fb.com/news/2026/04/introducing-muse-spark-meta-superintelligence-labs/,
  https://dev.meta.ai/resources/blog/build-with-muse-spark/, https://dev.meta.ai/docs/,
  https://research.meta.ai/blog/introducing-muse-code-and-muse-spark-1-2,
  https://research.meta.ai/blog/introducing-muse-spark-1-3, https://research.meta.ai/blog/muse-spark-open,
  https://pytorch.org/blog/muse-spark-open/, https://huggingface.co/meta-models/Muse-Spark-open-816B-A42B,
  https://aws.amazon.com/blogs/machine-learning/metas-muse-spark-open-now-available-in-amazon-sagemaker-jumpstart/
- Harnesses: https://github.com/SWE-agent/mini-swe-agent, https://inspect.aisi.org.uk/tools-mcp.html,
  https://docs.openhands.dev/openhands/usage/settings/mcp-settings
- Systems: https://opentelemetry.io/docs/demo/feature-flags/, https://github.com/GoogleCloudPlatform/microservices-demo,
  https://github.com/delimitrou/DeathStarBench
- DORA metrics: https://dora.dev/guides/dora-metrics/history/
