# rhobound for Muse Code: install, use and judge

This guide covers:
- installing rhobound for Meta's Muse Code;
- using it while you code;
- judging its predictions;
- running its gate in CI.

`README.md` beside it is the short version. Each `rhobound` and `rhobound-mcp` command cited here is run by the
repository's tests against the real binaries, to check that its verbs and flags exist. The walkthrough in section 4
is run line by line, and its exit codes and results are checked. The `muse` commands and the CI scripts' calls to a
model are not run here (section 10).

**What rhobound does.** It predicts how a code change moves the **mean** latency of a service call graph, from
OpenTelemetry traces: before you code, how much a service may add; after, how the change moves each entry point.
Predictions are advisory. The gate in CI decides.

## 1. What you install, and where it runs

| part | what it is | runs as | started by |
|---|---|---|---|
| `rhobound` | the engine: fits traces, predicts, gates | you | the server, for each tool call; CI |
| `rhobound-mcp` | the MCP server Muse talks to; also `init` and the hooks' `muse-hook` | you | Muse, at each session start (stdio) |
| the plugin (`integrations/muse-code`) | three skills and two hooks | you, outside Muse's sandbox (hooks) | Muse |
| `~/.config/rhobound-mcp/config.json` | the engine (pinned by sha256), captures, policies, state folder | | written by `init` |
| one entry in `~/.config/muse/settings.json` | registers the server, `mode: optional` | | written by `init` |

The server is registered in Muse's documented settings, not inside the plugin.
- **Why:** a plugin's own server entries are less well understood (Muse drops their `env` and `args`).
- **What `mode: optional` buys:** a server that cannot start is skipped with a warning instead of aborting the run.
- **The flip side:** the plugin does nothing until `init` has written that entry and a new session has started.

## 2. Install

**Requirements:**
- Go 1.25 or later;
- git;
- a POSIX `/bin/sh`;
- Muse Code with plugins;
- for real use, a capture: a folder of OpenTelemetry traces of your services under load (see `docs/USAGE.md`).

**2.1 Build the two binaries,** from the repository's root, into a folder outside any repository you will work in:

```sh
go build -o ~/.local/bin/rhobound ./cmd/rhobound
(cd mcp && go build -o ~/.local/bin/rhobound-mcp ./cmd/rhobound-mcp)
```

Check them:
- `rhobound version --json`;
- `rhobound-mcp version --json`;
- `rhobound-mcp muse-hook api`, which prints the hook protocol, `1`.

**2.2 Install and approve the plugin.**

```sh
muse plugins install ./integrations/muse-code
muse plugins approve rhobound
```

**2.3 Check a capture, and choose a policy.** `rhobound check FOLDER` checks a capture against the data contract:
- exit 0: admitted;
- 4: refused, with the reasons;
- 2: an error.

A policy (`rhobound.policy/v1`) sets the gate's limits:
- `max_entry_mean_change_pct`: the threshold, 5% in `examples/mcp/policy.example.json`;
- `max_fit_age_h`: how old a fit may be;
- `trusted_labels`: which measurements may make a preview pass;
- `max_preview_attempts`.

Start from the example.

**2.4 Register the server with `init`.** Run it without `--write` first. It is a dry run: it prints one JSON report
and writes nothing.

```sh
rhobound-mcp init --engine ~/.local/bin/rhobound --capture NAME=FOLDER --policy default=POLICY.json
```

Read the report before you write anything:

| field | must be |
|---|---|
| `config.check` | `ok`: the configuration passes the server's own start checks (it loads, and the engine's sha256 is the one pinned) |
| `config.engine.path`, `config.engine.sha256` | the binary you built, and the sha256 that will be pinned |
| `muse_settings.entry.command` | the `rhobound-mcp` Muse will start at every session |
| `config.captures`, `config.policies`, `config.state_dir` | what the server will read, and where it keeps its records |
| `muse_settings.action` | `add`, `replace` or `keep`: what changes in Muse's settings |
| `muse_settings.kept`, `dropped`, `parked` | on a replace: the members of your existing entry init keeps, the ones it drops (`url`, `headers`, which contradict a stdio entry; they stay in the backup), and whether it kept your `"enabled": false` |

Then write it, and check that Muse's settings hold the entry:

```sh
rhobound-mcp init --engine ~/.local/bin/rhobound --capture NAME=FOLDER --policy default=POLICY.json --write
rhobound-mcp init
```

