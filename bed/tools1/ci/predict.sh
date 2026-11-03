#!/bin/bash
# predict: the A/B records of RUN -> a measured-ab change on production's fit -> rhobound predict -> rhobound gate.
#   sudo -n -u rbd /opt/rbd/ci/predict.sh RUN                         (RUN = the PR head sha)
# Reads runs/RUN/{candidate.json, policy.json (pr-check)}, every A/B folder runs/RUN/ab/ and runs/RUN/ab-<service>/ (ab.sh's
# AB_DIR; never ab*.old-*, an earlier A/B moved aside) with {ab.json, record/ab-record.json}, and baseline.json (the fit).
# The services are candidate.json's (CI v2: services, one candidate image for all, or a multi-image change's digests map,
# each service its own image's digest; v1: service). An A/B folder counts when
# its ab.json is ok; each one that counts must name a listed service (ab-<service>/ its own), its candidate digest and
# that service's production digest at the build (candidate.json baselines; still production's now); every listed service
# needs exactly one: refused otherwise (no verdict on half a blast radius). One change item per service, SPEC 0b rule 3:
# value = that record's own_ms.delta for the service as a point, label measured-ab, evidence = the record's digest; the CLI
# widens each to +-2 SE. ROUTE_ITEMS (rbd.env.local): off (the default) or on; on, a service whose record has routes
# (diff-fit writes them for two or more routes both arms read) gets one own_ms item per route instead, value that route's
# own_ms.delta, route its name: the engine moves the queue by the route's share and each caller by the routes it reaches
# (a CLI with route items, maze-fix effbb804 or later, is required; the bed's 19baaed refuses them).
# Writes runs/RUN/{change.json, prediction.json, gate/, predict.json}.
# predict.json names the candidate and baseline digests and sha256(candidate.json) it measured (sign.sh signs only that);
# its service/baseline_digest/record_digest/delta_ms are the first service's, and services lists them all (with ab_dir).
# policy.json is copied to a private temporary file; the copy must be the pinned policy (sha256 = RBD_POLICY_SHA256, rbd.env)
# and is what the gate reads; the gate's digest of the policy it applied (gate.json digests.policy) must then be
# RBD_POLICY_DIGEST (rbd.env, the bootstrap's gate of the pinned policy): refused otherwise or unset, no verdict kept.
# One verdict per run: refused once runs/RUN holds predict.json or gate/ (a re-gate needs a new commit). Under
# runs/RUN/.lock (flock; one step of a run at a time: pr-check, build, ab, predict, sign).
# The judge (the knob JUDGE_CMD in rbd.env.local; ARCHITECTURE 7): after the prediction, before the gate,
#   rhobound judge-packet -> JUDGE_OUT=runs/RUN/judge $JUDGE_CMD packet.json > answer.json (its request.json, model.txt)
#   -> rhobound judge-check -> rhobound gate ... --judge-answer --judge-packet --judge-model --judge-request (ci-judge).
# A judge that fails or is refused is "judge unavailable" (judge/judge.json says why): the gate decides without it, and it
# is never asked again. escalate turns the verdict into inconclusive; nothing a judge says can loosen one.
# JUDGE_MODE (rbd.env.local): gate (the default: the answer goes to the gate as above) or advisory (the choice on
# 2026-10-30: the judge is asked and checked the same way, its admitted answer is recorded in judge/judge.json, the
# report and the signed predicate as advisory, and the gate decides on the rules alone).
# Exit = the gate's: 0 pass, 1 block, 3 inconclusive; 2 when no verdict could be computed. Last stdout line: one JSON object.
set -euo pipefail
STEP=predict
ci_jstr() { python3 -I -c 'import json,sys; print(json.dumps(sys.argv[1]))' "$1"; }
ci_fail() {
  [[ -n ${ERR:-} && -s ${ERR:-} ]] && tail -n 15 "$ERR" >&2
  echo "$STEP: error: $1" >&2; printf '{"step":"%s","ok":false,"exit":2,"error":%s}\n' "$STEP" "$(ci_jstr "$1")"; exit 2
}
[[ $# -eq 1 ]] || ci_fail "usage: predict.sh RUN"
RUNID=$1
[[ $RUNID =~ ^[0-9a-f]{40}$ ]] || ci_fail "RUN must be a 40-hex commit id"

RBD_ROOT=/opt/rbd
NOW=$(date -u +%Y-%m-%dT%H:%M:%SZ)
if [[ -z ${SUDO_USER:-} ]]; then   # tests only; sudo never passes these
  [[ -n ${RBD_OPT:-} ]] && RBD_ROOT=$RBD_OPT
  [[ -n ${RBD_TEST_NOW:-} ]] && NOW=$RBD_TEST_NOW
fi
[[ -r $RBD_ROOT/lib/rbd-env.sh ]] || ci_fail "$RBD_ROOT/lib/rbd-env.sh missing"
# shellcheck source=/dev/null
ci_msg=$(. "$RBD_ROOT/lib/rbd-env.sh" 2>&1 > /dev/null) || ci_fail "rbd-env.sh: $ci_msg"
# shellcheck source=/dev/null
. "$RBD_ROOT/lib/rbd-env.sh"
PATH=$RBD_ROOT/bin:$PATH
for v in RBD_HOME RHOBOUND_STATE; do [[ -n ${!v:-} ]] || ci_fail "$v not set by rbd-env.sh"; done
[[ ${RBD_POLICY_SHA256:-} =~ ^[0-9a-f]{64}$ ]] ||
  ci_fail "RBD_POLICY_SHA256 is not set to a sha256 (64 hex) in rbd.env (the bootstrap writes it): no policy without the pin"
[[ ${RBD_POLICY_DIGEST:-} =~ ^sha256:[0-9a-f]{64}$ ]] ||
  ci_fail "RBD_POLICY_DIGEST is not set to sha256:<64 hex> in rbd.env (the bootstrap writes the gate's digest of the pinned policy): no verdict without it"
export RHOBOUND_STATE
command -v rhobound > /dev/null || ci_fail "rhobound not found in $RBD_ROOT/bin"

RUN=$RBD_HOME/runs/$RUNID
[[ -d $RUN ]] || ci_fail "no runs/$RUNID (pr-check.sh and build.sh first)"
# one step of a run at a time (pr-check, build, ab, predict, sign): a flock on runs/RUN/.lock, held until this step exits
exec 7>> "$RUN/.lock" || ci_fail "cannot open runs/$RUNID/.lock"
flock -n 7 || ci_fail "another step of runs/$RUNID is running (runs/$RUNID/.lock is held): one step of a run at a time"
[[ ! -e $RUN/predict.json && ! -e $RUN/gate ]] ||
  ci_fail "runs/$RUNID already holds a prediction (predict.json or gate/): a verdict is never re-rolled; a re-gate needs a new commit"
[[ -r $RUN/candidate.json ]] || ci_fail "no runs/$RUNID/candidate.json (build.sh first)"
[[ -r $RUN/policy.json ]] || ci_fail "no runs/$RUNID/policy.json (pr-check.sh first)"
[[ -r $RBD_HOME/baseline.json ]] || ci_fail "no $RBD_HOME/baseline.json"
mkdir -p "$RUN/logs"
ERR=$RUN/logs/predict.err
: > "$ERR"
# the policy the gate reads: a private copy of policy.json, hashed against the pin below; never the shared path again
PCOPY=$(mktemp "$RUN/.policy-gate.XXXXXX") || ci_fail "cannot make a temporary file in runs/$RUNID"
trap 'rm -f "$PCOPY"' EXIT
cp -- "$RUN/policy.json" "$PCOPY" || ci_fail "cannot copy runs/$RUNID/policy.json"

RITEMS=${ROUTE_ITEMS:-off}
[[ $RITEMS == on || $RITEMS == off ]] || ci_fail "ROUTE_ITEMS must be on or off, not '$RITEMS' (rbd.env.local)"
# change.json (python: the delta must round-trip exactly; the CLI compares it to the record bit for bit)
fit=$(python3 -I - "$RUN" "$RBD_HOME/baseline.json" "$RHOBOUND_STATE" "$RBD_POLICY_SHA256" "$PCOPY" "$RITEMS" 2>> "$ERR" <<'PY'
import hashlib, json, os, re, sys
run, base_path, state, pin, pcopy, ritems = sys.argv[1:7]
def fail(msg):
    print(msg, file=sys.stderr); sys.exit(1)
craw = open(os.path.join(run, "candidate.json"), "rb").read()
cand = json.loads(craw)
svc = cand["service"]
svcs = cand.get("services") or [svc]   # CI v2: every service the one candidate image is for (the first is svc)
bases = cand.get("baselines") or {svc: cand.get("baseline_digest")}
if svcs[0] != svc or set(bases) != set(svcs) or bases[svc] != cand.get("baseline_digest") or len(set(svcs)) != len(svcs):
    fail("candidate.json is inconsistent: service %s, services %s, baselines %s" % (svc, svcs, bases))
# each service's candidate digest: its image's (a multi-image change's digests map), else the one image's
multi = "digests" in cand
digs = cand.get("digests") if multi else {s: cand["digest"] for s in svcs}
if (not isinstance(digs, dict) or set(digs) != set(svcs) or digs[svc] != cand["digest"]
        or not all(isinstance(v, str) and re.fullmatch(r"sha256:[0-9a-f]{64}", v) for v in digs.values())):
    fail("candidate.json's digests %r do not name one sha256 digest per listed service, the first one's = digest" % (digs,))
base = json.load(open(base_path))
if not isinstance(base.get("fit"), dict) or not base["fit"].get("dir"):
    fail("baseline.json has no production fit yet (run refit.sh)")
fit = os.path.join(base["fit"]["dir"], "fit.json")
fsha = "sha256:" + hashlib.sha256(open(fit, "rb").read()).hexdigest()
if base["fit"].get("digest") != fsha:
    fail("baseline.json's fit digest %s is not %s's sha256 %s" % (base["fit"].get("digest"), fit, fsha))
for s in svcs:
    if bases[s] and base.get("services", {}).get(s) != bases[s]:
        fail("production moved since the build: baseline.json %s = %s, the run was built against %s"
             % (s, base.get("services", {}).get(s), bases[s]))
pol = open(pcopy, "rb").read()   # the private copy the gate reads
if hashlib.sha256(pol).hexdigest() != pin:
    fail("runs/RUN/policy.json (sha256 %s) is not the pinned policy RBD_POLICY_SHA256" % hashlib.sha256(pol).hexdigest())
# the A/B folders: ab/ and ab-<service>/ (ab.sh's AB_DIR); one ok A/B per listed service, none of another service
found, skipped = {}, []
for d in sorted(os.listdir(run)):
    if not re.fullmatch(r"ab(-[a-z]([a-z0-9-]{0,44}[a-z0-9])?)?", d) or not os.path.isdir(os.path.join(run, d)):
        continue
    abj = os.path.join(run, d, "ab.json")
    ab = json.load(open(abj)) if os.path.exists(abj) else {}
    if ab.get("ok") is not True:
        skipped.append("%s/ (%s)" % (d, "ok false at stage %s" % ab.get("stage") if ab else "no ab.json"))
        continue
    s = ab.get("service")
    if d != "ab" and d != "ab-%s" % s:
        fail("runs/RUN/%s/ab.json is an A/B of %r: an ab-<service>/ folder holds that service's A/B only" % (d, s))
    if s not in svcs:
        fail("the A/B in runs/RUN/%s/ is of %s, a service the change request does not list (%s)" % (d, s, ",".join(svcs)))
    if s in found:
        fail("two A/Bs of %s (runs/RUN/%s/ and %s/): one per service" % (s, found[s][0], d))
    found[s] = (d, ab)
missing = [s for s in svcs if s not in found]
if missing:
    fail("no A/B record of %s that is ok (did ab.sh / diff-fit fail? A/B folders: %s): every service the change request "
         "lists is measured (a request that lists fewer services is a new commit)"
         % (",".join(missing), "; ".join(skipped) or "none"))
def match(lst, d):
    return "absent" if not lst or not d else ("match" if any(x.endswith(d) for x in lst) else "mismatch")
items, meta = [], []
for s in svcs:
    d, ab = found[s]
    # the A/B must have measured THIS run's images (ab.sh's ab.json): a workflow cannot pass ab.sh other digests unnoticed
    want = {"service": s, "base_digest": bases[s], "cand_digest": digs[s]}
    got = {k: ab.get(k) for k in want}
    if got != want:
        fail("the A/B is not this run's: %s/ab.json %s, candidate.json %s" % (d, got, want))
    rec_path = os.path.join(run, d, "record", "ab-record.json")
    if not os.path.exists(rec_path):
        fail("no A/B record runs/RUN/%s/record/ab-record.json (did diff-fit fail? see runs/RUN/%s/)" % (d, d))
    raw = open(rec_path, "rb").read()
    rsha = hashlib.sha256(raw).hexdigest()
    if (ab.get("record") or {}).get("sha256") != "sha256:" + rsha:
        fail("%s/ab.json names record %s, the record file is sha256:%s" % (d, (ab.get("record") or {}).get("sha256"), rsha))
    if not os.path.exists(os.path.join(state, "ab", rsha + ".json")):
        fail("the record sha256:%s is not in RHOBOUND_STATE/ab (diff-fit and predict must share RHOBOUND_STATE)" % rsha)
    rec = json.loads(raw)
    rows = [x for x in rec.get("services", []) if x.get("service") == s]
    if len(rows) != 1:
        fail("the A/B record in %s/ does not measure %s (services: %s)" % (d, s, [x.get("service") for x in rec.get("services", [])]))
    delta = rows[0]["own_ms"]["delta"]
    if not isinstance(delta, (int, float)) or isinstance(delta, bool):
        fail("own_ms.delta of %s is not a number" % s)
    # the arms' image digests, when the Collector reports them (SPEC 0b rule 5): recorded, never decisive here
    seen = {k: rec["arms"][k].get("images", {}).get(s, []) for k in ("baseline", "candidate")}
    images = {"baseline": match(seen["baseline"], bases[s]), "candidate": match(seen["candidate"], digs[s])}
    routes = (rows[0].get("routes") or []) if ritems == "on" else []
    for r in routes:
        rd = (r.get("own_ms") or {}).get("delta") if isinstance(r, dict) else None
        if not isinstance(rd, (int, float)) or isinstance(rd, bool) or not isinstance(r.get("route"), str) or not r["route"]:
            fail("a route of %s in the record has no name or no numeric own_ms.delta: %s" % (s, r))
        items.append({"op": "own_ms", "service": s, "route": r["route"], "value": rd, "label": "measured-ab",
                      "evidence": ["sha256:" + rsha]})
    if not routes:
        items.append({"op": "own_ms", "service": s, "value": delta, "label": "measured-ab", "evidence": ["sha256:" + rsha]})
    meta.append({"service": s, "ab_dir": d, "baseline_digest": bases[s], "record_digest": "sha256:" + rsha, "delta_ms": delta,
                 "images": images, "routes": [r["route"] for r in routes]})
    if multi:
        meta[-1]["candidate_digest"] = digs[s]
change = {"schema": "rhobound.change/v1", "fit": fsha, "items": items}
tmp = os.path.join(run, ".change.json.tmp")
with open(tmp, "w") as f:
    f.write(json.dumps(change, indent=1) + "\n")
os.replace(tmp, os.path.join(run, "change.json"))
with open(os.path.join(run, ".predict-meta.json"), "w") as f:
    json.dump({"service": svc, "record_digest": meta[0]["record_digest"], "delta_ms": meta[0]["delta_ms"],
               "images": meta[0]["images"], "services": meta,
               "candidate_digest": cand["digest"], "baseline_digest": cand.get("baseline_digest"),
               "candidate_digests": digs if multi else None,
               "candidate_sha256": "sha256:" + hashlib.sha256(craw).hexdigest()}, f)
print(fit)
PY
) || ci_fail "cannot build the change: $(tail -n 1 "$ERR")"

# predict: exit 0, or 1 with a JSON refusal on stdout (the gate turns it into inconclusive input_refused:<code>)
rc=0
rhobound predict --fit "$fit" --changes "$RUN/change.json" --json > "$RUN/.prediction.json.tmp" 2>> "$ERR" || rc=$?
if [[ $rc -ne 0 ]]; then
  python3 -I -c 'import json,sys; d=json.load(open(sys.argv[1])); sys.exit(0 if isinstance(d.get("error"), dict) else 1)' \
    "$RUN/.prediction.json.tmp" 2> /dev/null || ci_fail "rhobound predict failed (exit $rc) without a refusal record"
  echo "predict: rhobound predict refused (exit $rc); the gate records it" >&2
fi
mv -f "$RUN/.prediction.json.tmp" "$RUN/prediction.json"

# the judge (JUDGE_CMD set): its answer goes to the gate only through the CLI's own check
jargs=()
JMODE=${JUDGE_MODE:-gate}
[[ $JMODE == gate || $JMODE == advisory ]] || ci_fail "JUDGE_MODE must be gate or advisory, not '$JMODE' (rbd.env.local)"
judge_rec() {   # judge_rec STATUS WHY [MODEL REQUEST]: judge/judge.json (+ the typed decision of check.json when admitted)
  python3 -I -c '
import json, os, sys
f, s, w, m, r, mode, chk = sys.argv[1:8]
d = {"status": s, "why": w, "model": m or None, "request": r or None, "mode": mode}
if s == "admitted" and os.path.exists(chk):
    c = json.load(open(chk))
    d.update(decision=c.get("decision"), reasons=c.get("reasons"), answer=c.get("answer"))
json.dump(d, open(f, "w"))' "$J/judge.json" "$1" "$2" "${3:-}" "${4:-}" "$JMODE" "$J/check.json"
}
if [[ -n ${JUDGE_CMD:-} && $rc -eq 0 ]]; then
  J=$RUN/judge
  rm -rf "$J"; mkdir -p "$J"
  read -r -a jcmd <<< "$JUDGE_CMD"
  if ! rhobound judge-packet "$RUN/prediction.json" --policy "$PCOPY" --policy-name default --fit "$fit" --now "$NOW" --json \
    > "$J/packet.json" 2> "$J/packet.err"; then
    judge_rec unavailable "judge-packet failed: $(tail -n 1 "$J/packet.err")"
  elif ! JUDGE_OUT=$J timeout 900 "${jcmd[@]}" "$J/packet.json" > "$J/answer.json" 2> "$J/provider.err"; then
    judge_rec unavailable "the provider gave no answer: $(tail -n 1 "$J/provider.err")"
  elif [[ ! -s $J/request.json || ! -s $J/model.txt ]]; then
    judge_rec unavailable "the provider wrote no request.json/model.txt"
  else
    jmodel=$(head -n 1 "$J/model.txt" | tr -cd 'A-Za-z0-9._:/@-' | head -c 128)
    jreq="sha256:$(sha256sum "$J/request.json" | cut -d' ' -f1)"
    jrc=0
    rhobound judge-check "$J/answer.json" --packet "$J/packet.json" --json > "$J/check.json" 2> "$J/check.err" || jrc=$?
    if [[ $jrc -eq 0 && -n $jmodel ]]; then
      if [[ $JMODE == gate ]]; then
        jargs=(--judge-answer "$J/answer.json" --judge-packet "$J/packet.json" --judge-model "$jmodel" --judge-request "$jreq")
        judge_rec admitted "judge-check admitted the answer; the gate weighs it" "$jmodel" "$jreq"
      else
        judge_rec admitted "judge-check admitted the answer; advisory: recorded, not given to the gate" "$jmodel" "$jreq"
      fi
    else
      judge_rec refused "judge-check refused the answer (exit $jrc): $(tail -n 1 "$J/check.err" | cut -c1-300)" "$jmodel" "$jreq"
    fi
  fi
  echo "predict: judge: $(python3 -I -c 'import json,sys; d=json.load(open(sys.argv[1])); print(d["status"], "-", d["why"][:200])' "$J/judge.json")" >&2
fi

rm -rf "$RUN/.gate.tmp"
grc=0
rhobound gate "$RUN/prediction.json" --policy "$PCOPY" --now "$NOW" --out "$RUN/.gate.tmp" --json ${jargs[@]+"${jargs[@]}"} \
  > "$RUN/.gate.out" 2>> "$ERR" || grc=$?
case $grc in 0 | 1 | 3) ;; *) ci_fail "rhobound gate failed (exit $grc)" ;; esac
[[ -s $RUN/.gate.tmp/gate.json && -s $RUN/.gate.tmp/verdict.txt ]] || ci_fail "rhobound gate wrote no verdict"
# the effective policy the gate applied (its digest, contract.DigestOf) must be the pinned one
gpd=$(python3 -I -c 'import json,sys; print(json.load(open(sys.argv[1]))["digests"]["policy"])' "$RUN/.gate.tmp/gate.json" \
  2> /dev/null || true)
