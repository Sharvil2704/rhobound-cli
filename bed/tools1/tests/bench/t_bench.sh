#!/usr/bin/env bash
# t_bench.sh: the bench funnel S0-S6 end to end, offline: tools1/bench/run_task.py on a stand-in task (fixtures/task-tb1:
# a stand-in hot package, hidden tests, four reference patches) with agent.py (--plan, --approach) and judge_loop.py against
# the scripted Meta API (tools1/tests/agent/fakes.py api, routed by prompt_cache_key), a stand-in rhobound-mcp (fakes.py
# mcp), sbx.sh with a docker stand-in (fakebin/docker: runs nothing; go-test text canned per approach, fixtures/canned.json)
# and the REAL rhobound CLI (build/rhobound-arm64 preview on tools1/tests/ci/fixtures/fit.json, repo/policy/gate.json).
# Shows an approach cut at S2, at S4 and at S5, a revise round, 'judge unavailable' twice, and one selected; then
# orch/agent_take.sh takes the selected OUT (rbd.change-request/v2) in a copy of the kit. No network; never runs docker.
#   bash tools1/tests/bench/t_bench.sh          (scratch: $HOME/rbd-dev/tmp/t_bench.*; KEEP_T=1 keeps it)
# shellcheck disable=SC2016  # python snippets are single-quoted on purpose
set -uo pipefail
H=$(cd "$(dirname "$0")" && pwd); DEMO=$(cd "$H/../../.." && pwd)
F=$H/fixtures
export PATH="$H/fakebin:$PATH"
[[ $(command -v docker) == "$H/fakebin/docker" ]] || { echo "t_bench: the docker stand-in is not first on PATH: refused"; exit 1; }
mkdir -p "$HOME"/rbd-dev/tmp; T=$(mktemp -d "$HOME"/rbd-dev/tmp/t_bench.XXXXXX)
PIDS=()
[[ -n ${KEEP_T:-} ]] && echo "T=$T"
cleanup() { local p; for p in "${PIDS[@]}"; do kill "$p" 2> /dev/null; done; [[ -n ${KEEP_T:-} ]] || rm -rf "$T"; }
trap cleanup EXIT
pass=0 fail=0
check() { local d=$1; shift; if "$@" > /dev/null 2>&1; then pass=$((pass + 1)); else fail=$((fail + 1)); echo "FAIL: $d"; fi; }
KEY=sk-meta-test-$RANDOM$RANDOM-secretvalue
MTOK=mcp-token-$RANDOM$RANDOM
NOW=2026-10-22T06:00:00Z   # within the policy's fit age of the fixture fit (as tools1/tests/ci/lib.sh)

# main: day-1 main (frozen fixture, as t_agent.sh: repo/ follows GitHub main) with the stand-in hot package; main.sha
REPO0=$DEMO/tools1/tests/ci/fixtures/repo-day1
mkdir -p "$T/src/main" "$T/stub"; cp -r "$REPO0/kshop" "$T/src/main/kshop"
rm -rf "$T/src/main/kshop/app/internal/hot"; mkdir -p "$T/src/main/kshop/app/internal/hot"
cp "$F/hot/rank.go" "$F/hot/rank_test.go" "$T/src/main/kshop/app/internal/hot/"
printf '%040d\n' 9 > "$T/src/main.sha"
printf '%s' "$MTOK" > "$T/mcp-token"

python3 -I - "$T/script.json" "$F/hot/rank.go" << 'PY'
import json, sys
out, rank = sys.argv[1], open(sys.argv[2]).read()
P = "kshop/app/internal/hot/rank.go"
def src(tag):
    return rank.replace("// canned: main", "// canned: " + tag)
def cc(calls=(), content=None, fin="tool_calls", model="muse-spark-1.3"):
    m = {"role": "assistant", "content": content}
    if calls:
        m["tool_calls"] = [{"id": "call_%d" % i, "type": "function", "function": {"name": n, "arguments": json.dumps(a)}}
                           for i, (n, a) in enumerate(calls, 1)]
    return {"id": "c", "object": "chat.completion", "created": 1, "model": model,
            "choices": [{"index": 0, "message": m, "finish_reason": fin if calls else "stop"}],
            "usage": {"prompt_tokens": 1000, "completion_tokens": 100}}
