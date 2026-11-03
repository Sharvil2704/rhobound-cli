#!/usr/bin/env bash
# Make an A/B record fixture with the REAL CLI: mkarms.py (auth arms, arm b EXTRA_MS longer) -> check --cut per arm ->
# diff-fit. Copies the record to fixtures/ab-record-EXTRA_MSms.json. Heavy (2 x 43 MB raw arms): run once, by hand.
#   bash tools1/tests/ci/mkfixtures.sh EXTRA_MS
# Env: RHOBOUND [build/rhobound-local]  SPANS [rs2 base-poisson100-r1 spans]  SCRATCH [$RBD_SCRATCH/partD]
set -euo pipefail
[[ $# -eq 1 && $1 =~ ^[0-9]+(\.[0-9]+)?$ ]] || { echo "usage: mkfixtures.sh EXTRA_MS" >&2; exit 2; }
X=$1
HERE=$(cd "$(dirname "$0")" && pwd)
KIT=$(cd "$HERE/../../.." && pwd)
CLI=${RHOBOUND:-$KIT/build/rhobound-local}
SPANS=${SPANS:?set SPANS to a recorded kshop capture (traces/spans.jsonl.gz): the fixtures are committed; this only regenerates them}
W=${SCRATCH:-${RBD_SCRATCH:-${TMPDIR:-/tmp}/rbd}/partD}/fx-$X
CAP=$(cd "$(dirname "$0")/../../.." && pwd)/orch/capped.sh
run() { if [[ -f $CAP ]]; then RB_MEM_MAX=2G GOMAXPROCS=2 bash "$CAP" "$@"; else "$@"; fi; }

rm -rf "$W"; mkdir -p "$W/state"
export RHOBOUND_STATE=$W/state
run python3 -I "$HERE/mkarms.py" "$SPANS" "$W" 240 "$X"
win=$(cat "$W/window.txt")
for a in a b; do
  run "$CLI" check "$W/raw-$a" --window "$win" --cut entry-start --out "$W/cut-$a" --request-count "$W/rc-$a.json" --json \
    > "$W/check-$a.json"
done
cp "$W/loadgen.csv" "$W/cut-a/"
run "$CLI" diff-fit --baseline "$W/cut-a" --candidate "$W/cut-b" --baseline-name auth@a --candidate-name auth@b \
  --out "$W/record" --json > "$W/df.json"
cp "$W/record/ab-record.json" "$HERE/fixtures/ab-record-${X}ms.json"
rm -rf "$W/raw-a" "$W/raw-b" "$W/cut-a" "$W/cut-b"
python3 -I -c 'import json,sys; r=json.load(open(sys.argv[1])); s=r["services"][0]
print("record", json.load(open(sys.argv[2]))["ab_digest"], s["service"], "own_ms delta", s["own_ms"]["delta"], "se", s["own_ms"]["se"],
      "findings", [f["code"] for f in r["findings"]])' "$HERE/fixtures/ab-record-${X}ms.json" "$W/df.json"
