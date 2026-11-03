#!/usr/bin/env bash
# t_agent.sh: tools1/agent/agent.py against a scripted Messages API and a stand-in rhobound-mcp (fakes.py), then
# orch/agent_take.sh on its output in a copy of the kit (compiles the change with the local Go, offline). No network.
# shellcheck disable=SC2016
set -uo pipefail
H=$(cd "$(dirname "$0")" && pwd); DEMO=$(cd "$H/../../.." && pwd)
REPO0=$DEMO/tools1/tests/ci/fixtures/repo-day1   # day-1 main: the fixtures below edit its lib_v11.go (repo/ follows GitHub main)
SCR=${RBD_SCRATCH:-${TMPDIR:-/tmp}/rbd}; mkdir -p "$SCR"; T=$(mktemp -d "$SCR/t_agent.XXXXXX")
PIDS=()
[[ -n ${KEEP_T:-} ]] && echo "T=$T"
trap 'for p in "${PIDS[@]}"; do kill "$p" 2> /dev/null; done; [[ -n ${KEEP_T:-} ]] || rm -rf "$T"' EXIT
pass=0 fail=0
check() { local d=$1; shift; if "$@" > /dev/null 2>&1; then pass=$((pass + 1)); else fail=$((fail + 1)); echo "FAIL: $d"; fi; }
KEY=sk-ant-test-$RANDOM$RANDOM-secretvalue
MTOK=mcp-token-$RANDOM$RANDOM

mkdir -p "$T/src/main"; cp -r "$REPO0/maze" "$T/src/main/maze"; printf '%040d\n' 7 > "$T/src/main.sha"
printf '%s' "$MTOK" > "$T/mcp-token"
python3 -I "$H/fakes.py" mcp "$MTOK" "$T/mcp.port" "$T/mcp.log" & PIDS+=($!)
for _ in $(seq 1 50); do [[ -s $T/mcp.port ]] && break; sleep 0.1; done

NEWLIB=$(sed -e 's/^func VerifyToken(token string) bool {$/var verified sync.Map\n\nfunc VerifyToken(token string) bool {\n\tif v, ok := verified.Load(token); ok {\n\t\treturn v.(bool)\n\t}/' \
  -e 's/^\treturn err == nil \&\& len(k) == 32 \&\& token != "x"$/\tok := err == nil \&\& len(k) == 32 \&\& token != "x"\n\tverified.Store(token, ok)\n\treturn ok/' \
  -e 's/^\t"crypto\/sha256"$/\t"crypto\/sha256"\n\t"sync"/' "$REPO0/maze/app/internal/work/lib_v11.go")
