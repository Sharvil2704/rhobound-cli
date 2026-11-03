#!/usr/bin/env bash
# make_prs: open prepared changes as PRs on the PRIVATE demo repo: one branch rbd/<name> each, cut from the CURRENT main.
#   bash changes/make_prs.sh NAME...          NAME: c1-noop c2-auth-small c3-auth-mid c4-pay-wait c5-model (best: one at a time)
#                                             (c5-model: written by orch/agent_take.sh from the model's run)
#                                             cN-bench (SPEC2 S6: the bench funnel's selected approach, via orch/agent_take.sh;
#                                             title from title.txt; the PR gets the label rbd-bench, created when missing,
#                                             which orch/automerge.sh watches)
#                                             cN-muse (the Muse Code experiment, orch/muse_arm.sh: one iteration's change via
#                                             orch/agent_take.sh; title from title.txt; the PR gets the label rbd-muse, created
#                                             when missing: NEVER merged, orch/automerge.sh merges only rbd-bench PRs; arm R
#                                             deploys a gate pass and arm C its built image through the truth bracket, out of
#                                             band, and production returns to baseline after every measurement)
#                                             cN-plant (SPEC3 F9: a planted change written by changes/plant.py; title from
#                                             title.txt; manifest.json must be rbd.plant-change/v1 with never_merge true,
#                                             patch_sha256 = sha256 of change.patch (an edit after plant.py is refused) and
#                                             compiled true (plant.py without --no-compile; PLANT_UNCOMPILED=1: tests only);
#                                             the PR is a DRAFT labelled rbd-plant, created when missing: orch/automerge.sh
#                                             refuses to merge any rbd-plant PR, whatever its verdict; an open PR of a
#                                             cN-plant must hold exactly the folder's change on its base, else refused: a
#                                             reused name never measures an old patch against a new manifest)
#   DRYRUN=1 bash changes/make_prs.sh NAME    apply and commit in a temp clone; no push, no PR (it says the label and
#                                             draft state the PR would get)
# Runs on your workstation with gh (logged in) and git over https. Never pushes main, never force-pushes; refuses unless the
# repo is private and allows merge commits only. An open PR for rbd/<name> is reported, not re-created (cN-plant: only
# when its head holds exactly the folder's change; another change there is refused, exit 1).
# A PR = change.patch's maze/app part applied to main + rhobound-change.json written fresh (main may hold an older one from a
# merged PR). Refused unless every path it changes against main is under maze/app/ or is rhobound-change.json (a patch,
# prepared or model-written, never reaches .github/ or policy/). Every PR writes rhobound-change.json, so of several open
# PRs only one can be merged: the day keeps c1..c4 open, merges exactly one and closes the rest (step 7 of cluster test 2's runbook);
# a second change is re-cut from the new main with make_prs.sh (a new gate run).
# rhobound-change.json is copied as given: v1 {schema, services: [1 name], summary} or v2 (rbd.change-request/v2: services
# 1..5 names, summary, base?); only its shape is checked here (pr-check.sh validates it against the kit). A change whose patch
# has no code part (a base-image change: only rhobound-change.json) is a commit of the request alone.
# Env: REPO [Sharvil2704/rhobound-maze-bed]  WORK [$RBD_SCRATCH/make_prs]  DRYRUN [0]  PLANT_UNCOMPILED [0: tests]
#      URL [https://github.com/REPO.git: tests point it at a local bare repo]
set -euo pipefail
say() { echo "[make_prs $(date -u +%H:%M:%S)] $*" >&2; }
die() { echo "make_prs: error: $*" >&2; exit 1; }
[[ $# -ge 1 ]] || die "usage: make_prs.sh NAME... (c1-noop c2-auth-small c3-auth-mid c4-pay-wait cN-model cN-bench cN-muse cN-plant)"
REPO=${REPO:-Sharvil2704/rhobound-maze-bed}
WORK=${WORK:-${RBD_SCRATCH:-${TMPDIR:-/tmp}/rbd}/make_prs}
DRYRUN=${DRYRUN:-0}
URL=${URL:-https://github.com/$REPO.git}
HERE=$(cd "$(dirname "$0")" && pwd)
for c in gh git python3; do command -v "$c" > /dev/null || die "$c is required"; done
gh auth status > /dev/null 2>&1 || die "gh is not logged in (gh auth login)"
# commit identity: GIT_AUTHOR_NAME/EMAIL, else the global git config, else the gh account's noreply address
NAME=${GIT_AUTHOR_NAME:-$(git config --global user.name || true)}
EMAIL=${GIT_AUTHOR_EMAIL:-$(git config --global user.email || true)}
if [[ -z $NAME || -z $EMAIL ]]; then
  read -r gid glogin < <(gh api user -q '"\(.id) \(.login)"') || die "cannot read the gh account (gh api user)"
  NAME=${NAME:-$glogin} EMAIL=${EMAIL:-$gid+$glogin@users.noreply.github.com}
fi

title() {
  case $1 in
    c1-noop) echo "c1-noop: reword a comment in lib_v11.go (control)" ;;
    c2-auth-small) echo "c2-auth-small: auth verify_token PBKDF2 iterations 2500 -> 6927" ;;
    c3-auth-mid) echo "c3-auth-mid: auth verify_token PBKDF2 iterations 2500 -> 20780" ;;
    c4-pay-wait) echo "c4-pay-wait: payments card risk_check hold 6 ms -> 15 ms" ;;
    c[0-9]-model | c[0-9][0-9]-model | c[0-9]-bench | c[0-9][0-9]-bench | c[0-9]-muse | c[0-9][0-9]-muse | c[0-9]-plant | c[0-9][0-9]-plant)
      # orch/agent_take.sh (model, bench, muse), changes/plant.py (plant)
      [[ -r $HERE/$1/title.txt ]] && printf '%s: %s\n' "$1" "$(head -n 1 "$HERE/$1/title.txt")" ;;
    *) return 1 ;;
  esac
}
labelof() { # the label of change NAME's PR (none for the prepared and model changes)
  case $1 in
    *-bench) echo rbd-bench ;;
    *-muse) echo rbd-muse ;;
    *-plant) echo rbd-plant ;;
  esac
}
BENCH=0 MUSE=0 PLANT=0
for n in "$@"; do
  if ! title "$n" > /dev/null || [[ ! -r $HERE/$n/change.patch || ! -r $HERE/$n/rhobound-change.json ]]; then
    die "unknown change '$n'"
  fi
  python3 -I -c '
