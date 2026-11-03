#!/usr/bin/env bash
# capture.sh NAME SECONDS SEED   one production window (SPEC 3, SPEC 0b rules 1-2) -> $RBD_HOME/captures/NAME/
#   raw/traces/          the Collector files covering the window (raw/ holds nothing else: the folder the CLI reads)
#   request-count.json   rhobound.request-count/v1 from the load's own log: window S = the "maze-load: N requests over" line, E = S + SECONDS
#   cut/                 rhobound check raw --window S,E --cut entry-start --out cut --request-count request-count.json
#   meta/                load.json (the Job's log, then one rbd.load/v1 line: the load setting the window ran at), load-job.json,
#                        k8s.json, capture.json (its "load": the same setting), check.json (+ .err) -- never inside raw/ or cut/
# Under the cluster lock. The background load is stopped for the window and started again at the end, also on failure.
# The load (SPEC3 F6a): the window runs at the load setting, $RBD_HOME/load.env read through loadmix.py (load.sh set|reset|show;
#   no file = spec.json's 100 rps and mix, the window Job exactly as before), read once under the lock before anything is
#   touched (a refused setting: exit 1, the background load untouched); bgload.sh start, in the trap, reads the same file
#   under the same lock, so the background load comes back at the window's setting, not the default. The Job's log must
#   echo the setting's rate ("(R rps)"), else the capture fails (kept as NAME.failed-*, its load.json recorded).
# A failed capture is kept as NAME.failed-<epoch> (NAME can be used again). Last line {"step":"capture","ok":...}; exit 0 / 1.
# shellcheck disable=SC2015
set -uo pipefail
RBD_OPT=${RBD_OPT:-/opt/rbd}
# shellcheck source=../lib/rbd-env.sh
. "$RBD_OPT/lib/rbd-env.sh"
# shellcheck source=../lib/lock.sh
. "$RBD_OPT/lib/lock.sh"
export RBD_STEP=capture
NAME=${1:-} SECS=${2:-} SEED=${3:-}
FLUSH_S=${RBD_FLUSH_S:-20}

