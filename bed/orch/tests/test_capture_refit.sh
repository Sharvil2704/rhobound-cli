#!/usr/bin/env bash
# test_capture_refit.sh: capture.sh and refit.sh end to end, offline: the kubectl stub plays the cluster (the window Job's log is the
# real rs2 load.json; spans-reader's files are the real rs2 capture, decompressed and split into a rotated file + the open file
# with an unfinished line, beside an old junk file that must not be copied), the CLI is the real one (build/rhobound-arm64).
# Checks the window and request count (SPEC 0b rule 2, equal to the proof's), check --window --cut with the real CLI, the layout
# (rule 1), the background load stopped and started again, failures (busy lock, a window with no spans, a name used twice, a
# failed window Job), then
# refit: fit --name prod, baseline.json, the rhobound-mcp registration, and the refusal when production runs other images.
# Heavy (570 MB of spans): run it through capped.sh, e.g. RB_MEM_MAX=4G bash .../capped.sh bash orch/tests/test_capture_refit.sh
# shellcheck disable=SC1090,SC1091,SC2012,SC2015,SC2016,SC2088,SC2155  # test code
set -uo pipefail
# shellcheck source=lib.sh
. "$(dirname "$(readlink -f "$0")")/lib.sh"
mk_env
RS2=$HOME/rbd-dev/capture
PROOF=$HOME/rbd-dev/leaf
ECR=123456789012.dkr.ecr.ap-south-1.amazonaws.com/rhobound-demo/kshop
export RBD_SETTLE_S=0 RBD_FLUSH_S=0 RBD_POLL_S=0 RBD_LOCK_WAIT=5
dg() { printf 'sha256:%064d' "$1"; }
D=$T/data; mkdir -p "$D"; export FAKE_DATA=$D FAKE_LOAD_JSON=$RS2/load.json FAKE_K8S_JSON=$T/k8s.json
echo "  (decompressing the rs2 capture)"
zcat "$RS2/traces/spans.jsonl.gz" > "$T/all.jsonl"
n=$(wc -l < "$T/all.jsonl")
head -n $((n - 1)) "$T/all.jsonl" > "$D/spans-2026-10-22T05-22-50.000.jsonl"; touch -d 2026-10-22T05:22:50Z "$D/spans-2026-10-22T05-22-50.000.jsonl"
{ tail -n 1 "$T/all.jsonl"; printf '{"resourceSpans":[{"resource":'; } > "$D/spans.jsonl"; touch -d 2026-10-22T05:23:30Z "$D/spans.jsonl"
rm -f "$T/all.jsonl"
echo 'not json at all' > "$D/spans-2026-10-22T03-00-00.000.jsonl"; touch -d 2026-10-22T03:00:00Z "$D/spans-2026-10-22T03-00-00.000.jsonl"
svcs=$(jq -r '.services | keys[]' "$DEMO/tools1/kshop/spec.json")
i=0; for s in $svcs; do i=$((i + 1)); printf '%s\t%s\n' "$s" "$(dg "$i")"; done | jq -Rn '[inputs | split("\t") | {key: .[0], value: .[1]}] | from_entries' > "$T/svc.json"
jq -n --arg r "$ECR" --slurpfile s "$T/svc.json" '{schema: "rbd.baseline/v1", services: $s[0], image_ref: $r, fit: null, capture: null}' > "$T/home/baseline.json"
jq -n --arg r "$ECR" --arg l "$ECR@$(dg 99)" '{schema: "rbd.images/v1", load: $l, collector: ($r + "@" + ("sha256:" + "1" * 64)), busybox: ($r + "@" + ("sha256:" + "2" * 64))}' > "$T/home/images.json"
mk_k8s() { jq --arg r "$ECR" '{kind: "List", items: [to_entries[] | {kind: "Deployment", metadata: {name: .key}, spec: {template: {spec: {containers: [{name: .key, image: ($r + "@" + .value)}]}}}}]}' "$1" > "$FAKE_K8S_JSON"; }
mk_k8s "$T/svc.json"
CAP=$DEMO/tools1/ci/capture.sh REFIT=$DEMO/tools1/ci/refit.sh