import json, re, sys
d = json.load(open(sys.argv[1]))
s = d.get("services")
ok = isinstance(s, list) and all(isinstance(x, str) and re.fullmatch(r"[a-z][a-z0-9-]{0,31}", x) for x in s) and len(set(s)) == len(s)
ok = ok and isinstance(d.get("summary"), str) and d["summary"].strip() != ""
if d.get("schema") == "rbd.change-request/v1":
    ok = ok and len(s) == 1 and set(d) == {"schema", "services", "summary"}
elif d.get("schema") == "rbd.change-request/v2":
    ok = ok and 1 <= len(s) <= 5 and set(d) <= {"schema", "services", "summary", "base"}
    ok = ok and ("base" not in d or (isinstance(d["base"], str) and re.fullmatch(r"[a-z0-9][a-z0-9_.-]{0,31}", d["base"]) is not None))
else:
    ok = False
sys.exit(0 if ok else 1)
' "$HERE/$n/rhobound-change.json" 2> /dev/null ||
    die "$n: rhobound-change.json is not a v1 (one service) or v2 (1..5 services, base?) change request"
  [[ $n != *-bench ]] || BENCH=1
  [[ $n != *-muse ]] || MUSE=1
  if [[ $n == *-plant ]]; then
    python3 -I -c '
import json, sys
m = json.load(open(sys.argv[1]))
sys.exit(0 if m.get("schema") == "rbd.plant-change/v1" and m.get("never_merge") is True and m.get("name") == sys.argv[2] else 1)
' "$HERE/$n/manifest.json" "$n" 2> /dev/null ||
      die "$n: manifest.json is not changes/plant.py's (rbd.plant-change/v1, never_merge true, name $n)"
    # the patch is the one plant.py wrote (and compiled): an edit after it would reach the PR uncompiled and unrecorded
    python3 -I -c '
import hashlib, json, sys
want = json.load(open(sys.argv[1])).get("patch_sha256")
sys.exit(0 if isinstance(want, str) and hashlib.sha256(open(sys.argv[2], "rb").read()).hexdigest() == want else 1)
' "$HERE/$n/manifest.json" "$HERE/$n/change.patch" 2> /dev/null ||
      die "$n: change.patch changed since changes/plant.py wrote it (not the manifest's patch_sha256): re-run changes/plant.py"
    if [[ ${PLANT_UNCOMPILED:-0} != 1 ]]; then
      python3 -I -c 'import json,sys; sys.exit(0 if json.load(open(sys.argv[1])).get("compiled") is True else 1)' \
        "$HERE/$n/manifest.json" || die "$n: never compiled here (plant.py --no-compile is for tests): re-run changes/plant.py without it"
    fi
    PLANT=1
  fi
done

