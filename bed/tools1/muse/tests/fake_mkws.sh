#!/usr/bin/env bash
# fake_mkws.sh USER NAME [--opt-in]: the tests' stand-in for /opt/muse/mkws.sh (tools1/muse/mkws.sh), under MUSE_TEST_ROOT:
# a fresh workspace home/USER/ws/NAME = rbd/src/main as a new git repository with one baseline commit (and the opt-in file
# committed in it with --opt-in), as the real one makes it; no module download (the tests are offline).
set -euo pipefail
u=$1 name=$2 optin=${3:-}
R=${MUSE_TEST_ROOT:?}
case $u in muser|musec) ;; *) echo "fake_mkws: user $u?" >&2; exit 2 ;; esac
[[ $name =~ ^[a-z0-9][a-z0-9._-]{0,60}$ ]] || { echo "fake_mkws: name $name?" >&2; exit 2; }
ws=$R/home/$u/ws/$name
[ ! -e "$ws" ] || { echo "fake_mkws: $ws exists" >&2; exit 1; }
mkdir -p "$ws"
tar -C "$R/rbd/src/main" -cf - . | tar -C "$ws" -xf -
cd "$ws"
if [ "$optin" = --opt-in ]; then mkdir -p .rhobound; printf '%s\n' '{"schema": "rhobound.muse/v1", "remind_predict": true}' > .rhobound/muse.json; fi
git init -q -b main . && git -c user.name=bed -c user.email=bed@example.invalid add -A &&
  git -c user.name=bed -c user.email=bed@example.invalid commit -q -m "bed main $(cat "$R/rbd/src/main.sha")"
echo "$ws"
