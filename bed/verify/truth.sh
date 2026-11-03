#!/usr/bin/env bash
# verify/truth.sh: the truth bracket of one change, OUTSIDE the product. On rbd-tools1 as user rbd.
#   truth.sh CHANGE SERVICE CAND_DIGEST [--keep]   the bracket (about 30 min: run it under setsid nohup, poll truth.json)
#   truth.sh CHANGE SERVICE CAND_DIGEST --check    preflight only (env, baseline, live image, names free, lock free); changes nothing
# Under the cluster lock, for the whole run:
#   0. B0 waits until the background load has run RBD_WARM_B0 (120) s at the current setting (load.sh set/reset restarts it)
#   1. B0 = capture.sh truth-CHANGE-b0 600 SEED (production at baseline.json)
#   2. kubectl -n maze set image deployment/SERVICE SERVICE=RBD_ECR@CAND_DIGEST; rollout status (OUT OF BAND: no gate)
#   3. warm-up 180 s (the background load runs: capture.sh restarts it after its window)
#   4. C = capture.sh truth-CHANGE-c 600 SEED2
#   5. unless --keep: set image back to baseline.json's digest; rollout status; warm-up 120 s
# Any failure or signal after step 2 started: rollback to the baseline digest (not with --keep), exit 1.
# Preflight refuses (exit 1, nothing changed) when production's SERVICE is not at baseline.json, the candidate equals it, or
# the output folder or a capture name already exists (re-run under a new CHANGE name; the old files stay for the record).
# Writes $RBD_HOME/verify/truth/CHANGE/: truth.json (rbd.truth/v1, rewritten at every phase), b0.load.json, c.load.json,
#   truth.log, b0.capture.log, c.capture.log. Seeds: sha256 of the capture names. Last stdout line: {"step":"truth","ok",...}.
# Exit: 0 ok; 1 failed (production restored unless --keep); 2 usage; 4 failed AND the rollback failed (production runs the candidate).
# Env: RBD_WARM_C [180] RBD_WARM_BACK [120], and vlib.sh's (RBD_LIB, RBD_CI, RBD_WINDOW_S, RBD_LOCK_WAIT, RBD_ROLLOUT_TIMEOUT).
# --keep leaves the candidate in production, for inspection only: baseline.json is not changed (only deploy.sh/refit.sh write
#   it), so deploy.sh ("fix the drift first") and later truth/aa runs refuse until SERVICE is set back (the command is printed).
set -euo pipefail
usage() { echo "usage: $0 CHANGE SERVICE CAND_DIGEST [--keep|--check]" >&2; exit 2; }
KEEP=0; CHECK=0; pos=()
for x in "$@"; do case $x in --keep) KEEP=1 ;; --check) CHECK=1 ;; -h | --help) sed -n '2,19p' "$0"; exit 0 ;; -*) usage ;; *) pos+=("$x") ;; esac; done
((${#pos[@]} == 3)) || usage
CHANGE=${pos[0]}; SERVICE=${pos[1]}; CAND=${pos[2]}
WHO="truth $CHANGE"
# shellcheck source=vlib.sh
. "$(dirname "$(readlink -f "$0")")/vlib.sh"
valid_name "$CHANGE" || { echo "CHANGE: [a-z0-9-], at most 41 chars" >&2; usage; }
IFS=, read -r -a SVCS <<< "$SERVICE"   # 2026-10-31: SERVICE may list up to 5 services (one candidate image, CI v2)
((${#SVCS[@]} >= 1 && ${#SVCS[@]} <= 5)) || { echo "SERVICE: 1 to 5 maze service names, comma-separated" >&2; usage; }
for s_ in "${SVCS[@]}"; do [[ $s_ =~ ^[a-z][a-z0-9-]{0,30}$ ]] || { echo "SERVICE: a maze service name" >&2; usage; }; done
[[ $(printf '%s\n' "${SVCS[@]}" | sort -u | wc -l) == "${#SVCS[@]}" ]] || { echo "SERVICE: a service twice" >&2; usage; }
IFS=, read -r -a CANDL <<< "$CAND"   # one digest for every listed service (one image), or one per service in order
((${#CANDL[@]} == 1 || ${#CANDL[@]} == ${#SVCS[@]})) || { echo "CAND_DIGEST: one digest, or one per listed service" >&2; usage; }
declare -A CANDS=()
for i_ in "${!SVCS[@]}"; do
  c_=${CANDL[0]}; ((${#CANDL[@]} == 1)) || c_=${CANDL[$i_]}
  valid_digest "$c_" || { echo "CAND_DIGEST: sha256:<64 hex>" >&2; usage; }
  CANDS[${SVCS[$i_]}]=$c_
done
CAND=${CANDL[0]}   # truth.json cand_digest: the first service's (cand_digests lists each)
WARM_C=${RBD_WARM_C:-180}; WARM_BACK=${RBD_WARM_BACK:-120}
WARM_B0=${RBD_WARM_B0:-120}   # 2026-10-31: B0 waits until the background load has run this long at the current setting
[[ $WARM_B0 =~ ^[0-9]+$ ]] || { echo "RBD_WARM_B0: whole seconds" >&2; usage; }
B0N=truth-$CHANGE-b0; CN=truth-$CHANGE-c
SEED=$(seed_of "$B0N"); SEED2=$(seed_of "$CN")
[[ $SEED2 != "$SEED" ]] || SEED2=$((SEED + 1))
STATUS=preflight; PHASE=preflight; ERR=; OUT=; ROLLED=0; RESTORED=0; BASE=; LIVE0=; LIVE1=
declare -A BASES=()
declare -A T=() NODES=(); WARN=(); B0_SETTLE=0

state() {   # truth.json, atomically
  [[ -n $OUT && -d $OUT ]] || return 0
  local ta=() k
  for k in "${!T[@]}"; do ta+=(--arg "$k" "${T[$k]}"); done
  jq -n --arg change "$CHANGE" --arg service "$SERVICE" --arg status "$STATUS" --arg phase "$PHASE" --arg error "$ERR" \
    --argjson keep "$KEEP" --arg image_ref "$RBD_ECR" --arg base "$BASE" --arg cand "$CAND" --arg live0 "$LIVE0" \
    --arg live1 "$LIVE1" --arg b0n "$B0N" --arg cn "$CN" --argjson seed "$SEED" --argjson seed2 "$SEED2" \
    --argjson window "$WINDOW_S" --argjson warm_c "$WARM_C" --argjson warm_back "$WARM_BACK" \
    --argjson warm_b0 "$WARM_B0" --argjson b0_settle "$B0_SETTLE" \
    --argjson services "$(printf '%s\n' "${SVCS[@]}" | jq -R . | jq -s .)" \
    --argjson bases "$(for k in "${!BASES[@]}"; do jq -n --arg k "$k" --arg v "${BASES[$k]}" '{($k): $v}'; done | jq -s 'add // {}')" \
    --argjson cands "$(for k in "${!CANDS[@]}"; do jq -n --arg k "$k" --arg v "${CANDS[$k]}" '{($k): $v}'; done | jq -s 'add // {}')" \
    --argjson nodes "$(for k in "${!NODES[@]}"; do jq -n --arg k "$k" --arg v "${NODES[$k]}" '{($k): $v}'; done | jq -s 'add // {}')" \
    --argjson times "$(jq -n '$ARGS.named' "${ta[@]}")" \
    --argjson warnings "$(if ((${#WARN[@]})); then printf '%s\n' "${WARN[@]}" | jq -R . | jq -s .; else echo '[]'; fi)" \
    '{schema: "rbd.truth/v1", change: $change, service: $service, status: $status, phase: $phase, error: $error,
      keep: ($keep == 1), image_ref: $image_ref, base_digest: $base, cand_digest: $cand, live_before: $live0,
      live_after: $live1, captures: {b0: $b0n, c: $cn}, seeds: {b0: $seed, c: $seed2}, window_s: $window,
      services: $services, base_digests: $bases, cand_digests: $cands,
      warm_c_s: $warm_c, warm_back_s: $warm_back, warm_b0_s: $warm_b0, b0_settle_s: $b0_settle, nodes: $nodes,
      times: $times, warnings: $warnings}' | put "$OUT/truth.json"
}
warn() { WARN+=("$*"); vlog "WARN: $*"; }
mark() { PHASE=$1; T[$1]=$(now); state; vlog "phase $1"; }

set_one() {   # set_one SVC DIGEST: SVC to RBD_ECR@DIGEST (no wait)
  vlog "set image deployment/$1 $1=$RBD_ECR@$2"
  "${KG[@]}" set image "deployment/$1" "$1=$RBD_ECR@$2"
}
set_image() {   # set_image cand|base: every listed service to the candidate (one image) or back to its own baseline digest;
  # all set first, then each rollout status and live image checked
  local s d got rc=0
  for s in "${SVCS[@]}"; do d=${CANDS[$s]}; [[ $1 == cand ]] || d=${BASES[$s]}; set_one "$s" "$d" || rc=1; done
  for s in "${SVCS[@]}"; do
    d=${CANDS[$s]}; [[ $1 == cand ]] || d=${BASES[$s]}
    kubectl -n "$NS" rollout status "deployment/$s" --timeout="$ROLLOUT_TIMEOUT" || { rc=1; continue; }
    got=$(live_image "$s") || { rc=1; continue; }
    [[ $got == "$RBD_ECR@$d" ]] || { vlog "live image $got after set image $RBD_ECR@$d"; rc=1; }
  done
  return $rc
}

nodes_of() {   # nodes_of PHASE: the nodes of each listed service's pods now (truth.json .nodes.PHASE; placement is not pinned)
  local s n=()
  for s in "${SVCS[@]}"; do
    n+=("$s=$("${KG[@]}" get pods -l "app=$s" -o 'jsonpath={range .items[*]}{.spec.nodeName}{" "}{end}' 2> /dev/null | xargs | tr ' ' '+' || true)")
  done
  NODES[$1]=${n[*]}
  ((${#SVCS[@]} > 1)) || NODES[$1]=${NODES[$1]#*=}   # one service: as before (node names only)
}

settle_b0() {   # B0 starts only after the background load has run WARM_B0 s at the current setting (a load.sh set/reset restarts it)
  local st age
  st=$("${KG[@]}" get job "${RBD_BGLOAD_JOB:-maze-bgload}" -o 'jsonpath={.status.startTime}' 2> /dev/null || true)
  if [[ -z $st ]]; then warn "background load job not found: B0 waits the full ${WARM_B0}s"; B0_SETTLE=$WARM_B0
  else age=$(($(date -u +%s) - $(date -u -d "$st" +%s))); ((age >= WARM_B0)) || B0_SETTLE=$((WARM_B0 - age)); fi
  ((B0_SETTLE == 0)) || { vlog "B0 waits ${B0_SETTLE}s: the background load started at ${st:-?}"; snooze "$B0_SETTLE"; }
}

on_exit() {
  local rc=$?
  trap - EXIT INT TERM HUP
  [[ -z $CHILD ]] || kill "$CHILD" 2> /dev/null || true
  if ((CHECK)); then exit "$rc"; fi
  if ((rc != 0)); then
    [[ -n $ERR ]] || ERR="exit $rc in phase $PHASE"
    STATUS=failed
    if ((ROLLED && !RESTORED && !KEEP)); then
      vlog "failure in phase $PHASE: rolling $SERVICE back to their baseline digests"
      T[rollback_on_failure]=$(now)
      if set_image base; then
        RESTORED=1; STATUS=failed-restored; LIVE1=$RBD_ECR@$BASE
      else
        STATUS=failed-not-restored; rc=4
        for s_ in "${SVCS[@]}"; do vlog "FAIL: ROLLBACK FAILED: production $s_ may run $CAND; restore by hand: kubectl -n $NS set image deployment/$s_ $s_=$RBD_ECR@${BASES[$s_]}"; done
      fi
    elif ((ROLLED && KEEP)); then
      STATUS=failed-kept
      vlog "failure with --keep: production $SERVICE stays on $CAND"
    fi
  fi
  T[finished]=$(now); state || true
  jq -cn --arg c "$CHANGE" --arg s "$STATUS" --arg e "$ERR" --arg o "$OUT" --argjson rc "$rc" \
    '{step: "truth", ok: ($rc == 0), change: $c, status: $s, error: $e, out: $o, exit: $rc}' || true
  exit "$rc"
}
trap on_exit EXIT
trap 'ERR="signal INT in phase $PHASE"; exit 130' INT
trap 'ERR="signal TERM in phase $PHASE"; exit 143' TERM
trap 'ERR="signal HUP in phase $PHASE"; exit 129' HUP

# ---- preflight (read-only)
env_load
for s_ in "${SVCS[@]}"; do
  b_=$(base_digest "$s_") || vdie "baseline.json (see above)"
  [[ ${CANDS[$s_]} != "$b_" ]] || vdie "the candidate is production's digest $b_ for $s_: nothing to measure"
  l_=$(live_image "$s_") || vdie "live image (see above)"
  [[ ${l_##*@} == "$b_" ]] || vdie "production $s_ runs $l_, baseline.json says $b_: restore it (or deploy.sh) first"
  [[ ${l_%@*} == "$RBD_ECR" ]] || vdie "production $s_ image $l_ is not from RBD_ECR $RBD_ECR"
  BASES[$s_]=$b_
done
BASE=${BASES[${SVCS[0]}]}; LIVE0=$(live_image "${SVCS[0]}")   # truth.json base_digest/live_before: the first service's
VDIR=$RBD_HOME/verify/truth/$CHANGE
for p in "$VDIR" "$RBD_HOME/captures/$B0N" "$RBD_HOME/captures/$CN"; do
  [[ ! -e $p ]] || vdie "$p exists: re-run under a new CHANGE name (the old files stay)"
done
[[ -x $RBD_CI/capture.sh ]] || vdie "no $RBD_CI/capture.sh"
[[ -r $RBD_LIB/lock.sh ]] || vdie "no $RBD_LIB/lock.sh (part B's install)"
if ((CHECK)); then
  lock_free || vdie "the lock is held now ($RBD_HOME/lock)"
  vlog "check ok: $SERVICE $BASE -> $CAND, captures $B0N (seed $SEED) $CN (seed $SEED2), keep=$KEEP"
  exit 0
fi

# ---- the bracket
lock_take "truth-$CHANGE"
mkdir -p "$VDIR" || vdie "cannot create $VDIR"
OUT=$VDIR; VLOG=$OUT/truth.log; STATUS=running
vlog "start: $SERVICE base $BASE cand $CAND keep=$KEEP window ${WINDOW_S}s warm ${WARM_C}s/${WARM_BACK}s"
settle_b0
nodes_of b0
mark b0_start
capture "$B0N" "$SEED" "$OUT/b0.load.json" "$OUT/b0.capture.log"
((CAP_RC == 0)) || WARN+=("capture.sh $B0N exited $CAP_RC: the window finished, its load.json is used ($CAP_LOAD)")
mark b0_end
mark rollout_start
ROLLED=1
set_image cand || vdie "rollout of $CAND failed"
mark rollout_done
bg=$("${KG[@]}" get job "${RBD_BGLOAD_JOB:-maze-bgload}" -o 'jsonpath={.status.active}' 2> /dev/null || true)
[[ $bg == 1 ]] || warn "background load job ${RBD_BGLOAD_JOB:-maze-bgload} not active (got '$bg'): the warm-up ran without it"
snooze "$WARM_C"
nodes_of c
mark c_start
capture "$CN" "$SEED2" "$OUT/c.load.json" "$OUT/c.capture.log"
((CAP_RC == 0)) || WARN+=("capture.sh $CN exited $CAP_RC: the window finished, its load.json is used ($CAP_LOAD)")
mark c_end
if ((KEEP)); then
  LIVE1=$RBD_ECR@$CAND; STATUS=ok-kept
  vlog "--keep: production $SERVICE stays on $CAND; baseline.json unchanged, so deploy.sh refuses until restored:"
  vlog "  kubectl -n $NS set image deployment/$SERVICE $SERVICE=$RBD_ECR@$BASE && kubectl -n $NS rollout status deployment/$SERVICE"
else
  mark rollback_start
  set_image base || vdie "rollback to the baseline digests failed"
  RESTORED=1; LIVE1=$RBD_ECR@$BASE
  mark rollback_done
  snooze "$WARM_BACK"
  nodes_of after
  STATUS=ok
fi
mark complete
vlog "done: $STATUS"
