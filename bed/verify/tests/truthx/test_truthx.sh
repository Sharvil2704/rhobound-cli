#!/usr/bin/env bash
# Offline tests of truthx.sh (and regress.py on its output) against stand-ins: verify/tests/stubs/kubectl first on PATH, this
# folder's maze-format capture.sh, fake rbd-env.sh / lock.sh (or part B's own). Nothing reaches a cluster or AWS.
# usage: bash test_truthx.sh   (scratch under VERIFY_SCRATCH [$RBD_SCRATCH/verify])
set -uo pipefail
unset RBD_LOAD_RPS RBD_LOAD_MIX RBD_WINDOW_S RBD_WARM_C RBD_WARM_BACK RBD_WARM_B0 RBD_LOCK_HELD
HERE=$(cd "$(dirname "$0")" && pwd)
V=$(cd "$HERE/../.." && pwd)
KIT=$(dirname "$V")
SCR=${VERIFY_SCRATCH:-${RBD_SCRATCH:-${TMPDIR:-/tmp}/rbd}/verify}
mkdir -p "$SCR"
ACCT=acct-example ECR=acct-example.registry.example.invalid/rhobound-demo/maze   # RBD_ECR holds the account, as on the bed
dg() { echo "sha256:$(printf '%s' "$1" | sha256sum | cut -d' ' -f1)"; }
BASE=$(dg base); BASE2=$(dg base2); OTHER=$(dg other)
C1=$(dg cand1); C2=$(dg cand2); C3=$(dg cand3)
SVCS="web mobile search-api checkout partner index-a index-b index-c catalog auth"
fails=0; n=0
ok() { n=$((n + 1)); echo "ok   $n $*"; }
bad() { n=$((n + 1)); fails=$((fails + 1)); echo "FAIL $n $*"; }
check() { local what=$1; shift; if "$@"; then ok "$what"; else bad "$what"; fi; }

setup() {   # setup [fallback|partb]: a fresh tools1 in $T; index-a runs BASE2, every other service BASE
  T=$(mktemp -d "$SCR/tx-XXXXXX"); EXTRA=()
  mkdir -p "$T/bin" "$T/lib" "$T/ci" "$T/home" "$T/stub"
  cp "$V/tests/stubs/kubectl" "$T/bin/kubectl"
  cp "$HERE/stubs/capture.sh" "$T/ci/capture.sh"
  chmod +x "$T/bin/kubectl" "$T/ci/capture.sh"
  case ${1:-fallback} in
    fallback)
      echo "export RBD_HOME=$T/home RBD_ECR=$ECR RBD_ACCOUNT=$ACCT KUBECONFIG=/dev/null RHOBOUND_STATE=$T/home/state" > "$T/lib/rbd-env.sh"
      echo '# part B lock.sh without rbd_lock' > "$T/lib/lock.sh" ;;
    partb)
      cp "$KIT/tools1/lib/lock.sh" "$KIT/tools1/lib/rbd-env.sh" "$T/lib/"
      printf '%s\n' RBD_REGION=example-region-1 "RBD_ACCOUNT=$ACCT" RBD_BUCKET=example-bucket "RBD_ECR=$ECR" \
        RBD_KMS=awskms:///alias/example KUBECONFIG=/dev/null "RBD_HOME=$T/home" "RHOBOUND_STATE=$T/home/state" \
        RBD_REPO=example/bed > "$T/rbd.env"
      EXTRA=(RBD_ENV_FILE="$T/rbd.env" RBD_OPT="$T/opt" STUB_REAL_LOCK=1) ;;
  esac
  local s
  for s in $SVCS; do printf '%s' "$ECR@$BASE" > "$T/stub/img-$s"; done
  printf '%s' "$ECR@$BASE2" > "$T/stub/img-index-a"
  jq -n --arg b "$BASE" --arg b2 "$BASE2" --arg r "$ECR" --arg s "$SVCS" '{schema: "rbd.baseline/v1", image_ref: $r,
    services: ([$s | splits(" ")] | map({(.): $b}) | add | .["index-a"] = $b2)}' > "$T/home/baseline.json"
  : > "$T/stub/kubectl.log"; : > "$T/stub/capture.log"
}
run() {   # run ARGS...: truthx.sh under the stand-ins; stdout -> $T/out, stderr -> $T/err, exit -> RC
  [[ $(PATH="$T/bin:$PATH" command -v kubectl) == "$T/bin/kubectl" ]] || { echo "stub kubectl not first on PATH: stop"; exit 9; }
  env PATH="$T/bin:$PATH" STUB="$T/stub" "${EXTRA[@]}" STUB_CANDS="$C1 $C2 $C3" RBD_LIB="$T/lib" RBD_CI="$T/ci" \
    RBD_WARM_C="${WARM_C:-0}" RBD_WARM_BACK=0 RBD_WARM_B0="${WARM_B0:-0}" RBD_LOCK_WAIT=1 RBD_ROLLOUT_TIMEOUT=5s \
    "$V/truthx.sh" "$@" > "$T/out" 2> "$T/err"
  RC=$?
}
sets() { grep -c ' set image ' "$T/stub/kubectl.log"; }
tj() { jq -r "$1" "$T/home/verify/truthx/$NM/truth.json"; }
img() { cat "$T/stub/img-$1"; }
last() { tail -n 1 "$T/out" | jq -r "$1"; }
RG() { python3 -I "$V/regress.py" "$@" > "$T/rg.json" 2> "$T/rg.err"; RRC=$?; }
rg() { jq -r "$1" "$T/rg.json"; }

