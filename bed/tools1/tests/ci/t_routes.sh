#!/usr/bin/env bash
# predict.sh's per-route items (ROUTE_ITEMS, rbd.env.local) with a REAL CLI that takes them, on a fit with routes: the
# local maze campaign's fit (catalog serves GET /item and GET /search; search-api reaches only /search) and c1's catalog
# A/B record re-made by that CLI (routes: /item -0.02 ms, /search +2.51 ms; blended +0.56 ms).
# The fixture repo's image runs catalog and pricing, so each run also carries an A/A record of pricing (one blended item).
#   off (the default): one own_ms item for catalog, its blended delta, as before
#   on: one own_ms item per route, each the route's delta, cited to the record; search-api's predicted change is the
#       route set's (about +2.0..+3.0 ms) where the blended item gives about +0.4..+0.7 ms
#   a ROUTE_ITEMS that is neither on nor off is refused before any prediction
#   RHOBOUND=/path/to/rhobound bash tools1/tests/ci/t_routes.sh   (run_tests.sh builds one from this repository)
set -uo pipefail
export RHOBOUND=${RHOBOUND:?set RHOBOUND to a rhobound CLI built from this repository (run_tests.sh builds one)}
# shellcheck source=tools1/tests/ci/lib.sh
. "$(dirname "$0")/lib.sh"
echo "== routes: predict.sh's per-route items (CLI $("$CLI" version))"
mkenv routes
S=$T/src
mkrepo "$S"
mkbaseline
FX=$HERE/fixtures
# contract 1 with this CLI: the effective-policy digest it computes for the pinned policy, as the bootstrap pins it after
# an upgrade (a CLI with route items computes another digest than the 19baaed pin in lib.sh)
RDIG=$(RBD_TMP=$T bash "$KIT/tools1/setup/policy-digest.sh" "$CLI" "$KIT/orch/fixtures/policy-digest-prediction.json" \
  "$HERE/fixtures/repo-day1/policy/gate.json") || { bad "policy-digest.sh with $CLI"; RDIG=$PDIG; }
setdig "$RDIG"
NOW_R=2026-11-01T14:30:00Z   # just after the fit's window (2026-11-01 13:50-13:55)
cp "$FX/fit-routes.json" "$THOME/captures/prod/fit/fit.json"
python3 -I - "$THOME/baseline.json" "$THOME/captures/prod/fit/fit.json" << 'PY'
import hashlib, json, sys
p, fit = sys.argv[1:3]
b = json.load(open(p))
b["fit"]["digest"] = "sha256:" + hashlib.sha256(open(fit, "rb").read()).hexdigest()
json.dump(b, open(p, "w"))
PY

