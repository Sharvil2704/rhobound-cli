#!/usr/bin/env bash
# task.sh ARM TICKET ITER RUN [FEEDBACK_FILE]   (root, on rbd-tools1; installed as /opt/muse/task.sh)
#   One iteration of one arm of the Muse experiment: a headless Muse Code session on a ticket, then the agent's work as
#   the OUT folder of tools1/agent/agent.py at /var/lib/rbd/agent/RUN-iITER (owned by rbd), which orch/agent_take.sh takes.
#   ARM R: user muser (the rhobound plugin and MCP server), its workspace made with mkws.sh --opt-in (the Stop reminder's
#   opt-in file); ARM C: user musec (no plugin, no MCP), no opt-in. Same ticket text, model, effort and step cap for both.
#   ITER 1 makes the workspace /home/USER/ws/<run, lower-cased> from the bed's main (and keeps a snapshot of that main in
#   /var/lib/rbd/muse/runs/RUN/base: the export's baseline, never the workspace's own .git, which the agent can rewrite);
#   ITER 2..3 reuse it and need FEEDBACK_FILE (a regular file, at most 32000 bytes are used).
#   The prompt: /opt/muse/tickets/TICKET/task.md, and for ITER > 1 a fixed lead line and the feedback (export.py prompt).
#   Steps: the user's stray processes killed -> /opt/muse/run.sh USER WS PROMPT /home/USER/runs/RUN-iITER STEPS -> the
#   user's processes killed -> the work committed in the workspace as the user (the agent's .git/config replaced, no hook,
#   no filter, no global or system config) so the next iteration continues from it -> export.py export (as root, reading
#   the workspace and Muse's logs as untrusted data: no link followed) into a staging folder, chowned to rbd and moved to
#   OUT in one rename -> /var/lib/rbd/muse/runs/RUN/iITER/done. The raw events and session log stay in
#   /var/lib/rbd/muse/runs/RUN/iITER (never in OUT: agent_take's 5 MB cap).
#   Last stdout line: {"step": "muse-task", "ok", "out", "session_rc", "wall_s", "files", "service", "model_steps",
#   "mcp_calls", "stop_blocked", "error"?}. Exit 0 the change is in OUT (result.json ok), 1 OUT holds result.json ok:false
#   (its error says why: feed it back), 2 usage or state error (nothing ran), 3 the session ran but export.py failed (no OUT;
#   the raw logs are in /var/lib/rbd/muse/runs/RUN/iITER), 4 another session or hidden run of this user holds its lock.
# Env: MUSE_STEPS [150] (the step cap, the same for both arms; fixed at iteration 1 in run.json, recorded in usage.json;
#   a later iteration refuses a different one), MUSE_MAX_ITER [3],
#   MUSE_TEST_ROOT (tests only: every path under it, no sudo, chown, pkill; sudo's env_reset keeps it out of real runs).
# shellcheck disable=SC2015  # A && B || die is meant
set -euo pipefail
umask 027
die() { echo "task.sh: error: $*" >&2; exit "${2:-2}"; }
say() { echo "[task.sh $(date -u +%H:%M:%S)] $*" >&2; }
[ $# -ge 4 ] && [ $# -le 5 ] || die "usage: task.sh ARM TICKET ITER RUN [FEEDBACK_FILE]"
ARM=$1 TICKET=$2 ITER=$3 RUN=$4 FB=${5:-}
case $ARM in R) U=muser OPTIN=--opt-in ;; C) U=musec OPTIN= ;; *) die "ARM must be R or C, not $ARM" ;; esac
[[ $TICKET =~ ^[A-Za-z0-9][A-Za-z0-9_-]{0,31}$ ]] || die "TICKET: letters, digits, - _ (at most 32)"
MAXIT=${MUSE_MAX_ITER:-3}
[[ $MAXIT =~ ^[1-9]$ && $ITER =~ ^[1-9]$ ]] && (( ITER <= MAXIT )) || die "ITER must be 1..$MAXIT, not $ITER"
[[ $RUN =~ ^[A-Za-z0-9][A-Za-z0-9_-]{0,27}$ ]] || die "RUN: letters, digits, - _ (at most 28: RUN-iITER is agent_take's run name)"
STEPS=${MUSE_STEPS:-150}   # experiment 2: harder tickets and a working shell (experiment 1: 80)
[[ $STEPS =~ ^[1-9][0-9]{0,3}$ ]] || die "MUSE_STEPS must be 1..9999"
WSN=${RUN,,}   # mkws.sh takes lower-case names

