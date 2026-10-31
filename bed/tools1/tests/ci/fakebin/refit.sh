#!/usr/bin/env bash
# test stand-in for part B's refit.sh NAME: logs the call, its NAME's validity, and how it sees the cluster lock (nested = the
# caller's lock.sh lock, inherited: what part B's refit.sh accepts without waiting).
set -euo pipefail
if [[ -n ${RBD_LOCK_HELD:-} && /proc/$$/fd/9 -ef $RBD_HOME/lock ]]; then lk=nested
elif flock -n "$RBD_HOME/lock" true; then lk=free; else lk=HELD; fi
[[ ${1:-} =~ ^[a-z0-9][a-z0-9._-]{0,62}$ ]] && nm=ok || nm=BAD
echo "refit $* lock=$lk name=$nm" >> "$STUB_DIR/calls.log"
exit "${STUB_REFIT_RC:-0}"
