#!/usr/bin/env bash
# test_task.sh: tools1/muse/task.sh, export.py and hidden.sh end to end, offline, with stand-ins for /opt/muse/run.sh and
# mkws.sh (fake_run.sh writes Muse's event and session-log shapes as seen live; fake_mkws.sh makes the workspace from a
# copy of the kit's repo/, which is state/main.sha's commit). MUSE_TEST_ROOT puts every path under a scratch folder; sudo,
# pkill, ssh, aws, docker and kubectl fail loudly if anything calls them. The contract check: the real orch/agent_take.sh
# takes task.sh's OUT (RBD_AGENT_LOCAL, a copy of the kit; compiled through capped.sh).
# Then hidden.sh: pass, fail, does-not-compile, no-test-ran and refused cases (go test on the catalog package, offline).
#   bash tools1/muse/tests/test_task.sh            (KEEP=1 keeps the scratch folder)
set -uo pipefail
H=$(cd "$(dirname "$0")" && pwd)
KIT=$(cd "$H/../../.." && pwd)
SCR=${RBD_SCRATCH:-${TMPDIR:-/tmp}/rbd}/muse-t
mkdir -p "$SCR"
T=$(mktemp -d "$SCR/t.XXXXXX")
PASS=0 FAILS=0
ok() { PASS=$((PASS + 1)); echo "  ok   $*"; }
bad() { FAILS=$((FAILS + 1)); echo "  FAIL $*"; }
check() { local d=$1; shift; if "$@"; then ok "$d"; else bad "$d"; fi; }
j() { python3 -I -c 'import json,sys; d=json.load(open(sys.argv[1]))
for k in sys.argv[2].split("."):
    d = d[int(k)] if isinstance(d, list) else d.get(k)
print(json.dumps(d) if isinstance(d, (dict, list, bool)) or d is None else d)' "$1" "$2"; }

mkdir -p "$T/bin"
for c in sudo pkill pgrep ssh aws docker kubectl setpriv unshare; do
  printf '#!/usr/bin/env bash\necho "STUB: %s $* must not run in this test" >&2\necho "%s $*" >> "%s/forbidden.log"\nexit 97\n' \
    "$c" "$c" "$T" > "$T/bin/$c"
done
chmod +x "$T/bin/"*
export PATH=$T/bin:$PATH
[ "$(command -v sudo)" = "$T/bin/sudo" ] || { echo "stubs are not first on PATH: refusing to run" >&2; exit 2; }
export MUSE_TEST_ROOT=$T/root FAKE_LOG=$T/fake.log
R=$MUSE_TEST_ROOT
mkdir -p "$R/opt-muse/tickets" "$R/rbd/src" "$R/rbd/tmp" "$R/home/muser" "$R/home/musec" "$R/vartmp"
cp "$H/fake_run.sh" "$R/opt-muse/run.sh"
cp "$H/fake_mkws.sh" "$R/opt-muse/mkws.sh"
cp "$KIT/tools1/muse/export.py" "$R/opt-muse/export.py"
cp -r "$H/fixtures/T9" "$R/opt-muse/tickets/T9"
cp -r "$H/fixtures/T9" "$R/opt-muse/tickets/T8"
printf '%s\n' '{"id": "T8", "services": ["events"]}' > "$R/opt-muse/tickets/T8/meta.json"
cp -r "$H/fixtures/T9" "$R/opt-muse/tickets/T7"
printf '%s\n' '{"id": "T7", "services": ["catalog"], "test_tags": "nosuchtag"}' > "$R/opt-muse/tickets/T7/meta.json"
cp -r "$KIT/repo" "$R/rbd/src/main"
rm -rf "$R/rbd/src/main/.git"
MAIN=$(head -c 40 "$KIT/state/main.sha" 2> /dev/null || true)
[[ $MAIN =~ ^[0-9a-f]{40}$ ]] || MAIN=0123456789abcdef0123456789abcdef01234567   # no state/ in a fresh checkout: any commit id works
echo "$MAIN" > "$R/rbd/src/main.sha"
TASK=$KIT/tools1/muse/task.sh HIDDEN=$KIT/tools1/muse/hidden.sh
CAT=maze/app/internal/svc/catalog

# the agents (FAKE_AGENT: bash, cwd = the workspace)
A=$T/agents
mkdir -p "$A"
cat > "$A/hello.sh" << 'EOF'
printf 'package catalog\n\n// Hello greets the storefront health page.\nfunc Hello() string { return "hi" }\n' > maze/app/internal/svc/catalog/hello.go
echo "my notes" > NOTES.md
echo '{"schema": "rbd.change-request/v1", "services": ["web"], "summary": "agent wrote this"}' > rhobound-change.json
EOF
cat > "$A/comment.sh" << 'EOF'
printf '\n// Search is called from several goroutines at once.\n' >> maze/app/internal/svc/catalog/catalog.go
EOF
cat > "$A/ho.sh" << 'EOF'
printf 'package catalog\n\nfunc Hello() string { return "ho" }\n' > maze/app/internal/svc/catalog/hello.go
EOF
cat > "$A/none.sh" << 'EOF'
echo "looked around" > /dev/null
EOF
cat > "$A/nine.sh" << 'EOF'
for i in 1 2 3 4 5 6 7 8 9; do printf 'package catalog\n\nconst c%s = %s\n' $i $i > maze/app/internal/svc/catalog/c$i.go; done
EOF
cat > "$A/delete.sh" << 'EOF'
bash "$FAKE_AGENTS/hello.sh"; rm maze/app/internal/svc/catalog/catalog_test.go
EOF
cat > "$A/link.sh" << 'EOF'
bash "$FAKE_AGENTS/hello.sh"; ln -s catalog.go maze/app/internal/svc/catalog/alias.go
EOF
cat > "$A/linkdir.sh" << 'EOF'
mkdir -p ../../outside && printf 'package catalog\n\n// SECRET-OUTSIDE\n' > ../../outside/secret.go
cp maze/app/internal/svc/catalog/*.go ../../outside/
rm -rf maze/app/internal/svc/catalog && ln -s "$(cd ../../outside && pwd)" maze/app/internal/svc/catalog
EOF
cat > "$A/big.sh" << 'EOF'
python3 -I -c 'print("package catalog\n\n// " + "x" * 120000)' > maze/app/internal/svc/catalog/big.go
EOF
cat > "$A/tag.sh" << 'EOF'
printf '//go:build linux\n\npackage catalog\n\nfunc Hello() string { return "hi" }\n' > maze/app/internal/svc/catalog/hello.go
EOF
cat > "$A/n12.sh" << 'EOF'
printf 'package catalog\n\nconst acct = 123456789012\n\nfunc Hello() string { return "hi" }\n' > maze/app/internal/svc/catalog/hello.go
EOF
cat > "$A/gomod.sh" << 'EOF'
bash "$FAKE_AGENTS/hello.sh"; printf '\n// tidy\n' >> maze/app/go.mod
EOF
cat > "$A/fifo.sh" << 'EOF'
bash "$FAKE_AGENTS/hello.sh"; mkfifo maze/app/pipe; mkfifo maze/app/internal/svc/catalog/zz.txt
EOF
cat > "$A/gitevil.sh" << EOF
bash "\$FAKE_AGENTS/hello.sh"
printf '#!/bin/sh\ntouch $T/hook-ran\n' > .git/hooks/pre-commit; chmod +x .git/hooks/pre-commit
printf '#!/bin/sh\ntouch $T/hook-ran\n' > .git/hooks/post-commit; chmod +x .git/hooks/post-commit
git config filter.evil.clean "sh -c 'touch $T/filter-ran; cat'"
git config core.fsmonitor "sh -c 'touch $T/fsmonitor-ran'"
echo '* filter=evil' > .gitattributes
EOF
cat > "$A/twoimg.sh" << 'EOF'
bash "$FAKE_AGENTS/hello.sh"; printf '\n// pricing, too\n' >> maze/app/internal/svc/pricing/pricing.go
EOF
cat > "$A/notify.sh" << 'EOF'
printf '\n// notify: events and audit share this image.\n' >> maze/app/cmd/notify/main.go
EOF
export FAKE_AGENTS=$A
FB=$T/feedback.md
printf 'The gate said: block. Deciding rule: max_entry_mean_change_ms (search-api /q +6.2 ms > 4.0).\n' > "$FB"

rt() {   # rt AGENT ARM TICKET ITER RUN [FEEDBACK]: task.sh's exit code in RC, stdout in $T/o, stderr in $T/e
  local ag=$1; shift
  RC=0
  FAKE_AGENT=$A/$ag.sh timeout 300 bash "$TASK" "$@" > "$T/o" 2> "$T/e" || RC=$?
}
ag=$R/rbd/agent
echo "== task.sh: arm R, iteration 1 (an agent that adds Hello)"
rt hello R T9 1 mx-T9-R
check "exit 0 (OUT holds the change): $RC" test "$RC" = 0
O=$ag/mx-T9-R-i1
check "OUT is agent.py's format: result ok, manifest v1 schema, files/, rhobound-change.json, change.patch, title.txt" bash -c "
  [ \"\$(cd '$O' && find . -type f | sort | tr '\n' ' ')\" = './change.patch ./files/$CAT/hello.go ./manifest.json ./result.json ./rhobound-change.json ./title.txt ./usage.json ' ]"
check "result.json ok, service catalog, 1 file" test "$(j "$O/result.json" ok)/$(j "$O/result.json" service)/$(j "$O/result.json" files)" = "true/catalog/1"
check "manifest: schema, base_sha = main.sha, model, turns, the file's sha256" python3 -I -c '
import hashlib, json, sys
m = json.load(open(sys.argv[1] + "/manifest.json"))
f = m["files"][0]
b = open(sys.argv[1] + "/files/" + f["path"], "rb").read()
assert m["schema"] == "rbd.agent-change/v1" and m["base_sha"] == sys.argv[2] and m["model"] == "muse-spark-1.3", m
assert m["turns"] == 3 and f["new"] is True and f["sha256"] == hashlib.sha256(b).hexdigest() and f["bytes"] == len(b), m
assert [c["tool"] for c in m["mcp_calls"]] == ["context", "predict"], m["mcp_calls"]' "$O" "$MAIN"
check "rhobound-change.json v1 {schema, services [catalog], summary = the manifest's} (not the agent's own file)" python3 -I -c '
import json, sys
r = json.load(open(sys.argv[1] + "/rhobound-change.json")); m = json.load(open(sys.argv[1] + "/manifest.json"))
assert r == {"schema": "rbd.change-request/v1", "services": ["catalog"], "summary": m["summary"]}, r' "$O"
check "title: fixed, from task.md ($(cat "$O/title.txt"))" test "$(cat "$O/title.txt")" = "[muse-R i1] T9: Catalog greets its callers"
check "summary: the agent's note, without its addresses, 12-digit number, CI-skip token or control character" python3 -I -c '
import json, sys
s = json.load(open(sys.argv[1] + "/manifest.json"))["summary"]
assert "I added Hello to catalog" in s and "100.64.7.9" not in s and "10.0.0.5" not in s and "123456789012" not in s, s
assert "skip ci" not in s.lower() and "\x07" not in s and len(s) <= 1000, s' "$O"
U=$O/usage.json
check "usage: model steps 3, tokens 1200/450/300/200, steps cap 150, wall time, rc 0" bash -c "
  [ \"$(j "$U" model_steps)/$(j "$U" tokens.input)/$(j "$U" tokens.output)/$(j "$U" tokens.cached)/$(j "$U" tokens.reasoning)/$(j "$U" steps_cap)/$(j "$U" session.rc)\" = 3/1200/450/300/200/150/0 ] &&
  python3 -I -c 'import json,sys; s=json.load(open(sys.argv[1]))[\"session\"]; assert s[\"wall_s\"] >= 0 and s[\"started\"].endswith(\"Z\")' '$U'"
check "usage: MCP calls context, predict (not the model's mention, not a file's content); 6 offered; 2 previews" bash -c "
  [ '$(j "$U" mcp_call_counts)' = '{\"context\": 1, \"predict\": 1}' ] && [ '$(j "$U" previews_new)' = 2 ] &&
  [ '$(j "$U" mcp_offered)' = '[\"budget\", \"context\", \"explain\", \"fit_start\", \"job_status\", \"predict\"]' ]"
check "usage: tool calls by kind (read_file 1, edit_file 2, the MCP kinds)" python3 -I -c '
import json, sys
k = json.load(open(sys.argv[1]))["tool_calls_by_kind"]
assert k == {"tool.read_file": 1, "tool.mcp__rhobound__context": 1, "tool.mcp": 1, "tool.edit_file": 2}, k' "$U"
check "usage: hook records from the session log (SessionStart 0; Stop 2 blocked, then 0)" python3 -I -c '
import json, sys
h = json.load(open(sys.argv[1]))["hooks"]
assert h["session_log"]["found"] and h["session_log"]["by"] == "session id from the events", h["session_log"]
assert h["summary"]["SessionStart"]["exit_codes"] == [0] and h["summary"]["Stop"]["exit_codes"] == [2, 0], h["summary"]
assert h["stop_blocked"] == 1 and h["summary"]["Stop"]["effects"] == [["blocked"], []], h' "$U"
check "usage: workspace commit, base commit, ignored NOTES.md, rhobound-change.json, .rhobound/muse.json" python3 -I -c '
import json, re, sys
w = json.load(open(sys.argv[1]))["workspace"]
assert re.fullmatch("[0-9a-f]{40}", w["commit"]) and re.fullmatch("[0-9a-f]{40}", w["base_commit"]), w
assert {"NOTES.md", "rhobound-change.json", ".rhobound/muse.json"} <= set(w["ignored"]), w["ignored"]
assert w["changed"] == ["maze/app/internal/svc/catalog/hello.go"] and w["touched"] == ["internal/svc/catalog"], w' "$U"
ID=$R/rbd/muse/runs/mx-T9-R/i1
check "raw logs archived beside OUT, not in it (events.jsonl, session.jsonl, stderr.tail, prompt.md, done)" bash -c "
  [ -s '$ID/events.jsonl' ] && [ -s '$ID/session.jsonl' ] && [ -s '$ID/stderr.tail' ] && [ -s '$ID/prompt.md' ] && [ -s '$ID/done' ] &&
  [ ! -e '$O/events.jsonl' ] && [ -d '$R/rbd/muse/runs/mx-T9-R/base/maze/app' ] && [ -s '$R/rbd/muse/runs/mx-T9-R/run.json' ]"
check "the last stdout line: {step muse-task, ok, out, session_rc, ...}" python3 -I -c '
import json, sys
l = json.loads(open(sys.argv[1]).read().strip().splitlines()[-1])
assert l["step"] == "muse-task" and l["ok"] is True and l["out"].endswith("/rbd/agent/mx-T9-R-i1") and l["stop_blocked"] == 1, l' "$T/o"
WR=$R/home/muser/ws/mx-t9-r
check "the work is committed in the workspace (2 commits, clean tree), the opt-in file in the baseline" bash -c "
  [ \"\$(git -C '$WR' rev-list --count HEAD)\" = 2 ] && [ -z \"\$(git -C '$WR' status --porcelain)\" ] &&
  git -C '$WR' show HEAD~1:.rhobound/muse.json > /dev/null"
check "run.sh got: user muser, the workspace, the step cap 150" grep -q "^muser $WR .*/mx-T9-R/i1/prompt.md $R/home/muser/runs/mx-T9-R-i1 150\$" "$FAKE_LOG"

echo "== task.sh: arm C, iteration 1 (same ticket, same agent)"
rt hello C T9 1 mx-T9-C
check "exit 0: $RC" test "$RC" = 0
OC=$ag/mx-T9-C-i1
check "the same prompt for both arms (byte for byte)" cmp -s "$ID/prompt.md" "$R/rbd/muse/runs/mx-T9-C/i1/prompt.md"
check "the prompt is task.md" cmp -s "$ID/prompt.md" "$R/opt-muse/tickets/T9/task.md"
check "arm C: no MCP offered or called, no hook record, no preview, no opt-in file" bash -c "
  [ '$(j "$OC/usage.json" mcp_calls)' = '[]' ] && [ '$(j "$OC/usage.json" mcp_offered)' = '[]' ] &&
  [ '$(j "$OC/usage.json" hooks.records)' = '[]' ] && [ '$(j "$OC/usage.json" previews_new)' = 0 ] &&
  [ '$(j "$OC/usage.json" hooks.stop_blocked)' = 0 ] && [ ! -e '$R/home/musec/ws/mx-t9-c/.rhobound' ]"
check "arm C: same files, title with its arm" bash -c "
  cmp -s '$O/files/$CAT/hello.go' '$OC/files/$CAT/hello.go' && [ \"\$(cat '$OC/title.txt')\" = '[muse-C i1] T9: Catalog greets its callers' ]"

echo "== task.sh: iteration 2 (feedback; the workspace carries on)"
rt comment R T9 2 mx-T9-R "$FB"
check "exit 0: $RC" test "$RC" = 0
O2=$ag/mx-T9-R-i2
check "the prompt: task.md, the fixed lead line, the feedback" python3 -I - "$R/rbd/muse/runs/mx-T9-R/i2/prompt.md" \
  "$R/opt-muse/tickets/T9/task.md" "$FB" "$KIT/tools1/muse/export.py" << 'PY'
import importlib.util, sys
sys.dont_write_bytecode = True
s = importlib.util.spec_from_file_location("x", sys.argv[4]); x = importlib.util.module_from_spec(s); s.loader.exec_module(x)
p, t, f = (open(a).read() for a in sys.argv[1:4])
assert p == t.rstrip("\n") + "\n\n---\n\n" + x.LEAD + "\n\n" + f.rstrip("\n") + "\n", p
PY
check "OUT i2: the cumulative change (iteration 1's hello.go and iteration 2's catalog.go)" bash -c "
  [ \"\$(cd '$O2/files' && find . -type f | sort | tr '\n' ' ')\" = './$CAT/catalog.go ./$CAT/hello.go ' ] &&
  [ \"\$(git -C '$WR' rev-list --count HEAD)\" = 3 ] && [ '$(j "$O2/manifest.json" base_sha)' = '$MAIN' ]"
check "title of iteration 2" test "$(cat "$O2/title.txt")" = "[muse-R i2] T9: Catalog greets its callers"
rt comment C T9 2 mx-T9-C "$FB"
check "arm C iteration 2: exit 0 and the same prompt as arm R's" bash -c "[ $RC = 0 ] && cmp -s '$R/rbd/muse/runs/mx-T9-R/i2/prompt.md' '$R/rbd/muse/runs/mx-T9-C/i2/prompt.md'"

echo "== task.sh: refusals before anything runs (exit 2, 4)"
n0=$(wc -l < "$FAKE_LOG")
rt hello R T9 2 mx-T9-R "$FB"; check "iteration 2 again: exit 2 ($(tail -c 120 "$T/e"))" test "$RC" = 2
rt hello R T9 3 mx-T9-R; check "iteration 3 without feedback: exit 2" test "$RC" = 2
rt hello C T9 3 mx-T9-R "$FB"; check "iteration 3 of an R run as arm C: exit 2" bash -c "[ $RC = 2 ] && grep -q 'another arm' '$T/e'"
rt hello R T9 4 mx-T9-R "$FB"; check "iteration 4 (max 3): exit 2" test "$RC" = 2
rt hello R T9 2 mx-new "$FB"; check "iteration 2 of a run that never started: exit 2" test "$RC" = 2
rt hello R T9 1 mx-fb "$FB"; check "iteration 1 with feedback: exit 2" test "$RC" = 2
rt hello R T9 1 mx-T9-R; check "iteration 1 of a run that exists: exit 2" test "$RC" = 2
rt hello X T9 1 mx-x; check "arm X: exit 2" test "$RC" = 2
rt hello R T9 1 'mx/../x'; check "a run name with a slash: exit 2" test "$RC" = 2
rt hello R NOPE 1 mx-nope; check "an unknown ticket: exit 2" test "$RC" = 2
MUSE_STEPS=abc rt hello R T9 1 mx-steps; check "MUSE_STEPS abc: exit 2" test "$RC" = 2
MUSE_STEPS=60 rt hello R T9 3 mx-T9-R "$FB"; check "iteration 3 with another step cap than iteration 1's: exit 2" bash -c "[ $RC = 2 ] && grep -q 'step cap 150' '$T/e'"
mkdir -p "$R/rbd/muse/locks"
flock "$R/rbd/muse/locks/muser.lock" sleep 4 &
lp=$!
python3 -I -c 'import time; time.sleep(0.5)'
rt hello R T9 1 mx-busy; check "the user's lock is held: exit 4" test "$RC" = 4
rt hello C T9 1 mx-free; check "...the other arm's user is free: exit 0" test "$RC" = 0
wait "$lp"
check "none of those ran a session but the free one" test "$(($(wc -l < "$FAKE_LOG") - n0))" = 1

echo "== task.sh: changes that cannot be carried (exit 1, result.json says why)"
refused() {   # refused AGENT RUN PATTERN: exit 1, result.json ok false with PATTERN in its error(s), no files/ in OUT
  rt "$1" R T9 1 "$2"
  local o=$ag/$2-i1
  check "$1: exit 1, $(j "$o/result.json" error | head -c 110)" bash -c "
    [ $RC = 1 ] && [ '$(j "$o/result.json" ok)' = false ] && grep -q -- '$3' '$o/result.json' && [ ! -e '$o/files' ] &&
    [ ! -e '$o/manifest.json' ] && [ -s '$o/usage.json' ] && [ -e '$R/rbd/muse/runs/$2/i1/done' ]"
}
refused none mx-none "no change under maze/app"
refused nine mx-nine "9 .go files changed (at most 8)"
refused delete mx-del "deletes maze/app/internal/svc/catalog/catalog_test.go"
refused link mx-link "link or special file where a .go file is expected: maze/app/internal/svc/catalog/alias.go"
refused linkdir mx-ldir "deletes"
check "...the linked folder was never read (its file is nowhere in OUT or the run's records)" bash -c "
  ! grep -rq SECRET-OUTSIDE '$ag/mx-ldir-i1' '$R/rbd/muse/runs/mx-ldir'"
refused big mx-big "bytes (at most 100000)"
refused tag mx-tag "build constraint lines differ"
refused n12 mx-n12 "12-digit number"
rt gomod R T9 1 mx-gomod
check "go.mod edited beside a .go change: exit 0, carried without it, a warning says so" bash -c "
  [ $RC = 0 ] && grep -q 'maze/app/go.mod changed in the workspace but is not carried' '$ag/mx-gomod-i1/result.json' &&
  [ ! -e '$ag/mx-gomod-i1/files/maze/app/go.mod' ]"
t0=$(date +%s)
rt fifo R T9 1 mx-fifo
check "fifos in the workspace: not opened, not carried (exit 0 in $(($(date +%s) - t0)) s)" bash -c "
  [ $RC = 0 ] && [ $(($(date +%s) - t0)) -lt 60 ] && grep -q 'maze/app/pipe' '$ag/mx-fifo-i1/usage.json'"
rt gitevil R T9 1 mx-evil
check "the agent's git hook, clean filter and fsmonitor never run when task.sh commits; the commit is made" bash -c "
  [ $RC = 0 ] && [ ! -e '$T/hook-ran' ] && [ ! -e '$T/filter-ran' ] && [ ! -e '$T/fsmonitor-ran' ] &&
  [ \"\$(git -C '$R/home/muser/ws/mx-evil' rev-list --count HEAD)\" = 2 ]"
FAKE_RC=1 rt hello R T9 1 mx-cap
check "the session hit its step cap (exit 1): the work is still exported, session_rc 1" bash -c "
  [ $RC = 0 ] && [ '$(j "$ag/mx-cap-i1/result.json" session_rc)' = 1 ] && [ '$(j "$ag/mx-cap-i1/usage.json" session.rc)' = 1 ]"
rt twoimg R T9 1 mx-two
check "a change that also touches pricing's code: carried for catalog; warnings name pricing's image and the ticket's folder" bash -c "
  [ $RC = 0 ] && grep -q 'also touches internal/svc/pricing, which is not image catalog' '$ag/mx-two-i1/result.json' &&
  grep -q 'asks for changes only under maze/app/internal/svc/catalog/' '$ag/mx-two-i1/result.json'"
rt notify R T8 1 mx-T8-R
check "a change for events (image notify, with audit): rhobound-change.json v2 [events, audit]" bash -c "
  [ $RC = 0 ] && [ '$(j "$ag/mx-T8-R-i1/rhobound-change.json" schema)' = rbd.change-request/v2 ] &&
  [ '$(j "$ag/mx-T8-R-i1/rhobound-change.json" services)' = '[\"events\", \"audit\"]' ]"
check "no stub was called (sudo, pkill, ssh, aws, docker, kubectl, setpriv, unshare)" test ! -e "$T/forbidden.log"

echo "== orch/agent_take.sh takes task.sh's OUT (the contract; one compile through capped.sh)"
# a copy of the kit under the scratch folder (agent_take compiles the change there)
mkdir -p "$SCR"
K=$(mktemp -d "$SCR/muse-kit-test.XXXXXX")
trap 'rm -rf "$K"' EXIT
mkdir -p "$K/orch" "$K/changes" "$K/state" "$K/tools1/maze"
cp "$KIT/orch/agent_take.sh" "$KIT/orch/capped.sh" "$K/orch/"
cp -r "$KIT/repo" "$K/repo"
rm -rf "$K/repo/.git"
printf '%s\n' "$MAIN" > "$K/state/main.sha"
cp "$KIT/tools1/maze/bases.json" "$K/tools1/maze/" 2> /dev/null || true
take() { RC=0; RBD_AGENT_LOCAL=$1 timeout 900 bash "$K/orch/agent_take.sh" "$(basename "$1")" "$2" > "$T/take.out" 2> "$T/take.err" || RC=$?; }
SKIPS=""
if (( $(df -Pm "$K" | awk 'NR==2 {print $4}') < 4100 )); then   # agent_take refuses to compile under 4 GB free
  echo "  SKIP agent_take's two compiles: less than 4.1 GB free on this machine (free space and rerun)"; SKIPS=2
else
  take "$ag/mx-T9-R-i2" c9-model
  check "agent_take: arm R iteration 2 (2 files, v1) taken and compiled (exit $RC) $(grep -m1 'error' "$T/take.err" | head -c 200)" test "$RC" = 0
  check "...changes/c9-model: change.patch, title.txt as task.sh wrote it, the v1 request" bash -c "
    [ -s '$K/changes/c9-model/change.patch' ] && cmp -s '$K/changes/c9-model/title.txt' '$ag/mx-T9-R-i2/title.txt' &&
    cmp -s '$K/changes/c9-model/rhobound-change.json' '$ag/mx-T9-R-i2/rhobound-change.json'"
  take "$ag/mx-T8-R-i1" c8-model
  check "agent_take: the v2 request (events, audit) taken and compiled (exit $RC) $(grep -m1 'error' "$T/take.err" | head -c 200)" test "$RC" = 0
fi
take "$ag/mx-none-i1" c7-model
check "agent_take: an ok:false OUT is refused before any compile (exit $RC)" bash -c "[ $RC = 1 ] && grep -q 'did not submit' '$T/take.err'"
rm -rf "$K"
trap - EXIT

echo "== hidden.sh: the ticket's hidden tests on a copy (go test, offline)"
CAPPED=$KIT/orch/capped.sh
export MUSE_TEST_GOMODCACHE MUSE_TEST_GOCACHE=$SCR/gocache-hidden
MUSE_TEST_GOMODCACHE=$(go env GOMODCACHE)
mkdir -p "$MUSE_TEST_GOCACHE"
[ ! -f "$CAPPED" ] || export MUSE_TEST_WRAP="env RB_MEM_MAX=3G bash $CAPPED"
hd() { RC=0; timeout 900 bash "$HIDDEN" "$@" > "$T/ho" 2> "$T/he" || RC=$?; HJ=$(tail -n 1 "$T/ho"); }
hj() { python3 -I -c 'import json,sys; d=json.loads(sys.argv[1]); print(json.dumps(d.get(sys.argv[2])))' "$HJ" "$1"; }
hd R T9 mx-T9-R 1
check "arm R i1 (Hello returns hi): pass, exit 0, the 2 hidden tests and the package's own 1 ($RC)" bash -c "
  [ $RC = 0 ] && [ '$(hj pass)' = true ] && [ '$(hj passed)' = 3 ] && [ '$(hj missing)' = '[]' ]"
check "...hidden.json in the run's records = the stdout line; expected both hidden tests; the copy is gone" bash -c "
  python3 -I -c 'import json,sys; assert json.load(open(sys.argv[1])) == json.loads(sys.argv[2])' '$R/rbd/muse/runs/mx-T9-R/i1/hidden.json' '$HJ' &&
  [ '$(hj expected)' = '[\"TestHiddenHello\", \"TestHiddenSearchUnchanged\"]' ] && [ -z \"\$(ls '$R/vartmp')\" ]"
check "...the hidden test never reached a workspace" bash -c "! find '$R/home' -name zz_hidden_test.go | grep -q ."
rt ho R T9 1 mx-ho
hd R T9 mx-ho 1
check "Hello returns ho: fail, exit 1, failed [TestHiddenHello], its message in the tail" bash -c "
  [ $RC = 1 ] && [ '$(hj failed)' = '[\"TestHiddenHello\"]' ] && [ '$(hj error)' = null ] && grep -q 'want' <<< '$(hj output_tail)'"
rt comment C T9 1 mx-noh
hd C T9 mx-noh 1
check "a change without Hello: the hidden tests do not compile: fail, exit 1, build_failed" bash -c "
  [ $RC = 1 ] && [ '$(hj build_failed)' = true ] && [ '$(hj pass)' = false ]"
rt hello R T7 1 mx-T7
hd R T7 mx-T7 1
check "the wrong build tag (no hidden test ran): exit 3, error, not a test failure" bash -c "
  [ $RC = 3 ] && [ '$(hj error)' != null ] && [ '$(hj failed)' = '[]' ]"
hd R T9 mx-none 1
check "an iteration with no exported change: exit 2, no hidden.json" bash -c "[ $RC = 2 ] && [ ! -e '$R/rbd/muse/runs/mx-none/i1/hidden.json' ]"
hd C T9 mx-T9-R 1
check "the wrong arm for the run: exit 2" test "$RC" = 2
check "no copy left behind, no stub called" bash -c "[ -z \"\$(ls '$R/vartmp')\" ] && [ ! -e '$T/forbidden.log' ]"

echo "== the tickets lane's T4 and T5 (when present): each ref patch as the agent -> task.sh -> hidden.sh"
TK=$KIT/tools1/muse/tickets
if [ -f "$TK/T4/refs/good.patch" ] && [ -f "$TK/T5/refs/good.patch" ]; then
  for t in T4 T5; do rm -rf "$R/opt-muse/tickets/$t"; cp -r "$TK/$t" "$R/opt-muse/tickets/$t"; done
  for t in T4 T5; do
    for ref in naive good; do
      printf 'git apply "%s"\n' "$TK/$t/refs/$ref.patch" > "$A/ref-$t-$ref.sh"
      run=mx-$t-$ref
      rt "ref-$t-$ref" C "$t" 1 "$run"
      check "$t $ref: task.sh exports it (exit $RC, $(j "$ag/$run-i1/result.json" files) file(s), service $(j "$ag/$run-i1/result.json" service))" \
        bash -c "[ $RC = 0 ] && cmp -s '$ag/$run-i1/files/$CAT/catalog.go' <(cd '$R/home/musec/ws/${run,,}' && cat '$CAT/catalog.go')"
      hd C "$t" "$run" 1
      check "$t $ref: the ticket's hidden tests pass on it (exit $RC, $(hj passed) passed, failed $(hj failed))" test "$RC" = 0
    done
  done
  printf 'printf "\\n// a comment\\n" >> %s/catalog.go\n' "$CAT" > "$A/cmt.sh"
  rt cmt C T5 1 mx-T5-cmt
  hd C T5 mx-T5-cmt 1
  check "T5 hidden tests on main's catalog (a comment-only change): fail (exit $RC, build_failed $(hj build_failed), failed $(hj failed))" test "$RC" = 1
else
  echo "  SKIP the tickets lane's T4/T5 are not in tools1/muse/tickets yet"
fi

echo "== export.py unit tests"
if python3 -I "$H/test_export.py" > "$T/unit.txt" 2>&1; then ok "test_export.py: $(tail -n 3 "$T/unit.txt" | head -n 1)"; else bad "test_export.py"; tail -20 "$T/unit.txt"; fi

echo "test_task.sh: $PASS passed, $FAILS failed${SKIPS:+, $SKIPS skipped}"
[ -n "${KEEP:-}" ] && echo "kept $T" || rm -rf "$T"
[ "$FAILS" = 0 ]
