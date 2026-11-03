#!/usr/bin/env bash
# push_main.sh "MESSAGE"   demo2: move GitHub main on to repo/'s tree with ONE new commit (fast-forward, never forced), for
# changes that cannot go through a gated PR: the maze-hot app and gate.yml (pr-check refuses .github/; SPEC2 4).
#   1. publish_main.sh's leak scan on repo/ (DRYRUN=1: its scan runs first; nothing is created or pushed by it)
#   2. a fresh clone of main; its tree replaced by repo/'s (rsync --delete, .git kept); one commit as the gh account
#      (its noreply address), MESSAGE + the attribution trailer; git push origin main (refused by GitHub unless fast-forward)
#   3. state/main.sha = the new commit; prints it. A repo/ that already is main's tree: nothing pushed, exit 0.
# Exit 0 pushed or nothing to do; 1 refused or failed. Env: REPO [Sharvil2704/rhobound-maze-bed].
set -euo pipefail
DEMO=$(cd "$(dirname "$0")/.." && pwd)
REPO=${REPO:-Sharvil2704/rhobound-maze-bed}
say() { echo "[push_main $(date -u +%H:%M:%S)] $*" >&2; }
die() { echo "push_main: error: $*" >&2; exit 1; }
[[ $# -eq 1 && -n $1 ]] || die "usage: push_main.sh MESSAGE"
scan=$(DRYRUN=1 bash "$DEMO/orch/publish_main.sh" 2>&1 || true)
grep -q 'scanned clean' <<< "$scan" || { echo "$scan" | tail -20 >&2; die "the leak scan of repo/ did not pass (above)"; }
say "$(grep -o 'repo/: [0-9]* files scanned clean' <<< "$scan")"
SCR=${RBD_SCRATCH:-${TMPDIR:-/tmp}/rbd}; mkdir -p "$SCR"; W=$(mktemp -d "$SCR/push_main.XXXXXX")
trap 'rm -rf "$W"' EXIT
gitc() { git -c credential.helper= -c 'credential.helper=!gh auth git-credential' "$@"; }
gitc clone -q "https://github.com/$REPO.git" "$W/main" || die "cannot clone $REPO"
old=$(git -C "$W/main" rev-parse HEAD)
rsync -a --delete --exclude .git "$DEMO/repo/" "$W/main/"
git -C "$W/main" add -A
if git -C "$W/main" diff --cached --quiet; then
  say "GitHub main ${old:0:12} already holds repo/'s tree: nothing pushed"
  printf '%s\n' "$old" > "$DEMO/state/main.sha"; echo "$old"; exit 0
fi
git -C "$W/main" --no-pager diff --cached --stat | tail -5 >&2
read -r gid glogin < <(gh api user -q '"\(.id) \(.login)"') || die "cannot read the gh account"
git -C "$W/main" -c user.name="$glogin" -c user.email="$gid+$glogin@users.noreply.github.com" commit -q -m "$1"
gitc -C "$W/main" push -q origin HEAD:refs/heads/main || die "push refused (main moved on? never forced)"
new=$(git -C "$W/main" rev-parse HEAD)
printf '%s\n' "$new" > "$DEMO/state/main.sha"
say "main ${old:0:12} -> ${new:0:12}"
echo "$new"