What `--write` does:
- It writes the configuration (at most 0600, all paths absolute) and one settings entry:
  `mcp_servers.rhobound = {"transport": "stdio", "command": …, "args": ["stdio", "--config", …], "enabled": true,
  "mode": "optional"}`.
- Every other byte of `settings.json` stays as it was.
- Every file it replaces is kept as `FILE.rhobound-bak-<UTC time>`.
- It also writes `~/.local/state/rhobound-mcp/muse-registration.json`. That file tells the hooks which settings file
  init wrote; their environment may not carry `XDG_CONFIG_HOME`.

The last `init` (no flags) must report `muse_settings.action` `keep`. Run it again after any of:
- `muse plugins approve`, `update` or `disable`;
- `muse skills enable` or `disable`.

Muse may rewrite `settings.json` on any of these.

What init refuses, and why:

| refusal | why |
|---|---|
| a path inside the git work tree of the current folder (engine, server, configuration, state folder, capture, policy), unless you add `--allow-workspace-paths` | a repository's text could ask your agent to set rhobound up with the repository's own binaries, which would then run as you in every later session |
| a settings file that is not plain JSON, has no `schema_version` or one other than 1, holds both `mcp_servers` and `mcpServers` (Muse then disables MCP), or already has another entry running `rhobound-mcp` | init will not guess what Muse would read |
| a configuration that differs from the one the flags make | it is yours; `--force` replaces it (and backs it up) |

**2.5 Start a new Muse session.** The tools appear as:
- `mcp__rhobound__context`;
- `mcp__rhobound__budget`;
- `mcp__rhobound__predict`;
- `mcp__rhobound__explain`;
- `mcp__rhobound__fit_start`;
- `mcp__rhobound__job_status`.

The entry is user-level, so these six tool definitions and the server's instructions load in every repository. To
park the server, set `"enabled": false` in the entry; init keeps a false you set.

**2.6 Optional: the Stop reminder, per repository.** Commit `.rhobound/muse.json` holding exactly
`{"schema": "rhobound.muse/v1", "remind_predict": true}`.
- **What it does:** in that repository, a session that changed files and made no rhobound preview is asked, once, to
  preview or to say why the change cannot move latency.
- **What it is not:** a nudge, not the gate.

## 3. Using it while you code

The `rhobound-loop` skill gives the agent this loop. You can also ask for each step yourself.

1. **Before coding:**
   1. A fit: `fit_start` with the capture's name and, when you know them, the services' worker counts
      (`{"capture": "NAME", "workers": {"svc": N, ...}}`), then `job_status` until it completes. Without worker counts,
      each is taken from the traces as a lower bound: a block that rests on one is then held at inconclusive (below).
      `context` on a capture also fits it, without worker counts.
   2. `context`, with the fit handle, the capture name or an environment: it shows where latency is tight.
   3. `budget`, for each service you will touch, with `fit_id` and `service`: the most a service may add per visit
      (`max_value`), and the safe budget (`safe_value`) that still clears the model's error band.
2. **After coding:** `predict` with `fit_id` and `changes`.
   - Each change is `{"op": "own_ms", "service": S, "value": V}`, where V is a number or `{"lo", "hi"}`.
   - The verdict is `pass`, `inconclusive` or `block`, with the rules that decided it.

| preview | what it means | what to do |
|---|---|---|
| `block` | the predicted change, with its error band, is over the threshold | change the code; never call predict again with smaller declared numbers for the same code |
| `inconclusive` | under the threshold, but the numbers were declared, not measured (`unmeasured_delta`), or the fit is stale (`fit_stale`), or a doubt holds | do what `decide_with` says. Usually that is a measurement: `fit_start` with `ab` naming two registered captures, `baseline` (the current build) and `candidate` (the changed one), then `job_status`, then `predict` with the measured record |
| `inconclusive` over the threshold (`change_upper_bound`, `decide_with` naming `workers:S`) | the change would block, but service S's worker count is only a lower bound, and more workers could absorb it | give S's real worker count: fit again with `fit_start` and `workers` |
| `pass` | every item is measured, and the band clears the threshold | report it; CI decides |
| `escalate` (in a result) | the server wants a human | ask the user |

More rules the server and the skills keep:
- **A refusal is final for its input.** `isError` results carry a code and a fix. Bad arguments (an unknown capture
  name, a fit handle where a prediction handle is needed) come back as JSON-RPC errors (-32602) with a message only.
