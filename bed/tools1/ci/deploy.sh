#!/bin/bash
# deploy: THE enforcement point. Deploys an image to production only when a gate verdict signed with the KMS key says pass,
# for this service, against the production image that is running now. Then refit.sh (a new production window and fit).
#   sudo -n -u rbd /opt/rbd/ci/deploy.sh SERVICE DIGEST          (DIGEST = sha256:<64 hex>)
#   sudo -n -u rbd /opt/rbd/ci/deploy.sh --run GIT_SHA           (SERVICE and DIGEST from runs/GIT_SHA/candidate.json)
# Refuses (exit 1, nothing changed) unless every verified attestation of DIGEST says pass and the newest one names SERVICE,
# DIGEST and a baseline_digest equal to baseline.json's (and the Deployment's) current image, and was decided under the
# pinned policy: policy_sha256 = RBD_POLICY_SHA256 (rbd.env) = sha256 of runs/<its git_sha>/policy.json, and policy_digest
# (the gate's digest of the effective policy it applied) = RBD_POLICY_DIGEST (rbd.env; never compared with the run's own
# files, which rbd writes). Under the cluster lock (part B's lock.sh), held through refit.sh (which sees it
# nested). Rollout failure -> rollout undo, exit 1, baseline.json unchanged.
# v2 (SPEC2 4: one image for 1..5 services): the services deployed are the ones the newest verified predicate lists
# (services [{service, baseline_digest}]; a v1 predicate: its service), never the caller's: SERVICE must be one of them and
# DIGEST goes to EVERY one, each of which must still run (baseline.json and its Deployment) the baseline digest the
# predicate names for it (one already at DIGEST is left as is). Each is set, then each rollout waited for; a failed rollout
# undoes every service this run set (baseline.json unchanged); then every old pod gone, one settle, baseline.json updated
# for all of them in one write, one refit.
# A multi-image change (2026-11-03: the predicate's candidate_digests {service: digest}): each service goes to ITS image;
# DIGEST must be one of them, and every other image of the change must verify too, its newest pass predicate the same
# verdict (the same prediction, services and digests): one signed pass covers the whole change or nothing deploys.
# Exit 0 deployed (or already deployed), 1 refused or failed. Last stdout line: one JSON object.
set -euo pipefail
STEP=deploy
TYPE=https://rhobound.dev/attestations/gate-verdict/v1
ci_red() { if [[ -n ${RBD_ACCOUNT:-} ]]; then sed "s/${RBD_ACCOUNT}/<account>/g"; else cat; fi; }
ci_jstr() { python3 -I -c 'import json,sys; print(json.dumps(sys.argv[1]))' "$1"; }
ci_jlist() { python3 -I -c 'import json,sys; print(json.dumps(sys.argv[1:]))' "$@"; }
ci_fail() {
  local m; m=$(printf '%s' "$1" | ci_red)
  if [[ -n ${LOG:-} && -s ${LOG:-} && ${2:-} != nolog ]]; then echo "--- last lines of the log ---" >&2; tail -n 20 "$LOG" | ci_red >&2; fi
  echo "$STEP: REFUSED/FAILED: $m" >&2; printf '{"step":"%s","ok":false,"error":%s}\n' "$STEP" "$(ci_jstr "$m")"; exit 1
}
RBD_ROOT=/opt/rbd
[[ -z ${SUDO_USER:-} && -n ${RBD_OPT:-} ]] && RBD_ROOT=$RBD_OPT   # tests only; sudo's env_reset never passes it
[[ -r $RBD_ROOT/lib/rbd-env.sh ]] || ci_fail "$RBD_ROOT/lib/rbd-env.sh missing"
# shellcheck source=/dev/null
ci_msg=$(. "$RBD_ROOT/lib/rbd-env.sh" 2>&1 > /dev/null) || ci_fail "rbd-env.sh: $ci_msg"
# shellcheck source=/dev/null
. "$RBD_ROOT/lib/rbd-env.sh"
[[ -r $RBD_ROOT/lib/lock.sh ]] || ci_fail "$RBD_ROOT/lib/lock.sh missing"
# shellcheck source=/dev/null
. "$RBD_ROOT/lib/lock.sh"
PATH=$RBD_ROOT/bin:$PATH
for v in RBD_REGION RBD_ECR RBD_KMS RBD_HOME KUBECONFIG; do [[ -n ${!v:-} ]] || ci_fail "$v not set by rbd-env.sh"; done
[[ ${RBD_POLICY_SHA256:-} =~ ^[0-9a-f]{64}$ ]] ||
  ci_fail "RBD_POLICY_SHA256 is not set to a sha256 (64 hex) in rbd.env (the bootstrap writes it): no policy without the pin"