mkscript() {   # $1 out file, $2 = "good" | "refusal" | "bad-paths" | "meta" | "redirect" | "echo" | "budget"
  python3 -I - "$1" "$2" "$NEWLIB" "http://127.0.0.1:$(cat "$T/mcp.port")/stolen" "$KEY" << 'PY'
import json, sys
out, kind, newlib = sys.argv[1], sys.argv[2], sys.argv[3]
def msg(stop, *blocks, model="claude-opus-5-5"):
    return {"id": "msg", "type": "message", "role": "assistant", "model": model, "stop_reason": stop, "content": list(blocks),
            "usage": {"input_tokens": 1000, "output_tokens": 100, "cache_read_input_tokens": 500}}
def use(i, name, inp):
    return {"type": "tool_use", "id": "toolu_%d" % i, "name": name, "input": inp}
th = {"type": "thinking", "thinking": "", "signature": "sig-opaque"}
if kind == "refusal":
    r = [dict(msg("refusal"), stop_details={"type": "refusal", "category": "cyber"})]
elif kind == "bad-paths":
    r = [msg("tool_use", use(1, "write_file", {"path": "maze/app/../../.github/workflows/x.go", "content": "package x\n"}),
             use(2, "write_file", {"path": "maze/app/go.mod", "content": "module x\n"}),
             use(3, "write_file", {"path": "maze/spec.json", "content": "{}"}),
             use(4, "write_file", {"path": "maze/app/newdir/x.go", "content": "package x\n"})),
         msg("tool_use", use(5, "submit_change", {"service": "auth", "title": "t", "summary": "s"})),
         msg("end_turn", {"type": "text", "text": "I cannot."}),
         msg("end_turn", {"type": "text", "text": "Still no."})]
elif kind == "meta":
    def cc(fin, content=None, calls=(), model="muse-spark-1.3"):
        m = {"role": "assistant", "content": content, "refusal": None, "reasoning_content": "hidden thoughts"}
        if calls:
            m["tool_calls"] = [{"id": "call_%d" % i, "type": "function", "function": {"name": n, "arguments": a if isinstance(a, str) else json.dumps(a)}} for i, n, a in calls]
        return {"id": "chatcmpl", "object": "chat.completion", "created": 1, "model": model, "choices": [{"index": 0, "message": m, "finish_reason": fin}],
                "usage": {"prompt_tokens": 1000, "completion_tokens": 200, "total_tokens": 1200, "completion_tokens_details": {"reasoning_tokens": 150}, "prompt_tokens_details": {"cached_tokens": 800}}}
    r = [{"status": 504, "body": {"error": {"type": "server_error", "code": "gateway_timeout", "message": "too long", "param": None}}},
         {"status": 503, "body": {"error": {"type": "server_error", "code": "service_overloaded", "message": "busy", "param": None}}},
         cc("tool_calls", "Looking at production first.", [(1, "rhobound_context", {"env": "prod"})]),
         cc("tool_calls", None, [(2, "rhobound_budget", {"fit_id": "fit_abc123", "service": "auth"}), (3, "read_file", {"path": "maze/app/internal/work/lib_v11.go"}), (4, "list_files", {})]),
         cc("tool_calls", None, [(5, "write_file", {"path": "maze/app/internal/work/lib_v11.go", "content": newlib})]),
         cc("tool_calls", None, [(6, "rhobound_predict", {"env": "prod", "changes": [{"op": "own_ms", "service": "auth", "value": -1}]}), (7, "read_file", "{not json")]),
         cc("stop", "Done, I think."),
         cc("tool_calls", None, [(9, "submit_change", {"service": "auth", "title": "auth: cache VerifyToken results (AUTH-142)",
                                                         "summary": "Caches the PBKDF2 verification result per token. Expected auth own_ms -1."})])]
elif kind in ("redirect", "echo", "budget"):
    def cc(fin, content=None, calls=()):
        m = {"role": "assistant", "content": content}
        if calls:
            m["tool_calls"] = [{"id": "call_%d" % i, "type": "function", "function": {"name": n, "arguments": json.dumps(a)}} for i, n, a in calls]
        return {"id": "c", "object": "chat.completion", "created": 1, "model": "muse-spark-1.3", "choices": [{"index": 0, "message": m, "finish_reason": fin}], "usage": {}}
    if kind == "redirect":
        r = [{"status": 302, "body": {}, "headers": {"Location": sys.argv[4]}}]
    elif kind == "echo":
        r = [cc("tool_calls", None, [(1, "write_file", {"path": "maze/app/internal/work/lib_v11.go", "content": newlib + "\n// " + sys.argv[5] + "\n"})]),
             cc("tool_calls", None, [(2, "submit_change", {"service": "auth", "title": "t", "summary": "s"})])]
    else:
        r = [cc("tool_calls", None, [(i, "rhobound_predict", {"env": "prod", "changes": []}) for i in range(1, 8)]),
             cc("stop", "done"), cc("stop", "done")]
else:
    r = [{"status": 529, "body": {"type": "error", "error": {"type": "overloaded_error", "message": "busy"}}},
         msg("tool_use", th, {"type": "text", "text": "Looking at production first."}, use(1, "rhobound_context", {"env": "prod"})),
         msg("tool_use", use(2, "rhobound_budget", {"fit_id": "fit_abc123", "service": "auth"}), use(3, "read_file", {"path": "maze/app/internal/work/lib_v11.go"}), use(4, "list_files", {})),
         msg("tool_use", use(5, "write_file", {"path": "maze/app/internal/work/lib_v11.go", "content": newlib})),
         msg("tool_use", use(6, "rhobound_predict", {"env": "prod", "changes": [{"service": "auth", "own_ms": -3}]}), use(7, "fit_start", {"env": "prod"})),
         msg("tool_use", use(8, "submit_change", {"service": "nosuch", "title": "x", "summary": "y"})),
         msg("tool_use", use(9, "submit_change", {"service": "auth", "title": "auth: cache VerifyToken results (AUTH-142)",
                                                  "summary": "Caches the PBKDF2 verification result per token. Expected auth own_ms -3."}))]
json.dump(r, open(out, "w"))
PY
}
runagent() {   # $1 kind, $2 out dir; env from the caller
  mkscript "$T/script-$1.json" "$1"
  rm -f "$T/api-$1.port" "$T/api-$1.log"
  python3 -I "$H/fakes.py" api "$T/script-$1.json" "$T/api-$1.port" "$T/api-$1.log" & PIDS+=($!)
  for _ in $(seq 1 50); do [[ -s $T/api-$1.port && -s $T/mcp.port ]] && break; sleep 0.1; done
  env -u ANTHROPIC_API_KEY RBD_AGENT_PROVIDER="${PROVIDER:-anthropic}" RBD_AGENT_API_URL="http://127.0.0.1:$(cat "$T/api-$1.port")/v1/messages" \
    RBD_MCP_URL="http://127.0.0.1:$(cat "$T/mcp.port")/mcp" RBD_MCP_TOKEN_FILE="$T/mcp-token" \
    RBD_AGENT_KEY_CMD="printf '%s\n' $KEY" RBD_REPO=o/r \
    python3 -I "$DEMO/tools1/agent/agent.py" --out "$2" --src "$T/src/main" > "$T/out-$1.txt" 2> "$T/err-$1.txt"
}