def judge(ans):
    return cc(content=json.dumps(ans) if not isinstance(ans, str) else ans, fin="stop", model="muse-wonder-1.0")
def sub(svc="catalog", title="hot: faster Rank", summary="Faster Rank, identical results."):
    return ("submit_change", {"service": svc, "title": title, "summary": summary})
plan = [{"tag": "wrong-fast", "line": "skip the rune decode (fast, maybe wrong)"},
        {"tag": "fanout", "line": "score docs on goroutines"},
        {"tag": "cache", "line": "memoize per query"},
        {"tag": "precompute", "line": "tokenize the catalog once at build"}]
S = {
 "rbd-agent-plan": [cc([("submit_plan", {"strategies": plan})]),
                    cc([("rhobound_context", {"env": "prod"}), ("rhobound_budget", {"fit_id": "fit_abc123", "service": "catalog"})]),
                    cc([("submit_plan", {"strategies": plan})])],
 "rbd-agent-m1-r1": [cc([("write_file", {"path": P, "content": src("m1-wrong")})]), cc([("run_tests", {})]), cc([sub()])],
 "rbd-agent-m2-r1": [cc([("write_file", {"path": P, "content": src("m2-fanout")})]), cc([sub()])],
 "rbd-agent-m3-r1": [cc([("write_file", {"path": P, "content": src("m3-cache")})]), cc([("run_bench", {})]), cc([sub()])],
 "rbd-agent-m4-r1": [cc([("write_file", {"path": "kshop/app/internal/work/x.go", "content": "package work\n"}),
                         ("write_file", {"path": P, "content": src("m4-v1")})]),
                     cc([("run_tests", {})] * 7),
                     cc([sub(svc="pricing")]), cc([sub(title="hot: precompute tokens", summary="Tokens precomputed once.")])],
 "rbd-agent-m4-r2": [cc([("read_file", {"path": P})]), cc([("write_file", {"path": P, "content": src("m4-v2")})]),
                     cc([sub(title="hot: precompute tokens, no per-call allocs", summary="Tokens precomputed once; no allocs.")])],
 "rbd-judge-m3-r1": [judge({"schema": "bench.judge-verdict/v1", "decision": "reject", "rank": 3, "commentary": "special-cases inputs",
                            "issues": [{"code": "test-gaming", "severity": "high", "fix": "Do not key the cache on the benchmark's query."}]})],
 "rbd-judge-m4-r1": [judge({"schema": "bench.judge-verdict/v1", "decision": "revise", "rank": 1, "commentary": "sound",
                            "issues": [{"code": "alloc-heavy", "severity": "medium", "fix": "Reuse the score buffer between calls."}]})],
 "rbd-judge-m4-r2": [judge({"schema": "bench.judge-verdict/v1", "decision": "accept", "rank": 1, "issues": [], "commentary": "good"})],
 "rbd-judge-ref-good-r1": [judge({"schema": "bench.judge-verdict/v1", "decision": "accept", "rank": 1, "issues": [],
                                  "commentary": "about 4.8 ms faster per call"})],
 "rbd-judge-ref-slow-r1": [judge({"schema": "bench.judge-verdict/v1", "decision": "accept", "rank": 1,
                                  "issues": [{"code": "made-up-code", "severity": "low", "fix": "x"}]})],
}
json.dump(S, open(out, "w"))
PY
python3 -I "$DEMO/tools1/tests/agent/fakes.py" mcp "$MTOK" "$T/mcp.port" "$T/mcp.log" & PIDS+=($!)
python3 -I "$DEMO/tools1/tests/agent/fakes.py" api "$T/script.json" "$T/api.port" "$T/api.log" & PIDS+=($!)
for _ in $(seq 1 50); do [[ -s $T/api.port && -s $T/mcp.port ]] && break; sleep 0.1; done
API=http://127.0.0.1:$(cat "$T/api.port")/v1/chat/completions