if [ -n "${MUSE_TEST_ROOT:-}" ]; then
  TR=$MUSE_TEST_ROOT OPT=$MUSE_TEST_ROOT/opt-muse HOMES=$MUSE_TEST_ROOT/home RBD=$MUSE_TEST_ROOT/rbd HTMP=$MUSE_TEST_ROOT/vartmp
else
  [ "$(id -u)" = 0 ] || die "run as root (sudo /opt/muse/task.sh ...)"
  TR="" OPT=/opt/muse HOMES=/home RBD=/var/lib/rbd HTMP=/var/tmp
fi
EXPORT=$OPT/export.py TD=$OPT/tickets/$TICKET
WS=$HOMES/$U/ws/$WSN S=$HOMES/$U/runs/$RUN-i$ITER
RD=$RBD/muse/runs/$RUN ID=$RBD/muse/runs/$RUN/i$ITER OUT=$RBD/agent/$RUN-i$ITER

as_user() {   # as_user CMD...: as the arm's user, a clean environment
  if [ -n "$TR" ]; then env -i HOME="$HOMES/$U" PATH="$PATH" LANG=C.UTF-8 "$@"
  else sudo -u "$U" -H env -i HOME="/home/$U" PATH=/usr/local/bin:/usr/bin:/bin LANG=C.UTF-8 "$@"; fi
}
to_rbd() { [ -n "$TR" ] || chown -R rbd:rbd "$@"; }
to_rbd1() { [ -n "$TR" ] || chown rbd:rbd "$@"; }
kill_user() {   # the user's every process (the session's leftovers: sandbox children, the stdio MCP server), its crontab,
  # and its files in the shared scratch folders (the other arm runs there next)
  [ -n "$TR" ] && return 0
  crontab -r -u "$U" 2> /dev/null || true
  for _ in $(seq 1 40); do
    pkill -KILL -u "$U" 2> /dev/null || true
    pgrep -u "$U" > /dev/null || break
    sleep 0.25
  done
  pgrep -u "$U" > /dev/null && die "processes of $U still alive after SIGKILL" 3
  find /tmp /var/tmp /dev/shm -xdev -user "$U" -delete 2> /dev/null || true
}
# Preconditions that keep the session contained, checked before every session (statically: the rules themselves).
contained() {
  [ -n "$TR" ] && return 0
  local uid; uid=$(id -u "$U")
  iptables -C OUTPUT -m owner --uid-owner "$uid" -d 169.254.169.254 -j REJECT 2> /dev/null \
    || die "the instance-metadata block for $U is missing (iptables): refusing to run a session" 2
  if command -v ip6tables > /dev/null; then
    ip6tables -C OUTPUT -m owner --uid-owner "$uid" -d fd00:ec2::254 -j REJECT 2> /dev/null \
      || die "the instance-metadata block for $U is missing (ip6tables): refusing to run a session" 2
  fi
  [ "$(stat -c '%u %a' /opt/muse/tickets 2> /dev/null)" = "0 700" ] || die "/opt/muse/tickets must be root 0700" 2
  [ ! -e "$TD/refs" ] || die "the ticket's refs/ must not be installed on tools1" 2
  # as the session sees them: inside hide.sh's namespace
  local h=/opt/muse/hide.sh
  ! "$h" "$U" sudo -u "$U" test -r "$TD/task.md" || die "$U can read the ticket folder" 2
  ! "$h" "$U" sudo -u "$U" test -r /opt/actions-runner/.runner || die "$U can read the runner's checkout" 2
  ! "$h" "$U" sudo -u "$U" test -r /opt/rbd/etc/rbd.env || die "$U can read the bed's environment" 2
  if [ "$U" = musec ]; then
    ! "$h" musec sudo -u musec test -r /opt/muse/plugin/muse-code/.muse-plugin/plugin.json || die "musec can read the rhobound plugin" 2
    ! "$h" musec sudo -u musec test -s /opt/muse/bin/rhobound-mcp || die "musec can run rhobound-mcp" 2
    ! "$h" musec sudo -u musec test -r /opt/muse/rb/policy.json || die "musec can read rhobound's capture and policy" 2
    ! "$h" musec sudo -u musec test -x /opt/rbd/bin/rhobound || die "musec can run the bed's engine" 2
  fi
}

