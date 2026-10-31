#!/usr/bin/env bash
# abmix.py on the real kshop capture (rs2 base-poisson100-r1: raw, window from the spans) and on its real cut (window
# from the cut's manifest.json): auth /verify 1.0 at ~100/s; payments /charge/card ~0.6, /charge/wallet ~0.4 at ~30/s.
# usage: bash tools1/tests/ab/test_abmix.sh      (env: WORK, LEAF, RHOBOUND)
set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
MIX=$HERE/../../lib/abmix.py
CAP=${CAP:-$HOME/rbd-dev/capture}
LEAF=${LEAF:-$HOME/rbd-dev/leaf}
RHOBOUND=${RHOBOUND:-$HOME/rbd-dev/rhobound}
WORK=${WORK:-$HOME/rbd-dev/tmp/partC/repro}
fail() { echo "FAIL: $*" >&2; exit 1; }
mkdir -p "$WORK"
if [[ ! -f $WORK/prodcut/manifest.json ]]; then
  rm -rf "$WORK/prodcut"
  "$RHOBOUND" check "$LEAF/pc" --window 2026-10-22T05:12:45Z,2026-10-22T05:22:45Z --cut entry-start \
    --out "$WORK/prodcut" --request-count "$LEAF/pc/request-count.json" --json >/dev/null
fi
for src in "$CAP:spans" "$WORK/prodcut:manifest.json"; do
  dir=${src%:*}; how=${src##*:}
  python3 -I "$MIX" auth "$dir" --name base1 >"$WORK/mix-auth.json" || fail "abmix auth $dir"
  jq -e --arg how "$how" '.service == "auth" and .paths == [{"path": "/verify", "w": 1}] and .from_capture == "base1"
    and .rate_per_pod > 99 and .rate_per_pod < 101.5 and .window_source == $how and (.pods | length) == 1' \
    "$WORK/mix-auth.json" >/dev/null || fail "auth mix from $dir: $(jq -c . "$WORK/mix-auth.json")"
  python3 -I "$MIX" payments "$dir" >"$WORK/mix-pay.json" || fail "abmix payments $dir"
  jq -e '(.paths | map(.path)) == ["/charge/card", "/charge/wallet"] and (.paths[0].w - 0.6 | fabs) < 0.01
    and (.paths[1].w - 0.4 | fabs) < 0.01 and (.paths | map(.w) | add - 1 | fabs) < 1e-5
    and .rate_per_pod > 29.5 and .rate_per_pod < 30.5' "$WORK/mix-pay.json" >/dev/null \
    || fail "payments mix from $dir: $(jq -c . "$WORK/mix-pay.json")"
  echo "ok: $dir ($how): auth $(jq -c '[.rate_per_pod, .paths]' "$WORK/mix-auth.json"), payments $(jq -c \
    '[.rate_per_pod, .paths]' "$WORK/mix-pay.json")"
done
rc=0; python3 -I "$MIX" nosuch "$WORK/prodcut" >/dev/null 2>&1 || rc=$?
[[ $rc == 1 ]] || fail "unknown service: exit $rc, want 1"
rc=0; python3 -I "$MIX" auth >/dev/null 2>&1 || rc=$?
[[ $rc == 2 ]] || fail "usage: exit $rc, want 2"
echo "PASS test_abmix"