runagent good "$T/run-good"; rc=$?
check "good run: exit 0 (after one 529 retry)" test "$rc" -eq 0
check "good run: last stdout line ok, service auth, 1 file" python3 -I -c 'import json,sys; d=json.loads(open(sys.argv[1]).read().splitlines()[-1]); assert d["ok"] and d["service"]=="auth" and d["files"]==1' "$T/out-good.txt"
check "good run: the key appears in no output, log or request log body" bash -c '! grep -rqF "$1" "$2"/run-good "$2"/out-good.txt "$2"/err-good.txt' _ "$KEY" "$T"
check "good run: the MCP token appears in no output" bash -c '! grep -rqF "$1" "$2"/run-good "$2"/out-good.txt "$2"/err-good.txt' _ "$MTOK" "$T"
check "API request: headers x-api-key, anthropic-version 2026-10-21, the fallback beta" python3 -I -c '
import json,sys
L=[json.loads(l) for l in open(sys.argv[1])]; h=L[1]["headers"]
assert h["x-api-key"]==sys.argv[2] and h["anthropic-version"]=="2026-10-21" and h["anthropic-beta"]=="server-side-fallback-2026-07-01"' "$T/api-good.log" "$KEY"
check "API body: model, effort high, fallbacks default, no sampling params, no thinking param, cache_control" python3 -I -c '
import json,sys
b=json.loads(open(sys.argv[1]).readline())["body"]
assert b["model"]=="claude-opus-5-5" and b["output_config"]=={"effort":"high"} and b["fallbacks"]=="default"
assert not ({"temperature","top_p","top_k","thinking"} & set(b)) and b["cache_control"]=={"type":"ephemeral"}' "$T/api-good.log"
check "API tools: local + rhobound_{context,budget,predict,explain}; no fit_start/job_status; no top-level oneOf/\$schema" python3 -I -c '
import json,sys
b=json.loads(open(sys.argv[1]).readline())["body"]; n=[t["name"] for t in b["tools"]]
assert n[:4]==["list_files","read_file","write_file","submit_change"] and sorted(n[4:])==["rhobound_budget","rhobound_context","rhobound_explain","rhobound_predict"], n
for t in b["tools"]:
    assert not ({"oneOf","anyOf","allOf","$schema"} & set(t["input_schema"])), t
assert "oneOf" in [t for t in b["tools"] if t["name"]=="rhobound_context"][0]["description"]' "$T/api-good.log"
check "history is append-only: request 3 starts with request 2's messages, thinking block passed back unchanged" python3 -I -c '
import json,sys
L=[json.loads(l)["body"] for l in open(sys.argv[1])]
a,b=L[2]["messages"],L[3]["messages"]
assert b[:len(a)]==a
assert a[1]["content"][0]=={"type":"thinking","thinking":"","signature":"sig-opaque"}' "$T/api-good.log"
check "tool results: unknown fit_start is_error; bad service refused; predict got repo/branch injected" python3 -I -c '
import json,sys
L=[json.loads(l)["body"] for l in open(sys.argv[1])]
last=L[-1]["messages"]
res={c["tool_use_id"]:c for m in last if m["role"]=="user" and isinstance(m["content"],list) for c in m["content"] if c.get("type")=="tool_result"}
assert res["toolu_7"]["is_error"] and "unknown tool" in res["toolu_7"]["content"]
assert res["toolu_8"]["is_error"] and "service must be one of" in res["toolu_8"]["content"]
m=[json.loads(l) for l in open(sys.argv[2])]
p=[x["body"]["params"]["arguments"] for x in m if x["body"].get("method")=="tools/call" and x["body"]["params"]["name"]=="predict"][0]
assert p["repo"]=="o/r" and p["branch"]=="rbd/c5-model"
assert all(x["headers"].get("mcp-session-id")=="sess-1" for x in m[1:])' "$T/api-good.log" "$T/mcp.log"
check "OUT: manifest lists lib_v11.go with its sha256; rhobound-change.json for auth; change.patch shows sync.Map" python3 -I -c '
import json,sys,hashlib,os
o=sys.argv[1]; m=json.load(open(o+"/manifest.json"))
f=m["files"][0]; b=open(o+"/files/"+f["path"],"rb").read()
assert f["path"]=="maze/app/internal/work/lib_v11.go" and hashlib.sha256(b).hexdigest()==f["sha256"] and m["base_sha"]=="0"*39+"7"
assert json.load(open(o+"/rhobound-change.json"))["services"]==["auth"]
assert "+var verified sync.Map" in open(o+"/change.patch").read()
assert [c["tool"] for c in m["mcp_calls"]]==["context","budget","predict"]' "$T/run-good"