benv=(env -u ANTHROPIC_API_KEY RBD_AGENT_PROVIDER=meta RBD_AGENT_API_URL="$API" JUDGE_API_URL="$API"
  RBD_MCP_URL="http://127.0.0.1:$(cat "$T/mcp.port")/mcp" RBD_MCP_TOKEN_FILE="$T/mcp-token"
  RBD_AGENT_KEY_CMD="printf '%s\n' $KEY" JUDGE_KEY_CMD="printf '%s\n' $KEY" RBD_REPO=o/r RBD_HOME="$T/home"
  SBX_DOCKER="$H/fakebin/docker" STUB_DIR="$T/stub" STUB_CANNED="$F/canned.json" SBX_DOCKERFILE="$DEMO/tools1/kshop/Dockerfile"
  SBX_LOCK="$T/home/bench.lock" RBD_CLI="$DEMO/build/rhobound-arm64" RBD_BENCH_NOW="$NOW")
"${benv[@]}" python3 -I "$DEMO/tools1/bench/run_task.py" "$F/task-tb1" "$T/out" --src "$T/src/main" \
  --fit "$DEMO/tools1/tests/ci/fixtures/fit.json" --policy "$DEMO/repo/policy/gate.json" > "$T/run.out" 2> "$T/run.err"; rc=$?
[[ $rc -eq 0 ]] || tail -n 30 "$T/run.err"
O=$T/out
check "run_task: exit 0, last line ok, m4 selected" python3 -I -c '
import json,sys; d=json.loads(open(sys.argv[1]).read().splitlines()[-1]); assert d["ok"] and d["selected"]=="m4", d' "$T/run.out"
check "funnel.json: the shared schema's fields, 4 model rows (plan order) + 4 reference rows, timings S0..S6" python3 -I -c '
import json,sys; f=json.load(open(sys.argv[1]))
assert {"task","started_at","finished_at","base_sha","coder","judge","k","approaches","selected","timings"} <= set(f), sorted(f)
assert f["schema"]=="rbd.bench-funnel/v1" and f["task"]=="tb1" and f["k"]==4 and f["base_sha"]=="0"*39+"9"
assert f["coder"]=="muse-spark-1.3" and f["judge"]=="muse-wonder-1.0", (f["coder"], f["judge"])
A=f["approaches"]; ids=[a["id"] for a in A]
assert ids==["m1","m2","m3","m4","ref-good","ref-wrong","ref-latency-bad","ref-slow"], ids
for a in A:
    assert {"id","origin","strategy","stage_reached","cut","s1","s2","s3","s4","s5","selected"} <= set(a), a
