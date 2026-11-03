#!/usr/bin/env bash
# The pipeline offline, end to end: pr-check -> build (stubs) -> [ab.sh stand-in: a REAL diff-fit record] -> predict.sh with
# the REAL CLI -> sign.sh (stub cosign/aws) -> report.sh -> deploy.sh (stub cosign/kubectl) -> judge.sh. The effective-policy
# pin RBD_POLICY_DIGEST (contract 1) at predict, sign and deploy; one verdict per run; the per-run lock.
#   run P: c2 + the 2026-10-30 proof record (auth +0.67 ms)    expected pass, exit 0
#   run B: c3 + a record of auth +6.1 ms (mkfixtures.sh 6)     expected block, exit 1
#   run I: c1 + an A/A record (auth +0 ms) at the real clock (fit 8 days old) expected inconclusive (fit_stale), exit 3
#   run R: c4-like auth change whose record is not in the store  expected exit 2 (no verdict)
#   CI v2 run M: one image for catalog + pricing, A/A records derived per service (ab-catalog/, ab-pricing/) expected pass;
#   run N: predict.sh's v2 refusals (a missing/failed/foreign A/B); sign (every A/B), report (per service), deploy v2 (both
#   services, undo of both on a failed rollout, stale/drift of one refused)
set -uo pipefail
# shellcheck source=tools1/tests/ci/lib.sh
. "$(dirname "$0")/lib.sh"
echo "== flow: predict (real CLI), sign, report, deploy, judge"
mkenv flow
S=$T/src
mkrepo "$S"
mkbaseline
FX=$HERE/fixtures
CH=$HERE/fixtures/changes

prep() { # prep NAME 'branch cmds' RECORD [nostore] -> H = head sha: pr-check + build + the A/B record in place
  H=$(branch "$S" "$1" "$2")
  "$CI/pr-check.sh" "$S" "$(git -C "$S" rev-parse main)" "$H" > "$T/prc-$1.out" 2> "$T/prc-$1.err" || { bad "pr-check $1"; cat "$T/prc-$1.err"; }
  "$CI/build.sh" "$S" "$H" "$(fget "$T/prc-$1.out" service)" > "$T/build-$1.out" 2> "$T/build-$1.err" || { bad "build $1"; cat "$T/build-$1.err"; }
  ab_standin "$H" "$3" "${4:-}"
}
prep p "git apply $CH/c2-auth-small/change.patch" "$FX/ab-record-1ms.json"; P=$H
prep b "git apply $CH/c3-auth-mid/change.patch" "$FX/ab-record-6ms.json"; B=$H
prep i "git apply $CH/c1-noop/change.patch" "$FX/ab-record-0ms.json"; I=$H
prep r "git apply --exclude=rhobound-change.json $CH/c3-auth-mid/change.patch; cp $CH/c2-auth-small/rhobound-change.json .; sed -i 's/20780/20781/' maze/app/internal/work/lib_v11.go" "$FX/ab-record-1ms.json" nostore; R=$H

predict() { # predict RUN [now] -> rc; out in $T/pred-RUN.out
  local rc=0
  if [[ -n ${2:-} ]]; then RBD_TEST_NOW=$2 "$CI/predict.sh" "$1" > "$T/pred-$1.out" 2> "$T/pred-$1.err" || rc=$?
  else "$CI/predict.sh" "$1" > "$T/pred-$1.out" 2> "$T/pred-$1.err" || rc=$?; fi
  echo "$rc"
}
# run P's refusals first: each comes before any verdict, so P can still be gated once (one verdict per run, no re-roll)
pref() { # pref DESC EXPECTED: predict.sh on P refused, exit 2, no verdict kept (no gate/, .gate.tmp, predict.json, policy copy)
  local rc; rc=$(RBD_TEST_NOW=$NOW_FIT "$CI/predict.sh" "$P" > "$T/out" 2> "$T/err"; echo $?)
  local R=$THOME/runs/$P
  if [[ $rc -eq 2 && $(fget "$T/out" ok) == false && ! -e $R/gate && ! -e $R/.gate.tmp && ! -e $R/predict.json ]] &&
    [[ -z $(compgen -G "$R/.policy-gate.*") ]] && grep -q -- "$2" "$T/err"; then ok "predict.sh refuses $1 (exit $rc, no verdict kept)"
  else bad "predict.sh refuses $1: rc=$rc $(tail -n 1 "$T/err")"; fi
}
cp "$THOME/runs/$P/ab/ab.json" "$T/ab.keep"
python3 -I -c 'import json,sys; a=json.load(open(sys.argv[1])); a["cand_digest"]=a["base_digest"]; json.dump(a,open(sys.argv[1],"w"))' \
  "$THOME/runs/$P/ab/ab.json"
pref "an A/B of other images than the run's (ab.json: production vs production)" "the A/B is not this run"
cp "$T/ab.keep" "$THOME/runs/$P/ab/ab.json"
cp "$THOME/runs/$P/policy.json" "$T/policy.keep"
sed -i 's/: 5/: 1000/' "$THOME/runs/$P/policy.json"
pref "a runs/RUN/policy.json that is not the pinned policy" "not the pinned policy"
cp "$T/policy.keep" "$THOME/runs/$P/policy.json"
setpin
pref "when RBD_POLICY_SHA256 is not set in rbd.env" "RBD_POLICY_SHA256"
setpin "$PIN"
setdig
pref "when RBD_POLICY_DIGEST is not set in rbd.env" "RBD_POLICY_DIGEST is not set"
setdig "sha256:${PDIG:7:63}"
pref "when RBD_POLICY_DIGEST is not sha256:<64 hex>" "RBD_POLICY_DIGEST is not set"
setdig "sha256:$(printf other | sha256sum | cut -d' ' -f1)"
pref "when the gate's digest of the policy it applied is not RBD_POLICY_DIGEST (the gate ran; its verdict is dropped)" \
  "not the pinned RBD_POLICY_DIGEST"
setdig "$PDIG"
rcP=$(predict "$P" "$NOW_FIT")
# run B: policy.json is swapped for a lax one (max 1000%) between predict.sh's hash and the gate (round-1 recheck2 finding 2,
# made deterministic by a CLI wrapper that swaps it as the gate starts): the gate reads predict.sh's private copy
# shellcheck disable=SC2016  # written literally: the wrapper expands them
printf '#!/bin/bash\nif [ "$1" = gate ]; then echo "rhobound $*" >> "%s"; sed -i "s/: 5/: 1000/" "%s"; fi\nexec "%s" "$@"\n' \
  "$T/stub/calls.log" "$THOME/runs/$B/policy.json" "$CLI" > "$T/rhobound-swap"