[ -f "$TD/task.md" ] && [ ! -L "$TD/task.md" ] || die "no ticket $TICKET ($TD/task.md)"
[ -f "$EXPORT" ] || die "no $EXPORT"
[ -d "$RBD" ] || die "no $RBD"
# root's own scratch, never $RBD/tmp (rbd's: CI's pr-check makes its folders there, and a root-made one locks it out)
mkdir -p "$RBD/muse/runs" "$RBD/muse/locks" "$RBD/agent" "$RBD/muse/tmp"
to_rbd1 "$RBD/muse/runs" "$RBD/agent"
chmod 0750 "$RBD/agent"
exec 9> "$RBD/muse/locks/$U.lock"
flock -n 9 || die "another session or hidden-test run of $U holds $RBD/muse/locks/$U.lock" 4

[ ! -e "$OUT" ] || die "$OUT exists: iteration $ITER of $RUN was exported already"
[ ! -e "$ID" ] || die "$ID exists: iteration $ITER of $RUN ran already (remove it to redo a crashed iteration)"
[ ! -e "$S" ] || die "$S exists: a session for $RUN-i$ITER ran already"
if [ "$ITER" = 1 ]; then
  [ -z "$FB" ] || die "iteration 1 takes no feedback (both arms start from the same text)"
  [ ! -e "$RD" ] || die "$RD exists: RUN $RUN was started already (a new RUN name for a new run)"
  [ ! -e "$WS" ] || die "$WS exists"
else
  [ -n "$FB" ] || die "iteration $ITER needs FEEDBACK_FILE"
  [ -f "$FB" ] && [ ! -L "$FB" ] || die "the feedback $FB is not a regular file"
  [ -f "$RD/run.json" ] || die "no $RD/run.json: iteration 1 of $RUN never ran"
  python3 -I -c 'import json,sys; r=json.load(open(sys.argv[1])); sys.exit(0 if (r["arm"], r["ticket"], r["user"], r["ws"]) == tuple(sys.argv[2:6]) else 1)' \
    "$RD/run.json" "$ARM" "$TICKET" "$U" "$WS" || die "$RUN was started as another arm, ticket or workspace ($RD/run.json)"
  [ -e "$RD/i$((ITER - 1))/done" ] || die "iteration $((ITER - 1)) of $RUN has not finished"
  [ -d "$WS" ] && [ ! -L "$WS" ] || die "the workspace $WS is gone"
fi

trap '[ -z "${rpid:-}" ] || kill "$rpid" 2> /dev/null || true; kill_user; rm -rf "${STAGE:-}"' EXIT
trap 'exit 130' INT TERM HUP
if [ "$ITER" = 1 ]; then
  say "iteration 1: main snapshot and workspace $WS ($ARM, $U)"
  mkdir -p "$RD"
  m1=$(head -c 64 "$RBD/src/main.sha" | tr -d '\n')
  [[ $m1 =~ ^[0-9a-f]{40}$ ]] || die "$RBD/src/main.sha is not a commit"
  cp -a "$RBD/src/main" "$RD/base"
  "$OPT/mkws.sh" "$U" "$WSN" ${OPTIN:+"$OPTIN"} > /dev/null
  m2=$(head -c 64 "$RBD/src/main.sha" | tr -d '\n')
  [ "$m1" = "$m2" ] || die "the bed's main moved from $m1 to $m2 while the workspace was made: start a new RUN"
  bc=$(as_user git -C "$WS" rev-parse HEAD)   # before any agent ran: the workspace's own baseline commit
  [[ $bc =~ ^[0-9a-f]{40}$ ]] || die "no baseline commit in $WS"
  printf '{"schema": "rbd.muse-run/v1", "run": "%s", "arm": "%s", "ticket": "%s", "user": "%s", "ws": "%s", "main_sha": "%s", "base_commit": "%s", "steps": %s, "created": "%s"}\n' \
    "$RUN" "$ARM" "$TICKET" "$U" "$WS" "$m1" "$bc" "$STEPS" "$(date -u +%FT%TZ)" > "$RD/run.json"
