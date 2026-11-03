#!/usr/bin/env bash
# muse2_resume.sh ARM T0_EPOCH: muse2_chain.sh that skips a ticket whose (tagged) arm already finished (accepted or not_accepted)
#   Muse experiment 2 (reports/muse-live/DECLARE-2.md): tickets T6, T7, T8 in that order on this kit's bed, each by
#   orch/muse_arm.sh with at most 3 iterations; no new ticket at or after T0 + 3 h, no new iteration at or after
#   T0 + 3 h 30 min (MUSE_DEADLINE). Stops at the first arm that ends in error (exit 1, 2, 4 or 5): a harness fault is
#   looked at before anything else runs. Log: state/logs/muse2-ARM.log; each arm's own log state/logs/muse-TICKET-ARM.log.
set -uo pipefail
ARM=${1:?usage: muse2_chain.sh R|C T0_EPOCH} T0=${2:?usage: muse2_chain.sh R|C T0_EPOCH}
[[ $ARM == R || $ARM == C ]] || { echo "ARM must be R or C" >&2; exit 2; }
[[ $T0 =~ ^[0-9]{10}$ ]] || { echo "T0 must be epoch seconds" >&2; exit 2; }
cd "$(dirname "$(readlink -f "$0")")/.." || exit 1
TICKET_CUT=$((T0 + 3 * 3600)) ITER_CUT=$((T0 + 3 * 3600 + 1800))
say() { echo "[muse2 $ARM $(date -u +%H:%M:%S)] $*"; }
say "start: T0 $(date -u -d "@$T0" +%H:%MZ), no new ticket from $(date -u -d "@$TICKET_CUT" +%H:%MZ), no new iteration from $(date -u -d "@$ITER_CUT" +%H:%MZ)"
for t in T6 T7 T8; do
  [ ! -e state/muse/STOP ] || { say "kill switch state/muse/STOP: stop"; exit 5; }
  if (($(date +%s) >= TICKET_CUT)); then say "time box: $t not started"; continue; fi
  tv="MUSE2_TAG_$t" tag=${!tv:-}   # MUSE2_TAG_T6=r2: a new attempt of a ticket whose first one a harness fault spoiled
  done_st=$(python3 -I -c 'import json,sys; print(json.load(open(sys.argv[1])).get("status"))' "state/muse/$t-$ARM${tag:+-$tag}/timeline.json" 2> /dev/null || true)
  case $done_st in accepted | not_accepted) say "$t${tag:+ ($tag)}: already $done_st, skipped"; continue ;; esac
  say "$t: start${tag:+ (attempt tag $tag)}"
  rc=0
  MUSE_DEADLINE=$ITER_CUT bash orch/muse_arm.sh "$t" "$ARM" ${tag:+--tag "$tag"} > "state/logs/muse-$t-$ARM${tag:+-$tag}.log" 2>&1 < /dev/null || rc=$?
  st=$(python3 -I -c 'import json,sys; print(json.load(open(sys.argv[1])).get("status"))' "state/muse/$t-$ARM${tag:+-$tag}/timeline.json" 2> /dev/null)
  say "$t: exit $rc, status $st"
  case $rc in 0 | 3) ;; *) say "$t ended in error (exit $rc): stop the chain"; exit "$rc" ;; esac
done
say "done"
