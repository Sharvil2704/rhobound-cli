#!/usr/bin/env bash
# demo_live.sh: the judges' live demo on a running bed. Each demo is one multi-image change made from the patches in
# changes/demo/ (real code a coding agent wrote in the experiments; the plant is the T9 spec written the direct way):
#   pass     pricing + media (two images): the gate passes in about 9 min (RESULTS-4 V4: pass in 9.2 min, production clean)
#   block    rank + pricing + the direct 7x7 media sharpen (three images): the gate blocks before production, naming media
#            (V2: block in 9.7 min; production measured +38 ms at mobile and web)
#   single   pricing alone (one image): about 7.5 min, the single-image case of RESULTS-3
#   edge     rank + pricing + media (three images): sits at the 4-ms bar at mobile (V1, V1b: inconclusive; production
#            clean). Do not show it live as a pass: its verdict depends on that run's A/B noise.
# For each: a branch of the app repository's main with the patches and a change request (rbd.change-request/v2), a PR
# (never merged), the gate (CI on the bed's runner: one build per image, the A/Bs at once, one prediction, one signed
# verdict), then what it decided: the verdict and its rules, every entry's predicted change and band, the A/B step's
# time and nodes. --truth also deploys the change once to measure production (verify/truthx.sh: B0, deploy, warm-up, C,
# rollback; about 18 min) and says whether each entry landed inside its predicted band.
#   usage: bash orch/demo_live.sh [--truth] [--dry] DEMO...      (from bed/; REPO: the app repository, e.g. you/maze-app)
#   --dry: no network. The branches are built in a scratch clone of bed/repo and each service's tree is checked against the
#          tree the experiments gated; nothing is pushed.
# Env: REPO (or state/kit.env's), RBD_SCRATCH [$TMPDIR/rbd], DEMO_CI_WAIT [3600 s].
set -uo pipefail
HERE=$(dirname "$(readlink -f "$0")")
BED=$(cd "$HERE/.." && pwd)
P=$BED/changes/demo
SCR=${RBD_SCRATCH:-${TMPDIR:-/tmp}/rbd}/demo
TRUTH=0 DRY=0 DEMOS=()
for a in "$@"; do case $a in --truth) TRUTH=1 ;; --dry) DRY=1 ;; -h | --help) sed -n '2,25p' "$0"; exit 0 ;; *) DEMOS+=("$a") ;; esac; done
(( ${#DEMOS[@]} )) || { echo "usage: bash orch/demo_live.sh [--truth] [--dry] pass|block|single|edge ..." >&2; exit 2; }
say() { echo "[demo $(date -u +%H:%M:%S)] $*"; }
die() { say "$*"; exit 1; }
# each demo: its services in order, and each service's patch; the service trees the experiments gated (git tree ids)
declare -A SVCS=([pass]="pricing media" [block]="rank pricing media" [single]="pricing" [edge]="rank pricing media")
declare -A PATCH=([pass]="pricing:pricing-promotions media:media-sharpen" [block]="rank:rank-mmr pricing:pricing-promotions media:media-sharpen-direct"
  [single]="pricing:pricing-promotions" [edge]="rank:rank-mmr pricing:pricing-promotions media:media-sharpen")
declare -A TREE=([rank-mmr]=0c12ec0ec5aec0f10b4f3d33d78975d6d600b326 [pricing-promotions]=9dc6812950abbe1e55d3402f42e02908f72b1e33
  [media-sharpen]=82a9fed6fdad869efd6dfecdc0e24425177f1e91 [media-sharpen-direct]=876ec2ee467bbaf7268987596e3cf2ad44a9ea19
  [fraud-velocity]=7909868b4781b8832d22d5f69aa7d9a59e4b2c7c)
declare -A WHY=([pass]="two images, only media on mobile's path: expect pass" [block]="the plant pushes media to 80% busy: expect block"
  [single]="one image: expect pass" [edge]="rank and media both on /feed: expect inconclusive or pass (at the bar)")
for d in "${DEMOS[@]}"; do [[ -n ${SVCS[$d]:-} ]] || die "unknown demo '$d' (pass block single edge)"; done
if (( ! DRY )); then
  [[ -z ${REPO:-} && -r $BED/state/kit.env ]] && REPO=$(sed -n 's/^REPO=//p' "$BED/state/kit.env" | head -n 1)
  [[ ${REPO:-} =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]] || die "set REPO to the app repository (owner/name) that orch/publish_main.sh made"
  command -v gh > /dev/null || die "gh not found"
fi
mkdir -p "$SCR"
W=$(mktemp -d "$SCR/run.XXXXXX")
if (( DRY )); then
  if ! { cp -r "$BED/repo" "$W/app" && git -C "$W/app" init -q && git -C "$W/app" add -A &&
    git -C "$W/app" -c user.name=demo -c user.email=demo@invalid commit -qm "bed/repo"; }; then die "cannot make a scratch clone of bed/repo"; fi
else
  gh repo clone "$REPO" "$W/app" -- -q || die "cannot clone $REPO"
fi
git -C "$W/app" config user.name "${GIT_AUTHOR_NAME:-rhobound demo}"
git -C "$W/app" config user.email "${GIT_AUTHOR_EMAIL:-demo@invalid}"
base=$(git -C "$W/app" rev-parse HEAD)
# shellcheck disable=SC2016  # $1 expands on the tools machine, not here
fetch() { bash "$HERE/rbd.sh" run bash -c 'f=$1; [ -f "$f" ] && [ ! -L "$f" ] || exit 3; head -c 8000000 "$f"' x "$1"; }
rc=0
for d in "${DEMOS[@]}"; do
  br=demo-$d-$(date -u +%Y%m%d%H%M%S)
  say "$d: ${SVCS[$d]} (${WHY[$d]})"
  git -C "$W/app" checkout -q -B "$br" "$base" || die "$d: cannot branch"
  for sp in ${PATCH[$d]}; do
    s=${sp%%:*} p=${sp#*:}
    git -C "$W/app" apply --index "$P/$p.patch" || die "$d: $p.patch does not apply on $(git -C "$W/app" rev-parse --short HEAD)"
    got=$(git -C "$W/app" write-tree --prefix="maze/app/internal/svc/$s/" 2> /dev/null)
    [[ $got == "${TREE[$p]}" ]] || die "$d: after $p.patch, $s's tree is $got, not the gated ${TREE[$p]}"
  done
  python3 -I -c 'import json,sys; print(json.dumps({"schema": "rbd.change-request/v2", "services": sys.argv[1].split(),
    "summary": "rhobound demo %s: %s (changes/demo/ of the rhobound-cli repository)" % (sys.argv[2], sys.argv[1])}))' \
    "${SVCS[$d]}" "$d" > "$W/app/rhobound-change.json"
  if ! { git -C "$W/app" add rhobound-change.json && git -C "$W/app" commit -qm "rhobound demo $d: ${SVCS[$d]}"; }; then die "$d: commit failed"; fi
  sha=$(git -C "$W/app" rev-parse HEAD)
  if (( DRY )); then say "$d: --dry: branch $br at ${sha:0:12}, every service tree matches the gated one; nothing pushed"; continue; fi
  git -C "$W/app" push -q origin "$br" || die "$d: push failed"
  pr=$(gh pr create --repo "$REPO" --base main --head "$br" --title "[rhobound demo] $d: ${SVCS[$d]}" \
    --body "A rhobound demo change (bed/orch/demo_live.sh $d). Measured by the gate only. Never merge." 2>&1 | tail -n 1)
  say "$d: PR $pr; waiting for the gate"
  rid="" t0=$(date +%s)
  until [[ -n $rid ]]; do rid=$(gh api "repos/$REPO/actions/runs?head_sha=$sha" --jq '.workflow_runs[0].id // empty' 2> /dev/null); [[ -n $rid ]] || sleep 10; done
  until [[ $(gh api "repos/$REPO/actions/runs/$rid" --jq .status 2> /dev/null) == completed ]]; do
    (( $(date +%s) - t0 < ${DEMO_CI_WAIT:-3600} )) || die "$d: the gate did not finish in ${DEMO_CI_WAIT:-3600} s (run $rid)"
    sleep 30
  done
  o=$W/$d; mkdir -p "$o"
  gh api "repos/$REPO/actions/runs/$rid/jobs" > "$o/ci-jobs.json"
  R=/var/lib/rbd/runs/$sha
  fetch "$R/gate/gate.json" > "$o/gate.json" || { say "$d: no gate.json: the gate failed before its verdict (gh run view $rid --repo $REPO --log-failed)"; rc=1; continue; }
  fetch "$R/ab-all.json" > "$o/ab-all.json" 2> /dev/null || true
  python3 -I - "$o" "$d" << 'PY'
import datetime as dt, json, os, re, sys
o, d = sys.argv[1:3]
g = json.load(open(os.path.join(o, "gate.json")))
def ts(s): return dt.datetime.fromisoformat(re.sub(r"(\.\d{6})\d+", r"\1", s.replace("Z", "+00:00")))
st = json.load(open(os.path.join(o, "ci-jobs.json")))["jobs"][0]["steps"]
a = next((x for x in st if x["name"].startswith("A/B in the cluster")), None)
b = next((x for x in st if x["name"].startswith("sign the verdict")), None)
rules = [r["rule"] for r in g.get("rules", []) if r.get("effect") in ("block", "inconclusive")]
print("  verdict: %s %s" % (g["verdict"].upper(), ("(" + ", ".join(rules) + ")") if rules else ""))
for e in g["entries"]:
    c, bd = e["change_ms"], e["band_ms"]
    print("    %-11s predicted change %+7.2f .. %+7.2f ms   band %+7.2f .. %+7.2f   %s" % (e["entry"], c["lo"], c["hi"], bd["lo"], bd["hi"], e["effect"]))
if a and b and a.get("started_at") and b.get("completed_at"):
    print("  rhobound's own CI time (first A/B to signature): %.1f min" % ((ts(b["completed_at"]) - ts(a["started_at"])).total_seconds() / 60))
p = os.path.join(o, "ab-all.json")
if os.path.exists(p) and os.path.getsize(p):
    j = json.load(open(p))
    print("  A/Bs at once: %d, %d s, on %s" % (j["parallel"], j["seconds"], ", ".join(x["node"] for x in j["services"])))
for x in g.get("decide_with") or []:
    print("  decide with: " + x)
PY
  if (( TRUTH )); then
    args=()
    for s in ${SVCS[$d]}; do args+=("$s=$(fetch "$R/candidate-$s.json" | python3 -I -c 'import json,sys; print(json.load(sys.stdin)["digest"])')"); done
    n=demo-$d-$(date -u +%H%M%S)
    say "$d: measuring production (truthx $n, about 18 min; production goes back to its baseline after)"
    bash "$HERE/rbd.sh" bg "$n" env RBD_LOCK_WAIT=1800 /opt/rbd/verify/truthx.sh "$n" "${args[@]}" > /dev/null || { say "$d: truthx cannot start"; rc=1; continue; }
    until bash "$HERE/rbd.sh" tail "$n" 3 2> /dev/null | grep -q '^== .*: done, exit'; do sleep 20; done
    for f in b0.load.json c.load.json; do fetch "/var/lib/rbd/verify/truthx/$n/$f" > "$o/$f"; done
    python3 -I "$BED/verify/regress.py" --b0 "$o/b0.load.json" --c "$o/c.load.json" --policy "$BED/repo/policy/gate.json" --out "$o/regress.json" > /dev/null 2>&1
    python3 -I - "$o" << 'PY'
import json, os, sys
o = sys.argv[1]
r = json.load(open(os.path.join(o, "regress.json"))); g = json.load(open(os.path.join(o, "gate.json")))
band = {e["entry"]: e["band_ms"] for e in g["entries"]}
print("  production: %s" % ("clean" if r.get("production_ok") else "REGRESSED"))
for e in r["entries"]:
    m, b = e.get("change_ms"), band.get(e["entry"])
    if m is None or b is None: continue
    print("    %-11s measured %+7.2f ms   inside the predicted band: %s" % (e["entry"], m, "yes" if b["lo"] <= m <= b["hi"] else "NO"))
PY
  fi
done
say "done (scratch $W)"
exit "$rc"
