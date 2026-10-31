#!/usr/bin/env bash
# register-fit.sh FIT_JSON [ENV]   make a fit rhobound-mcp's baseline for an environment (default prod), as DEPLOY_AWS.md 14 lays
#   it out: the fit's bytes as state_dir/server/artifacts/<hex> (0600) and state_dir/server/baselines/ENV.json = {"fit":"sha256:<hex>"}.
#   Run as rbd (the server's user). state_dir: RBD_MCP_STATE, default $RBD_HOME/mcp/state (/var/lib/rbd/mcp/state). Exit 0 / 1.
# shellcheck disable=SC2015
set -euo pipefail
FIT=${1:-} ENV=${2:-prod}
STATE=${RBD_MCP_STATE:-${RBD_HOME:-/var/lib/rbd}/mcp/state}
[ -s "$FIT" ] && [[ $ENV =~ ^[a-z0-9-]{1,40}$ ]] || { echo "usage: register-fit.sh FIT_JSON [ENV]" >&2; exit 1; }
[ -d "$STATE" ] || { echo "register-fit: no $STATE (rbd_bootstrap.sh mcp)" >&2; exit 1; }
hex=$(sha256sum -- "$FIT" | cut -d' ' -f1)
install -d -m 0700 "$STATE/server" "$STATE/server/artifacts" "$STATE/server/baselines"
install -m 0600 "$FIT" "$STATE/server/artifacts/$hex.tmp" && mv -f "$STATE/server/artifacts/$hex.tmp" "$STATE/server/artifacts/$hex"
( umask 077; printf '{"fit":"sha256:%s"}' "$hex" > "$STATE/server/baselines/$ENV.json.tmp" ) && mv -f "$STATE/server/baselines/$ENV.json.tmp" "$STATE/server/baselines/$ENV.json"
echo "register-fit: $ENV -> sha256:$hex" >&2
