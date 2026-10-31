#!/usr/bin/env bash
# t_automerge.sh: orch/automerge.sh (SPEC2 S8/S9) against the stateful fake GitHub (fakegh.py): a pass is merged with
# --match-head-commit at the exact head and its deploy.yml run waited for and recorded (timeline.json, the shared schema); a
# non-pass verdict is recorded and the PR left open; every typed precondition (label, branch, base, fork, author, files,
# mergeable, main's tip, the status's creator and description) refuses a merge; pending waits and times out; the kill switch;
# DRYRUN writes nothing; one merge in flight; once mode merges at most one; a failed deploy and a refused merge are errors.
# SPEC3 F9: a planted change (label rbd-plant or branch rbd/cN-plant) is never merged in pr, once and merge_one (a PR relabelled
# between two reads: fakegh labels2), before the variance guard; labels or a branch of another shape are refused as if planted.
set -uo pipefail
# shellcheck source=tools1/tests/bench/s8lib.sh
. "$(dirname "$0")/s8lib.sh"
AM=$KIT/orch/automerge.sh
echo "== automerge.sh (fake GitHub)"
am() { bash "$AM" "$@" > "$T/am.out" 2> "$T/am.err"; echo $?; }
TL() { jq1 "$RBD_STATE/bench/$1/timeline.json" "$2"; }
KEYS='["deploy_ended", "deploy_ok", "deploy_run", "gate_ended", "gate_run", "gate_started", "head", "merge_sha", "merged_at", "pr", "rule", "task", "verdict"]'
keys() { python3 -I -c 'import json,sys; print(json.dumps(sorted(json.load(open(sys.argv[1])))))' "$RBD_STATE/bench/$1/timeline.json"; }

mkenv8 am-pass
world 7
H=$(headof 7)
rc=$(am pr 7 --task T1-rank)
check "pass: exit 0 (rc $rc)" test "$rc" -eq 0
check "...merged with --merge --match-head-commit at the exact head" grep -qx "gh pr merge 7 --repo Sharvil2704/rhobound-demo --merge --match-head-commit $H" "$STUB_DIR/calls.log"
check "...exactly one merge call" test "$(merges)" -eq 1
check "...the PR is MERGED in the fake GitHub" test "$(prstate 7)" = MERGED
check "...timeline.json has exactly the shared keys" test "$(keys T1-rank)" = "$KEYS"
check "...timeline: task, pr, head, verdict pass, rule" test "$(TL T1-rank task) $(TL T1-rank pr) $(TL T1-rank head) $(TL T1-rank verdict) $(TL T1-rank rule)" = "T1-rank 7 $H pass mean_change@storefront"
check "...timeline: the gate run of that head (507, started 21:01, ended 21:20)" test "$(TL T1-rank gate_run) $(TL T1-rank gate_started) $(TL T1-rank gate_ended)" = "507 2026-10-30T21:01:00Z 2026-10-30T21:20:00Z"
M=$(python3 -I -c 'import json,sys; print(json.load(open(sys.argv[1]))["main"])' "$STUB_WORLD")
check "...timeline: merge_sha = the merge commit, merged_at set" bash -c "[ '$(TL T1-rank merge_sha)' = '$M' ] && [ -n '$(TL T1-rank merged_at)' ]"
check "...the deploy.yml run of THAT merge commit was waited for and recorded (deploy_ok true)" bash -c "grep -q 'gh run list --repo Sharvil2704/rhobound-demo --workflow deploy.yml --commit $M' '$STUB_DIR/calls.log' &&
  [ '$(TL T1-rank deploy_ok)' = true ] && [ -n '$(TL T1-rank deploy_run)' ] && [ -n '$(TL T1-rank deploy_ended)' ]"
check "...no merge in flight afterwards (state/automerge.inflight removed)" test ! -e "$RBD_STATE/automerge.inflight"
check "...the decisions are logged (automerge.jsonl: merged, deployed)" bash -c "grep -q '\"action\": \"merged\"' '$RBD_STATE/bench/T1-rank/automerge.jsonl' && grep -q '\"action\": \"deployed\"' '$RBD_STATE/bench/T1-rank/automerge.jsonl'"
check "...gh only: nothing forbidden ran (ssh, aws, docker, kubectl)" test ! -s "$STUB_DIR/forbidden.log"
check "...no PR body, title or comment was read (no body/title/comments field asked)" bash -c "! grep -E -- '--json [^ ]*(body|title|comments)' '$STUB_DIR/calls.log'"