fail() {
  log "ERROR: $1"
  [ -n "${WORK:-}" ] && [ -d "$WORK" ] && FAILED="$RBD_HOME/captures/$NAME.failed-$(date +%s)" && mv "$WORK" "$FAILED" && log "kept as $FAILED"
  rbd_result capture false "$(jq -cn --arg n "$NAME" --arg e "$1" --arg d "${FAILED:-}" '{name: $n, error: $e, kept: $d}')"
  exit 1
}
[ $# = 3 ] && [[ $NAME =~ ^[a-z0-9][a-z0-9._-]{0,62}$ && $SECS =~ ^[0-9]+$ && $SEED =~ ^[0-9]{1,9}$ ]] \
  || { echo "usage: capture.sh NAME SECONDS SEED   (NAME [a-z0-9._-], SECONDS 30..3600)" >&2; rbd_result capture false '{"error":"usage"}'; exit 1; }
[ "$SECS" -ge 30 ] && [ "$SECS" -le 3600 ] || fail "SECONDS must be 30..3600"
OUT=$RBD_HOME/captures/$NAME
[ ! -e "$OUT" ] || fail "$OUT exists"
need_cmd kubectl jq python3
[ -x "$RBD_CLI" ] || fail "no rhobound CLI at $RBD_CLI"
LOAD_IMAGE=$(images_get load) || fail "no load image"
rbd_lock "${RBD_LOCK_WAIT:-3600}" || fail "the cluster lock is busy"
# the load setting, once (the trap's bgload.sh start reads the same file under this lock); its reason is the error when refused
LOADSET=$(python3 -I "$RBD_OPT/maze/loadmix.py" show "$RBD_HOME/load.env" 2>&1) && jq -e '.schema == "rbd.load/v1"' <<< "$LOADSET" > /dev/null 2>&1 \
  || fail "the load setting is refused: ${LOADSET#loadmix: }"
LOADARGS=()
[ "$(jq -r .source <<< "$LOADSET")" = default ] || LOADARGS=(--rps "$(jq -r .rps <<< "$LOADSET")" --mix-weights "$(jq -r .mix <<< "$LOADSET")")

WORK=$RBD_HOME/captures/.$NAME.tmp
rm -rf "$WORK"; mkdir -p "$WORK/raw/traces" "$WORK/meta" || fail "cannot create $WORK"
STOPPED=""
restart_bg() { if [ -n "$STOPPED" ] && [ -z "${RBD_KEEP_BGLOAD_STOPPED:-}" ]; then "$RBD_OPT/maze/bgload.sh" start || log "WARNING: the background load did not start again"; fi; }
trap restart_bg EXIT
started_at=$(now_utc)

log "$NAME: stopping the background load"
"$RBD_OPT/maze/bgload.sh" stop || fail "could not stop the background load"
STOPPED=1
sleep "${RBD_SETTLE_S:-5}"
kubectl -n "$RBD_NS" delete job maze-load --ignore-not-found --wait=true --timeout=120s > /dev/null || fail "could not delete the old maze-load Job"
python3 -I "$RBD_OPT/maze/render.py" load --load-image "$LOAD_IMAGE" --name maze-load --seconds "$SECS" --seed "$SEED" "${LOADARGS[@]}" \
  > "$WORK/meta/load-job.json" || fail "render.py load failed"
kubectl apply -f "$WORK/meta/load-job.json" > /dev/null || fail "could not create the maze-load Job"
log "$NAME: window Job running for $SECS s (seed $SEED; $(jq -r .summary <<< "$LOADSET"))"
deadline=$(( $(date +%s) + SECS + 300 ))
while :; do
  # "/" keeps the fields apart: with a space, read drops the leading blank of " 1" (failed, never succeeded) and sees succ=1
  st=$(kubectl -n "$RBD_NS" get job maze-load -o jsonpath='{.status.succeeded}/{.status.failed}' 2> /dev/null) || st="?/?"
  IFS=/ read -r succ failed <<< "$st"
  [ "${succ:-}" = 1 ] && break
  [ -n "${failed:-}" ] && [ "$failed" != "?" ] && [ "$failed" -ge 1 ] && fail "the maze-load Job failed (kubectl -n $RBD_NS logs job/maze-load)"
  [ "$(date +%s)" -lt "$deadline" ] || fail "the maze-load Job did not finish within $((SECS + 300)) s"
  if [ "$(date +%s)" -gt "$((deadline - SECS - 210))" ]; then   # 90 s after the start: a pod still Pending will not run (image pull?)
    ph=$(kubectl -n "$RBD_NS" get pods -l job-name=maze-load -o jsonpath='{.items[0].status.phase} {.items[0].status.containerStatuses[0].state.waiting.reason}' 2> /dev/null || true)
    [[ $ph != Pending* ]] || fail "the maze-load pod is still $ph after 90 s (kubectl -n $RBD_NS describe pod -l job-name=maze-load)"
  fi
  sleep "${RBD_POLL_S:-10}"
done
kubectl -n "$RBD_NS" logs job/maze-load > "$WORK/meta/load.json" || fail "could not read the Job's log"
# the setting the window ran at, as load.json's last line (verify copies only load.json); no "url" key: loadlog, score.py, load_ok skip it
tl=$(tail -c 1 "$WORK/meta/load.json")   # not empty: the log does not end in a newline
{ [ -z "$tl" ] || echo; jq -c . <<< "$LOADSET"; } >> "$WORK/meta/load.json" || fail "could not record the load setting in load.json"
win=$(python3 -I "$RBD_OPT/maze/loadlog.py" "$WORK/meta/load.json" --seconds "$SECS" --out "$WORK/request-count.json") || fail "the load log is not one finished window"
S=$(jq -r .start <<< "$win") E=$(jq -r .end <<< "$win")
jq -e --argjson s "$LOADSET" '.rps == $s.rps' <<< "$win" > /dev/null \
  || fail "the window ran at $(jq -r .rps <<< "$win") rps (the Job's log), the load setting is $(jq -r .rps <<< "$LOADSET") rps"
log "$NAME: window $S .. $E ($(jq -c .entries <<< "$win")); waiting ${FLUSH_S} s for the exporters to flush"
sleep "$FLUSH_S"

copied=$("$RBD_OPT/lib/copy_traces.sh" "$(jq -r .since_ns <<< "$win")" "$(jq -r .until_ns <<< "$win")" "$WORK/raw" | tail -n 1) || fail "copying the Collector files failed"
kubectl -n "$RBD_NS" get deploy,svc,pods -o json > "$WORK/meta/k8s.json" || log "WARNING: no k8s.json"

log "$NAME: rhobound check --window $S,$E --cut entry-start"
"$RBD_CLI" check "$WORK/raw" --window "$S,$E" --cut entry-start --out "$WORK/cut" --request-count "$WORK/request-count.json" --json \
  > "$WORK/meta/check.json" 2> "$WORK/meta/check.err"
crc=$?
verdict=$(jq -r '.verdict // "?"' "$WORK/meta/check.json" 2> /dev/null) manifest=$(jq -r '.manifest_sha256 // ""' "$WORK/meta/check.json" 2> /dev/null)
jq -n --arg name "$NAME" --argjson secs "$SECS" --argjson seed "$SEED" --argjson win "$win" --arg img "$LOAD_IMAGE" \
  --arg started "$started_at" --arg finished "$(now_utc)" --argjson copied "${copied:-null}" --argjson crc "$crc" \
  --arg verdict "$verdict" --arg manifest "$manifest" --arg cli "$("$RBD_CLI" version 2> /dev/null)" \
  --argjson services "$(jq -c '.services // {}' "$RBD_HOME/baseline.json" 2> /dev/null || echo '{}')" --argjson load "$LOADSET" \
  '{schema: "rbd.capture/v1", name: $name, seconds: $secs, seed: $seed, rps: $win.rps, window: {start: $win.start, end: $win.end},
    requests: $win.entries, load: $load, load_image: $img, baseline_services: $services, started_at: $started, finished_at: $finished,
    traces: $copied, check: {exit: $crc, verdict: $verdict, manifest_sha256: $manifest}, cli: $cli}' > "$WORK/meta/capture.json"
case $crc in
  0) ;;
  4) fail "rhobound check refused the window ($(jq -c '.counts // {}' "$WORK/meta/check.json" 2> /dev/null)); see meta/check.json" ;;
  *) fail "rhobound check failed (exit $crc): $(head -c 300 "$WORK/meta/check.err")" ;;
esac
[ -s "$WORK/cut/manifest.json" ] || fail "check admitted the window but wrote no cut/manifest.json"
mv "$WORK" "$OUT" || fail "cannot move $WORK to $OUT"
WORK=""
log "$NAME: $verdict, manifest $manifest -> $OUT"
rbd_result capture true "$(jq -cn --arg n "$NAME" --arg d "$OUT" --arg s "$S" --arg e "$E" --arg v "$verdict" --arg m "$manifest" \
  --argjson c "$(jq -c '{copied, bytes}' <<< "${copied:-null}" 2> /dev/null || echo null)" --arg l "$(jq -r .summary <<< "$LOADSET")" \
  '{name: $n, dir: $d, window: {start: $s, end: $e}, verdict: $v, manifest_sha256: $m, traces: $c, load: $l}')"
