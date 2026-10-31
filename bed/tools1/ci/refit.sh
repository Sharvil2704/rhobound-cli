#!/usr/bin/env bash
# refit.sh NAME   the production fit (SPEC 6): a 600-s window (capture.sh, seed from NAME) -> rhobound fit --name prod -> baseline.json
#   fit: rhobound fit --manifest captures/NAME/cut/manifest.json --name prod --out captures/NAME/fit --json (the cut check made)
#   baseline.json: fit {dir, digest = "sha256:" + sha256(fit.json)}, capture NAME, updated_at (atomic replace; services kept)
#   Refused when the window's Deployments do not run baseline.json's digests (a fit of another production).
#   Then the fit is registered with rhobound-mcp as environment "prod" (when /var/lib/rbd/mcp/state exists).
# RBD_REFIT_SECONDS overrides the 600 s (tests). Under the cluster lock. Last line {"step":"refit","ok":...}; exit 0 / 1.
# shellcheck disable=SC2015
set -uo pipefail
RBD_OPT=${RBD_OPT:-/opt/rbd}
# shellcheck source=../lib/rbd-env.sh
. "$RBD_OPT/lib/rbd-env.sh"
# shellcheck source=../lib/lock.sh
. "$RBD_OPT/lib/lock.sh"
export RBD_STEP=refit
NAME=${1:-}
fail() { log "ERROR: $1"; rbd_result refit false "$(jq -cn --arg n "$NAME" --arg e "$1" '{name: $n, error: $e}')"; exit 1; }
[ $# = 1 ] && [[ $NAME =~ ^[a-z0-9][a-z0-9._-]{0,62}$ ]] || { echo "usage: refit.sh NAME" >&2; rbd_result refit false '{"error":"usage"}'; exit 1; }
BL=$RBD_HOME/baseline.json
[ -s "$BL" ] && jq -e '.services | length > 0' "$BL" > /dev/null 2>&1 || fail "$BL has no services (run: rbd_bootstrap.sh images)"
SECS=${RBD_REFIT_SECONDS:-600}
SEED=$(( 16#$(printf '%s' "$NAME" | sha256sum | cut -c1-7) % 1000000 + 1 ))
rbd_lock "${RBD_LOCK_WAIT:-3600}" || fail "the cluster lock is busy"

"$RBD_OPT/ci/capture.sh" "$NAME" "$SECS" "$SEED" > "$RBD_HOME/runs/.refit-$NAME.capture.out" || fail "capture.sh failed: $(tail -n 1 "$RBD_HOME/runs/.refit-$NAME.capture.out")"
C=$RBD_HOME/captures/$NAME
mv -f "$RBD_HOME/runs/.refit-$NAME.capture.out" "$C/meta/capture.out"

# the window must have run exactly baseline.json's images
mism=$(jq -r --slurpfile bl "$BL" '[.items[] | select(.kind == "Deployment") | .metadata.name as $n | .spec.template.spec.containers[0].image as $i
        | select(($bl[0].services[$n] // null) != null) | select(($i | split("@")[1] // "") != $bl[0].services[$n]) | "\($n): \($i)"] | join("; ")' "$C/meta/k8s.json" 2> /dev/null) \
  || fail "cannot read $C/meta/k8s.json"
[ -z "$mism" ] || fail "production does not run baseline.json's images: $mism"

log "$NAME: rhobound fit --name prod"
"$RBD_CLI" fit --manifest "$C/cut/manifest.json" --name prod --out "$C/fit" --json > "$C/meta/fit.json" 2> "$C/meta/fit.err" \
  || fail "rhobound fit failed: $(head -c 300 "$C/meta/fit.err") $(head -c 300 "$C/meta/fit.json")"
digest=$(sha256_of "$C/fit/fit.json") || fail "no fit.json"
printed=$(jq -r '.fit_digest // empty' "$C/meta/fit.json")
[ "$printed" = "$digest" ] || fail "fit printed $printed, fit.json hashes to $digest"

tmp=$(mktemp "$RBD_HOME/.baseline.json.XXXXXX") || fail "mktemp"
jq --arg dir "$C/fit" --arg d "$digest" --arg n "$NAME" --arg t "$(now_utc)" \
  '.schema = "rbd.baseline/v1" | .fit = {dir: $dir, digest: $d} | .capture = $n | .updated_at = $t' "$BL" > "$tmp" && [ -s "$tmp" ] \
  && chmod 0644 "$tmp" && mv -f "$tmp" "$BL" || { rm -f "$tmp"; fail "could not update $BL"; }
log "$NAME: baseline fit $digest"

mcp=skipped
if [ -d "$RBD_HOME/mcp/state" ]; then
  "$RBD_OPT/mcp/register-fit.sh" "$C/fit/fit.json" prod || fail "the fit is in baseline.json but rhobound-mcp did not take it"
  mcp=prod
fi
rbd_result refit true "$(jq -cn --arg n "$NAME" --arg d "$digest" --arg dir "$C/fit" --arg m "$(jq -r '.manifest_sha256 // ""' "$C/meta/check.json")" --arg mcp "$mcp" \
  '{name: $n, fit_digest: $d, fit_dir: $dir, capture_manifest: $m, mcp_env: $mcp}')"