[[ ${RBD_POLICY_DIGEST:-} =~ ^sha256:[0-9a-f]{64}$ ]] ||
  ci_fail "RBD_POLICY_DIGEST is not set to sha256:<64 hex> in rbd.env (the bootstrap writes the gate's digest of the pinned policy): nothing deploys without it"
export KUBECONFIG AWS_REGION=${AWS_REGION:-$RBD_REGION} AWS_DEFAULT_REGION=${AWS_DEFAULT_REGION:-$RBD_REGION}

if [[ $# -eq 2 && $1 == --run ]]; then
  [[ $2 =~ ^[0-9a-f]{40}$ ]] || ci_fail "--run takes a 40-hex commit id"
  c=$RBD_HOME/runs/$2/candidate.json
  [[ -r $c ]] || ci_fail "no runs/$2/candidate.json: this commit was never built by the gate"
  read -r SERVICE DIGEST < <(python3 -I -c 'import json,sys; d=json.load(open(sys.argv[1])); print(d["service"], d["digest"])' "$c") ||
    ci_fail "unreadable $c"
elif [[ $# -eq 2 ]]; then SERVICE=$1 DIGEST=$2
else ci_fail "usage: deploy.sh SERVICE DIGEST | deploy.sh --run GIT_SHA"
fi
[[ $DIGEST =~ ^sha256:[0-9a-f]{64}$ ]] || ci_fail "DIGEST must be sha256:<64 hex>"
python3 -I -c 'import json,sys; sys.exit(sys.argv[2] not in json.load(open(sys.argv[1]))["services"])' \
  "$RBD_ROOT/maze/spec.json" "$SERVICE" 2> /dev/null || ci_fail "unknown service '$SERVICE'"
IMAGE=$RBD_ECR@$DIGEST
mkdir -p "$RBD_HOME/deploys"
STAMP=$(date -u +%Y%m%d-%H%M%S)
LOG=$RBD_HOME/deploys/$STAMP-$SERVICE-${DIGEST:7:12}.log
: > "$LOG"

export RBD_STEP=deploy
rbd_lock "${RBD_LOCK_WAIT:-3600}" "deploy $SERVICE" || ci_fail "the cluster lock is busy ($(rbd_lock_holder))"

{ aws ecr get-login-password --region "$RBD_REGION" | docker login --username AWS --password-stdin "${RBD_ECR%%/*}"; } >> "$LOG" 2>&1 ||
  ci_fail "ECR login failed"
att=$RBD_HOME/deploys/$STAMP-$SERVICE.att.jsonl
cosign verify-attestation --key "$RBD_KMS" --type "$TYPE" --insecure-ignore-tlog=true "$IMAGE" > "$att" 2>> "$LOG" ||
  ci_fail "no attestation of type $TYPE signed by the KMS key verifies on $DIGEST"
# decide (python, twice): every verified predicate must say pass; the newest must name DIGEST and the pinned policy, and
# lists the services (v2: services; v1: service) SERVICE must be one of. Then, with each one's Deployment image: every
# service must still run the baseline its predicate entry names (or already run DIGEST).
IFS= read -r -d '' DECIDE <<'PY' || true
import base64, hashlib, json, os, re, sys
mode, att, svc, digest, typ, home, pin, pdig, spec, base_path, imgs = sys.argv[1:12]
DRE = r"sha256:[0-9a-f]{64}"
def refuse(msg):
    print("REFUSE " + msg); sys.exit(0)
preds = []
for line in open(att):
    line = line.strip()
    if not line:
        continue
    try:
        env = json.loads(line)
        st = json.loads(base64.b64decode(env["payload"]))
    except (ValueError, KeyError, TypeError):
        continue
    if st.get("predicateType") != typ:
        continue
    if not any(s.get("digest", {}).get("sha256") == digest.split(":", 1)[1] for s in st.get("subject", [])):
        continue
    preds.append(st.get("predicate") or {})
if not preds:
    refuse("no verified %s predicate names %s as its subject" % (typ, digest))
nonpass = sorted({p.get("verdict", "?") for p in preds} - {"pass"})
if nonpass:
    refuse("a signed verdict for this image is %s (a block or inconclusive is never deployed, never retried into a pass)" % "/".join(nonpass))
p = max(preds, key=lambda q: str(q.get("decided_at", "")))
# the services this pass covers, each with the production digest it was measured against
if p.get("services") is not None:
    ents = p["services"] if isinstance(p["services"], list) else []
    pbase = {e.get("service"): e.get("baseline_digest") for e in ents if isinstance(e, dict)}
    targets = [e.get("service") for e in ents if isinstance(e, dict)]
else:
    pbase, targets = {p.get("service"): p.get("baseline_digest")}, [p.get("service")]
names = json.load(open(spec))["services"]
if not 1 <= len(targets) <= 5 or len(set(targets)) != len(targets) or not all(t in names for t in targets):
    refuse("the pass verdict lists services %r: want 1 to 5 distinct services of spec.json" % (targets,))
if svc not in targets:
    refuse("the pass verdict is for service %r, not %r" % (",".join(map(str, targets)), svc))
# each service's image: a multi-image change's candidate_digests, else the one candidate digest
cmap = p.get("candidate_digests")
if cmap is not None and (not isinstance(cmap, dict) or set(cmap) != set(targets)):
    refuse("the pass verdict's candidate_digests %r do not cover its services %r" % (cmap, targets))
tdig = {t: (cmap[t] if cmap is not None else p.get("candidate_digest")) for t in targets}
if not all(isinstance(d, str) and re.fullmatch(DRE, d) for d in tdig.values()):
    refuse("the pass verdict names a candidate that is not a sha256 digest: %r" % (tdig,))
if digest not in tdig.values() or (cmap is None and p.get("candidate_digest") != digest):
    refuse("the pass verdict names candidate %s, not %s" % (p.get("candidate_digest") if cmap is None else tdig, digest))
sha = str(p.get("git_sha", ""))
if not re.fullmatch(r"[0-9a-f]{40}", sha):
    refuse("the pass verdict names no commit (git_sha %r)" % sha)
if p.get("policy_sha256") != "sha256:" + pin:
    refuse("the pass verdict was decided under policy %s, not the pinned policy sha256:%s" % (p.get("policy_sha256"), pin))
pol = os.path.join(home, "runs", sha, "policy.json")
if not os.path.exists(pol) or hashlib.sha256(open(pol, "rb").read()).hexdigest() != pin:
    refuse("runs/%s/policy.json is missing or not the pinned policy RBD_POLICY_SHA256" % sha)
if p.get("policy_digest") != pdig:
    refuse("the pass verdict's policy_digest %s is not the pinned effective policy RBD_POLICY_DIGEST %s"
           % (p.get("policy_digest"), pdig))
if mode == "targets":   # the prediction, then SERVICE=DIGEST for every service the pass covers
    print("TARGETS %s %s" % (p.get("prediction_digest"), " ".join("%s=%s" % (t, tdig[t]) for t in targets))); sys.exit(0)
cur = dict(l.split(" ", 1) for l in open(imgs).read().splitlines() if " " in l)
base = json.load(open(base_path)).get("services", {})
todo = []
for t in targets:
    now, img = base.get(t), cur.get(t, "")
    if now == tdig[t] and img.endswith("@" + tdig[t]):
        continue   # already deployed (baseline.json agrees)
    if pbase.get(t) != now:
        refuse("stale verdict: %s was measured against production %s, production is now %s" % (t, pbase.get(t), now))
    if not img.endswith("@" + str(now)):
        refuse("deployment/%s runs %s, not baseline.json's %s: fix the drift first" % (t, img.split("@")[-1], now))
    todo.append(t)
if not todo:
    print("ALREADY %s" % sha); sys.exit(0)
print("OK %s %s %s" % (sha, p.get("decided_at"), " ".join(todo)))
PY
decide() { # decide MODE [ATT DIGEST]: the verification above, on att/DIGEST or another image's attestations
  python3 -I -c "$DECIDE" "$1" "${2:-$att}" "$SERVICE" "${3:-$DIGEST}" "$TYPE" "$RBD_HOME" "$RBD_POLICY_SHA256" \
    "$RBD_POLICY_DIGEST" "$RBD_ROOT/maze/spec.json" "$RBD_HOME/baseline.json" "$imgs"; }
imgs=$RBD_HOME/deploys/$STAMP-$SERVICE.images.txt
dec=$(decide targets) || ci_fail "the verification step failed"
case $dec in
  REFUSE*) ci_fail "${dec#REFUSE }" ;;
  TARGETS*) read -r -a TPAIRS <<< "${dec#TARGETS }" ;;
  *) ci_fail "unexpected verification result" ;;
esac
TARGETS=() OTHERS=(); declare -A TDIG=()
for x in "${TPAIRS[@]:1}"; do
  t=${x%%=*} d=${x#*=}; TARGETS+=("$t"); TDIG[$t]=$d
  [[ $d == "$DIGEST" || " ${OTHERS[*]} " == *" $d "* ]] || OTHERS+=("$d")
done
# a multi-image change: every other image must carry the same signed pass (the same prediction, services and digests)
for d in "${OTHERS[@]}"; do
  oatt=$RBD_HOME/deploys/$STAMP-$SERVICE.att-${d:7:12}.jsonl
  cosign verify-attestation --key "$RBD_KMS" --type "$TYPE" --insecure-ignore-tlog=true "$RBD_ECR@$d" > "$oatt" 2>> "$LOG" ||
    ci_fail "no attestation of type $TYPE signed by the KMS key verifies on $d (an image of this change)"
  odec=$(decide targets "$oatt" "$d") || ci_fail "the verification step failed ($d)"
  [[ $odec == "$dec" ]] || ci_fail "the image $d of this change does not carry the same signed pass (${odec#REFUSE })"
done
: > "$imgs"
for t in "${TARGETS[@]}"; do
  img=$(kubectl -n maze get deployment "$t" -o jsonpath="{.spec.template.spec.containers[?(@.name==\"$t\")].image}" 2>> "$LOG") ||
    ci_fail "cannot read deployment/$t in namespace maze"
  printf '%s %s\n' "$t" "$img" >> "$imgs"
done
dec=$(decide state) || ci_fail "the verification step failed"
case $dec in
  REFUSE*) ci_fail "${dec#REFUSE }" ;;
  ALREADY*)
    echo "deploy: ${TARGETS[*]} already run their candidates (baseline.json agrees); nothing to do, no refit" >&2
    printf '{"step":"deploy","ok":true,"service":"%s","services":%s,"digest":"%s","already_deployed":true}\n' "$SERVICE" \
      "$(ci_jlist "${TARGETS[@]}")" "$DIGEST"
    exit 0 ;;
  OK*) read -r _ GIT_SHA DECIDED TODO <<< "$dec"; read -r -a TODO <<< "$TODO" ;;
  *) ci_fail "unexpected verification result" ;;