# 1. three services, one candidate each: B0, deploy all, C, rollback all to their own baselines; 300-s windows by default
setup; NM=x1-three
STUB_SHIFT=web=5.0 run "$NM" web="$C1" search-api="$C2" index-a="$C3"
check "three services: exit 0 ($RC)" test "$RC" = 0
check "six set image (3 candidates, 3 back)" test "$(sets)" = 6
check "each candidate went to its own service" test "$(grep -c " set image deployment/web web=$ECR@$C1" "$T/stub/kubectl.log") $(grep -c " set image deployment/search-api search-api=$ECR@$C2" "$T/stub/kubectl.log") $(grep -c " set image deployment/index-a index-a=$ECR@$C3" "$T/stub/kubectl.log")" = "1 1 1"
check "each restored to ITS OWN baseline (index-a: BASE2)" test "$(img web) $(img search-api) $(img index-a)" = "$ECR@$BASE $ECR@$BASE $ECR@$BASE2"
check "RBD_WINDOW_S unset: capture.sh got 300 s windows" test "$(grep -c "^truthx-$NM-[bc0]* 300 " "$T/stub/capture.log")" = 2
check "B0 captured with production at baseline" grep -q "^truthx-$NM-b0 .* index-a=$ECR@$BASE2 .*web=$ECR@$BASE " "$T/stub/capture.log"
check "C captured with all three candidates live" \
  test "$(grep "^truthx-$NM-c " "$T/stub/capture.log" | grep -c "index-a=$ECR@$C3 .*search-api=$ECR@$C2 .*web=$ECR@$C1 ")" = 1
check "captures ran under the held lock" test "$(grep -c "held_env=truthx-$NM:[0-9]* probe=held" "$T/stub/capture.log")" = 2
check "truth.json: schema, status ok, phase complete" test "$(tj '"\(.schema) \(.status) \(.phase)"')" = "rbd.truthx/v1 ok complete"
check "truth.json: the four timestamps" \
  test "$(tj '[.times.deploy_started, .times.deploy_done, .times.c_window_start, .times.c_window_end, .times.rollback_done] | map(test("^20[0-9-]{8}T[0-9:]{8}Z$")) | all')" = true
check "truth.json: c_window {start,end} = the times" test "$(tj '.c_window.start == .times.c_window_start and .c_window.end == .times.c_window_end')" = true
check "truth.json: order b0 < deploy <= c < rollback" \
  test "$(tj '.times | .b0_start <= .deploy_started and .deploy_started <= .deploy_done and .deploy_done <= .c_window_start and .c_window_end <= .rollback_started and .rollback_started <= .rollback_done')" = true
check "truth.json: durations_s numbers" test "$(tj '.durations_s | [.deploy, .rollback, .total] | map(type == "number" and . >= 0) | all')" = true
check "truth.json: services, cand_digests, base_digests" \
  test "$(tj '.services | join(",")') $(tj '.cand_digests["search-api"]') $(tj '.base_digests["index-a"]')" = "web,search-api,index-a $C2 $BASE2"
