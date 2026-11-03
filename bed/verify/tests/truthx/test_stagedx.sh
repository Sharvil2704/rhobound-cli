#!/usr/bin/env bash
# Offline tests of stagedx.sh (experiment 2b part 3: a staged rollout, one service per stage) against truthx's stand-ins:
# verify/tests/stubs/kubectl first on PATH, this folder's capture.sh (it logs every deployment's image at each capture).
# usage: bash test_stagedx.sh   (scratch under VERIFY_SCRATCH [$RBD_SCRATCH/verify])
# shellcheck disable=SC2034,SC2119,SC2120  # truthx's test helpers, copied whole: OTHER and setup's partb mode go unused here
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
run() {   # run ARGS...: stagedx.sh under the stand-ins; stdout -> $T/out, stderr -> $T/err, exit -> RC
  [[ $(PATH="$T/bin:$PATH" command -v kubectl) == "$T/bin/kubectl" ]] || { echo "stub kubectl not first on PATH: stop"; exit 9; }
  env PATH="$T/bin:$PATH" STUB="$T/stub" "${EXTRA[@]}" STUB_CANDS="$C1 $C2 $C3" RBD_LIB="$T/lib" RBD_CI="$T/ci" \
    RBD_WARM_C="${WARM_C:-0}" RBD_WARM_BACK=0 RBD_WARM_B0="${WARM_B0:-0}" RBD_LOCK_WAIT=1 RBD_ROLLOUT_TIMEOUT=5s \
    "$V/stagedx.sh" "$@" > "$T/out" 2> "$T/err"
  RC=$?
}
sets() { grep -c ' set image ' "$T/stub/kubectl.log"; }
tj() { jq -r "$1" "$T/home/verify/stagedx/$NM/truth.json"; }
img() { cat "$T/stub/img-$1"; }
last() { tail -n 1 "$T/out" | jq -r "$1"; }
RG() { python3 -I "$V/regress.py" "$@" > "$T/rg.json" 2> "$T/rg.err"; RRC=$?; }
rg() { jq -r "$1" "$T/rg.json"; }


D() { echo "$T/home/verify/stagedx/$NM"; }
cap() { grep "^stagedx-$NM-$1 " "$T/stub/capture.log"; }

# 1. three stages in the order given: B0 at baseline, then web, web+search-api, all three; rollback to each one's baseline
setup; NM=s1-three
STUB_SHIFT=web=5.0 run "$NM" web="$C1" search-api="$C2" index-a="$C3"
check "three stages: exit 0 ($RC)" test "$RC" = 0
check "captures in order b0 c1 c2 c3" test "$(cut -d' ' -f1 "$T/stub/capture.log" | xargs)" = "stagedx-$NM-b0 stagedx-$NM-c1 stagedx-$NM-c2 stagedx-$NM-c3"
check "B0 at baseline" grep -q "index-a=$ECR@$BASE2 .*search-api=$ECR@$BASE .*web=$ECR@$BASE " <<< "$(cap b0)"
check "c1: web only" grep -q "index-a=$ECR@$BASE2 .*search-api=$ECR@$BASE .*web=$ECR@$C1 " <<< "$(cap c1)"
check "c2: web and search-api (stage 1 stays)" grep -q "index-a=$ECR@$BASE2 .*search-api=$ECR@$C2 .*web=$ECR@$C1 " <<< "$(cap c2)"
check "c3: all three" grep -q "index-a=$ECR@$C3 .*search-api=$ECR@$C2 .*web=$ECR@$C1 " <<< "$(cap c3)"
check "six set image (3 stages, 3 back)" test "$(sets)" = 6
check "each restored to ITS OWN baseline (index-a: BASE2)" test "$(img web) $(img search-api) $(img index-a)" = "$ECR@$BASE $ECR@$BASE $ECR@$BASE2"
check "300-s windows, all under the held lock" test "$(grep -c "^stagedx-$NM-[bc0-9]* 300 .* held_env=stagedx-$NM:[0-9]* probe=held" "$T/stub/capture.log")" = 4
check "truth.json: schema, status ok, phase complete" test "$(tj '"\(.schema) \(.status) \(.phase)"')" = "rbd.stagedx/v1 ok complete"
check "truth.json: stages in order with distinct seeds" \
  test "$(tj '[.stages[] | "\(.k):\(.service)"] | join(" ")') $(tj '[.stages[].seed] + [.seeds.b0] | unique | length')" = "1:web 2:search-api 3:index-a 4"
check "truth.json: stage times ordered" \
  test "$(tj '.times | .b0_end <= .s1_deploy_started and .s1_deploy_done <= .s1_c_start and .s1_c_end <= .s2_deploy_started and .s2_c_end <= .s3_deploy_started and .s3_deploy_done <= .s3_c_start and .s3_c_end <= .rollback_started')" = true
check "b0 and c1..c3 load.json copied" test -s "$(D)/b0.load.json" -a -s "$(D)/c1.load.json" -a -s "$(D)/c2.load.json" -a -s "$(D)/c3.load.json"
check "last stdout line: the step JSON, ok" test "$(last '"\(.step) \(.ok) \(.status) \(.exit)"')" = "stagedx true ok 0"
check "lock released after exit" flock -n "$T/home/lock" true
RG --b0 "$(D)/b0.load.json" --c "$(D)/c1.load.json"
check "regress b0 vs c1: +5 ms at web -> regressed ($RRC)" test "$RRC $(rg .regressed) $(rg .worst.entry)" = "1 true web"

# 2. the second stage's window fails: every listed service rolled back, exit 1
setup; NM=s2-fail
STUB_FAIL_ON=stagedx-$NM-c2 run "$NM" web="$C1" index-a="$C3"
check "c2 fails: exit 1 ($RC)" test "$RC" = 1
check "c2 fails: all restored" test "$(img web) $(img index-a)" = "$ECR@$BASE $ECR@$BASE2"
check "c2 fails: status failed-restored, phase s2_c_start" test "$(tj '"\(.status) \(.phase)"')" = "failed-restored s2_c_start"
check "c2 fails: last line names the step" test "$(last '"\(.step) \(.ok) \(.exit)"')" = "stagedx false 1"

# 3. --check changes nothing; a candidate at its baseline digest is refused before anything is set
setup; NM=s3-check
run "$NM" web="$C1" search-api="$C2" --check
check "--check: exit 0, nothing set, no capture ($RC)" test "$RC $(sets) $(wc -l < "$T/stub/capture.log")" = "0 0 0"
setup; NM=s4-same
run "$NM" web="$C1" index-a="$BASE2"
check "candidate = baseline: refused, nothing set ($RC)" test "$RC $(sets)" = "1 0"

echo "stagedx tests: $((n - fails))/$n passed"
((fails == 0))
