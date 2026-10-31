#!/usr/bin/env bash
# sync_main.sh   demo2, between bench tasks: after a merge moved GitHub main on, make every copy of main agree before the next
# funnel (agent_take.sh refuses a run whose base_sha is not state/main.sha):
#   1. a fresh clone of GitHub main -> repo/ (rsync --delete, the tree only) and state/main.sha
#   2. RBD_IMAGES_UPLOAD_ONLY=1 rbd_bootstrap.sh images: main's tree -> rbd-tools1:/var/lib/rbd/src/main (+ main.sha), no build
#      (a merged change's image was built by its gate and deployed by deploy.sh)
# Prints main's sha. Exit 0 / 1. Env: REPO [Sharvil2704/rhobound-demo].
set -euo pipefail
DEMO=$(cd "$(dirname "$0")/.." && pwd)
REPO=${REPO:-Sharvil2704/rhobound-demo}
die() { echo "sync_main: error: $*" >&2; exit 1; }
mkdir -p "$DEMO/../.tmp-bed"; W=$(mktemp -d "$DEMO/../.tmp-bed/sync_main.XXXXXX")
trap 'rm -rf "$W"' EXIT
git -c credential.helper= -c 'credential.helper=!gh auth git-credential' clone -q "https://github.com/$REPO.git" "$W/main" ||
  die "cannot clone $REPO"
sha=$(git -C "$W/main" rev-parse HEAD)
rsync -a --delete --exclude .git "$W/main/" "$DEMO/repo/"
printf '%s\n' "$sha" > "$DEMO/state/main.sha"
echo "[sync_main] repo/ and state/main.sha = GitHub main ${sha:0:12}" >&2
RBD_IMAGES_UPLOAD_ONLY=1 bash "$DEMO/orch/rbd_bootstrap.sh" images >&2 || die "upload of main to rbd-tools1 failed"
got=$(bash "$DEMO/orch/rbd.sh" run cat /var/lib/rbd/src/main.sha 2> /dev/null | tail -n 1)
[[ $got == "$sha" ]] || die "rbd-tools1's src/main.sha is '$got', not $sha"
echo "$sha"