runagent bad-paths "$T/run-bad"; rc=$?
check "bad paths: exit 1 (nothing submitted)" test "$rc" -eq 1
check "bad paths: traversal, go.mod, spec.json, new folder all refused; submit with no change refused" python3 -I -c '
import json,sys
L=[json.loads(l)["body"] for l in open(sys.argv[1])]
res=[c for m in L[-1]["messages"] if m["role"]=="user" and isinstance(m["content"],list) for c in m["content"] if c.get("type")=="tool_result"]
assert [r["is_error"] for r in res]==[True]*5, res
assert "no file changed" in res[4]["content"]' "$T/api-bad-paths.log"
check "bad paths: no files/ written" test ! -e "$T/run-bad/files"
runagent refusal "$T/run-ref"; rc=$?
check "refusal: exit 1 and result.json says the model declined" bash -c "[ $rc -eq 1 ] && grep -q declined '$T/run-ref/result.json'"
check "a non-empty OUT is refused (exit 2)" bash -c 'python3 -I "$1/tools1/agent/agent.py" --out "$2/run-good" --src "$2/src/main"; [ $? -eq 2 ]' _ "$DEMO" "$T"

PROVIDER=meta runagent meta "$T/run-meta"; rc=$?
check "meta: exit 0 after a 504 (effort lowered) and a 503 retry" test "$rc" -eq 0
check "meta: Bearer auth, no x-api-key, nothing of Anthropic's" python3 -I -c '
import json,sys
for l in open(sys.argv[1]):
    h=json.loads(l)["headers"]
    assert h["authorization"]=="Bearer "+sys.argv[2] and "x-api-key" not in h and "anthropic-version" not in h' "$T/api-meta.log" "$KEY"
check "meta body: muse-spark-1.3, effort high then medium after the 504, tool_choice auto, no sampling params, developer first" python3 -I -c '
import json,sys
B=[json.loads(l)["body"] for l in open(sys.argv[1])]
assert all(b["model"]=="muse-spark-1.3" and b["tool_choice"]=="auto" and b["max_completion_tokens"]==32000 for b in B)
assert B[0]["reasoning_effort"]=="high" and all(b["reasoning_effort"]=="medium" for b in B[1:]), [b["reasoning_effort"] for b in B]
assert not any({"temperature","top_p","max_tokens","stop","n","system","thinking"} & set(b) for b in B)
assert B[0]["messages"][0]["role"]=="developer" and B[0]["prompt_cache_key"]=="rbd-agent-run-meta"' "$T/api-meta.log"
check "meta tools: function format, strict on local tools, no \$ref/\$defs/top-level oneOf left, ref inlined with its description" python3 -I -c '
import json,sys
b=json.loads(open(sys.argv[1]).readline())["body"]; T=b["tools"]
assert all(t["type"]=="function" and set(t["function"])>={"name","description","parameters"} for t in T)
assert [t["function"].get("strict") for t in T[:4]]==[True]*4
s=json.dumps(T); assert "$ref" not in s and "$defs" not in s
ctx=[t for t in T if t["function"]["name"]=="rhobound_context"][0]["function"]
assert "oneOf" not in ctx["parameters"] and "oneOf" in ctx["description"]
assert ctx["parameters"]["properties"]["env"]=={"type":"string","pattern":"^[a-z]+$","description":"an env"}' "$T/api-meta.log"
check "meta history: assistant tool_calls then one tool message per call in order; bad JSON args -> ERROR not run" python3 -I -c '
import json,sys
B=[json.loads(l)["body"] for l in open(sys.argv[1])]; M=B[-1]["messages"]
for i,m in enumerate(M):
    if m["role"]=="assistant" and m.get("tool_calls"):
        ids=[c["id"] for c in m["tool_calls"]]; nxt=M[i+1:i+1+len(ids)]
        assert [x["role"] for x in nxt]==["tool"]*len(ids) and [x["tool_call_id"] for x in nxt]==ids, (ids,nxt)
    assert "reasoning_content" not in m and "refusal" not in m
