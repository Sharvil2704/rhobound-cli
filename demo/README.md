# The demo, command by command

The commands for a short live demo on a laptop: macOS on Apple silicon, or Linux. Run them in order, in one terminal.
Parts 1 and 5 need no key and no cloud. Parts 3 and 4 call Meta's models with your Meta API key. Part 6 hosts
rhobound on AWS and runs the same agent against it.

## 0. Once: install and clone

On macOS:

```bash
brew install go python git jq bash coreutils
```

On Ubuntu: `sudo apt-get update && sudo apt-get install -y python3 git jq curl`, and Go 1.25 or later from
https://go.dev/dl/.

```bash
git clone -b rhobound-mcp https://github.com/Sharvil2704/rhobound-cli ~/rbd-video && cd ~/rbd-video
```

## 1. The engine, the agent's MCP loop and the plugin's install (offline, under a minute)

```bash
bash demo/judges.sh --quick
```

What it shows:
- the agent's loop over MCP on sample traces: line 5 `-> pass` (a measured change) and line 6 `-> block` (a change
  over the latency budget);
- the Muse Code plugin installed into a scratch home: `muse_settings keep`;
- the results tables.

Its part 4 checks the AWS bed's scripts, which need bash 4 or later and GNU coreutils. On macOS, put Homebrew's
coreutils first for this terminal, and part 4 runs too:

```bash
export PATH="$(brew --prefix coreutils)/libexec/gnubin:$PATH"
```

## 2. Your Meta API key, off screen

It is read without echo and stored in a file only you can read:

```bash
( umask 077; printf 'Meta API key: '; stty -echo; read -r K; stty echo; echo; printf '%s' "$K" > ~/.meta-key )
```

## 3. Muse Code asks rhobound before it codes (Muse Spark, live)

Muse Code 1.4.14 from Meta's release manifest (channel `muse-stable`), checked against the manifest's sha256:

```bash
curl -fsS "$(curl -fsS https://api.meta.ai/muse-code/channels/muse-stable | jq -r .manifest_url)" -o ~/muse-manifest.json
```

```bash
A=aarch64_macos && mkdir -p ~/.local/bin && curl -fsS "$(jq -r .artifacts.$A.url ~/muse-manifest.json)" -o ~/.local/bin/muse && echo "$(jq -r .artifacts.$A.checksum ~/muse-manifest.json)  $HOME/.local/bin/muse" | shasum -a 256 -c - && chmod 755 ~/.local/bin/muse
```

On Linux, use `A=aarch64_linux` or `A=x86_linux`. Then build rhobound and the MCP server, and put all three on this
terminal's `PATH`:

```bash
go build -o ~/.local/bin/rhobound ./cmd/rhobound && (cd mcp && go build -o ~/.local/bin/rhobound-mcp ./cmd/rhobound-mcp) && export PATH="$HOME/.local/bin:$PATH" && muse --version
```

Install the plugin, and copy the sample traces out of the clone. Their policy's fit-age limit is raised, because the
samples date from 2023:

```bash
muse plugins install ./integrations/muse-code && muse plugins approve rhobound
```

```bash
mkdir -p ~/rhobound-try/work && cp -r testdata/mcp/loop ~/rhobound-try/loop && jq '. + {max_fit_age_h: 1000000}' testdata/mcp/loop/policy.json > ~/rhobound-try/policy.json
```

Register the server: a dry run, then `--write`, then a check that says `keep` for both.

```bash
cd ~ && rhobound-mcp init --engine ~/.local/bin/rhobound --capture loop=$HOME/rhobound-try/loop --capture loop-a=$HOME/rhobound-try/loop/ab/baseline --capture loop-b=$HOME/rhobound-try/loop/ab/candidate --policy default=$HOME/rhobound-try/policy.json
```

```bash
rhobound-mcp init --engine ~/.local/bin/rhobound --capture loop=$HOME/rhobound-try/loop --capture loop-a=$HOME/rhobound-try/loop/ab/baseline --capture loop-b=$HOME/rhobound-try/loop/ab/candidate --policy default=$HOME/rhobound-try/policy.json --write
```

```bash
rhobound-mcp init
```