if [[ $gpd != "$RBD_POLICY_DIGEST" ]]; then
  rm -rf "$RUN/.gate.tmp" "$RUN/.gate.out"
  ci_fail "the gate applied policy ${gpd:-(no digest)}, not the pinned RBD_POLICY_DIGEST $RBD_POLICY_DIGEST (rbd.env): no verdict kept"
fi
mv -T "$RUN/.gate.tmp" "$RUN/gate"
rm -f "$RUN/.gate.out"

python3 -I - "$RUN" "$grc" "$rc" <<'PY'
import json, os, sys
run, grc, prc = sys.argv[1], int(sys.argv[2]), int(sys.argv[3])
g = json.load(open(os.path.join(run, "gate", "gate.json")))
verdict = open(os.path.join(run, "gate", "verdict.txt")).read().strip()
if verdict != g.get("verdict") or {"pass": 0, "block": 1, "inconclusive": 3}.get(verdict) != grc:
    print("predict: gate outputs disagree (verdict.txt %r, gate.json %r, exit %d)" % (verdict, g.get("verdict"), grc), file=sys.stderr)
    print(json.dumps({"step": "predict", "ok": False, "exit": 2, "error": "gate outputs disagree"}))
    sys.exit(2)
meta = json.load(open(os.path.join(run, ".predict-meta.json")))
rule = next((r for r in g["rules"] if r.get("evaluated") and r.get("effect") == verdict), None)
if verdict == "pass":
    rule = next((r for r in g["rules"] if r.get("rule") == "mean_change"), rule)
