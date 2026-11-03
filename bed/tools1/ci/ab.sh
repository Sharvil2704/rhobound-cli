#!/bin/bash
# The A/B of one change (SPEC 5): arms SERVICE-ab-a (BASE) and -b (CAND) in rbd-ab, abdrive on load1 sending one
# Poisson schedule to both, the Collector's files split per arm, `rhobound check` per arm, `rhobound diff-fit`.
# usage: ab.sh RUN SERVICE BASE_DIGEST CAND_DIGEST [AB_DIR]   (as rbd; writes $RBD_HOME/runs/RUN/AB_DIR/)
#        ab.sh RUN --all [SECONDS]   every service of the run's change request at once, one A/B per A/B node (below);
#                                    SECONDS (60..1800): the longer A/B the gate's preview asked for, of every service
#   AB_DIR: ab (the default) or ab-SERVICE, so the A/Bs of a multi-service change (CI v2: one per listed service, one
#   candidate image) live side by side in one run; predict.sh reads every ab/ and ab-<service>/ (never ab*.old-*).
# env (or rbd.env, which sudo keeps): AB_SECONDS 600, AB_WARMUP 60, AB_RATE (mix's), AB_SEED (from RUN),
#   AB_FLUSH_WAIT 20, AB_LOCK_WAIT 3000 (a truth bracket holds the lock ~35 min), AB_READY_TIMEOUT 300, AB_POLL 15,
#   AB_KEEP_RAW 1, AB_PROD_NS (RBD_NS, maze), AB_POOL_KEY rhobound.io/pool, AB_LOG_BYTES 0.
#   AB_LOG_BYTES 1: abdrive -log-bytes, loadgen.csv's 6th column bytes (each response body's size), which diff-fit turns
#   into the record's loadgen.response_bytes and, on a change above 10%, ab.payload_changed. It needs an abdrive image
#   with -log-bytes (images.sh builds one from tools1/abdrive) and a CLI that reads the bytes column (maze-fix d1f0bbdc or
#   later; the bed's 19baaed refuses the 6-column log at diff_fit).
#   abdrive's image: images.json "abdrive" (images_get), or RBD_ECR@RBD_ABDRIVE_DIGEST.
# Uses part B's lib: rbd-env.sh (env, images_get), lock.sh (rbd_lock), copy_traces.sh SINCE_NS UNTIL_NS OUTDIR.
# Under runs/RUN/.lock (flock; one step of a run at a time: pr-check, build, ab, predict, sign), taken before the cluster
# lock. Refused (stage run, before any cluster call) once runs/RUN holds predict.json or gate/: the A/B of a gated run is
# never re-run (a re-gate needs a new commit); a run without a prediction may be re-run (its earlier ab/ moves aside).
# The last stdout line is one JSON object {"step":"ab","ok":...}; exit 0 ok, 1 refused or failed. The arms and the
# driver pod are deleted on every exit path (trap); leftovers of a killed run are deleted at the next start.
# Names are per service (SERVICE-ab-a/-b, abdrive-SERVICE, abdrive-mix-SERVICE; label rbd.ab.svc=SERVICE), so the A/Bs of
# several services can run at once without touching each other's objects.
# --all (parallel A/Bs, 2026-11-03): the services of runs/RUN/pr.json, each with its candidate-<svc>.json's candidate and
# baseline digests (build.sh's: one image per image the change touches), so the workflow passes no digest. The parent holds
# runs/RUN/.lock and the cluster lock for the whole set, deletes every leftover in rbd-ab once, and runs one child ab.sh per
# service in ab-<svc>/, at most min(A/B nodes, AB_PARALLEL [3]) at a time, each child on its own Ready node of the A/B pool
# (nodeSelector kubernetes.io/hostname): an arm pair saturates a 4-vCPU node, so two A/Bs never share one (one A/B node:
# one at a time, as before). A child proves it is the parent's by runs/RUN/.ab-parent (a token only rbd can read), inherits
# both locks (fd 7 and fd 9, RBD_LOCK_HELD) and deletes only its own service's objects. Writes runs/RUN/ab-all.json (each
# service's node, start, end, exit). Last line {"step":"ab-all","ok",...,"services":[...],"parallel":N}; exit 0 when every
# A/B is ok, 1 otherwise. Every A/B's arms call production's callees, so N A/Bs at once put N A/Bs' side load on them.
set -euo pipefail