assert A[3]["strategy"].startswith("precompute: ") and [a["origin"] for a in A]==["model"]*4+["reference"]*4
assert sorted(f["timings"])==["S0","S1","S2","S3","S4","S5","S6"] and f["timings"]["S1"]>0 and f["timings"]["S0"]>0' "$O/funnel.json"
row() { python3 -I -c 'import json,sys; print(json.dumps([a for a in json.load(open(sys.argv[1]))["approaches"] if a["id"]==sys.argv[2]][0]))' "$O/funnel.json" "$1"; }
for id in m1 m2 m3 m4 ref-good ref-wrong ref-latency-bad ref-slow; do row "$id" > "$T/row-$id.json"; done
check "m1 (model): cut at S2 by the hidden tests (2 failed), s1 compiled + visible pass" python3 -I -c '
import json,sys; a=json.load(open(sys.argv[1]))
assert a["cut"]["stage"]=="S2" and a["stage_reached"]=="S2" and a["s2"]=={"hidden_pass":False,"failed":2,"passed":3}, a
assert a["s1"]["compiled"] and a["s1"]["visible_pass"] and a["s1"]["turns"]==3 and a["s1"]["tokens"]==3300 and a["s3"] is None' "$T/row-m1.json"
check "m2 (model, +20 ms/call): cut at S4 by the real preview (block, saturates), declared catalog {16, 40}" python3 -I -c '
import json,sys; a=json.load(open(sys.argv[1]))
assert a["cut"]["stage"]=="S4" and a["s4"]["verdict"]=="block" and a["s4"]["binding_rule"].startswith("saturates"), a["s4"]
d=a["s4"]["declared"]["catalog"]; assert abs(d["lo"]-16)<1e-6 and abs(d["hi"]-40)<1e-6, d
assert abs(a["s3"]["delta_ms"]-20)<1e-6 and a["s3"]["allocs"]==9000 and a["s5"] is None' "$T/row-m2.json"
check "m3 (model): passes S4, cut at S5 by the judge (reject, test-gaming)" python3 -I -c '
import json,sys; a=json.load(open(sys.argv[1]))
assert a["cut"]["stage"]=="S5" and "test-gaming" in a["cut"]["reason"] and a["s5"]["decision"]=="reject", a
assert a["s4"]["verdict"]!="block" and a["s4"]["entries"] and {e["name"] for e in a["s4"]["entries"]}=={"storefront","checkout"}' "$T/row-m3.json"
check "m4 (model): judge revise -> one more round -> accept; selected at S6 on the revision's numbers" python3 -I -c '
import json,sys; a=json.load(open(sys.argv[1]))
assert a["selected"] and a["stage_reached"]=="S6" and a["cut"] is None, a
s=a["s5"]; assert s["decision"]=="accept" and s["revised"] and s["before"]["decision"]=="revise" and s["before"]["issues"][0]["code"]=="alloc-heavy", s
assert abs(a["s3"]["delta_ms"]+5)<1e-6 and a["s4"]["declared"]["catalog"]=={"lo":-10.0,"hi":-4.0}, a["s4"]["declared"]' "$T/row-m4.json"
check "references: wrong cut at S2, latency-bad cut at S4, good and slow survive with 'judge unavailable' (ms figure, unknown code)" python3 -I -c '
import json,sys; R={k: json.load(open(sys.argv[1]+"/row-"+k+".json")) for k in ("ref-good","ref-wrong","ref-latency-bad","ref-slow")}
assert R["ref-wrong"]["cut"]["stage"]=="S2" and R["ref-latency-bad"]["cut"]["stage"]=="S4"
g,s=R["ref-good"]["s5"],R["ref-slow"]["s5"]
assert R["ref-good"]["cut"] is None and g["decision"]=="unavailable" and "time figure" in g["note"], g
assert R["ref-slow"]["cut"] is None and s["decision"]=="unavailable" and "unknown issue code" in s["note"], s
assert not any(r["selected"] for r in R.values()) and all(r["s1"]["turns"]==0 for r in R.values())' "$T"
check "S6: the most sensitive entry is storefront; the order lists only model survivors" python3 -I -c '
import json,sys; f=json.load(open(sys.argv[1])); assert f["select"]["entry"]=="storefront" and f["select"]["order"]==["m4"], f["select"]' "$O/funnel.json"
check "selected/: agent.py OUT format (files/, manifest, change.patch, result.json) with rhobound-change.json v2 {services [catalog]}" python3 -I -c '
import json,sys,hashlib,os; o=sys.argv[1]; m=json.load(open(o+"/manifest.json"))
assert m["schema"]=="rbd.agent-change/v1" and m["task"]=="tb1" and m["revised"] is True and m["service"]=="catalog"
f=m["files"][0]; b=open(o+"/files/"+f["path"],"rb").read(); assert hashlib.sha256(b).hexdigest()==f["sha256"] and b"canned: m4-v2" in b
assert json.load(open(o+"/rhobound-change.json"))=={"schema":"rbd.change-request/v2","services":["catalog"],"summary":m["summary"]}
assert json.load(open(o+"/result.json"))["ok"] and "canned: m4-v2" in open(o+"/change.patch").read()
assert not [n for n in os.listdir(o) if n.startswith("sbx-")]' "$O/selected"
check "the API key and the MCP token appear nowhere in OUT or the logs" bash -c '! grep -rqF "$1" "$3/out" "$3/run.out" "$3/run.err" && ! grep -rqF "$2" "$3/out"' _ "$KEY" "$MTOK" "$T"

