#!/usr/bin/env bash
# Offline tests of truth.sh, aa.sh, collect.sh (and score.py --bundle on their output) against stubs: a fake kubectl first on
# PATH, a fake capture.sh (tests/stubs), fake rbd-env.sh / lock.sh. Nothing reaches a cluster or AWS. usage: bash test_truth.sh
set -uo pipefail
unset RBD_LOAD_RPS RBD_LOAD_MIX   # part B's load setting (SPEC3 F6a) never from the caller's shell: its readers refuse a stray one
HERE=$(cd "$(dirname "$0")" && pwd)
V=$(dirname "$HERE")
KIT=$(dirname "$V")
SCR=${VERIFY_SCRATCH:-$HOME/rbd-dev/tmp/verify}
mkdir -p "$SCR"
ECR=123456789012.dkr.ecr.ap-south-1.amazonaws.com/rhobound-demo/kshop
BASE=sha256:$(printf 'base' | sha256sum | cut -d' ' -f1)
CAND=sha256:$(printf 'cand' | sha256sum | cut -d' ' -f1)
OTHER=sha256:$(printf 'other' | sha256sum | cut -d' ' -f1)
fails=0; n=0
ok() { n=$((n + 1)); echo "ok   $n $*"; }
bad() { n=$((n + 1)); fails=$((fails + 1)); echo "FAIL $n $*"; }
check() { local what=$1; shift; if "$@"; then ok "$what"; else bad "$what"; fi; }

setup() {   # setup [LOCKSH_VARIANT]: a fresh tools1 in $T (fallback | fn | fn-noop)
  T=$(mktemp -d "$SCR/truth-XXXXXX"); EXTRA=()
  mkdir -p "$T/bin" "$T/lib" "$T/ci" "$T/home" "$T/stub"
  cp "$HERE/stubs/kubectl" "$T/bin/kubectl"
  cp "$HERE/stubs/capture.sh" "$T/ci/capture.sh"
  cat > "$T/lib/rbd-env.sh" << EOF
export RBD_HOME=$T/home RBD_ECR=$ECR KUBECONFIG=/dev/null RHOBOUND_STATE=$T/home/state
EOF
  case ${1:-fallback} in
    fallback) echo '# part B lock.sh without rbd_lock' > "$T/lib/lock.sh" ;;
    fn) cat > "$T/lib/lock.sh" << 'EOF'
rbd_lock() { exec 9>> "$RBD_HOME/lock"; flock -w "${1:-5}" 9 || return 1; export RBD_LOCK_HELD=${2:-x}; }   # part B's signature: WAIT_S WHAT
EOF
      ;;
    fn-noop) echo 'rbd_lock() { return 0; }' > "$T/lib/lock.sh" ;;
    partb)   # part B's own lock.sh and rbd-env.sh (tools1/lib), an rbd.env with example values
      cp "$KIT/tools1/lib/lock.sh" "$KIT/tools1/lib/rbd-env.sh" "$T/lib/"
      printf '%s\n' RBD_REGION=ap-south-1 RBD_ACCOUNT=123456789012 RBD_BUCKET=rhobound-research-123456789012-ap-south-1 \
        "RBD_ECR=$ECR" RBD_KMS=awskms:///alias/rhobound-demo-verdict KUBECONFIG=/dev/null "RBD_HOME=$T/home" \
        "RHOBOUND_STATE=$T/home/state" RBD_REPO=Sharvil2704/rhobound-demo > "$T/rbd.env"
      EXTRA=(RBD_ENV_FILE="$T/rbd.env" RBD_OPT="$T/opt" STUB_REAL_LOCK=1) ;;
  esac
  local s
  for s in auth cart catalog checkout inventory payments pricing product recommend storefront; do
    printf '%s' "$ECR@$BASE" > "$T/stub/img-$s"
  done
  jq -n --arg b "$BASE" --arg r "$ECR" '{schema: "rbd.baseline/v1", image_ref: $r, capture: "refit-1",
    services: ({auth: $b, cart: $b, catalog: $b, checkout: $b, inventory: $b, payments: $b, pricing: $b, product: $b,
    recommend: $b, storefront: $b})}' > "$T/home/baseline.json"
  : > "$T/stub/kubectl.log"; : > "$T/stub/capture.log"
}
run() {   # run SCRIPT ARGS...: under the stubs; stdout -> $T/out, stderr -> $T/err, exit -> RC
  [[ $(PATH="$T/bin:$PATH" command -v kubectl) == "$T/bin/kubectl" ]] || { echo "stub kubectl not first on PATH: stop"; exit 9; }
  env PATH="$T/bin:$PATH" STUB="$T/stub" "${EXTRA[@]}" STUB_CAND="$CAND" RBD_LIB="$T/lib" RBD_CI="$T/ci" RBD_WINDOW_S=5 \
    RBD_WARM_C="${WARM_C:-0}" RBD_WARM_BACK=0 RBD_LOCK_WAIT=1 RBD_ROLLOUT_TIMEOUT=5s "$@" > "$T/out" 2> "$T/err"
  RC=$?
}
sets() { grep -c ' set image ' "$T/stub/kubectl.log"; }
nth_set() { grep ' set image ' "$T/stub/kubectl.log" | sed -n "${1}p"; }
tj() { jq -r "$1" "$T/home/verify/truth/$CH/truth.json"; }
img() { cat "$T/stub/img-$1"; }
last() { tail -n 1 "$T/out" | jq -r "$1"; }