echo "-- capture.sh c1 600 7"
t0=$(date +%s)
out=$(bash "$CAP" c1 600 7 2> "$T/c1.err"); rc=$?
echo "  (capture took $(( $(date +%s) - t0 )) s)"
last=$(tail -n 1 <<< "$out")
check "capture exit 0 (rc $rc)" [ $rc = 0 ] || { tail -20 "$T/c1.err"; }
check "last line: step capture ok" [ "$(jq -r '"\(.step) \(.ok)"' <<< "$last")" = "capture true" ]
check "window from the load log: 05:12:45 .. 05:22:45" [ "$(jq -r '"\(.window.start) \(.window.end)"' <<< "$last")" = "2026-10-22T05:12:45Z 2026-10-22T05:22:45Z" ]
C=$T/home/captures/c1
check "request-count.json is the proof's (SPEC 0b)" [ "$(jq -cS . "$C/request-count.json")" = "$(jq -cS . "$PROOF/pc/request-count.json")" ]
check "raw/ holds only traces/ (rule 1)" [ "$(ls "$C/raw")" = traces ]
check "raw/traces: the rotated file and the open one, not the old junk" [ "$(ls "$C/raw/traces" | tr '\n' ' ')" = "spans-2026-10-22T05-22-50.000.jsonl spans.jsonl " ]
check "the open file's unfinished line was cut" [ "$(wc -l < "$C/raw/traces/spans.jsonl")" = 1 ] && jq -e . "$C/raw/traces/spans.jsonl" > /dev/null
check "meta/ holds load.json k8s.json capture.json check.json" bash -c "cd '$C/meta' && ls load.json k8s.json capture.json check.json > /dev/null"
nl=$(wc -l < "$RS2/load.json")
check "load.json = the Job's log, then one rbd.load/v1 line (SPEC3 F6a: no load.env, the default 100 rps)" bash -c "[ \$(wc -l < '$C/meta/load.json') = $((nl + 1)) ] && head -n $nl '$C/meta/load.json' | cmp -s - '$RS2/load.json' && tail -n 1 '$C/meta/load.json' | jq -e '.schema == \"rbd.load/v1\" and .source == \"default\" and .rps == 100' > /dev/null"
check "capture.json records the same load" [ "$(jq -cS .load "$C/meta/capture.json")" = "$(tail -n 1 "$C/meta/load.json" | jq -cS .)" ]
v=$(jq -r .verdict "$C/meta/check.json")
check "check admitted the cut ($v; $(jq -c .counts "$C/meta/check.json"))" bash -c "[ '$v' = admitted ] || [ '$v' = admitted-with-doubts ]"
check "the cut was checked WITH the count (kept share counted)" [ "$(jq -r .kept_share.source "$C/meta/check.json")" = counted ]
check "no refusal-level finding" [ "$(jq '[.findings[]? | select(.level == "refuse" or .level == "refused")] | length' "$C/meta/check.json")" = 0 ]
check "cut/ holds manifest.json, request-count.json, traces/" bash -c "cd '$C/cut' && ls manifest.json request-count.json traces > /dev/null"
check "the cut's request-count.json is the window's" cmp -s "$C/cut/request-count.json" "$C/request-count.json"
check "capture.json records window, seed and check" [ "$(jq -r '"\(.window.start) \(.seed) \(.check.exit) \(.check.manifest_sha256 | startswith("sha256:"))"' "$C/meta/capture.json")" = "2026-10-22T05:12:45Z 7 0 true" ]
check "the window Job: kshop-load, 600 s, seed 7, the load image by digest" [ "$(jq -r '[.metadata.name, (.spec.template.spec.containers[0].env[] | select(.name == "LOAD_SECONDS" or .name == "LOAD_SEED") | .value), .spec.template.spec.containers[0].image] | join(" ")' "$C/meta/load-job.json")" = "kshop-load 600.0 7 $ECR@$(dg 99)" ]
order=$(grep -n -E 'delete job kshop-bgload|apply -f .*load-job.json|logs job/kshop-load|exec spans-reader -c reader -- tar|apply -f -$' "$STUB_LOG" | cut -d: -f2- | sed -E 's/^kubectl (-n [a-z-]+ )?//; s/ --.*//; s#-f /.*load-job.json#-f load-job#')
check "order: bgload stopped, window Job, its log, the copy, bgload started again ($(tr '\n' '|' <<< "$order"))" [ "$(tr '\n' '|' <<< "$order")" = "delete job kshop-bgload|apply -f load-job|logs job/kshop-load|exec spans-reader -c reader|delete job kshop-bgload|apply -f -|" ]
bgjob=$(grep -l '"kshop-bgload"' "$STUB_DIR"/apply.* 2> /dev/null | tail -n 1)
check "the background load started again as kshop-bgload" [ -n "$bgjob" ]
check "the lock is free afterwards" [ "$( (. "$DEMO/tools1/lib/lock.sh"; RBD_LOCK_FILE=$T/home/lock rbd_lock_holder) )" = free ]