# what the models were offered and told (the API log: one JSON per request)
check "S0: plan tools only (list/read/submit_plan/context/budget); submit_plan before context+budget refused" python3 -I -c '
import json,sys; L=[json.loads(l)["body"] for l in open(sys.argv[1])]; P=[b for b in L if b.get("prompt_cache_key")=="rbd-agent-plan"]
n=sorted(t["function"]["name"] for t in P[0]["tools"]); assert n==["list_files","read_file","rhobound_budget","rhobound_context","submit_plan"], n
t=[m for m in P[1]["messages"] if m["role"]=="tool"][0]; assert t["content"].startswith("ERROR: refused: call rhobound_context"), t
assert "Plan exactly 4" in P[0]["messages"][1]["content"]' "$T/api.log"
check "S1: run_tests/run_bench offered; the strategy in the ticket; write outside the writable folder refused; 7th run_tests not run; service outside the task refused" python3 -I -c '
import json,sys; L=[json.loads(l)["body"] for l in open(sys.argv[1])]; B=[b for b in L if b.get("prompt_cache_key")=="rbd-agent-m4-r1"]
n=[t["function"]["name"] for t in B[0]["tools"]]; assert "run_tests" in n and "run_bench" in n, n
assert "precompute: tokenize the catalog once" in B[0]["messages"][1]["content"]
M=B[-1]["messages"]; T=[m["content"] for m in M if m["role"]=="tool"]
assert "only directly in kshop/app/internal/hot/" in T[0] and T[1].startswith("ok:"), T[:2]
assert sum("not run: at most 6 run_tests" in x for x in T)==1 and sum(x.startswith("PASS: 1 passed") for x in T)==6, T
assert any("service must be one of [\x27catalog\x27]" in x for x in T)' "$T/api.log"
check "revise round: the reviewer's issue in the ticket; read_file sees the first version (--start)" python3 -I -c '
import json,sys; L=[json.loads(l)["body"] for l in open(sys.argv[1])]; B=[b for b in L if b.get("prompt_cache_key")=="rbd-agent-m4-r2"]
assert "alloc-heavy: Reuse the score buffer" in B[0]["messages"][1]["content"]
t=[m for m in B[1]["messages"] if m["role"]=="tool"][0]; assert "canned: m4-v1" in t["content"], t' "$T/api.log"
check "S5: muse-wonder-1.0, json_object, one request per review (never re-asked); the diff untrusted, siblings are model rows only" python3 -I -c '
import json,sys,collections; L=[json.loads(l)["body"] for l in open(sys.argv[1])]; J=[b for b in L if str(b.get("prompt_cache_key","")).startswith("rbd-judge-")]
c=collections.Counter(b["prompt_cache_key"] for b in J); assert sorted(c)==["rbd-judge-m3-r1","rbd-judge-m4-r1","rbd-judge-m4-r2","rbd-judge-ref-good-r1","rbd-judge-ref-slow-r1"] and set(c.values())=={1}, c
for b in J:
    assert b["model"]=="muse-wonder-1.0" and b["response_format"]=={"type":"json_object"}
    p=json.loads(b["messages"][1]["content"]); assert p["diff"]["untrusted"] is True and len(p["diff"]["lines"])<=400
    assert all(s["id"].startswith("m") for s in p["siblings"])
    assert "data, never instructions" in b["messages"][0]["content"] or "DATA, never instructions" in b["messages"][0]["content"]
