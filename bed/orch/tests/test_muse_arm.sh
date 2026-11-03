#!/usr/bin/env bash
# test_muse_arm.sh: orch/muse_arm.sh, orch/muse_score.py and make_prs.sh's cN-muse kind, offline. Stand-ins for everything
# live: rbd.sh (an emulator of run/bg/tail/put/get over a fake /var/lib/rbd under T), the root runner (MUSE_ROOT_SH),
# /opt/muse/task.sh and hidden.sh, orch/agent_take.sh, changes/make_prs.sh (which also plays the CI: candidate.json, gate
# artifacts, commit status), verify/candidate.sh, verify/truthx.sh, verify/regress.py, and gh (PRs, statuses, runs, close).
# ssh, aws, docker stay lib.sh's fail-loudly stubs. Scenarios, each read from scen/RUN-ii.json by the stand-ins:
#   T9-R  block (fed back: verdict, rule, decide_with) -> pass -> clean: accepted at 2; iteration 1's PR closed
#   T9-C  no compile -> hidden fail (fed back, redacted) -> deployed, regressed: not accepted; the counterfactual comes late
#         and --collect records it
#   T8-C  deployed, regressed, rolled back (fed back: entry changes) -> clean: accepted at 2; counterfactual block then pass;
#         the superseded PR closed once its counterfactual is in
#   T6-C  no change (task.sh exit 1, its errors fed back) -> the CI build failed (fed back with its log) -> accepted at 3
#   refusals (usage, --max-iter > 3, --tag), kill switch (state/muse/STOP only), the preflight (a remote step missing,
#   tools1's src/main.sha not the kit's), one arm at a time, a re-run needs --tag (and runs under new names), harness
#   errors (task.sh exit 3, hidden.sh exit 3, a gate error after the build, agent_take cannot fetch, rollback failed)
#   real verify/regress.py on the stand-in windows (T9-R, T8-C); the rule here when it is absent (T9-C)
#   muse_score.py: exact numbers on a hand-made timeline pair; then over the scenarios' state
#   make_prs.sh c23-muse on a local bare repo with tools1/tests/ci/fakebin/gh: label rbd-muse, title from title.txt
# shellcheck disable=SC1090,SC1091,SC2012,SC2015,SC2016,SC2088,SC2155  # test code
set -uo pipefail
# shellcheck source=lib.sh
. "$(dirname "$(readlink -f "$0")")/lib.sh"
ARMSH=$DEMO/orch/muse_arm.sh SCORE=$DEMO/orch/muse_score.py
SB=$T/sb TV=$T/tools1/var SCEN=$T/scen GHD=$T/gh
mkdir -p "$SB" "$TV/logs" "$SCEN" "$GHD" "$T/seen" "$T/state/agent" "$T/changes/c22-plant"
export SB_TV=$TV SB_SCEN=$SCEN SB_GH=$GHD SB_SEEN=$T/seen SB_LOG=$T/sb.log SB_CHANGES=$T/changes SB_AGSTATE=$T/state/agent
: > "$SB_LOG"

