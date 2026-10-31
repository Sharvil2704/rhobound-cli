#!/usr/bin/env bash
# load.sh show | set (--rps R [--mix M] | --mix M | --rates M) [--no-restart] | reset [--no-restart]   (as rbd on rbd-tools1)
#   The production load setting (SPEC3 F6a), ONE file: $RBD_HOME/load.env (RBD_LOAD_RPS, RBD_LOAD_MIX; rbd's, 0644). capture.sh
#   runs its window at it; bgload.sh runs the background load at it (start, the restart in capture.sh's trap after every
#   window, and the 5-min ensure, which also restarts a Job running at another load). No file = spec.json's load (100 rps
#   Poisson; browse 0.70, card 0.18, wallet 0.12): the Jobs exactly as before the file existed.
#   show     the effective setting, one JSON line (loadmix.py, rbd.load/v1: source default|load.env, rps, mix, shares, rates,
#            entries = per entry service rps, summary)
#   set      --rps R: the total rate, 10..400 rps, at most one decimal (kshop-load logs it with one);
#            --mix browse=W,card=W,wallet=W: every URL of spec.json's mix once, W >= 0 summing > 0, relative (a 0 leaves the
#            URL out of the Job; verify's truth/aa then refuse the window: they want 3 result lines);
#            --rates browse=91,card=18,wallet=12: per-URL rates, R = their sum (browse x1.3 here).
#            A part not given is spec.json's, not the old file's. Validated by loadmix.py (which reads its own output back),
#            written to a temporary file beside load.env and read back there as capture.sh/bgload.sh read it, renamed over
#            load.env only when accepted, then the background load started (again) at it: bgload.sh start, nested; it also
#            starts a stopped one. A refused set changes nothing: the old load.env (or none) and the running Job stay.
#   reset    remove load.env (spec.json's load again), then the background load started (again) at it.
#   --no-restart  the file only: the next capture.sh window, or bgload.sh ensure (every 5 min, lock free), applies it.
# Under the cluster lock (waits RBD_LOCK_WAIT, 3600 s; nested in a step that holds it): never in the middle of a window, an
# A/B or a truth bracket. RBD_LOAD_RPS / RBD_LOAD_MIX in the environment (rbd.env.local) must agree with the new setting,
# else refused (every reader would refuse it). From the orchestrator: bash orch/rbd.sh run /opt/rbd/kshop/load.sh set --rps 130
# set/reset: last line {"step":"load","ok":...,"action","load":{the setting},"restarted"}. Exit 0; 1 refused/failed; 2 usage.
# shellcheck disable=SC2015
set -euo pipefail
RBD_OPT=${RBD_OPT:-/opt/rbd}
# shellcheck source=../lib/rbd-env.sh
. "$RBD_OPT/lib/rbd-env.sh"
# shellcheck source=../lib/lock.sh
. "$RBD_OPT/lib/lock.sh"
export RBD_STEP=load
F=$RBD_HOME/load.env
MIX=$RBD_OPT/kshop/loadmix.py
usage() { echo "usage: load.sh show | set (--rps R [--mix browse=W,card=W,wallet=W] | --mix ... | --rates browse=R,card=R,wallet=R) [--no-restart] | reset [--no-restart]" >&2; exit 2; }
refuse() { log "ERROR: $1"; rbd_result load false "$(jq -cn --arg a "$ACTION" --arg e "$1" '{action: $a, error: $e}')"; exit 1; }

ACTION=${1:-}
[ $# -ge 1 ] || usage
shift
RESTART=1 args=() rates=0 other=0
while [ $# -gt 0 ]; do
  case $1 in
    --rps | --mix | --rates)
      [ "$ACTION" = set ] && [ $# -ge 2 ] && [ -n "$2" ] || usage
      if [ "$1" = --rates ]; then rates=1; else other=1; fi
      args+=("$1" "$2"); shift 2 ;;
    --no-restart) [ "$ACTION" = set ] || [ "$ACTION" = reset ] || usage; RESTART=0; shift ;;
    *) usage ;;
  esac
done
need_cmd python3 jq

restart() {   # restart SETTING_JSON: the background load at the new setting (or not, --no-restart); the last line
  local r=false
  if [ "$RESTART" = 1 ]; then
    log "starting the background load again at it"
    if ! "$RBD_OPT/kshop/bgload.sh" start; then
      log "ERROR: $F is written, but the background load did not start again (bgload.sh ensure retries every 5 min)"
      rbd_result load false "$(jq -cn --arg a "$ACTION" --argjson l "$1" '{action: $a, load: $l, restarted: false, error: "the setting is written; the background load did not start again"}')"
      exit 1
    fi
    r=true
  else
    log "--no-restart: the next capture.sh window, or bgload.sh ensure (lock free), applies it"
  fi
  rbd_result load true "$(jq -cn --arg a "$ACTION" --argjson l "$1" --argjson r "$r" '{action: $a, load: $l, restarted: $r}')"
}

case $ACTION in
  show)
    [ ${#args[@]} = 0 ] && [ "$RESTART" = 1 ] || usage
    exec python3 -I "$MIX" show "$F" ;;
  set)
    [ ${#args[@]} -gt 0 ] && ! { [ "$rates" = 1 ] && [ "$other" = 1 ]; } || usage
    body=$(python3 -I "$MIX" envfile "${args[@]}" --by "$(id -un)" 2>&1) || refuse "${body#loadmix: }"
    rbd_lock "${RBD_LOCK_WAIT:-3600}" || refuse "the cluster lock is busy ($(rbd_lock_holder))"
    # the new file beside load.env, read back there as the readers read it; renamed over load.env only when accepted
    kept="nothing changed: $([ -e "$F" ] || [ -L "$F" ] && echo "$F as it was" || echo "no $F (spec.json's load)"), the background load as it was"
    TMPF=$(mktemp "$RBD_HOME/.load.env.XXXXXX") || refuse "cannot write beside $F; $kept"
    trap '[ -z "${TMPF:-}" ] || rm -f "$TMPF"' EXIT
    { printf '%s\n' "$body" > "$TMPF" && chmod 0644 "$TMPF"; } || refuse "cannot write $TMPF; $kept"
    if ! chk=$(python3 -I "$MIX" show "$TMPF" 2>&1); then
      chk=${chk#loadmix: }
      refuse "the new load.env is refused on reading back (${chk//"$TMPF"/the new load.env}); $kept"
    fi
    mv -f "$TMPF" "$F" || refuse "cannot rename $TMPF to $F; $kept"
    TMPF=""
    now=$(python3 -I "$MIX" show "$F" 2>&1) \
      || refuse "$F, accepted a moment ago, is refused now (changed meanwhile?): ${now#loadmix: }; the background load as it was (load.sh set or reset)"
    log "$F: $(jq -r .summary <<< "$now")"
    restart "$now" ;;
  reset)
    [ ${#args[@]} = 0 ] || usage
    chk=$(python3 -I "$MIX" show --default 2>&1) || refuse "${chk#loadmix: }"
    rbd_lock "${RBD_LOCK_WAIT:-3600}" || refuse "the cluster lock is busy ($(rbd_lock_holder))"
    if [ -e "$F" ] || [ -L "$F" ]; then rm -f "$F" || refuse "cannot remove $F"; log "$F removed"; else log "no $F: already spec.json's load"; fi
    now=$(python3 -I "$MIX" show "$F" 2>&1) || refuse "${now#loadmix: }"
    log "$(jq -r .summary <<< "$now")"
    restart "$now" ;;
  *) usage ;;
esac