t7=[m for m in M if m["role"]=="tool" and m["tool_call_id"]=="call_7"][0]
assert t7["content"].startswith("ERROR: not run")
assert any(m["role"]=="user" and "submit_change" in m["content"] for m in M)' "$T/api-meta.log"
check "meta: OUT taken as in the Anthropic run (manifest provider meta, served_by muse-spark-1.3, usage counts reasoning)" python3 -I -c '
import json,sys
m=json.load(open(sys.argv[1]+"/manifest.json"))
assert m["provider"]=="meta" and m["served_by"]==["muse-spark-1.3"] and m["usage"]["reasoning"]==900 and m["service"]=="auth"
assert [c["tool"] for c in m["mcp_calls"]]==["context","budget","predict"]' "$T/run-meta"
check "meta: the key appears in no output" bash -c '! grep -rqF "$1" "$2"/run-meta "$2"/out-meta.txt "$2"/err-meta.txt' _ "$KEY" "$T"

# agent_take.sh in a copy of the kit (it writes changes/c5-model and state/ next to itself)
K=$T/kit; mkdir -p "$K/orch" "$K/changes" "$K/state"; cp "$DEMO/orch/agent_take.sh" "$DEMO/orch/capped.sh" "$K/orch/"; cp -r "$REPO0" "$K/repo"
printf '%040d\n' 7 > "$K/state/main.sha"
RBD_AGENT_LOCAL="$T/run-good" bash "$K/orch/agent_take.sh" r1 > "$T/take.out" 2> "$T/take.err"; rc=$?
check "agent_take: the good run compiles (go build default + maze_v11, go vet) and is taken (exit 0)" test "$rc" -eq 0
check "agent_take: changes/c5-model has change.patch (git apply --check on repo/), rhobound-change.json, title.txt" bash -c '
  c=$1/changes/c5-model; [ -s $c/change.patch ] && [ "$(cat $c/title.txt)" = "auth: cache VerifyToken results (AUTH-142)" ] &&
  d=$(mktemp -d) && cp -r $1/repo/. $d && git -C $d init -q && git -C $d apply --check $c/change.patch; r=$?; rm -rf $d; exit $r' _ "$K"
cp -r "$T/run-good" "$T/run-broken"
printf '//go:build maze_v11\n\npackage work\n\nfunc broken( {\n' > "$T/run-broken/files/maze/app/internal/work/lib_v11.go"
python3 -I -c '
import json,sys,hashlib
o=sys.argv[1]; m=json.load(open(o+"/manifest.json")); b=open(o+"/files/maze/app/internal/work/lib_v11.go","rb").read()
m["files"][0].update(sha256=hashlib.sha256(b).hexdigest(), bytes=len(b)); json.dump(m,open(o+"/manifest.json","w"))' "$T/run-broken"
RBD_AGENT_LOCAL="$T/run-broken" bash "$K/orch/agent_take.sh" r2 > /dev/null 2>&1; rc=$?
check "agent_take: a change that does not compile exits 3 with compile.txt" bash -c "[ $rc -eq 3 ] && grep -q 'syntax error\|expected' '$K/state/agent/r2.compile.txt'"
cp -r "$T/run-good" "$T/run-extra"; echo x > "$T/run-extra/files/maze/app/extra.go"
RBD_AGENT_LOCAL="$T/run-extra" bash "$K/orch/agent_take.sh" r3 > /dev/null 2>&1; rc=$?
check "agent_take: a file not in the manifest is refused (exit 1)" test "$rc" -eq 1
cp -r "$T/run-good" "$T/run-link"; rm "$T/run-link/files/maze/app/internal/work/lib_v11.go"; ln -s /etc/passwd "$T/run-link/files/maze/app/internal/work/lib_v11.go"
RBD_AGENT_LOCAL="$T/run-link" bash "$K/orch/agent_take.sh" r4 > /dev/null 2>&1; rc=$?
check "agent_take: a symlink in files/ is refused (exit 1)" test "$rc" -eq 1
cp -r "$T/run-good" "$T/run-trav"
python3 -I -c '
import json,sys
o=sys.argv[1]; m=json.load(open(o+"/manifest.json")); m["files"][0]["path"]="maze/app/../../.github/x.go"; json.dump(m,open(o+"/manifest.json","w"))' "$T/run-trav"
RBD_AGENT_LOCAL="$T/run-trav" bash "$K/orch/agent_take.sh" r5 > /dev/null 2>&1; rc=$?
check "agent_take: a traversal path in the manifest is refused (exit 1)" test "$rc" -eq 1
cp -r "$T/run-good" "$T/run-leak"
python3 -I -c '
import json,sys
o=sys.argv[1]; m=json.load(open(o+"/manifest.json")); m["summary"]="see 8.8.8.8"; json.dump(m,open(o+"/manifest.json","w"))
r=json.load(open(o+"/rhobound-change.json")); r["summary"]=m["summary"]; json.dump(r,open(o+"/rhobound-change.json","w"))' "$T/run-leak"
RBD_AGENT_LOCAL="$T/run-leak" bash "$K/orch/agent_take.sh" r6 > "$T/leak.out" 2>&1; rc=$?
check "agent_take: a public IPv4 in the summary is refused by the leak scan (exit 1)" test "$rc" -eq 1