info=$(gh repo view "$REPO" --json visibility,mergeCommitAllowed,squashMergeAllowed,rebaseMergeAllowed) ||
  die "cannot read $REPO with gh"
python3 -I -c '
import json, sys
d = json.loads(sys.argv[1])
if d.get("visibility") != "PRIVATE":
    sys.exit("make_prs: error: %s is %s, not PRIVATE: refusing" % (sys.argv[2], d.get("visibility")))
if not d.get("mergeCommitAllowed") or d.get("squashMergeAllowed") or d.get("rebaseMergeAllowed"):
    sys.exit("make_prs: error: %s must allow merge commits only (deploy.yml reads the merge commit): "
             "gh repo edit %s --enable-merge-commit --enable-squash-merge=false --enable-rebase-merge=false" % (sys.argv[2], sys.argv[2]))
' "$info" "$REPO"

# the labels: rbd-bench (orch/automerge.sh watches it), rbd-muse (never merged: automerge.sh merges only rbd-bench) and
# rbd-plant (orch/automerge.sh refuses it), created when missing
# (never under DRYRUN)
ensure_label() { # NAME COLOR DESCRIPTION
  local labels
  labels=$(gh label list --repo "$REPO" --limit 500 --json name) || die "cannot list the labels of $REPO"
  if ! python3 -I -c 'import json,sys; sys.exit(0 if any(l.get("name") == sys.argv[2] for l in json.loads(sys.argv[1])) else 1)' \
    "$labels" "$1"; then
    gh label create "$1" --repo "$REPO" --color "$2" --description "$3" > /dev/null || die "cannot create the label $1"
    say "label $1 created on $REPO"
  fi
}
if [[ $BENCH == 1 && $DRYRUN != 1 ]]; then
  ensure_label rbd-bench 5319e7 "rbd bench: orch/automerge.sh merges it on a rhobound/verdict success"
fi
if [[ $MUSE == 1 && $DRYRUN != 1 ]]; then
  ensure_label rbd-muse 0e8a16 "rbd muse experiment (orch/muse_arm.sh): NEVER merged; orch/automerge.sh merges only rbd-bench"
fi
if [[ $PLANT == 1 && $DRYRUN != 1 ]]; then
  ensure_label rbd-plant b60205 "rbd planted change (SPEC3 F9): NEVER merged; orch/automerge.sh refuses it"
fi

