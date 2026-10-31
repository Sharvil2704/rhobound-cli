# shellcheck shell=bash
# lock.sh: one job at a time on the cluster (SPEC 3). Sourced:   . /opt/rbd/lib/lock.sh
#   rbd_lock [WAIT_S] [WHAT]   take $RBD_HOME/lock (flock on fd 9), waiting up to WAIT_S (default RBD_LOCK_WAIT or 3600); 1 if not got
#   rbd_lock_try [WHAT]        the same without waiting: 1 at once when another job holds it
#   rbd_unlock                 release it (also released when the holding shell exits)
#   rbd_lock_holder            who holds it (the holder file), or "free"
# The lock lives as long as fd 9 of the taking shell and of every child it starts. A child step (refit -> capture, truth -> capture)
# sees RBD_LOCK_HELD and fd 9 open on the lock file, and does not wait on its own parent. A background child left running keeps it.
RBD_LOCK_FILE=${RBD_LOCK_FILE:-${RBD_HOME:-/var/lib/rbd}/lock}

_rbd_lock_nested() { [ -n "${RBD_LOCK_HELD:-}" ] && [ -e "/proc/$BASHPID/fd/9" ] && [ "/proc/$BASHPID/fd/9" -ef "$RBD_LOCK_FILE" ]; }

_rbd_lock_take() {   # $1 flock option (-w N | -n)  $2 N  $3 what
  local what=$3 tmp
  if _rbd_lock_nested; then return 0; fi
  exec 9>> "$RBD_LOCK_FILE" || { echo "lock: cannot open $RBD_LOCK_FILE" >&2; return 1; }
  if [ "$1" = -n ]; then flock -n 9; else flock -w "$2" 9; fi || {
    echo "lock: $RBD_LOCK_FILE is held by $(rbd_lock_holder)${2:+ (waited $2 s)}" >&2; exec 9>&-; return 1; }
  export RBD_LOCK_HELD=$BASHPID
  tmp="$RBD_LOCK_FILE.holder.$BASHPID"
  printf '%s pid %s user %s since %s\n' "$what" "$BASHPID" "$(id -un)" "$(date -u +%FT%TZ)" > "$tmp" && mv -f "$tmp" "$RBD_LOCK_FILE.holder"
  return 0
}

rbd_lock() { _rbd_lock_take -w "${1:-${RBD_LOCK_WAIT:-3600}}" "${2:-${RBD_STEP:-$(basename "$0")}}"; }
rbd_lock_try() { _rbd_lock_take -n "" "${1:-${RBD_STEP:-$(basename "$0")}}"; }

rbd_unlock() {
  [ "${RBD_LOCK_HELD:-}" = "$BASHPID" ] || return 0   # only the shell that took it
  rm -f "$RBD_LOCK_FILE.holder"
  flock -u 9 2> /dev/null; exec 9>&-
  unset RBD_LOCK_HELD
}

rbd_lock_holder() {
  if (exec 8>> "$RBD_LOCK_FILE" && flock -n 8) 2> /dev/null; then echo free; else cat "$RBD_LOCK_FILE.holder" 2> /dev/null || echo "unknown holder"; fi
}