# ---- stand-ins ----------------------------------------------------------------------------------------------------------
cat > "$SB/map.sh" << 'EOF'
map() { local a=$1; if [[ $a == /var/lib/rbd || $a == /var/lib/rbd/* ]]; then echo "$SB_TV${a#/var/lib/rbd}"; else echo "$a"; fi; }
EOF
cat > "$SB/rbd.sh" << 'EOF'
#!/usr/bin/env bash
# rbd.sh stand-in: run/bg/tail/put/get over SB_TV (the fake /var/lib/rbd; /var/lib/rbd/... arguments are mapped into it)
set -uo pipefail
. "$(dirname "$0")/map.sh"
echo "rbd.sh $*" >> "$SB_LOG"
cmd=$1; shift
case $cmd in
  run) a=(); for x in "$@"; do a+=("$(map "$x")"); done; cd "$SB_TV" && "${a[@]}" ;;
  bg) n=$1; shift; a=(); for x in "$@"; do a+=("$(map "$x")"); done
      mkdir -p "$SB_TV/logs"; rm -f "$SB_TV/logs/$n.rc"
      (cd "$SB_TV" && setsid nohup bash -c '"$@" > "$0.out" 2>&1 < /dev/null; echo $? > "$0.rc"' "$SB_TV/logs/$n" "${a[@]}" > /dev/null 2>&1 < /dev/null &)
      echo "started $n" ;;
  tail) n=$1; if [ -f "$SB_TV/logs/$n.rc" ]; then echo "== $n: done, exit $(cat "$SB_TV/logs/$n.rc")"; else echo "== $n: running (or never started)"; fi
        tail -n "${2:-20}" "$SB_TV/logs/$n.out" 2> /dev/null; true ;;
  put) d=$(map "$2"); mkdir -p "$d" && cp -R "$1" "$d/" ;;
  get) s=$(map "$1"); mkdir -p "$2" && tar -C "$(dirname "$s")" -cf - "$(basename "$s")" | tar -xf - -C "$2" ;;
  *) echo "rbd.sh stand-in: $cmd?" >&2; exit 2 ;;
esac
EOF
cat > "$SB/root.sh" << 'EOF'
#!/usr/bin/env bash
# MUSE_ROOT_SH stand-in: CMD... "as root on rbd-tools1" = here, /var/lib/rbd mapped
. "$(dirname "$0")/map.sh"
echo "root $*" | head -c 300 >> "$SB_LOG"; echo >> "$SB_LOG"
a=(); for x in "$@"; do a+=("$(map "$x")"); done
"${a[@]}"
EOF
cat > "$SB/scen.sh" << 'EOF'
# sc RI KEY DEFAULT: the scenario's value for one iteration
sc() { local v; v=$(jq -r --arg k "$2" '.[$k] // empty | if type == "object" or type == "array" then tojson else . end' "$SB_SCEN/$1.json" 2> /dev/null); echo "${v:-$3}"; }
EOF
cat > "$SB/task.sh" << 'EOF'
#!/usr/bin/env bash
# /opt/muse/task.sh stand-in (tools1/muse/task.sh's contract): ARM TICKET ITER RUN [FEEDBACK] -> OUT /var/lib/rbd/agent/RUN-iITER
# (result.json, usage.json rbd.muse-usage/v1; arm C with scenario raw=yes: no usage.json, Muse's raw logs in muse/runs/RUN/iITER)
. "$(dirname "$0")/scen.sh"
ARM=$1 TICKET=$2 I=$3 RUN=$4 FB=${5:-}
RI=$RUN-i$I OUT=$SB_TV/agent/$RUN-i$I RAW=$SB_TV/muse/runs/$RUN/i$I
echo "task $ARM $TICKET $I $RUN feedback=${FB:+yes}" >> "$SB_LOG"
[ -z "$FB" ] || cp "$FB" "$SB_SEEN/$RI.feedback.md"
mkdir -p "$OUT" "$RAW"
rc=$(sc "$RI" agent_rc 0)
if [ "$ARM" = R ]; then mcp='["context", "budget", "predict"]'; counts='{"context": 1, "budget": 1, "predict": 1}'; stops=1
else mcp='[]'; counts='{}'; stops=0; fi
if [ "$rc" = 1 ]; then
  printf '{"step": "agent", "ok": false, "turns": 9, "mcp_calls": [], "usage": {"input": 900, "output": 90, "cached": null, "reasoning": null, "total": 990}, "error": "the workspace changes nothing under maze/app", "errors": ["the workspace changes nothing under maze/app", "a file outside internal/svc/catalog/ was edited: go.mod"]}\n' > "$OUT/result.json"
else
  printf '{"step": "agent", "ok": true, "turns": 17, "mcp_calls": %s, "usage": {"input": 50000, "output": 7000, "cached": 20000, "reasoning": null, "total": 57000}}\n' "$mcp" > "$OUT/result.json"
fi
if [ "$(sc "$RI" raw no)" = yes ]; then
  { echo '{"payload_type": "run.model.configured", "payload": {"tools": ["mcp__rhobound__predict", "mcp__rhobound__context"]}}'
    echo '{"payload_type": "task.lifecycle.proposed", "payload": {"tool_name": "shell", "args": "go test ./..."}}'
    echo '{"payload_type": "task.lifecycle.proposed", "payload": {"tool_name": "write_file"}}'
    echo '{"payload_type": "run.usage", "payload": {"input_tokens": 41000, "output_tokens": 6000, "total_tokens": 47000}}'
  } > "$RAW/events.jsonl"
else
  printf '{"schema": "rbd.muse-usage/v1", "arm": "%s", "ticket": "%s", "iteration": %s, "model": "muse-spark-1.3", "effort": "high", "steps_cap": 80, "session": {"started": "2026-11-02T21:00:00Z", "ended": "2026-11-02T21:12:00Z", "wall_s": 720.0, "rc": 0, "timed_out": false}, "model_steps": 23, "model_steps_completed": 22, "tokens": {"input": 50000, "output": 7000, "cached": 20000, "reasoning": null, "total": 57000}, "tool_calls_by_kind": {"shell": 3, "write_file": 2}, "mcp_offered": ["budget", "context", "predict"], "mcp_calls": [], "mcp_call_counts": %s, "hooks": {"stop_blocked": %s}, "run_usage": {"input_tokens": 50000}}\n' \
    "$ARM" "$TICKET" "$I" "$counts" "$stops" > "$OUT/usage.json"
fi
echo "muse session done for $RI"
printf '{"step": "muse-task", "ok": %s, "out": "%s", "arm": "%s", "iteration": %s}\n' "$([ "$rc" = 0 ] && echo true || echo false)" "$OUT" "$ARM" "$I"
exit "$rc"
EOF
cat > "$SB/agent_take.sh" << 'EOF'
#!/usr/bin/env bash
# orch/agent_take.sh stand-in: RI CHANGE -> changes/CHANGE (0), compile errors (3) or a refusal (1), as the scenario says
. "$(dirname "$0")/scen.sh"
RI=$1 CH=$2
echo "take $RI $CH" >> "$SB_LOG"
case $(sc "$RI" take_rc 0) in
  0) mkdir -p "$SB_CHANGES/$CH"
     printf 'diff --git a/maze/app/internal/svc/catalog/catalog.go b/maze/app/internal/svc/catalog/catalog.go\n+// %s\n' "$RI" > "$SB_CHANGES/$CH/change.patch"
     printf '{"schema": "rbd.change-request/v2", "services": ["%s"], "summary": "faster search (%s)"}\n' "$(sc "$RI" service catalog)" "$RI" > "$SB_CHANGES/$CH/rhobound-change.json"
     echo "Faster catalog.Search ($RI)" > "$SB_CHANGES/$CH/title.txt"
     printf '{"schema": "rbd.agent-change/v1", "run": "%s", "service": "%s", "model": "muse-spark-1.3"}\n' "$RI" "$(sc "$RI" service catalog)" > "$SB_CHANGES/$CH/manifest.json"
     echo "agent_take: changes/$CH written" >&2; exit 0 ;;
  3) printf 'maze/app/internal/svc/catalog/catalog.go:41:9: undefined: fuzzyIndex\n(go build -tags '"''"' failed)\n' > "$SB_AGSTATE/$RI.compile.txt"
     echo "agent_take: error: the change does not compile: state/agent/$RI.compile.txt (agent.py --feedback takes it)" >&2; exit 3 ;;
  1) echo "agent_take: refused: maze/app/internal/svc/catalog/x.go: '//go:linkname' is not allowed in a model-written change" >&2
     echo "agent_take: error: the agent's output is refused (above)" >&2; exit 1 ;;
  9) echo "agent_take: error: cannot fetch /var/lib/rbd/agent/$RI: ssh: connect" >&2; exit 1 ;;
esac
EOF
cat > "$SB/hidden.sh" << 'EOF'
#!/usr/bin/env bash
# /opt/muse/hidden.sh stand-in (tools1/muse/hidden.sh's contract): ARM TICKET RUN ITER -> muse/runs/RUN/iITER/hidden.json
# (rbd.muse-hidden/v1) and the same object as the last stdout line; exit 0 pass, 1 fail, 3 error
. "$(dirname "$0")/scen.sh"
RI=$3-i$4 D=$SB_TV/muse/runs/$3/i$4
echo "hidden $*" >> "$SB_LOG"
mkdir -p "$D"
rc=$(sc "$RI" hidden_rc 0)
case $rc in
  1) j='{"schema": "rbd.muse-hidden/v1", "pass": false, "failed": ["TestSameAnswers"], "ran": 5, "passed": 4, "expected": 5, "missing": [], "build_failed": false, "go_test_rc": 1, "error": null, "output_tail": "--- FAIL: TestSameAnswers (0.02s)\n    search_hidden_test.go:51: query \"blue shoe\": got [12 9], want [9 12] (seen from 169.254.169.254, id 123456789012)\nFAIL"}' ;;
  3) j='{"schema": "rbd.muse-hidden/v1", "pass": false, "failed": [], "ran": 0, "error": "no test ran: go test timed out"}' ;;
  *) j='{"schema": "rbd.muse-hidden/v1", "pass": true, "failed": [], "ran": 5, "passed": 5, "expected": 5, "missing": [], "build_failed": false, "go_test_rc": 0, "error": null, "output_tail": "ok  \tmaze/internal/svc/catalog\t0.41s"}' ;;
esac
printf '%s\n' "$j" > "$D/hidden.json"
echo "running the hidden tests of $2 against $RI"
printf '%s\n' "$j" | jq -c .
exit "$rc"
EOF
cat > "$SB/make_prs.sh" << 'EOF'
#!/usr/bin/env bash
# changes/make_prs.sh stand-in: CHANGE -> one open PR (the gh stand-in's files) and the CI it starts: candidate.json, the gate's
# artifacts and the commit status on the head (scenario: build ok|fail, verdict pass|block|inconclusive|error-ab, late)
. "$(dirname "$0")/scen.sh"
CH=$1
RI=$(jq -r .run "$SB_CHANGES/$CH/manifest.json")
echo "make_prs $CH ($RI)" >> "$SB_LOG"
n=$(($(cat "$SB_GH/prn" 2> /dev/null || echo 100) + 1)); echo "$n" > "$SB_GH/prn"
head=$(printf '%s' "$CH-$RI" | sha1sum | cut -c1-40)
now=$(date -u +%FT%TZ)
printf '[{"number": %d, "headRefOid": "%s", "url": "https://github.com/Sharvil2704/rhobound-maze-bed/pull/%d", "createdAt": "%s"}]\n' "$n" "$head" "$n" "$now" > "$SB_GH/pr-rbd_$CH.json"
echo OPEN > "$SB_GH/state-$n"; echo "$RI" > "$SB_GH/ri-$head"
svc=$(sc "$RI" service catalog) dig=sha256:$(printf '%s' "$head" | sha256sum | cut -c1-64)
R=$SB_TV/runs/$head; mkdir -p "$R/gate"
v=$(sc "$RI" verdict pass) rule=$(sc "$RI" rule mean_change@catalog)
if [ "$(sc "$RI" build ok)" != ok ]; then echo "x.go:3:1: undefined: fuzzyIndex (the CI build, Go 1.26.9)" > "$R/build-failed"
else
  printf '{"schema": "rbd.candidate/v1", "git_sha": "%s", "service": "%s", "services": ["%s"], "digest": "%s", "image": "123456789012.dkr.ecr.ap-south-1.amazonaws.com/rhobound-demo/maze@%s", "built_at": "%s"}\n' \
    "$head" "$svc" "$svc" "$dig" "$dig" "$now" > "$R/candidate.json"
fi
case $v in
  pass | block | inconclusive)
    eff=$v; [ "$v" = pass ] && eff=pass
    printf '{"verdict": "%s", "decide_with": %s, "rules": [{"rule": "input_refused", "effect": "pass", "evaluated": true, "number": "1"}, {"rule": "mean_change", "effect": "%s", "entry": "search-api", "evaluated": true, "number": "10", "threshold": 4, "value": %s, "variant": "block_band_model"}, {"rule": "doubt_holds:ab.payload_changed", "code": "ab.payload_changed", "effect": "%s", "entry": "catalog", "evaluated": %s, "number": "5"}]}\n' \
      "$v" "$(sc "$RI" decide_with '[]')" "$eff" "$(sc "$RI" value 1.2)" "$([ "$v" = inconclusive ] && echo inconclusive || echo pass)" "$([ "$v" = inconclusive ] && echo true || echo false)" > "$R/gate/gate.json"
    printf '{"step": "predict", "verdict": "%s", "rule": "%s", "candidate_digest": "%s", "images": {"%s": "123456789012.dkr.ecr.ap-south-1.amazonaws.com/rhobound-demo/maze@%s"}}\n' "$v" "$rule" "$dig" "$svc" "$dig" > "$R/predict.json"
    st=success; [ "$v" = pass ] || st=failure; desc="$v: $rule" ;;
  error-ab) st=error desc="no signed verdict: ab failure (see the run)" ;;
  error-build) st=error desc="no signed verdict: build failure (see the run)" ;;
esac
status=$(printf '[{"context": "rhobound/verdict", "state": "%s", "description": "%s", "creator": {"login": "github-actions[bot]"}, "updated_at": "%s"}, {"context": "rhobound/verdict", "state": "pending", "description": "gate running", "creator": {"login": "github-actions[bot]"}}]' "$st" "$desc" "$now")
if [ "$(sc "$RI" late no)" = yes ]; then echo "$status" > "$SB_GH/late-status-$head.json"; else echo "$status" > "$SB_GH/status-$head.json"; fi
printf '[{"databaseId": %d, "status": "completed", "conclusion": "%s", "createdAt": "%s", "startedAt": "%s", "updatedAt": "%s", "headSha": "%s"}]\n' \
  $((900 + n)) "$([ "$st" = success ] && echo success || echo failure)" "$now" "$now" "$now" "$head" > "$SB_GH/run-$head.json"
echo "https://github.com/Sharvil2704/rhobound-maze-bed/pull/$n"
EOF
cat > "$SB/candidate.sh" << 'EOF'
#!/usr/bin/env bash
# verify/candidate.sh stand-in (its contract): HEAD [--wait S] -> SVC=sha256:<digest> lines when built (exit 0); exit 1 when
# the build ended without an image (the build log's tail on stderr); exit 4 not yet
echo "candidate $*" >> "$SB_LOG"
d=runs/$1
if [ -s "$d/candidate.json" ]; then jq -r '.digest as $d | .services[] | "\(.)=\($d)"' "$d/candidate.json"; exit 0; fi
if [ -e "$d/build-failed" ]; then echo "candidate: the build of $1 ended without a candidate; the end of its log:" >&2; cat "$d/build-failed" >&2; exit 1; fi
echo "candidate: $1: not built yet" >&2; exit 4
EOF
cat > "$SB/truthx.sh" << 'EOF'
#!/usr/bin/env bash
# verify/truthx.sh stand-in (its contract): NAME SVC=DIGEST... -> verify/truthx/NAME/{truth.json (rbd.truthx/v1 times),
# b0.load.json, c.load.json}; the deltas per entry come from the scenario of the run whose candidate has the first DIGEST
. "$(dirname "$0")/scen.sh"
N=$1; shift
echo "truthx $N $* lock_wait=${RBD_LOCK_WAIT:-unset}" >> "$SB_LOG"
D=${1#*=} S=${1%%=*}
head=$(grep -l "\"digest\": \"$D\"" "$SB_TV"/runs/*/candidate.json | head -n 1 | xargs dirname | xargs basename)
RI=$(cat "$SB_GH/ri-$head")
O=$SB_TV/verify/truthx/$N; mkdir -p "$O"
L=$(sc "$RI" lock 0)
t() { date -u -d "@$(( $(date +%s) + L + $1 ))" +%FT%TZ; }
printf '{"schema": "rbd.truthx/v1", "change": "%s", "status": "ok", "image_ref": "123456789012.dkr.ecr.ap-south-1.amazonaws.com/rhobound-demo/maze", "window_s": 300, "b0_settle_s": 30, "services": ["%s"], "cand_digests": {"%s": "%s"}, "times": {"b0_start": "%s", "b0_end": "%s", "deploy_started": "%s", "deploy_done": "%s", "c_window_start": "%s", "c_window_end": "%s", "rollback_started": "%s", "rollback_done": "%s", "complete": "%s", "finished": "%s"}}\n' \
  "$N" "$S" "$S" "$D" "$(t 0)" "$(t 300)" "$(t 300)" "$(t 320)" "$(t 500)" "$(t 800)" "$(t 800)" "$(t 815)" "$(t 935)" "$(t 935)" > "$O/truth.json"
python3 -I - "$O" "$(sc "$RI" deltas '{}')" << 'LOADPY'
import json, sys
o, d = sys.argv[1], json.loads(sys.argv[2])
base = {"web": ("browse", 59.2), "mobile": ("feed", 74.1), "search-api": ("q", 60.1), "checkout": ("buy", 94.4), "partner": ("bulk", 58.2)}
for w, add in (("b0", False), ("c", True)):
    with open("%s/%s.load.json" % (o, w), "w") as f:
        f.write("2026/11/02 21:00:00 maze-load: 36000 requests over 300 s (120.0 rps), seed 1\n")
        for e, (path, m) in base.items():
            f.write(json.dumps({"errors": 0, "mean_ms": m + (d.get(e, 0.3) if add else 0.0), "ok": 4000, "url": "http://%s:8080/%s" % (e, path)}) + "\n")
        f.write("2026/11/02 21:05:00 maze-load: done in 300 s\n")
        f.write(json.dumps({"schema": "rbd.load/v1", "rps": 120.0, "shares": {"browse": 0.42, "feed": 0.25, "q": 0.125, "buy": 0.125, "bulk": 0.08}}) + "\n")
LOADPY
echo "truthx $N: ok (set image deployment/$S $S=123456789012.dkr.ecr.ap-south-1.amazonaws.com/rhobound-demo/maze@$D)"
exit "$(sc "$RI" truth_rc 0)"
EOF
cat > "$T/bin/gh" << 'EOF'
#!/usr/bin/env bash
# gh stand-in for muse_arm.sh: auth status, pr list --head, api .../commits/HEAD/statuses, run list --commit, pr view/close
echo "gh $*" >> "$SB_GH/calls.log"
arg() { local k=$1; shift; while [ $# -gt 0 ]; do [ "$1" = "$k" ] && { echo "$2"; return; }; shift; done; }
case "$1 $2" in
  "auth status") exit 0 ;;
  "pr list") b=$(arg --head "$@"); cat "$SB_GH/pr-${b//\//_}.json" 2> /dev/null || echo '[]' ;;
  "pr view") cat "$SB_GH/state-$3" 2> /dev/null || echo UNKNOWN ;;
  "pr close") echo CLOSED > "$SB_GH/state-$3"; echo "$3" >> "$SB_GH/closed.log" ;;
  "pr merge") echo "gh stand-in: a merge was attempted" >&2; echo "$*" >> "$SB_GH/MERGED"; exit 1 ;;
  "run list") h=$(arg --commit "$@"); cat "$SB_GH/run-$h.json" 2> /dev/null || echo '[]' ;;
  "api "*) h=$(sed -n 's,^repos/[^/]*/[^/]*/commits/\([0-9a-f]\{40\}\)/statuses.*,\1,p' <<< "$2")
           [ -n "$h" ] || { echo "gh stand-in: api $2?" >&2; exit 2; }
           cat "$SB_GH/status-$h.json" 2> /dev/null || echo '[]' ;;
  *) echo "gh stand-in: unsupported: $*" >&2; exit 2 ;;
