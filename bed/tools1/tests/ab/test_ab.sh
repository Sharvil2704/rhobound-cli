#!/usr/bin/env bash
# shellcheck disable=SC2015  # "A && B || fail": fail when either check fails, as meant
# ab.sh end to end with a fake kubectl (records calls, canned Deployment, a canned abdrive pod whose /out holds the
# offline proof's loadgen.csv / rc-a.json / rc-b.json), a fake copy_traces.sh (the synthetic mixed capture of
# test_repro.sh) and the REAL rhobound CLI for check / diff-fit; then the failure paths and the trap.
# usage: bash tools1/tests/ab/test_ab.sh      (env: WORK, LEAF, RHOBOUND; run it through capped.sh)
set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
KIT=$(cd "$HERE/../.." && pwd)
LEAF=${LEAF:-$HOME/rbd-dev/leaf}
RHOBOUND=${RHOBOUND:-$HOME/rbd-dev/rhobound}
WORK=${WORK:-$HOME/rbd-dev/tmp/partC/repro}
ARMS=$LEAF/arms
PASSED=0
fail() { echo "FAIL: $*" >&2; exit 1; }
ok() { echo "ok: $*"; PASSED=$((PASSED + 1)); }
ECR=123456789012.dkr.ecr.ap-south-1.amazonaws.com/rhobound-demo/kshop
BASE=sha256:$(printf 'a%.0s' {1..64})
CAND=sha256:$(printf 'c%.0s' {1..64})
RUN=0123456789abcdef0123456789abcdef01234567

# inputs shared by every case: the mixed capture (test_repro.sh's) and a real production cut for abmix
[[ -f $WORK/mixed/traces/spans.jsonl ]] || {
  rm -rf "$WORK/mixed.new"; mkdir -p "$WORK"
  python3 -I "$HERE/mkmixed.py" "$ARMS" "$HOME"/rbd-dev/capture/traces/spans.jsonl.gz \
    "$WORK/mixed.new"
  mv "$WORK/mixed.new" "$WORK/mixed"; }
if [[ ! -f $WORK/prodcut/manifest.json ]]; then
  rm -rf "$WORK/prodcut"
  "$RHOBOUND" check "$LEAF/pc" --window 2026-10-22T05:12:45Z,2026-10-22T05:22:45Z --cut entry-start \
    --out "$WORK/prodcut" --request-count "$LEAF/pc/request-count.json" --json >/dev/null
fi