mkenv8 am-pending
world 8:pending=3
rc=$(am pr 8 --task T2-round)
check "pending three reads, then pass: waited, merged (rc $rc)" bash -c "[ $rc -eq 0 ] && [ $(merges) -eq 1 ] && [ $(grep -c 'statuses' "$STUB_DIR/calls.log") -ge 4 ]"

mkenv8 am-block
world 9:verdict=block
rc=$(am pr 9 --task T3-fold)
check "block: exit 3, no merge, the PR left OPEN (rc $rc)" bash -c "[ $rc -eq 3 ] && [ $(merges) -eq 0 ] && [ $(prstate 9) = OPEN ]"
check "...timeline: verdict block, its rule, nothing merged" test "$(TL T3-fold verdict) $(TL T3-fold rule) $(TL T3-fold merged_at)" = "block mean_change@storefront "
check "...recorded in automerge.jsonl as not-merged" grep -q '"action": "not-merged"' "$RBD_STATE/bench/T3-fold/automerge.jsonl"
check "...the PR is never closed or commented" bash -c "! grep -qE '^gh pr (close|comment|edit)' '$STUB_DIR/calls.log'"
for v in inconclusive error; do
  mkenv8 "am-$v"
  world "10:verdict=$v"
  rc=$(am pr 10 --task T4-base)
  check "$v: exit 3, no merge, verdict recorded (rc $rc)" bash -c "[ $rc -eq 3 ] && [ $(merges) -eq 0 ] && [ '$(TL T4-base verdict)' = $v ]"
done

mkenv8 am-timeout
world 11:verdict=none
rc=$(am pr 11 --task T1-rank --wait 0)
check "no verdict yet and --wait 0: exit 4, no merge (rc $rc)" bash -c "[ $rc -eq 4 ] && [ $(merges) -eq 0 ] && grep -q '\"action\": \"timeout\"' '$RBD_STATE/bench/T1-rank/automerge.jsonl'"

mkenv8 am-stop
world 12
echo stop > "$RBD_STATE/automerge.stop"
rc=$(am pr 12 --task T1-rank)
check "kill switch state/automerge.stop: exit 5, no merge (rc $rc)" bash -c "[ $rc -eq 5 ] && [ $(merges) -eq 0 ]"
rc=$(am once)
check "...once: exit 5, no merge (rc $rc)" bash -c "[ $rc -eq 5 ] && [ $(merges) -eq 0 ]"

mkenv8 am-dry
world 13
rc=$(DRYRUN=1 am pr 13 --task T1-rank)
check "DRYRUN=1: exit 0, would merge, no merge call (rc $rc)" bash -c "[ $rc -eq 0 ] && [ $(merges) -eq 0 ] && grep -q 'DRYRUN: would merge PR 13' '$T/am.err'"
check "...the decision JSON on stdout says ready" test "$(jq1 "$T/am.out" ready)" = true
check "...no file written (no timeline, no jsonl, no inflight)" bash -c "[ -z \"\$(find '$RBD_STATE' -type f)\" ]"

# every typed precondition refuses a merge of a pass
pre() { # NAME SPEC WANT-IN-REASON
  mkenv8 "am-pre-$1"
  world "$2"
  local rc
  rc=$(am pr 20 --task T1-rank)
  check "refused ($1): exit 3, no merge, reason '$3' recorded (rc $rc)" bash -c "[ $rc -eq 3 ] && [ $(merges) -eq 0 ] && grep -qF '$3' '$RBD_STATE/bench/T1-rank/automerge.jsonl'"
}
pre stale "20:behind=1" "main moved since the PR was cut"
pre conflict "20:mergeable=CONFLICTING" "mergeable CONFLICTING"
pre files "20:files=kshop/app/internal/hot/rank.go|.github/workflows/gate.yml" "files outside kshop/app/"
pre author "20:author=someone-else" "is not this gh account"
pre label "20:label=0" "no label rbd-bench"
pre branch "20:branch=feature/x" "is not rbd/*"
pre base "20:base=release" "is not main"
pre fork "20:cross=1" "not a branch of this repository"
pre draft "20:draft=1" "a draft"
pre creator "20:creator=someone" "was created by"
pre desc "20:desc=block: mean_change@checkout" "its description is not"

