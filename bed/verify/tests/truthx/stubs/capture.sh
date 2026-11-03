#!/usr/bin/env bash
# fake capture.sh NAME SECONDS SEED for truthx's tests: part B's lock convention (no second lock when RBD_LOCK_HELD is set),
# what it saw in $STUB/capture.log (every deployment's image, so a test sees B0 at baseline and C on the candidates), then
# captures/NAME/meta/load.json in the maze's format (5 entries, 120 rps, part B's rbd.load/v1 line). Means: web 59.2, mobile
# 74.1, search-api 60.1, checkout 94.4, partner 58.2, plus a jitter from the seed below 0.1 ms, plus STUB_SHIFT
# ("web=5.0,partner=1") while any deployment runs a digest listed in STUB_CANDS (space-separated).
#   STUB_FAIL_ON=NAME           exit 1 without a load.json
#   STUB_BROKEN=ENTRY           while a candidate runs: that entry answers nothing ok (all errors)
#   STUB_DRIFT_ON=NAME:SVC:IMG  while capturing NAME, deployment SVC is set to IMG behind the verifier's back
#   STUB_REAL_LOCK=1            lock as part B's capture.sh does: source $RBD_LIB/lock.sh, rbd_lock 5 (nested)
set -uo pipefail
name=$1 secs=$2 seed=$3
# shellcheck source=/dev/null
. "$RBD_LIB/rbd-env.sh"
probe=free; flock -n "$RBD_HOME/lock" true || probe=held
imgs=$(for f in "$STUB"/img-*; do printf '%s=%s ' "${f##*/img-}" "$(cat "$f")"; done)
echo "$name $secs $seed held_env=${RBD_LOCK_HELD:-} probe=$probe imgs=$imgs" >> "$STUB/capture.log"
if [[ -n ${STUB_REAL_LOCK:-} ]]; then
  # shellcheck source=/dev/null
  . "$RBD_LIB/lock.sh"; rbd_lock 5 capture || { echo "capture: the cluster lock is busy" >&2; exit 1; }
elif [[ -z ${RBD_LOCK_HELD:-} ]]; then exec 9>> "$RBD_HOME/lock"; flock -n 9 || { echo "capture: lock busy" >&2; exit 1; }; fi
[[ ${STUB_FAIL_ON:-} == "$name" ]] && { echo "stub: capture $name failed" >&2; exit 1; }
if [[ -n ${STUB_DRIFT_ON:-} && ${STUB_DRIFT_ON%%:*} == "$name" ]]; then
  r=${STUB_DRIFT_ON#*:}; printf '%s' "${r#*:}" > "$STUB/img-${r%%:*}"
fi
on=0
for d in ${STUB_CANDS:-}; do grep -qF -- "$d" <<< "$imgs" && on=1; done
declare -A M=([web]=59.2 [mobile]=74.1 [search-api]=60.1 [checkout]=94.4 [partner]=58.2)
declare -A P=([web]=browse [mobile]=feed [search-api]=q [checkout]=buy [partner]=bulk)
declare -A N=([web]=15000 [mobile]=9000 [search-api]=4500 [checkout]=4500 [partner]=3000)
if ((on)); then
  IFS=, read -r -a sh <<< "${STUB_SHIFT:-}"
  for kv in "${sh[@]}"; do [[ -n $kv ]] && M[${kv%%=*}]=$(awk -v a="${M[${kv%%=*}]}" -v d="${kv#*=}" 'BEGIN{print a+d}'); done
fi
j=$(awk -v s="$seed" 'BEGIN{print (s % 5) * 0.02}')
D=$RBD_HOME/captures/$name
mkdir -p "$D/meta"
{
  echo "2026/11/02 09:00:00 maze-load: 36000 requests over $secs s (120.0 rps), seed $seed"
  for e in web mobile search-api checkout; do
    ok=${N[$e]} er=0
    if ((on)) && [[ ${STUB_BROKEN:-} == "$e" ]]; then er=$ok ok=0; fi
    awk -v m="${M[$e]}" -v j="$j" -v e="$e" -v p="${P[$e]}" -v ok="$ok" -v er="$er" \
      'BEGIN{printf "{\"errors\":%d,\"mean_ms\":%.4f,\"ok\":%d,\"p50_ms\":1,\"p95_ms\":2,\"p99_ms\":3,\"url\":\"http://%s:8080/%s\"}\n", er, (ok ? m+j : 0), ok, e, p}'
  done
  echo "2026/11/02 09:05:00 maze-load: done in $secs s"
  awk -v m="${M[partner]}" -v j="$j" 'BEGIN{printf "{\"errors\":0,\"mean_ms\":%.4f,\"ok\":3000,\"p50_ms\":1,\"p95_ms\":2,\"p99_ms\":3,\"url\":\"http://partner:8080/bulk\"}\n", m+j}'
  echo '{"schema":"rbd.load/v1","source":"default","file":null,"sha256":null,"rps":120.0,"mix":"browse=50.0,feed=30.0,q=15.0,buy=15.0,bulk=10.0","shares":{"browse":0.416667,"feed":0.25,"q":0.125,"buy":0.125,"bulk":0.083333},"rates":{"browse":50.0,"feed":30.0,"q":15.0,"buy":15.0,"bulk":10.0},"entries":{"web":50.0,"mobile":30.0,"search-api":15.0,"checkout":15.0,"partner":10.0},"summary":"120 rps (default): browse 50, feed 30, q 15, buy 15, bulk 10"}'
} > "$D/meta/load.json"
echo "{\"step\":\"capture\",\"ok\":true,\"name\":\"$name\"}"