esac
EOF
chmod +x "$SB"/*.sh "$T/bin/gh"
export RBD_SH=$SB/rbd.sh MUSE_ROOT_SH=$SB/root.sh MUSE_ROOT_LOGS=$T/tools1/rootlogs MUSE_TASK=$SB/task.sh MUSE_HIDDEN=$SB/hidden.sh \
  MUSE_AGENT_TAKE=$SB/agent_take.sh MUSE_MAKE_PRS=$SB/make_prs.sh MUSE_CANDIDATE=$SB/candidate.sh MUSE_TRUTHX=$SB/truthx.sh \
  MUSE_REGRESS=$DEMO/verify/regress.py MUSE_CHANGES=$T/changes RBD_STATE=$T/state MUSE_AGENT_STATE=$T/state/agent MUSE_POLL=1 MUSE_CF_WAIT=4 \
  MUSE_AGENT_WAIT=60 MUSE_HIDDEN_WAIT=60 MUSE_GATE_WAIT=60 MUSE_BUILD_WAIT=60 MUSE_MEASURE_WAIT=60
export MUSE_MAIN_SHA=$T/main.sha
echo 7ccb6922da148ddcc259cdd3b2a9a750845a4a07 > "$MUSE_MAIN_SHA"; mkdir -p "$TV/src"; cp "$MUSE_MAIN_SHA" "$TV/src/main.sha"
scen() { printf '%s\n' "$2" > "$SCEN/$1.json"; }
tlq() { jq -r "$2" "$T/state/muse/$1/timeline.json"; }
arm() { bash "$ARMSH" "$@" > "$T/arm.out" 2> "$T/arm.err"; echo $?; }

echo "-- refusals"
check "usage: no args (exit 2)" [ "$(arm)" = 2 ]
check "a bad ticket (exit 2)" [ "$(arm 'T9;x' R)" = 2 ]
check "a bad arm (exit 2)" [ "$(arm T9 X)" = 2 ]
check "--max-iter 0 (exit 2)" [ "$(arm T9 R --max-iter 0)" = 2 ]
check "--max-iter 4: task.sh's cap is 3 (exit 2)" [ "$(arm T9 R --max-iter 4)" = 2 ]
check "--tag with an upper-case letter or 7 characters (exit 2)" bash -c "[ \$(bash '$ARMSH' T9 R --tag X > /dev/null 2>&1; echo \$?) = 2 ] && [ \$(bash '$ARMSH' T9 R --tag abcdefg > /dev/null 2>&1; echo \$?) = 2 ]"
check "--collect for arm R (exit 2)" [ "$(arm T9 R --collect)" = 2 ]
check "--collect with no timeline (exit 1)" [ "$(arm T7 C --collect)" = 1 ]
mkdir -p "$T/state/muse"; touch "$T/state/muse/STOP"
check "kill switch: exit 5, nothing started" bash -c "[ $(arm T7 R) = 5 ] && ! grep -q '^task' '$SB_LOG'"
rm -f "$T/state/muse/STOP"
touch "$T/state/automerge.stop"
rc=$(MUSE_TRUTHX=$T/nope/truthx.sh arm T7 C)
check "state/automerge.stop is not this driver's kill switch (it stops merges): the run went on to the preflight (exit $rc, not 5)" [ "$rc" = 1 ]
rm -f "$T/state/automerge.stop"
echo 0000000000000000000000000000000000000000 > "$TV/src/main.sha"
rc=$(arm T7 C)
check "rbd-tools1's src/main.sha is not the kit's: refused before any session (exit 1, no timeline)" bash -c "[ $rc = 1 ] && grep -q 'agent_take.sh would refuse every change' '$T/arm.err' && [ ! -e '$T/state/muse/T7-C/timeline.json' ] && ! grep -q '^task ' '$SB_LOG'"
cp "$MUSE_MAIN_SHA" "$TV/src/main.sha"
rc=$(MUSE_TRUTHX=$T/nope/truthx.sh arm T7 C)
check "a remote step missing on rbd-tools1: refused before anything (exit 1, no timeline)" bash -c "[ $rc = 1 ] && grep -q 'missing (or not executable) on rbd-tools1: $T/nope/truthx.sh' '$T/arm.err' && [ ! -e '$T/state/muse/T7-C/timeline.json' ]"
check "nothing ran for the refusals (no task.sh, no PR)" bash -c "! grep -qE '^(task|make_prs)' '$SB_LOG'"
rm -rf "$T/state/muse/T7-R"

echo "-- T9-R: block (fed back) -> pass -> clean: accepted at 2"
scen mx-T9-R-i1 '{"verdict": "block", "rule": "mean_change@search-api", "value": 5.79, "decide_with": ["an A/B of fraud (diff-fit): a measured delta passes if the band at checkout stays at or under 4 ms"]}'
scen mx-T9-R-i2 '{"verdict": "pass", "deltas": {"search-api": 1.2}}'
rc=$(arm T9 R); cp "$T/arm.err" "$T/arm-T9-R.err"
check "exit 0 (rc $rc)" [ "$rc" = 0 ] || tail -5 "$T/arm.err"
check "timeline: accepted at 2" [ "$(tlq T9-R '"\(.status) \(.accepted_iteration) \(.exit)"')" = "accepted 2 0" ]
check "names: c23-muse then c24-muse (after c22-plant)" [ "$(tlq T9-R '[.iterations[].change] | join(" ")')" = "c23-muse c24-muse" ]
check "outcomes: gate_block accepted" [ "$(tlq T9-R '[.iterations[].outcome] | join(" ")')" = "gate_block accepted" ]
check "phases of iteration 1: agent take hidden pr gate" [ "$(tlq T9-R '[.phases[] | select(.iter == 1) | .phase] | join(" ")')" = "agent take hidden pr gate" ]
check "phases of iteration 2 end with the bracket's" bash -c "[ \"\$(jq -r '[.phases[] | select(.iter == 2) | .phase] | join(\" \")' '$T/state/muse/T9-R/timeline.json')\" = 'agent take hidden pr gate measure measure.lock_wait measure.b0_settle measure.b0 measure.rollout measure.warmup measure.c measure.rollback measure.settle_back' ]"
check "every phase has UTC start and end" [ "$(tlq T9-R '[.phases[] | select((.started_at // "" | test("^[0-9-]{10}T[0-9:]{8}Z$")) and (.ended_at // "" | test("^[0-9-]{10}T[0-9:]{8}Z$")))] | length')" = "$(tlq T9-R '.phases | length')" ]
FB2=$T/state/muse/T9-R/iter-02/feedback-in.md
check "iteration 2's feedback: the verdict and its rule" grep -q '^Verdict: block (mean_change@search-api)' "$FB2"
check "...the deciding rule with value and threshold" grep -q '^- mean_change at search-api: 5.79 against 4 (block)' "$FB2"
check "...decide_with" grep -q 'an A/B of fraud (diff-fit)' "$FB2"
check "task.sh got that feedback file for i=2 (and none for i=1)" bash -c "cmp -s '$FB2' '$T/seen/mx-T9-R-i2.feedback.md' && [ ! -e '$T/seen/mx-T9-R-i1.feedback.md' ]"
check "task.sh ran as root with ARM TICKET i RUN [FEEDBACK]" bash -c "grep -q '^task R T9 1 mx-T9-R feedback=\$' '$SB_LOG' && grep -q '^task R T9 2 mx-T9-R feedback=yes' '$SB_LOG' && grep -q '^root bash -c .* rootbg muse-mx-T9-R-i1-agent' '$SB_LOG'"
check "the feedback was put under /var/lib/rbd/muse/feedback" grep -q "^rbd.sh put .*/mx-T9-R-i2.feedback.md /var/lib/rbd/muse/feedback" "$SB_LOG"
check "one bracket only (the pass), named mx-t9-r-i2, cluster-lock wait 3600" bash -c "[ \$(grep -c '^truthx ' '$SB_LOG') = 1 ] && grep -q '^truthx mx-t9-r-i2 catalog=sha256:[0-9a-f]\{64\} lock_wait=3600' '$SB_LOG'"
p1=$(tlq T9-R '.iterations[0].pr') p2=$(tlq T9-R '.iterations[1].pr')
check "iteration 1's PR #$p1 closed (superseded), #$p2 left open" bash -c "[ \$(cat '$GHD/state-$p1') = CLOSED ] && [ \$(cat '$GHD/state-$p2') = OPEN ] && [ '$(tlq T9-R '.iterations[0].closed')' = true ]"
check "nothing merged" [ ! -e "$GHD/MERGED" ]
check "the gate: verdict, deciding rules and decide_with on the iteration" [ "$(tlq T9-R '.iterations[0].gate | "\(.verdict) \(.deciding_rules[0].rule) \(.decide_with | length)"')" = "block mean_change 1" ]
check "regress.py's verdict used (source, entries)" [ "$(tlq T9-R '.iterations[1].measure | "\(.source) \(.regressed) \(.worst_entry)"')" = "verify/regress.py false search-api" ]
check "agent stats from OUT/usage.json: steps 23, tool calls 5, tokens 57000, session 720 s" [ "$(tlq T9-R '.iterations[0].agent | "\(.source) \(.steps) \(.tool_calls) \(.tokens.total) \(.muse_seconds | floor)"')" = "usage.json 23 5 57000 720" ]
check "agent stats: rhobound MCP calls (context, budget, predict 1 each), Stop reminders 1 (hooks.stop_blocked)" [ "$(tlq T9-R '.iterations[0].agent | "\(.mcp_calls.context) \(.mcp_calls.budget) \(.mcp_calls.predict) \(.stop_reminders)"')" = "1 1 1 1" ]
check "candidate kept as digests and services only (no image ref)" [ "$(tlq T9-R '.iterations[1].candidate | keys | join(",")')" = "digest,digests,git_sha,services" ]
check "hidden.sh ran as ARM TICKET RUN ITER" grep -q '^hidden R T9 mx-T9-R 2$' "$SB_LOG"
check "candidate.sh asked once per look (--wait 0)" grep -q "^candidate [0-9a-f]\{40\} --wait 0$" "$SB_LOG"

