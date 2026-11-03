#!/usr/bin/env bash
# policy-digest.sh CLI PREDICTION POLICY [EXPECTED]   the effective-policy digest CLI's `gate` writes as gate.json digests.policy for
#   POLICY: RBD_POLICY_DIGEST in rbd.env (predict.sh, sign.sh and deploy.sh refuse a verdict decided under any other policy).
#   rbd_bootstrap.sh runs it on your workstation with build/rhobound-local on orch/fixtures/policy-digest-prediction.json and
#   repo/policy/gate.json (no rbd.env without it), then on rbd-tools1 with the installed /opt/rbd/bin/rhobound on the same bytes and
#   EXPECTED = the workstation's digest (the tools1 step refuses a difference). Needs python3 only (runs before tools1-setup.sh).
#   Prints sha256:<64 hex>. Exit 0; 1 no digest, or not EXPECTED; 2 usage. Scratch: a folder under RBD_TMP [/var/tmp], removed.
# shellcheck disable=SC2015
set -euo pipefail
CLI=${1:-} PRED=${2:-} POL=${3:-} WANT=${4:-}
die() { echo "policy-digest: $1" >&2; exit "${2:-1}"; }
[ $# -ge 3 ] && [ $# -le 4 ] && [ -x "$CLI" ] && [ -s "$PRED" ] && [ -s "$POL" ] \
  || die "usage: policy-digest.sh CLI PREDICTION POLICY [EXPECTED] (CLI executable, the two files not empty)" 2
[ -z "$WANT" ] || [[ $WANT =~ ^sha256:[0-9a-f]{64}$ ]] || die "EXPECTED must be sha256:<64 hex>, not '$WANT'" 2
D=$(mktemp -d "${RBD_TMP:-/var/tmp}/rbd-pdigest.XXXXXX") || die "mktemp failed"
trap 'rm -rf "$D"' EXIT
# the digest does not depend on the verdict (exit 0 pass, 1 block, 3 inconclusive all write gate.json; 2 is a tool error);
# --now inside the fixture's fit window keeps the run the same every time
rc=0; "$CLI" gate "$PRED" --policy "$POL" --now 2026-10-22T06:00:00Z --out "$D/gate" --json > "$D/out.json" 2> "$D/err" || rc=$?
case $rc in 0 | 1 | 3) ;; *) die "$CLI gate exit $rc: $(head -c 300 "$D/err")" ;; esac
g=$(python3 -I -c 'import json, sys; print(json.load(open(sys.argv[1]))["digests"]["policy"])' "$D/gate/gate.json" 2> /dev/null) || g=""
[[ $g =~ ^sha256:[0-9a-f]{64}$ ]] || die "$CLI gate wrote no digests.policy to gate.json ('$g')"
[ -z "$WANT" ] || [ "$g" = "$WANT" ] || die "$CLI computes $g for this policy, not $WANT: the two CLI builds differ (rbd_bootstrap.sh build kit)"
echo "$g"