esac

echo "deploy: signed pass verified (decided $DECIDED, commit ${GIT_SHA:0:12}); rolling out ${TODO[*]}" >&2
ROLLED=()
undo_all() { # undo every service this run set (newest first): the cluster is left as it was, baseline.json unchanged
  local i d
  for ((i = ${#ROLLED[@]} - 1; i >= 0; i--)); do
    d=${ROLLED[i]}
    kubectl -n maze rollout undo "deployment/$d" >> "$LOG" 2>&1 || true
    kubectl -n maze rollout status "deployment/$d" --timeout=300s >> "$LOG" 2>&1 || true
  done
}
for t in "${TODO[@]}"; do
  if ! kubectl -n maze set image "deployment/$t" "$t=$RBD_ECR@${TDIG[$t]}" >> "$LOG" 2>&1; then
    undo_all
    ci_fail "kubectl set image of $t failed; rolled back ${ROLLED[*]:-nothing}, baseline.json unchanged"
  fi
  ROLLED+=("$t")
done
for t in "${TODO[@]}"; do
  if ! kubectl -n maze rollout status "deployment/$t" --timeout="${RBD_ROLLOUT_TIMEOUT:-300s}" >> "$LOG" 2>&1; then
    undo_all
    ci_fail "rollout of $t did not complete; rolled back ${ROLLED[*]}, baseline.json unchanged"
  fi
done
# rollout status returns once the new pods are ready, while an old pod may still be terminating and serving for its grace
# period. Wait until every pod of each service runs DIGEST (a terminating pod is listed until it is gone).
for t in "${TODO[@]}"; do
  others=unknown
  for _ in $(seq 1 "${RBD_POD_WAIT_S:-180}"); do
    ids=$(kubectl -n maze get pods -l "app=$t" -o jsonpath='{range .items[*]}{.status.containerStatuses[*].imageID}{"\n"}{end}' 2>> "$LOG") || ids=""
    others=$(grep -v -e "@${TDIG[$t]}\$" -e '^$' <<< "$ids" || true)
    [[ -n $ids && -z $others ]] && break
    others=${others:-no pod listed}
    sleep 1
  done
  [[ -z $others ]] || ci_fail "DEPLOYED (baseline.json not updated), but $t still has pods of another image ($(head -c 200 <<< "$others")): refit.sh not run; run both by hand once they are gone"
done
# Then let the old image's spans age out of the trace files the refit will copy: copy_traces.sh takes every Collector file
# that may hold spans of [window start - 120 s, ...], each file covers about 70 s (rotated by size at the demo's load), so
# the refit's input reaches about 190 s before its window, and rhobound check counts image digests over the whole input,
# not only inside --window (a CLI fix is pending). The day's three post-deploy refits were refused (trace.mixed_images)
# with no old-image span inside the window; 150 s was not enough (T2, 2026-10-30 19:06Z). 240 s is.
settle=${RBD_SETTLE_S:-240}
[[ -n ${SUDO_USER:-} ]] && settle=240   # tests only may shorten it
echo "deploy: ${TODO[*]} run only their candidates; waiting ${settle} s for the old image's spans to leave the trace files" >&2
sleep "$settle"
python3 -I - "$RBD_HOME/baseline.json" "$SERVICE" "$DIGEST" "$GIT_SHA" "${TPAIRS[@]:1}" <<'PY' || ci_fail "baseline.json update failed (the image IS deployed)"
import datetime, json, os, sys
path, svc, digest, sha = sys.argv[1:5]
pairs = [x.split("=", 1) for x in sys.argv[5:]]
targets = [t for t, _ in pairs]
b = json.load(open(path))
now = datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
for t, d in pairs:   # every service the pass covers, each to its own image (one already at it stays at it)
    b.setdefault("services", {})[t] = d
b["updated_at"] = now
b["last_deploy"] = {"service": svc, "services": targets, "digest": digest, "git_sha": sha, "at": now}
if len({d for _, d in pairs}) > 1:
    b["last_deploy"]["digests"] = dict(pairs)
tmp = path + ".tmp"
with open(tmp, "w") as f:
    f.write(json.dumps(b, indent=1, sort_keys=True) + "\n")
os.replace(tmp, path)
PY
if [[ $GIT_SHA =~ ^[0-9a-f]{40}$ && -d $RBD_HOME/runs/$GIT_SHA ]]; then
  printf '{"service":"%s","services":%s,"digest":"%s","deployed_at":"%s"}\n' "$SERVICE" "$(ci_jlist "${TARGETS[@]}")" "$DIGEST" \
    "$STAMP" > "$RBD_HOME/runs/$GIT_SHA/deploy.json"
fi
NAME=deploy-$SERVICE-${DIGEST:7:12}-$STAMP
echo "deploy: ${TARGETS[*]} now run $DIGEST; refit $NAME (a production window, then the fit)" >&2
"$RBD_ROOT/ci/refit.sh" "$NAME" >> "$LOG" 2>&1 || ci_fail "DEPLOYED, but refit.sh $NAME failed: run it by hand before the next gate"
rbd_unlock
printf '{"step":"deploy","ok":true,"service":"%s","services":%s,"digest":"%s","git_sha":"%s","refit":"%s"}\n' "$SERVICE" \
  "$(ci_jlist "${TARGETS[@]}")" "$DIGEST" "$GIT_SHA" "$NAME"
