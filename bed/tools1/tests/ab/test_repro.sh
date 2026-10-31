#!/usr/bin/env bash
# splitarms.py + the REAL CLI on a synthetic mixed capture (the offline proof's auth arms inside real production lines):
# split, `check --window --cut` per arm, diff-fit; must reproduce the offline proof's A/B record (SPEC 0b).
# usage: bash tools1/tests/ab/test_repro.sh      (env: WORK, LEAF, PROD, RHOBOUND; run it through capped.sh)
set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
LIB=$HERE/../../lib
LEAF=${LEAF:-$HOME/rbd-dev/leaf}
PROD=${PROD:-$HOME/rbd-dev/capture/traces/spans.jsonl.gz}
RHOBOUND=${RHOBOUND:-$HOME/rbd-dev/rhobound}
WORK=${WORK:-$HOME/rbd-dev/tmp/partC/repro}
ARMS=$LEAF/arms
fail() { echo "FAIL: $*" >&2; exit 1; }
mkdir -p "$WORK"
if [[ ! -f $WORK/mixed/traces/spans.jsonl ]]; then
  rm -rf "$WORK/mixed.new"
  python3 -I "$HERE/mkmixed.py" "$ARMS" "$PROD" "$WORK/mixed.new"
  mv "$WORK/mixed.new" "$WORK/mixed"
fi
R=$WORK/run
rm -rf "$R"
mkdir -p "$R"
python3 -I "$LIB/splitarms.py" auth "$WORK/mixed" "$R/raw-a" "$R/raw-b" --stats "$R/split.json" 2>"$R/split.err" \
  || fail "splitarms: $(cat "$R/split.err")"
jq -e '.traces == {"a": 24196, "b": 24196} and .arm_roots.a.pod_prefix > 0 and .arm_roots.b.pod_prefix > 0
       and .bad_lines == 1 and .conflicts == 0 and .spans.dropped > 50000' "$R/split.json" >/dev/null \
  || fail "split stats $(cat "$R/split.json")"
S=$(jq -r .window.start "$ARMS/rc-a.json")
E=$(jq -r .window.end "$ARMS/rc-a.json")
for x in a b; do
  rc=0
  "$RHOBOUND" check "$R/raw-$x" --window "$S,$E" --cut entry-start --out "$R/cut-$x" --request-count "$ARMS/rc-$x.json" \
    --json >"$R/check-$x.json" 2>"$R/check-$x.err" || rc=$?
  [[ $rc == 0 ]] || fail "check $x exit $rc: $(cat "$R/check-$x.err")"
  jq -e --slurpfile o "$ARMS/check-$x.json" '.verdict == $o[0].verdict and .counts == $o[0].counts
       and .kept_share == $o[0].kept_share' "$R/check-$x.json" >/dev/null || fail "check $x differs from the proof's"
  echo "check $x: $(jq -c '{verdict, counts, kept_share, manifest_sha256}' "$R/check-$x.json")"
  echo "  proof:  $(jq -c '{manifest_sha256}' "$ARMS/check-$x.json")"
done
cp "$ARMS/loadgen.csv" "$R/cut-a/"
rc=0
RHOBOUND_STATE=$R/state "$RHOBOUND" diff-fit --baseline "$R/cut-a" --candidate "$R/cut-b" --baseline-name auth@a \
  --candidate-name auth@b --out "$R/record" --json >"$R/df.json" 2>"$R/df.err" || rc=$?
[[ $rc == 0 ]] || fail "diff-fit exit $rc: $(cat "$R/df.err") $(cat "$R/df.json")"
echo "diff-fit: $(cat "$R/df.json")   proof: $(cat "$ARMS/df.json")"
q='{own: .services[0].own_ms, visits: .services[0].visits, loadgen: .loadgen.client_latency_ms,
    requests: .loadgen.requests, findings, overlap_share}'
jq -e --slurpfile o "$ARMS/record/ab-record.json" "($q) == (\$o[0] | $q)" "$R/record/ab-record.json" >/dev/null \
  || fail "record numbers differ: $(jq -c "$q" "$R/record/ab-record.json") vs $(jq -c "$q" "$ARMS/record/ab-record.json")"
echo "record: $(jq -c '{own_ms: .services[0].own_ms, visits: .services[0].visits, findings}' "$R/record/ab-record.json")"
if cmp -s "$R/record/ab-record.json" "$ARMS/record/ab-record.json"; then
  echo "record bytes: IDENTICAL to the offline proof's (ab_digest $(jq -r .ab_digest "$R/df.json"))"
else
  echo "record bytes: differ from the proof's (numbers equal):"
  diff <(jq -S . "$ARMS/record/ab-record.json") <(jq -S . "$R/record/ab-record.json") || true
fi
rm -rf "$R/raw-a" "$R/raw-b"
echo "PASS test_repro"