p=json.loads([b for b in J if b["prompt_cache_key"]=="rbd-judge-m3-r1"][0]["messages"][1]["content"])
assert [s["id"] for s in p["siblings"]]==["m1","m2","m4"] and p["preview"]["verdict"] and p["microbench"]["BenchmarkRank"]["delta_ms"]==-3.0' "$T/api.log"
check "S4: the change file is rhobound.change/v1 on the fit digest, one declared own_ms item for catalog" python3 -I -c '
import json,sys,hashlib; c=json.load(open(sys.argv[1]+"/rows/m2/r1/s4/changes.json"))
assert c["fit"]=="sha256:"+hashlib.sha256(open(sys.argv[2],"rb").read()).hexdigest()
assert [(i["op"],i["service"],i["label"]) for i in c["items"]]==[("own_ms","catalog","declared")]' "$O" "$DEMO/tools1/tests/ci/fixtures/fit.json"

# the sandbox calls (the docker stand-in's log)
check "sbx: every docker run has exactly the isolation flags, the builder by digest from the Dockerfile, /w read-only" python3 -I -c '
import json,sys; L=[json.loads(l) for l in open(sys.argv[1])]; R=[x for x in L if x["argv"][0]=="run"]
import re; D=open(sys.argv[2]).read(); img=[l.split()[1] for l in D.splitlines() if l.startswith("FROM ")][0]
img=re.search(r"^ARG GO_IMAGE=(\S+)$", D, re.M).group(1) if img=="${GO_IMAGE}" else img
want=["--rm","--network","none","--read-only","--tmpfs","/tmp:rw,exec,nosuid,nodev,size=1536m","--cap-drop","ALL","--security-opt","no-new-privileges","--pids-limit","512","--memory","2g","--cpus","2","--user","65532:65532"]
assert len(R)>20
for x in R:
    a=x["argv"]; assert a[1]=="--name" and a[3:3+len(want)]==want, a[:24]
    assert x["image"]==img and x["cmd"][:2]==["sh","-c"] and "-v" in a and any(v.endswith(":/w:ro") for v in a)
    assert x["env"]["GOPROXY"]=="off" and x["env"]["GOFLAGS"]=="-mod=mod -buildvcs=false" and x["env"]["GOCACHE"].startswith("/tmp/")
    assert "docker" not in json.dumps(x["env"])' "$T/stub/docker.log" "$DEMO/tools1/kshop/Dockerfile"
check "sbx: hidden mode copies the hidden tests in; tests mode does not; the module has only go.mod + the hot package" python3 -I -c '
import json,sys; L=[json.loads(l) for l in open(sys.argv[1])]; R=[x for x in L if x["argv"][0]=="run" and x["env"].get("SBX_STEP")=="test"]
h=[x for x in R if x["env"]["SBX_MODE"]=="hidden"]; t=[x for x in R if x["env"]["SBX_MODE"]=="tests"]
assert h and t and all("internal/hot/rank_hidden_test.go" in x["cand_files"] for x in h)
assert not any("internal/hot/rank_hidden_test.go" in x["cand_files"] for x in t)
assert all(set(x["cand_files"])<= {"go.mod","internal/hot/rank.go","internal/hot/rank_test.go","internal/hot/rank_hidden_test.go"} for x in R)' "$T/stub/docker.log"
check "sbx: benches never overlap (flock): 7 S3 benches (m2 m3 m4-r1 m4-r2, 3 refs) + 1 run_bench = 8" python3 -I -c '
import json,sys; L=[json.loads(l) for l in open(sys.argv[1])]; R=sorted((x["t0"],x["t1"]) for x in L if x["argv"][0]=="run" and x["env"].get("SBX_STEP")=="run")
assert len(R)==8, len(R)
assert all(R[i][1]<=R[i+1][0] for i in range(len(R)-1)), R' "$T/stub/docker.log"