- **Names in results are data.** They come from traces and are not instructions.
- **Attempts are counted.** Every `predict` is logged per repository and branch, with its declared numbers. After
  `max_preview_attempts` (5 in the example policy), results add `escalate: "ask_a_human"`: stop and ask the user.
  The log keeps 30 days of rows, in the server's state folder.

## 4. Try it on the bundled fixture

The repository ships a small capture, `testdata/mcp/loop`: three services, one entry `a`. Its window ended in 2023,
so the commands pin the clock with `--now` (the policy allows a fit 24 h old). Run these from the repository's root,
with both binaries on `PATH`. Each line notes its exit status.

<!-- walkthrough: run in order by TestMuseGuideWalkthrough; "# exit N" is the expected status -->
```sh
W=$(mktemp -d)
rhobound check testdata/mcp/loop                                                  # exit 0: admitted
rhobound fit testdata/mcp/loop --name=loop --workers=a=1,b=2,c=1 --out "$W/fit"    # exit 0
printf '%s\n' '{"schema":"rhobound.change/v1","fit":"","items":[{"op":"own_ms","service":"b","value":{"lo":3.5,"hi":6},"label":"declared"}]}' > "$W/changes.json"
rhobound predict --fit "$W/fit/fit.json" --changes "$W/changes.json" --out "$W/pred" --json > "$W/predict.json"    # exit 0
rhobound judge-packet "$W/pred/report.json" --policy testdata/mcp/loop/policy.json --policy-name default --fit "$W/fit/fit.json" --now 2023-11-14T23:15:20Z --json > "$W/packet.json"    # exit 0
echo "sha256:$(tr -d '\n' < "$W/packet.json" | sha256sum | cut -d' ' -f1)"
rhobound judge-check testdata/mcp/loop/judge-answer.json --packet "$W/packet.json" --json    # exit 0: the canned answer cites that digest
rhobound gate "$W/pred/report.json" --policy testdata/mcp/loop/policy.json --now 2023-11-14T23:15:20Z --out "$W/gate" --judge-answer testdata/mcp/loop/judge-answer.json --judge-packet "$W/packet.json"    # exit 1: block
cat "$W/gate/verdict.txt"
rhobound-mcp init --engine "$(command -v rhobound)" --capture loop=testdata/mcp/loop --policy default=testdata/mcp/loop/policy.json --config "$W/config.json" --muse-settings "$W/settings.json"    # exit 1: the capture and policy are in this repository
rhobound-mcp init --engine "$(command -v rhobound)" --capture loop=testdata/mcp/loop --policy default=testdata/mcp/loop/policy.json --config "$W/config.json" --muse-settings "$W/settings.json" --allow-workspace-paths    # exit 0: a dry run; nothing is written
```

