#!/usr/bin/env bash
# demo.sh: the agent's loop on this repository's sample traces, no AWS, no network, no credentials.
# Builds bin/rhobound and bin/rhobound-mcp, writes a configuration to a temporary folder, starts the server over stdio
# and calls its tools as a coding agent does: fit the traces, read the latency budget, measure an A/B, predict.
#   bash examples/mcp/demo.sh          (from the repository's root; Go 1.25 or later, python3)
set -euo pipefail
cd "$(dirname "$0")/../.."
ROOT=$PWD
go build -o bin/rhobound ./cmd/rhobound
(cd mcp && go build -o ../bin/rhobound-mcp ./cmd/rhobound-mcp)
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
# The sample traces date from 2023: raise the fit's age limit, or every answer is held as fit_stale.
python3 -I - "$ROOT" "$T" <<'EOF'
import hashlib, json, sys
root, t = sys.argv[1:]
policy = json.load(open(f"{root}/examples/mcp/policy.example.json"))
policy["max_fit_age_h"] = 10**6
json.dump(policy, open(f"{t}/policy.json", "w"))
eng = f"{root}/bin/rhobound"
json.dump({
    "schema": "rhobound-mcp.config/v1",
    "engine": {"path": eng, "sha256": hashlib.sha256(open(eng, "rb").read()).hexdigest()},
    "state_dir": f"{t}/state",
    "captures": {"loop": f"{root}/testdata/mcp/loop", "loop-a": f"{root}/testdata/mcp/loop/ab/baseline",
                 "loop-b": f"{root}/testdata/mcp/loop/ab/candidate"},
    "policies": {"default": f"{t}/policy.json"},
    "profile": "default",
}, open(f"{t}/config.json", "w"))
EOF
python3 -I - "$ROOT/bin/rhobound-mcp" "$T/config.json" <<'EOF'
import json, subprocess, sys, time
srv = subprocess.Popen([sys.argv[1], "stdio", "--config", sys.argv[2]], stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                       text=True)
seq = 0

def rpc(method, params, notify=False):
    global seq
    msg = {"jsonrpc": "2.0", "method": method, "params": params}
    if not notify:
        seq += 1
        msg["id"] = seq
    srv.stdin.write(json.dumps(msg) + "\n")
    srv.stdin.flush()
    while not notify:
        r = json.loads(srv.stdout.readline())
        if r.get("id") == seq:
            if "error" in r:
                sys.exit(f"{method}: {r['error']}")
            return r["result"]

def tool(name, args):
    r = rpc("tools/call", {"name": name, "arguments": args})
    if r.get("isError"):
        sys.exit(f"{name}: {r.get('content')}")
    return r["structuredContent"]

def job(args):
    j = tool("fit_start", args)
    jid = j["job_id"]
    while j["state"] == "working":
        time.sleep(0.2)
        j = tool("job_status", {"job_id": jid})
    if j["state"] != "completed":
        sys.exit(f"fit_start: {j}")
    return j

def verdict(p):
    pv = p["preview"]
    held = [r["rule"] for r in pv.get("rules", []) if r.get("effect") in ("block", "inconclusive")]
    e = p["entries"][0]
    band = e["band_ms"]
    return (f"entry {e['name']} {band['lo']:+.2f} .. {band['hi']:+.2f} ms (limit {e['threshold_ms']:.2f} ms) -> "
            f"{pv['verdict']}" + (f" ({', '.join(held)})" if held else ""))

rpc("initialize", {"protocolVersion": "2025-06-18", "capabilities": {}, "clientInfo": {"name": "demo", "version": "1"}})
rpc("notifications/initialized", {}, notify=True)
t0 = time.time()
fit = job({"capture": "loop", "workers": {"a": 1, "b": 2, "c": 1}})["fit_id"]
print(f"1. fit_start  traces of a -> b -> c, 3,099 requests: {fit}")
ctx = tool("context", {"fit_id": fit})
for e in ctx["entries"]:
    print(f"2. context    entry {e['name']}: model {e['model_ms']:.2f} ms, observed {e['observed_ms']:.2f} ms")
b = tool("budget", {"fit_id": fit, "service": "b"})["items"][0]
print(f"3. budget     service b may add {b['safe_value']:.2f} ms per visit (limit reached at {b['max_value']:.2f})")
ab = job({"ab": {"baseline": "loop-a", "candidate": "loop-b"}})
print(f"4. fit_start  A/B of the candidate image of b: {ab['ab_id']}")
print(f"5. predict    the measured A/B: {verdict(tool('predict', {'fit_id': fit, 'measured': [{'ab': ab['ab_id']}]}))}")
big = tool("predict", {"fit_id": fit, "changes": [{"op": "own_ms", "service": "b", "value": 3}]})
print(f"6. predict    b +3 ms, over the budget: {verdict(big)}")
print(f"   {time.time() - t0:.2f} s for the whole loop")
srv.stdin.close()
srv.wait(5)
EOF
