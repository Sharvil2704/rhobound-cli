# shellcheck shell=bash disable=SC2034  # (ROLLOUT_TIMEOUT, ERR: read by the scripts that source this)
# verify/vlib.sh: helpers of truth.sh, aa.sh, collect.sh (sourced; bash). The verifier never calls rhobound: files and kubectl only.
# Paths (test hooks): RBD_LIB [/opt/rbd/lib] (rbd-env.sh, lock.sh), RBD_CI [/opt/rbd/ci] (capture.sh), RBD_WINDOW_S [600],
#   RBD_CAPTURE_SLACK_S [1200: a capture.sh that runs longer than window + slack is killed], RBD_LOCK_WAIT [60 s],
#   RBD_ROLLOUT_TIMEOUT [300s], RBD_NS [maze]
# Lock (SPEC 3: flock on $RBD_HOME/lock, one job on the cluster at a time). The verifier holds it for its whole run and EXPORTS
#   RBD_LOCK_HELD; capture.sh, run under it, must not lock again when RBD_LOCK_HELD is set (or must flock the inherited fd 9
#   without reopening it). part B's lock.sh (tools1/lib/lock.sh) does exactly that: rbd_lock [WAIT_S] [WHAT] flocks fd 9 and exports
#   RBD_LOCK_HELD; a child that sees RBD_LOCK_HELD and fd 9 open on the lock file is nested and does not lock. Without rbd_lock the
#   same flock is taken here on fd 9. Either way a second open of the file is then probed: it must be refused. A capture.sh that
#   still waits on the lock is detected through /proc/locks and stopped (no 30-min deadlock).
# capture.sh keeps a failed capture as captures/NAME.failed-<epoch>: its load.json is used when the window itself finished.

RBD_LIB=${RBD_LIB:-/opt/rbd/lib}
RBD_CI=${RBD_CI:-/opt/rbd/ci}
WINDOW_S=${RBD_WINDOW_S:-600}
CAPTURE_SLACK_S=${RBD_CAPTURE_SLACK_S:-1200}
LOCK_WAIT=${RBD_LOCK_WAIT:-60}
ROLLOUT_TIMEOUT=${RBD_ROLLOUT_TIMEOUT:-300s}
NS=${RBD_NS:-maze}
VLOG=${VLOG:-/dev/null}
WHO=${WHO:-verify}