mut() {   # $1 name, $2 python editing the copy (argv[1] = the run folder): a manifest/file mutation with sha256 kept right
  rm -rf "$T/run-$1"; cp -r "$T/run-good" "$T/run-$1"
  python3 -I -c "$2
import hashlib, json, sys
o = sys.argv[1]; m = json.load(open(o + '/manifest.json'))
for f in m['files']:
    b = open(o + '/files/' + f['path'], 'rb').read(); f.update(sha256=hashlib.sha256(b).hexdigest(), bytes=len(b))
json.dump(m, open(o + '/manifest.json', 'w'))
r = json.load(open(o + '/rhobound-change.json')); r['summary'] = m['summary']; json.dump(r, open(o + '/rhobound-change.json', 'w'))" "$T/run-$1"
  RBD_AGENT_LOCAL="$T/run-$1" bash "$K/orch/agent_take.sh" "r-$1" > "$T/take-$1.txt" 2>&1
}
cp -r "$T/run-good" "$T/run-plant"; echo "ORIGINAL" > "$T/victim.txt"; ln -s "$T/victim.txt" "$T/run-plant/compile.txt"
RBD_AGENT_LOCAL="$T/run-plant" bash "$K/orch/agent_take.sh" r7 > /dev/null 2>&1; rc=$?
check "agent_take: a symlink anywhere in the run (compile.txt -> a file here) is refused (exit 1) and the target is untouched" bash -c "[ $rc -eq 1 ] && [ \"\$(cat '$T/victim.txt')\" = ORIGINAL ]"
mut skip 'import json, sys
o = sys.argv[1]; m = json.load(open(o + "/manifest.json")); m["title"] = "auth: faster [skip ci]"; json.dump(m, open(o + "/manifest.json", "w"))'
check "agent_take: a [skip ci] title is refused (exit 1)" bash -c "[ $? -eq 1 ] && grep -q CI-skip '$T/take-skip.txt'"
mut base 'import json, sys
o = sys.argv[1]; m = json.load(open(o + "/manifest.json")); m["base_sha"] = "1" * 40; json.dump(m, open(o + "/manifest.json", "w"))'
check "agent_take: a run on another main (base_sha) is refused (exit 1)" bash -c "[ $? -eq 1 ] && grep -q 'worked on' '$T/take-base.txt'"
mut tag 'import sys
p = sys.argv[1] + "/files/maze/app/internal/work/lib_v11.go"; s = open(p).read().replace("//go:build maze_v11", "//go:build maze_v11 && !go1.27"); open(p, "w").write(s)'
check "agent_take: a changed build constraint (//go:build ... !go1.27) is refused (exit 1)" bash -c "[ $? -eq 1 ] && grep -q 'build constraints' '$T/take-tag.txt'"
mut embed 'import sys
p = sys.argv[1] + "/files/maze/app/internal/work/lib_v11.go"; s = open(p).read().replace("package work", "package work\n\n//go:embed lib_v10.go\nvar x string"); open(p, "w").write(s)'
check "agent_take: //go:embed in the change is refused (exit 1)" bash -c "[ $? -eq 1 ] && grep -q 'not allowed' '$T/take-embed.txt'"
rm -rf "$T/run-nores"; cp -r "$T/run-good" "$T/run-nores"; rm "$T/run-nores/result.json"
RBD_AGENT_LOCAL="$T/run-nores" bash "$K/orch/agent_take.sh" r8 > "$T/take-nores.txt" 2>&1; rc=$?
check "agent_take: a crashed run (no result.json) is refused with a clear message (exit 1)" bash -c "[ $rc -eq 1 ] && grep -q 'no result.json' '$T/take-nores.txt'"
check "agent_take: the good run's checked copy is in state/agent/r1 and nothing was written into the fetched run" bash -c "[ -s '$K/state/agent/r1/manifest.json' ] && [ ! -e '$T/run-good/compile.txt' ]"
check "agent.py: a write_file path with a trailing newline is refused" python3 -I -c '
import importlib.util,sys,pathlib
spec=importlib.util.spec_from_file_location("agent", sys.argv[1]); a=importlib.util.module_from_spec(spec); spec.loader.exec_module(a)
w=a.Workspace(pathlib.Path(sys.argv[2]))
t,e=w.write_file({"path":"maze/app/internal/work/x.go\n","content":"package work\n"}); assert e, t
t,e=w.write_file({"path":"maze/app/internal/work/x.go","content":"package work\n\ud800\n"}); assert e and "UTF-8" in t, t' "$DEMO/tools1/agent/agent.py" "$T/src/main"