# sbx.sh alone: a task with a base key builds the candidate with bases.json's image, the baseline with main's
mkdir -p "$T/tb2"; cp -r "$F/task-tb1/hidden" "$T/tb2/"
python3 -I -c 'import json,sys; t=json.load(open(sys.argv[1])); t["base"]="go127"; json.dump(t,open(sys.argv[2],"w"))' "$F/task-tb1/task.json" "$T/tb2/task.json"
G127=golang:1.27.2-bookworm@sha256:$(printf '%064d' 1)
printf '{"go1269": "%s", "go127": {"image": "%s"}}\n' "$(sed -n 's/^FROM \([^ ]*\).*/\1/p' "$DEMO/tools1/kshop/Dockerfile" | head -1)" "$G127" > "$T/bases.json"
cp -r "$T/src/main" "$T/cand"; sed -i 's/canned: main/canned: m4-v2/' "$T/cand/kshop/app/internal/hot/rank.go"
: > "$T/stub/docker.log"
env SBX_DOCKER="$H/fakebin/docker" STUB_DIR="$T/stub" STUB_CANNED="$F/canned.json" SBX_DOCKERFILE="$DEMO/tools1/kshop/Dockerfile" \
  SBX_BASES="$T/bases.json" SBX_LOCK="$T/home/bench.lock" SBX_BASE_TREE="$T/src/main" \
  bash "$DEMO/tools1/bench/sbx.sh" bench "$T/cand" "$T/tb2" "$T/sbx-base" > /dev/null 2>&1; rc=$?
check "sbx: base go127 -> baseline built with main's image, candidate built and run with bases.json's; delta -5 ms" python3 -I -c '
import json,sys; L=[json.loads(l) for l in open(sys.argv[1])]; r=json.load(open(sys.argv[2]))
s=[(x["env"]["SBX_STEP"],x["image"]) for x in L]; g=sys.argv[3]
assert [a for a,_ in s]==["build","build","run"] and s[0][1]!=g and s[1][1]==g and s[2][1]==g, s
assert sys.argv[4]=="0" and r["ok"] and r["bench"]["BenchmarkRank"]["delta_ms"]==-5.0' "$T/stub/docker.log" "$T/sbx-base/result.json" "$G127" "$rc"
env SBX_DOCKER="$H/fakebin/docker" STUB_DIR="$T/stub" STUB_CANNED="$F/canned.json" SBX_DOCKERFILE="$DEMO/tools1/kshop/Dockerfile" \
  SBX_BASES="$T/nosuch.json" bash "$DEMO/tools1/bench/sbx.sh" tests "$T/cand" "$T/tb2" "$T/sbx-nobase" > /dev/null 2>&1; rc=$?
check "sbx: a base key without bases.json is refused (exit 2)" test "$rc" -eq 2
bash "$DEMO/tools1/bench/sbx.sh" run "$T/cand" "$T/tb2" "$T/sbx-x" > /dev/null 2>&1; rc=$?
check "sbx: an unknown MODE is a usage error (exit 2)" test "$rc" -eq 2

# orch/agent_take.sh takes the selected OUT (v2) in a copy of the kit whose repo/ is this main
K=$T/kit; mkdir -p "$K/orch" "$K/changes" "$K/state"; cp "$DEMO/orch/agent_take.sh" "$K/orch/"; cp -r "$T/src/main" "$K/repo"
cp "$T/src/main.sha" "$K/state/main.sha"
RBD_AGENT_LOCAL="$O/selected" bash "$K/orch/agent_take.sh" b1 c7-bench > "$T/take.out" 2> "$T/take.err"; rc=$?
[[ $rc -eq 0 ]] || tail -n 8 "$T/take.err"
check "agent_take: the selected approach is taken as changes/c7-bench (v2 change request kept)" bash -c "[ $rc -eq 0 ] &&
  python3 -I -c 'import json,sys; r=json.load(open(sys.argv[1])); assert r[\"schema\"]==\"rbd.change-request/v2\" and r[\"services\"]==[\"catalog\"]' '$K/changes/c7-bench/rhobound-change.json' &&
  grep -q 'canned: m4-v2' '$K/changes/c7-bench/change.patch'"

echo "== t_bench: $pass passed, $fail failed"
[[ $fail -eq 0 ]]
