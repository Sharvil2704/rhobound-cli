#!/usr/bin/env bash
# test_mcp.sh: tools1/mcp end to end on this box with arm64 builds of the same commit: mcp-setup.sh writes token, tokens.json, config
# and registers the proof's production fit as env prod (files only: RBD_MCP_SYSTEMD=0); the real rhobound-mcp runs `http` with that
# config on a loopback port; orch/mcp_call.py lists the tools and calls context/budget/predict through it with the bearer token.
# Needs the arm64 rhobound-mcp at $HOME/rbd-dev/tmp/partB/arm64/rhobound-mcp (built from this repository).
# shellcheck disable=SC1090,SC1091,SC2012,SC2015,SC2016,SC2088,SC2155  # test code
set -uo pipefail
# shellcheck source=lib.sh
. "$(dirname "$(readlink -f "$0")")/lib.sh"
PROOF=$HOME/rbd-dev/leaf
MCPBIN=${RBD_TEST_MCP:-$HOME/rbd-dev/tmp/partB/arm64/rhobound-mcp}
[ -x "$MCPBIN" ] || { echo "no $MCPBIN" >&2; exit 2; }
PORT=$((20000 + RANDOM % 20000))
mkdir -p "$T/opt/bin" "$T/fit"
cp "$DEMO/build/rhobound-arm64" "$T/opt/bin/rhobound"; cp "$MCPBIN" "$T/opt/bin/rhobound-mcp"
cp "$PROOF/prod/fit/fit.json" "$T/fit/fit.json"
jq -n --arg d "$T/fit" '{schema: "rbd.baseline/v1", services: {}, fit: {dir: $d}}' > "$T/baseline.json"
policy=$DEMO/repo/policy/gate.json; [ -s "$policy" ] || policy=$PROOF/policy.json
export RBD_MCP_DIR=$T/mcp RBD_MCP_BIN=$T/opt/bin RBD_MCP_OWNER=$(id -un) RBD_BASELINE=$T/baseline.json RBD_MCP_SYSTEMD=0
export RBD_MCP_FIT_TTL_H=8760   # the proof fit's window ended 2026-10-22: past the default 168 h
out=$(bash "$DEMO/tools1/mcp/mcp-setup.sh" "$policy" 2>&1); rc=$?
check "mcp-setup.sh (files only) exit 0" [ $rc = 0 ] || echo "$out"
check "token 0600, 43 base64url chars" bash -c "[ \"\$(stat -c %a '$T/mcp/token')\" = 600 ] && grep -Eqx '[A-Za-z0-9_-]{43}' '$T/mcp/token'"
check "tokens.json holds the token's sha256, the repo and an expiry" [ "$(jq -r '.tokens[0] | "\(.sha256) \(.repo) \(.expires | test("^20[0-9-]+T"))"' "$T/mcp/tokens.json")" = "$(tr -d '\n' < "$T/mcp/token" | sha256sum | cut -d' ' -f1) Sharvil2704/rhobound-demo true" ]
check "config: engine sha256 = the binary's" [ "$(jq -r .engine.sha256 "$T/mcp/config.json")" = "$(sha256sum "$T/opt/bin/rhobound" | cut -d' ' -f1)" ]
check "config: env prod (dir store), policy default, state_dir" [ "$(jq -r '"\(.envs.prod.store) \(.policies.default | endswith("policy-default.json")) \(.state_dir)"' "$T/mcp/config.json")" = "dir true $T/mcp/state" ]
fd=$(sha256sum "$T/fit/fit.json" | cut -d' ' -f1)
check "the baseline fit is registered as prod" [ "$(cat "$T/mcp/state/server/baselines/prod.json")" = "{\"fit\":\"sha256:$fd\"}" ]
out2=$(bash "$DEMO/tools1/mcp/mcp-setup.sh" "$policy" 2>&1); check "a second run keeps the token (idempotent)" bash -c "! grep -q 'new token' <<< '$out2'"

"$T/opt/bin/rhobound-mcp" http --config "$T/mcp/config.json" --listen "127.0.0.1:$PORT" --static-tokens "$T/mcp/tokens.json" > "$T/server.log" 2>&1 &
sp=$!
code=""; for _ in $(seq 1 50); do code=$(curl -s -o /dev/null -w '%{http_code}' -m 2 -X POST "http://127.0.0.1:$PORT/mcp" || true); [ "$code" = 401 ] && break; sleep 0.2; done
check "the server answers 401 without a token" [ "$code" = 401 ]
URL=http://127.0.0.1:$PORT/mcp
RBD_MCP_TOKEN=wrong python3 -I "$DEMO/orch/mcp_call.py" --url "$URL" list > /dev/null 2>&1; check "a wrong token is refused (exit 2)" [ $? = 2 ]
TOKEN=$(cat "$T/mcp/token")
tools=$(RBD_MCP_TOKEN=$TOKEN python3 -I "$DEMO/orch/mcp_call.py" --url "$URL" list 2> "$T/list.err" | jq -r '.[].name' | sort | tr '\n' ' ')
check "tools/list: $tools" [ "$tools" = "budget context explain fit_start job_status predict " ]
ctx=$(RBD_MCP_TOKEN=$TOKEN python3 -I "$DEMO/orch/mcp_call.py" --url "$URL" call context '{"env": "prod"}' 2> "$T/ctx.err"); rc=$?
check "context {env: prod} on the registered fit (rc $rc)" [ $rc = 0 ] || { echo "$ctx" | head -20; cat "$T/ctx.err"; }
fid=$(jq -r '.fit_id // empty' <<< "$ctx")
check "context names the entries checkout and storefront" [ "$(jq -r '[.entries[]?.name] | sort | join(" ")' <<< "$ctx")" = "checkout storefront" ]
bud=$(RBD_MCP_TOKEN=$TOKEN python3 -I "$DEMO/orch/mcp_call.py" --url "$URL" call budget "{\"fit_id\": \"$fid\", \"service\": \"auth\"}" 2> "$T/bud.err"); rc=$?
check "budget {fit_id, service auth} (rc $rc)" [ $rc = 0 ] || { echo "$bud" | head -20; }
pr=$(RBD_MCP_TOKEN=$TOKEN python3 -I "$DEMO/orch/mcp_call.py" --url "$URL" call predict '{"env": "prod", "changes": [{"op": "own_ms", "service": "auth", "value": 1}], "repo": "Sharvil2704/rhobound-demo", "branch": "demo"}' 2> "$T/pr.err"); rc=$?
check "predict {env prod, auth +1 ms} (rc $rc): preview $(jq -r '.preview.verdict // "?"' <<< "$pr")" [ $rc = 0 ] || { echo "$pr" | head -20; }
printf '%s\n' "$pr" > "$T/pr.json"
v=$(jq -r '.preview.verdict' "$T/pr.json" 2> /dev/null)
check "a declared change never previews as pass ($v)" bash -c "[ '$v' = block ] || [ '$v' = inconclusive ]"
# entries, or (a summary truncated at its size limit) the preview's mean_change row for checkout
check "checkout's predicted change is positive" [ "$(jq -r '([.entries[] | select(.name == "checkout") | .change_ms] + [.preview.rules[]? | select(.rule == "mean_change" and .entry == "checkout") | .value]) | .[0] > 0' "$T/pr.json" 2> /dev/null)" = true ]
kill "$sp" 2> /dev/null; wait "$sp" 2> /dev/null
check "the token never reached the server log" bash -c "! grep -qF '$TOKEN' '$T/server.log'"
finish