# round 2 of the review (wf_92dee97f-768): agent.py
PROVIDER=meta runagent redirect "$T/run-redir"; rc=$?
check "agent.py: an API 302 is not followed (exit 1) and the redirect target never sees the key" bash -c "[ $rc -eq 1 ] && grep -q 'HTTP 302' '$T/run-redir/result.json' && ! grep -q stolen '$T/mcp.log'"
PROVIDER=meta runagent echo "$T/run-echo"; rc=$?
check "agent.py: a model output holding the key keeps nothing (exit 1, no files/)" bash -c "[ $rc -eq 1 ] && grep -q 'holds a secret' '$T/run-echo/result.json' && [ ! -e '$T/run-echo/files' ] && ! grep -rqF '$KEY' '$T/run-echo'"
PROVIDER=meta runagent budget "$T/run-budget"; rc=$?
check "agent.py: the 7th MCP call of a turn is not run (budget 6 per turn)" python3 -I -c '
import json,sys
B=[json.loads(l)["body"] for l in open(sys.argv[1])]; M=B[-1]["messages"]
t=[m for m in M if m["role"]=="tool"]
assert len(t)==7 and sum("MCP budget" in m["content"] for m in t)==1, [m["content"][:40] for m in t]' "$T/api-budget.log"
check "agent.py: a 300-character file name is refused by write_file" python3 -I -c '
import importlib.util,sys,pathlib
spec=importlib.util.spec_from_file_location("agent", sys.argv[1]); a=importlib.util.module_from_spec(spec); spec.loader.exec_module(a)
w=a.Workspace(pathlib.Path(sys.argv[2]))
t,e=w.write_file({"path":"maze/app/internal/work/"+"a"*300+".go","content":"package work\n"}); assert e, t
t,e=w.read_file({"path":["x"]}); assert e, t' "$DEMO/tools1/agent/agent.py" "$T/src/main"
# round 2: agent_take
mut bom 'import sys
p = sys.argv[1] + "/files/maze/app/internal/work/lib_v11.go"; s = open(p).read(); open(p, "w").write("\ufeff" + s)'
check "agent_take: a byte-order mark in a changed file is refused (exit 1)" bash -c "[ $? -eq 1 ] && grep -q 'byte-order mark' '$T/take-bom.txt'"
python3 -I - "$T" << 'PY'
import io, json, os, sys, tarfile
T = sys.argv[1]; src = T + "/run-good"
def add_tree(tf, prefix):
    for d, dirs, names in os.walk(src):
        for n in dirs + names:
            p = os.path.join(d, n); tf.add(p, arcname=prefix + "/" + os.path.relpath(p, src), recursive=False)
# 1. the run folder itself mode 0100 with a symlink inside
with tarfile.open(T + "/t-mode.tar", "w") as tf:
    add_tree(tf, "tmode")
    i = tarfile.TarInfo("tmode/compile.txt"); i.type = tarfile.SYMTYPE; i.linkname = T + "/victim.txt"; tf.addfile(i)
    i = tarfile.TarInfo("tmode"); i.type = tarfile.DIRTYPE; i.mode = 0o100; tf.addfile(i)
# 2. a hard link inside the run
with tarfile.open(T + "/t-hard.tar", "w") as tf:
    add_tree(tf, "thard")
    i = tarfile.TarInfo("thard/extra.json"); i.type = tarfile.LNKTYPE; i.linkname = "thard/result.json"; tf.addfile(i)
# 3. a 7 MB file (the stream is over the cap)
with tarfile.open(T + "/t-big.tar", "w") as tf:
    add_tree(tf, "tbig")
    i = tarfile.TarInfo("tbig/big.bin"); i.size = 7_000_000; tf.addfile(i, io.BytesIO(b"\0" * 7_000_000))
