#!/usr/bin/env bash
# automerge.sh (SPEC2 S8): merges a bench PR on a pass, one at a time, and records its gate -> merge -> deploy timeline.
#   bash orch/automerge.sh pr N --task TASK [--wait S]  one PR: waits (up to S s [7200]) for its rhobound/verdict, merges a
#                                                       pass, waits for the deploy.yml run of the merge commit (S9)
#   bash orch/automerge.sh once                         every open PR labelled rbd-bench that a state/bench/<task>/pr.json
#                                                       (an earlier run's bench funnel, not kept here) names: records each verdict, merges at most ONE pass
#   bash orch/automerge.sh watch [INTERVAL]             'once' every INTERVAL s [300] until the kill switch exists
# Runs HERE (your workstation) with gh only: no ssh, no AWS, no model key. It waits for a gate (~15-25 min) and a deploy with
# its refit (~15 min): run it detached (setsid nohup bash orch/automerge.sh ... > state/logs/automerge-T.log 2>&1 < /dev/null &).
# It reads ONLY typed state, never a PR's title, body, comments, commit messages or any model text:
#   the PR (gh pr view --json): state OPEN, not a draft, label rbd-bench, head branch rbd/*, base main, not from a fork, author
#     = this gh account (make_prs.sh opened it), mergeable MERGEABLE (UNKNOWN: asked again), files[].path only maze/app/** and
#     rhobound-change.json (what make_prs.sh and pr-check.sh admit), head sha 40 hex;
#   the newest commit status 'rhobound/verdict' ON THAT EXACT HEAD SHA (gh api .../commits/HEAD/statuses), created by
#     AUTOMERGE_STATUS_CREATOR [github-actions[bot]: gate.yml's token; empty = not checked]: state success is the only merge
#     trigger, and its description must then start 'pass: ' (gate.yml writes 'VERDICT: RULE'; the rule word is recorded);
#     pending or absent = wait; failure/error = a non-pass verdict: recorded, the PR left open (never closed or commented);
#   main's tip (git/ref/heads/main) and compare MAIN...HEAD: merge base = main's tip, behind_by 0 (the gate measured against the
#     production that main is; a PR cut from an older main is stale: re-cut it with make_prs.sh);
#   the gate.yml run of the head (gate_run, gate_started, gate_ended) and the deploy.yml run of the merge commit.
# A PLANTED change is never merged, whatever its verdict (SPEC3 F9: a planted regression must never reach production through
# deploy.yml): a PR labelled rbd-plant, or whose head branch is rbd/cN-plant (changes/plant.py + make_prs.sh), is refused
# explicitly as soon as it is read (pr: exit 3 at once, even while its gate runs; once: never a candidate; merge_one: refused
# before the variance guard and the merge, on the facts re-read under the lock), and assess() lists it among the reasons, so it
# is never 'ready' either. Fail closed: a PR whose labels or branch cannot be told is refused the same way (pr.json
# unreadable, labels not a list, a label that is not an object with a string name, headRefName not a string).
# Merge: gh pr merge N --merge --match-head-commit HEAD (GitHub refuses when the head moved since it was read). At most one
# merge in flight: state/automerge.inflight is written right after a merge and removed once that merge's deploy.yml run has
# completed and is in the timeline; every merge happens under a flock on state/automerge.lock and first finishes (waits for)
# an in-flight one. deploy.sh stays the enforcement point (a KMS-signed pass for that digest); this script only merges.
# Kill switch: state/automerge.stop (any content): no merge from then on (checked before every merge and every loop), exit 5.
# DRYRUN=1: every read, the decision printed as JSON on stdout, no merge, no file written.
# Before merging a pass: AUTOMERGE_GUARD [orch/variance_guard.sh] HEAD must exit 0 (the variance relaxation of 2026-10-30 is for
# improvements only: a variance-changing pass that is not an improvement at every measured service is left open).
# Writes state/bench/<task>/timeline.json (shared schema: task pr head gate_run gate_started gate_ended verdict rule
# merged_at merge_sha deploy_run deploy_ended deploy_ok; atomic replace; a new head resets it) and appends every decision to
# state/bench/<task>/automerge.jsonl.
# Exit (pr): 0 merged and its deploy.yml run succeeded (once/watch: 0 unless an error); 1 error, merge refused or the deploy
# failed; 3 not merged: the verdict is not pass, or a precondition failed (stale base, conflict, files, author, label);
# 4 timed out (no verdict, or the deploy run did not end); 5 kill switch. A planted change (rbd-plant) is exit 3.
# Env: REPO [Sharvil2704/rhobound-maze-bed]  RBD_STATE [kit/state]  DRYRUN [0]  AUTOMERGE_POLL [60 s]  AUTOMERGE_DEPLOY_WAIT
#      [5400 s]  AUTOMERGE_LOCK_WAIT [7200 s]  AUTOMERGE_STATUS_CREATOR [github-actions[bot]]
set -euo pipefail
DEMO=$(cd "$(dirname "$0")/.." && pwd)
REPO=${REPO:-Sharvil2704/rhobound-maze-bed}
STATE=${RBD_STATE:-$DEMO/state}
DRYRUN=${DRYRUN:-0}
POLL=${AUTOMERGE_POLL:-60}
DEPLOY_WAIT=${AUTOMERGE_DEPLOY_WAIT:-5400}
LOCK_WAIT=${AUTOMERGE_LOCK_WAIT:-7200}
GUARD=${AUTOMERGE_GUARD-$DEMO/orch/variance_guard.sh}   # empty: no guard (tests); see merge_one
CREATOR=${AUTOMERGE_STATUS_CREATOR-github-actions[bot]}
LABEL=rbd-bench
PLANT_LABEL=rbd-plant   # changes/plant.py's planted changes: NEVER merged (is_plant, assess)
WHY=""
STOP=$STATE/automerge.stop
INFL=$STATE/automerge.inflight
say() { echo "[automerge $(date -u +%H:%M:%S)] $*" >&2; }
die() { echo "automerge: error: $*" >&2; exit "${2:-1}"; }
usage() { sed -n '2,/^# Env:/p' "$0" | sed 's/^# \{0,1\}//' >&2; exit 2; }
[[ $# -ge 1 ]] || usage
for c in gh python3 flock; do command -v "$c" > /dev/null || die "$c is required"; done
[[ $POLL =~ ^[0-9]+$ && $DEPLOY_WAIT =~ ^[0-9]+$ && $LOCK_WAIT =~ ^[0-9]+$ ]] || die "AUTOMERGE_* must be whole seconds" 2
mkdir -p "$STATE/bench"
W=$(mktemp -d "$STATE/.automerge.XXXXXX")
trap 'rm -rf "$W"' EXIT

ghj() { # OUT gh ARGS...: gh's stdout (JSON) into OUT, or say why not and fail
  local o=$1
  shift
  if gh "$@" > "$o.tmp" 2> "$W/gh.err"; then mv -f "$o.tmp" "$o"; return 0; fi
  say "gh $* failed: $(head -c 300 "$W/gh.err" | tr -cd '[:print:] ')"
  return 1
}
stopped() { [[ -e $STOP ]]; }
now() { date +%s; }

ME=""
need_me() { # the gh account's login: bench PRs are this account's (make_prs.sh opens them)
  [[ -n $ME ]] && return 0
  ME=$(gh api user 2> /dev/null | python3 -I -c 'import json,sys; print(json.load(sys.stdin)["login"])') ||
    die "cannot read the gh account (gh auth status)"
}

# tl TASK PATCH_JSON: merge PATCH into state/bench/TASK/timeline.json (only the shared keys; a new head starts a fresh one)
tl() {
  [[ $DRYRUN == 1 ]] && return 0
  mkdir -p "$STATE/bench/$1"
  python3 -I - "$STATE/bench/$1/timeline.json" "$1" "$2" << 'PY'
import json, os, sys
path, task, patch = sys.argv[1], sys.argv[2], json.loads(sys.argv[3])
KEYS = ["task", "pr", "head", "gate_run", "gate_started", "gate_ended", "verdict", "rule", "merged_at", "merge_sha",
        "deploy_run", "deploy_ended", "deploy_ok"]
fresh = dict.fromkeys(KEYS)
try:
    cur = json.load(open(path))
except (OSError, ValueError):
    cur = fresh
if patch.get("head") and cur.get("head") and patch["head"] != cur["head"]:
    cur = dict(fresh)
out = {k: cur.get(k) for k in KEYS}
out.update({k: v for k, v in patch.items() if k in KEYS})
out["task"] = task
tmp = path + ".tmp"
with open(tmp, "w") as f:
    f.write(json.dumps(out, indent=1) + "\n")
os.replace(tmp, path)
PY
}
logd() { # TASK JSON: one decision line in state/bench/TASK/automerge.jsonl
  [[ $DRYRUN == 1 ]] && return 0
  mkdir -p "$STATE/bench/$1"
  python3 -I -c 'import json,sys,time; d=json.loads(sys.argv[1]); d["at"]=time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()); print(json.dumps(d, sort_keys=True))' \
    "$2" >> "$STATE/bench/$1/automerge.jsonl"
}

# assess N: every typed fact about PR N -> $W/a.json {pr, head, branch, verdict, rule, gate_*, main, ready, wait, reasons}
assess() {
  local n=$1 head main
  need_me
  ghj "$W/pr.json" pr view "$n" --repo "$REPO" \
    --json number,state,isDraft,labels,headRefName,headRefOid,baseRefName,isCrossRepository,author,mergeable,files || return 1
  head=$(python3 -I -c 'import json,re,sys; h=json.load(open(sys.argv[1])).get("headRefOid") or ""; print(h if re.fullmatch("[0-9a-f]{40}", h) else "")' "$W/pr.json")
  [[ -n $head ]] || { say "PR $n: no 40-hex head sha"; return 1; }
  ghj "$W/st.json" api "repos/$REPO/commits/$head/statuses?per_page=100" || return 1
  ghj "$W/main.json" api "repos/$REPO/git/ref/heads/main" || return 1
  main=$(python3 -I -c 'import json,re,sys; h=(json.load(open(sys.argv[1])).get("object") or {}).get("sha") or ""; print(h if re.fullmatch("[0-9a-f]{40}", h) else "")' "$W/main.json")
  [[ -n $main ]] || { say "main has no 40-hex tip"; return 1; }
  ghj "$W/cmp.json" api "repos/$REPO/compare/$main...$head" || return 1
  ghj "$W/gr.json" run list --repo "$REPO" --workflow gate.yml --commit "$head" --limit 1 \
    --json databaseId,status,conclusion,createdAt,startedAt,updatedAt,headSha || return 1
  python3 -I - "$W" "$ME" "$LABEL" "$CREATOR" "$main" "$PLANT_LABEL" > "$W/a.json" << 'PY'
import json, os, re, sys
W, me, label, creator, main, plant = sys.argv[1:7]
ld = lambda n: json.load(open(os.path.join(W, n)))
pr, st, cmp_, gr = ld("pr.json"), ld("st.json"), ld("cmp.json"), ld("gr.json")
head = pr["headRefOid"]
a = {"pr": pr.get("number"), "head": head, "branch": pr.get("headRefName"), "verdict": None, "rule": None,
     "status_state": None, "gate_run": None, "gate_started": None, "gate_ended": None, "main": main, "ready": False,
     "wait": [], "reasons": []}
R, Wt = a["reasons"].append, a["wait"].append
if pr.get("state") != "OPEN":
    R("the PR is %s, not OPEN" % pr.get("state"))
if pr.get("isDraft"):
    R("a draft")
if label not in [l.get("name") for l in pr.get("labels") or []]:
    R("no label %s" % label)
if plant in [l.get("name") for l in pr.get("labels") or []]:
    R("label %s: a planted change (changes/plant.py) is never merged automatically" % plant)
if re.fullmatch(r"rbd/c[0-9]{1,2}-plant", str(pr.get("headRefName"))):
    R("head branch %s is a planted change (rbd/cN-plant): never merged automatically" % pr.get("headRefName"))
if not re.fullmatch(r"rbd/[A-Za-z0-9][A-Za-z0-9._-]{0,63}", str(pr.get("headRefName"))):
    R("head branch %r is not rbd/*" % pr.get("headRefName"))
if pr.get("baseRefName") != "main":
    R("base %r is not main" % pr.get("baseRefName"))
if pr.get("isCrossRepository") is not False:
    R("the head is not a branch of this repository")
if (pr.get("author") or {}).get("login") != me:
    R("author %r is not this gh account %r (make_prs.sh opens bench PRs)" % ((pr.get("author") or {}).get("login"), me))
files = [f.get("path") for f in pr.get("files") or []]
if not files or len(files) >= 100:
    R("%d changed files (1..99 checkable)" % len(files))
bad = [p for p in files if not re.fullmatch(r"maze/app/.+|rhobound-change\.json", str(p))]
if bad:
    R("files outside maze/app/ and rhobound-change.json: %s" % ", ".join(map(str, bad[:5])))
m = pr.get("mergeable")
if m == "UNKNOWN" or m is None:
    Wt("mergeability not computed yet")
elif m != "MERGEABLE":
    R("mergeable %s" % m)
if (cmp_.get("merge_base_commit") or {}).get("sha") != main or cmp_.get("behind_by") != 0:
    R("main moved since the PR was cut (behind_by %s): stale verdict, re-cut it with make_prs.sh" % cmp_.get("behind_by"))
s = next((x for x in st if isinstance(x, dict) and x.get("context") == "rhobound/verdict"), None) if isinstance(st, list) else None
if s is None:
    a["verdict"] = "pending"
    Wt("no rhobound/verdict status on %s yet" % head[:12])
else:
    a["status_state"] = s.get("state")
    who = (s.get("creator") or {}).get("login")
    d = str(s.get("description") or "")
    dm = re.match(r"(pass|block|inconclusive): ([A-Za-z0-9_@.:-]{0,64})", d)
    if creator and who != creator:
        R("the rhobound/verdict status was created by %r, not %r" % (who, creator))
    if s.get("state") == "pending":
        a["verdict"] = "pending"
        Wt("gate running")
    elif s.get("state") == "success":
        a["verdict"], a["rule"] = (dm.group(1), dm.group(2)) if dm else ("error", None)
        if a["verdict"] != "pass":
            R("status success but its description is not 'pass: RULE'")
    elif s.get("state") == "failure" and dm and dm.group(1) != "pass":
        a["verdict"], a["rule"] = dm.group(1), dm.group(2)
    else:
        a["verdict"] = "error"
        R("status %s: no signed verdict" % s.get("state"))
runs = [r for r in gr if isinstance(r, dict) and r.get("headSha") == head] if isinstance(gr, list) else []
if runs:
    r = runs[0]
    a["gate_run"] = r.get("databaseId")
    a["gate_started"] = r.get("startedAt") or r.get("createdAt")
    a["gate_ended"] = r.get("updatedAt") if r.get("status") == "completed" else None
if a["verdict"] in ("block", "inconclusive", "error"):
    a["wait"] = []
a["ready"] = a["verdict"] == "pass" and not a["reasons"] and not a["wait"]
print(json.dumps(a, sort_keys=True))
PY
}
af() { python3 -I -c 'import json,sys; v=json.load(open(sys.argv[1])).get(sys.argv[2]); print("" if v is None else (json.dumps(v) if isinstance(v,(list,dict,bool)) else v))' "$W/a.json" "$1"; }
# is_plant: 0 when PR $W/pr.json (as assess just read it) is a planted change (WHY: the label and/or the branch), and also
# when that cannot be told (fail closed, WHY says so): pr.json unreadable, labels not a list (null or missing included), a
# label that is not an object with a string name, or headRefName not a string (null or missing included); 1 only when it is
# certainly not one (labels a list of named objects, possibly empty, without rbd-plant; a branch name not rbd/cN-plant)
is_plant() {
  local rc=0
  WHY=$(python3 -I - "$W/pr.json" "$PLANT_LABEL" << 'PY'
import json, re, sys
pr, plant = json.load(open(sys.argv[1])), sys.argv[2]
labels, branch = pr.get("labels"), pr.get("headRefName")
odd = []
if not isinstance(labels, list):
    odd.append("labels %s" % json.dumps(labels)[:60])
elif not all(isinstance(l, dict) and isinstance(l.get("name"), str) for l in labels):
    odd.append("a label without a name: %s" % json.dumps(labels)[:120])
if not isinstance(branch, str):
    odd.append("headRefName %s" % json.dumps(branch)[:60])
if odd:
    print("; ".join(odd))
    sys.exit(2)
why = []
if plant in [l["name"] for l in labels]:
    why.append("label " + plant)
if re.fullmatch(r"rbd/c[0-9]{1,2}-plant", branch):
    why.append("head branch " + branch)
print(" and ".join(why))
sys.exit(0 if why else 10)
PY
) || rc=$?
  ((rc != 10)) || return 1
  if ((rc == 2)); then
    WHY="its labels or branch cannot be told ($WHY): refused as if planted"
  elif ((rc != 0)); then
    WHY="its labels and branch cannot be read: refused as if planted"
  fi
  return 0
}
# the a.json facts the timeline keeps
tl_of_a() { python3 -I -c 'import json,sys; a=json.load(open(sys.argv[1])); print(json.dumps({k: a[k] for k in ("head","gate_run","gate_started","gate_ended","verdict","rule")} | {"pr": a["pr"]}))' "$W/a.json"; }

# finish_inflight: wait for the in-flight merge's deploy.yml run, record it, clear the marker. 0 deployed ok, 1 failed, 4 timeout
finish_inflight() {
  [[ -e $INFL ]] || return 0
  local task m t0 st
  task=$(python3 -I -c 'import json,sys; print(json.load(open(sys.argv[1]))["task"])' "$INFL")
  m=$(python3 -I -c 'import json,sys; print(json.load(open(sys.argv[1]))["merge_sha"])' "$INFL")
  [[ $m =~ ^[0-9a-f]{40}$ ]] || die "state/automerge.inflight names no merge sha: fix it by hand"
  say "in flight: $task's merge ${m:0:12}: waiting for its deploy.yml run (up to ${DEPLOY_WAIT} s)"
  t0=$(now)
  while :; do
    if ghj "$W/dr.json" run list --repo "$REPO" --workflow deploy.yml --commit "$m" --limit 1 \
      --json databaseId,status,conclusion,createdAt,updatedAt,headSha; then
      st=$(python3 -I - "$W/dr.json" "$m" << 'PY'
import json, sys
runs = [r for r in json.load(open(sys.argv[1])) if r.get("headSha") == sys.argv[2]]
if not runs:
    print("none")
elif runs[0].get("status") != "completed":
    print("running %s" % runs[0].get("databaseId"))
else:
    r = runs[0]
    print("done " + json.dumps({"deploy_run": r.get("databaseId"), "deploy_ended": r.get("updatedAt"),
                                 "deploy_ok": r.get("conclusion") == "success"}))
PY
)
      if [[ $st == done* ]]; then
        tl "$task" "${st#done }"
        logd "$task" "{\"action\":\"deployed\",\"merge_sha\":\"$m\",\"run\":${st#done }}"
        rm -f "$INFL"
        if [[ $st == *'"deploy_ok": true'* ]]; then say "$task: deploy.yml run for ${m:0:12} succeeded"; return 0; fi
        say "$task: deploy.yml run for ${m:0:12} did NOT succeed (deploy.sh refused or failed): see gh run view"
        return 1
      fi
    fi
    if (($(now) - t0 >= DEPLOY_WAIT)); then
      say "$task: no completed deploy.yml run for ${m:0:12} after ${DEPLOY_WAIT} s; still in flight (state/automerge.inflight)"
      return 4
    fi
    sleep "$POLL"
  done
}

# merge_one N TASK: under the lock, finish any in-flight merge, re-assess, merge a ready pass, wait for its deploy
merge_one() {
  local n=$1 task=$2 head rc=0
  if [[ $DRYRUN == 1 ]]; then
    assess "$n" || return 1
    if [[ $(af ready) == true ]]; then say "DRYRUN: would merge PR $n at $(af head)"; else say "DRYRUN: PR $n not ready"; fi
    cat "$W/a.json"
    return 0
  fi
  exec 8>> "$STATE/automerge.lock"
  flock -w "$LOCK_WAIT" 8 || { say "another automerge held state/automerge.lock for ${LOCK_WAIT} s"; return 1; }
  finish_inflight || rc=$?
  if ((rc == 4)); then flock -u 8; return 4; fi   # one in flight: never a second merge while the first has not deployed
  rc=0
  if stopped; then say "kill switch state/automerge.stop: PR $n not merged"; flock -u 8; return 5; fi
  assess "$n" || { flock -u 8; return 1; }   # fresh facts under the lock: the head or main may have moved
  tl "$task" "$(tl_of_a)"
  if is_plant; then
    say "PR $n is a planted change ($WHY): automerge.sh never merges it, whatever its verdict ($(af verdict))"
    logd "$task" "{\"action\":\"plant-refused\",\"assess\":$(cat "$W/a.json")}"
    flock -u 8
    return 3
  fi
  if [[ $(af ready) != true ]]; then
    say "PR $n not merged: verdict $(af verdict); $(af reasons) $(af wait)"
    logd "$task" "{\"action\":\"not-merged\",\"assess\":$(cat "$W/a.json")}"
    flock -u 8
    return 3
  fi
  head=$(af head)
  # the variance relaxation of 2026-10-30 is for improvements only (orch/variance_guard.sh): a pass whose A/B changed a variance
  # merges only when every measured service improved; otherwise it is recorded and left open for a person
  if [[ -n $GUARD ]]; then
    local g grc=0
    g=$(bash "$GUARD" "$head" 2> /dev/null) || grc=$?
    logd "$task" "{\"action\":\"variance-guard\",\"pr\":$n,\"rc\":$grc,\"guard\":${g:-null}}"
    if ((grc != 0)); then
      say "PR $n not merged: the variance guard holds it ($(python3 -I -c 'import json,sys; print(json.loads(sys.argv[1]).get("reason"))' "${g:-{\}}" 2> /dev/null || echo unreadable))"
      flock -u 8
      return 3
    fi
    say "PR $n: variance guard: $(python3 -I -c 'import json,sys; print(json.loads(sys.argv[1]).get("reason"))' "$g" 2> /dev/null)"
  fi
  say "PR $n: pass ($(af rule)) at ${head:0:12}, base = main's tip: merging"
  if ! gh pr merge "$n" --repo "$REPO" --merge --match-head-commit "$head" > "$W/merge.out" 2>&1; then
    say "gh pr merge $n refused: $(head -c 300 "$W/merge.out" | tr -cd '[:print:] ')"
    logd "$task" "{\"action\":\"merge-refused\",\"pr\":$n,\"head\":\"$head\"}"
    flock -u 8
    return 1
  fi
  ghj "$W/merged.json" pr view "$n" --repo "$REPO" --json state,mergeCommit,mergedAt,headRefOid || { flock -u 8; return 1; }
  python3 -I - "$W/merged.json" "$head" "$task" "$n" "$INFL" > "$W/mpatch.json" << 'PY' || { say "PR $n: merged, but its merge commit is unreadable: fix state/automerge.inflight by hand"; flock -u 8; return 1; }
import json, os, re, sys
d, head, task, n, infl = json.load(open(sys.argv[1])), sys.argv[2], sys.argv[3], int(sys.argv[4]), sys.argv[5]
m = (d.get("mergeCommit") or {}).get("oid") or ""
if d.get("state") != "MERGED" or not re.fullmatch("[0-9a-f]{40}", m) or d.get("headRefOid") != head:
    sys.exit("not merged at %s: %s" % (head, json.dumps(d)[:300]))
rec = {"task": task, "pr": n, "head": head, "merge_sha": m, "merged_at": d.get("mergedAt")}
with open(infl + ".tmp", "w") as f:
    f.write(json.dumps(rec) + "\n")
os.replace(infl + ".tmp", infl)
print(json.dumps({"merged_at": d.get("mergedAt"), "merge_sha": m}))
PY
  tl "$task" "$(cat "$W/mpatch.json")"
  logd "$task" "{\"action\":\"merged\",\"pr\":$n,\"head\":\"$head\",\"merge\":$(cat "$W/mpatch.json")}"
  say "PR $n merged: $(cat "$W/mpatch.json")"
  finish_inflight || rc=$?
  flock -u 8
  return "$rc"
}

# tasks_of: "PR TASK" lines from state/bench/*/pr.json (written by orch/bench.sh: the only PRs this script touches)
tasks_of() {
  python3 -I - "$STATE/bench" << 'PY'
import glob, json, os, re, sys
for p in sorted(glob.glob(os.path.join(sys.argv[1], "*", "pr.json"))):
    try:
        d = json.load(open(p))
    except (OSError, ValueError):
        continue
    t = os.path.basename(os.path.dirname(p))
    if isinstance(d.get("pr"), int) and d.get("task") == t and re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9_.-]{0,63}", t):
        print(d["pr"], t)
PY
}

once() {
  local n task best="" btask="" rc=0
  declare -A T=()
  while read -r n task; do T[$n]=$task; done < <(tasks_of)
  ghj "$W/list.json" pr list --repo "$REPO" --label "$LABEL" --state open --limit 100 --json number,headRefName || return 1
  while read -r n; do
    task=${T[$n]:-}
    if [[ -z $task ]]; then say "PR $n: labelled $LABEL but no state/bench/*/pr.json names it: left alone"; continue; fi
    assess "$n" || { rc=1; continue; }
    tl "$task" "$(tl_of_a)"
    if is_plant; then
      say "PR $n ($task) is a planted change ($WHY): never merged, whatever its verdict ($(af verdict))"
      logd "$task" "{\"action\":\"plant-refused\",\"assess\":$(cat "$W/a.json")}"
      continue
    fi
    say "PR $n ($task): verdict $(af verdict) $(af rule); ready $(af ready); $(af reasons)"
    if [[ $(af ready) == true && -z $best ]]; then best=$n btask=$task; fi
    if [[ $(af verdict) =~ ^(block|inconclusive|error)$ ]]; then
      logd "$task" "{\"action\":\"recorded\",\"assess\":$(cat "$W/a.json")}"
    fi
  done < <(python3 -I -c 'import json,sys; [print(p["number"]) for p in sorted(json.load(open(sys.argv[1])), key=lambda p: p["number"])]' "$W/list.json")
  if [[ -n $best ]]; then
    if stopped; then say "kill switch: PR $best not merged"; return 5; fi
    merge_one "$best" "$btask" || { local r=$?; ((r == 3)) || rc=$r; }
  fi
  return "$rc"
}

cmd=$1
shift
case $cmd in
  pr)
    [[ $# -ge 3 && $1 =~ ^[0-9]+$ && $2 == --task && $3 =~ ^[A-Za-z0-9][A-Za-z0-9_.-]{0,63}$ ]] || usage
    N=$1 TASK=$3 WAITS=7200
    shift 3
    if [[ $# -ge 2 && $1 == --wait && $2 =~ ^[0-9]+$ ]]; then WAITS=$2; shift 2; fi
    [[ $# -eq 0 ]] || usage
    if [[ -r $STATE/bench/$TASK/pr.json ]]; then
      python3 -I -c 'import json,sys; sys.exit(0 if json.load(open(sys.argv[1])).get("pr") == int(sys.argv[2]) else 1)' \
        "$STATE/bench/$TASK/pr.json" "$N" || die "state/bench/$TASK/pr.json names another PR than $N"
    fi
    t0=$(now)
    while :; do
      stopped && { say "kill switch state/automerge.stop: stopping"; exit 5; }
      assess "$N" || exit 1
      tl "$TASK" "$(tl_of_a)"
      if is_plant; then
        say "PR $N ($TASK) is a planted change ($WHY): automerge.sh never merges it, whatever its verdict ($(af verdict)); left open"
        logd "$TASK" "{\"action\":\"plant-refused\",\"assess\":$(cat "$W/a.json")}"
        [[ $DRYRUN != 1 ]] || cat "$W/a.json"
        exit 3
      fi
      v=$(af verdict)
      if [[ $(af ready) == true ]]; then
        rc=0; merge_one "$N" "$TASK" || rc=$?
        exit "$rc"
      fi
      if [[ $v =~ ^(block|inconclusive|error)$ || -n $(af reasons | tr -d '[]') ]]; then
        say "PR $N ($TASK): verdict $v $(af rule): not merged, left open; $(af reasons)"
        logd "$TASK" "{\"action\":\"not-merged\",\"assess\":$(cat "$W/a.json")}"
        [[ $DRYRUN != 1 ]] || cat "$W/a.json"
        exit 3
      fi
      if (($(now) - t0 >= WAITS)); then
        say "PR $N ($TASK): still $v after ${WAITS} s ($(af wait)): not merged"
        logd "$TASK" "{\"action\":\"timeout\",\"assess\":$(cat "$W/a.json")}"
        exit 4
      fi
      sleep "$POLL"
    done
    ;;
  once) [[ $# -eq 0 ]] || usage; stopped && { say "kill switch state/automerge.stop"; exit 5; }; once ;;
  watch)
    IV=${1:-300}
    [[ $IV =~ ^[0-9]+$ ]] || usage
    while :; do
      stopped && { say "kill switch state/automerge.stop: watch ends"; exit 5; }
      once || say "this round ended with exit $?"
      sleep "$IV"
    done
    ;;
  *) usage ;;
esac