check "truth.json: window_s 300, no drift, no warnings" test "$(tj '"\(.window_s) \(.drift_after | length) \(.warnings | length)"')" = "300 0 0"
check "b0 and c load.json copied" test -s "$T/home/verify/truthx/$NM/b0.load.json" -a -s "$T/home/verify/truthx/$NM/c.load.json"
check "last stdout line: the step JSON, ok" test "$(last '"\(.step) \(.ok) \(.status) \(.exit)"')" = "truthx true ok 0"
check "stdout holds no kubectl chatter" test "$(wc -l < "$T/out")" = 1
check "lock released after exit" flock -n "$T/home/lock" true
check "truth.json, truth.log: the account written as <account>" \
  test "$(cat "$T/home/verify/truthx/$NM/truth.json" "$T/home/verify/truthx/$NM/truth.log" | grep -c "$ACCT") $(tj .image_ref)" = "0 <account>.registry.example.invalid/rhobound-demo/maze"
RG "$T/home/verify/truthx/$NM"
check "regress on it: +5 ms at web -> regressed, exit 1 ($RRC)" test "$RRC $(rg .regressed) $(rg .worst.entry)" = "1 true web"
check "regress on it: web change about +5" test "$(rg '.entries[] | select(.entry == "web") | (.change_ms - 5 | fabs) < 0.1')" = true
check "regress on it: the other entries about 0, not over" \
  test "$(rg '[.entries[] | select(.entry != "web") | (.change_ms | fabs) < 0.1 and (.over | not)] | all')" = true
X1=$T

# 2. one service, +1 ms: production_ok; a threshold of 0.5 makes it a regression
setup; NM=x2-one
STUB_SHIFT=partner=1.0 run "$NM" partner="$C1"
check "one service: exit 0 ($RC)" test "$RC" = 0
RG "$T/home/verify/truthx/$NM"
check "regress: +1 ms -> production_ok, exit 0 ($RRC)" test "$RRC $(rg .regressed) $(rg .production_ok)" = "0 false true"
RG "$T/home/verify/truthx/$NM" --threshold 0.5
check "regress --threshold 0.5: regressed, not beyond the 2 ms noise, partner unresolved ($RRC)" \
  test "$RRC $(rg .regressed) $(rg .regressed_resolved) $(rg '.unresolved | index("partner") != null')" = "1 true false true"

# 3. the candidate answers nothing ok at checkout: regress sees errors_up, not a speed-up
setup; NM=x3-broken
STUB_BROKEN=checkout run "$NM" checkout="$C1"
RG "$T/home/verify/truthx/$NM"
check "broken entry: errors_up, not production_ok, exit 1 ($RC $RRC)" \
  test "$RC $RRC $(rg '.errors_up | join(",")') $(rg .production_ok)" = "0 1 checkout false"
check "broken entry: no change_ms for it" test "$(rg '.entries[] | select(.entry == "checkout") | .change_ms')" = null

# 4. C capture fails: every service rolled back to its own baseline, exit 1
setup; NM=x4-cfail
STUB_FAIL_ON=truthx-$NM-c run "$NM" web="$C1" index-a="$C3"
check "C fails: exit 1 ($RC)" test "$RC" = 1
check "C fails: all restored" test "$(img web) $(img index-a)" = "$ECR@$BASE $ECR@$BASE2"
check "C fails: status failed-restored, phase c_window_start" test "$(tj '"\(.status) \(.phase)"')" = "failed-restored c_window_start"
check "C fails: error names the capture" grep -q "capture.sh truthx-$NM-c" <<< "$(tj .error)"
check "C fails: rollback times recorded" test "$(tj '.times | (.rollback_on_failure != null) and (.rollback_on_failure_done != null)')" = true
check "C fails: step JSON ok=false, exit 1" test "$(last '"\(.ok) \(.exit)"')" = "false 1"