PY
for k in mode hard big; do RBD_AGENT_TAR="$T/t-$k.tar" bash "$K/orch/agent_take.sh" "t$k" > "$T/take-t$k.txt" 2>&1; echo $? > "$T/take-t$k.rc"; done
check "agent_take: a run folder of mode 0100 with a symlink inside is refused (exit 1), the target untouched" bash -c "[ \$(cat '$T/take-tmode.rc') -eq 1 ] && grep -q 'link, device' '$T/take-tmode.txt' && [ \"\$(cat '$T/victim.txt')\" = ORIGINAL ]"
check "agent_take: a hard link in the run is refused (exit 1)" bash -c "[ \$(cat '$T/take-thard.rc') -eq 1 ] && grep -q 'hard link' '$T/take-thard.txt'"
check "agent_take: a tar stream over 6 MB is refused before unpacking (exit 1)" bash -c "[ \$(cat '$T/take-tbig.rc') -eq 1 ] && grep -q 'before unpacking' '$T/take-tbig.txt'"
mut giant 'import sys
p = sys.argv[1] + "/files/maze/app/internal/work/lib_v11.go"; s = open(p).read(); open(p, "w").write(s + "\nvar giant = [300 << 20]byte{300<<20 - 1: 1}\n")'
check "agent_take: a 300 MB array fails the capped compile (exit 3: the 256 MB file cap), the build cache stays small" bash -c "[ $? -eq 3 ] && [ \$(du -sm '$SCR/agent-gocache' | cut -f1) -lt 1500 ]"
mut esc 'import json, sys
o = sys.argv[1]; r = json.load(open(o + "/result.json")); r["ok"] = False; r["error"] = "x\x1b]0;PWNED\x07\x1b[2J"; json.dump(r, open(o + "/result.json", "w"))'
check "agent_take: control characters from result.json are printed escaped" bash -c "! grep -q \$'\\x1b' '$T/take-esc.txt' && grep -q 'x1b' '$T/take-esc.txt'"

# SPEC2 4: rhobound-change.json v2 (the bench's runs: several services, an optional base key of tools1/maze/bases.json)
v2() {   # $1 name, $2 a python dict literal merged into a v2 change request of the run (services/base/extra fields)
  mut "$1" "import json, sys
o = sys.argv[1]; m = json.load(open(o + '/manifest.json'))
json.dump(dict({'schema': 'rbd.change-request/v2', 'services': ['auth', 'inventory'], 'summary': m['summary']}, **$2), open(o + '/rhobound-change.json', 'w'))"
}
v2 v2good '{}'
check "agent_take v2: services [auth, inventory] (the manifest's auth first) is taken (exit 0), the v2 file kept" bash -c "[ $? -eq 0 ] && grep -q 'change-request/v2' '$K/changes/c5-model/rhobound-change.json'"
v2 v2nobases "{'base': 'go127'}"
check "agent_take v2: a base key while the kit has no tools1/maze/bases.json is refused (exit 1)" bash -c "[ $? -eq 1 ] && grep -q 'no tools1/maze/bases.json' '$T/take-v2nobases.txt'"
mkdir -p "$K/tools1/maze"; printf '{"go1269": "golang:1.26.9-bookworm@sha256:%064d", "go127": "golang:1.27.2-bookworm@sha256:%064d"}\n' 1 2 > "$K/tools1/maze/bases.json"
v2 v2base "{'base': 'go127'}"
check "agent_take v2: base go127 (a key of bases.json) is taken (exit 0)" test $? -eq 0
v2 v2badbase "{'base': 'go999'}"
check "agent_take v2: an unknown base key is refused (exit 1)" bash -c "[ $? -eq 1 ] && grep -q 'not a key of tools1/maze/bases.json' '$T/take-v2badbase.txt'"
v2 v2svc "{'services': ['inventory']}"
check "agent_take v2: services without the manifest's service are refused (exit 1)" bash -c "[ $? -eq 1 ] && grep -q 'the first the manifest' '$T/take-v2svc.txt'"
v2 v2many "{'services': ['auth', 'inventory', 'cart', 'pricing']}"
check "agent_take v2: four services are refused (exit 1)" test $? -eq 1
v2 v2extra "{'dockerfile': 'FROM scratch'}"
check "agent_take v2: an unknown field (a Dockerfile) is refused (exit 1)" bash -c "[ $? -eq 1 ] && grep -q 'v2 is {schema' '$T/take-v2extra.txt'"
RBD_AGENT_LOCAL="$T/run-good" bash "$K/orch/agent_take.sh" r9 c7-other > "$T/take-name.txt" 2>&1; rc=$?
check "agent_take: CHANGE must be cN-model or cN-bench (c7-other refused, exit 1)" bash -c "[ $rc -eq 1 ] && grep -q 'cN-bench' '$T/take-name.txt'"

echo "== t_agent: $pass passed, $fail failed"
[[ $fail -eq 0 ]]
