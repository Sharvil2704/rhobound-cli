#!/usr/bin/env bash
# kitenv.sh CMD...   CMD with this kit's state/kit.env exported (REPO, RBD_GH_REPO, RBD_SSHC, RBD_KH, RBD_SUBNET_RE, ...):
#   the Muse experiment's two beds are driven by two kit copies, each with its own state/kit.env. Scripts that source
#   rbd_lib.sh read it themselves; this wrapper also covers those that do not (changes/make_prs.sh, orch/muse_arm.sh's
#   REPO default).
set -euo pipefail
K=$(cd "$(dirname "$(readlink -f "$0")")/.." && pwd)
[ $# -ge 1 ] || { echo "usage: kitenv.sh CMD..." >&2; exit 2; }
# shellcheck source=/dev/null
if [ -f "$K/state/kit.env" ]; then set -a; . "$K/state/kit.env"; set +a; fi
cd "$K"
exec "$@"