echo "-- T9-C: no compile -> hidden fail -> deployed, regressed (counterfactual late, then --collect)"
scen mx-T9-C-i1 '{"take_rc": 3}'
scen mx-T9-C-i2 '{"hidden_rc": 1}'
scen mx-T9-C-i3 '{"verdict": "block", "rule": "mean_change@search-api", "value": 6.1, "late": "yes", "deltas": {"search-api": 6.4}, "lock": 120}'
rc=$(MUSE_REGRESS="" arm T9 C)
check "exit 3: not accepted (rc $rc)" [ "$rc" = 3 ] || tail -5 "$T/arm.err"
check "outcomes: no_compile hidden_fail regressed" [ "$(tlq T9-C '[.iterations[].outcome] | join(" ")')" = "no_compile hidden_fail regressed" ]
check "iteration 2's feedback: the compile errors" grep -q 'undefined: fuzzyIndex' "$T/state/muse/T9-C/iter-02/feedback-in.md"
F3=$T/state/muse/T9-C/iter-03/feedback-in.md
check "iteration 3's feedback: the hidden tests' output" grep -q -- '--- FAIL: TestSameAnswers' "$F3"
check "...with the address and the 12-digit number redacted" bash -c "grep -q 'seen from <ip>, id <n12>' '$F3' && ! grep -q '169.254.169.254\|123456789012' '$F3'"
check "no PR for the iterations that failed the checks; one for iteration 3" [ "$(tlq T9-C '[.iterations[] | .pr // "none"] | map(tostring) | join(" ")' | sed 's/[0-9][0-9]*$/N/')" = "none none N" ]
check "arm C waited only for the build: no gate phase, a build phase" [ "$(tlq T9-C '[.phases[] | select(.iter == 3) | .phase] | .[0:6] | join(" ")')" = "agent take hidden pr build measure" ]
check "the bracket's lock wait (b0 start 120 s after the launch, 30 s of it B0 settle: 90 s) is its own phase" [ "$(tlq T9-C '[.phases[] | select(.iter == 3 and .phase == "measure.lock_wait") | .seconds >= 85 and .seconds <= 95] | .[0]')" = true ]
check "measured with the rule here (regress.py absent): search-api +6.40 regressed, noisy band" [ "$(tlq T9-C '.iterations[2].measure | "\(.source | startswith("muse_arm")) \(.regressed) \(.worst_entry) \(.worst_delta_ms * 100 | round) \(.noisy_band)"')" = "true true search-api 640 false" ]
check "exposure: (rollback_done - rollout_done) 495 s x 2.4 ms over" [ "$(tlq T9-C '.iterations[2].measure | (.exposure_ms_min * 100 | round)')" = "1980" ]
check "the counterfactual is pending (late), the run says so" [ "$(tlq T9-C '"\(.iterations[2].counterfactual.verdict) \(.counterfactual_complete)"')" = "pending false" ]
check "iteration 3's feedback (for a next one) would be the regression" grep -q 'it regressed, and it was rolled back' "$T/state/muse/T9-C/iter-03/feedback-out.md"
h3=$(tlq T9-C '.iterations[2].head'); mv "$GHD/late-status-$h3.json" "$GHD/status-$h3.json"
rc=$(arm T9 C --collect)
check "--collect: exit 0 and the counterfactual recorded: block (mean_change@search-api)" bash -c "[ $rc = 0 ] && [ \"\$(jq -r '.iterations[2].counterfactual | \"\(.verdict) \(.rule) \(.final)\"' '$T/state/muse/T9-C/timeline.json')\" = 'block mean_change@search-api true' ]"
check "--collect keeps the arm's status (not_accepted, exit 3)" [ "$(tlq T9-C '"\(.status) \(.exit)"')" = "not_accepted 3" ]
check "the last iteration's PR stays open" [ "$(cat "$GHD/state-$(tlq T9-C '.iterations[2].pr')")" = OPEN ]