setup() {  # a fresh fake machine in $T
  T=$WORK/t-$1
  rm -rf "$T"
  mkdir -p "$T/root/lib" "$T/root/bin" "$T/home/captures/base1" "$T/driver-out"
  cp "$KIT/lib/rbd-env.sh" "$KIT/lib/lock.sh" "$T/root/lib/"     # part B's, real
  cp "$HERE/fake/copy_traces.sh" "$T/root/lib/"
  cat >"$T/rbd.env" <<EOT
RBD_REGION=ap-south-1
RBD_ACCOUNT=123456789012
RBD_BUCKET=rhobound-research-123456789012-ap-south-1
RBD_ECR=$ECR
RBD_KMS=awskms:///alias/rhobound-demo-verdict
KUBECONFIG=$T/kubeconfig
RHOBOUND_STATE=$T/home/state
RBD_HOME=$T/home
RBD_REPO=Sharvil2704/rhobound-demo
EOT
  jq -n --arg ecr "$ECR" '{schema: "rbd.images/v1", image_ref: $ecr,
    abdrive: ($ecr + "@sha256:abd0000000000000000000000000000000000000000000000000000000000001")}' \
    >"$T/home/images.json"
  ln -s "$KIT/lib/abmix.py" "$T/root/lib/abmix.py"
  ln -s "$KIT/lib/splitarms.py" "$T/root/lib/splitarms.py"
  cp "$HERE/fake/kubectl" "$T/root/bin/kubectl"
  ln -s "$RHOBOUND" "$T/root/bin/rhobound"
  ln -s "$WORK/prodcut" "$T/home/captures/base1/cut"
  jq -n --arg b "$BASE" --arg ecr "$ECR" '{schema: "rbd.baseline/v1", services: {auth: $b, payments: $b},
    image_ref: $ecr, fit: {dir: "/var/lib/rbd/captures/base1/fit", digest: "sha256:0"}, capture: "base1",
    updated_at: "2026-10-30T08:00:00Z"}' >"$T/home/baseline.json"
  cp "$ARMS/loadgen.csv" "$ARMS/rc-a.json" "$ARMS/rc-b.json" "$T/driver-out/"
  jq -n --slurpfile rc "$ARMS/rc-a.json" '{schema: "rbd.abdrive-summary/v1", service: "auth", window: $rc[0].window,
    first_send_unix_ns: 1792646025000000000, last_answer_unix_ns: 1792646265000000000,
    arms: {A: {scheduled: 24196, answered: 24196, failed: 0, errors: []},
           B: {scheduled: 24196, answered: 24196, failed: 0, errors: []}}, interrupted: false, ok: true}' \
    >"$T/driver-out/summary.json"
  echo "abdrive: (canned)" >"$T/driver-out/abdrive.log"
  echo 0 >"$T/driver-out/exit"
  export FAKE_T=$T FAKE_MIXED=$WORK/mixed FAKE_PROD=$HERE/fixtures/prod-deploy-auth.json RBD_OPT=$T/root
  export RBD_ENV_FILE=$T/rbd.env AB_FLUSH_WAIT=0 AB_POLL=1 AB_LOCK_WAIT=5
  unset FAKE_ROLLOUT_RC FAKE_EXEC_NEVER AB_SECONDS AB_KEEP_RAW RBD_CLI RBD_ABDRIVE_DIGEST
}
runab() {  # args...; sets RC, LAST (last stdout line)
  RC=0
  bash "$KIT/ci/ab.sh" "$@" >"$T/stdout" 2>"$T/stderr" || RC=$?
  LAST=$(tail -n 1 "$T/stdout")
  jq -e . <<<"$LAST" >/dev/null || fail "the last stdout line is not JSON: $LAST"
}
teardown_last() {  # the last kubectl call is the label delete in rbd-ab
  tail -n 1 "$T/kubectl.log" | grep -q '^-n rbd-ab delete deployment,replicaset,service,pod,configmap -l rbd.ab=1 --ignore-not-found --cascade=foreground --wait=true --timeout=150s$' \
    || fail "$1: the last kubectl call is not the teardown: $(tail -n 1 "$T/kubectl.log")"
}

# 1. success: real check + diff-fit on the split arms reproduce the offline proof's own-time delta
setup ok
echo AB_SECONDS=240 >>"$T/rbd.env"
runab "$RUN" auth "$BASE" "$CAND"
[[ $RC == 0 ]] || fail "success case: exit $RC: $LAST $(tail -n 5 "$T/stderr")"
D=$T/home/runs/$RUN/ab
jq -e '.step == "ab" and .ok == true and .own_ms_delta == 0.6706931917706136 and .own_ms_se == 0.0599651934101887
       and (.ab_digest | startswith("sha256:")) and .teardown == "ok"' <<<"$LAST" >/dev/null || fail "last line $LAST"
[[ $(grep -c . "$T/stdout") == 1 ]] || fail "stdout holds more than the JSON line"
ok "success: exit 0, last line $(jq -c '{ok, own_ms_delta, own_ms_se, ab_digest}' <<<"$LAST")"
jq -e --arg b "$BASE" --arg c "$CAND" '.ok and .stage == "done" and .error == null and .base_is_production == true
  and .live_digest == $b and .base_digest == $b and .cand_digest == $c and .seconds == 240 and .warmup == 60
  and .rate == 100.05 and .mix.paths == [{"path": "/verify", "w": 1}] and .mix.window_source == "manifest.json"
  and .driver.exit == 0 and .check.a.exit == 0 and .check.b.exit == 0
  and .check.a.verdict == "admitted-with-doubts" and .check.a.kept_share == {"source": "counted", "value": 1}
  and .diff_fit.exit == 0 and .record.service.own_ms.delta == 0.6706931917706136
  and .record.service.visits == {"baseline": 24133, "candidate": 24133} and .record.findings == []
  and .split.traces == {"a": 24196, "b": 24196} and .teardown == "ok"
  and (.timings | has("arms_ready") and has("driver_done") and has("teardown") and has("diff_fit"))
  and .ab_dir == "ab"' "$D/ab.json" >/dev/null || fail "ab.json $(jq -c 'del(.mix, .split, .driver.summary)' "$D/ab.json")"