# 5. one candidate never rolls out: the deploy failed, every service set back
setup; NM=x5-rollout
STUB_ROLLOUT_FAIL=$C2 run "$NM" web="$C1" search-api="$C2"
check "rollout fails: exit 1 ($RC)" test "$RC" = 1
check "rollout fails: status failed-restored at deploy_started" test "$(tj '"\(.status) \(.phase)"')" = "failed-restored deploy_started"
check "rollout fails: both restored" test "$(img web) $(img search-api)" = "$ECR@$BASE $ECR@$BASE"
check "rollout fails: no C window" test "$(grep -c "^truthx-$NM-c " "$T/stub/capture.log")" = 0

# 6. the rollback itself fails: exit 4, loud, the manual command for each service
setup; NM=x6-noback
STUB_FAIL_ON=truthx-$NM-c STUB_ROLLOUT_FAIL=$BASE2 run "$NM" web="$C1" index-a="$C3"
check "rollback fails: exit 4 ($RC)" test "$RC" = 4
check "rollback fails: status failed-not-restored" test "$(tj .status)" = failed-not-restored
check "rollback fails: manual command for index-a with its own baseline" \
  grep -qF "set image deployment/index-a index-a=\$RBD_ECR@$BASE2" "$T/err"
check "rollback fails: and for web" grep -qF "set image deployment/web web=\$RBD_ECR@$BASE" "$T/err"
check "rollback fails: says ROLLBACK FAILED twice" test "$(grep -c "ROLLBACK FAILED" "$T/err")" = 2
check "rollback fails: no account in truth.json or truth.log" \
  test "$(cat "$T/home/verify/truthx/$NM/truth.json" "$T/home/verify/truthx/$NM/truth.log" | grep -c "$ACCT")" = 0

# 7. TERM during the warm-up: rolled back, exit 143
setup; NM=x7-term
( WARM_C=30 run "$NM" web="$C1" mobile="$C2"; echo "$RC" > "$T/rc" ) &
bgp=$!
for _ in $(seq 1 100); do
  [[ -f $T/home/verify/truthx/$NM/truth.json && $(tj .phase) == deploy_done ]] && break
  sleep 0.1
done
tpid=$(sed -n "s/.*held_env=truthx-$NM:\([0-9]*\).*/\1/p" "$T/stub/capture.log" | head -n 1)
[[ -n $tpid ]] && kill -TERM "$tpid"
wait "$bgp"
check "TERM in warm-up: exit 143 ($(cat "$T/rc"))" test "$(cat "$T/rc")" = 143
check "TERM: both restored, failed-restored" test "$(img web) $(img mobile) $(tj .status)" = "$ECR@$BASE $ECR@$BASE failed-restored"
check "TERM: error names the phase" grep -q "signal TERM in phase deploy_done" <<< "$(tj .error)"

# 8. preflight: an UNLISTED service off baseline -> refused, nothing changed
setup; NM=x8-drift0
printf '%s' "$ECR@$OTHER" > "$T/stub/img-catalog"
run "$NM" web="$C1"
check "unlisted service off baseline: exit 1, no set image, no capture ($RC)" \
  test "$RC $(sets) $(wc -l < "$T/stub/capture.log")" = "1 0 0"
check "unlisted service off baseline: message names it" grep -q "catalog runs $OTHER" "$T/err"
check "unlisted service off baseline: no output folder" test ! -e "$T/home/verify/truthx/$NM"

# 9. preflight: a candidate equal to its baseline, a service not in baseline.json
setup; NM=x9
run "$NM" web="$C1" index-a="$BASE2"
check "candidate = baseline: refused ($RC)" test "$RC $(sets)" = "1 0"
run "$NM" web="$C1" nosuch="$C2"
check "service not in baseline.json: refused ($RC)" test "$RC $(sets)" = "1 0"

# 10. usage
setup; NM=x10
run "$NM"; check "no SVC=DIGEST: usage 2 ($RC)" test "$RC" = 2
run "$NM" web; check "SVC without =DIGEST: usage 2 ($RC)" test "$RC" = 2
run "$NM" web=sha256:abc; check "bad digest: usage 2 ($RC)" test "$RC" = 2
run "$NM" web="$C1" web="$C2"; check "a service twice: usage 2 ($RC)" test "$RC" = 2
run Bad_Name web="$C1"; check "bad NAME: usage 2 ($RC)" test "$RC" = 2
run "$NM" Web="$C1"; check "bad service name: usage 2 ($RC)" test "$RC" = 2
a=(); for i in $(seq 1 33); do a+=("s$i=$C1"); done
run "$NM" "${a[@]}"; check "33 services: usage 2 ($RC)" test "$RC" = 2
check "usage: nothing done" test "$(sets) $(wc -l < "$T/stub/capture.log")" = "0 0"