# 1. the bracket, fallback lock: B0, candidate, C, rollback
setup fallback; CH=c1-noop
run "$V/truth.sh" $CH auth "$CAND"
check "truth ok exits 0 ($RC)" test "$RC" = 0
check "two set image: candidate then baseline" test "$(sets)" = 2
check "first set image is the candidate" grep -q "auth=$ECR@$CAND" <<< "$(nth_set 1)"
check "second set image is the baseline" grep -q "auth=$ECR@$BASE" <<< "$(nth_set 2)"
check "production back at baseline" test "$(img auth)" = "$ECR@$BASE"
check "truth.json status ok" test "$(tj .status)" = ok
check "truth.json digests" test "$(tj .base_digest) $(tj .cand_digest)" = "$BASE $CAND"
check "seeds differ and are recorded" test "$(tj '.seeds.b0 != .seeds.c and .seeds.b0 > 0')" = true
check "b0 and c load.json copied" test -s "$T/home/verify/truth/$CH/b0.load.json" -a -s "$T/home/verify/truth/$CH/c.load.json"
check "B0 captured on the baseline image" grep -q "^truth-$CH-b0 5 .* img=$ECR@$BASE" "$T/stub/capture.log"
check "C captured on the candidate image" grep -q "^truth-$CH-c 5 .* img=$ECR@$CAND" "$T/stub/capture.log"
check "capture.sh ran under the held lock (env exported, probe refused)" \
  test "$(grep -c "held_env=truth-$CH:[0-9]* probe=held" "$T/stub/capture.log")" = 2
check "last stdout line is the step JSON (ok)" test "$(last .step) $(last .ok)" = "truth true"
check "times recorded" test "$(tj '[.times.b0_start, .times.rollout_done, .times.c_end, .times.rollback_done, .times.finished] | all')" = true
check "lock released after exit" flock -n "$T/home/lock" true
BUNDLE_T=$T

# 2. C capture fails: rollback happens, exit 1
setup fallback; CH=c2
STUB_FAIL_ON=truth-$CH-c run "$V/truth.sh" $CH auth "$CAND"
check "failure exits 1 ($RC)" test "$RC" = 1
check "rollback after the failure (2 set image, last = baseline)" test "$(sets)" = 2
check "rollback set image is the baseline" grep -q "auth=$ECR@$BASE" <<< "$(nth_set 2)"
check "production restored" test "$(img auth)" = "$ECR@$BASE"
check "status failed-restored" test "$(tj .status)" = failed-restored
check "error names the capture" grep -q "capture.sh truth-$CH-c" <<< "$(tj .error)"
check "step JSON ok=false" test "$(last .ok)" = false

