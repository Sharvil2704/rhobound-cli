#!/usr/bin/env bash
# run.sh USER WORKSPACE PROMPT_FILE OUT_DIR [MAX_STEPS] [EXTRA...]   (root, on rbd-tools1)
#   One headless Muse Code session as USER (muser: with rhobound; musec: without) in WORKSPACE, its JSONL events in
#   OUT_DIR/events.jsonl. The Meta key is read by rbd from Secrets Manager into a pipe and straight into muse's
#   --api-key-stdin: never a file, never an argument, never the environment. Muse's own sandbox and approval-free
#   headless mode; the user has no AWS (metadata blocked), no kubeconfig, no docker, no sudo.
set -euo pipefail
[ $# -ge 4 ] || { echo "usage: run.sh USER WORKSPACE PROMPT_FILE OUT_DIR [MAX_STEPS] [EXTRA...]" >&2; exit 2; }
u=$1 ws=$2 pf=$3 out=$4 steps=${5:-80}; shift 4; [ $# -gt 0 ] && shift
case $u in muser|musec) ;; *) echo "run.sh: user $u?" >&2; exit 2 ;; esac
case $ws in /home/"$u"/ws/*) ;; *) echo "run.sh: workspace must be under /home/$u/ws" >&2; exit 2 ;; esac
[ -d "$ws" ] && [ -f "$pf" ] || { echo "run.sh: no workspace or prompt" >&2; exit 2; }
install -d -o "$u" -g "$u" -m 0700 "$out"
install -o "$u" -g "$u" -m 0600 "$pf" "$out/prompt.md"
date -u +%FT%TZ > "$out/started"; chown "$u:$u" "$out/started"
rc=0
sudo -u rbd /usr/local/bin/aws secretsmanager get-secret-value --secret-id rhobound-demo/anthropic-key \
    --query SecretString --output text \
  | /opt/muse/hide.sh "$u" sudo -u "$u" -H env PATH="/opt/muse/bin:/opt/muse/go/bin:/usr/local/bin:/usr/bin:/bin" GOFLAGS=-mod=mod \
      GOPROXY=off GOTOOLCHAIN=local GOCACHE="$ws/.gocache" GOTMPDIR="$ws/.gotmp" bash -c '
      cd "$1" || exit 2
      shift; out=$1; steps=$2; shift 2
      exec timeout 2400 /opt/muse/bin/muse exec --json --api-key-stdin --model muse-spark-1.3 --reasoning-effort high \
        --max-model-steps "$steps" --disable-approval --disable-request-user-input --trust-workspace \
        --prompt-file "$out/prompt.md" "$@" > "$out/events.jsonl" 2> "$out/stderr.txt"' _ "$ws" "$out" "$steps" "$@" || rc=$?
date -u +%FT%TZ > "$out/ended"; echo "$rc" > "$out/rc"; chown "$u:$u" "$out/ended" "$out/rc"
exit "$rc"