CL=$WORK/clone
rm -rf "$CL"; mkdir -p "$WORK"
gitc() { git -c credential.helper= -c 'credential.helper=!gh auth git-credential' "$@"; }
gitc clone -q "$URL" "$CL" || die "clone of $REPO failed"
cd "$CL"
git rev-parse -q --verify origin/main > /dev/null || die "$REPO has no main branch"
# same_change NAME BRANCH: 0 when origin/BRANCH (an open PR's head) holds exactly what changes/NAME makes on that PR's base
# (its merge base with origin/main): change.patch's maze/app part applied + rhobound-change.json, compared as git trees. Built
# in a scratch index (git apply --cached): the work tree and the real index are never touched. 1 otherwise (no such branch,
# the patch does not apply there, or another tree: plant.py --force rewrote the folder after the PR was opened).
same_change() {
  local idx=$PWD/.git/make_prs-check.index mb blob mode=100644 tree
  git rev-parse -q --verify "refs/remotes/origin/$2" > /dev/null || return 1
  mb=$(git merge-base origin/main "origin/$2") || return 1
  rm -f "$idx"
  GIT_INDEX_FILE=$idx git read-tree "$mb" || return 1
  if [[ -n $(git apply --numstat --exclude=rhobound-change.json "$HERE/$1/change.patch" 2> /dev/null) ]]; then
    GIT_INDEX_FILE=$idx git apply --cached --exclude=rhobound-change.json "$HERE/$1/change.patch" 2> /dev/null || return 1
  fi
  [[ ! -x $HERE/$1/rhobound-change.json ]] || mode=100755
  blob=$(git hash-object -w "$HERE/$1/rhobound-change.json") || return 1
  GIT_INDEX_FILE=$idx git update-index --add --cacheinfo "$mode,$blob,rhobound-change.json" || return 1
  tree=$(GIT_INDEX_FILE=$idx git write-tree) || return 1
  rm -f "$idx"
  [[ $tree == "$(git rev-parse "refs/remotes/origin/$2^{tree}")" ]]
}
for n in "$@"; do
  br=rbd/$n
  open=$(gh pr list --repo "$REPO" --head "$br" --state open --json url -q '.[0].url // empty')
  if [[ -n $open && $n == *-plant ]]; then   # the gate measures the open PR: it must be the change this folder describes
    same_change "$n" "$br" ||
      die "$n: already open with ANOTHER change ($open): $br is not changes/$n's change.patch and request on its base" \
        "(plant.py --force rewrote the folder after the PR was opened?); its gate would be recorded against the new manifest:" \
        "close it, delete $br and use a new name"
    say "$n: already open with this same change: $open"
    continue
  fi
  if [[ -n $open ]]; then say "$n: already open: $open"; continue; fi
  if gitc ls-remote --exit-code --heads origin "$br" > /dev/null 2>&1; then
    die "$n: branch $br exists on $REPO without an open PR; delete it (gh api -X DELETE repos/$REPO/git/refs/heads/$br) or rename"
  fi
  git checkout -q -B "$br" origin/main
  if [[ -n $(git apply --numstat --exclude=rhobound-change.json "$HERE/$n/change.patch" 2> /dev/null) ]]; then   # else: request only
    git apply --index --exclude=rhobound-change.json "$HERE/$n/change.patch" || die "$n: change.patch does not apply on the current main"
  fi
  cp "$HERE/$n/rhobound-change.json" rhobound-change.json
  git add rhobound-change.json
  outside=$(git diff --cached --name-only origin/main | grep -Ev '^(maze/app/.+|rhobound-change\.json)$' || true)
  [[ -z $outside ]] || die "$n: the change touches paths outside maze/app/ and rhobound-change.json: $(tr '\n' ' ' <<< "$outside")"
  summary=$(python3 -I -c 'import json,sys; print(json.load(open(sys.argv[1]))["summary"])' rhobound-change.json)
  t=$(title "$n")
  git -c user.name="$NAME" -c user.email="$EMAIL" commit -q -m "$t" -m "$summary"
  git --no-pager show --stat --format='%h %s' HEAD >&2
  lab=()
  label=$(labelof "$n")
  [[ -z $label ]] || lab=(--label "$label")
  [[ $n != *-plant ]] || lab+=(--draft)
  if [[ $DRYRUN == 1 ]]; then
    if ((${#lab[@]})); then say "$n: DRYRUN, not pushed; the PR would be opened with: ${lab[*]}"; else say "$n: DRYRUN, not pushed"; fi
    continue
  fi
  gitc push -q origin "refs/heads/$br:refs/heads/$br" || die "$n: push of $br failed"
  body=$(printf '%s\n\n%s\n' "$summary" \
    "$(if [[ $n == *-bench ]]; then echo "Bench change \`changes/$n\` (SPEC2: the rbd-bench funnel's selected approach, tools1/bench/run_task.py). orch/automerge.sh merges it only on a rhobound/verdict success for this head.";
       elif [[ $n == *-muse ]]; then echo "Muse Code experiment change \`changes/$n\` (orch/muse_arm.sh, one iteration of one arm; written by $(python3 -I -c 'import json,sys; m=json.load(open(sys.argv[1])); print(", ".join(m.get("served_by") or [m.get("model") or "the agent"]))' "$HERE/$n/manifest.json" 2> /dev/null || echo "the agent"), checked by orch/agent_take.sh). NEVER merge it: labelled rbd-muse, which orch/automerge.sh does not merge (it merges only rbd-bench). Arm R deploys a gate pass and arm C its built image, both through the truth bracket out of band; production returns to baseline after every measurement.";
       elif [[ $n == *-plant ]]; then echo "Planted change \`changes/$n\` (SPEC3 F9, changes/plant.py: $(python3 -I -c 'import json,sys; m=json.load(open(sys.argv[1])); print("%s at %s %s, %s" % (m["mechanism"], m["service"], m["function"], m["placement"]))' "$HERE/$n/manifest.json")). NEVER merge it: a draft labelled rbd-plant, which orch/automerge.sh refuses whatever its verdict. Its registered dose is the A/B-measured own-time delta, not the knob.";
       elif [[ $n == *-model ]]; then echo "Model-written change (tools1/agent/agent.py: $(python3 -I -c 'import json,sys; m=json.load(open(sys.argv[1])); print(", ".join(m.get("served_by") or [m["model"]]), "with the rhobound MCP tools:", ", ".join(c["tool"] for c in m.get("mcp_calls") or []) or "none")' "$HERE/$n/manifest.json"))."; else echo "Prepared change \`changes/$n\` of the rhobound demo."; fi) The gate job decides (commit status \`rhobound/verdict\`); deploy.sh deploys only an image whose signed verdict is pass.")
  url=$(gh pr create --repo "$REPO" --base main --head "$br" --title "$t" --body "$body" "${lab[@]}") || die "$n: gh pr create failed"
  say "$n: $url"
done