fi
read -r MAIN BC RSTEPS < <(python3 -I -c 'import json,sys; r=json.load(open(sys.argv[1])); print(r["main_sha"], r["base_commit"], r["steps"])' "$RD/run.json")
if [ "$ITER" != 1 ]; then   # every iteration of a run has iteration 1's step cap
  [ -z "${MUSE_STEPS:-}" ] || [ "$MUSE_STEPS" = "$RSTEPS" ] || die "MUSE_STEPS $MUSE_STEPS differs from the run's step cap $RSTEPS"
  STEPS=$RSTEPS
fi
mkdir -p "$ID"
python3 -I "$EXPORT" prompt --task "$TD/task.md" --iter "$ITER" ${FB:+--feedback "$FB"} > "$ID/prompt.md" ||
  die "cannot build the prompt"
python3 -I "$EXPORT" previews --home "$HOMES/$U" > "$ID/previews-before.json"
to_rbd "$RD"
contained
kill_user
rm -rf "$HTMP/muse-hidden-$U".* 2> /dev/null || true   # a hidden run's copy never outlives it (hidden.sh holds this lock)

say "session: $U in $WS, step cap $STEPS ($ARM, $TICKET, iteration $ITER)"
t0=$(date +%s.%N)
rc=0
"$OPT/run.sh" "$U" "$WS" "$ID/prompt.md" "$S" "$STEPS" >&2 &   # in the background: a signal to task.sh ends it at once
rpid=$!
wait "$rpid" || rc=$?
rpid=
t1=$(date +%s.%N)
kill_user
say "session ended: exit $rc after $(python3 -I -c 'import sys; print(round(float(sys.argv[2]) - float(sys.argv[1])))' "$t0" "$t1") s"

# the agent's work, committed as the user. Its .git is untrusted: refused unless a plain folder with no commondir; its
# config is replaced (no filter, fsmonitor, include, worktree), hooks off, no system or global config
commit="" note=""
if [ -L "$WS/.git" ] || [ ! -d "$WS/.git" ] || [ -e "$WS/.git/commondir" ] || [ -L "$WS/.git/commondir" ]; then
  note="not committed: the workspace's .git is not a plain repository folder"
else
  # shellcheck disable=SC2016
  if out=$(as_user bash -c '
      set -e; cd "$1"
      rm -rf .git/config
      printf "[core]\n\trepositoryformatversion = 0\n\tfilemode = true\n\tbare = false\n" > .git/config
      export GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null GIT_TERMINAL_PROMPT=0
      g() { timeout 300 git --git-dir="$PWD/.git" --work-tree="$PWD" -c core.hooksPath=/dev/null -c core.fsmonitor=false \
              -c core.untrackedCache=false -c commit.gpgSign=false -c user.name=muse-task \
              -c user.email=muse-task@example.invalid "$@"; }
      g add -A > /dev/null
      g commit -q --no-verify --allow-empty -m "$2" > /dev/null
      g rev-parse HEAD' _ "$WS" "iteration $ITER (task.sh)" 2>&1); then
    commit=$(printf '%s\n' "$out" | tail -n 1)
    [[ $commit =~ ^[0-9a-f]{40}$ ]] || { note="commit gave no sha"; commit=; }
  else
    note="not committed: $(printf '%s' "$out" | tail -c 300 | tr -cd '[:print:]')"
  fi
fi
kill_user
[ -z "$note" ] || say "$note"

STAGE=$(mktemp -d "$RBD/muse/tmp/muse-out.XXXXXX")
rmdir "$STAGE"
line=$(python3 -I "$EXPORT" export --ws "$WS" --base "$RD/base" --main-sha "$MAIN" --session "$S" --home "$HOMES/$U" \
  --ticket-dir "$TD" --arm "$ARM" --ticket "$TICKET" --iter "$ITER" --run "$RUN" --user "$U" --stage "$STAGE" \
  --out "$OUT" --raw "$ID" --rc "$rc" --t0 "$t0" --t1 "$t1" --steps "$STEPS" ${commit:+--commit "$commit"} \
  ${note:+--commit-note "$note"} --base-commit "$BC" --previews-before "$ID/previews-before.json") ||
  die "export.py failed after the session (its raw logs are in $ID)" 3
to_rbd "$STAGE" "$ID"
mv -T "$STAGE" "$OUT"
STAGE=
date -u +%FT%TZ > "$ID/done"
to_rbd "$ID/done"
say "OUT $OUT"
echo "$line"
python3 -I -c 'import json,sys; sys.exit(0 if json.loads(sys.argv[1])["ok"] else 1)' "$line"
