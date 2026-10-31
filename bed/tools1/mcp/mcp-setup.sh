#!/usr/bin/env bash
# mcp-setup.sh [POLICY_JSON]   (root, on rbd-tools1) rhobound-mcp http as a systemd unit (user rbd) on 127.0.0.1:8765 (SPEC 4).
#   /var/lib/rbd/mcp/: token (0600, made here once; it leaves the machine only into the orchestrator's memory), tokens.json (its
#   sha256: rhobound:read), config.json (rhobound-mcp.config/v1: engine = /opt/rbd/bin/rhobound by sha256, env "prod" whose
#   baseline is the production fit, policy "default" = the repo's policy/gate.json), state/ (the server's store).
#   POLICY_JSON default: /var/lib/rbd/src/main/policy/gate.json (uploaded by rbd_bootstrap.sh images). Idempotent. Exit 0 / 1.
# RBD_MCP_FIT_TTL_H (168). Tests: RBD_MCP_DIR, RBD_MCP_BIN, RBD_MCP_OWNER (default rbd), RBD_BASELINE, RBD_MCP_SYSTEMD=0 (files only, no unit, no root).
# shellcheck disable=SC2015
set -euo pipefail
M=${RBD_MCP_DIR:-/var/lib/rbd/mcp}
BIN=${RBD_MCP_BIN:-/opt/rbd/bin}
OWNER=${RBD_MCP_OWNER:-rbd}
SYSTEMD=${RBD_MCP_SYSTEMD:-1}
BASELINE=${RBD_BASELINE:-/var/lib/rbd/baseline.json}
POLICY=${1:-/var/lib/rbd/src/main/policy/gate.json}
ENGINE=$BIN/rhobound
PORT=${RBD_MCP_PORT:-8765}
DAYS=${RBD_MCP_TOKEN_DAYS:-7}
TTL=${RBD_MCP_FIT_TTL_H:-168}   # hours a baseline fit is used after its window ended (fit.expired after)
HERE=$(dirname "$(readlink -f "$0")")
die() { echo "mcp-setup: $1" >&2; exit 1; }
REPO=Sharvil2704/rhobound-demo
if [ -r /opt/rbd/etc/rbd.env ]; then REPO=$(sed -n 's/^RBD_REPO=//p' /opt/rbd/etc/rbd.env); fi
if [ "$SYSTEMD" = 1 ]; then [ "$(id -u)" = 0 ] || die "run as root"; fi
as_owner() { if [ "$(id -un)" = "$OWNER" ]; then "$@"; else sudo -u "$OWNER" "$@"; fi; }
own() { if [ "$(id -un)" != "$OWNER" ]; then chown "$OWNER:$OWNER" "$@"; fi; }
[ -x "$ENGINE" ] && [ -x "$BIN/rhobound-mcp" ] || die "no $ENGINE or $BIN/rhobound-mcp (rbd_bootstrap.sh tools1)"
[ -s "$POLICY" ] && jq -e '.schema == "rhobound.policy/v1"' "$POLICY" > /dev/null || die "$POLICY is not a rhobound.policy/v1 file"
for d in "$M" "$M/state" "$M/env-prod"; do install -d -m 0700 "$d"; own "$d"; done
if [ ! -s "$M/token" ]; then
  ( umask 077; head -c 32 /dev/urandom | base64 | tr '+/' '-_' | tr -d '=\n' > "$M/token.new" ) && own "$M/token.new" && mv -f "$M/token.new" "$M/token"
  echo "mcp-setup: new token in $M/token"
fi
tsha=$(tr -d '\n' < "$M/token" | sha256sum | cut -d' ' -f1)
exp=$(date -u -d "+$DAYS days" +%Y-%m-%dT%H:%M:%SZ)
( umask 077
  jq -n --arg s "$tsha" --arg r "$REPO" --arg e "$exp" '{tokens: [{sha256: $s, repo: $r, expires: $e}]}' > "$M/tokens.json.new"
  cp "$POLICY" "$M/policy-default.json.new"
  jq -n --arg p "$ENGINE" --arg s "$(sha256sum "$ENGINE" | cut -d' ' -f1)" --arg st "$M/state" --arg env "$M/env-prod" --arg pol "$M/policy-default.json" --argjson ttl "$TTL" \
    '{schema: "rhobound-mcp.config/v1", engine: {path: $p, sha256: $s}, state_dir: $st, envs: {prod: {store: "dir", root: $env}},
      policies: {default: $pol}, profile: "default", fit_ttl_h: $ttl}' > "$M/config.json.new" )
for f in tokens.json policy-default.json config.json; do own "$M/$f.new"; chmod 0600 "$M/$f.new"; mv -f "$M/$f.new" "$M/$f"; done
fit=$(jq -r '.fit.dir // empty' "$BASELINE" 2> /dev/null || true)
if [ -n "$fit" ] && [ -s "$fit/fit.json" ]; then
  as_owner env RBD_MCP_STATE="$M/state" "$HERE/register-fit.sh" "$fit/fit.json" prod
else
  echo "mcp-setup: no production fit yet: refit.sh registers it (context/predict with env prod answer fit.no_baseline until then)"
fi
[ "$SYSTEMD" = 1 ] || { echo "mcp-setup: files written in $M (no unit: RBD_MCP_SYSTEMD=0)"; exit 0; }
install -m 0644 "$HERE/rhobound-mcp.service" /etc/systemd/system/rhobound-mcp.service
systemctl daemon-reload
systemctl enable rhobound-mcp.service > /dev/null 2>&1
systemctl restart rhobound-mcp.service
code=""
for _ in $(seq 1 30); do
  code=$(curl -s -o /dev/null -w '%{http_code}' -m 3 -X POST "http://127.0.0.1:$PORT/mcp" || true)
  [ "$code" = 401 ] && break
  sleep 1
done
[ "$code" = 401 ] || { journalctl -u rhobound-mcp -n 20 --no-pager >&2 || true; die "rhobound-mcp does not answer on 127.0.0.1:$PORT (got ${code:-nothing}, want 401 without a token)"; }
body='{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"rbd-setup","version":"1"}}}'
code=$(curl -s -o /dev/null -w '%{http_code}' -m 10 -X POST "http://127.0.0.1:$PORT/mcp" -H 'Content-Type: application/json' \
  -H 'Accept: application/json, text/event-stream' -H @<(printf 'Authorization: Bearer %s\n' "$(cat "$M/token")") --data "$body" || true)
[ "$code" = 200 ] || die "initialize with the token answered $code (want 200)"
echo "mcp-setup: rhobound-mcp up on 127.0.0.1:$PORT (401 without a token, 200 with it); token expires $exp"