What you see:
- The first draft, own time `b` +3.5 to 6 ms declared, is a **block**. The change at `a` is +4.10 to +7.15 ms and the
  band +3.07 to +8.32 ms, over the 2.26 ms threshold (5% of `a`'s 45.22 ms).
- The digest echoed is the one the canned judge answer cites, so `judge-check` passes and prints only the answer's
  typed fields: decision `revise`, one expected operation (batch `b`'s calls to `c`, a `scale_count`), and a
  measurement to make. `predict` does not apply structural operations such as `scale_count` yet: such a suggestion
  is a note for the coder, whose next draft is predicted as usual.
- The gate records the answer as `client-asserted` in `gate.json` and still blocks: a judge cannot relax a verdict.
- The two `init` lines show the refusal of section 2.4: the fixture's files lie in this repository's work tree.

The scripted agent of the server's tests runs the rest of the loop with real numbers:
1. +0.4 ms declared: inconclusive;
2. an A/B of `loop-a` and `loop-b`: `b` +0.355 ms measured;
3. predict with that record: a pass.

`testdata/mcp/README.md` has each step. The tests pin the server's clock. A real server reads the real clock, so in
Muse every preview on this 2023 fixture is `fit_stale` under its own policy. To try the loop in Muse, register a copy
of `testdata/mcp/loop/policy.json` with `max_fit_age_h` raised (to 100000, say), and the three captures (section 7).

## 5. Judging a prediction

A judge reviews a prediction's **judge packet** (`rhobound-mcp.judge-packet/v1`), which holds:
- the prediction;
- the budgets and leverage of the changed services;
- the rules;
- the assumptions;
- any open questions.

It answers accept ("this is it"), revise ("it could be better", with typed changes to try) or escalate ("the packet
cannot settle it"). Three rules hold on every route:
- **A judge never supplies milliseconds, never relaxes a verdict and never overrides a refusal.** `rhobound
  judge-check` enforces this.
- **Only typed fields go back to the coding agent:** `decision`, `reasons[].code`, `assumptions`, `expected_ops` and
  `measure`.
- **`commentary` is for humans only.** It is wrapped as untrusted text.

At the gate, only `escalate` has an effect: it turns a pass into inconclusive; a block stays a block. Nothing a judge
answers makes a preview pass.

### 5.1 The answer

One `rhobound-mcp.judge-answer/v1` object (`docs/mcp/schemas/judge-answer.v1.json`):

| field | content |
|---|---|
| `schema` | `rhobound-mcp.judge-answer/v1` |
| `packet` | `sha256:` and the hex sha256 of the packet's canonical JSON (5.4 says how to get it) |
| `decision` | `accept`, `revise` or `escalate` |
| `reasons` | up to 16 `{"refs": [paths into the packet, e.g. "prediction.entries[0]"], "code": "over_budget"}`; codes are `[a-z_]` |
| `assumptions` | answers to the packet's `open_questions` only: `{"question": "Q1", "range": {"lo", "hi"}, "evidence": [...], "confidence": "low/medium/high"}` |
| `suggestions` | for `revise`: `{"rank": 1, "expected_ops": [change items]}`. A suggestion counts only through a new predict of the revised change. `predict` applies `own_ms`, `own_pct`, `workers` and `load_scale` today, and an answer may not use `own_ms` or `glue_ms` (they are milliseconds), so a suggestion a new predict can take as it is uses `own_pct`, `workers` or `load_scale`; structural ones (`scale_count`, `add_call` and the like) are notes for the coder |
| `measure` | `{"service", "kind": "ab" or "profile", "why_code"}`: what to measure |
| `commentary` | free text, at most 2 KB, for humans |

`testdata/mcp/loop/judge-answer.json` is a complete example.

`rhobound judge-check ANSWER.json --packet PACKET.json --json` checks an answer.
- **Exit 0:** it prints the typed fields and the provenance.
- **Exit 1:** a refusal, one of:
  - `judge.packet_mismatch`: the answer cites another packet; the message names this packet's digest;
  - `judge.ms_forbidden`: a millisecond figure;
  - `judge.loosening`: a reason asks to relax a rule;
  - `judge.answer_outside_question`;
  - `judge.evidence_unresolved`.
- **Exit 2:** the answer or the packet is not of its schema.

### 5.2 In CI: the independent judge

This is the review that counts as a second opinion: a model other than the coding agent's, pinned by id, run by CI
with its own credentials. The scripts are in `examples/judge/`.

```sh
JUDGE_ENDPOINT=https://api.example.com/v1 JUDGE_API_KEY=... JUDGE_MODEL_ID=MODEL bash examples/judge/openai-compatible.sh PREDICTION.json POLICY.json OUTDIR
JUDGE_MODEL_ID=MODEL bash examples/judge/bedrock-converse.sh PREDICTION.json POLICY.json OUTDIR
```

Each script runs five steps:
1. builds the packet with the CLI's `judge-packet` verb (set `FIT` to the fit record for budgets and leverage,
   and `POLICY_NAME` to the policy's configured name);
2. sends it with the `review_latency_impact` prompt at temperature 0;
3. checks the reply with `judge-check`;
4. records the request's digest;
5. runs the gate with `--judge-model` and `--judge-request`, so `gate.json` labels the answer `ci-judge`.

An answer `judge-check` refuses or cannot read is "judge unavailable": the step records it in
`OUTDIR/judge-unavailable.json`, never retries it into another answer, and runs the gate without it. The script's
exit status is always the gate's (0 pass, 1 block, 2 error, 3 inconclusive), so a judge that answers badly cannot
stop or pass a release on its own.

What the gate does not check: that the packet belongs to the prediction it gates. `ci-judge` is a label the CI step
asserts (with `--judge-model` and `--judge-request`), not something the gate verifies. The verdict is never relaxed
either way, but `gate.json` and `summary.md` show the answer as given.

Keep the key in the CI system's secret store. Choose a model family different from the coder's.

### 5.3 From the command line, on a prediction file

The walkthrough of section 4 is this route. In general:

```sh
rhobound fit FOLDER --name NAME --out FITDIR
rhobound predict --fit FITDIR/fit.json --changes CHANGES.json --out PREDDIR --json
rhobound judge-packet PREDDIR/report.json --policy POLICY.json --policy-name default --fit FITDIR/fit.json --json > PACKET.json
rhobound judge-check ANSWER.json --packet PACKET.json --json
rhobound gate PREDDIR/report.json --policy POLICY.json --out GATEDIR --judge-answer ANSWER.json --judge-packet PACKET.json
```

- `--fit` must be the fit the prediction was made from, or `judge-packet` refuses.
- Without `--workers`, the fit takes each service's worker count from the traces as a lower bound. A block that rests
  on such a count is held at inconclusive, since more workers could absorb the change. Pin the counts you know
  (`--workers=svc=N,...`), as the walkthrough does.
- `judge-packet --json` writes the canonical bytes and a newline, so `tr -d '\n' < PACKET.json | sha256sum` gives
  the digest the answer must cite.
- The gate exits 0 pass, 1 block, 2 error, 3 inconclusive; in a `set -e` script, test its status rather than stop
  at a block. It writes `verdict.txt` (one word), `gate.json` (every rule, the digests, the judge's provenance) and
  `summary.md`.

### 5.4 In Muse: the agent's own judge answer

The `rhobound-judge-review` skill is off by default (`muse skills enable rhobound-judge-review`). With it, the coding
agent answers in the judge's role.
- **What the answer is:** a structured second look, labelled `client-asserted`, not an independent review. The agent
  is judging its own work, and the packet passes through its hands. Show it to people as that.
- **The agent's steps:**
  1. Make a private folder: `D=$(mktemp -d)`.
  2. Get the packet for the prediction handle, by one of:
     - the MCP prompt `review_latency_impact` with `prediction_id`;
     - the resource `rhobound://judge-packet/<handle>`;
     - `mcp__rhobound__explain` with `target` = the handle and `section` = `judge_packet`.

     If it says `truncated`, stop.
     With `explain`, pass `max_chars` 8000 (the default, 2000, cuts even a small packet); the prompt and the resource
     return the whole packet.
  3. Save the packet to `$D/PACKET.json` unchanged: from `explain`, its result's structured `content` object (the
     text form adds a scope line after the JSON). Key order and spacing do not matter, since the digest is over the
     canonical JSON; never change a value.
  4. Get the digest: put `sha256:` and 64 zeros in the answer's `packet` field and run `judge-check` once. Its
     `judge.packet_mismatch` refusal names the packet's digest. Put that in.
  5. Run `judge-check` again. Show only the typed fields. If it refuses for any other reason, there is no checked
     answer.

## 6. The gate in CI

The authoritative decision is CI's. It runs the CLI's `gate` verb on a prediction built from its own lookups:
- the fit by digest;
- measured A/B records;
- the repository's policy file.

It maps the exit status to the check run:
- 0: success;
- 1: failure;
- 3: neutral while advisory, or a required review when enforcing.

A new environment is advisory until its readiness record earns enforcement. `docs/mcp/ARCHITECTURE.md` section 6
has the rules, the advisory-to-enforcing conditions and the mappings for GitHub Actions, CodePipeline and Argo
Rollouts.

## 7. Maintenance

| when | do |
|---|---|
| you rebuilt the engine | `rhobound-mcp init --repin` (a dry run: it shows the old and new sha256), then `rhobound-mcp init --repin --write`. Only for a rebuild you made yourself, from a source you trust: an engine that changed without you may have been replaced, so put the configured one back |
| you updated the plugin's files | `muse plugins update rhobound`, `muse plugins approve rhobound`, then `rhobound-mcp init` (expect `keep`) |
| Muse warns that the rhobound server was skipped | `rhobound-mcp init` shows why: `config.check` names the failed start check |
| you want the tools off for a while | set `"enabled": false` in the entry; init keeps it |
| a new capture or policy | init writes exactly the captures and policies its flags name, and `--capture` and `--policy` repeat: rerun the 2.4 command listing every capture and policy you want, add `--force` (the old configuration is backed up), then `--write`. For the A/B loop on the fixture: `--capture loop=testdata/mcp/loop --capture loop-a=testdata/mcp/loop/ab/baseline --capture loop-b=testdata/mcp/loop/ab/candidate` |
| uninstall | remove the `mcp_servers.rhobound` entry from `settings.json`, turn the plugin off (`muse plugins disable rhobound`, or remove it with Muse's plugin commands), and delete `~/.config/rhobound-mcp`, `~/.local/state/rhobound-mcp`, the plugin's data folder (`MUSE_PLUGIN_DATA_DIR`, else `~/.cache/rhobound-mcp/muse`) and the `*.rhobound-bak-*` backups beside `settings.json` and the configuration (they are copies of the whole earlier files, other entries' credentials included) |

## 8. Troubleshooting

| symptom | cause, and what to do |
|---|---|
| no `mcp__rhobound__` tools in a session | no entry, a parked entry, or a skipped server: run `rhobound-mcp init` and read `config.check` and `muse_settings.action`; start a new session after a write |
| `config.check: server.engine_mismatch` | the engine is not the pinned binary: see Maintenance |
| `config.check: engine.unusable` | the engine path is missing, not a regular file, or too large |
| `config.action: refused` | see the refusals in 2.4; `config.detail` names the paths |
| `muse_settings.action: refused` | `muse_settings.detail` says why; fix `settings.json` by hand |
| every preview is inconclusive with `fit_stale` | the capture's window is older than `max_fit_age_h`: use a recent capture |
| the Stop reminder never fires | the repository's `.rhobound/muse.json` is missing or not the exact form; or the server is not registered, enabled and passing its start checks; or the data folder is not usable (it must be a folder of yours that others cannot write, outside the repository; group-writable is fine); or the configuration's state folder lies inside the repository; or git refused the repository (another owner); or the session was started in the home folder itself and `rhobound-mcp` is not on `PATH`; or the home folder is itself the repository's root (a dotfiles repository in it, and a project without its own `.git`) |
| the reminder fired although you made no change | it counts every change to the repository's files, yours included, except what git ignores (`~/.config/git/ignore` is read; a `core.excludesFile` in `~/.gitconfig` is not) |

## 9. Security notes

**What runs, and where.** The hooks run as you, outside Muse's sandbox, at every session start and stop once the plugin
is approved. They are built so that a repository you open cannot use them:
- **Nothing from the workspace, and only a repository switch.** They never read a path, binary or setting from the
  workspace, and a repository's only control is the reminder's on/off file.
- **git runs listing names only,** with no filters, hooks, fsmonitor, transports or lazy fetches, and with its
  ownership check. Names are looked at inside the repository only.
- **A private sessions folder.** They write and remove only their own markers there, and only once the server is
  registered.
- **Environment values inside the repository are ignored:** `HOME`, `XDG_CONFIG_HOME`, the data folder and `PATH`
  entries.
- **Bounded reads, no stdout, fail-open exits.** Every file read is size-capped. The hooks never print to standard
  output, and every failure exits 0.

**Two cases a shell cannot catch.** Muse failing to open the hook script, and a machine that cannot start a process:
in both, `/bin/sh` exits 2, which Muse reads as a block.

**Setup.**
- **What init pins:** it pins the engine by sha256, and the server refuses another binary.
- **Inputs:** the setup skill takes init's inputs only from you, never from a repository's text, and init itself
  refuses paths inside the current work tree.
- **Review before `--write`:** read `config.engine.path` and `muse_settings.entry.command`.

**Judging.** Only the CI judge is independent. The in-Muse answer is the agent's own and is labelled
`client-asserted`.

## 10. Not yet checked on a real Muse build

Everything above is tested offline. The plugin manifest is tested against the plugin format as the community measured
it with `muse plugins validate`; Meta publishes no plugin page.

The first checks on a machine with Muse:
1. `muse plugins validate ./integrations/muse-code`: valid, no diagnostics.
2. `muse plugins hook test rhobound:rhobound-stop --fixture mcp/cmd/rhobound-mcp/testdata/muse/stop.json --json`, from
   a folder other than the plugin's: the script path resolves to the plugin's folder, and the hook exits 0.
3. After `muse plugins approve rhobound`, `rhobound-mcp init` reports `keep`: the entry survived Muse's own rewrite of
   `settings.json`.
4. One live session in an opted-in repository:
   - the reminder fires once after an edit with no preview, and not after a preview;
   - a server that cannot start is skipped with a warning, not an abort.