echo "-- T8-C: regressed, rolled back (fed back) -> clean: accepted at 2; counterfactual block then pass"
scen mx-T8-C-i1 '{"verdict": "block", "rule": "mean_change@search-api", "value": 6.0, "deltas": {"search-api": 6.4}, "raw": "yes"}'
scen mx-T8-C-i2 '{"verdict": "pass", "deltas": {"search-api": 1.0}}'
rc=$(arm T8 C)
check "exit 0 (rc $rc)" [ "$rc" = 0 ] || tail -5 "$T/arm.err"
check "outcomes: regressed accepted" [ "$(tlq T8-C '[.iterations[].outcome] | join(" ")')" = "regressed accepted" ]
F=$T/state/muse/T8-C/iter-02/feedback-in.md
check "feedback: deployed, regressed, rolled back; the entry changes" bash -c "grep -q 'rolled back' '$F' && grep -q '^- search-api: +6.40 ms (over the threshold)' '$F' && grep -q '^- web: +0.30 ms\$' '$F'"
check "counterfactuals: block then pass, both final" [ "$(tlq T8-C '[.iterations[].counterfactual | "\(.verdict)/\(.final)"] | join(" ")')" = "block/true pass/true" ]
check "iteration 1's PR closed once its counterfactual was in; 2 open" bash -c "[ \$(cat '$GHD/state-$(tlq T8-C '.iterations[0].pr')') = CLOSED ] && [ \$(cat '$GHD/state-$(tlq T8-C '.iterations[1].pr')') = OPEN ]"
check "no usage.json: agent stats from Muse's raw events in muse/runs/RUN/i1 (2 tool calls, no MCP, 47000 tokens), kept as *.raw" bash -c "[ \"\$(jq -r '.iterations[0].agent | \"\\(.source) \\(.tool_calls) \\(.mcp_calls | length) \\(.tokens.total)\"' '$T/state/muse/T8-C/timeline.json')\" = 'raw logs (events.jsonl) 2 0 47000' ] && [ -s '$T/state/muse/T8-C/iter-01/agent/events.jsonl.raw' ]"
check "regress.py (the real one) decided: search-api +6.40 over, resolved, rbd.regress/v1" [ "$(tlq T8-C '.iterations[0].measure | "\(.source) \(.regressed) \(.production_ok) \(.worst_entry) \(.noisy_band)"')" = "verify/regress.py true false search-api false" ]
check "two brackets, both with the long lock wait" [ "$(grep -c '^truthx mx-t8-c-i[12] .* lock_wait=3600' "$SB_LOG")" = 2 ]