# 3. --keep with the same failure: no rollback
setup fallback; CH=c3
STUB_FAIL_ON=truth-$CH-c run "$V/truth.sh" $CH auth "$CAND" --keep
check "--keep failure exits 1 ($RC)" test "$RC" = 1
check "--keep: one set image only (no rollback)" test "$(sets)" = 1
check "--keep: production stays on the candidate" test "$(img auth)" = "$ECR@$CAND"
check "status failed-kept" test "$(tj .status)" = failed-kept

# 4. --keep success
setup fn; CH=c4
run "$V/truth.sh" $CH auth "$CAND" --keep
check "--keep ok exits 0 ($RC)" test "$RC" = 0
check "--keep ok: one set image" test "$(sets)" = 1
check "--keep ok: status ok-kept, keep true" test "$(tj .status) $(tj .keep)" = "ok-kept true"
check "rbd_lock path: capture under the held lock" test "$(grep -c "held_env=truth-c4 probe=held" "$T/stub/capture.log")" = 2

# 5. preflight: production not at baseline -> refused, nothing changed
setup fallback; CH=c5
printf '%s' "$ECR@$OTHER" > "$T/stub/img-auth"
run "$V/truth.sh" $CH auth "$CAND"
check "not at baseline: exit 1 ($RC)" test "$RC" = 1
check "not at baseline: no set image, no capture" test "$(sets) $(wc -l < "$T/stub/capture.log")" = "0 0"
check "not at baseline: message" grep -q "restore it" "$T/err"
check "not at baseline: no output folder" test ! -e "$T/home/verify/truth/$CH"

# 6. rollback itself fails -> exit 4, loud
setup fallback; CH=c6
STUB_FAIL_ON=truth-$CH-c STUB_ROLLOUT_FAIL=$BASE run "$V/truth.sh" $CH auth "$CAND"
check "rollback failure exits 4 ($RC)" test "$RC" = 4
check "status failed-not-restored" test "$(tj .status)" = failed-not-restored
check "says ROLLBACK FAILED with the manual command" grep -q "ROLLBACK FAILED.*set image deployment/auth auth=$ECR@$BASE" "$T/err"

# 7. capture.sh fails after a finished window (kept as NAME.failed-<epoch>): its load.json used, warned
setup fallback; CH=c7
STUB_RC_ON=truth-$CH-b0 run "$V/truth.sh" $CH auth "$CAND"
check "finished window, capture exit 1: truth ok ($RC)" test "$RC" = 0
check "the warning is recorded, naming the failed folder" \
  test "$(tj '.warnings | map(select(test("exited 1: .*truth-c7-b0.failed-"))) | length')" = 1
check "b0.load.json taken from the failed folder" test -s "$T/home/verify/truth/$CH/b0.load.json"

# 8. rollout of the candidate fails -> rollback attempted, exit 1
setup fallback; CH=c8
STUB_ROLLOUT_FAIL=$CAND run "$V/truth.sh" $CH auth "$CAND"
check "candidate rollout failure exits 1 ($RC)" test "$RC" = 1
check "candidate rollout failure: rolled back" test "$(img auth) $(tj .status)" = "$ECR@$BASE failed-restored"

# 9. signal during the warm-up -> rollback, exit 143
setup fallback; CH=c9
( WARM_C=30 run "$V/truth.sh" $CH auth "$CAND"; echo "$RC" > "$T/rc" ) &
bgp=$!
for _ in $(seq 1 100); do
  [[ -f $T/home/verify/truth/$CH/truth.json && $(tj .phase) == rollout_done ]] && break
  sleep 0.1
