#!/usr/bin/env bash
# fake capture.sh NAME SECONDS SEED: keeps part B's lock convention (no second lock when RBD_LOCK_HELD is set), records what it
# saw in $STUB/capture.log, writes captures/NAME/meta/load.json in kshop-load's format, then part B's rbd.load/v1 line (the load
# setting, SPEC3 F6a: the default here) as capture.sh appends it. Means: storefront 68 / checkout 88.7, plus
# STUB_D_SF / STUB_D_CO [1.0] while auth runs $STUB_CAND, plus a small jitter from the seed.
#   STUB_FAIL_ON=NAME   exit 1 without a load.json
#   STUB_RC_ON=NAME     a finished window, then a failure (check refused): kept as NAME.failed-<epoch> as part B does, exit 1
#   STUB_REAL_LOCK=1    lock as part B's capture.sh does: source $RBD_LIB/lock.sh, rbd_lock 5 (nested under the verifier)
#   STUB_IGNORE_HELD=1  takes the lock anyway, waiting up to 60 s (a non-re-entrant capture.sh: the verifier must stop it)
set -uo pipefail
name=$1 secs=$2 seed=$3
# shellcheck source=/dev/null
. "$RBD_LIB/rbd-env.sh"
probe=free; flock -n "$RBD_HOME/lock" true || probe=held
echo "$name $secs $seed held_env=${RBD_LOCK_HELD:-} probe=$probe img=$(cat "$STUB/img-auth")" >> "$STUB/capture.log"
if [[ -n ${STUB_REAL_LOCK:-} ]]; then
  # shellcheck source=/dev/null
  . "$RBD_LIB/lock.sh"; rbd_lock 5 capture || { echo "capture: the cluster lock is busy" >&2; exit 1; }
elif [[ -n ${STUB_IGNORE_HELD:-} ]]; then exec 8>> "$RBD_HOME/lock"; flock -w 60 8 || { echo "capture: lock busy" >&2; exit 1; }   # a lock.sh that is not re-entrant
elif [[ -z ${RBD_LOCK_HELD:-} ]]; then exec 9>> "$RBD_HOME/lock"; flock -n 9 || { echo "capture: lock busy" >&2; exit 1; }; fi
[[ ${STUB_FAIL_ON:-} == "$name" ]] && { echo "stub: capture $name failed" >&2; exit 1; }
sf=68.0 co=88.7
if [[ $(cat "$STUB/img-auth") == *"${STUB_CAND:-none}" ]]; then
  sf=$(awk -v a=$sf -v d="${STUB_D_SF:-1.0}" 'BEGIN{print a+d}'); co=$(awk -v a=$co -v d="${STUB_D_CO:-1.0}" 'BEGIN{print a+d}')
fi
j=$(awk -v s="$seed" 'BEGIN{print (s % 5) * 0.02}')
D=$RBD_HOME/captures/$name
[[ ${STUB_RC_ON:-} == "$name" ]] && D=$RBD_HOME/captures/.$name.tmp
mkdir -p "$D/meta"
{
  echo "2026/10/31 09:00:00 kshop-load: 60000 requests over $secs s (100.0 rps), seed $seed"
  awk -v m="$sf" -v j="$j" 'BEGIN{printf "{\"errors\":0,\"mean_ms\":%.4f,\"ok\":42000,\"p50_ms\":1,\"p95_ms\":2,\"p99_ms\":3,\"url\":\"http://storefront.kshop.svc.cluster.local:8080/browse\"}\n", m+j}'
  awk -v m="$co" -v j="$j" 'BEGIN{printf "{\"errors\":0,\"mean_ms\":%.4f,\"ok\":10800,\"p50_ms\":1,\"p95_ms\":2,\"p99_ms\":3,\"url\":\"http://checkout.kshop.svc.cluster.local:8080/buy/card\"}\n", m+j}'
  echo "2026/10/31 09:10:00 kshop-load: done in $secs s"
  awk -v m="$co" -v j="$j" 'BEGIN{printf "{\"errors\":0,\"mean_ms\":%.4f,\"ok\":7200,\"p50_ms\":1,\"p95_ms\":2,\"p99_ms\":3,\"url\":\"http://checkout.kshop.svc.cluster.local:8080/buy/wallet\"}\n", m+j}'
  echo '{"schema":"rbd.load/v1","source":"default","file":null,"sha256":null,"rps":100.0,"mix":"browse=0.7,card=0.18,wallet=0.12","shares":{"browse":0.7,"card":0.18,"wallet":0.12},"rates":{"browse":70.0,"card":18.0,"wallet":12.0},"entries":{"storefront":70.0,"checkout":30.0},"summary":"100 rps (default): browse 70, card 18, wallet 12"}'
} > "$D/meta/load.json"
if [[ ${STUB_RC_ON:-} == "$name" ]]; then
  mv "$D" "$RBD_HOME/captures/$name.failed-$(date +%s)"; echo "stub: rhobound check refused the window" >&2; exit 1
fi
echo "{\"step\":\"capture\",\"ok\":true,\"name\":\"$name\"}"