The live session. The prompt is [muse-prompt.md](muse-prompt.md): a feature adds 4 ms to service b; use rhobound
before writing code.

```bash
cd ~/rhobound-try/work && muse exec --json --api-key-stdin --model muse-spark-1.3 --reasoning-effort high --max-model-steps 30 --disable-approval --disable-request-user-input --trust-workspace --prompt-file ~/rbd-video/demo/muse-prompt.md < ~/.meta-key | tee ~/rhobound-try/events.jsonl | jq -j 'select(.payload_type == "run.output.delta") | .payload | (.delta // .text // .content // empty) | strings'
```

The rhobound tools it called, in order:

```bash
jq -r 'select(.payload_type == "task.lifecycle.proposed") | tostring' ~/rhobound-try/events.jsonl | grep -o 'mcp__rhobound__[a-z_]*'
```

What a run looked like (Linux arm64, 2026-11-04):

```
b's safe budget is 1.07 ms per visit (max 1.95 ms).
+4 ms to b: advisory block on entry a, CI decides.
Build it off the critical path — async/background, or parallel with c.
```

It called `fit_start`, `job_status`, `context`, `explain`, `budget` and `predict`. The numbers are rhobound's: b may add
1.07 ms per visit, and +4 ms takes entry a to +3.67 .. +5.73 ms against a 2.26-ms limit. The wording is the model's own.

## 4. A second Meta model judges the evidence (Muse Wonder, live)

```bash
cd ~/rbd-video && W=$HOME/rbd-judge && mkdir -p $W/judge && bin/rhobound fit testdata/mcp/loop --name=loop --workers=a=1,b=2,c=1 --out $W/fit
```

```bash
printf '%s\n' '{"schema":"rhobound.change/v1","fit":"","items":[{"op":"own_ms","service":"b","value":{"lo":3.5,"hi":6},"label":"declared"}]}' > $W/changes.json && bin/rhobound predict --fit $W/fit/fit.json --changes $W/changes.json --out $W/pred --json > $W/predict.json
```

```bash
bin/rhobound judge-packet $W/pred/report.json --policy testdata/mcp/loop/policy.json --policy-name default --fit $W/fit/fit.json --now 2023-11-14T23:15:20Z --json > $W/packet.json
```

The live call: [meta-judge.py](../bed/tools1/judge/meta-judge.py) sends the packet to `muse-wonder-1.0` on the Meta
Model API.

```bash
JUDGE_OUT=$W/judge JUDGE_KEY_CMD='cat ~/.meta-key' python3 -I bed/tools1/judge/meta-judge.py $W/packet.json > $W/answer.json && cat $W/judge/model.txt
```

```bash
bin/rhobound judge-check $W/answer.json --packet $W/packet.json --json | jq '{decision, reasons, expected_ops, measure}'
```

```bash
bin/rhobound gate $W/pred/report.json --policy testdata/mcp/loop/policy.json --now 2023-11-14T23:15:20Z --out $W/gate --judge-answer $W/answer.json --judge-packet $W/packet.json; cat $W/gate/verdict.txt
```

`judge-check` admits only a well-formed answer that cites this packet. The gate records it and still prints `block`: a
judge cannot relax a verdict. In the 2026-11-04 run Muse Wonder answered `escalate`, with reasons including `over_budget` and
`unmeasured_delta`, and asked for an A/B at a and a profile of b.

## 5. The challenge for your own agent