done
tpid=$(sed -n 's/.*held_env=truth-c9:\([0-9]*\).*/\1/p' "$T/stub/capture.log" | head -n 1)
[[ -n $tpid ]] && kill -TERM "$tpid"
wait "$bgp"
check "TERM in warm-up exits 143 ($(cat "$T/rc"))" test "$(cat "$T/rc")" = 143
check "TERM: rolled back" test "$(img auth) $(tj .status)" = "$ECR@$BASE failed-restored"
check "TERM: error names the phase" grep -q "signal TERM in phase rollout_done" <<< "$(tj .error)"

# 10. lock busy -> refused before anything
setup fallback; CH=c10
flock "$T/home/lock" sleep 20 &
holder=$!
sleep 0.3
run "$V/truth.sh" $CH auth "$CAND"
kill "$holder" 2> /dev/null; wait "$holder" 2> /dev/null
check "lock busy: exit 1 ($RC)" test "$RC" = 1
check "lock busy: no set image, no capture" test "$(sets) $(wc -l < "$T/stub/capture.log")" = "0 0"
check "lock busy: message" grep -q "lock busy" "$T/err"

# 11. a lock.sh whose rbd_lock does not hold the lock -> refused
setup fn-noop; CH=c11
run "$V/truth.sh" $CH auth "$CAND"
check "lock.sh contract differs: exit 1, nothing done" test "$RC $(sets)" = "1 0"
check "lock.sh contract differs: message" grep -q "not held after taking it" "$T/err"

# 11b. a capture.sh that waits for the lock the verifier holds: stopped within seconds, nothing rolled out
setup fallback; CH=c11b
t0=$SECONDS
STUB_IGNORE_HELD=1 run "$V/truth.sh" $CH auth "$CAND"
check "deadlock: exit 1 within 15 s ($RC, $((SECONDS - t0)) s)" test "$RC" = 1 -a $((SECONDS - t0)) -lt 15
check "deadlock: message" grep -q "waits for the cluster lock the verifier holds" "$T/err"
check "deadlock: no set image" test "$(sets)" = 0
check "deadlock: lock free afterwards" flock -n "$T/home/lock" true

# 12. re-run under the same name -> refused; --check; usage
T=$BUNDLE_T; EXTRA=(); CH=c1-noop
run "$V/truth.sh" $CH auth "$CAND"
check "same CHANGE again: exit 1 (exists)" test "$RC" = 1
check "same CHANGE again: message" grep -q "exists: re-run under a new CHANGE name" "$T/err"
: > "$T/stub/kubectl.log"
run "$V/truth.sh" c12 auth "$CAND" --check
check "--check ok exits 0, no set image, no folder" test "$RC $(sets)" = "0 0" -a ! -e "$T/home/verify/truth/c12"
run "$V/truth.sh" c12 auth "$BASE" --check
check "--check: candidate = baseline refused" test "$RC" = 1
run "$V/truth.sh" c12 auth sha256:abc
check "bad digest: usage exit 2" test "$RC" = 2
run "$V/truth.sh" c12 auth
check "missing arg: usage exit 2" test "$RC" = 2

# 12b. part B's own lock.sh + rbd-env.sh: the bracket, capture.sh nested under the verifier's lock (rbd_lock 5 returns at once)
if [[ -r $KIT/tools1/lib/lock.sh && -r $KIT/tools1/lib/rbd-env.sh ]]; then
  setup partb; CH=c12b
  run "$V/truth.sh" $CH auth "$CAND"
  check "part B lock.sh: truth ok ($RC)" test "$RC" = 0
  check "part B lock.sh: both captures nested (held_env = truth.sh's pid, probe refused)" \
    test "$(grep -c "held_env=[0-9][0-9]* probe=held" "$T/stub/capture.log")" = 2
  # (the holder's label is rbd_lock's WAIT_S, not WHAT: part B's rbd_lock passes WAIT twice; the pid is the verifier's)
  hpid=$(sed -n 's/.*held_env=\([0-9]*\) .*/\1/p' "$T/stub/capture.log" | head -n 1)
  check "part B lock.sh: holder file names the verifier's pid ($hpid)" grep -q " pid $hpid user " "$T/home/lock.holder"
  check "part B lock.sh: rolled back, status ok" test "$(img auth) $(tj .status)" = "$ECR@$BASE ok"
  check "part B log/die did not replace the verifier's (truth.log written)" grep -q "phase c_end" "$T/home/verify/truth/$CH/truth.log"
  setup partb; CH=c12c
  flock "$T/home/lock" sleep 20 &
  holder=$!; sleep 0.3
  run "$V/truth.sh" $CH auth "$CAND"
  kill "$holder" 2> /dev/null; wait "$holder" 2> /dev/null
  check "part B lock.sh busy: exit 1 within RBD_LOCK_WAIT, nothing done" test "$RC $(sets)" = "1 0"