echo "-- one arm at a time; an arm runs once"
check "a finished arm is not re-run (exit 1, timeline untouched, --tag named)" bash -c "s=\$(sha256sum < '$T/state/muse/T8-C/timeline.json'); [ \$(bash '$ARMSH' T8 C > '$T/rerun.err' 2>&1; echo \$?) = 1 ] && [ \"\$(sha256sum < '$T/state/muse/T8-C/timeline.json')\" = \"\$s\" ] && grep -q 'needs --tag T' '$T/rerun.err'"
scen mx-T8-C-r2-i1 '{"verdict": "pass", "deltas": {"search-api": 0.8}}'
rc=$(arm T8 C --tag r2)
check "--tag r2: a new attempt under new names (RUN mx-T8-C-r2, state/muse/T8-C-r2, bracket mx-t8-c-r2-i1), accepted (rc $rc)" bash -c "[ $rc = 0 ] && [ \"\$(jq -r '\"\\(.run) \\(.tag) \\(.iterations[0].run) \\(.iterations[0].truth_name) \\(.status)\"' '$T/state/muse/T8-C-r2/timeline.json')\" = 'mx-T8-C-r2 r2 mx-T8-C-r2-i1 mx-t8-c-r2-i1 accepted' ] && grep -q '^task C T8 1 mx-T8-C-r2 ' '$SB_LOG'"
( flock 8; sleep 4 ) 8>> "$T/state/muse/.driver.lock" &
sleep 0.5
check "a second driver while one holds state/muse/.driver.lock: refused" bash -c "[ \$(bash '$ARMSH' T6 R > '$T/lock.out' 2>&1; echo \$?) = 1 ] && grep -q 'one arm at a time' '$T/lock.out'"
wait; rm -rf "$T/state/muse/T6-R"

echo "-- harness errors stop the arm"
scen mx-T5-R-i1 '{"agent_rc": 3}'
rc=$(arm T5 R)
check "task.sh exit 3 (the export failed): the arm stops (exit 1, status error, the iteration's outcome error)" bash -c "[ $rc = 1 ] && [ \"\$(jq -r '\"\\(.status) \\(.iterations[0].outcome)\"' '$T/state/muse/T5-R/timeline.json')\" = 'error error' ]"
scen mx-T4-R-i1 '{"verdict": "error-ab"}'
rc=$(arm T4 R)
check "a gate error after the build (A/B): the harness's, not fed back (exit 1)" bash -c "[ $rc = 1 ] && grep -q 'the harness, not the agent' '$T/arm.err' && [ ! -e '$T/state/muse/T4-R/iter-01/feedback-out.md' ]"
scen mx-T3-R-i1 '{"verdict": "error-build"}'
scen mx-T3-R-i2 '{"verdict": "pass"}'
rc=$(arm T3 R)
check "a gate error at the build: fed back as the agent's (accepted at 2, rc $rc)" bash -c "[ $rc = 0 ] && grep -q 'no signed verdict: build failure' '$T/state/muse/T3-R/iter-02/feedback-in.md'"
scen mx-T2-C-i1 '{"truth_rc": 4}'
rc=$(arm T2 C)
check "truthx exit 4 (rollback failed): exit 4, said loudly, recorded as a deploy" bash -c "[ $rc = 4 ] && grep -q 'THE ROLLBACK FAILED' '$T/arm.err' && [ \"\$(jq -r '.iterations[0] | \"\\(.deployed) \\(.measure_exit) \\(.outcome)\"' '$T/state/muse/T2-C/timeline.json')\" = 'true 4 error' ]"
scen mx-T1-C-i1 '{"take_rc": 9}'
rc=$(arm T1 C)
check "agent_take cannot fetch: the harness's (exit 1), not fed back" bash -c "[ $rc = 1 ] && [ ! -e '$T/state/muse/T1-C/iter-01/feedback-out.md' ]"
scen mx-T1-R-i1 '{"take_rc": 1}'
scen mx-T1-R-i2 '{"verdict": "pass"}'
rc=$(arm T1 R --max-iter 2)
check "a refusal is fed back (its lines), accepted at 2 (rc $rc)" bash -c "[ $rc = 0 ] && grep -q 'go:linkname' '$T/state/muse/T1-R/iter-02/feedback-in.md'"

scen mx-T6-R-i1 '{"hidden_rc": 3}'
rc=$(arm T6 R)
check "hidden.sh exit 3 (the check could not run): the harness's (exit 1), not fed back" bash -c "[ $rc = 1 ] && grep -q 'the harness, not the agent' '$T/arm.err' && [ ! -e '$T/state/muse/T6-R/iter-01/feedback-out.md' ]"
scen mx-T6-C-i1 '{"agent_rc": 1}'
scen mx-T6-C-i2 '{"build": "fail", "verdict": "error-build"}'
scen mx-T6-C-i3 '{"verdict": "pass", "deltas": {"search-api": 0.5}}'
rc=$(arm T6 C)
check "arm C: no change (task.sh exit 1) -> build failed -> accepted at 3 (rc $rc)" bash -c "[ $rc = 0 ] && [ \"\$(jq -r '[.iterations[].outcome] | join(\" \")' '$T/state/muse/T6-C/timeline.json')\" = 'no_change build_failed accepted' ]"
check "...task.sh's errors were the feedback (no agent_take run for it)" bash -c "grep -q '^- a file outside internal/svc/catalog/ was edited: go.mod' '$T/state/muse/T6-C/iter-02/feedback-in.md' && ! grep -q '^take mx-T6-C-i1 ' '$SB_LOG'"
check "...the build failure was fed back with the build log's tail" bash -c "grep -q 'no signed verdict: build failure' '$T/state/muse/T6-C/iter-03/feedback-in.md' && grep -q 'undefined: fuzzyIndex (the CI build' '$T/state/muse/T6-C/iter-03/feedback-in.md'"
check "...the failed build was not deployed (one bracket for T6-C)" [ "$(grep -c '^truthx mx-t6-c-' "$SB_LOG")" = 1 ]

