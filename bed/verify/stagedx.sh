#!/usr/bin/env bash
# verify/stagedx.sh: a STAGED rollout of a change of several services, measured (experiment 2b part 3, outside the product).
# truthx.sh's bracket with the deploy split into stages: one B0, then the listed services one at a time IN THE ORDER GIVEN,
# each stage followed by its own warm-up and window. On rbd-tools1 as user rbd.
#   stagedx.sh NAME SVC=DIGEST... [--check]  NAME [a-z0-9-] (<= 41 chars); 1..32 distinct maze services, each with its own
#                                            candidate digest (sha256:<64 hex>); --check: preflight only, changes nothing
# Under the cluster lock, for the whole run (about 6 + 9 min per stage with the defaults: run it with 'orch/rbd.sh bg'):
#   0. B0 waits until the background load has run RBD_WARM_B0 (120) s at the current setting
#   1. B0 = capture.sh stagedx-NAME-b0 RBD_WINDOW_S SEED (production at baseline.json: EVERY service, checked in preflight)
#   2. stage k = 1..n: kubectl -n maze set image deployment/SVC_k SVC_k=RBD_ECR@DIGEST_k (the earlier stages stay deployed),
#      its rollout status and live image; warm-up RBD_WARM_C (180) s; Ck = capture.sh stagedx-NAME-cK RBD_WINDOW_S SEED_k
#   3. rollback: every listed service back to ITS OWN baseline.json digest, rollout status, live image; warm-up RBD_WARM_BACK
#      (120) s; then every service of baseline.json is checked again (a drift is a warning, not a failure)
# Every stage runs: the staged strategy's stop (at the first stage whose window regresses against B0) is applied when the
# windows are scored (verify/regress.py --b0 b0.load.json --c cK.load.json), not here.
# Always rolled back. Any failure or signal (INT TERM HUP) after stage 1 started: every listed service set back to its
# baseline digest, exit 1 (4 when that rollback failed too). Preflight refuses as truthx.sh does.
# Writes $RBD_HOME/verify/stagedx/NAME/: truth.json (rbd.stagedx/v1, rewritten atomically at every phase), b0.load.json,
#   c1.load.json .. cN.load.json, truth.log and the capture logs. truth.json: truthx.sh's fields, with times.{b0_start,
#   b0_end, sK_deploy_started, sK_deploy_done, sK_c_start, sK_c_end (K = 1..n), rollback_started, rollback_done, complete,
#   finished; on a failure rollback_on_failure, rollback_on_failure_done} and stages [{k, service, capture, seed}].
# Last stdout line: {"step":"stagedx","ok",...,"status","phase","error","out","exit"}.
# Exit: 0 ok; 1 failed (production restored); 2 usage; 4 failed AND the rollback failed (production may run candidates).
# Env: as truthx.sh.
set -euo pipefail
usage() { echo "usage: $0 NAME SVC=DIGEST... [--check]" >&2; exit 2; }
CHECK=0; pos=()
for x in "$@"; do case $x in --check) CHECK=1 ;; -h | --help) sed -n '2,30p' "$0"; exit 0 ;; -*) usage ;; *) pos+=("$x") ;; esac; done
((${#pos[@]} >= 2)) || usage
NAME=${pos[0]}
WHO="stagedx $NAME"
RBD_WINDOW_S=${RBD_WINDOW_S:-300}   # before vlib.sh: it fixes WINDOW_S when sourced (600 there); the bed's rbd.env.local says 300 too
# shellcheck source=vlib.sh
. "$(dirname "$(readlink -f "$0")")/vlib.sh"
valid_name "$NAME" || { echo "NAME: [a-z0-9-], at most 41 chars" >&2; usage; }
SVCS=(); declare -A CANDS=()
for p_ in "${pos[@]:1}"; do
  [[ $p_ == *=* ]] || { echo "not SVC=DIGEST: $p_" >&2; usage; }
  s_=${p_%%=*}; d_=${p_#*=}
  [[ $s_ =~ ^[a-z][a-z0-9-]{0,30}$ ]] || { echo "SVC: a maze service name (got '$s_')" >&2; usage; }
  valid_digest "$d_" || { echo "DIGEST of $s_: sha256:<64 hex> (got '$d_')" >&2; usage; }
  [[ -z ${CANDS[$s_]:-} ]] || { echo "SVC: $s_ listed twice" >&2; usage; }
  SVCS+=("$s_"); CANDS[$s_]=$d_
done
((${#SVCS[@]} >= 1 && ${#SVCS[@]} <= 32)) || { echo "1 to 32 services" >&2; usage; }
SERVICE=$(IFS=,; echo "${SVCS[*]}")
CAND=${CANDS[${SVCS[0]}]}   # truth.json cand_digest: the first service's (cand_digests lists each)
WARM_C=${RBD_WARM_C:-180}; WARM_BACK=${RBD_WARM_BACK:-120}; WARM_B0=${RBD_WARM_B0:-120}
for v_ in "$WINDOW_S" "$WARM_C" "$WARM_BACK" "$WARM_B0"; do
  [[ $v_ =~ ^[0-9]+$ ]] || { echo "RBD_WINDOW_S, RBD_WARM_C, RBD_WARM_BACK, RBD_WARM_B0: whole seconds" >&2; usage; }
done
B0N=stagedx-$NAME-b0; CN=stagedx-$NAME-c1
SEED=$(seed_of "$B0N"); SEED2=$(seed_of "$CN")
[[ $SEED2 != "$SEED" ]] || SEED2=$((SEED + 1))
CNS=(); CSEEDS=()
for k_ in $(seq 1 ${#SVCS[@]}); do
  c_=stagedx-$NAME-c$k_; s_=$(seed_of "$c_"); [[ $s_ != "$SEED" ]] || s_=$((s_ + 1))
  CNS+=("$c_"); CSEEDS+=("$s_")
done
STATUS=preflight; PHASE=preflight; ERR=; OUT=; ROLLED=0; RESTORED=0; BASE=; LIVE0=; LIVE1=
declare -A BASES=() T=() TE=() NODES=(); WARN=(); B0_SETTLE=0; DRIFT=()

jmap() {   # jmap NAME: the associative array NAME as one JSON object
  local -n m_=$1
  local k
  for k in "${!m_[@]}"; do jq -n --arg k "$k" --arg v "${m_[$k]}" '{($k): $v}'; done | jq -s 'add // {}'
}
jlist() { if (($#)); then printf '%s\n' "$@" | jq -R . | jq -s .; else echo '[]'; fi; }
dur() { [[ -n ${TE[$1]:-} && -n ${TE[$2]:-} ]] && echo $((TE[$2] - TE[$1])) || echo null; }

state() {   # truth.json, atomically
  [[ -n $OUT && -d $OUT ]] || return 0
  local tot=null endk=$PHASE
  [[ -z ${TE[finished]:-} ]] || endk=finished
  [[ -z ${TE[b0_start]:-} || -z ${TE[$endk]:-} ]] || tot=$((TE[$endk] - TE[b0_start]))
  jq -n --arg name "$NAME" --arg service "$SERVICE" --arg status "$STATUS" --arg phase "$PHASE" --arg error "$(rd "$ERR")" \
    --arg image_ref "$(rd "$RBD_ECR")" --arg base "$BASE" --arg cand "$CAND" --arg live0 "$(rd "$LIVE0")" \
    --arg live1 "$(rd "$LIVE1")" \
    --arg b0n "$B0N" --arg cn "$CN" --argjson seed "$SEED" --argjson seed2 "$SEED2" \
    --argjson window "$WINDOW_S" --argjson warm_c "$WARM_C" --argjson warm_back "$WARM_BACK" \
    --argjson warm_b0 "$WARM_B0" --argjson b0_settle "$B0_SETTLE" \
    --argjson services "$(jlist "${SVCS[@]}")" --argjson bases "$(jmap BASES)" --argjson cands "$(jmap CANDS)" \
    --argjson nodes "$(jmap NODES)" --argjson times "$(jmap T)" --argjson warnings "$(jlist "${WARN[@]}")" \
    --argjson drift "$(jlist "${DRIFT[@]}")" --argjson d_deploy "$(dur s1_deploy_started "s${#SVCS[@]}_deploy_done")" \
    --argjson stages "$(stages_json)" \
    --argjson d_back "$(dur rollback_started rollback_done)" --argjson d_tot "$tot" \
    '{schema: "rbd.stagedx/v1", change: $name, name: $name, service: $service, status: $status, phase: $phase,
      error: $error, keep: false, image_ref: $image_ref, base_digest: $base, cand_digest: $cand, live_before: $live0,
      live_after: $live1, captures: {b0: $b0n, c: $cn}, seeds: {b0: $seed, c: $seed2}, window_s: $window,
      services: $services, base_digests: $bases, cand_digests: $cands,
      warm_c_s: $warm_c, warm_back_s: $warm_back, warm_b0_s: $warm_b0, b0_settle_s: $b0_settle, nodes: $nodes,
      times: $times, c_window: {start: ($times.c_window_start // null), end: ($times.c_window_end // null)},
      durations_s: {deploy: $d_deploy, rollback: $d_back, total: $d_tot}, drift_after: $drift,
      warnings: $warnings, stages: $stages}' | put "$OUT/truth.json"
}
stages_json() {   # the stages, in order: [{k, service, capture, seed}]
  local k
  for k in "${!SVCS[@]}"; do
    jq -n --argjson k $((k + 1)) --arg s "${SVCS[$k]}" --arg c "${CNS[$k]}" --argjson seed "${CSEEDS[$k]}" \
      '{k: $k, service: $s, capture: $c, seed: $seed}'
  done | jq -s .
}
rd() {   # rd TEXT: TEXT with rbd.env's RBD_ACCOUNT as <account> (RBD_ECR holds it): what truthx writes is fetched to the driver box
  local t=$*
  [[ -z ${RBD_ACCOUNT:-} ]] || t=${t//"$RBD_ACCOUNT"/<account>}
  printf '%s' "$t"
}
warn() { WARN+=("$(rd "$*")"); vlog "WARN: $(rd "$*")"; }
# shellcheck disable=SC2034  # T: read through jmap's nameref
stamp() { T[$1]=$(now); TE[$1]=$(date -u +%s); }
mark() { PHASE=$1; stamp "$1"; state; vlog "phase $1"; }

waitfor() {   # waitfor CMD...: CMD in the background, waited on (a trapped signal interrupts the wait at once, not after CMD)
  local rc=0
  "$@" &
  CHILD=$!
  wait "$CHILD" || rc=$?
  CHILD=
  return "$rc"
}
set_one() {   # set_one SVC DIGEST: SVC to RBD_ECR@DIGEST (no wait)
  vlog "set image deployment/$1 $1=\$RBD_ECR@$2"
  waitfor "${KG[@]}" set image "deployment/$1" "$1=$RBD_ECR@$2" >&2
}
set_image() {   # set_image cand|base: every listed service to its candidate or back to its own baseline digest; all set first,
  # then each rollout status and live image checked
  local s d got rc=0
  for s in "${SVCS[@]}"; do d=${CANDS[$s]}; [[ $1 == cand ]] || d=${BASES[$s]}; set_one "$s" "$d" || rc=1; done
  for s in "${SVCS[@]}"; do
    d=${CANDS[$s]}; [[ $1 == cand ]] || d=${BASES[$s]}
    waitfor kubectl -n "$NS" rollout status "deployment/$s" --timeout="$ROLLOUT_TIMEOUT" >&2 ||
      { vlog "rollout status $s failed"; rc=1; continue; }
    got=$("${KG[@]}" get deployment "$s" -o "jsonpath={.spec.template.spec.containers[?(@.name==\"$s\")].image}") ||
      { vlog "kubectl get deployment $s failed"; rc=1; continue; }
    [[ $got == "$RBD_ECR@$d" ]] || { vlog "$(rd "live image $got after set image $RBD_ECR@$d")"; rc=1; }
  done
  return $rc
}

nodes_of() {   # nodes_of PHASE: SVC=node+node ... of each listed service's pods now (placement is not pinned)
  local s n=()
  for s in "${SVCS[@]}"; do
    n+=("$s=$("${KG[@]}" get pods -l "app=$s" -o 'jsonpath={range .items[*]}{.spec.nodeName}{" "}{end}' 2> /dev/null | xargs | tr ' ' '+' || true)")
  done
  # shellcheck disable=SC2034  # NODES: read through jmap's nameref
  NODES[$1]=${n[*]}
}

settle_b0() {   # B0 starts only after the background load has run WARM_B0 s at the current setting (a load.sh set/reset restarts it)
  ((WARM_B0 > 0)) || return 0
  local st t0 age
  st=$("${KG[@]}" get job "${RBD_BGLOAD_JOB:-maze-bgload}" -o 'jsonpath={.status.startTime}' 2> /dev/null || true)
  if [[ $st =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9:]{8}Z$ ]] && t0=$(date -u -d "$st" +%s 2> /dev/null); then
    age=$(($(date -u +%s) - t0)); ((age >= 0)) || age=0
    ((age >= WARM_B0)) || B0_SETTLE=$((WARM_B0 - age))
  else
    warn "background load job start time not found (got '$st'): B0 waits the full ${WARM_B0}s"; B0_SETTLE=$WARM_B0
  fi
  ((B0_SETTLE == 0)) || { vlog "B0 waits ${B0_SETTLE}s: the background load started at ${st:-?}"; snooze "$B0_SETTLE"; }
}

drift_check() {   # every service of baseline.json at its digest now? (after the rollback: a drift is recorded, not fatal)
  local s d img
  while read -r s d; do
    img=$("${KG[@]}" get deployment "$s" -o "jsonpath={.spec.template.spec.containers[?(@.name==\"$s\")].image}" 2> /dev/null) ||
      { DRIFT+=("$s: kubectl get failed"); continue; }
    [[ $img == "$RBD_ECR@$d" ]] || DRIFT+=("$(rd "$s runs ${img:-nothing} (baseline $d)")")
  done < <(jq -r '.services | to_entries[] | "\(.key) \(.value)"' "$BASELINE")
  ((${#DRIFT[@]} == 0)) || warn "after the rollback, production is not at baseline.json: ${DRIFT[*]}"
}

on_exit() {
  local rc=$?
  trap - EXIT
  trap '' INT TERM HUP   # a second signal must not cut the rollback short (SIGKILL still can)
  [[ -z $CHILD ]] || kill "$CHILD" 2> /dev/null || true
  if ((CHECK)); then exit "$rc"; fi
  if ((rc != 0)); then
    [[ -n $ERR ]] || ERR="exit $rc in phase $PHASE"
    STATUS=failed
    if ((ROLLED && !RESTORED)); then
      vlog "failure in phase $PHASE: rolling $SERVICE back to their baseline digests"
      stamp rollback_on_failure; state || true
      if set_image base; then
        RESTORED=1; STATUS=failed-restored; LIVE1=$RBD_ECR@$BASE; stamp rollback_on_failure_done
      else
        STATUS=failed-not-restored; rc=4
        for s_ in "${SVCS[@]}"; do vlog "FAIL: ROLLBACK FAILED: production $s_ may run ${CANDS[$s_]}; restore by hand (as rbd, rbd-env.sh sourced): kubectl -n $NS set image deployment/$s_ $s_=\$RBD_ECR@${BASES[$s_]}"; done
      fi
    fi
  fi
  stamp finished; state || true
  jq -cn --arg c "$NAME" --arg s "$STATUS" --arg p "$PHASE" --arg e "$ERR" --arg o "$OUT" --argjson rc "$rc" \
    '{step: "stagedx", ok: ($rc == 0), name: $c, status: $s, phase: $p, error: $e, out: $o, exit: $rc}' || true
  exit "$rc"
}
trap on_exit EXIT
trap 'ERR="signal INT in phase $PHASE"; exit 130' INT
trap 'ERR="signal TERM in phase $PHASE"; exit 143' TERM
trap 'ERR="signal HUP in phase $PHASE"; exit 129' HUP

# ---- preflight (read-only)
env_load
all_at_baseline   # B0 is production at baseline: every service, not only the listed ones
for s_ in "${SVCS[@]}"; do
  b_=$(base_digest "$s_") || vdie "baseline.json (see above)"
  [[ ${CANDS[$s_]} != "$b_" ]] || vdie "the candidate of $s_ is production's digest $b_: nothing to deploy"
  l_=$(live_image "$s_") || vdie "live image (see above)"
  [[ $l_ == "$RBD_ECR@$b_" ]] || vdie "$(rd "production $s_ runs $l_, not $RBD_ECR@$b_: restore it (or deploy.sh) first")"
  BASES[$s_]=$b_
done
BASE=${BASES[${SVCS[0]}]}; LIVE0=$RBD_ECR@$BASE   # truth.json base_digest/live_before: the first service's
VDIR=$RBD_HOME/verify/stagedx/$NAME
for p in "$VDIR" "$RBD_HOME/captures/$B0N" "${CNS[@]/#/$RBD_HOME/captures/}"; do
  [[ ! -e $p ]] || vdie "$p exists: re-run under a new NAME (the old files stay)"
done
[[ -x $RBD_CI/capture.sh ]] || vdie "no $RBD_CI/capture.sh"
[[ -r $RBD_LIB/lock.sh ]] || vdie "no $RBD_LIB/lock.sh (part B's install)"
if ((CHECK)); then
  lock_free || vdie "the lock is held now ($RBD_HOME/lock)"
  vlog "check ok: ${#SVCS[@]} stage(s) $SERVICE, captures $B0N (seed $SEED) ${CNS[*]}, window ${WINDOW_S}s"
  exit 0
fi

# ---- the run
lock_take "stagedx-$NAME"
mkdir -p "$VDIR" || vdie "cannot create $VDIR"
OUT=$VDIR; VLOG=$OUT/truth.log; STATUS=running
for s_ in "${SVCS[@]}"; do vlog "service $s_: base ${BASES[$s_]} cand ${CANDS[$s_]}"; done
vlog "start: ${#SVCS[@]} stage(s) in order $SERVICE, window ${WINDOW_S}s, warm ${WARM_C}s/${WARM_BACK}s"
settle_b0
nodes_of b0
mark b0_start
capture "$B0N" "$SEED" "$OUT/b0.load.json" "$OUT/b0.capture.log"
((CAP_RC == 0)) || WARN+=("capture.sh $B0N exited $CAP_RC: the window finished, its load.json is used ($CAP_LOAD)")
mark b0_end
ROLLED=1   # from here on a failure rolls every listed service back (set image of a service at its baseline is a no-op)
for k_ in "${!SVCS[@]}"; do
  s_=${SVCS[$k_]}; K_=$((k_ + 1))
  mark "s${K_}_deploy_started"
  set_one "$s_" "${CANDS[$s_]}" || vdie "stage $K_: set image $s_ failed"
  waitfor kubectl -n "$NS" rollout status "deployment/$s_" --timeout="$ROLLOUT_TIMEOUT" >&2 || vdie "stage $K_: rollout status $s_ failed"
  got_=$("${KG[@]}" get deployment "$s_" -o "jsonpath={.spec.template.spec.containers[?(@.name==\"$s_\")].image}") ||
    vdie "stage $K_: kubectl get deployment $s_ failed"
  [[ $got_ == "$RBD_ECR@${CANDS[$s_]}" ]] || vdie "$(rd "stage $K_: live image $got_ after set image $RBD_ECR@${CANDS[$s_]}")"
  mark "s${K_}_deploy_done"
  bg=$("${KG[@]}" get job "${RBD_BGLOAD_JOB:-maze-bgload}" -o 'jsonpath={.status.active}' 2> /dev/null || true)
  [[ $bg == 1 ]] || warn "stage $K_: background load job ${RBD_BGLOAD_JOB:-maze-bgload} not active (got '$bg'): the warm-up ran without it"
  snooze "$WARM_C"
  nodes_of "c$K_"
  mark "s${K_}_c_start"
  capture "${CNS[$k_]}" "${CSEEDS[$k_]}" "$OUT/c$K_.load.json" "$OUT/c$K_.capture.log"
  ((CAP_RC == 0)) || WARN+=("capture.sh ${CNS[$k_]} exited $CAP_RC: the window finished, its load.json is used ($CAP_LOAD)")
  mark "s${K_}_c_end"
done
mark rollback_started
set_image base || vdie "rollback to the baseline digests failed"
RESTORED=1; LIVE1=$RBD_ECR@$BASE
mark rollback_done
snooze "$WARM_BACK"
nodes_of after
drift_check
STATUS=ok
mark complete
vlog "done: $STATUS (${#SVCS[@]} stages, rollback $(dur rollback_started rollback_done) s)"
