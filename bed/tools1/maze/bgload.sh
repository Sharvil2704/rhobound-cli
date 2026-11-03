#!/usr/bin/env bash
# bgload.sh start|stop|ensure|status   the background production load: Job maze-bgload (render.py load at the load setting,
#   RBD_BGLOAD_SECONDS long, default 12 h) on the load pool. It keeps production warm and is what an A/B's callees see.
#   The load setting (SPEC3 F6a) is $RBD_HOME/load.env, read through loadmix.py (load.sh set|reset|show writes it): no file =
#   spec.json's mix at 100 rps, the Job exactly as before; with one, --rps/--mix-weights. capture.sh runs its window at the
#   same setting and calls start after it (its trap), so the load never falls back to the default after a window.
#   start/stop take the cluster lock (a step that holds it, e.g. capture.sh or load.sh, calls them nested). start reads the
#   setting and renders the Job before it stops the old one: a refused setting leaves the running Job alone (exit 1).
#   ensure (rbd-bgload.timer, every 5 min) starts it again when it is missing or finished, or when it runs at another load
#   than the setting (its LOAD_RPS/LOAD_MIX/LOAD_PATTERN differ from what start would render; an unreadable Job env is left
#   alone), only when the lock is free: never in the middle of a window or an A/B. A refused setting: exit 1, nothing touched.
#   One expected one-off: load.sh set to spec.json's own values renders LOAD_RPS "100.0" where the default Job has "100", so
#   ensure restarts a default-started Job once (load.sh reset is the way back to the default).
#   status: running or not, the setting, and a running Job at another load.
# Exit 0; 1 on failure.
# shellcheck disable=SC2015
set -euo pipefail
RBD_OPT=${RBD_OPT:-/opt/rbd}
# shellcheck source=../lib/rbd-env.sh
. "$RBD_OPT/lib/rbd-env.sh"
# shellcheck source=../lib/lock.sh
. "$RBD_OPT/lib/lock.sh"
export RBD_STEP=bgload
JOB=maze-bgload
SECS=${RBD_BGLOAD_SECONDS:-43200}
SETTING=""
CMP_IMG=compare.invalid/maze-load@sha256:0000000000000000000000000000000000000000000000000000000000000000   # the image does not matter to compare

active() { [ "$(kubectl -n "$RBD_NS" get job "$JOB" -o jsonpath='{.status.active}' 2> /dev/null)" = 1 ]; }

setting() {   # SETTING = the effective load setting (rbd.load/v1 JSON); exit 1 when refused
  SETTING=$(python3 -I "$RBD_OPT/maze/loadmix.py" show "$RBD_HOME/load.env" 2>&1) && jq -e '.schema == "rbd.load/v1"' <<< "$SETTING" > /dev/null 2>&1 \
    || die "the load setting is refused: ${SETTING#loadmix: }"
}

job() {   # job SECONDS SEED IMAGE: the Job's manifest at SETTING (spec.json's flags-free render when it is the default)
  local args=()
  [ "$(jq -r .source <<< "$SETTING")" = default ] || args=(--rps "$(jq -r .rps <<< "$SETTING")" --mix-weights "$(jq -r .mix <<< "$SETTING")")
  python3 -I "$RBD_OPT/maze/render.py" load --load-image "$3" --name "$JOB" --seconds "$1" --seed "$2" "${args[@]}"
}

load_env() { jq -c '[.spec.template.spec.containers[0].env[]? | select(.name | test("^LOAD_(RPS|MIX|PATTERN)$")) | {name, value}] | sort_by(.name)'; }

compare() {   # SAME, UNKNOWN or "DIFF <the running Job's LOAD_* env>": the running Job against what start would render now
  local want have
  want=$(job 1 1 "$CMP_IMG" | load_env) || { echo UNKNOWN; return 0; }
  have=$(kubectl -n "$RBD_NS" get job "$JOB" -o json 2> /dev/null | load_env 2> /dev/null) || have=""
  if [ -z "$have" ] || [ "$have" = "[]" ]; then echo UNKNOWN; elif [ "$have" = "$want" ]; then echo SAME; else echo "DIFF $have"; fi
}

stop() {
  kubectl -n "$RBD_NS" delete job "$JOB" --ignore-not-found --wait=true --timeout=120s > /dev/null
  kubectl -n "$RBD_NS" wait --for=delete pod -l "job-name=$JOB" --timeout=120s > /dev/null 2>&1 || true
  log "stopped"
}

start() {
  local img seed man
  setting
  img=$(images_get load) || exit 1
  seed=$(( $(date +%s) / 3600 % 100000 + 1000 ))
  man=$(job "$SECS" "$seed" "$img") || die "render.py load failed for Job $JOB"
  stop
  kubectl apply -f - <<< "$man" > /dev/null || die "could not create Job $JOB"
  for _ in $(seq 1 30); do [ -n "$(kubectl -n "$RBD_NS" get pods -l "job-name=$JOB" -o name 2> /dev/null)" ] && break; sleep 1; done   # the Job makes its pod
  kubectl -n "$RBD_NS" wait --for=condition=Ready pod -l "job-name=$JOB" --timeout=180s > /dev/null || die "Job $JOB did not start in 180 s"
  log "started ($SECS s, seed $seed; $(jq -r .summary <<< "$SETTING"))"
}

case ${1:-} in
  start) rbd_lock "${RBD_LOCK_WAIT:-3600}" || exit 1; start ;;
  stop) rbd_lock "${RBD_LOCK_WAIT:-3600}" || exit 1; stop ;;
  ensure)
    rbd_lock_try ensure || { log "lock held ($(rbd_lock_holder)): not touching the background load"; exit 0; }
    if active; then
      setting
      c=$(compare)
      case $c in
        SAME) exit 0 ;;
        UNKNOWN) log "WARNING: cannot read the running Job's load env: leaving it"; exit 0 ;;
      esac
      log "running at another load (${c#DIFF }) than the setting ($(jq -r .summary <<< "$SETTING")): starting it again"
      start; exit 0
    fi
    log "not running: starting it"; start ;;
  status)
    if active; then run=1; echo "maze-bgload: running"; else run=0; echo "maze-bgload: NOT running"; fi
    if SETTING=$(python3 -I "$RBD_OPT/maze/loadmix.py" show "$RBD_HOME/load.env" 2>&1); then
      echo "  load setting: $(jq -r .summary <<< "$SETTING")"
      if [ "$run" = 1 ]; then
        c=$(compare)
        [[ $c != DIFF* ]] || echo "  the running Job is at another load: ${c#DIFF } (bgload.sh ensure starts it again at the setting)"
      fi
    else
      echo "  load setting REFUSED: ${SETTING#loadmix: }"
    fi ;;
  *) echo "usage: bgload.sh start|stop|ensure|status" >&2; exit 2 ;;
esac