mkenv8 am-unknown
world 21:mergeable=UNKNOWN
rc=$(am pr 21 --task T1-rank --wait 0)
check "mergeability UNKNOWN is waited for, never merged (rc $rc)" bash -c "[ $rc -eq 4 ] && [ $(merges) -eq 0 ]"

mkenv8 am-deployfail
world 22
world_set deploy_final '"failure"'
rc=$(am pr 22 --task T1-rank)
check "the deploy.yml run fails (deploy.sh refused): exit 1, deploy_ok false recorded (rc $rc)" bash -c "[ $rc -eq 1 ] && [ '$(TL T1-rank deploy_ok)' = false ] && [ ! -e '$RBD_STATE/automerge.inflight' ]"

mkenv8 am-mergefail
world 23
world_set merge_fails true
rc=$(am pr 23 --task T1-rank)
check "GitHub refuses the merge: exit 1, nothing merged recorded (rc $rc)" bash -c "[ $rc -eq 1 ] && [ -z '$(TL T1-rank merged_at)' ] && [ ! -e '$RBD_STATE/automerge.inflight' ]"

# one in flight: A merged, its deploy run never ends within the wait; B's pass is not merged meanwhile
mkenv8 am-inflight
world 30 31
world_set deploy_polls 1000
rc=$(AUTOMERGE_DEPLOY_WAIT=0 am pr 30 --task TA)
check "A merged, its deploy not finished in time: exit 4, A stays in flight (rc $rc)" bash -c "[ $rc -eq 4 ] && [ $(merges) -eq 1 ] && [ '$(jq1 "$RBD_STATE/automerge.inflight" pr)' = 30 ]"
# B: re-cut from the new main meanwhile (behind 0), a pass
python3 -I -c 'import json,sys; w=json.load(open(sys.argv[1])); w["prs"]["31"]["behind_by"]=0; json.dump(w,open(sys.argv[1],"w"))' "$STUB_WORLD"
rc=$(AUTOMERGE_DEPLOY_WAIT=0 am pr 31 --task TB)
check "...B (a pass on the new main) is NOT merged while A's deploy runs (exit 4, still one merge call; rc $rc)" bash -c "[ $rc -eq 4 ] && [ $(merges) -eq 1 ] && [ $(prstate 31) = OPEN ]"
python3 -I -c 'import json,sys; w=json.load(open(sys.argv[1])); [r.update(polls_left=0) for r in w["runs"]]; w["deploy_polls"]=0; json.dump(w,open(sys.argv[1],"w"))' "$STUB_WORLD"
rc=$(am pr 31 --task TB)
check "...once A's deploy completed: A's deploy recorded first, then B merged and deployed (rc $rc)" bash -c "[ $rc -eq 0 ] &&
  [ '$(TL TA deploy_ok)' = true ] && [ $(merges) -eq 2 ] && [ '$(TL TB deploy_ok)' = true ] && [ ! -e '$RBD_STATE/automerge.inflight' ]"
rc=$(bash "$AM" pr 30 --task TA > /dev/null 2>&1; echo $?)
check "...a merged PR is never merged again (A: state MERGED, exit 3; rc $rc)" bash -c "[ $rc -eq 3 ] && [ $(merges) -eq 2 ]"

# once: only PRs a state/bench/<task>/pr.json names; at most one merge per round
mkenv8 am-once
world 40 41 42:verdict=block 43
for p in 40:T1-rank 41:T3-fold 42:T2-round; do
  mkdir -p "$RBD_STATE/bench/${p#*:}"
  printf '{"task": "%s", "pr": %s, "change": "c%s-bench"}\n' "${p#*:}" "${p%%:*}" "${p%%:*}" > "$RBD_STATE/bench/${p#*:}/pr.json"
