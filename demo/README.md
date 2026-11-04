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

## 6. Live on AWS: the same agent against a hosted rhobound

[bed/aws/live_mcp.sh](../bed/aws/live_mcp.sh) puts rhobound's MCP server on one small arm64 machine in your AWS
account, behind HTTPS with a Let's Encrypt certificate and read-only bearer tokens. The machine builds rhobound from this
repository at the branch's current commit, fits the sample traces (re-timed so their window ends at boot), and serves
them as the environment `prod`. It has no ssh and no AWS role, and it terminates itself after 8 hours by default
(about 0.02 USD per hour).

In AWS CloudShell:

```bash
curl -fsSLO https://raw.githubusercontent.com/Sharvil2704/rhobound-cli/rhobound-mcp/bed/aws/live_mcp.sh
```

```bash
bash live_mcp.sh up
```

`up` prints the URL, the token and one command for your laptop. After 3-5 minutes, `status` shows the boot's `READY`
line and the six tools:

```bash
bash live_mcp.sh status
```

On your laptop, with the token and the endpoint's host from `up`:

```bash
export RHOBOUND_TOKEN=<the token> H=<the host, NN-NN-NN-NN.sslip.io>
```

One request straight from the terminal: +4 ms on b, predicted on the hosted production fit. It prints `"block"`:

```bash
curl -s https://$H/mcp -H "Authorization: Bearer $RHOBOUND_TOKEN" -H 'Content-Type: application/json' -H 'Accept: application/json, text/event-stream' -d '{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"predict","arguments":{"env":"prod","changes":[{"op":"own_ms","service":"b","value":4}]}}}' | jq '.result.structuredContent.preview.verdict'
```

Then point Muse Code's `rhobound` entry at the endpoint with the command `up` printed (it starts `f=~/.config/muse/...`),
and run the same session with the hosted prompt, [muse-prompt-live.md](muse-prompt-live.md):

```bash
cd ~/rhobound-try/work && muse exec --json --api-key-stdin --model muse-spark-1.3 --reasoning-effort high --max-model-steps 30 --disable-approval --disable-request-user-input --trust-workspace --prompt-file ~/rbd-video/demo/muse-prompt-live.md < ~/.meta-key | tee ~/rhobound-try/events-live.jsonl | jq -j 'select(.payload_type == "run.output.delta") | .payload | (.delta // .text // .content // empty) | strings'
```

For judges: `HOURS=168 bash live_mcp.sh up` keeps the machine up for a week (about 3 USD). `share` prints the block to
paste into the submission: the URL, a separate judges' token, its expiry and how to try it. Never commit a token to
the repository; a judge who wants an endpoint of their own runs `live_mcp.sh up` in their own account.

```bash
bash live_mcp.sh share
```

When you are done, in CloudShell:

```bash
bash live_mcp.sh down
```

To point Muse back at the local server, run part 3's `rhobound-mcp init ... --write` again.

## 7. Afterwards

```bash
rm ~/.meta-key
```

The gate live on AWS, with real pull requests, is [JUDGES.md, tier 2](../JUDGES.md#tier-2-the-gate-live-on-aws).
