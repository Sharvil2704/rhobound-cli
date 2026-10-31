#!/bin/bash
# sign: the gate's verdict of RUN as a signed attestation on the candidate image (cosign + the KMS key), and one ledger row,
# write-once, in S3 (s3://RBD_BUCKET/demo1/ledger/<prediction-sha256>.json) and in RBD_HOME/ledger/. Every verdict is signed
# (pass, block, inconclusive): deploy.sh refuses all but pass. The ledger is written BEFORE the attestation.
#   sudo -n -u rbd /opt/rbd/ci/sign.sh RUN
# Needs cosign v2.x (v3 dropped --tlog-upload from attest). The prediction digest is gate.json's digests.report (sha256 of
# prediction.json without its final newline). A rerun with the same prediction and verdict is a no-op for the ledger.
# Signs only the image that was measured: candidate.json (byte for byte), predict.json and, for EVERY service it lists (CI v2:
# one candidate image for 1..5 services; predict.json services, each with its A/B folder ab/ or ab-<service>/), that A/B's
# ab.json must name the same candidate digest and that service's baseline digest, ok, its record one of change.json's
# evidence (the evidence = exactly those records); policy.json must be the pinned policy
# (sha256 = RBD_POLICY_SHA256, rbd.env), recorded in the predicate as policy_sha256, and the gate must have applied the pinned
# effective policy: gate.json digests.policy = RBD_POLICY_DIGEST (rbd.env), the predicate's policy_digest (deploy.sh checks
# both against rbd.env). Under runs/RUN/.lock (flock; one step of a run at a time: pr-check, build, ab, predict, sign).
# The predicate keeps the v1 fields (service, baseline_digest, ab_record_digest: the first service's) and gains services
# [{service, baseline_digest, ab_record_digest}] (every service; deploy.sh v2 deploys the one candidate digest to each).
# Exit 0 signed, 1 refused or failed. Last stdout line: one JSON object.
set -euo pipefail
STEP=sign
TYPE=https://rhobound.dev/attestations/gate-verdict/v1
ci_red() { if [[ -n ${RBD_ACCOUNT:-} ]]; then sed "s/${RBD_ACCOUNT}/<account>/g"; else cat; fi; }
ci_jstr() { python3 -I -c 'import json,sys; print(json.dumps(sys.argv[1]))' "$1"; }
ci_fail() {
  local m; m=$(printf '%s' "$1" | ci_red)
  if [[ -n ${LOG:-} && -s ${LOG:-} ]]; then echo "--- last lines of the log ---" >&2; tail -n 20 "$LOG" | ci_red >&2; fi
  echo "$STEP: error: $m" >&2; printf '{"step":"%s","ok":false,"error":%s}\n' "$STEP" "$(ci_jstr "$m")"; exit 1
}
[[ $# -eq 1 ]] || ci_fail "usage: sign.sh RUN"
RUNID=$1
[[ $RUNID =~ ^[0-9a-f]{40}$ ]] || ci_fail "RUN must be a 40-hex commit id"

RBD_ROOT=/opt/rbd
[[ -z ${SUDO_USER:-} && -n ${RBD_OPT:-} ]] && RBD_ROOT=$RBD_OPT   # tests only; sudo's env_reset never passes it
[[ -r $RBD_ROOT/lib/rbd-env.sh ]] || ci_fail "$RBD_ROOT/lib/rbd-env.sh missing"
# shellcheck source=/dev/null
ci_msg=$(. "$RBD_ROOT/lib/rbd-env.sh" 2>&1 > /dev/null) || ci_fail "rbd-env.sh: $ci_msg"
# shellcheck source=/dev/null
. "$RBD_ROOT/lib/rbd-env.sh"
PATH=$RBD_ROOT/bin:$PATH
for v in RBD_REGION RBD_ECR RBD_KMS RBD_BUCKET RBD_HOME; do [[ -n ${!v:-} ]] || ci_fail "$v not set by rbd-env.sh"; done
[[ ${RBD_POLICY_SHA256:-} =~ ^[0-9a-f]{64}$ ]] ||
  ci_fail "RBD_POLICY_SHA256 is not set to a sha256 (64 hex) in rbd.env (the bootstrap writes it): no policy without the pin"
[[ ${RBD_POLICY_DIGEST:-} =~ ^sha256:[0-9a-f]{64}$ ]] ||
  ci_fail "RBD_POLICY_DIGEST is not set to sha256:<64 hex> in rbd.env (the bootstrap writes the gate's digest of the pinned policy): nothing signed without it"
export AWS_REGION=${AWS_REGION:-$RBD_REGION} AWS_DEFAULT_REGION=${AWS_DEFAULT_REGION:-$RBD_REGION}
cv=$(cosign version 2>&1 | awk '/GitVersion/ {print $2}') || true
[[ $cv == v2.* ]] || ci_fail "cosign v2.x required (found '${cv:-none}'): v3 has no --tlog-upload on attest"

RUN=$RBD_HOME/runs/$RUNID
[[ -d $RUN ]] || ci_fail "no runs/$RUNID (predict.sh first)"
# one step of a run at a time (pr-check, build, ab, predict, sign): a flock on runs/RUN/.lock, held until this step exits
exec 7>> "$RUN/.lock" || ci_fail "cannot open runs/$RUNID/.lock"
flock -n 7 || ci_fail "another step of runs/$RUNID is running (runs/$RUNID/.lock is held): one step of a run at a time"
for f in candidate.json change.json prediction.json gate/gate.json gate/verdict.txt predict.json policy.json; do
  [[ -r $RUN/$f ]] || ci_fail "no runs/$RUNID/$f (predict.sh first)"
done
mkdir -p "$RUN/logs" "$RBD_HOME/ledger"
LOG=$RUN/logs/sign.log
: > "$LOG"
rm -f "$RUN/sign.json"   # written again only after cosign attest succeeded (report.sh reads it as "signed")

# predicate rbd.gate-verdict/v1 + ledger row (canonical JSON: sorted keys, no spaces)
key=$(python3 -I - "$RUN" "$RUNID" "$RBD_ECR" "$TYPE" "$RBD_POLICY_SHA256" "$RBD_POLICY_DIGEST" 2>> "$LOG" <<'PY'
import hashlib, json, os, re, sys
run, sha, ecr, typ, pin, pdig = sys.argv[1:7]
def fail(msg):
    print(msg, file=sys.stderr); sys.exit(1)
g = json.load(open(os.path.join(run, "gate", "gate.json")))
verdict = open(os.path.join(run, "gate", "verdict.txt")).read().strip()
craw = open(os.path.join(run, "candidate.json"), "rb").read()
cand = json.loads(craw)
change = json.load(open(os.path.join(run, "change.json")))
pj = json.load(open(os.path.join(run, "predict.json")))
pol = open(os.path.join(run, "policy.json"), "rb").read()
pred = open(os.path.join(run, "prediction.json"), "rb").read()
if verdict not in ("pass", "block", "inconclusive") or verdict != g.get("verdict"):
    fail("verdict.txt %r and gate.json %r disagree" % (verdict, g.get("verdict")))
pd = g["digests"]["report"]
if "sha256:" + hashlib.sha256(pred.rstrip(b"\n")).hexdigest() != pd:
    fail("prediction.json is not the report the gate decided on (%s)" % pd)
if cand["git_sha"] != sha:
    fail("candidate.json is for %s, not %s" % (cand["git_sha"], sha))
if hashlib.sha256(pol).hexdigest() != pin:
    fail("runs/RUN/policy.json (sha256 %s) is not the pinned policy RBD_POLICY_SHA256" % hashlib.sha256(pol).hexdigest())
if g.get("digests", {}).get("policy") != pdig:
    fail("gate.json's effective policy %s is not the pinned RBD_POLICY_DIGEST %s (the gate decided under another policy)"
         % (g.get("digests", {}).get("policy"), pdig))
# the image signed is the image the A/B measured and predict.sh gated (predict.sh's checks, again at signing time)
want = {"candidate_digest": cand["digest"], "baseline_digest": cand.get("baseline_digest")}
if pj.get("candidate_sha256") != "sha256:" + hashlib.sha256(craw).hexdigest():
    fail("candidate.json changed after predict.sh (predict.json names candidate.json %s)" % pj.get("candidate_sha256"))
if {k: pj.get(k) for k in want} != want or pj.get("service") != cand["service"] or pj.get("prediction_digest") != pd:
    fail("predict.json %s is not this candidate %s and gate report %s"
         % ({k: pj.get(k) for k in ("service", "prediction_digest", *want)}, want, pd))
# every A/B the prediction used (one per service the one candidate image is for), checked again at signing time
svcs = cand.get("services") or [cand["service"]]
bases = cand.get("baselines") or {cand["service"]: cand.get("baseline_digest")}
pss = pj.get("services") or [{"service": cand["service"], "ab_dir": "ab", "baseline_digest": cand.get("baseline_digest"),
                               "record_digest": pj.get("record_digest")}]
if [x.get("service") for x in pss] != svcs or svcs[0] != cand["service"] or pss[0].get("record_digest") != pj.get("record_digest"):
    fail("predict.json measured services %s, candidate.json lists %s" % ([x.get("service") for x in pss], svcs))
ev = [e for it in change.get("items", []) for e in it.get("evidence", [])]
recs = []
for x in pss:
    s, d = x["service"], str(x.get("ab_dir"))
    if not re.fullmatch(r"ab(-[a-z]([a-z0-9-]{0,44}[a-z0-9])?)?", d) or d not in ("ab", "ab-" + s):
        fail("predict.json names A/B folder %r for %s" % (d, s))
    abj = os.path.join(run, d, "ab.json")
    if not os.path.exists(abj):
        fail("no runs/RUN/%s/ab.json: the A/B is not this run's" % d)
    ab = json.load(open(abj))
    wants = {"candidate_digest": cand["digest"], "baseline_digest": bases.get(s)}
    got = {"candidate_digest": ab.get("cand_digest"), "baseline_digest": ab.get("base_digest")}
    if got != wants or ab.get("service") != s or ab.get("ok") is not True or x.get("baseline_digest") != bases.get(s):
        fail("the A/B is not this run's: %s/ab.json %s (service %s, ok %s), candidate.json %s"
             % (d, got, ab.get("service"), ab.get("ok"), wants))
    rd = (ab.get("record") or {}).get("sha256")
    if rd != x.get("record_digest") or rd not in ev:
        fail("change.json's evidence %s is not ab.json's record %s (%s)" % (ev, rd, d))
    recs.append({"service": s, "baseline_digest": bases.get(s), "ab_record_digest": rd})
if sorted(ev) != sorted(r["ab_record_digest"] for r in recs):
    fail("change.json's evidence %s is not ab.json's record set %s" % (ev, [r["ab_record_digest"] for r in recs]))
keep = ("number", "rule", "effect", "entry", "value", "threshold", "code")
rules = [{k: r[k] for k in keep if k in r} for r in g["rules"] if r.get("evaluated")]
p = {"verdict": verdict, "rules": rules, "advisory": bool(g.get("advisory")), "candidate_digest": cand["digest"],
     "baseline_digest": cand.get("baseline_digest"), "service": cand["service"], "services": recs,
     "fit_digest": g["digests"].get("fit") or change.get("fit"), "ab_record_digest": recs[0]["ab_record_digest"],
     "prediction_digest": pd, "policy_digest": pdig, "policy_sha256": "sha256:" + pin, "git_sha": sha,
     "decided_at": g.get("now")}
if g.get("judge"):   # the CI judge, as the gate recorded it: provenance ci-judge, model, decision, answer and request digests
    p["judge"] = dict(g["judge"], request=g["digests"].get("judge_request"))
jf = os.path.join(run, "judge", "judge.json")
if os.path.exists(jf):   # an advisory judge (JUDGE_MODE=advisory): recorded beside the verdict, never part of it
    j = json.load(open(jf))
    if j.get("mode") == "advisory" and j.get("status") == "admitted":
        if g.get("judge"):
            fail("judge.json says advisory, but the gate weighed a judge answer")
        p["judge_advisory"] = {k: j.get(k) for k in ("model", "decision", "reasons", "answer", "request")}
canon = lambda d: json.dumps(d, sort_keys=True, separators=(",", ":")) + "\n"
row = {"schema": "rbd.ledger/v1", "predicate_type": typ, "image": "RBD_ECR@" + cand["digest"], "predicate": p}
for name, d in (("predicate.json", p), ("ledger-row.json", row)):
    tmp = os.path.join(run, "." + name + ".tmp")
    with open(tmp, "w") as f:
        f.write(canon(d))
    os.replace(tmp, os.path.join(run, name))
print(pd.split(":", 1)[1])
PY
) || ci_fail "cannot build the predicate: $(tail -n 1 "$LOG")"
ROW=$RUN/ledger-row.json
# the digest the checks above passed (the predicate), never candidate.json read a second time
cand_digest=$(python3 -I -c 'import json,sys; print(json.load(open(sys.argv[1]))["candidate_digest"])' "$RUN/predicate.json")
verdict=$(cat "$RUN/gate/verdict.txt")

# ledger: S3 first (write-once), then the local copy (write-once); an identical existing row is fine
S3KEY=demo1/ledger/$key.json
if aws s3api put-object --bucket "$RBD_BUCKET" --key "$S3KEY" --body "$ROW" --content-type application/json \
  --if-none-match '*' >> "$LOG" 2> "$RUN/logs/.put.err"; then
  s3=written
else
  grep -q 'PreconditionFailed\|412' "$RUN/logs/.put.err" || { cat "$RUN/logs/.put.err" >> "$LOG"; ci_fail "S3 ledger write failed"; }
  aws s3api get-object --bucket "$RBD_BUCKET" --key "$S3KEY" "$RUN/logs/.ledger-s3.json" >> "$LOG" 2>&1 ||
    ci_fail "S3 ledger row exists and cannot be read back"
  cmp -s "$RUN/logs/.ledger-s3.json" "$ROW" ||
    ci_fail "the S3 ledger already holds a DIFFERENT row for prediction $key (write-once; a verdict is never re-decided)"
  s3=exists
fi
rm -f "$RUN/logs/.put.err" "$RUN/logs/.ledger-s3.json"
python3 -I - "$ROW" "$RBD_HOME/ledger/$key.json" <<'PY' || ci_fail "the local ledger already holds a DIFFERENT row for prediction $key"
import os, sys
src, dst = sys.argv[1:3]
data = open(src, "rb").read()
try:
    fd = os.open(dst, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o644)
except FileExistsError:
    sys.exit(0 if open(dst, "rb").read() == data else 1)
with os.fdopen(fd, "wb") as f:
    f.write(data)
PY

# attestation on the candidate image (ECR login first: cosign reads ~/.docker/config.json)
{ aws ecr get-login-password --region "$RBD_REGION" | docker login --username AWS --password-stdin "${RBD_ECR%%/*}"; } >> "$LOG" 2>&1 ||
  ci_fail "ECR login failed"
cosign attest --key "$RBD_KMS" --type "$TYPE" --predicate "$RUN/predicate.json" --tlog-upload=false --yes \
  "$RBD_ECR@$cand_digest" >> "$LOG" 2>&1 || ci_fail "cosign attest failed"
res=$(printf '{"step":"sign","ok":true,"verdict":"%s","candidate_digest":"%s","ledger_key":"%s","s3":"%s","signed_at":"%s"}' \
  "$verdict" "$cand_digest" "$key" "$s3" "$(date -u +%Y-%m-%dT%H:%M:%SZ)")
printf '%s\n' "$res" > "$RUN/.sign.json.tmp" && mv -f "$RUN/.sign.json.tmp" "$RUN/sign.json"
echo "sign: $verdict attested on $cand_digest; ledger $key ($s3)" >&2
printf '%s\n' "$res"