done
rc=$(am once)
check "once: exit 0, exactly one merge (the lowest ready PR, 40; rc $rc)" bash -c "[ $rc -eq 0 ] && [ $(merges) -eq 1 ] && grep -q '^gh pr merge 40 ' '$STUB_DIR/calls.log'"
check "...the block of 42 recorded in its timeline, left open" bash -c "[ '$(TL T2-round verdict)' = block ] && [ $(prstate 42) = OPEN ]"
check "...PR 43 (labelled, but no pr.json names it) left alone" bash -c "grep -q 'PR 43: labelled rbd-bench but no state/bench' '$T/am.err' && [ $(prstate 43) = OPEN ]"
check "...pr mode refuses a PR number other than the task's pr.json" bash -c "[ \$(bash '$AM' pr 41 --task T1-rank > /dev/null 2>&1; echo \$?) -eq 1 ]"

# a new head on the PR starts a fresh timeline
mkenv8 am-newhead
world 50:verdict=block
am pr 50 --task T1-rank > /dev/null
world 50:rev=2
am pr 50 --task T1-rank > /dev/null
check "a new head resets the timeline (verdict pass, merged at the new head)" bash -c "[ '$(TL T1-rank head)' = '$(headof 50)' ] && [ '$(TL T1-rank verdict)' = pass ] && [ -n '$(TL T1-rank merge_sha)' ]"

# the variance guard (the owner's relaxation is for improvements only): a stub guard command per case
mkenv8 am-guard-hold
world 23
printf '#!/bin/sh\necho "{\\"allow\\": false, \\"reason\\": \\"variance changed and not an improvement at every service\\"}"\nexit 1\n' > "$T/guard-hold.sh"
rc=$(AUTOMERGE_GUARD="$T/guard-hold.sh" am pr 23 --task T1-rank)
check "a pass the variance guard holds: exit 3, no merge, PR left open (rc $rc)" bash -c "[ $rc -eq 3 ] && [ $(merges) -eq 0 ] && [ $(prstate 23) = OPEN ] && grep -q 'variance guard holds it' '$T/am.err'"
check "...the guard's answer is logged (automerge.jsonl variance-guard rc 1)" grep -q '"action": "variance-guard"' "$RBD_STATE/bench/T1-rank/automerge.jsonl"
mkenv8 am-guard-allow
world 24
printf '#!/bin/sh\necho "{\\"allow\\": true, \\"reason\\": \\"variance changed, an improvement at every service\\"}"\nexit 0\n' > "$T/guard-allow.sh"
rc=$(AUTOMERGE_GUARD="$T/guard-allow.sh" am pr 24 --task T1-rank)
check "a pass the variance guard allows (an improvement everywhere): merged (rc $rc)" bash -c "[ $rc -eq 0 ] && [ $(merges) -eq 1 ] && grep -q 'an improvement at every service' '$T/am.err'"

# SPEC3 F9: a planted change (label rbd-plant, or head branch rbd/cN-plant: changes/plant.py + make_prs.sh) is NEVER merged,
# whatever its verdict: refused explicitly, recorded, the PR left open
plant() { # NAME SPEC WHY
  mkenv8 "am-plant-$1"
  world "$2"
  local rc
  rc=$(am pr 60 --task T1-rank)
  check "planted ($1), a signed pass: exit 3, no merge call, left OPEN (rc $rc)" bash -c "[ $rc -eq 3 ] && [ $(merges) -eq 0 ] && [ $(prstate 60) = OPEN ]"
  check "...refused explicitly as a planted change ($3), recorded as plant-refused" bash -c "grep -qF 'is a planted change ($3): automerge.sh never merges it' '$T/am.err' &&
    grep -q '\"action\": \"plant-refused\"' '$RBD_STATE/bench/T1-rank/automerge.jsonl'"
}
plant both-labels "60:labels=rbd-bench|rbd-plant" "label rbd-plant"
plant plant-label "60:labels=rbd-plant" "label rbd-plant"
plant branch "60:branch=rbd/c60-plant" "head branch rbd/c60-plant"
plant label-and-branch "60:labels=rbd-bench|rbd-plant,branch=rbd/c7-plant" "label rbd-plant and head branch rbd/c7-plant"
check "...assess lists both reasons too (never 'ready')" bash -c "grep -q 'label rbd-plant: a planted change (changes/plant.py) is never merged automatically' '$RBD_STATE/bench/T1-rank/automerge.jsonl' &&
  grep -q 'head branch rbd/c7-plant is a planted change' '$RBD_STATE/bench/T1-rank/automerge.jsonl'"