echo "-- failures"
out=$(bash "$CAP" c1 600 7 2> /dev/null); check "the same NAME again is refused (exit 1)" [ $? = 1 ] && check "...with a JSON line" [ "$(tail -n 1 <<< "$out" | jq -r .ok)" = false ]
( . "$DEMO/tools1/lib/lock.sh"; RBD_LOCK_FILE=$T/home/lock rbd_lock 5 other-job; sleep 8 ) & hp=$!; sleep 1
: > "$STUB_LOG"
RBD_LOCK_WAIT=2 bash "$CAP" c2 600 7 > /dev/null 2> "$T/c2.err"; rc=$?
check "lock held by another job: refused (exit 1)" [ $rc = 1 ] && check "...naming it" grep -q other-job "$T/c2.err"
check "...without touching the background load" bash -c "! grep -q 'kshop-bgload' '$STUB_LOG'"
wait $hp
sed 's#^2026/10/22 05:12:45#2026/10/22 07:12:45#' "$RS2/load.json" > "$T/late.json"
: > "$STUB_LOG"
FAKE_LOAD_JSON=$T/late.json bash "$CAP" c3 600 7 > "$T/c3.out" 2> "$T/c3.err"; rc=$?
check "a window with no spans in it fails (exit $rc)" [ $rc = 1 ]
check "...kept as c3.failed-*" bash -c "ls -d '$T'/home/captures/c3.failed-* > /dev/null 2>&1 && [ ! -e '$T/home/captures/c3' ]"
check "...and the background load was started again" grep -q "kshop-bgload" "$STUB_LOG"
: > "$STUB_LOG"
STUB_LOAD_STATUS=/1 bash "$CAP" c4 600 7 > "$T/c4.out" 2> "$T/c4.err"; rc=$?
check "a FAILED window Job (succeeded unset, failed 1) is reported as failed (exit $rc)" [ $rc = 1 ] && check "...as the Job failing, not as a bad load log" bash -c "grep -q 'the kshop-load Job failed' '$T/c4.err' && ! grep -q 'not one finished window' '$T/c4.err'"
check "...its log was never read as a window" bash -c "! grep -q 'logs job/kshop-load' '$STUB_LOG'"
check "...kept as c4.failed-*, the background load started again" bash -c "ls -d '$T'/home/captures/c4.failed-* > /dev/null 2>&1 && grep -q 'kshop-bgload' '$STUB_LOG'"
rm -rf "$T"/home/captures/c3.failed-* "$T"/home/captures/c4.failed-* "$C/raw"

echo "-- refit.sh"
mkdir -p "$T/home/mcp/state"
t0=$(date +%s)
out=$(bash "$REFIT" prod-a 2> "$T/r1.err"); rc=$?
echo "  (refit took $(( $(date +%s) - t0 )) s)"
last=$(tail -n 1 <<< "$out")
check "refit exit 0 (rc $rc)" [ $rc = 0 ] || tail -20 "$T/r1.err"
R=$T/home/captures/prod-a
fd="sha256:$(sha256sum "$R/fit/fit.json" | cut -d' ' -f1)"
check "fit digest = sha256 of fit.json, printed by fit and refit" [ "$(jq -r .fit_digest <<< "$last")" = "$fd" ] && [ "$(jq -r .fit_digest "$R/meta/fit.json")" = "$fd" ]
check "baseline.json: fit {dir, digest}, capture prod-a, services kept" [ "$(jq -r '"\(.fit.dir) \(.fit.digest) \(.capture) \(.services | length)"' "$T/home/baseline.json")" = "$R/fit $fd prod-a 10" ]
check "the fit is named prod (--name prod)" grep -q '"prod"' "$R/fit/fit.json"
check "the fit's manifest is the cut's (fit --manifest cut/manifest.json)" grep -q "$(jq -r .manifest_sha256 "$R/meta/check.json" | cut -d: -f2)" "$R/fit/fit.json"
check "rhobound-mcp: baselines/prod.json names the fit" [ "$(cat "$T/home/mcp/state/server/baselines/prod.json")" = "{\"fit\":\"$fd\"}" ]
check "rhobound-mcp: artifacts/<hex> holds the fit's bytes (0600)" bash -c "cmp -s '$R/fit/fit.json' '$T/home/mcp/state/server/artifacts/${fd#sha256:}' && [ \"\$(stat -c %a '$T/home/mcp/state/server/artifacts/${fd#sha256:}')\" = 600 ]"
check "the seed came from the name" [ "$(jq -r .seed "$R/meta/capture.json")" = "$(( 16#$(printf prod-a | sha256sum | cut -c1-7) % 1000000 + 1 ))" ]
rm -rf "$R/raw"
cp "$T/home/baseline.json" "$T/bl.before"
jq '.auth = "sha256:'"$(printf '%064d' 7777)"'"' "$T/svc.json" > "$T/svc2.json"; mk_k8s "$T/svc2.json"
out=$(bash "$REFIT" prod-b 2> "$T/r2.err"); rc=$?
tail -n 1 <<< "$out" | jq -r .error > "$T/r2.json.err"
check "production runs another auth image: refit refused (exit $rc)" [ $rc = 1 ] && check "...naming auth ($(cat "$T/r2.json.err"))" grep -q "^production does not run baseline.json.s images: auth: " "$T/r2.json.err"
check "...and baseline.json is unchanged" cmp -s "$T/home/baseline.json" "$T/bl.before"
rm -rf "$T/home/captures/prod-b/raw" "$D"
finish
