#!/usr/bin/env bash
# mkws.sh USER NAME [--opt-in]   (root, on rbd-tools1)
#   A fresh workspace /home/USER/ws/NAME: the bed's main tree (/var/lib/rbd/src/main, the commit in main.sha) as a new git
#   repository with one baseline commit, the Go module cache filled once per user (so builds need no network later),
#   and, with --opt-in, the rhobound Stop reminder's opt-in file committed in the baseline. Prints the workspace path.
set -euo pipefail
u=$1 name=$2 optin=${3:-}
case $u in muser|musec) ;; *) echo "mkws.sh: user $u?" >&2; exit 2 ;; esac
[[ $name =~ ^[a-z0-9][a-z0-9._-]{0,60}$ ]] || { echo "mkws.sh: name $name?" >&2; exit 2; }
ws=/home/$u/ws/$name
[ ! -e "$ws" ] || { echo "mkws.sh: $ws exists" >&2; exit 1; }
install -d -o "$u" -g "$u" -m 0700 "/home/$u/ws" "$ws"
tar -C /var/lib/rbd/src/main -cf - . | sudo -u "$u" tar -C "$ws" -xf -
main=$(cat /var/lib/rbd/src/main.sha)
sudo -u "$u" -H env PATH=/opt/muse/go/bin:/usr/bin:/bin bash -c '
  set -e; cd "$1"
  if [ "$2" = --opt-in ]; then mkdir -p .rhobound; printf "%s\n" "{\"schema\": \"rhobound.muse/v1\", \"remind_predict\": true}" > .rhobound/muse.json; fi
  git init -q -b main . && mkdir -p .gocache .gotmp && printf "/.gocache/\n/.gotmp/\n" >> .git/info/exclude \
    && git -c user.name=bed -c user.email=bed@example.invalid add -A \
    && git -c user.name=bed -c user.email=bed@example.invalid commit -q -m "bed main $3"
  cd maze/app && GOFLAGS=-mod=mod go mod download' _ "$ws" "$optin" "$main"
echo "$ws"