now() { date -u +%Y-%m-%dT%H:%M:%SZ; }
vlog() { printf '[%s] %s: %s\n' "$(now)" "$WHO" "$*" | tee -a "$VLOG" >&2; }
vdie() { ERR="$*"; vlog "FAIL: $*"; exit 1; }
put() {   # put FILE: stdin into FILE by temp + rename
  local f=$1 t
  t="$(dirname "$f")/.$(basename "$f").tmp.$$"
  cat > "$t" && mv -f "$t" "$f"
}
seed_of() {   # seed_of NAME: a positive int from sha256(NAME), stable across runs
  local h
  h=$(printf '%s' "$1" | sha256sum | cut -c1-7)
  echo $((16#$h + 1))
}
valid_name() { [[ $1 =~ ^[a-z0-9][a-z0-9-]{0,40}$ ]]; }
valid_capture() { [[ $1 =~ ^[a-z0-9][a-z0-9._-]{0,62}$ ]]; }   # capture.sh's NAME rule (truth-<CHANGE>-b0 is up to 50 chars)
valid_digest() { [[ $1 =~ ^sha256:[0-9a-f]{64}$ ]]; }
load_ok() {   # load_ok FILE: maze-load's log of a finished window (the done line, 3 URL result lines)
  [[ -s $1 ]] && grep -q 'maze-load: done in' "$1" && (($(grep -c '"url"' "$1") >= 3))
}

env_load() {   # rbd.env through part B's rbd-env.sh; RBD_HOME and RBD_ECR are required
  [[ -r $RBD_LIB/rbd-env.sh ]] || vdie "no $RBD_LIB/rbd-env.sh (part B's install)"
  # shellcheck source=/dev/null
  . "$RBD_LIB/rbd-env.sh" || vdie "$RBD_LIB/rbd-env.sh failed"
  [[ -n ${RBD_HOME:-} && -n ${RBD_ECR:-} ]] || vdie "RBD_HOME or RBD_ECR not set by rbd-env.sh"
  BASELINE=$RBD_HOME/baseline.json
  KG=(kubectl --request-timeout=60s -n "$NS")
}

base_digest() {   # base_digest SERVICE: baseline.json's digest of SERVICE
  local d ref
  [[ -r $BASELINE ]] || vdie "no $BASELINE"
  d=$(jq -r --arg s "$1" '.services[$s] // empty' "$BASELINE") || vdie "$BASELINE: not JSON"
  valid_digest "$d" || vdie "$BASELINE: no digest for $1 (got '$d')"
  ref=$(jq -r '.image_ref // empty' "$BASELINE")
  [[ -z $ref || $ref == "$RBD_ECR" ]] || vdie "$BASELINE image_ref $ref is not RBD_ECR $RBD_ECR"
  echo "$d"
}

live_image() {   # live_image SERVICE: the image of container SERVICE in deployment SERVICE
  local img
  img=$("${KG[@]}" get deployment "$1" -o "jsonpath={.spec.template.spec.containers[?(@.name==\"$1\")].image}") ||
    vdie "kubectl get deployment $1 failed"
  [[ -n $img ]] || vdie "deployment $1 has no container named $1"
  echo "$img"
}

all_at_baseline() {   # every service of baseline.json runs its baseline digest (A/A needs production unchanged)
  local s d img bad=()
  [[ -r $BASELINE ]] || vdie "no $BASELINE"
  while read -r s d; do
    img=$(live_image "$s")
    [[ ${img##*@} == "$d" ]] || bad+=("$s runs ${img##*@} (baseline $d)")
  done < <(jq -r '.services | to_entries[] | "\(.key) \(.value)"' "$BASELINE")
  ((${#bad[@]} == 0)) || vdie "production is not at baseline.json: ${bad[*]}"
}

lock_take() {   # lock_take LABEL: hold $RBD_HOME/lock for this process's life (see the header)
  local f=$RBD_HOME/lock
  [[ -z ${RBD_LOCK_HELD:-} ]] || vdie "RBD_LOCK_HELD=$RBD_LOCK_HELD is set: run the verifier on its own, not under another step"
  [[ -r $RBD_LIB/lock.sh ]] || vdie "no $RBD_LIB/lock.sh (part B's install)"
  # shellcheck source=/dev/null
  . "$RBD_LIB/lock.sh" || vdie "$RBD_LIB/lock.sh failed"
  if declare -F rbd_lock > /dev/null; then
    rbd_lock "$LOCK_WAIT" "$1" || vdie "lock busy ($f): another step holds the cluster"
  else
    exec 9>> "$f" || vdie "cannot open $f"
    flock -w "$LOCK_WAIT" 9 || vdie "lock busy for ${LOCK_WAIT}s ($f): another step holds the cluster"
  fi
  if flock -n "$f" true 2> /dev/null; then vdie "the lock is not held after taking it ($f): lock.sh's contract differs"; fi
  export RBD_LOCK_HELD="${RBD_LOCK_HELD:-$1:$$}"   # rbd_lock may have set its own value
  vlog "lock held ($f, RBD_LOCK_HELD=$RBD_LOCK_HELD)"
}

lock_free() {   # lock_free: 0 if no one holds $RBD_HOME/lock now (a probe; takes nothing)
  flock -n "$RBD_HOME/lock" true 2> /dev/null
}

lock_waiter_under() {   # lock_waiter_under PID: 0 if PID or a descendant waits in flock on $RBD_HOME/lock (/proc/locks "->" rows)
  local ino w p
  ino=$(stat -c %i "$RBD_HOME/lock" 2> /dev/null) || return 1
  while read -r w; do
    p=$w
    while [[ -n $p && $p != 0 && $p != 1 ]]; do
      [[ $p == "$1" ]] && return 0
      p=$(awk '/^PPid:/ {print $2}' "/proc/$p/status" 2> /dev/null)
    done
  done < <(awk -v i=":$ino" '$2 == "->" && $3 == "FLOCK" && substr($7, length($7) - length(i) + 1) == i {print $6}' /proc/locks 2> /dev/null)
  return 1
}

CHILD=
capture() {   # capture NAME SEED OUTFILE LOGFILE: capture.sh NAME WINDOW_S SEED; its meta/load.json to OUTFILE. Sets CAP_RC.
  local name=$1 seed=$2 out=$3 clog=$4 lj
  lj=$RBD_HOME/captures/$name/meta/load.json
  vlog "capture.sh $name $WINDOW_S $seed"
  CAP_RC=0; CAP_LOAD=
  : > "$clog.start"
  timeout --kill-after=30 "$((WINDOW_S + CAPTURE_SLACK_S))" "$RBD_CI/capture.sh" "$name" "$WINDOW_S" "$seed" >> "$clog" 2>&1 &
  CHILD=$!
  while kill -0 "$CHILD" 2> /dev/null; do   # a capture.sh that waits for the lock we hold would wait for ever: stop it now
    if lock_waiter_under "$CHILD"; then
      kill "$CHILD" 2> /dev/null; wait "$CHILD" 2> /dev/null || true; CHILD=
      vdie "capture.sh $name waits for the cluster lock the verifier holds (deadlock): capture.sh/lock.sh must not lock again when RBD_LOCK_HELD is set"
    fi
    sleep 1
  done
  wait "$CHILD" || CAP_RC=$?
  CHILD=
  if ((CAP_RC != 0)) && [[ ! -e $lj ]]; then   # part B moves a failed capture to NAME.failed-<epoch>: the newest one
    local d
    d=$(find "$RBD_HOME/captures" -maxdepth 1 -name "$name.failed-*" -newer "$clog.start" -printf '%T@ %p\n' 2> /dev/null | sort -n | tail -n 1 | cut -d' ' -f2-)
    [[ -z $d ]] || lj=$d/meta/load.json
  fi
  if ! load_ok "$lj"; then
    tail -n 5 "$clog" >&2 || true
    vdie "capture.sh $name exited $CAP_RC and left no finished load.json (log $clog)"
  fi
  CAP_LOAD=$lj
  ((CAP_RC == 0)) || vlog "WARN: capture.sh $name exited $CAP_RC; the window finished and its load.json is used: $lj (log $clog)"
  put "$out" < "$lj" || vdie "cannot write $out"
}

snooze() {   # snooze S: sleep that a trapped signal interrupts
  sleep "$1" &
  CHILD=$!
  wait "$CHILD" || true
  CHILD=
}
