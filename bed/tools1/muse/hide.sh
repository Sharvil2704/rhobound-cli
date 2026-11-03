#!/usr/bin/env bash
# hide.sh USER CMD...   (root, on rbd-tools1; /opt/muse/hide.sh)
#   CMD in a mount namespace of its own in which USER's session cannot see what its arm must not: for both users the GitHub
#   runner's checkout (every branch of the bed repo, both arms' PRs among them), /opt/rbd/etc (the bed's environment,
#   the account id in it), the tickets (hidden tests) and the other user's home; for musec (the arm without rhobound) also
#   rhobound itself: the plugin, the production capture and policy, rhobound-mcp and the bed's engine. Each is covered by
#   an empty read-only tmpfs (a folder) or /dev/null (a file); nothing on disk changes. tools1 has no setfacl, and the
#   runner's workflow re-opens its checkout's modes on every run, so modes alone cannot hide it. CMD then drops to USER
#   itself (sudo -u / setpriv), inside this namespace. Exit: CMD's, or 2 when a cover cannot be mounted.
set -euo pipefail
[ $# -ge 2 ] || { echo "usage: hide.sh USER CMD..." >&2; exit 2; }
u=$1; shift
case $u in muser) other=musec ;; musec) other=muser ;; *) echo "hide.sh: user $u?" >&2; exit 2 ;; esac
dirs=(/opt/actions-runner /opt/rbd/etc /opt/muse/tickets "/home/$other")
files=()
if [ "$u" = musec ]; then
  dirs+=(/opt/muse/plugin /opt/muse/rb /opt/rbd/bin)
  files+=(/opt/muse/bin/rhobound-mcp)
fi
# shellcheck disable=SC2016  # the inner script is single-quoted on purpose: it expands its own arguments
exec unshare --mount --propagation private -- bash -c '
  set -euo pipefail
  n=$1; shift
  for ((i = 0; i < n; i++)); do d=$1; shift; [ -d "$d" ] || continue
    mount -t tmpfs -o ro,mode=000,size=4k,nosuid,nodev,noexec hide "$d" || { echo "hide.sh: cannot cover $d" >&2; exit 2; }; done
  m=$1; shift
  for ((i = 0; i < m; i++)); do f=$1; shift; [ -e "$f" ] || continue
    mount --bind -o ro /dev/null "$f" || { echo "hide.sh: cannot cover $f" >&2; exit 2; }; done
  exec "$@"' _ "${#dirs[@]}" "${dirs[@]}" "${#files[@]}" "${files[@]}" "$@"