RUN=${1:-}; SERVICE=${2:-}; BASE=${3:-}; CAND=${4:-}; AB_DIR=${5:-ab}; MODE=${6:-}
ALL=0
ALL_SECONDS=""
if [[ $SERVICE == --all ]]; then ALL=1 ALL_SECONDS=${3:-} SERVICE="" BASE="" CAND="" AB_DIR=""; fi
STAGE=usage; ERR=""; FINISHED=0; TORN=0; CREATED=0; TEARDOWN=none; R=""; CHILD=0; TOKEN_FILE=""; ALL_OUT=""
CHILD_PIDS=()   # --all: the children still running (finish stops them)
NS=rbd-ab
RBD_STEP=ab
log() { echo "ab: $*" >&2; }
jstr() { printf '"%s"' "$(printf '%s' "$1" | tr '\n\t\r' '   ' | tr -d '\000-\037' | sed 's/\\/\\\\/g; s/"/\\"/g')"; }
stamp() { [[ -n $R && -d $R ]] && printf '%s %s\n' "$1" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" >>"$R/timings.txt"; return 0; }
stage() { STAGE=$1; log "== $1"; stamp "$1"; }
jf() {  # a file's (last) JSON value, or null
  local j=""
  if [[ -s $1 ]]; then j=$(jq -cs 'last' "$1" 2>/dev/null) || j=""; fi
  if [[ -n $j ]]; then printf '%s\n' "$j"; else echo null; fi
}

delete_ab() {  # our objects in rbd-ab (label rbd.ab=1; a parallel child: its own service's only), until the pods are gone
  local sel=rbd.ab=1
  [[ $CHILD == 0 ]] || sel="rbd.ab=1,rbd.ab.svc=$SERVICE"
  timeout 180 kubectl -n "$NS" delete deployment,replicaset,service,pod,configmap -l "$sel" --ignore-not-found \
    --cascade=foreground --wait=true --timeout=150s >&2
}
teardown() {
  [[ $TORN == 1 ]] && return 0
  TORN=1
  [[ $CREATED == 1 ]] || return 0
  if delete_ab; then TEARDOWN=ok; else TEARDOWN=failed; log "teardown FAILED"; fi
  stamp teardown
}

write_summary() {
  local ok=$1 f=$R/ab.json
  [[ -n $R && -d $R ]] || return 0
  local chk='{exit: .exit, verdict: .r.verdict, counts: .r.counts, kept_share: .r.kept_share, manifest: .r.manifest_sha256}'
  if jq -n --arg run "$RUN" --arg service "$SERVICE" --arg abdir "$AB_DIR" --argjson ok "$ok" --arg stage "$STAGE" --arg error "$ERR" \
    --arg base "$BASE" --arg cand "$CAND" --arg ecr "${RBD_ECR:-}" --arg abimg "${ABIMG:-}" \
    --arg live "${LIVE_DIGEST:-}" --arg prodbase "${PROD_BASE:-}" --arg teardown "$TEARDOWN" \
    --arg seconds "${AB_SECONDS:-}" --arg warmup "${AB_WARMUP:-}" --arg seed "${AB_SEED:-}" --arg rate "${RATE:-}" \
    --arg logbytes "${AB_LOG_BYTES:-}" \
    --arg ws "${WS:-}" --arg we "${WE:-}" --arg since "${SINCE_NS:-}" --arg until "${UNTIL_NS:-}" \
    --argjson copy "$(jf "$R/copy-traces.json")" \
    --arg drvexit "${DRV_EXIT:-}" --arg dfexit "${DF_EXIT:-}" --arg ca "${CHK_A:-}" --arg cb "${CHK_B:-}" \
    --argjson mix "$(jf "$R/mix.json")" --argjson drv "$(jf "$R/driver/summary.json")" \
    --argjson split "$(jf "$R/split.json")" --argjson cka "$(jf "$R/check-a.json")" \
    --argjson ckb "$(jf "$R/check-b.json")" --argjson df "$(jf "$R/diff-fit.json")" \
    --argjson rec "$(jf "$R/record/ab-record.json")" \
    --arg recsha "$( [[ -f $R/record/ab-record.json ]] && sha256sum "$R/record/ab-record.json" | cut -d' ' -f1)" \
    --arg dferr "$( [[ -f $R/diff-fit.err ]] && tail -n 5 "$R/diff-fit.err")" \
    --rawfile timings "$( [[ -f $R/timings.txt ]] && echo "$R/timings.txt" || echo /dev/null)" '
    def num: if . == "" then null else tonumber end;
    {schema: "rbd.ab/v1", run: $run, service: $service, ab_dir: $abdir, ok: $ok, stage: (if $ok then "done" else $stage end),
     error: (if $ok then null else $error end), base_digest: $base, cand_digest: $cand, image_ref: $ecr,
     abdrive_image: $abimg, live_digest: $live, baseline_json_digest: $prodbase,
     base_is_production: (if $prodbase == "" then null else $prodbase == $base end),
     seconds: ($seconds | num), warmup: ($warmup | num), seed: ($seed | num), rate: ($rate | num),
     log_bytes: (if $logbytes == "" then null else $logbytes == "1" end),
     window: {start: $ws, end: $we}, traces: {since_ns: ($since | num), until_ns: ($until | num), copy: $copy},
     mix: $mix, driver: {exit: ($drvexit | num), summary: $drv}, split: $split,
     check: {a: ({exit: ($ca | num), r: $cka} | '"$chk"'), b: ({exit: ($cb | num), r: $ckb} | '"$chk"')},
     diff_fit: {exit: ($dfexit | num), out: $df, stderr: $dferr},
     record: (if $rec == null then null else
       {path: "record/ab-record.json", sha256: ("sha256:" + $recsha), findings: $rec.findings,
        overlap_share: $rec.overlap_share, loadgen: $rec.loadgen,
        service: ([$rec.services[] | select(.service == $service)] | first)} end),
     teardown: $teardown,
     timings: ([$timings | split("\n")[] | select(length > 0) | split(" ") | {key: .[0], value: .[1]}] | from_entries)}
    ' >"$f.tmp" 2>"$R/ab.json.err"; then
    mv "$f.tmp" "$f"
  else
    log "could not write ab.json: $(cat "$R/ab.json.err")"
  fi
}

finish() {  # CODE: teardown, ab.json, then the last line
  local code=$1 dg="" delta="null" se="null"
  set +e
  trap - EXIT INT TERM
  FINISHED=1
  teardown
  if [[ $code == 0 ]]; then write_summary true; else write_summary false; fi
  if declare -F rbd_unlock >/dev/null; then rbd_unlock; fi   # lock.sh's: the holder file goes too (only its taker's)
  if [[ $ALL == 1 ]]; then
    if (( ${#CHILD_PIDS[@]} > 0 )); then   # the parent failed or was signalled: its children tear their arms down and stop
      kill -TERM "${CHILD_PIDS[@]}" 2>/dev/null || true
      wait "${CHILD_PIDS[@]}" 2>/dev/null || true
    fi
    [[ -z $TOKEN_FILE ]] || rm -f "$TOKEN_FILE"
    printf '{"step":"ab-all","ok":%s,"run":%s,"stage":%s,"error":%s,"services":%s,"parallel":%s,"out":%s}\n' \
      "$([[ $code == 0 ]] && echo true || echo false)" "$(jstr "$RUN")" "$(jstr "$STAGE")" "$(jstr "$ERR")" \
      "${ALL_SVCS_JSON:-[]}" "${ALL_WIDTH:-0}" "$(jstr "$ALL_OUT")"
    exit "$code"
  fi
  if [[ $code == 0 ]]; then
    dg=$(jq -r '.ab_digest // empty' "$R/diff-fit.json" 2>/dev/null)
    delta=$(jq -r --arg s "$SERVICE" '[.services[] | select(.service == $s)][0].own_ms.delta // "null"' \
      "$R/record/ab-record.json" 2>/dev/null || echo null)
    se=$(jq -r --arg s "$SERVICE" '[.services[] | select(.service == $s)][0].own_ms.se // "null"' \
      "$R/record/ab-record.json" 2>/dev/null || echo null)
    printf '{"step":"ab","ok":true,"run":%s,"service":%s,"dir":%s,"record":%s,"ab_digest":%s,"own_ms_delta":%s,"own_ms_se":%s,"teardown":%s}\n' \
      "$(jstr "$RUN")" "$(jstr "$SERVICE")" "$(jstr "$R")" "$(jstr "$R/record/ab-record.json")" "$(jstr "$dg")" \
      "${delta:-null}" "${se:-null}" "$(jstr "$TEARDOWN")"
  else
    printf '{"step":"ab","ok":false,"run":%s,"service":%s,"stage":%s,"error":%s,"dir":%s,"teardown":%s}\n' \
      "$(jstr "$RUN")" "$(jstr "$SERVICE")" "$(jstr "$STAGE")" "$(jstr "$ERR")" "$(jstr "$R")" "$(jstr "$TEARDOWN")"
  fi
  exit "$code"
}
fail() { ERR="$*"; log "FAILED at $STAGE: $ERR"; finish 1; }
# shellcheck disable=SC2317  # invoked by the EXIT trap
on_exit() { local rc=$?; [[ $FINISHED == 1 ]] && exit "$rc"; ERR=${ERR:-"unexpected exit $rc"}; finish 1; }
trap on_exit EXIT
trap 'ERR="interrupted by a signal"; finish 1' INT TERM

USAGE="usage: ab.sh RUN SERVICE BASE_DIGEST CAND_DIGEST [AB_DIR [preview|SECONDS]] | ab.sh RUN --all [SECONDS]"
if [[ $ALL == 1 ]]; then
  [[ $# -eq 2 || $# -eq 3 ]] || fail "$USAGE"
  [[ -z $ALL_SECONDS || ( $ALL_SECONDS =~ ^[0-9]{2,4}$ && $ALL_SECONDS -ge 60 && $ALL_SECONDS -le 1800 ) ]] \
    || fail "--all SECONDS $ALL_SECONDS: want 60..1800 (the longer A/B the gate's preview asked for)"
  [[ $RUN =~ ^[A-Za-z0-9]([A-Za-z0-9._-]{0,61}[A-Za-z0-9])?$ ]] || fail "RUN $RUN: 1-63 of [A-Za-z0-9._-]"
else
  [[ $# -ge 4 && $# -le 6 ]] || fail "$USAGE"
  [[ -z $MODE || $MODE == preview || $MODE =~ ^[0-9]{2,4}$ ]] || fail "MODE $MODE: want preview or SECONDS (60..1800)"
  [[ $RUN =~ ^[A-Za-z0-9]([A-Za-z0-9._-]{0,61}[A-Za-z0-9])?$ ]] || fail "RUN $RUN: 1-63 of [A-Za-z0-9._-]"
  [[ $SERVICE =~ ^[a-z]([a-z0-9-]{0,44}[a-z0-9])?$ ]] || fail "SERVICE $SERVICE: a DNS label of at most 46"
  [[ $AB_DIR == ab || $AB_DIR == "ab-$SERVICE" ]] || fail "AB_DIR $AB_DIR: want ab or ab-$SERVICE"
  for d in "$BASE" "$CAND"; do [[ $d =~ ^sha256:[0-9a-f]{64}$ ]] || fail "digest $d: want sha256:<64 hex>"; done
  BASE12=${BASE#sha256:}; BASE12=${BASE12:0:12}; CAND12=${CAND#sha256:}; CAND12=${CAND12:0:12}
fi
DRV=abdrive-$SERVICE DRVMIX=abdrive-mix-$SERVICE

stage env
# caller's AB_* win over rbd.env's (sudo's env_reset drops the caller's, so rbd.env is how the pipeline sets them)
for v in AB_SECONDS AB_WARMUP AB_RATE AB_SEED AB_FLUSH_WAIT AB_LOCK_WAIT AB_READY_TIMEOUT AB_POLL AB_KEEP_RAW \
         AB_PROD_NS AB_POOL_KEY AB_LOG_BYTES AB_PARALLEL; do if [[ -n ${!v:-} ]]; then printf -v "IN_$v" '%s' "${!v}"; fi; done
RBD_ROOT=/opt/rbd
[[ -z ${SUDO_USER:-} && -n ${RBD_OPT:-} ]] && RBD_ROOT=$RBD_OPT   # tests only; sudo's env_reset never passes it
export RBD_OPT=$RBD_ROOT RBD_STEP
RBD_LIB=$RBD_ROOT/lib
for f in rbd-env.sh lock.sh copy_traces.sh abmix.py splitarms.py; do [[ -f $RBD_LIB/$f ]] || fail "no $RBD_LIB/$f"; done
ERR="sourcing $RBD_LIB/rbd-env.sh failed (rbd.env; its message is above)"
# shellcheck source=/dev/null
. "$RBD_LIB/rbd-env.sh" || fail "$ERR"
ERR=""
for v in AB_SECONDS AB_WARMUP AB_RATE AB_SEED AB_FLUSH_WAIT AB_LOCK_WAIT AB_READY_TIMEOUT AB_POLL AB_KEEP_RAW \
         AB_PROD_NS AB_POOL_KEY AB_LOG_BYTES AB_PARALLEL; do iv=IN_$v; if [[ -n ${!iv:-} ]]; then printf -v "$v" '%s' "${!iv}"; fi; done
export PATH="$RBD_ROOT/bin:$PATH"
for v in RBD_HOME RBD_ECR KUBECONFIG RHOBOUND_STATE; do
  [[ -n ${!v:-} ]] || fail "$v is not set (rbd.env)"
done
export KUBECONFIG RHOBOUND_STATE
NS=${RBD_AB_NS:-rbd-ab}
CLI=${RBD_CLI:-$RBD_ROOT/bin/rhobound}
[[ -x $CLI ]] || fail "no rhobound CLI at $CLI"
for c in kubectl jq python3 flock timeout sha256sum; do
  command -v "$c" >/dev/null || fail "$c not found"
done
if [[ -n ${RBD_ABDRIVE_DIGEST:-} ]]; then
  ABIMG=$RBD_ECR@$RBD_ABDRIVE_DIGEST
else
  ABIMG=$(images_get abdrive) || fail "no abdrive image in $RBD_HOME/images.json (rbd_bootstrap.sh images)"
fi
[[ $ABIMG =~ ^[^@[:space:]]+@sha256:[0-9a-f]{64}$ ]] || fail "abdrive image $ABIMG: want REF@sha256:<64 hex>"
AB_SECONDS=${AB_SECONDS:-600}; AB_WARMUP=${AB_WARMUP:-60}; AB_FLUSH_WAIT=${AB_FLUSH_WAIT:-20}
AB_LOCK_WAIT=${AB_LOCK_WAIT:-3000}; AB_READY_TIMEOUT=${AB_READY_TIMEOUT:-300}; AB_POLL=${AB_POLL:-15}
AB_KEEP_RAW=${AB_KEEP_RAW:-1}; AB_PROD_NS=${AB_PROD_NS:-${RBD_NS:-maze}}; AB_POOL_KEY=${AB_POOL_KEY:-rhobound.io/pool}
AB_LOG_BYTES=${AB_LOG_BYTES:-0}; AB_PARALLEL=${AB_PARALLEL:-3}
[[ $AB_LOG_BYTES == 0 || $AB_LOG_BYTES == 1 ]] || fail "AB_LOG_BYTES=$AB_LOG_BYTES: want 0 or 1"
[[ $AB_PARALLEL =~ ^[1-9]$ ]] || fail "AB_PARALLEL=$AB_PARALLEL: want 1..9 (A/Bs at once; the drivers share the load node)"
AB_SEED=${AB_SEED:-$((16#$(printf '%s' "$RUN" | sha256sum | cut -c1-8)))}
for v in AB_SECONDS AB_WARMUP AB_FLUSH_WAIT AB_LOCK_WAIT AB_READY_TIMEOUT AB_POLL AB_SEED; do
  [[ ${!v} =~ ^[0-9]+$ ]] || fail "$v=${!v}: want a whole number"
done
(( AB_SECONDS > 0 )) || fail "AB_SECONDS must be > 0"

# --all: the run's services at once, one child ab.sh per service on its own A/B node (the header)
all_mode() {
  local run=$RBD_HOME/runs/$RUN self plan tok width i n rc dp svc slot
  self=$(readlink -f "$0")
  stage run
  [[ -d $run ]] || fail "no runs/$RUN (pr-check and build first)"
  exec 7>>"$run/.lock" || fail "cannot open runs/$RUN/.lock"
  flock -n 7 || fail "another step of runs/$RUN is running (runs/$RUN/.lock is held): one step of a run at a time"
  [[ ! -e $run/predict.json && ! -e $run/gate ]] \
    || fail "runs/$RUN already holds a prediction (predict.json or gate/): its A/Bs are not re-run; a re-gate needs a new commit"
  mkdir -p "$run/logs" || fail "cannot create runs/$RUN/logs"
  stage plan
  # the change request's services (pr-check's pr.json) and each one's candidate and baseline digests (build.sh's files)
  plan=$(python3 -I - "$run" 2>"$run/logs/ab-all.err" <<'PY'
import json, os, re, sys
run = sys.argv[1]
def fail(m):
    print(m, file=sys.stderr); sys.exit(1)
try:
    pr = json.load(open(os.path.join(run, "pr.json")))
except (OSError, ValueError) as e:
    fail("runs/RUN/pr.json: %s (pr-check first)" % e)
svcs = pr.get("services") or [pr.get("service")]
if (not isinstance(svcs, list) or not svcs or len(set(svcs)) != len(svcs)
        or not all(isinstance(x, str) and re.fullmatch(r"[a-z]([a-z0-9-]{0,44}[a-z0-9])?", x) for x in svcs)):
    fail("runs/RUN/pr.json names no valid services: %r" % (svcs,))
for s in svcs:
    try:
        c = json.load(open(os.path.join(run, "candidate-%s.json" % s)))
    except (OSError, ValueError) as e:
        fail("runs/RUN/candidate-%s.json: %s (build.sh first)" % (s, e))
    d, b = c.get("digest"), c.get("baseline_digest")
    if c.get("service") != s or not all(isinstance(x, str) and re.fullmatch(r"sha256:[0-9a-f]{64}", x) for x in (d, b)):
        fail("runs/RUN/candidate-%s.json: no valid service, digest and baseline_digest" % s)
    print(s, b, d)
PY
  ) || fail "the run's services and candidates: $(tail -n 1 "$run/logs/ab-all.err")"
  local -a P_SVC=() P_BASE=() P_CAND=()
  while read -r svc i n; do P_SVC+=("$svc"); P_BASE+=("$i"); P_CAND+=("$n"); done <<< "$plan"
  stage lock
  # shellcheck source=/dev/null
  . "$RBD_LIB/lock.sh" || fail "sourcing $RBD_LIB/lock.sh failed"
  rbd_lock "$AB_LOCK_WAIT" "ab --all $RUN" \
    || fail "the cluster lock is held by another step: $(rbd_lock_holder) (waited ${AB_LOCK_WAIT}s)"
  stage slots
  local -a SLOTS=()
  mapfile -t SLOTS < <(timeout 60 kubectl get nodes -l "$AB_POOL_KEY=ab" -o json 2>/dev/null | jq -r '.items[]
    | select(any(.status.conditions[]?; .type == "Ready" and .status == "True")) | select((.spec.unschedulable // false) | not)
    | .metadata.name' | sort)
  (( ${#SLOTS[@]} > 0 )) || fail "no Ready, schedulable node in the A/B pool ($AB_POOL_KEY=ab)"
  width=${#SLOTS[@]}; (( width <= ${#P_SVC[@]} )) || width=${#P_SVC[@]}; (( width <= AB_PARALLEL )) || width=$AB_PARALLEL
  ALL_WIDTH=$width
  log "--all: ${#P_SVC[@]} service(s) ${P_SVC[*]}; A/B nodes ${SLOTS[*]}; $width at a time${ALL_SECONDS:+; a longer A/B of ${ALL_SECONDS}s each}"
  stage cleanup
  delete_ab || fail "deleting an earlier A/B's leftovers in $NS"
  TOKEN_FILE=$run/.ab-parent
  tok=$(head -c 32 /dev/urandom | sha256sum | cut -c1-64)
  (umask 077; printf '%s' "$tok" > "$TOKEN_FILE") || fail "cannot write runs/$RUN/.ab-parent"
  stage ab
  local -A PSVC=() PSLOT=() T0=() T1=() RC=() NODE=()
  local -a FREE=("${SLOTS[@]:0:$width}")
  local t_all0; t_all0=$(date -u +%s)
  local -a child=("$self")
  # tests only: a stand-in child (never under sudo, whose env_reset drops it anyway)
  if [[ -z ${SUDO_USER:-} && -n ${AB_TEST_CHILD:-} ]]; then child=("$AB_TEST_CHILD"); fi
  reap() {   # one child has ended: its exit, end time and node back to FREE
    dp=""; rc=0
    wait -n -p dp || rc=$?
    [[ -n $dp && -n ${PSVC[$dp]:-} ]] || return 0
    RC[${PSVC[$dp]}]=$rc; T1[${PSVC[$dp]}]=$(date -u +%s); FREE+=("${PSLOT[$dp]}")
    log "--all: ${PSVC[$dp]} on ${PSLOT[$dp]} ended, exit $rc: $(tail -n 1 "$run/logs/ab-${PSVC[$dp]}.out" 2>/dev/null | head -c 300)"
    local k; for k in "${!CHILD_PIDS[@]}"; do [[ ${CHILD_PIDS[$k]} != "$dp" ]] || unset 'CHILD_PIDS[k]'; done
    unset 'PSVC[$dp]' 'PSLOT[$dp]'
  }
  for i in "${!P_SVC[@]}"; do
    while (( ${#FREE[@]} == 0 )); do reap; done
    svc=${P_SVC[$i]} slot=${FREE[0]}; FREE=("${FREE[@]:1}")
    NODE[$svc]=$slot; T0[$svc]=$(date -u +%s)
    AB_SLOT=$slot AB_PARENT_TOKEN=$tok bash "${child[@]}" "$RUN" "$svc" "${P_BASE[$i]}" "${P_CAND[$i]}" "ab-$svc" \
      ${ALL_SECONDS:+"$ALL_SECONDS"} >"$run/logs/ab-$svc.out" 2>"$run/logs/ab-$svc.err" &
    PSVC[$!]=$svc; PSLOT[$!]=$slot; CHILD_PIDS+=("$!")
    log "--all: $svc started on $slot (pid $!)"
  done
  while (( ${#PSVC[@]} > 0 )); do reap; done
  local t_all1; t_all1=$(date -u +%s)
  ALL_OUT=$run/ab-all.json
  [[ ! -e $ALL_OUT ]] || mv "$ALL_OUT" "$ALL_OUT.old-$(date -u +%Y%m%dT%H%M%SZ)" || fail "cannot move the earlier ab-all.json aside"
  for svc in "${P_SVC[@]}"; do
    jq -cn --arg s "$svc" --arg node "${NODE[$svc]}" --argjson t0 "${T0[$svc]}" --argjson t1 "${T1[$svc]:-0}" \
      --argjson rc "${RC[$svc]:-1}" --argjson ab "$(tail -n 1 "$run/logs/ab-$svc.out" 2>/dev/null | jq -c . 2>/dev/null || echo null)" \
      '{service: $s, node: $node, start: ($t0 | todate), end: ($t1 | todate), seconds: ($t1 - $t0), exit: $rc, ab: $ab}'
  done | jq -s --arg run "$RUN" --argjson w "$width" --argjson slots "$(printf '%s\n' "${SLOTS[@]}" | jq -R . | jq -s .)" \
    --argjson t0 "$t_all0" --argjson t1 "$t_all1" --arg secs "$ALL_SECONDS" \
    '{schema: "rbd.ab-all/v1", run: $run, parallel: $w, nodes: $slots, start: ($t0 | todate), end: ($t1 | todate),
      seconds: ($t1 - $t0), longer_ab_s: (if $secs == "" then null else ($secs | tonumber) end), services: .}' \
    > "$ALL_OUT.tmp" || fail "cannot write ab-all.json"
  mv "$ALL_OUT.tmp" "$ALL_OUT" || fail "cannot write ab-all.json"
  ALL_SVCS_JSON=$(jq -c '[.services[] | {service, node, seconds, exit, ok: (.ab.ok // false)}]' "$ALL_OUT")
  for svc in "${P_SVC[@]}"; do tail -n 1 "$run/logs/ab-$svc.out" 2>/dev/null || true; done
  local bad; bad=$(jq -r '[.services[] | select(.exit != 0 or (.ab.ok // false) != true) | .service] | join(" ")' "$ALL_OUT")
  [[ -z $bad ]] || fail "the A/B of $bad failed (runs/$RUN/logs/ab-<service>.err)"
  stage "done"
  finish 0
}
if [[ $ALL == 1 ]]; then all_mode; fi

# preview: the gate's verdict on the run's A/Bs so far, in a scratch run that is removed again (never a prediction of
# RUN, which predict.sh makes once): whether one longer A/B would decide a measurement-limited straddle (rule 10's
# gate.json ab_scale). Prints {"step":"ab-preview",...,"extend_seconds":N}: N = 0 when the gate needs no more
# measurement, or more cannot decide it; else AB_SECONDS x ab_scale x 1.2, at least 2x and at most 4x (1800 s at most).
preview() {
  STAGE=preview
  local src=$RBD_HOME/runs/$RUN sid scratch d n
  [[ -r $src/candidate.json && -r $src/policy.json ]] || fail "preview: no runs/$RUN with candidate.json and policy.json"
  [[ ! -e $src/predict.json && ! -e $src/gate ]] || fail "preview: runs/$RUN already holds a prediction"
  sid=$(printf 'ab-preview %s %s' "$RUN" "$(date -u +%s%N)" | sha1sum | cut -c1-40)
  scratch=$RBD_HOME/runs/$sid
  mkdir "$scratch" || fail "preview: cannot make a scratch run"
  cp "$src/candidate.json" "$src/policy.json" "$scratch/" || fail "preview: cannot copy the run's inputs"
  for d in "$src"/ab "$src"/ab-*; do
    [[ -d $d && $d != *.old-* ]] && { cp -r "$d" "$scratch/" || fail "preview: cannot copy $d"; }
  done
  bash "$RBD_ROOT/ci/predict.sh" "$sid" > "$scratch.out" 2>&1 || true
  n=$(python3 -I - "$scratch/gate/gate.json" "$AB_SECONDS" << 'PY'
import json, math, sys
try:
    g = json.load(open(sys.argv[1]))
except (OSError, ValueError):
    print(0); sys.exit()
k = g.get("ab_scale")
if g.get("verdict") != "inconclusive" or not isinstance(k, (int, float)) or not k > 0:
    print(0); sys.exit()
print(min(1800, math.ceil(int(sys.argv[2]) * min(4.0, max(2.0, 1.2 * k)))))
PY
  ) || n=0
  local verdict scale
  verdict=$(jq -r '.verdict // "none"' "$scratch/gate/gate.json" 2> /dev/null || echo none)
  scale=$(jq -r '.ab_scale // "null"' "$scratch/gate/gate.json" 2> /dev/null || echo null)
  rm -rf "$scratch" "$scratch.out"
  log "preview of runs/$RUN: verdict $verdict, ab_scale $scale: a longer A/B of ${n:-0} s"
  printf '{"step":"ab-preview","ok":true,"run":%s,"service":%s,"verdict":%s,"ab_scale":%s,"extend_seconds":%s}\n' \
    "$(jstr "$RUN")" "$(jstr "$SERVICE")" "$(jstr "$verdict")" "$scale" "${n:-0}"
  FINISHED=1
  exit 0
}
if [[ $MODE == preview ]]; then preview; fi
if [[ $MODE =~ ^[0-9]+$ ]]; then
  (( MODE >= 60 && MODE <= 1800 )) || fail "SECONDS $MODE: want 60..1800"
  log "a longer A/B: $MODE s (rbd.env's AB_SECONDS is $AB_SECONDS), asked for by the gate's preview"
  AB_SECONDS=$MODE
fi

stage run
mkdir -p "$RBD_HOME/runs/$RUN" || fail "cannot create $RBD_HOME/runs/$RUN"
if [[ -n ${AB_PARENT_TOKEN:-} ]]; then
  # a child of ab.sh --all: the parent holds runs/RUN/.lock (fd 7, inherited) and the cluster lock (fd 9, RBD_LOCK_HELD)
  tf=$RBD_HOME/runs/$RUN/.ab-parent
  [[ -f $tf && ! -L $tf && $(head -c 64 "$tf") == "$AB_PARENT_TOKEN" ]] \
    || fail "AB_PARENT_TOKEN does not match runs/$RUN/.ab-parent: not a child of ab.sh --all"
  [[ -e /proc/$$/fd/7 && /proc/$$/fd/7 -ef $RBD_HOME/runs/$RUN/.lock ]] \
    || fail "a child of ab.sh --all without its parent's runs/$RUN/.lock (fd 7)"
  [[ ( -z $MODE || $MODE =~ ^[0-9]+$ ) && $AB_DIR == "ab-$SERVICE" ]] \
    || fail "a child of ab.sh --all runs one A/B (plain, or SECONDS long) in ab-$SERVICE"
  [[ ${AB_SLOT:-} =~ ^[a-z0-9]([a-z0-9.-]{0,251}[a-z0-9])?$ ]] || fail "a child of ab.sh --all needs its A/B node (AB_SLOT)"
  CHILD=1
else
  AB_SLOT=""
  # one step of a run at a time (pr-check, build, ab, predict, sign): a flock on runs/RUN/.lock, held until ab.sh exits
  exec 7>>"$RBD_HOME/runs/$RUN/.lock" || fail "cannot open runs/$RUN/.lock"
  flock -n 7 || fail "another step of runs/$RUN is running (runs/$RUN/.lock is held): one step of a run at a time"
fi
[[ ! -e $RBD_HOME/runs/$RUN/predict.json && ! -e $RBD_HOME/runs/$RUN/gate ]] \
  || fail "runs/$RUN already holds a prediction (predict.json or gate/): its A/B is not re-run; a re-gate needs a new commit"

stage lock
# shellcheck source=/dev/null
. "$RBD_LIB/lock.sh" || fail "sourcing $RBD_LIB/lock.sh failed"
rbd_lock "$AB_LOCK_WAIT" "ab $RUN $SERVICE" \
  || fail "the cluster lock is held by another step: $(rbd_lock_holder) (waited ${AB_LOCK_WAIT}s)"

stage dir
R=$RBD_HOME/runs/$RUN/$AB_DIR
if [[ -e $R ]]; then
  old=$R.old-$(date -u +%Y%m%dT%H%M%SZ)
  mv "$R" "$old" || fail "cannot move the earlier $R aside"
  log "an earlier A/B of this run moved to $old"
fi
mkdir -p "$R/meta" || fail "cannot create $R"
stamp start

stage mix
[[ -f $RBD_HOME/baseline.json ]] || fail "no $RBD_HOME/baseline.json"
CAPTURE=$(jq -r '.capture // empty' "$RBD_HOME/baseline.json") || fail "baseline.json does not parse"
[[ -n $CAPTURE ]] || fail "baseline.json names no capture"
PROD_BASE=$(jq -r --arg s "$SERVICE" '.services[$s] // empty' "$RBD_HOME/baseline.json")
CUT=$RBD_HOME/captures/$CAPTURE/cut
[[ -d $CUT ]] || fail "no cut capture $CUT"
python3 -I "$RBD_LIB/abmix.py" "$SERVICE" "$CUT" --name "$CAPTURE" >"$R/mix.json.tmp" 2>"$R/mix.err" \
  || fail "abmix: $(tail -n 3 "$R/mix.err")"
mv "$R/mix.json.tmp" "$R/mix.json"
RATE=${AB_RATE:-$(jq -r .rate_per_pod "$R/mix.json")}
jq -en --arg r "$RATE" '$r | tonumber > 0' >/dev/null 2>&1 || fail "rate $RATE: want a number > 0"
log "mix: $(jq -c '{rate_per_pod, paths, window_source}' "$R/mix.json"); rate $RATE/s per arm"

stage manifests
timeout 60 kubectl -n "$AB_PROD_NS" get deployment "$SERVICE" -o json >"$R/meta/prod-deploy.json" 2>"$R/meta/get.err" \
  || fail "kubectl get deployment $SERVICE -n $AB_PROD_NS: $(tail -n 2 "$R/meta/get.err")"
LIVE_DIGEST=$(jq -r '.spec.template.spec.containers[0].image // "" | split("@") | .[1] // ""' "$R/meta/prod-deploy.json")
# the arms: production's pod spec (one container: env, resources, ports, probes), our image, labels and placement. The
# env is production's byte for byte (OTEL_RESOURCE_ATTRIBUTES included: the split keys on the Collector's
# k8s.deployment.name and the pod name), so a candidate reads production's env; only callee URLs are made FQDNs.
jq --arg svc "$SERVICE" --arg imga "$RBD_ECR@$BASE" --arg imgb "$RBD_ECR@$CAND" --arg run "$RUN" --arg abns "$NS" \
   --arg prodns "$AB_PROD_NS" --arg poolkey "$AB_POOL_KEY" --arg slot "$AB_SLOT" '
  def bad(m): error("the production Deployment: " + m);
  def fq: if test("^http://[a-z0-9-]+:") then sub("^http://(?<h>[a-z0-9-]+):"; "http://\(.h).\($prodns).svc.cluster.local:")
          else . end;
  .spec.template.spec as $ps
  | ($ps.containers // []) as $cs
  | if ($cs | length) != 1 then bad("\($cs | length) containers; one is supported") else . end
  | $cs[0] as $c
  | if (($c.envFrom // []) | length) > 0 then bad("envFrom is not supported (MAZE_CONFIG must be a plain env entry)")
    else . end
  | if (($c.volumeMounts // []) | length) > 0 then bad("volumeMounts are not supported") else . end
  | if any(($c.env // [])[]; (.valueFrom // {}) | has("configMapKeyRef") or has("secretKeyRef"))
    then bad("env from a ConfigMap or Secret is not supported") else . end
  | if any(($c.env // [])[]; .name == "MAZE_CONFIG" and (.value | type) == "string") then .
    else bad("no plain MAZE_CONFIG env entry") end
  # maze: the arms run in the A/B namespace, so every callee in the MAZE_CONFIG routes (call, par, batch, after) is given
  # its production FQDN through MAZE_PEERS (the runtime default http://NAME:8080 would resolve in the wrong namespace)
  | (($c.env // [])[] | select(.name == "MAZE_CONFIG") | .value | fromjson) as $k
  | ([($k.routes // {})[] | ((.steps // [])[] | (.call.to?, (.par // [])[].to, .batch.to?)), (.after // [])[].to]
     | map(select(type == "string")) | unique) as $callees
  | if any(($c.env // [])[]; .name == "MAZE_PEERS") then bad("MAZE_PEERS is set in production; not supported") else . end
  | ($c.env // []) as $env0
  | ($env0 + (if any($env0[]; .name == "OTEL_SERVICE_NAME") then [] else [{name: "OTEL_SERVICE_NAME", value: $svc}] end)
     + (if ($callees | length) > 0
        then [{name: "MAZE_PEERS", value: ($callees | map({key: ., value: ("http://" + . + ":8080" | fq)}) | from_entries | tojson)}]
        else [] end))
    as $env
  | (($c.ports // [])[0].containerPort // 8080) as $port
  | def arm($arm; $img):
      {app: ($svc + "-ab"), "rbd.arm": $arm, "rbd.ab": "1", "rbd.ab.svc": $svc, "rbd.run": $run} as $labels
      | {apiVersion: "apps/v1", kind: "Deployment",
         metadata: {name: ($svc + "-ab-" + $arm), namespace: $abns, labels: $labels},
         spec: {replicas: 1, selector: {matchLabels: {app: ($svc + "-ab"), "rbd.arm": $arm}},
                template: {metadata: {labels: $labels},
                           spec: ({automountServiceAccountToken: false, imagePullSecrets: [{name: "ecr"}],
                                   nodeSelector: ({($poolkey): "ab"}
                                                  + (if $slot != "" then {"kubernetes.io/hostname": $slot} else {} end)),
                                   tolerations: [{key: $poolkey, operator: "Exists"}],
                                   terminationGracePeriodSeconds: ($ps.terminationGracePeriodSeconds // 30),
                                   containers: [$c | {name, image: $img, imagePullPolicy: "IfNotPresent", command, args,
                                                      workingDir, env: $env, ports, resources, readinessProbe,
                                                      livenessProbe, startupProbe, securityContext}
                                                   | with_entries(select(.value != null))]}
                                  + (if $ps.securityContext then {securityContext: $ps.securityContext} else {} end))}}};
    def svc($arm):
      {apiVersion: "v1", kind: "Service",
       metadata: {name: ($svc + "-ab-" + $arm), namespace: $abns,
                  labels: {app: ($svc + "-ab"), "rbd.arm": $arm, "rbd.ab": "1", "rbd.ab.svc": $svc, "rbd.run": $run}},
       spec: {type: "ClusterIP", selector: {app: ($svc + "-ab"), "rbd.arm": $arm},
              ports: [{name: "http", port: 8080, targetPort: $port}]}};
    {apiVersion: "v1", kind: "List", items: [arm("a"; $imga), arm("b"; $imgb), svc("a"), svc("b")]}
  ' "$R/meta/prod-deploy.json" >"$R/meta/arms.json" 2>"$R/meta/arms.err" \
  || fail "arm manifests: $(tail -n 2 "$R/meta/arms.err")"
URL_A=http://$SERVICE-ab-a.$NS.svc.cluster.local:8080
URL_B=http://$SERVICE-ab-b.$NS.svc.cluster.local:8080
# both arms see the Host maze's callers send (render.py's call URLs: http://SERVICE:8080/...), not the arm's name
args=$(jq -cn --arg a "$URL_A" --arg b "$URL_B" --arg rate "$RATE" --arg s "$AB_SECONDS" --arg w "$AB_WARMUP" \
  --arg seed "$AB_SEED" --arg svc "$SERVICE" --arg bytes "$AB_LOG_BYTES" '["-a", $a, "-b", $b, "-rate", $rate,
  "-seconds", $s, "-warmup", $w, "-seed", $seed, "-service", $svc, "-host", ($svc + ":8080"), "-mix",
  "/etc/abdrive/mix.json", "-out", "/out"] + (if $bytes == "1" then ["-log-bytes"] else [] end)')
jq -n --arg img "$ABIMG" --arg run "$RUN" --arg abns "$NS" --arg poolkey "$AB_POOL_KEY" --argjson args "$args" \
   --arg svc "$SERVICE" --arg drv "$DRV" --arg drvmix "$DRVMIX" --rawfile mix "$R/mix.json" '
  {apiVersion: "v1", kind: "List", items: [
   {apiVersion: "v1", kind: "ConfigMap", metadata: {name: $drvmix, namespace: $abns,
     labels: {app: "abdrive", "rbd.ab": "1", "rbd.ab.svc": $svc, "rbd.run": $run}}, data: {"mix.json": $mix}},
   {apiVersion: "v1", kind: "Pod", metadata: {name: $drv, namespace: $abns,
     labels: {app: "abdrive", "rbd.ab": "1", "rbd.ab.svc": $svc, "rbd.run": $run}},
    spec: {restartPolicy: "Never", automountServiceAccountToken: false, enableServiceLinks: false,
      imagePullSecrets: [{name: "ecr"}], nodeSelector: {($poolkey): "load"},
      tolerations: [{key: $poolkey, operator: "Exists"}], terminationGracePeriodSeconds: 5,
      containers: [{name: "abdrive", image: $img, imagePullPolicy: "IfNotPresent",
        command: (["sh", "-c", "/abdrive \"$@\" >/out/abdrive.log 2>&1; echo $? >/out/exit; exec sleep 7200",
                   "abdrive"] + $args),
        resources: {requests: {cpu: "1", memory: "256Mi"}, limits: {memory: "1Gi"}},
        volumeMounts: [{name: "out", mountPath: "/out"}, {name: "mix", mountPath: "/etc/abdrive", readOnly: true}]}],
      volumes: [{name: "out", emptyDir: {}}, {name: "mix", configMap: {name: $drvmix}}]}}]}
  ' >"$R/meta/driver.json" || fail "driver manifest"

stage cleanup
CREATED=1
delete_ab || fail "deleting an earlier A/B's leftovers in $NS"

stage arms
timeout 120 kubectl apply -f "$R/meta/arms.json" >&2 || fail "kubectl apply of the arms"
stage arms_ready
for x in a b; do
  timeout $((AB_READY_TIMEOUT + 30)) kubectl -n "$NS" rollout status "deployment/$SERVICE-ab-$x" \
    --timeout="${AB_READY_TIMEOUT}s" >&2 || fail "arm $x ($SERVICE-ab-$x) not Ready within ${AB_READY_TIMEOUT}s"
done

stage driver
timeout 120 kubectl apply -f "$R/meta/driver.json" >&2 || fail "kubectl apply of the driver"
timeout $((AB_READY_TIMEOUT + 30)) kubectl -n "$NS" wait --for=condition=Ready "pod/$DRV" \
  --timeout="${AB_READY_TIMEOUT}s" >&2 || fail "the $DRV pod not Ready within ${AB_READY_TIMEOUT}s"
stamp driver_running
log "abdrive: ${AB_WARMUP}s warm-up + ${AB_SECONDS}s at $RATE/s per arm"
deadline=$(( $(date +%s) + AB_WARMUP + AB_SECONDS + 300 ))
DRV_EXIT=""
while :; do
  if out=$(timeout 60 kubectl -n "$NS" exec "$DRV" -- cat /out/exit 2>/dev/null) && [[ $out =~ ^[[:space:]]*[0-9]+ ]]; then
    DRV_EXIT=${out//[^0-9]/}
    break
  fi
  (( $(date +%s) < deadline )) || fail "abdrive did not finish by its deadline ($((AB_WARMUP + AB_SECONDS + 300))s)"
  sleep "$AB_POLL"
done
stamp driver_done
timeout 300 kubectl -n "$NS" cp "$DRV:/out" "$R/driver" >&2 || fail "kubectl cp of $DRV's /out"
for f in summary.json loadgen.csv rc-a.json rc-b.json; do
  [[ -s $R/driver/$f ]] || fail "abdrive exit $DRV_EXIT and no $f (log: $(tail -n 3 "$R/driver/abdrive.log" 2>/dev/null))"
done
[[ $DRV_EXIT == 0 ]] || fail "abdrive exit $DRV_EXIT: $(jq -c '{ok, interrupted, A: .arms.A | {answered, scheduled, failed,
  errors}, B: .arms.B | {answered, scheduled, failed, errors}}' "$R/driver/summary.json")"
cp "$R/driver/rc-a.json" "$R/driver/rc-b.json" "$R/driver/loadgen.csv" "$R/" || fail "copying abdrive's outputs"
[[ $AB_LOG_BYTES == 0 || $(head -n 1 "$R/loadgen.csv") == *,bytes ]] \
  || fail "AB_LOG_BYTES=1 and abdrive wrote no bytes column to loadgen.csv"
WS=$(jq -r .window.start "$R/rc-a.json"); WE=$(jq -r .window.end "$R/rc-a.json")
SINCE_NS=$(jq -r '.first_send_unix_ns // empty' "$R/driver/summary.json")
UNTIL_NS=$(jq -r '.last_answer_unix_ns // empty' "$R/driver/summary.json")
[[ $SINCE_NS =~ ^[0-9]{18,19}$ && $UNTIL_NS =~ ^[0-9]{18,19}$ ]] \
  || fail "summary.json has no first_send_unix_ns / last_answer_unix_ns ($SINCE_NS, $UNTIL_NS)"

stage teardown
teardown
[[ $TEARDOWN == ok ]] || log "the arms' teardown failed; continuing (the next A/B deletes leftovers)"

stage traces
log "waiting ${AB_FLUSH_WAIT}s for the Collector's flushes"
sleep "$AB_FLUSH_WAIT"
# copy_traces.sh widens [SINCE, UNTIL] to [SINCE-120 s, UNTIL+60 s] itself (SPEC 5 step 4); files land in raw/traces/
"$RBD_LIB/copy_traces.sh" "$SINCE_NS" "$UNTIL_NS" "$R/raw" >"$R/copy-traces.out" \
  || fail "copy_traces.sh $SINCE_NS $UNTIL_NS failed: $(tail -n 1 "$R/copy-traces.out" 2>/dev/null)"
tail -n 1 "$R/copy-traces.out" >"$R/copy-traces.json"
[[ -n $(find "$R/raw" -type f -name '*.json*' -print -quit 2>/dev/null) ]] || fail "copy_traces.sh copied no trace file"

stage split
python3 -I "$RBD_LIB/splitarms.py" "$SERVICE" "$R/raw" "$R/raw-a" "$R/raw-b" --stats "$R/split.json" \
  2>"$R/split.err" || fail "splitarms: $(tail -n 2 "$R/split.err")"
[[ $AB_KEEP_RAW == 1 ]] || rm -rf "$R/raw"

stage check
for x in a b; do
  rc=0
  "$CLI" check "$R/raw-$x" --window "$WS,$WE" --cut entry-start --out "$R/cut-$x" --request-count "$R/rc-$x.json" \
    --json >"$R/check-$x.json" 2>"$R/check-$x.err" || rc=$?
  if [[ $x == a ]]; then CHK_A=$rc; else CHK_B=$rc; fi
  log "check $x: exit $rc $(jq -c '{verdict, counts}' "$R/check-$x.json" 2>/dev/null)"
done
[[ $CHK_A == 0 && $CHK_B == 0 ]] || fail "rhobound check: arm a exit $CHK_A ($(jq -r '.verdict // .error // "?"' \
  "$R/check-a.json" 2>/dev/null)), arm b exit $CHK_B ($(jq -r '.verdict // .error // "?"' "$R/check-b.json" 2>/dev/null))"
cp "$R/loadgen.csv" "$R/cut-a/loadgen.csv" || fail "copying loadgen.csv into cut-a"

stage diff_fit
DF_EXIT=0
"$CLI" diff-fit --baseline "$R/cut-a" --candidate "$R/cut-b" --baseline-name "$SERVICE@$BASE12" \
  --candidate-name "$SERVICE@$CAND12" --out "$R/record" --json >"$R/diff-fit.json" 2>"$R/diff-fit.err" || DF_EXIT=$?
[[ $DF_EXIT == 0 && -s $R/record/ab-record.json ]] \
  || fail "rhobound diff-fit exit $DF_EXIT: $(head -c 600 "$R/diff-fit.json") $(tail -n 2 "$R/diff-fit.err")"
log "record: $(jq -c --arg s "$SERVICE" '[.services[] | select(.service == $s)][0] | {own_ms, visits}' \
  "$R/record/ab-record.json") findings $(jq -c '[.findings[].code]' "$R/record/ab-record.json")"
stage "done"
finish 0