else
  echo "skip: part B's tools1/lib/lock.sh or rbd-env.sh not present"
fi

# 13. aa.sh: two windows, resume, refusal when production differs
T=$BUNDLE_T; EXTRA=()
: > "$T/stub/capture.log"
run "$V/aa.sh" 2
check "aa.sh 2 exits 0 ($RC)" test "$RC" = 0
check "aa.sh: two captures under the held lock" test "$(grep -c '^aa-[12] 5 .*probe=held' "$T/stub/capture.log")" = 2
check "aa.sh: load.json copies" test -s "$T/home/verify/aa/aa-1.load.json" -a -s "$T/home/verify/aa/aa-2.load.json"
check "aa.sh: aa.json lists both" test "$(jq '.windows | length' "$T/home/verify/aa/aa.json")" = 2
run "$V/aa.sh" 3
check "aa.sh 3 resumes: one new capture only" test "$RC $(wc -l < "$T/stub/capture.log")" = "0 3"
printf '%s' "$ECR@$OTHER" > "$T/stub/img-cart"
run "$V/aa.sh" 1 aa2
check "aa.sh: production not at baseline refused" test "$RC" = 1 -a ! -e "$T/home/captures/aa2-1"
check "aa.sh: message names the service" grep -q "cart runs $OTHER" "$T/err"
printf '%s' "$ECR@$BASE" > "$T/stub/img-cart"
run "$V/aa.sh" 0
check "aa.sh 0: usage exit 2" test "$RC" = 2

# 14. collect.sh + score.py --bundle on the result (c1: +1 ms at both entries under the proof's prediction: right pass)
mkdir -p "$T/home/runs/headsha1/gate"
cp "$HERE/fixtures/proof/prediction.json" "$T/home/runs/headsha1/"
cp "$HERE/fixtures/proof/gate/gate.json" "$HERE/fixtures/proof/gate/verdict.txt" "$T/home/runs/headsha1/gate/"
run "$V/collect.sh" run c1-noop headsha1
check "collect.sh run exits 0 ($RC)" test "$RC" = 0
check "collect.sh run: files in the bundle" test -s "$T/home/verify/truth/c1-noop/prediction.json" -a -s "$T/home/verify/truth/c1-noop/gate/gate.json"
run "$V/collect.sh" run c1-noop nosuchrun
check "collect.sh run: missing run refused" test "$RC" = 1
mkdir -p "$T/home/captures/refit-1/meta"
cp "$T/home/captures/aa-1/meta/load.json" "$T/home/captures/refit-1/meta/load.json"
run "$V/collect.sh" aa refit-1
check "collect.sh aa: refit window added" test "$RC" = 0 -a -s "$T/home/verify/aa/refit-1.load.json"
run "$V/collect.sh" bogus
check "collect.sh: usage exit 2" test "$RC" = 2
# keep only the completed brackets in the bundle copy
B=$SCR/bundle-$$; mkdir -p "$B/truth"; cp -r "$T/home/verify/aa" "$B/"; cp -r "$T/home/verify/truth/c1-noop" "$B/truth/"
python3 -I "$V/score.py" --bundle "$B" --out "$B/out" > "$B/score.out"
src=$?
check "score --bundle: c1-noop right-pass" test "$(jq -r '.changes[0] | "\(.name) \(.service) \(.score)"' "$B/out/score.json")" = "c1-noop auth right-pass"
check "score --bundle: 4 A/A windows, 6 pairs" test "$(jq '.aa.entries.storefront.n' "$B/out/score.json")" = 6
check "score --bundle: observed +1 ms at storefront" \
  test "$(jq '.changes[0].entries[] | select(.name=="storefront") | (.observed_ms - 1 | fabs) < 0.1' "$B/out/score.json")" = true