echo "-- leaks: nothing written here (other than the verbatim *.raw fetches) holds the account id or the address"
leaks=$(grep -rlE '123456789012|169\.254\.169\.254' "$T/state/muse" --exclude='*.raw' 2> /dev/null || true)
check "no 12-digit account id or public address in state/muse (${leaks:-none})" [ -z "$leaks" ]
check "...the fetched truth.json and predict.json kept, redacted" bash -c "grep -q '<n12>.dkr.ecr' '$T/state/muse/T9-R/iter-02/truth/truth.json' && grep -q '<n12>.dkr.ecr' '$T/state/muse/T9-R/iter-01/gate/predict.json'"

echo "-- muse_score.py on a hand-made pair (exact numbers)"
F=$T/fx; mkdir -p "$F/T5-R" "$F/T5-C"
cat > "$F/T5-R/timeline.json" << 'EOF'
{"schema": "rbd.muse-arm/v1", "ticket": "T5", "arm": "R", "max_iter": 3, "threshold_ms": 4.0, "status": "accepted", "exit": 0,
 "started_at": "2026-11-03T00:00:00Z", "ended_at": "2026-11-03T02:00:00Z", "accepted_iteration": 2,
 "phases": [{"iter": 1, "phase": "agent", "seconds": 600}, {"iter": 1, "phase": "take", "seconds": 60}, {"iter": 1, "phase": "hidden", "seconds": 60},
            {"iter": 1, "phase": "pr", "seconds": 30}, {"iter": 1, "phase": "gate", "seconds": 1200},
            {"iter": 2, "phase": "agent", "seconds": 900}, {"iter": 2, "phase": "gate", "seconds": 1100}, {"iter": 2, "phase": "measure", "seconds": 1000}],
 "iterations": [
  {"iter": 1, "change": "c23-muse", "pr": 30, "head": "1111111111111111111111111111111111111111", "outcome": "gate_block", "hidden": {"rc": 0},
   "gate": {"verdict": "block", "rule": "mean_change@search-api", "gate_started": "2026-11-03T00:13:00Z", "gate_ended": "2026-11-03T00:33:00Z"},
   "agent": {"rc": 0, "steps": 20, "tool_calls": 40, "tokens": {"total": 100000}, "mcp_calls": {"predict": 2, "context": 1}, "stop_reminders": 1}},
  {"iter": 2, "change": "c24-muse", "pr": 31, "head": "2222222222222222222222222222222222222222", "outcome": "accepted", "hidden": {"rc": 0}, "deployed": true,
   "gate": {"verdict": "pass", "rule": "mean_change@search-api", "gate_started": "2026-11-03T00:50:00Z", "gate_ended": "2026-11-03T01:08:00Z"},
   "agent": {"rc": 0, "steps": 10, "tool_calls": 15, "tokens": {"total": 50000}, "mcp_calls": {"predict": 1}, "stop_reminders": 0},
   "measure": {"regressed": false, "worst_entry": "search-api", "worst_delta_ms": 1.5, "b0_window_s": 300, "lock_wait_s": 10, "exposure_ms_min": 0.0,
               "in_production_min": 8.0, "noisy_band": false, "times": {"c_end": "2026-11-03T01:30:00Z"}}}]}
EOF
cat > "$F/T5-C/timeline.json" << 'EOF'
{"schema": "rbd.muse-arm/v1", "ticket": "T5", "arm": "C", "max_iter": 3, "threshold_ms": 4.0, "status": "accepted", "exit": 0,
 "started_at": "2026-11-02T22:00:00Z", "ended_at": "2026-11-02T23:30:00Z", "accepted_iteration": 2,
 "phases": [{"iter": 1, "phase": "agent", "seconds": 500}, {"iter": 1, "phase": "build", "seconds": 240}, {"iter": 1, "phase": "measure", "seconds": 1500},
            {"iter": 2, "phase": "agent", "seconds": 700}, {"iter": 2, "phase": "build", "seconds": 260}, {"iter": 2, "phase": "measure", "seconds": 1600}],
 "iterations": [
  {"iter": 1, "change": "c25-muse", "pr": 32, "head": "3333333333333333333333333333333333333333", "outcome": "regressed", "hidden": {"rc": 0}, "deployed": true,
   "counterfactual": {"verdict": "block", "rule": "mean_change@search-api", "final": true},
   "agent": {"rc": 0, "steps": 12, "tool_calls": 30, "tokens": {"total": 80000}, "mcp_calls": {}, "stop_reminders": 0},
   "measure": {"regressed": true, "worst_entry": "search-api", "worst_delta_ms": 7.0, "b0_window_s": 300, "lock_wait_s": 600, "exposure_ms_min": 24.0,
               "in_production_min": 8.0, "noisy_band": false, "times": {"c_end": "2026-11-02T22:40:00Z"}}},
  {"iter": 2, "change": "c26-muse", "pr": 33, "head": "4444444444444444444444444444444444444444", "outcome": "accepted", "hidden": {"rc": 0}, "deployed": true,
   "counterfactual": {"verdict": "inconclusive", "rule": "doubt_holds:ab.payload_changed", "final": true},
   "agent": {"rc": 0, "steps": 8, "tool_calls": 20, "tokens": {"total": 40000}, "mcp_calls": {}, "stop_reminders": 0},
   "measure": {"regressed": false, "worst_entry": "web", "worst_delta_ms": 2.5, "b0_window_s": 300, "lock_wait_s": 540, "exposure_ms_min": 0.0,
               "in_production_min": 8.0, "noisy_band": true, "times": {"c_end": "2026-11-02T23:20:00Z"}}}]}
EOF
python3 -I "$SCORE" --state "$F" > "$T/score.md" 2> "$T/score.err"; rc=$?
check "exit 0 (rc $rc), SCORE.json and SCORE.md written" bash -c "[ $rc = 0 ] && [ -s '$F/SCORE.json' ] && [ -s '$F/SCORE.md' ]"
sq() { jq -r "$1" "$F/SCORE.json"; }
check "R: lead time 90 min (start -> accepted C window end), - B0 85 min, - queue 84.8 min" [ "$(sq '.arms[] | select(.arm == "R") | "\(.lead_time_s) \(.lead_time_minus_b0_s) \(.lead_time_minus_b0_and_queue_s)"')" = "5400 5100 5090" ]
check "C: lead time 80 min; - B0 (two brackets) 70 min; - queue 50.7 min" [ "$(sq '.arms[] | select(.arm == "C") | "\(.lead_time_s) \(.lead_time_minus_b0_s) \(.lead_time_minus_b0_and_queue_s)"')" = "4800 4200 3060" ]
check "R: agent 1500 s, CI 2300 s (gate phases), checks 150 s, gate runs 2280 s" [ "$(sq '.arms[] | select(.arm == "R") | "\(.agent_time_s) \(.ci_time_s) \(.checks_time_s) \(.gate_run_s)"')" = "1500 2300 150 2280" ]
check "C: CI 500 s (build phases), deploys 2, regressions 1, rollbacks 1, exposure 24" [ "$(sq '.arms[] | select(.arm == "C") | "\(.ci_time_s) \(.deploys) \(.regressions) \(.rollbacks) \(.exposure_ms_min == 24)"')" = "500 2 1 1 true" ]
check "R: deploys 1, no regression, no wrong pass; steps 30, tokens 150000, MCP 4, Stop 1" [ "$(sq '.arms[] | select(.arm == "R") | "\(.deploys) \(.regressions) \(.wrong_passes) \(.steps) \(.tokens) \(.mcp_calls) \(.stop_reminders)"')" = "1 0 0 30 150000 4 1" ]
check "C counterfactual: right on the regression, a false hold on the clean change" [ "$(sq '.arms[] | select(.arm == "C") | [.counterfactual[].reading] | join("; ")')" = "right: held a regression; false hold: held a clean change" ]
check "the Markdown: a row per arm, the R-C line (+10.0 min), the counterfactual table" bash -c "grep -q '^| T5 | R | accepted at 2 | 2/3 | 90.0 min | 85.0 min |' '$T/score.md' && grep -q '^| T5 | yes / yes | [^|]* | +10.0 min | +15.0 min | 0 / 1 | 0.0 / 24.0 |' '$T/score.md' && grep -q 'false hold: held a clean change' '$T/score.md'"
check "a noisy worst entry is marked" grep -q 'web +2.50 ms (noisy)' "$T/score.md"