chmod +x "$T/rhobound-swap"
ln -sf "$T/rhobound-swap" "$TROOT/bin/rhobound"
rcB=$(predict "$B" "$NOW_FIT")
ln -sf "$CLI" "$TROOT/bin/rhobound"
gp=$(grep '^rhobound gate ' "$T/stub/calls.log" | tail -n 1 | sed 's/.* --policy \([^ ]*\) .*/\1/')
check "B: policy.json swapped for max 1000% as the gate starts: the gate read predict.sh's private copy (block, its policy digest the pin, the copy removed)" \
  bash -c "[ $rcB -eq 1 ] && grep -q ': 1000' '$THOME/runs/$B/policy.json' && [[ '$gp' == '$THOME/runs/$B/.policy-gate.'* ]] && [ ! -e '$gp' ] &&
  [ \"\$(python3 -I -c 'import json,sys; print(json.load(open(sys.argv[1]))[\"digests\"][\"policy\"])' '$THOME/runs/$B/gate/gate.json')\" = '$PDIG' ]"
cp "$T/policy.keep" "$THOME/runs/$B/policy.json"
rcI=$(predict "$I")   # the real clock
rm -f "$THOME/state/ab/cff5faf972fa19443cf32058b5ec81902d7aa826c53ce64b7eb0612054b6c538.json"
rcR=$(predict "$R" "$NOW_FIT")
cp "$FX/ab-record-1ms.json" "$THOME/state/ab/cff5faf972fa19443cf32058b5ec81902d7aa826c53ce64b7eb0612054b6c538.json"
for x in P B I R; do
  r=${!x}; rc=rc$x
  echo "     run $x ${r:0:12}: predict.sh exit ${!rc}: $(last "$T/pred-$r.out" | cut -c1-230)"
done
check "P: the proof record -> pass, exit 0 (rule $(fget "$T/pred-$P.out" rule))" test "$rcP" -eq 0 -a "$(fget "$T/pred-$P.out" verdict)" = pass
check "P: the real CLI's digest of the pinned policy (gate.json digests.policy) is RBD_POLICY_DIGEST $(cut -c1-19 <<< "$PDIG")... (contract 1)" \
  test "$(fget "$THOME/runs/$P/gate/gate.json" digests.policy)" = "$PDIG"
check "P: change.json is SPEC 0b rule 3 (value = record delta, label measured-ab, evidence = record sha256)" python3 -I -c '
import json,sys,hashlib; c=json.load(open(sys.argv[1])); r=json.load(open(sys.argv[2])); it=c["items"][0]
sys.exit(not (c["schema"]=="rhobound.change/v1" and c["fit"]=="sha256:"+hashlib.sha256(open(sys.argv[3],"rb").read()).hexdigest()
  and it=={"op":"own_ms","service":"auth","value":r["services"][0]["own_ms"]["delta"],"label":"measured-ab",
           "evidence":["sha256:"+hashlib.sha256(open(sys.argv[2],"rb").read()).hexdigest()]}))' \
  "$THOME/runs/$P/change.json" "$FX/ab-record-1ms.json" "$FX/fit.json"
check "B: auth +6.1 ms -> block, exit 1 (rule $(fget "$T/pred-$B.out" rule))" \
  test "$rcB" -eq 1 -a "$(fget "$T/pred-$B.out" verdict)" = block -a "$(fget "$T/pred-$B.out" rule)" = mean_change@storefront
check "I: an A/A record at the real clock -> inconclusive fit_stale, exit 3" \
  test "$rcI" -eq 3 -a "$(fget "$T/pred-$I.out" rule)" = fit_stale
check "R: a record missing from RHOBOUND_STATE -> exit 2, no verdict" \
  test "$rcR" -eq 2 -a -n "$(grep 'not in RHOBOUND_STATE' "$T/pred-$R.err")"
check "P: predict.json names the candidate and baseline digests and sha256(candidate.json) it measured" python3 -I -c '
import json,sys,hashlib; p=json.load(open(sys.argv[1])); c=open(sys.argv[2],"rb").read(); d=json.loads(c)
sys.exit(not (p["candidate_digest"]==d["digest"] and p["baseline_digest"]==d["baseline_digest"]
  and p["candidate_sha256"]=="sha256:"+hashlib.sha256(c).hexdigest()))' "$THOME/runs/$P/predict.json" "$THOME/runs/$P/candidate.json"
# one verdict per run (round-1 recheck1 finding 3): no re-roll of a gated run, whatever its verdict
cp "$THOME/runs/$P/predict.json" "$T/predict.keep"
cp "$THOME/runs/$P/gate/gate.json" "$T/gate.keep"
rc=$(RBD_TEST_NOW=$NOW_FIT "$CI/predict.sh" "$P" > "$T/out" 2> "$T/err"; echo $?)
check "predict.sh again on a run that holds a verdict: refused, a re-gate needs a new commit (exit $rc; gate/ and predict.json unchanged)" \
  bash -c "[ $rc -eq 2 ] && grep -q 'never re-rolled; a re-gate needs a new commit' '$T/err' &&
  cmp -s '$T/predict.keep' '$THOME/runs/$P/predict.json' && cmp -s '$T/gate.keep' '$THOME/runs/$P/gate/gate.json'"
mkdir "$THOME/runs/$R/gate"
rc=$(RBD_TEST_NOW=$NOW_FIT "$CI/predict.sh" "$R" > "$T/out" 2> "$T/err"; echo $?)
check "  also when only gate/ exists (a predict.sh that stopped after the gate; exit $rc)" \
  bash -c "[ $rc -eq 2 ] && grep -q 'already holds a prediction' '$T/err'"
rmdir "$THOME/runs/$R/gate"
lockrun "$THOME/runs/$R/.lock" || bad "lockrun: the holder never took the lock"
rc=$(RBD_TEST_NOW=$NOW_FIT "$CI/predict.sh" "$R" > "$T/out" 2> "$T/err"; echo $?)
unlockrun
check "predict.sh refuses while another step of the same run holds runs/RUN/.lock (exit $rc)" \
  bash -c "[ $rc -eq 2 ] && grep -q 'another step of runs/$R is running' '$T/err'"
git -C "$S" checkout -q p
"$CI/build.sh" "$S" "$P" auth > "$T/out" 2> "$T/err"
rc=$?
check "build.sh again on a predicted run is refused (exit $rc): candidate.json is what predict.sh measured" \
  test "$rc" -eq 1 -a -n "$(grep 'already holds a prediction' "$T/err")"
check "gate/ written by the gate (verdict.txt, gate.json, summary.md) for P and B" \
  test -s "$THOME/runs/$P/gate/gate.json" -a "$(cat "$THOME/runs/$B/gate/verdict.txt")" = block
# the CLI's own refusal of a value that is not the record's delta (why change.json is written by python, bit for bit)
sed 's/"value": [0-9.e-]*/"value": 0.67069319177/' "$THOME/runs/$P/change.json" > "$T/badchange.json"
rhobound predict --fit "$THOME/captures/prod/fit/fit.json" --changes "$T/badchange.json" --json > "$T/badpred.json" 2> /dev/null
brc=$?
rhobound gate "$T/badpred.json" --policy "$REPO0/policy/gate.json" --now "$NOW_FIT" --out "$T/badgate" --json > /dev/null
grc=$?
check "a rounded delta is refused by the CLI (predict exit $brc) and gated inconclusive input_refused (exit $grc)" \
  grep -q 'input_refused:change.label_not_minted' "$T/badgate/gate.json"

echo "== sign"
for r in "$P" "$B" "$I"; do
  "$CI/sign.sh" "$r" > "$T/sign-$r.out" 2> "$T/sign-$r.err" || { bad "sign ${r:0:12}"; cat "$T/sign-$r.err"; }
done
pred=$THOME/runs/$P/predicate.json
check "P: predicate rbd.gate-verdict/v1 has every SPEC 6 field, and services (CI v2) = [its one service]" python3 -I -c '
import json,sys; p=json.load(open(sys.argv[1]))
want={"verdict","rules","advisory","candidate_digest","baseline_digest","service","fit_digest","ab_record_digest","prediction_digest","policy_digest","policy_sha256","git_sha","decided_at","services"}
sys.exit(not (set(p)==want and p["verdict"]=="pass" and p["service"]=="auth" and p["git_sha"]==sys.argv[2] and p["decided_at"]==sys.argv[3]
  and p["services"]==[{"service":"auth","baseline_digest":p["baseline_digest"],"ab_record_digest":p["ab_record_digest"]}]))' \
  "$pred" "$P" "$NOW_FIT"
check "P: predicate policy_sha256 = sha256: + RBD_POLICY_SHA256, policy_digest = the gate's = RBD_POLICY_DIGEST" python3 -I -c '
import json,sys; p=json.load(open(sys.argv[1])); g=json.load(open(sys.argv[2]))
sys.exit(not (p["policy_sha256"]=="sha256:"+sys.argv[3] and p["policy_digest"]==g["digests"]["policy"]==sys.argv[4]))' \
  "$pred" "$THOME/runs/$P/gate/gate.json" "$PIN" "$PDIG"
check "P: prediction_digest = gate digests.report = sha256(prediction.json minus its newline)" python3 -I -c '
import json,sys,hashlib; p=json.load(open(sys.argv[1])); g=json.load(open(sys.argv[2])); b=open(sys.argv[3],"rb").read().rstrip(b"\n")
sys.exit(not (p["prediction_digest"]==g["digests"]["report"]=="sha256:"+hashlib.sha256(b).hexdigest()))' \
  "$pred" "$THOME/runs/$P/gate/gate.json" "$THOME/runs/$P/prediction.json"
key=$(fget "$T/sign-$P.out" ledger_key)
check "P: ledger row in S3 demo1/ledger/<key>.json and in RBD_HOME/ledger, identical" \
  cmp -s "$T/stub/s3/rhobound-research-123456789012-ap-south-1/demo1/ledger/$key.json" "$THOME/ledger/$key.json"
check "P: the ledger row holds no account id" bash -c "! grep -q 123456789012 '$THOME/ledger/$key.json'"
check "sign passed --key \$RBD_KMS --type .../gate-verdict/v1 --tlog-upload=false --yes, image by digest" \
  grep -q "cosign attest --key awskms:///alias/rhobound-demo-verdict --type https://rhobound.dev/attestations/gate-verdict/v1 --predicate .* --tlog-upload=false --yes 123456789012.dkr.ecr.ap-south-1.amazonaws.com/rhobound-demo/maze@sha256:" "$T/stub/calls.log"
check "B and I are signed too (block, inconclusive)" test "$(fget "$T/sign-$B.out" verdict)" = block -a "$(fget "$T/sign-$I.out" verdict)" = inconclusive
"$CI/sign.sh" "$P" > "$T/out" 2> "$T/err"
check "a rerun of sign.sh with the same prediction is a no-op for the ledger (exit $?, s3 $(fget "$T/out" s3))" test "$(fget "$T/out" s3)" = exists
cp "$T/stub/s3/rhobound-research-123456789012-ap-south-1/demo1/ledger/$key.json" "$T/keep.json"
sed -i 's/"pass"/"PASS"/' "$T/stub/s3/rhobound-research-123456789012-ap-south-1/demo1/ledger/$key.json"
"$CI/sign.sh" "$P" > "$T/out" 2> "$T/err"
rc=$?
check "a different row already in S3 for the prediction is refused (write-once; exit $rc)" grep -q "DIFFERENT row" "$T/err"
cp "$T/keep.json" "$T/stub/s3/rhobound-research-123456789012-ap-south-1/demo1/ledger/$key.json"
STUB_COSIGN_VERSION=v3.1.4 "$CI/sign.sh" "$P" > "$T/out" 2> "$T/err"
rc=$?
check "cosign v3 is refused with a clear message (exit $rc)" grep -q "cosign v2.x required" "$T/err"

# sign.sh signs only the image predict.sh measured, under the pinned policy (predict.sh's checks again at signing time)
na=$(grep -c '^cosign attest' "$T/stub/calls.log")
signref() { # signref DESC FILE 'python edit of d' EXPECTED: FILE of run P edited, sign.sh refuses and signs nothing, FILE restored
  local R=$THOME/runs/$P rc
  cp "$R/$2" "$T/keep.f"
  python3 -I -c "import json,sys; d=json.load(open(sys.argv[1])); $3; json.dump(d, open(sys.argv[1], 'w'), indent=1)" "$R/$2"
  "$CI/sign.sh" "$P" > "$T/out" 2> "$T/err"
  rc=$?
  if [[ $rc -eq 1 && $(fget "$T/out" ok) == false && $(grep -c '^cosign attest' "$T/stub/calls.log") -eq $na ]] && grep -q -- "$4" "$T/err"; then
    ok "sign.sh refuses $1 (exit $rc, nothing signed)"
  else bad "sign.sh refuses $1: rc=$rc $(tail -n 1 "$T/err")"; fi
  cp "$T/keep.f" "$R/$2"
}
signref "a candidate.json swapped after predict.sh (another image)" candidate.json \
  'd["digest"]="sha256:"+"e"*64; d["image"]=d["image"].split("@")[0]+"@"+d["digest"]' "changed after predict.sh"
signref "a candidate.json rewritten after predict.sh (same digest, other bytes)" candidate.json 'd["built_at"]="2026-10-30T00:00:00Z"' \
  "changed after predict.sh"
signref "a predict.json of another candidate" predict.json 'd["candidate_digest"]="sha256:"+"e"*64' "is not this candidate"
signref "an A/B that failed (ab.json ok false)" ab/ab.json 'd["ok"]=False' "the A/B is not this run"
signref "an A/B of other images (ab.json: production vs production)" ab/ab.json 'd["cand_digest"]=d["base_digest"]' "the A/B is not this run"
signref "an A/B record that is not change.json's evidence" ab/ab.json 'd["record"]["sha256"]="sha256:"+"0"*64' "is not ab.json's record"
signref "a runs/RUN/policy.json that is not the pinned policy" policy.json 'd["max_entry_mean_change_pct"]=1000' "not the pinned policy"
signref "a gate.json whose policy digest is not RBD_POLICY_DIGEST" gate/gate.json 'd["digests"]["policy"]="sha256:"+"1"*64' \
  "not the pinned RBD_POLICY_DIGEST"
# round-1 recheck2 (t_sign_policy_subset.py): a gate decided with the guards off (doubts_that_hold []) keeps the pinned file's
# two keys, and runs/RUN/policy.json is still the pinned bytes; the real CLI's gate of P's prediction under that policy
printf '{"schema": "rhobound.policy/v1", "max_entry_mean_change_pct": 5, "doubts_that_hold": []}\n' > "$T/guards-off.json"
rhobound gate "$THOME/runs/$P/prediction.json" --policy "$T/guards-off.json" --now "$NOW_FIT" --out "$T/offgate" --json > /dev/null
mv "$THOME/runs/$P/gate" "$T/gate.p"
cp -r "$T/offgate" "$THOME/runs/$P/gate"
"$CI/sign.sh" "$P" > "$T/out" 2> "$T/err"
rc=$?
check "sign.sh refuses a pass the gate decided with the guards off (doubts_that_hold [], the pinned file's 2 keys; exit $rc, nothing signed)" \
  bash -c "[ $rc -eq 1 ] && grep -q 'not the pinned RBD_POLICY_DIGEST' '$T/err' && [ \$(grep -c '^cosign attest' '$T/stub/calls.log') -eq $na ] &&
  [ \"\$(cat '$THOME/runs/$P/gate/verdict.txt')\" = pass ]"
rm -rf "$THOME/runs/$P/gate"
mv "$T/gate.p" "$THOME/runs/$P/gate"
for v in "" "sha256:${PDIG:7:63}"; do
  setdig "$v"
  "$CI/sign.sh" "$P" > "$T/out" 2> "$T/err"
  rc=$?
  w="not set"; [[ -z $v ]] || w="not sha256:<64 hex>"
  check "sign.sh refuses when RBD_POLICY_DIGEST is $w (exit $rc, nothing signed)" bash -c "[ $rc -eq 1 ] &&
    grep -q 'RBD_POLICY_DIGEST is not set' '$T/err' && [ \$(grep -c '^cosign attest' '$T/stub/calls.log') -eq $na ]"
done
setdig "$PDIG"
lockrun "$THOME/runs/$P/.lock" || bad "lockrun: the holder never took the lock"
"$CI/sign.sh" "$P" > "$T/out" 2> "$T/err"
rc=$?
unlockrun
check "sign.sh refuses while another step of the same run holds runs/RUN/.lock (exit $rc, nothing signed)" bash -c "[ $rc -eq 1 ] &&
  grep -q 'another step of runs/$P is running' '$T/err' && [ \$(grep -c '^cosign attest' '$T/stub/calls.log') -eq $na ]"
setpin
"$CI/sign.sh" "$P" > "$T/out" 2> "$T/err"
rc=$?
check "sign.sh refuses when RBD_POLICY_SHA256 is not set in rbd.env (exit $rc, nothing signed)" bash -c "[ $rc -eq 1 ] &&
  grep -q RBD_POLICY_SHA256 '$T/err' && [ \$(grep -c '^cosign attest' '$T/stub/calls.log') -eq $na ]"
setpin "$PIN"
STUB_ATTEST_FAIL=1 "$CI/sign.sh" "$P" > "$T/out" 2> "$T/err"
rc=$?
"$CI/report.sh" "$P" > "$T/rep-unsigned.out" 2> /dev/null
check "a failed cosign attest: sign.sh exit $rc, and the report says NOT signed" bash -c "[ $rc -eq 1 ] &&
  grep -q 'NOT signed' '$T/rep-unsigned.out' && [ \"\$(tail -n 1 '$T/rep-unsigned.out' | python3 -I -c 'import json,sys; print(json.load(sys.stdin)[\"signed\"])')\" = False ]"
"$CI/sign.sh" "$P" > "$T/out" 2> "$T/err"
check "sign.sh again after the failure: signed (exit $?)" test -s "$THOME/runs/$P/sign.json"
echo "== report"
for r in "$P" "$B" "$I"; do "$CI/report.sh" "$r" > "$T/rep-$r.out" 2> "$T/rep-$r.err" || { bad "report ${r:0:12}"; cat "$T/rep-$r.err"; }; done
check "P: the summary starts with the verdict" test "$(head -n 1 "$T/rep-$P.out")" = "# rhobound gate: PASS (advisory)"
check "P: the report says signed (sign.json of this prediction)" grep -q '^Signed: yes' "$T/rep-$P.out"
check "P: entries table, A/B delta +- SE, digests, the verify command" bash -c "grep -q '^| storefront | 67.948 | ' '$T/rep-$P.out' &&
  grep -q 'delta +0.671 +- 0.060 ms' '$T/rep-$P.out' && grep -q 'RBD_ECR@sha256:' '$T/rep-$P.out' &&
  grep -q 'cosign verify-attestation --key \"\$RBD_KMS\"' '$T/rep-$P.out'"
check "B: BLOCK by mean_change at storefront, entries over the threshold" bash -c "head -n 1 '$T/rep-$B.out' | grep -q BLOCK &&
  grep -q 'rule 10 .mean_change. at storefront' '$T/rep-$B.out' && grep -q '| 3.397 | over |' '$T/rep-$B.out'"
check "report's last line is JSON with verdict and rule (what gate.yml reads)" \
  test "$(fget <(last "$T/rep-$B.out") verdict)/$(fget <(last "$T/rep-$B.out") rule)" = "block/mean_change@storefront"
check "no account id anywhere in the summaries" bash -c "! grep -q 123456789012 '$T/rep-$P.out' '$T/rep-$B.out' '$T/rep-$I.out'"
sed -n '1,12p' "$T/rep-$B.out" | sed 's/^/     | /'

echo "== deploy"
dep() { RBD_SETTLE_S=${RBD_SETTLE_S:-0} "$CI/deploy.sh" "$@" > "$T/dep.out" 2> "$T/dep.err"; echo $?; }
nset() { grep -c "kubectl -n maze set image" "$T/stub/calls.log"; }
n0=$(nset)
rc=$(dep --run "$B")
check "refuses the signed BLOCK (exit $rc: $(fget "$T/dep.out" error | cut -c1-70))" test "$rc" -eq 1 -a "$(nset)" -eq "$n0"
rc=$(dep --run "$I")
check "refuses the signed INCONCLUSIVE (exit $rc)" test "$rc" -eq 1 -a "$(nset)" -eq "$n0"
PD=$(python3 -I -c 'import json,sys; print(json.load(open(sys.argv[1]))["digest"])' "$THOME/runs/$P/candidate.json")
rc=$(dep payments "$PD")
check "refuses a pass for auth deployed as payments (exit $rc: $(fget "$T/dep.out" error | cut -c1-60))" test "$rc" -eq 1 -a "$(nset)" -eq "$n0"
rc=$(dep auth "sha256:$(printf x | sha256sum | cut -d' ' -f1)")
check "refuses an image with no attestation (exit $rc)" test "$rc" -eq 1 -a "$(nset)" -eq "$n0"
cp "$THOME/baseline.json" "$T/baseline.keep"
python3 -I -c 'import json,sys; b=json.load(open(sys.argv[1])); b["services"]["auth"]="sha256:"+"e"*64; json.dump(b,open(sys.argv[1],"w"))' "$THOME/baseline.json"
rc=$(dep --run "$P")
check "refuses a stale pass: production moved since the gate (exit $rc: $(fget "$T/dep.out" error | cut -c1-50))" test "$rc" -eq 1 -a "$(nset)" -eq "$n0"
cp "$T/baseline.keep" "$THOME/baseline.json"
cp "$T/stub/k8s/auth.image" "$T/auth.keep"
echo -n "123456789012.dkr.ecr.ap-south-1.amazonaws.com/rhobound-demo/maze@sha256:$(printf y | sha256sum | cut -d' ' -f1)" > "$T/stub/k8s/auth.image"
rc=$(dep --run "$P")
check "refuses when the Deployment does not run baseline.json's image (drift; exit $rc)" test "$rc" -eq 1 -a "$(nset)" -eq "$n0"
cp "$T/auth.keep" "$T/stub/k8s/auth.image"
# a digest that carries a pass AND a block: never deployed
MX=sha256:$(printf mixed | sha256sum | cut -d' ' -f1)
python3 -I -c 'import json,sys; p=json.load(open(sys.argv[1])); p["candidate_digest"]=sys.argv[3]; json.dump(p,open(sys.argv[2]+"/pass.json","w"))
p["verdict"]="block"; json.dump(p,open(sys.argv[2]+"/block.json","w"))' "$pred" "$T" "$MX"
for v in pass block; do
  cosign attest --key awskms:///alias/rhobound-demo-verdict --type https://rhobound.dev/attestations/gate-verdict/v1 \
    --predicate "$T/$v.json" --tlog-upload=false --yes "123456789012.dkr.ecr.ap-south-1.amazonaws.com/rhobound-demo/maze@$MX"
done
rc=$(dep auth "$MX")
check "refuses a digest that has a pass and a block (exit $rc: $(fget "$T/dep.out" error | cut -c1-50))" test "$rc" -eq 1 -a "$(nset)" -eq "$n0"
# the pinned policy at the deploy point: the predicate's policy_sha256 and policy_digest, the run's policy.json, the pin itself
attest_pass() { # attest_pass DIGEST 'python edit of p': P's pass predicate for DIGEST, edited, signed by the stub
  python3 -I -c "import json,sys; p=json.load(open(sys.argv[1])); p['candidate_digest']=sys.argv[3]; $2; json.dump(p,open(sys.argv[2],'w'))" \
    "$pred" "$T/pp.json" "$1"
  cosign attest --key awskms:///alias/rhobound-demo-verdict --type https://rhobound.dev/attestations/gate-verdict/v1 \
    --predicate "$T/pp.json" --tlog-upload=false --yes "123456789012.dkr.ecr.ap-south-1.amazonaws.com/rhobound-demo/maze@$1"
}
deref() { # deref DESC EXPECTED ARGS...: deploy.sh refuses, nothing set
  local rc; rc=$(dep "${@:3}")
  check "refuses $1 (exit $rc: $(fget "$T/dep.out" error | cut -c1-60))" bash -c "[ $rc -eq 1 ] && [ $(nset) -eq $n0 ] && grep -q -- '$2' '$T/dep.err'"
}
X1=sha256:$(printf pol1 | sha256sum | cut -d' ' -f1)
attest_pass "$X1" 'p["policy_sha256"]="sha256:"+"0"*64'
deref "a pass decided under another policy (policy_sha256 is not the pin)" "not the pinned policy" auth "$X1"
X2=sha256:$(printf pol2 | sha256sum | cut -d' ' -f1)
attest_pass "$X2" 'p.pop("policy_sha256")'
deref "a pass that names no policy_sha256" "not the pinned policy" auth "$X2"
X3=sha256:$(printf pol3 | sha256sum | cut -d' ' -f1)
attest_pass "$X3" 'p["policy_digest"]="sha256:"+"1"*64'
deref "a pass whose policy_digest is not RBD_POLICY_DIGEST" "policy_digest .* is not the pinned effective policy" auth "$X3"
# round-1 recheck1 PoC (poc_forged_deploy.sh): rbd-written run files that agree with the signed predicate (runs/F/policy.json
# the pinned bytes, runs/F/gate/gate.json naming the predicate's policy_digest): that comparison was circular; the pin is not
F=$(printf forged | sha1sum | cut -d' ' -f1)
mkdir -p "$THOME/runs/$F/gate"
cp "$REPO0/policy/gate.json" "$THOME/runs/$F/policy.json"
printf '{"digests":{"policy":"sha256:%s"}}\n' "$(printf forged | sha256sum | cut -d' ' -f1)" > "$THOME/runs/$F/gate/gate.json"
X4=sha256:$(printf never-measured | sha256sum | cut -d' ' -f1)
attest_pass "$X4" "p['git_sha']='$F'; p['policy_digest']='sha256:$(printf forged | sha256sum | cut -d' ' -f1)'; p['decided_at']='2099-01-01T00:00:00Z'"
deref "a forged pass whose policy_digest matches its own run's gate.json but not RBD_POLICY_DIGEST" \
  "is not the pinned effective policy RBD_POLICY_DIGEST" auth "$X4"
cp "$THOME/runs/$P/policy.json" "$T/policy.keep"
sed -i 's/: 5/: 1000/' "$THOME/runs/$P/policy.json"
deref "when runs/<git_sha>/policy.json is not the pinned policy" "policy.json is missing or not the pinned" --run "$P"
cp "$T/policy.keep" "$THOME/runs/$P/policy.json"
setpin
deref "when RBD_POLICY_SHA256 is not set in rbd.env" "RBD_POLICY_SHA256" --run "$P"
setpin "$PIN"
setdig
deref "when RBD_POLICY_DIGEST is not set in rbd.env" "RBD_POLICY_DIGEST is not set" --run "$P"
setdig "sha256:${PDIG:7:63}"
deref "when RBD_POLICY_DIGEST is not sha256:<64 hex>" "RBD_POLICY_DIGEST is not set" --run "$P"
setdig "$PDIG"
STUB_ROLLOUT_RC=1 dep --run "$P" > /dev/null
check "a failed rollout is undone, baseline.json unchanged, exit 1" bash -c "grep -q 'rollout undo deployment/auth' '$T/stub/calls.log' &&
  cmp -s '$T/baseline.keep' '$THOME/baseline.json' && cmp -s '$T/auth.keep' '$T/stub/k8s/auth.image'"
echo 1000 > "$T/stub/k8s/auth.terminating"
rc=$(RBD_POD_WAIT_S=2 dep --run "$P")
check "an old auth pod that never goes away: refused before the refit (exit $rc), baseline.json unchanged, no refit" bash -c "[ $rc -eq 1 ] &&
  grep -q 'still has pods of another image' '$T/dep.err' && cmp -s '$T/baseline.keep' '$THOME/baseline.json' && ! grep -q '^refit ' '$T/stub/calls.log'"
cp "$T/auth.keep" "$T/stub/k8s/auth.image"   # production as it was (the stub's rollout is not undone on this refusal)
rm -f "$T/stub/k8s/auth.prev"
echo 3 > "$T/stub/k8s/auth.terminating"
rc=$(dep --run "$P")
check "ACCEPTS the signed pass (exit $rc)" test "$rc" -eq 0
check "deploy waited for the terminating old pod before the refit (3 polls with it, then only the new image)" \
  test "$(grep -c 'kubectl -n maze get pods -l app=auth' "$T/stub/calls.log")" -ge 4
check "then the settle for the old image's spans to leave the trace files (RBD_SETTLE_S, 240 s under sudo), before refit.sh" \
  grep -q "waiting 0 s for the old image's spans to leave the trace files" "$T/dep.err"
check "kubectl set image deployment/auth auth=RBD_ECR@<candidate digest>" \
  grep -q "kubectl -n maze set image deployment/auth auth=123456789012.dkr.ecr.ap-south-1.amazonaws.com/rhobound-demo/maze@$PD" "$T/stub/calls.log"
check "verify-attestation used the KMS key, the type and --insecure-ignore-tlog=true" grep -q \
  "cosign verify-attestation --key awskms:///alias/rhobound-demo-verdict --type https://rhobound.dev/attestations/gate-verdict/v1 --insecure-ignore-tlog=true" "$T/stub/calls.log"
check "baseline.json now names the candidate for auth (other services unchanged)" python3 -I -c '
import json,sys; a=json.load(open(sys.argv[1])); b=json.load(open(sys.argv[2]))
sys.exit(not (a["services"]["auth"]==sys.argv[3] and {k:v for k,v in a["services"].items() if k!="auth"}=={k:v for k,v in b["services"].items() if k!="auth"} and a["fit"]==b["fit"]))' \
  "$THOME/baseline.json" "$T/baseline.keep" "$PD"
check "refit.sh ran inside deploy's lock (nested, part B's lock.sh) with a NAME refit.sh accepts" \
  grep -q "^refit deploy-auth-.* lock=nested name=ok$" "$T/stub/calls.log"
rc=$(dep --run "$P")
check "a second deploy of the same pass: already deployed, no second refit (exit $rc)" \
  test "$rc" -eq 0 -a "$(fget "$T/dep.out" already_deployed)" = true -a "$(grep -c '^refit ' "$T/stub/calls.log")" -eq 1

echo "== CI v2: one image for catalog + pricing (pr-check v2, build, one A/B each, predict, sign, report, deploy)"
for s in catalog pricing; do
  derive_record "$FX/ab-record-0ms.json" "$s" "$T/rec-$s-0.json"
  derive_record "$FX/ab-record-1ms.json" "$s" "$T/rec-$s-1.json"
done
v2prep() { # v2prep NAME -> H: a v2 request of catalog + pricing with a maze/app change; pr-check and build (no A/B yet)
  H=$(branch "$S" "$1" "echo '// $1' >> maze/app/internal/work/lib_v11.go; v2req '[\"catalog\", \"pricing\"]'")
  "$CI/pr-check.sh" "$S" "$(git -C "$S" rev-parse main)" "$H" > "$T/prc-$1.out" 2> "$T/prc-$1.err" || { bad "pr-check $1"; cat "$T/prc-$1.err"; }
  "$CI/build.sh" "$S" "$H" catalog > "$T/build-$1.out" 2> "$T/build-$1.err" || { bad "build $1"; cat "$T/build-$1.err"; }
}
v2prep m; M=$H
ab_standin_svc "$M" catalog "$T/rec-catalog-0.json"
ab_standin_svc "$M" pricing "$T/rec-pricing-0.json"
# leftovers predict.sh must not count: an earlier A/B moved aside (ab-catalog.old-*, even ok), a failed ab/ (ok false)
mkdir -p "$THOME/runs/$M/ab-catalog.old-20261030T010203Z" "$THOME/runs/$M/ab"
echo '{"ok": true, "service": "auth"}' > "$THOME/runs/$M/ab-catalog.old-20261030T010203Z/ab.json"
echo '{"ok": false, "service": "catalog", "stage": "driver"}' > "$THOME/runs/$M/ab/ab.json"
v2prep n; N=$H
v2pref() { # v2pref DESC EXPECTED: predict.sh on N refused, exit 2, no verdict kept
  local rc; rc=$(RBD_TEST_NOW=$NOW_FIT "$CI/predict.sh" "$N" > "$T/out" 2> "$T/err"; echo $?)
  if [[ $rc -eq 2 && ! -e $THOME/runs/$N/gate && ! -e $THOME/runs/$N/predict.json ]] && grep -q -- "$2" "$T/err"; then
    ok "predict.sh v2 refuses $1 (exit $rc, no verdict kept)"
  else bad "predict.sh v2 refuses $1: rc=$rc $(tail -n 1 "$T/err")"; fi
}
ab_standin_svc "$N" catalog "$T/rec-catalog-0.json"
v2pref "a request of catalog + pricing with only catalog's A/B" "no A/B record of pricing that is ok"
ab_standin_svc "$N" pricing "$T/rec-pricing-0.json"
python3 -I -c 'import json,sys; a=json.load(open(sys.argv[1])); a["ok"]=False; json.dump(a,open(sys.argv[1],"w"))' "$THOME/runs/$N/ab-pricing/ab.json"
v2pref "pricing's A/B that failed (ab.json ok false)" "no A/B record of pricing that is ok"
ab_standin_svc "$N" pricing "$T/rec-pricing-0.json"
python3 -I -c 'import json,sys; a=json.load(open(sys.argv[1])); a["cand_digest"]=a["base_digest"]; json.dump(a,open(sys.argv[1],"w"))' "$THOME/runs/$N/ab-pricing/ab.json"
v2pref "pricing's A/B of other images (production vs production)" "the A/B is not this run's: ab-pricing/ab.json"
ab_standin_svc "$N" pricing "$T/rec-catalog-0.json"
v2pref "an ab-pricing/ whose record measures catalog" "does not measure pricing"
ab_standin_svc "$N" pricing "$T/rec-pricing-0.json"
ab_standin_svc "$N" catalog "$T/rec-catalog-1.json" "" ab
v2pref "two ok A/Bs of catalog (ab/ and ab-catalog/)" "two A/Bs of catalog"
rm -rf "${THOME:?}/runs/$N/ab"
ab_standin_svc "$N" catalog "$T/rec-catalog-0.json" "" ab-pricing
v2pref "an ab-pricing/ folder holding catalog's A/B" "an ab-<service>/ folder holds that service's A/B only"
ab_standin_svc "$N" pricing "$T/rec-pricing-0.json"
ab_standin_svc "$N" pricing "$T/rec-pricing-1.json" nostore
v2pref "pricing's record missing from RHOBOUND_STATE" "not in RHOBOUND_STATE"
cp "$THOME/baseline.json" "$T/baseline.v2keep"
python3 -I -c 'import json,sys; b=json.load(open(sys.argv[1])); b["services"]["pricing"]="sha256:"+"e"*64; json.dump(b,open(sys.argv[1],"w"))' "$THOME/baseline.json"
ab_standin_svc "$N" pricing "$T/rec-pricing-0.json"
v2pref "when pricing's production moved since the build" "production moved since the build: baseline.json pricing"
cp "$T/baseline.v2keep" "$THOME/baseline.json"
rcM=$(predict "$M" "$NOW_FIT")
echo "     run M ${M:0:12}: predict.sh exit $rcM: $(last "$T/pred-$M.out" | cut -c1-200)"
check "M: catalog + pricing A/A records -> pass, exit 0 (rule $(fget "$T/pred-$M.out" rule))" \
  test "$rcM" -eq 0 -a "$(fget "$T/pred-$M.out" verdict)" = pass
check "M: change.json = one measured-ab item per service (catalog, pricing), each its record's delta and digest" python3 -I -c '
import json,sys,hashlib; c=json.load(open(sys.argv[1])); its=c["items"]
want=[]
for s,f in (("catalog",sys.argv[2]),("pricing",sys.argv[3])):
    b=open(f,"rb").read(); r=json.loads(b)
    want.append({"op":"own_ms","service":s,"value":r["services"][0]["own_ms"]["delta"],"label":"measured-ab","evidence":["sha256:"+hashlib.sha256(b).hexdigest()]})
sys.exit(not its==want)' "$THOME/runs/$M/change.json" "$T/rec-catalog-0.json" "$T/rec-pricing-0.json"
check "M: predict.json services = catalog (ab-catalog/) and pricing (ab-pricing/), each with its production digest; the old/failed folders ignored" python3 -I -c '
import json,sys; p=json.load(open(sys.argv[1])); c=json.load(open(sys.argv[2]))
sys.exit(not ([(x["service"],x["ab_dir"],x["baseline_digest"]) for x in p["services"]]==[("catalog","ab-catalog",c["baselines"]["catalog"]),
  ("pricing","ab-pricing",c["baselines"]["pricing"])] and p["service"]=="catalog" and p["record_digest"]==p["services"][0]["record_digest"]))' \
  "$THOME/runs/$M/predict.json" "$THOME/runs/$M/candidate.json"
"$CI/sign.sh" "$M" > "$T/sign-$M.out" 2> "$T/sign-$M.err" || { bad "sign M"; cat "$T/sign-$M.err"; }
check "M: predicate services = [{catalog, its baseline}, {pricing, its baseline}] for the one candidate digest; v1 fields = catalog's" python3 -I -c '
import json,sys; p=json.load(open(sys.argv[1])); c=json.load(open(sys.argv[2])); j=json.load(open(sys.argv[3]))
sys.exit(not (p["verdict"]=="pass" and p["candidate_digest"]==c["digest"] and p["service"]=="catalog" and p["baseline_digest"]==c["baselines"]["catalog"]
  and [(x["service"],x["baseline_digest"],x["ab_record_digest"]) for x in p["services"]]==[(x["service"],x["baseline_digest"],x["record_digest"]) for x in j["services"]]
  and p["ab_record_digest"]==j["services"][0]["record_digest"]))' "$THOME/runs/$M/predicate.json" "$THOME/runs/$M/candidate.json" "$THOME/runs/$M/predict.json"
na=$(grep -c '^cosign attest' "$T/stub/calls.log")
cp "$THOME/runs/$M/ab-pricing/ab.json" "$T/abp.keep"
python3 -I -c 'import json,sys; a=json.load(open(sys.argv[1])); a["cand_digest"]="sha256:"+"e"*64; json.dump(a,open(sys.argv[1],"w"))' "$THOME/runs/$M/ab-pricing/ab.json"
"$CI/sign.sh" "$M" > "$T/out" 2> "$T/err"
rc=$?
check "sign.sh checks every A/B: pricing's ab.json of another candidate is refused (exit $rc, nothing signed)" bash -c "[ $rc -eq 1 ] &&
  grep -q 'the A/B is not this run.s: ab-pricing/ab.json' '$T/err' && [ \$(grep -c '^cosign attest' '$T/stub/calls.log') -eq $na ]"
cp "$T/abp.keep" "$THOME/runs/$M/ab-pricing/ab.json"
"$CI/sign.sh" "$M" > "$T/out" 2> "$T/err"
check "  and signs again once restored (exit $?)" test "$(fget "$T/out" ok)" = True -o "$(fget "$T/out" ok)" = true
"$CI/report.sh" "$M" > "$T/rep-$M.out" 2> "$T/rep-$M.err" || { bad "report M"; cat "$T/rep-$M.err"; }
check "M: the report names both services and has one A/B line set per service" bash -c "grep -q '^Services .catalog., .pricing. (one image for all' '$T/rep-$M.out' &&
  grep -q '^- catalog own time per visit: .*delta +0.000' '$T/rep-$M.out' && grep -q '^- pricing own time per visit: ' '$T/rep-$M.out' &&
  grep -q 'record findings (pricing, .ab-pricing/.)' '$T/rep-$M.out' && grep -q 'production image of pricing (baseline)' '$T/rep-$M.out'"
check "  report's last line lists services [catalog, pricing]" test "$(fget <(last "$T/rep-$M.out") services)" = '["catalog", "pricing"]'
DM=$(python3 -I -c 'import json,sys; print(json.load(open(sys.argv[1]))["digest"])' "$THOME/runs/$M/candidate.json")
cp "$THOME/baseline.json" "$T/baseline.v2keep"
cp "$T/stub/k8s/catalog.image" "$T/catalog.keep"
cp "$T/stub/k8s/pricing.image" "$T/pricing.keep"
n0=$(nset)
deref "a v2 pass for catalog + pricing deployed as auth" "is for service .catalog,pricing., not .auth." auth "$DM"
echo -n "123456789012.dkr.ecr.ap-south-1.amazonaws.com/rhobound-demo/maze@sha256:$(printf z | sha256sum | cut -d' ' -f1)" > "$T/stub/k8s/pricing.image"
deref "a v2 pass when pricing's Deployment drifted from baseline.json" "deployment/pricing runs" --run "$M"
cp "$T/pricing.keep" "$T/stub/k8s/pricing.image"
python3 -I -c 'import json,sys; b=json.load(open(sys.argv[1])); b["services"]["pricing"]="sha256:"+"e"*64; json.dump(b,open(sys.argv[1],"w"))' "$THOME/baseline.json"
deref "a v2 pass when pricing's production moved since the gate (stale for one of its services)" "stale verdict: pricing" --run "$M"
cp "$T/baseline.v2keep" "$THOME/baseline.json"
STUB_ROLLOUT_FAIL=pricing dep --run "$M" > /dev/null
check "a failed rollout of pricing undoes catalog's too (both images as before), baseline.json unchanged, no refit" bash -c "
  grep -q 'rollout undo deployment/pricing' '$T/stub/calls.log' && grep -q 'rollout undo deployment/catalog' '$T/stub/calls.log' &&
  cmp -s '$T/catalog.keep' '$T/stub/k8s/catalog.image' && cmp -s '$T/pricing.keep' '$T/stub/k8s/pricing.image' &&
  cmp -s '$T/baseline.v2keep' '$THOME/baseline.json' && [ \$(grep -c '^refit ' '$T/stub/calls.log') -eq 1 ]"
rm -f "$T/stub/k8s/catalog.prev" "$T/stub/k8s/pricing.prev"
nr=$(grep -c '^refit ' "$T/stub/calls.log")
rc=$(dep pricing "$DM")
check "ACCEPTS the signed v2 pass (called as pricing, the second service; exit $rc): the one digest to catalog AND pricing" bash -c "[ $rc -eq 0 ] &&
  grep -q 'kubectl -n maze set image deployment/catalog catalog=123456789012.dkr.ecr.ap-south-1.amazonaws.com/rhobound-demo/maze@$DM' '$T/stub/calls.log' &&
  grep -q 'kubectl -n maze set image deployment/pricing pricing=123456789012.dkr.ecr.ap-south-1.amazonaws.com/rhobound-demo/maze@$DM' '$T/stub/calls.log'"
check "  baseline.json: catalog and pricing at the candidate, every other service unchanged; one refit; deploy.json lists both" python3 -I -c '
import json,sys; a=json.load(open(sys.argv[1])); b=json.load(open(sys.argv[2])); d=sys.argv[3]; dj=json.load(open(sys.argv[4]))
sys.exit(not (a["services"]["catalog"]==d and a["services"]["pricing"]==d and {k:v for k,v in a["services"].items() if k not in ("catalog","pricing")}
  =={k:v for k,v in b["services"].items() if k not in ("catalog","pricing")} and a["last_deploy"]["services"]==["catalog","pricing"]
  and dj["services"]==["catalog","pricing"] and int(sys.argv[5])==int(sys.argv[6])+1))' \
  "$THOME/baseline.json" "$T/baseline.v2keep" "$DM" "$THOME/runs/$M/deploy.json" "$(grep -c '^refit ' "$T/stub/calls.log")" "$nr"
rc=$(dep --run "$M")
check "a second deploy of the v2 pass: already deployed to both, no second refit (exit $rc)" \
  test "$rc" -eq 0 -a "$(fget "$T/dep.out" already_deployed)" = true -a "$(grep -c '^refit ' "$T/stub/calls.log")" -eq $((nr + 1))

echo "== multi-image: auth + catalog + pricing (images auth and hot): one build each, one A/B each, predict, sign every image, deploy each to its own"
derive_record "$FX/ab-record-0ms.json" auth "$T/rec-auth-0.json"
miprep() { # miprep NAME -> H: a v2 request of auth + catalog + pricing (two images); pr-check and build
  H=$(branch "$S" "$1" "echo '// $1' >> maze/app/internal/work/lib_v11.go; v2req '[\"auth\", \"catalog\", \"pricing\"]'")
  "$CI/pr-check.sh" "$S" "$(git -C "$S" rev-parse main)" "$H" > "$T/prc-$1.out" 2> "$T/prc-$1.err" || { bad "pr-check $1"; cat "$T/prc-$1.err"; }
  "$CI/build.sh" "$S" "$H" auth > "$T/build-$1.out" 2> "$T/build-$1.err" || { bad "build $1"; cat "$T/build-$1.err"; }
}
miprep mi; MI=$H
check "MI: two builds (tags auth-<sha> and catalog-<sha>): auth's digest is not catalog's, catalog's = pricing's; every record and the last line map them" python3 -I -c '
import json,sys,os
run,out,sha=sys.argv[1:4]; c={s: json.load(open(os.path.join(run,"candidate-%s.json"%s))) for s in ("auth","catalog","pricing")}
o=json.loads(open(out).read().splitlines()[-1]); top=json.load(open(os.path.join(run,"candidate.json")))
d={s: c[s]["digest"] for s in c}
ok=(d["auth"]!=d["catalog"] and d["catalog"]==d["pricing"] and c["auth"]["tag"]=="auth-"+sha and c["pricing"]["tag"]=="catalog-"+sha
    and all(c[s]["digests"]==d for s in c) and set(c["auth"]["images"])=={"auth","hot"}
    and c["auth"]["images"]["hot"]=={"digest":d["catalog"],"tag":"catalog-"+sha,"services":["catalog","pricing"]}
    and o["digests"]==d and o["digest"]==d["auth"] and top==c["auth"])
sys.exit(not ok)' "$THOME/runs/$MI" "$T/build-mi.out" "$MI"
check "  docker built cmd/auth and cmd/hot once each" bash -c "[ \$(grep -c 'docker build.*CMD=auth' '$T/stub/calls.log') -ge 1 ] && [ \$(grep -c 'docker build.*CMD=hot' '$T/stub/calls.log') -ge 1 ]"
miprep mj; MJ=$H
for s in auth catalog pricing; do ab_standin_svc "$MJ" "$s" "$T/rec-$s-0.json"; done
python3 -I -c 'import json,sys; a=json.load(open(sys.argv[1])); b=json.load(open(sys.argv[2])); a["cand_digest"]=b["digest"]; json.dump(a,open(sys.argv[1],"w"))' \
  "$THOME/runs/$MJ/ab-auth/ab.json" "$THOME/runs/$MJ/candidate-catalog.json"
rc=$(RBD_TEST_NOW=$NOW_FIT "$CI/predict.sh" "$MJ" > "$T/out" 2> "$T/err"; echo $?)
check "predict.sh refuses an A/B of auth that measured catalog's image (exit $rc, no verdict kept)" bash -c "[ $rc -eq 2 ] &&
  [ ! -e '$THOME/runs/$MJ/gate' ] && grep -q 'the A/B is not this run.s: ab-auth/ab.json' '$T/err'"
for s in auth catalog pricing; do ab_standin_svc "$MI" "$s" "$T/rec-$s-0.json"; done
rcMI=$(predict "$MI" "$NOW_FIT")
check "MI: A/A records of all three -> pass, exit 0 (rule $(fget "$T/pred-$MI.out" rule))" test "$rcMI" -eq 0 -a "$(fget "$T/pred-$MI.out" verdict)" = pass
check "MI: predict.json candidate_digests = candidate.json's digests; each services entry names its own candidate digest" python3 -I -c '
import json,sys; p=json.load(open(sys.argv[1])); c=json.load(open(sys.argv[2]))
sys.exit(not (p["candidate_digests"]==c["digests"] and [(x["service"],x["candidate_digest"]) for x in p["services"]]==[(s,c["digests"][s]) for s in ("auth","catalog","pricing")]))' \
  "$THOME/runs/$MI/predict.json" "$THOME/runs/$MI/candidate.json"
na=$(grep -c '^cosign attest' "$T/stub/calls.log")
"$CI/sign.sh" "$MI" > "$T/sign-$MI.out" 2> "$T/sign-$MI.err" || { bad "sign MI"; cat "$T/sign-$MI.err"; }
DA=$(python3 -I -c 'import json,sys; print(json.load(open(sys.argv[1]))["digests"]["auth"])' "$THOME/runs/$MI/candidate.json")
DH=$(python3 -I -c 'import json,sys; print(json.load(open(sys.argv[1]))["digests"]["catalog"])' "$THOME/runs/$MI/candidate.json")
check "MI: sign.sh attests both images (two cosign attest calls), the predicate names every service's digest" bash -c "
  [ \$(grep -c '^cosign attest' '$T/stub/calls.log') -eq $((na + 2)) ] && grep -q 'cosign attest.*@$DA' '$T/stub/calls.log' &&
  grep -q 'cosign attest.*@$DH' '$T/stub/calls.log'" 
check "  predicate candidate_digests and services[].candidate_digest; ledger row images = both" python3 -I -c '
import json,sys; p=json.load(open(sys.argv[1])); r=json.load(open(sys.argv[2])); c=json.load(open(sys.argv[3]))
sys.exit(not (p["candidate_digests"]==c["digests"] and p["candidate_digest"]==c["digests"]["auth"]
  and [x["candidate_digest"] for x in p["services"]]==[c["digests"][s] for s in ("auth","catalog","pricing")]
  and r["images"]==sorted("RBD_ECR@"+d for d in set(c["digests"].values()))))' \
  "$THOME/runs/$MI/predicate.json" "$THOME/runs/$MI/ledger-row.json" "$THOME/runs/$MI/candidate.json"
cp "$THOME/baseline.json" "$T/baseline.mikeep"
for s in auth catalog pricing; do cp "$T/stub/k8s/$s.image" "$T/$s.mikeep"; done
n0=$(nset)
mv "$STUB_DIR/att/${DH#sha256:}.jsonl" "$T/att-hot.keep"
deref "a multi-image pass when one of its images (hot) carries no attestation" "no attestation of type .* verifies on $DH" --run "$MI"
mv "$T/att-hot.keep" "$STUB_DIR/att/${DH#sha256:}.jsonl"
rc=$(dep --run "$MI")
check "ACCEPTS the signed multi-image pass (exit $rc: $(fget "$T/dep.out" error | cut -c1-80))" test "$rc" -eq 0
check "  each Deployment runs its own digest; baseline.json maps each service to it; last_deploy.digests" python3 -I -c '
import json,sys,os; k8s,base,da,dh=sys.argv[1:5]; b=json.load(open(base))
img=lambda s: open(os.path.join(k8s,s+".image")).read().strip().split("@")[-1]
sys.exit(not (img("auth")==da and img("catalog")==dh and img("pricing")==dh and b["services"]["auth"]==da
  and b["services"]["catalog"]==dh and b["services"]["pricing"]==dh and b["last_deploy"]["digests"]=={"auth":da,"catalog":dh,"pricing":dh}))' \
  "$T/stub/k8s" "$THOME/baseline.json" "$DA" "$DH"
cp "$T/baseline.mikeep" "$THOME/baseline.json"
for s in auth catalog pricing; do cp "$T/$s.mikeep" "$T/stub/k8s/$s.image"; rm -f "$T/stub/k8s/$s.prev"; done
echo "== judge (stub)"
"$CI/judge.sh" "$P" > "$T/out" 2> "$T/err"
rc=$?
check "judge.sh without JUDGE_CMD: exit 2, 'not configured' (exit $rc)" test "$rc" -eq 2 -a -n "$(grep 'not configured' "$T/err")"
printf '#!/bin/sh\necho "{}"\n' > "$T/provider.sh"
chmod +x "$T/provider.sh"
echo "export JUDGE_CMD=$T/provider.sh" >> "$TROOT/lib/rbd-env.sh"
RBD_TEST_NOW=$NOW_FIT "$CI/judge.sh" "$P" > "$T/out" 2> "$T/err"
rc=$?
check "judge.sh with a provider that answers {}: packet written, judge-check refuses, exit 1 (exit $rc)" \
  test "$rc" -eq 1 -a -s "$THOME/runs/$P/judge/packet.json"
done_summary