check "score --bundle: exit 0 (no failure listed) ($src)" test "$src" = 0

# 15. the day's flow (no aa.sh; no bracket for the no-op c1): the A/A set is the refit's window plus each bracket's B0, added by
#     collect.sh aa; score.py --bundle on exactly that (4 windows, 6 pairs)
setup fallback
mkdir -p "$T/home/runs/headsha1/gate"
cp "$HERE/fixtures/proof/prediction.json" "$T/home/runs/headsha1/"
cp "$HERE/fixtures/proof/gate/gate.json" "$HERE/fixtures/proof/gate/verdict.txt" "$T/home/runs/headsha1/gate/"
run "$T/ci/capture.sh" prod-0 5 4242   # the refit's window (refit.sh prod-0 runs capture.sh prod-0)
run "$V/collect.sh" aa prod-0
check "day: collect.sh aa prod-0 ($RC)" test "$RC" = 0 -a -s "$T/home/verify/aa/prod-0.load.json"
for c in c2-auth-small c3-auth-mid c4-auth-wait; do
  run "$V/truth.sh" "$c" auth "$CAND"
  r1=$RC
  run "$V/collect.sh" run "$c" headsha1
  r2=$RC
  run "$V/collect.sh" aa "truth-$c-b0"
  check "day: $c bracket, collect run, collect aa b0 ($r1 $r2 $RC)" test "$r1 $r2 $RC" = "0 0 0"
  check "day: $c's A/A copy is its B0" cmp -s "$T/home/verify/aa/truth-$c-b0.load.json" "$T/home/verify/truth/$c/b0.load.json"
done
B2=$SCR/bundle-day-$$; mkdir -p "$B2"; cp -r "$T/home/verify/aa" "$T/home/verify/truth" "$B2/"
python3 -I "$V/score.py" --bundle "$B2" --out "$B2/out" > "$B2/score.out"
src=$?
check "day score: exit 0 ($src)" test "$src" = 0
check "day score: A/A windows = prod-0 + the three B0" test "$(jq -c '[.aa.windows[].name] | sort' "$B2/out/score.json")" = \
  '["prod-0","truth-c2-auth-small-b0","truth-c3-auth-mid-b0","truth-c4-auth-wait-b0"]'
check "day score: 6 pairs at both entries" test "$(jq -c '[.aa.entries[].n]' "$B2/out/score.json")" = '[6,6]'
check "day score: three changes, each right-pass" \
  test "$(jq -c '[.changes[] | "\(.name) \(.score)"]' "$B2/out/score.json")" = '["c2-auth-small right-pass","c3-auth-mid right-pass","c4-auth-wait right-pass"]'
check "day score: the floor is the largest pair difference (p90 of 6)" \
  test "$(jq '.aa.entries.checkout | .floor_ms == ([.pairs[].abs_ms] | max)' "$B2/out/score.json")" = true
# a long CHANGE (41 chars: truth-<CHANGE>-b0 is 50) whose B0 capture.sh failed after its window: collect.sh aa takes it from
# the kept NAME.failed-<epoch>, as truth.sh did
L=c9-$(printf 'x%.0s' {1..38})
STUB_RC_ON=truth-$L-b0 run "$V/truth.sh" "$L" auth "$CAND"
r1=$RC
run "$V/collect.sh" aa "truth-$L-b0"
check "day: long name, failed B0 kept: collect.sh aa from NAME.failed-* ($r1 $RC)" test "$r1 $RC" = "0 0"
check "day: that A/A copy is the bracket's B0" cmp -s "$T/home/verify/aa/truth-$L-b0.load.json" "$T/home/verify/truth/$L/b0.load.json"
check "day: the fallback is logged" grep -q "kept failed capture" "$T/err"
run "$V/collect.sh" aa no-such-capture
check "day: collect.sh aa of a missing capture refused ($RC)" test "$RC" = 1