[[ $(jq -r .ab_digest "$D/diff-fit.json") == "$(jq -r '.record.sha256' "$D/ab.json")" ]] \
  || fail "the record's sha256 is not diff-fit's ab_digest"
dg=$(jq -r .ab_digest "$D/diff-fit.json")
[[ -f $T/home/state/ab/${dg#sha256:}.json && -f $D/cut-a/loadgen.csv && -d $D/raw && -d $D/cut-b/traces ]] \
  || fail "record not minted in RHOBOUND_STATE, or loadgen.csv / raw / cut-b missing"
jq -e --arg n "auth@aaaaaaaaaaaa" --arg m "auth@cccccccccccc" '.arms.baseline.capture == $n
  and .arms.candidate.capture == $m' "$D/record/ab-record.json" >/dev/null || fail "arm names in the record"
ok "ab.json, record (minted, names auth@BASE12 / auth@CAND12), cut-a/loadgen.csv"
A0=$T/applied/0.json; A1=$T/applied/1.json
jq -e --arg b "$ECR@$BASE" --arg c "$ECR@$CAND" --slurpfile p "$FAKE_PROD" '
  ($p[0].spec.template.spec.containers[0]) as $pc
  | (.items | map(.kind)) == ["Deployment", "Deployment", "Service", "Service"]
  and ([.items[0], .items[1]] | all(.metadata.namespace == "rbd-ab" and .spec.replicas == 1
      and .spec.template.spec.automountServiceAccountToken == false
      and .spec.template.spec.imagePullSecrets == [{"name": "ecr"}]
      and .spec.template.spec.nodeSelector == {"rhobound.io/pool": "ab"}
      and .spec.template.spec.tolerations == [{"key": "rhobound.io/pool", "operator": "Exists"}]
      and .spec.selector.matchLabels.app == "auth-ab" and .spec.template.metadata.labels.app == "auth-ab"
      and (.spec.template.metadata.labels | has("app.kubernetes.io/part-of") | not)
      and (.spec.template.spec.containers | length) == 1
      and .spec.template.spec.containers[0].resources == $pc.resources
      and .spec.template.spec.containers[0].readinessProbe == $pc.readinessProbe
      and .spec.template.spec.containers[0].ports == $pc.ports
      and .spec.template.spec.containers[0].env == $pc.env))
  and .items[0].metadata.name == "auth-ab-a" and .items[0].spec.template.spec.containers[0].image == $b
  and .items[0].spec.template.metadata.labels["rbd.arm"] == "a"
  and .items[1].metadata.name == "auth-ab-b" and .items[1].spec.template.spec.containers[0].image == $c
  and .items[1].spec.selector.matchLabels == {"app": "auth-ab", "rbd.arm": "b"}
  and .items[2].spec.selector == {"app": "auth-ab", "rbd.arm": "a"} and .items[2].spec.ports[0].port == 8080
  and .items[0].spec.template.spec.containers[0].env[0].valueFrom.fieldRef.fieldPath == "metadata.name"' "$A0" \
  >/dev/null || fail "arm manifests $(jq -c '.items[0].spec.template.spec' "$A0")"
ok "arm Deployments/Services: production's env byte for byte, resources/ports/probe, ECR@digest, labels, pool=ab, no SA token"
jq -e --arg img "$ECR@sha256:abd0000000000000000000000000000000000000000000000000000000000001" \
  --rawfile mix "$D/mix.json" '.items[0].kind == "ConfigMap" and .items[0].data["mix.json"] == $mix
  and .items[1].kind == "Pod" and .items[1].spec.containers[0].image == $img
  and .items[1].spec.nodeSelector == {"rhobound.io/pool": "load"} and .items[1].spec.restartPolicy == "Never"
  and .items[1].spec.automountServiceAccountToken == false
  and (.items[1].spec.containers[0].command | .[0:2] == ["sh", "-c"] and .[3] == "abdrive"
       and (.[4:] | join(" ")) == "-a http://auth-ab-a.rbd-ab.svc.cluster.local:8080 -b http://auth-ab-b.rbd-ab.svc.cluster.local:8080 -rate 100.05 -seconds 240 -warmup 60 -seed \(.[15]) -service auth -host auth:8080 -mix /etc/abdrive/mix.json -out /out")' \
  "$A1" >/dev/null || fail "driver manifest $(jq -c '.items[1].spec.containers[0].command' "$A1")"
ok "driver Pod: abdrive image by digest on pool=load, mix ConfigMap, args (seconds from rbd.env, production's Host)"
calls=$(cut -d' ' -f1-4 "$T/kubectl.log" | sed 's/ -l.*//' | tr '\n' '|')
want='-n kshop get deployment|-n rbd-ab delete deployment,replicaset,service,pod,configmap|apply -f '
[[ $calls == "$want"* ]] || fail "kubectl call order: $calls"
grep -q '^-n rbd-ab cp abdrive:/out ' "$T/kubectl.log" || fail "no kubectl cp"
teardown_last success
[[ $(grep -c ' exec abdrive -- cat /out/exit' "$T/kubectl.log") -ge 2 ]] || fail "the driver was not polled"
read -r from to dest <"$T/copy_traces.log"
[[ $from == 1792646025000000000 && $to == 1792646265000000000 && $dest == "$D/raw" ]] \
  || fail "copy_traces.sh args: $from $to $dest"
jq -e '.traces.copy.copied == 3 and .traces.since_ns == 1792646025000000000' "$D/ab.json" >/dev/null \
  || fail "ab.json traces $(jq -c .traces "$D/ab.json")"
[[ $(cat "$T/home/lock.holder" 2>/dev/null) == "" ]] || fail "lock.holder left behind: $(cat "$T/home/lock.holder")"
flock -n "$T/home/lock" true || fail "the lock is still held after exit"
ok "kubectl order (get, cleanup, apply, rollout, driver, poll, cp, teardown last), copy_traces ns args, lock released"

# 2. re-run of the same RUN: the earlier ab/ moves aside; the driver fails (exit 1) -> teardown, ok false
export FAKE_T=$T
echo 1 >"$T/driver-out/exit"
jq '.ok = false | .arms.B.answered = 20000' "$T/driver-out/summary.json" >"$T/s.json" && mv "$T/s.json" "$T/driver-out/summary.json"
: >"$T/kubectl.log"
runab "$RUN" auth "$BASE" "$CAND"
[[ $RC == 1 ]] && jq -e '.ok == false and .stage == "driver" and (.error | test("abdrive exit 1"))
  and .teardown == "ok"' <<<"$LAST" >/dev/null || fail "driver failure: exit $RC $LAST"
teardown_last "driver failure"
compgen -G "$T/home/runs/$RUN/ab.old-*" >/dev/null || fail "the earlier ab/ was not moved aside"
jq -e '.ok == false and .stage == "driver" and .driver.exit == 1' "$T/home/runs/$RUN/ab/ab.json" >/dev/null \
  || fail "driver failure ab.json"
ok "driver failure: exit 1, stage driver, teardown last, earlier run kept as ab.old-*"

# 2b. CI v2: a 5th argument AB_DIR ab-auth (one A/B per service of a multi-service change): all under runs/RUN/ab-auth/
abkeep=$(sha256sum "$T/home/runs/$RUN/ab/ab.json")
: >"$T/kubectl.log"
runab "$RUN" auth "$BASE" "$CAND" ab-auth
[[ $RC == 1 ]] && jq -e --arg d "$T/home/runs/$RUN/ab-auth" '.ok == false and .stage == "driver" and .dir == $d' <<<"$LAST" \
  >/dev/null || fail "AB_DIR ab-auth: exit $RC $LAST"
jq -e '.ab_dir == "ab-auth" and .ok == false and .stage == "driver" and .service == "auth"' \
  "$T/home/runs/$RUN/ab-auth/ab.json" >/dev/null || fail "AB_DIR ab-auth: ab.json $(head -c 300 "$T/home/runs/$RUN/ab-auth/ab.json")"
[[ $(sha256sum "$T/home/runs/$RUN/ab/ab.json") == "$abkeep" ]] || fail "AB_DIR ab-auth touched runs/RUN/ab/"
teardown_last "AB_DIR ab-auth"
ok "AB_DIR ab-auth: ab.json (ab_dir ab-auth) under runs/RUN/ab-auth/, runs/RUN/ab/ untouched, teardown last"

# 3. rollout fails; a production config with calls: callee URLs become production FQDNs; caller's AB_SECONDS wins
setup rollout
export FAKE_ROLLOUT_RC=1 FAKE_PROD=$HERE/fixtures/prod-deploy-calls.json AB_SECONDS=30
echo AB_SECONDS=240 >>"$T/rbd.env"
runab "$RUN" auth "$BASE" "$CAND"
[[ $RC == 1 ]] && jq -e '.ok == false and .stage == "arms_ready" and .teardown == "ok"' <<<"$LAST" >/dev/null \
  || fail "rollout failure: exit $RC $LAST"
teardown_last "rollout failure"
[[ ! -f $T/applied/1.json ]] || fail "the driver was applied after a failed rollout"
jq -e '[.items[0].spec.template.spec.containers[0].env[] | select(.name == "KSHOP_CONFIG")][0].value | fromjson
  | [.calls[].url] == ["http://inventory.kshop.svc.cluster.local:8080/reserve",
                       "http://payments.kshop.svc.cluster.local:8080/charge/{tail}",
                       "http://catalog.kshop.svc.cluster.local:8080/item"]' "$T/applied/0.json" >/dev/null \
  || fail "callee URLs not rewritten"
jq -e --slurpfile p "$FAKE_PROD" '[.items[0].spec.template.spec.containers[0].env[] | select(.name != "KSHOP_CONFIG")]
  == [$p[0].spec.template.spec.containers[0].env[] | select(.name != "KSHOP_CONFIG")]' "$T/applied/0.json" >/dev/null \
  || fail "the env differs from production's beyond KSHOP_CONFIG's callee URLs"
jq -e '.seconds == 30' "$T/home/runs/$RUN/ab/ab.json" >/dev/null || fail "the caller's AB_SECONDS did not win"
ok "rollout failure: exit 1, stage arms_ready, teardown last; callee URLs -> kshop FQDNs (the only env change); caller AB_SECONDS wins"

# 4. a production pod with envFrom is refused before anything is created
setup envfrom
export FAKE_PROD=$HERE/fixtures/prod-deploy-envfrom.json
runab "$RUN" auth "$BASE" "$CAND"
[[ $RC == 1 ]] && jq -e '.stage == "manifests" and (.error | test("envFrom")) and .teardown == "none"' <<<"$LAST" \
  >/dev/null || fail "envFrom: exit $RC $LAST"
[[ $(wc -l <"$T/kubectl.log") == 1 && ! -d $T/applied ]] || fail "envFrom: kubectl calls $(cat "$T/kubectl.log")"
ok "envFrom refused at manifests, nothing created"

# 5. the lock is held by another step: refused after AB_LOCK_WAIT, no kubectl call
setup lock
export AB_LOCK_WAIT=1
mkdir -p "$T/home"
flock "$T/home/lock" sleep 6 &
holder=$!
sleep 0.5
runab "$RUN" auth "$BASE" "$CAND"
kill "$holder" 2>/dev/null || true
wait "$holder" 2>/dev/null || true
[[ $RC == 1 ]] && jq -e '.stage == "lock" and (.error | test("lock"))' <<<"$LAST" >/dev/null \
  || fail "lock: exit $RC $LAST"
[[ ! -s $T/kubectl.log ]] || fail "lock: kubectl was called"
ok "lock held elsewhere: exit 1, stage lock, no cluster call"

# 5b. AB_LOCK_WAIT's default is 3000 s (a truth bracket holds the lock ~35 min): a stub lock.sh records the wait asked
setup lockdefault
unset AB_LOCK_WAIT
cat >"$T/root/lib/lock.sh" <<'EOT'
rbd_lock() { echo "$1" >"$FAKE_T/lockwait"; return 1; }
rbd_lock_holder() { echo "truth-c2 (stub)"; }
EOT
runab "$RUN" auth "$BASE" "$CAND"
[[ $RC == 1 && $(cat "$T/lockwait" 2>/dev/null) == 3000 ]] && jq -e '.stage == "lock" and (.error | test("waited 3000s"))' \
  <<<"$LAST" >/dev/null || fail "lock wait default: exit $RC, asked $(cat "$T/lockwait" 2>/dev/null): $LAST"
ok "AB_LOCK_WAIT unset: rbd_lock asked for 3000 s"

# 6. SIGTERM while the driver runs: the trap tears down and still ends with the JSON line
setup term
export FAKE_EXEC_NEVER=1
bash "$KIT/ci/ab.sh" "$RUN" auth "$BASE" "$CAND" >"$T/stdout" 2>"$T/stderr" &
pid=$!
for _ in $(seq 1 100); do grep -q ' exec ' "$T/kubectl.log" 2>/dev/null && break; sleep 0.1; done
kill -TERM "$pid"
RC=0; wait "$pid" || RC=$?
LAST=$(tail -n 1 "$T/stdout")
[[ $RC == 1 ]] && jq -e '.ok == false and .stage == "driver" and (.error | test("signal")) and .teardown == "ok"' \
  <<<"$LAST" >/dev/null || fail "SIGTERM: exit $RC $LAST"
teardown_last SIGTERM
ok "SIGTERM during the run: exit 1, teardown last, JSON last line"

# 7. diff-fit fails (a broken loadgen.csv): its exit and message are recorded, ok false
setup dfbad
sed -i '1s/.*/arm,seq,sent,answered,status/' "$T/driver-out/loadgen.csv"
runab "$RUN" auth "$BASE" "$CAND"
[[ $RC == 1 ]] && jq -e '.stage == "diff_fit" and (.error | test("diff-fit exit 1"))' <<<"$LAST" >/dev/null \
  || fail "diff-fit failure: exit $RC $LAST"
jq -e '.diff_fit.exit == 1 and (.diff_fit.stderr | test("header")) and .check.a.exit == 0 and .record == null' \
  "$T/home/runs/$RUN/ab/ab.json" >/dev/null || fail "diff-fit failure ab.json $(jq -c .diff_fit "$T/home/runs/$RUN/ab/ab.json")"
ok "diff-fit failure recorded (exit 1, its message), ok false"

# 8. usage and bad arguments: exit 1 with the JSON line, nothing touched
setup usage
for a in "x auth $BASE" "$RUN auth sha256:12 $CAND" "$RUN Auth_x $BASE $CAND" "-bad auth $BASE $CAND"; do
  # shellcheck disable=SC2086
  runab $a
  [[ $RC == 1 ]] && jq -e '.ok == false and .stage == "usage"' <<<"$LAST" >/dev/null || fail "usage $a: $RC $LAST"
done
[[ ! -e $T/kubectl.log ]] || fail "usage: kubectl called"
ok "bad arguments: exit 1, stage usage"

rm -rf "$WORK"/t-*/home/runs/*/ab/raw "$WORK"/t-*/home/runs/*/ab/raw-? "$WORK"/t-*/home/runs/*/ab.old-*/raw*
echo "PASS test_ab ($PASSED checks)"