mkenv8 am-plant-pending
world "61:labels=rbd-bench|rbd-plant,pending=50"
rc=$(am pr 61 --task T1-rank --wait 7200)
check "a planted change whose gate still runs: exit 3 at once (not a wait for its verdict), no merge (rc $rc)" bash -c "[ $rc -eq 3 ] && [ $(merges) -eq 0 ] &&
  [ $(grep -c 'statuses' "$STUB_DIR/calls.log") -eq 1 ]"
mkenv8 am-plant-dry
world "62:labels=rbd-bench|rbd-plant"
rc=$(DRYRUN=1 am pr 62 --task T1-rank)
check "DRYRUN: a planted pass is exit 3, its decision JSON not ready, the plant reason listed, nothing written (rc $rc)" bash -c "[ $rc -eq 3 ] &&
  [ '$(jq1 "$T/am.out" ready)' = false ] && grep -q 'never merged automatically' '$T/am.out' && [ -z \"\$(find '$RBD_STATE' -type f)\" ]"
mkenv8 am-plant-once
world "63:labels=rbd-bench|rbd-plant" 64 "65:branch=rbd/c65-plant"
for p in 63:T-plant 64:T1-rank 65:T-plant2; do
  mkdir -p "$RBD_STATE/bench/${p#*:}"
  printf '{"task": "%s", "pr": %s, "change": "c%s-x"}\n' "${p#*:}" "${p%%:*}" "${p%%:*}" > "$RBD_STATE/bench/${p#*:}/pr.json"
done
rc=$(am once)
check "once: the lowest ready PR is a plant (63): skipped; 64 merged; the plant 65 never (rc $rc)" bash -c "[ $rc -eq 0 ] && [ $(merges) -eq 1 ] &&
  grep -q '^gh pr merge 64 ' '$STUB_DIR/calls.log' && [ $(prstate 63) = OPEN ] && [ $(prstate 65) = OPEN ]"
check "...both plants refused explicitly and recorded" bash -c "grep -q 'PR 63 (T-plant) is a planted change (label rbd-plant)' '$T/am.err' &&
  grep -q '\"action\": \"plant-refused\"' '$RBD_STATE/bench/T-plant/automerge.jsonl'"
rc=$(am once)
check "...a second round (64 merged, the plants still open and now stale): no merge (rc $rc)" bash -c "[ $rc -eq 0 ] && [ $(merges) -eq 1 ]"
mkenv8 am-plant-only
world "66:labels=rbd-bench|rbd-plant"
mkdir -p "$RBD_STATE/bench/T-plant"; printf '{"task": "T-plant", "pr": 66}\n' > "$RBD_STATE/bench/T-plant/pr.json"
rc=$(am once)
check "once with only a planted pass: nothing merged (rc $rc)" bash -c "[ $rc -eq 0 ] && [ $(merges) -eq 0 ] && [ $(prstate 66) = OPEN ]"

# merge_one's own refusal (the second line of defence, on the facts re-read under the lock): the PR is a ready pass at its first
# read and labelled rbd-plant by merge_one's re-read (fakegh labels2); an allowing variance guard proves the refusal comes first
allow_guard() { printf '#!/bin/sh\necho called >> %s\necho "{\\"allow\\": true, \\"reason\\": \\"allowed\\"}"\nexit 0\n' "$T/guard.calls" > "$T/guard-allow.sh"; }
mkenv8 am-plant-relabel-once
world "67:labels2=rbd-bench|rbd-plant"
mkdir -p "$RBD_STATE/bench/T-relabel"; printf '{"task": "T-relabel", "pr": 67}\n' > "$RBD_STATE/bench/T-relabel/pr.json"
allow_guard
rc=$(AUTOMERGE_GUARD="$T/guard-allow.sh" am once)
check "once: PR 67 ready at its first read, relabelled rbd-plant by merge_one's re-read: not merged, left OPEN (rc $rc)" bash -c "[ $rc -eq 0 ] && [ $(merges) -eq 0 ] &&
  [ $(prstate 67) = OPEN ] && grep -q 'PR 67 (T-relabel): verdict pass .*; ready true' '$T/am.err'"
check "...refused inside merge_one (its own message, plant-refused recorded), before the variance guard (never called)" bash -c "
  grep -qF 'PR 67 is a planted change (label rbd-plant): automerge.sh never merges it, whatever its verdict (pass)' '$T/am.err' &&
  grep -q '\"action\": \"plant-refused\"' '$RBD_STATE/bench/T-relabel/automerge.jsonl' && [ ! -e '$T/guard.calls' ] &&
  ! grep -qE '\"action\": \"(variance-guard|not-merged)\"' '$RBD_STATE/bench/T-relabel/automerge.jsonl'"
mkenv8 am-plant-relabel-pr
world "68:labels2=rbd-bench|rbd-plant"
allow_guard
rc=$(AUTOMERGE_GUARD="$T/guard-allow.sh" am pr 68 --task T1-rank)
check "pr: the same relabel between pr mode's read and merge_one's: exit 3 from merge_one, no merge, guard never called (rc $rc)" bash -c "[ $rc -eq 3 ] && [ $(merges) -eq 0 ] &&
  grep -qF 'PR 68 is a planted change (label rbd-plant): automerge.sh never merges it' '$T/am.err' && [ ! -e '$T/guard.calls' ] &&
  grep -q '\"action\": \"plant-refused\"' '$RBD_STATE/bench/T1-rank/automerge.jsonl'"

# fail closed: a PR whose labels or branch cannot be told is refused as if planted (a list of named label objects, possibly
# empty, and a string branch are the only shapes that can say 'not a plant')
setpr() { python3 -I -c 'import json,sys; w=json.load(open(sys.argv[1])); w["prs"][sys.argv[2]][sys.argv[3]]=json.loads(sys.argv[4]); json.dump(w,open(sys.argv[1],"w"))' "$STUB_WORLD" "$@"; }
odd() { # NAME KEY JSON WANT
  mkenv8 "am-plant-odd-$1"
  world 70
  setpr 70 "$2" "$3"
  local rc
  rc=$(am pr 70 --task T1-rank)
  check "$2 = $3, a signed pass: refused as if planted (exit 3, no merge, plant-refused; rc $rc)" bash -c "[ $rc -eq 3 ] && [ $(merges) -eq 0 ] && [ $(prstate 70) = OPEN ] &&
    grep -qF 'is a planted change (its labels or branch cannot be told ($4' '$T/am.err' && grep -qF '): refused as if planted)' '$T/am.err' &&
    grep -q '\"action\": \"plant-refused\"' '$RBD_STATE/bench/T1-rank/automerge.jsonl'"
}
odd labels-null labels null "labels null"
odd labels-object labels '{}' 'labels {}'
odd label-noname labels '[{"name": "rbd-bench"}, {"name": null}]' 'a label without a name'
check "...(that one is otherwise a ready pass: assess sees rbd-bench and no rbd-plant, ready true; it merged before)" grep -q '"ready": true' "$RBD_STATE/bench/T1-rank/automerge.jsonl"
odd label-nokey labels '[{"name": "rbd-bench"}, {"title": "rbd-plant"}]' 'a label without a name'
odd branch-null headRefName null "headRefName null"
mkenv8 am-plant-odd-empty
world 71:label=0
rc=$(am pr 71 --task T1-rank)
check "labels [] (a list, no plant label): certainly not a plant: not-merged for 'no label rbd-bench', never plant-refused (rc $rc)" bash -c "[ $rc -eq 3 ] && [ $(merges) -eq 0 ] &&
  grep -q '\"action\": \"not-merged\"' '$RBD_STATE/bench/T1-rank/automerge.jsonl' && ! grep -q 'plant-refused' '$RBD_STATE/bench/T1-rank/automerge.jsonl'"

mkenv8 am-usage
rc=$(am pr x --task T1)
check "usage errors exit 2 before any gh call (rc $rc)" bash -c "[ $rc -eq 2 ] && [ ! -s '$STUB_DIR/calls.log' ]"
rc=$(am pr 1 --task 'bad/task')
check "usage errors exit 2 (rc $rc)" test "$rc" -eq 2
done_summary