[rhobound-maze-challenge](https://github.com/Sharvil2704/rhobound-maze-challenge): the maze with a correct but slow
thumbnail filter in production. Its own check, which every fix must pass:

```bash
git clone https://github.com/Sharvil2704/rhobound-maze-challenge ~/maze-challenge && cd ~/maze-challenge/maze/app && go test ./internal/svc/media/ && go test -run XXX -bench Sharpen ./internal/svc/media/
```

## 6. Live on AWS: Muse Code asks rhobound running in the cloud

Muse Code on your laptop, with the rhobound plugin, calls rhobound's MCP server on a machine in your AWS account.

```text
your laptop                                       one arm64 machine in your AWS account
Muse Code (Muse Spark 1.3)                        Caddy: HTTPS, a Let's Encrypt certificate
  + the rhobound plugin  --- MCP over HTTPS --->    rhobound-mcp: checks the bearer token (read-only)
                             Bearer <token>           rhobound: the engine, on production's fit (env prod)
```

How it works:
- **`bed/aws/live_mcp.sh up`** (from AWS CloudShell) makes a security group (ports 80 and 443 only) and one
  `t4g.small` (Ubuntu 24.04, arm64). The machine has no ssh and no AWS role, uses IMDSv2 only, and terminates itself
  after `HOURS` hours: 8 by default, at most 168. It costs about 0.02 USD per hour.
- **The machine boots `bed/aws/live_mcp_boot.sh`** from the same commit:
  - it builds rhobound and rhobound-mcp;
  - it re-times the sample traces so their window ends at boot. Every timestamp moves by one constant, so every
    duration and gap, and every number below, stays the same;
  - it fits them and registers the fit as the environment `prod`'s baseline;
  - it serves MCP on localhost, with Caddy in front on `https://<public IP, dashed>.sslip.io/mcp`.
- **Two read-only tokens** are made in CloudShell: yours and the judges'. The machine keeps only their sha256. Read-only
  means `context`, `budget`, `predict` and `explain` on `prod`; `fit_start` needs a scope a token never has.
- **The plugin's skill** (`rhobound-loop`) tells Muse to read the context and the budget before it codes and to predict
  after. The hosted tools have the same names as the local ones, so the plugin works unchanged.

### Start it (AWS CloudShell)

```bash
curl -fsSLO https://raw.githubusercontent.com/Sharvil2704/rhobound-cli/rhobound-mcp/bed/aws/live_mcp.sh
```

```bash
bash live_mcp.sh up
```

`up` prints the URL, your token and the commands for your laptop. After 3-5 minutes, `status` shows the boot's `READY`
line and `tools HTTP 200: budget context explain fit_start job_status predict`:

```bash
bash live_mcp.sh status
```

### Check it from your laptop

With the token and the host `up` printed:

```bash
export RHOBOUND_TOKEN=<the token> H=<the host, NN-NN-NN-NN.sslip.io>
```

One request straight from the terminal: +4 ms on b, predicted on the hosted production fit. It prints `"block"`:

```bash
curl -s https://$H/mcp -H "Authorization: Bearer $RHOBOUND_TOKEN" -H 'Content-Type: application/json' -H 'Accept: application/json, text/event-stream' -d '{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"predict","arguments":{"env":"prod","changes":[{"op":"own_ms","service":"b","value":4}]}}}' | jq '.result.structuredContent.preview.verdict'
```

### Point Muse Code at it

Run the `f=~/.config/muse/settings.json && jq ...` command that `up` printed. It makes Muse's `rhobound` entry the
hosted endpoint, under the key the settings file already uses: a file with both `mcp_servers` and `mcpServers` turns
MCP off. Muse fills `${RHOBOUND_TOKEN}` from the terminal's environment, so the token is never written to the file.

Store your Meta key in Muse once, off screen (`META_API_KEY`, when set, takes priority over a stored key):

```bash
unset META_API_KEY; muse auth set --api-key-stdin < ~/.meta-key
```

### Ask Muse, interactively

In the terminal where `RHOBOUND_TOKEN` is exported:

```bash
cd ~/rhobound-try/work && muse --model muse-spark-1.3 --reasoning-effort high --trust-workspace
```

Muse asks before each tool call (`--approval-mode never` skips that). Type `/mcp` to see `rhobound` connected, then:

```text
Service b is called by a, our user-facing entry, and calls c. A new feature will add about 4 ms of work to every call of b. Before you write any code, use the rhobound tools on the environment prod: read entry a's context and b's latency budget, then predict the +4 ms change. Is it safe to ship?
```

```text
What if b only adds 1 ms? Predict that on prod.
```

```text
Explain in two sentences why the gate blocked the 4 ms version.
```

```text
So how would you build the feature without breaking that budget?
```

What it answered (2026-11-04: Muse Code 1.4.14 on macOS, `muse-spark-1.3`, rhobound on AWS). The wording is the
model's own; the numbers are rhobound's.

```text
❯ Service b is called by a, our user-facing entry, and calls c. A new feature will add about 4 ms of work to every
  call of b. Before you write any code, use the rhobound tools on the environment prod: read entry a's context and
  b's latency budget, then predict the +4 ms change. Is it safe to ship?

◆ Read skill rhobound-loop · rhobound · 3 KB
◆ 3 MCP calls · rhobound · ✓ ×3 · 0.6s
◆ Not safe to ship. Preview verdict: block for entry a.
  • Entry a mean is ~45.22 ms at ~25.8 rps.
  • Budget for b: safe 1.07 ms, max 1.95 ms per visit. Your +4 ms is over both.
  • Prediction for +4 ms on b: entry a rises ~4.70 ms, over its 2.26 ms threshold.
  This preview is advisory; CI decides. To pass, you need a measured A/B of b where delta + 2 SE is at most
  1.07 ms per visit, or a smaller change.

❯ What if b only adds 1 ms? Predict that on prod.

◆ predict(detail=summary, env=prod) · rhobound · ✓ · 0.3s
◆ Preview verdict: inconclusive for entry a.
  • +1 ms on b puts a at +1.15 ms, under its 2.26 ms threshold. That rule passes.
  • A declared estimate previews as inconclusive at best, so this cannot pass on numbers alone.
  What would decide it: an A/B of b (diff-fit): a measured delta passes if delta + 2 SE is at most 1.07 ms per
  visit. This preview is advisory; CI decides.

❯ Explain in two sentences why the gate blocked the 4 ms version.

◆ The +4 ms on b exceeds its safe budget of 1.07 ms per visit (max 1.95 ms). It predicts entry a rises ~4.70 ms,
  with even the low end at 3.67 ms over its 2.26 ms mean-change limit, so the gate blocks.

❯ So how would you build the feature without breaking that budget?

◆ Keep the mean added work on b at or under 1.07 ms per visit. Ways to do that:
  • Do less per call: cache, sample a fraction of calls, or run only when needed.
  • Move work off the request path: queue it async after responding.
  • Make the work faster: cheaper check or lookup instead of 4 ms inline.
  Then prove it with a measured A/B of b: it passes if delta + 2 SE stays at most 1.07 ms.
```

What the run shows:
- **Muse asked before it coded.** It read the plugin's skill and called `context`, `budget` and `predict` on the
  hosted endpoint first.
- **The gate held its line twice.** +4 ms blocks: entry a would rise 3.67 to 5.73 ms against a 2.26-ms limit. +1 ms
  fits the budget but stays inconclusive, because a declared estimate is not a measurement: only an A/B of the real
  image can pass.
- **The plan came from the numbers.** Muse designed the feature around the 1.07-ms budget and named the measurement
  that would prove it.

### Or headless

The same question in one command, with [muse-prompt-live.md](muse-prompt-live.md):

```bash
cd ~/rhobound-try/work && muse exec --json --api-key-stdin --model muse-spark-1.3 --reasoning-effort high --max-model-steps 30 --disable-approval --disable-request-user-input --trust-workspace --prompt-file ~/rbd-video/demo/muse-prompt-live.md < ~/.meta-key | tee ~/rhobound-try/events-live.jsonl | jq -j 'select(.payload_type == "run.output.delta") | .payload | (.delta // .text // .content // empty) | strings'
```

### For judges

`HOURS=168 bash live_mcp.sh up` keeps the machine up for a week (about 3 USD). `share` prints the block to paste into
the submission: the URL, a separate judges' token, its expiry and how to try it. Never commit a token to the
repository; a judge who wants an endpoint of their own runs `live_mcp.sh up` in their own account.

```bash
bash live_mcp.sh share
```

### Stop it

```bash
bash live_mcp.sh down
```

To point Muse back at the local server, run part 3's `rhobound-mcp init ... --write` again.

## 7. Afterwards

```bash
rm ~/.meta-key
```

The gate live on AWS, with real pull requests, is [JUDGES.md, tier 2](../JUDGES.md#tier-2-the-gate-live-on-aws).