# 11. --check, the lock busy, a name used before
T=$X1; EXTRA=(); NM=x1-three
: > "$T/stub/kubectl.log"
run x11-check web="$C1" --check
check "--check: exit 0, no set image, no folder ($RC)" test "$RC $(sets)" = "0 0" -a ! -e "$T/home/verify/truthx/x11-check"
run "$NM" web="$C1"
check "same NAME again: refused ($RC)" test "$RC" = 1
check "same NAME again: message" grep -q "exists: re-run under a new NAME" "$T/err"
flock "$T/home/lock" sleep 20 &
holder=$!; sleep 0.3
run x11-check web="$C1" --check
check "--check with the lock held: exit 1 ($RC)" test "$RC" = 1
run x11-busy web="$C1"
check "lock busy: exit 1, no set image, no folder ($RC)" test "$RC $(sets)" = "1 0" -a ! -e "$T/home/verify/truthx/x11-busy"
kill "$holder" 2> /dev/null; wait "$holder" 2> /dev/null

# 12. six services (more than truth.sh's 5), and B0 settle with no readable job start time
setup; NM=x12-six
WARM_B0=1 run "$NM" web="$C1" mobile="$C1" search-api="$C1" checkout="$C1" partner="$C1" index-b="$C2"
check "six services: exit 0, 12 set image ($RC)" test "$RC $(sets)" = "0 12"
check "six services: all back on baseline" test "$(for s in web mobile search-api checkout partner index-b; do img "$s"; echo; done | sort -u)" = "$ECR@$BASE"
check "B0 settle: no job start time -> waits RBD_WARM_B0 and warns" \
  test "$(tj '"\(.b0_settle_s) \(.warnings | map(select(test("start time not found"))) | length)"')" = "1 1"

# 13. a service drifts during the run (not the verifier's doing): recorded after the rollback, status stays ok
setup; NM=x13-drift
STUB_DRIFT_ON="truthx-$NM-c:auth:$ECR@$OTHER" run "$NM" web="$C1"
check "drift: exit 0, status ok ($RC)" test "$RC $(tj .status)" = "0 ok"
check "drift: drift_after names auth" test "$(tj '.drift_after | map(select(startswith("auth runs"))) | length')" = 1
check "drift: a warning" test "$(tj '.warnings | map(select(test("not at baseline"))) | length')" = 1
check "drift: the image in it is redacted" test "$(tj '.drift_after[0]')" = "auth runs <account>.registry.example.invalid/rhobound-demo/maze@$OTHER (baseline $BASE)"

# 14. RBD_WINDOW_S is honoured
setup; NM=x14-win
RBD_WINDOW_S=45 run "$NM" web="$C1"
check "RBD_WINDOW_S=45: windows of 45 s ($RC)" test "$RC $(grep -c "^truthx-$NM-[bc0]* 45 " "$T/stub/capture.log") $(tj .window_s)" = "0 2 45"

# 15. part B's own lock.sh + rbd-env.sh: captures nested under truthx's lock
if [[ -r $KIT/tools1/lib/lock.sh && -r $KIT/tools1/lib/rbd-env.sh ]]; then
  setup partb; NM=x15-partb
  run "$NM" web="$C1" search-api="$C2"
  check "part B lock.sh: exit 0, status ok ($RC)" test "$RC $(tj .status)" = "0 ok"
  check "part B lock.sh: both captures nested (probe refused)" test "$(grep -c "held_env=[0-9][0-9]* probe=held" "$T/stub/capture.log")" = 2
  check "part B lock.sh: restored" test "$(img web) $(img search-api)" = "$ECR@$BASE $ECR@$BASE"
else
  echo "skip: part B's tools1/lib/lock.sh or rbd-env.sh not present"
fi

echo "$((n - fails))/$n passed"
if ((fails == 0)) && [[ -z ${VERIFY_KEEP:-} ]]; then rm -rf "$SCR"/tx-*; fi
((fails == 0))