echo "-- muse_score.py over the scenarios' state"
python3 -I "$SCORE" --state "$T/state/muse" --out "$T/score2" > "$T/score2.md" 2> "$T/score2.err"; rc=$?
check "exit 0 (rc $rc)" [ "$rc" = 0 ] || cat "$T/score2.err"
s2() { jq -r "$1" "$T/score2/SCORE.json"; }
check "T9-R: accepted at 2, 1 deploy, no regression, MCP calls 6, Stop reminders 2" [ "$(s2 '.arms[] | select(.ticket == "T9" and .arm == "R") | "\(.accepted_iteration) \(.deploys) \(.regressions) \(.mcp_calls) \(.stop_reminders)"')" = "2 1 0 6 2" ]
check "T9-C: not accepted, 1 deploy, 1 regression, counterfactual right" [ "$(s2 '.arms[] | select(.ticket == "T9" and .arm == "C") | "\(.accepted) \(.deploys) \(.regressions) \(.counterfactual[0].reading)"')" = "false 1 1 right: held a regression" ]
check "T8-C: lead time measured, lock queue counted (never negative)" [ "$(s2 '.arms[] | select(.ticket == "T8" and .arm == "C" and .tag == null) | (.lead_time_s > 0) and (.lock_wait_s >= 0)')" = true ]
check "T8-C-r2: scored as its own attempt (tag r2), accepted at 1" [ "$(s2 '.arms[] | select(.ticket == "T8" and .tag == "r2") | "\(.arm) \(.accepted_iteration)"')" = "C 1" ]
check "T2-C: the deploy whose rollback failed counts, unmeasured" [ "$(s2 '.arms[] | select(.ticket == "T2" and .arm == "C") | "\(.deploys) \(.unmeasured_deploys) \(.per_iteration[0].measured)"')" = "1 1 deployed, unmeasured" ]
check "T9: an R-against-C row" grep -q '^| T9 | yes / no |' "$T/score2.md"
leaks=$(grep -lE '123456789012|169\.254\.169\.254' "$T/score2/SCORE.json" "$T/score2/SCORE.md" "$F/SCORE.json" 2> /dev/null || true)
check "the scoreboard holds no account id or address" [ -z "$leaks" ]

echo "-- make_prs.sh c23-muse (local bare repo, tools1/tests/ci/fakebin/gh)"
MP=$T/mp; mkdir -p "$MP/fake" "$MP/changes/c23-muse" "$MP/stub"
cp "$DEMO/tools1/tests/ci/fakebin/gh" "$MP/fake/gh"; chmod +x "$MP/fake/gh"
cp "$DEMO/changes/make_prs.sh" "$MP/changes/"
gq() { git -c user.name=t -c user.email=t@example.invalid -c commit.gpgsign=false -C "$MP/src" "$@"; }
mkdir -p "$MP/src/maze/app" && printf 'package main\n\nfunc main() {}\n' > "$MP/src/maze/app/main.go"
gq init -q -b main && gq add -A && gq commit -q -m main && git clone -q --bare "$MP/src" "$MP/bare.git"
(cd "$MP/src" && sed -i 's/func main() {}/func main() { _ = 1 }/' maze/app/main.go && git diff > "$MP/changes/c23-muse/change.patch" && git checkout -q -- .)
printf '{"schema": "rbd.change-request/v2", "services": ["catalog"], "summary": "faster catalog search"}\n' > "$MP/changes/c23-muse/rhobound-change.json"
echo "Make catalog.Search faster" > "$MP/changes/c23-muse/title.txt"
printf '{"schema": "rbd.agent-change/v1", "model": "muse-spark-1.3", "served_by": ["muse-spark-1.3"]}\n' > "$MP/changes/c23-muse/manifest.json"
mp() { (export PATH="$MP/fake:$PATH" STUB_DIR=$MP/stub URL=$MP/bare.git WORK=$MP/work; "$@") > "$MP/out" 2> "$MP/err"; echo $?; }
rc=$(mp env DRYRUN=1 bash "$MP/changes/make_prs.sh" c23-muse)
check "DRYRUN: says the PR would get --label rbd-muse, pushes nothing (rc $rc)" bash -c "[ $rc = 0 ] && grep -q 'would be opened with: --label rbd-muse' '$MP/err' && ! git -C '$MP/bare.git' rev-parse -q --verify refs/heads/rbd/c23-muse > /dev/null && ! grep -q 'label create' '$MP/stub/calls.log' 2> /dev/null"
rc=$(mp bash "$MP/changes/make_prs.sh" c23-muse)
check "the PR: branch rbd/c23-muse pushed, title from title.txt, label rbd-muse (created when missing), not a draft (rc $rc)" bash -c "[ $rc = 0 ] && git -C '$MP/bare.git' rev-parse -q --verify refs/heads/rbd/c23-muse > /dev/null &&
  grep -q 'gh label create rbd-muse' '$MP/stub/calls.log' && tr '\\n' ' ' < '$MP/stub/calls.log' | grep -q 'gh pr create .*--head rbd/c23-muse --title c23-muse: Make catalog.Search faster .*--label rbd-muse' && ! tr '\\n' ' ' < '$MP/stub/calls.log' | grep -q 'pr create .*--draft'"
check "...its body says NEVER merge (rbd-muse is not rbd-bench)" grep -q 'NEVER merge it: labelled rbd-muse' "$MP/stub/calls.log"
check "...only maze/app/ and rhobound-change.json changed" [ "$(git -C "$MP/bare.git" diff --name-only main rbd/c23-muse | tr '\n' ' ')" = "maze/app/main.go rhobound-change.json " ]
check "automerge.sh merges only label rbd-bench (an rbd-muse PR is never a candidate)" bash -c "grep -q '^LABEL=rbd-bench\$' '$DEMO/orch/automerge.sh' && grep -q 'if label not in \[l.get(\"name\") for l in pr.get(\"labels\") or \[\]\]:' '$DEMO/orch/automerge.sh'"
check "make_prs.sh: cN-bench still gets rbd-bench, cN-muse rbd-muse" bash -c "grep -q '\*-bench) echo rbd-bench' '$DEMO/changes/make_prs.sh' && grep -q '\*-muse) echo rbd-muse' '$DEMO/changes/make_prs.sh'"

echo "-- static"
check "muse_arm.sh: bash -n" bash -n "$ARMSH"
if command -v shellcheck > /dev/null; then check "muse_arm.sh, make_prs.sh: shellcheck" shellcheck -x -P "$DEMO" "$ARMSH" "$DEMO/changes/make_prs.sh"; fi
check "muse_arm.sh never calls kubectl, aws or docker itself" bash -c "! grep -nE '(^|[^-a-z_])(kubectl|aws|docker) ' '$ARMSH' | grep -v '^[0-9]*:#' | grep -q ."
check "muse_score.py compiles" python3 -I -c "import ast,sys; ast.parse(open(sys.argv[1]).read())" "$SCORE"
check "no real ssh/aws/docker call (lib.sh's stubs)" bash -c "! grep -qE '^(ssh|aws|docker) ' '$STUB_LOG'"
finish