# 16. several services, one candidate image (2026-10-31: a shared-library / base change; up to 5 services)
BASE2=sha256:$(printf 'base2' | sha256sum | cut -d' ' -f1)
setup fallback; CH=c40-multi
printf '%s' "$ECR@$BASE2" > "$T/stub/img-payments"
jq --arg b "$BASE2" '.services.payments = $b' "$T/home/baseline.json" > "$T/home/b.tmp" && mv "$T/home/b.tmp" "$T/home/baseline.json"
run "$V/truth.sh" $CH auth,payments,inventory "$CAND"
check "multi: exits 0 ($RC)" test "$RC" = 0
check "multi: six set image (3 to the candidate, 3 back)" test "$(sets)" = 6
check "multi: auth back on its baseline after the bracket" test "$(img auth)" = "$ECR@$BASE"
check "multi: each restored to its OWN baseline digest" test "$(img auth) $(img payments) $(img inventory)" = "$ECR@$BASE $ECR@$BASE2 $ECR@$BASE"
check "multi: truth.json lists the services and their bases" \
  test "$(tj '.services | join(",")') $(tj '.base_digests.payments')" = "auth,payments,inventory $BASE2"
check "multi: the candidate went to all three" test "$(grep -c " set image .*=$ECR@$CAND" "$T/stub/kubectl.log")" = 3
setup fallback; CH=c40-fail
printf '%s' "$ECR@$BASE2" > "$T/stub/img-payments"
jq --arg b "$BASE2" '.services.payments = $b' "$T/home/baseline.json" > "$T/home/b.tmp" && mv "$T/home/b.tmp" "$T/home/baseline.json"
STUB_FAIL_ON=truth-$CH-c run "$V/truth.sh" $CH auth,payments "$CAND"
check "multi failure: exits 1 and every service restored ($RC)" \
  test "$RC $(img auth) $(img payments)" = "1 $ECR@$BASE $ECR@$BASE2"
check "multi failure: status failed-restored" test "$(tj .status)" = failed-restored
setup fallback; CH=c40-bad
run "$V/truth.sh" $CH auth,auth "$CAND"
check "multi: a service listed twice is refused ($RC)" test "$RC" = 2
run "$V/truth.sh" $CH a,b,c,d,e,f "$CAND"
check "multi: six services refused ($RC)" test "$RC" = 2

# 17. several services, one candidate image EACH (a multi-image change: two PRs deployed together)
CAND2=sha256:$(printf 'cand2' | sha256sum | cut -d' ' -f1)
setup fallback; CH=m1-multi-image
run "$V/truth.sh" $CH payments,catalog "$CAND,$CAND2"
check "multi-image: exits 0 ($RC)" test "$RC" = 0
check "multi-image: payments got its candidate, catalog its own" \
  test "$(grep -c " set image .*payments=$ECR@$CAND" "$T/stub/kubectl.log") $(grep -c " set image .*catalog=$ECR@$CAND2" "$T/stub/kubectl.log")" = "1 1"
check "multi-image: both back on baseline; truth.json lists both candidates" \
  test "$(img payments) $(img catalog) $(tj '.cand_digests.catalog')" = "$ECR@$BASE $ECR@$BASE $CAND2"
run "$V/truth.sh" m1-bad payments,catalog "$CAND,$CAND2,$CAND"
check "multi-image: a digest count that is neither 1 nor the service count is refused ($RC)" test "$RC" = 2

echo "$((n - fails))/$n passed"
if ((fails == 0)) && [[ -z ${VERIFY_KEEP:-} ]]; then rm -rf "$SCR"/truth-* "$B" "$B2"; fi
((fails == 0))