tok = (rule or {}).get("rule", "")
if not rule and verdict == "inconclusive" and (g.get("judge") or {}).get("decision") == "escalate":
    tok = "judge_escalate"   # every rule passed; the CI judge escalated (the commit status names it)
if rule and rule.get("entry") and tok == "mean_change":
    tok += "@" + rule["entry"]
jr = os.path.join(run, "judge", "judge.json")
judge = json.load(open(jr)) if os.path.exists(jr) else None
if judge is not None:
    judge["gate"] = g.get("judge")   # what the gate recorded (provenance ci-judge, model_id, decision, answer digest), or null
out = {"step": "predict", "ok": grc == 0, "exit": grc, "verdict": verdict, "rule": tok, "advisory": g.get("advisory"),
       "judge": judge,
       "service": meta["service"], "delta_ms": meta["delta_ms"], "record_digest": meta["record_digest"],
       "services": meta["services"],
       "prediction_digest": g["digests"]["report"], "predict_exit": prc, "images": meta["images"], "now": g.get("now"),
       "candidate_digest": meta["candidate_digest"], "baseline_digest": meta["baseline_digest"],
       "candidate_sha256": meta["candidate_sha256"]}
if meta.get("candidate_digests"):   # a multi-image change: every service's candidate digest
    out["candidate_digests"] = meta["candidate_digests"]
tmp = os.path.join(run, ".predict.json.tmp")
with open(tmp, "w") as f:
    f.write(json.dumps(out, indent=1, sort_keys=True) + "\n")
os.replace(tmp, os.path.join(run, "predict.json"))
os.remove(os.path.join(run, ".predict-meta.json"))
print("predict: %s (%s)%s" % (verdict, tok, ", advisory" if g.get("advisory") else ""), file=sys.stderr)
print(json.dumps(out, sort_keys=True))
PY
exit "$grc"