derive_record "$FX/ab-record-0ms.json" pricing "$T/rec-pricing-0.json"   # the image also runs pricing: an A/A of it
rprep() { # rprep NAME -> H: a v2 request of catalog + pricing (one image runs both) with a maze/app change; pr-check, build,
  # catalog's routed A/B record and pricing's A/A
  H=$(branch "$S" "$1" "echo '// $1' >> maze/app/internal/work/lib_v11.go; v2req '[\"catalog\", \"pricing\"]'")
  "$CI/pr-check.sh" "$S" "$(git -C "$S" rev-parse main)" "$H" > "$T/prc-$1.out" 2> "$T/prc-$1.err" || { bad "pr-check $1"; cat "$T/prc-$1.err"; }
  "$CI/build.sh" "$S" "$H" catalog > "$T/build-$1.out" 2> "$T/build-$1.err" || { bad "build $1"; cat "$T/build-$1.err"; }
  ab_standin_svc "$H" catalog "$FX/ab-record-routes.json"
  ab_standin_svc "$H" pricing "$T/rec-pricing-0.json"
}
rpredict() { # rpredict RUN ROUTE_ITEMS -> rc
  local rc=0
  ROUTE_ITEMS=$2 RBD_TEST_NOW=$NOW_R "$CI/predict.sh" "$1" > "$T/pred-$1.out" 2> "$T/pred-$1.err" || rc=$?
  echo "$rc"
}
items_are() { # items_are RUN MODE: change.json's items as MODE (blend or route) expects from the record
  python3 -I - "$THOME/runs/$1" "$FX/ab-record-routes.json" "$2" << 'PY'
import hashlib, json, os, sys
run, rec, mode = sys.argv[1:4]
raw = open(rec, "rb").read()
ev = ["sha256:" + hashlib.sha256(raw).hexdigest()]
row = [x for x in json.loads(raw)["services"] if x["service"] == "catalog"][0]
if mode == "route":
    want = [{"op": "own_ms", "service": "catalog", "route": r["route"], "value": r["own_ms"]["delta"], "label": "measured-ab",
             "evidence": ev} for r in row["routes"]]
else:
    want = [{"op": "own_ms", "service": "catalog", "value": row["own_ms"]["delta"], "label": "measured-ab", "evidence": ev}]
got = [x for x in json.load(open(os.path.join(run, "change.json")))["items"] if x["service"] == "catalog"]
sys.exit(0 if got == want else print("change.json items", got, "want", want) or 1)
PY
}
search_change() { # search_change RUN: search-api's predicted change (lo hi), from prediction.json
  python3 -I -c 'import json,sys; e=[x for x in json.load(open(sys.argv[1]))["entries"] if x["name"]=="search-api"][0]["change_ms"]
print("%.4f %.4f" % (e["lo"], e["hi"]))' "$THOME/runs/$1/prediction.json"
}

rprep off; OFF=$H
rprep on; ON=$H
rprep bad; BAD=$H

rc=$(rpredict "$BAD" yes)
check "ROUTE_ITEMS=yes is refused before any prediction (exit $rc)" \
  test "$rc" -eq 2 -a ! -e "$THOME/runs/$BAD/change.json" -a ! -e "$THOME/runs/$BAD/prediction.json"
grep -q "ROUTE_ITEMS must be on or off" "$T/pred-$BAD.err" || bad "the refusal names ROUTE_ITEMS: $(tail -n 2 "$T/pred-$BAD.err")"

rc=$(rpredict "$OFF" off)
echo "     run off ${OFF:0:12}: predict.sh exit $rc: $(last "$T/pred-$OFF.out" | cut -c1-160)"
check "off: change.json has one blended item for catalog, the record's own_ms.delta" items_are "$OFF" blend
check "off: a prediction was made" test -s "$THOME/runs/$OFF/prediction.json"

rc=$(rpredict "$ON" on)
echo "     run on ${ON:0:12}: predict.sh exit $rc: $(last "$T/pred-$ON.out" | cut -c1-160)"
check "on: change.json has one item per route (GET /item, GET /search), each the route's delta, cited to the record" \
  items_are "$ON" route
check "on: predict.json lists the routes it sent for catalog" python3 -I -c '
import json,sys; p=json.load(open(sys.argv[1])); sys.exit(p["services"][0].get("routes") != ["GET /item", "GET /search"])' \
  "$THOME/runs/$ON/predict.json"
rc=0; "$CI/sign.sh" "$ON" > "$T/sign-on.out" 2> "$T/sign-on.err" || rc=$?
check "on: sign.sh signs the verdict though change.json cites the record once per route (exit $rc)" test "$rc" -eq 0
read -r olo ohi < <(search_change "$OFF")
read -r nlo nhi < <(search_change "$ON")
echo "     search-api change: blended item $olo..$ohi ms, per-route items $nlo..$nhi ms"
check "on: search-api's change is the route set's (low end above 1.8 ms), the blended item's is under 1 ms" \
  python3 -I -c 'import sys; a=list(map(float,sys.argv[1:5])); sys.exit(not (a[1] < 1.0 and a[2] > 1.8 and a[3] < 3.5))' \
  "$olo" "$ohi" "$nlo" "$nhi"
done_summary
