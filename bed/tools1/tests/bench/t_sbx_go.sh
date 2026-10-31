#!/usr/bin/env bash
# t_sbx_go.sh: tools1/bench/sbx.sh's container scripts run for real with this box's Go, through fakebin/docker-local (the
# mounts rewritten to host folders, every go call inside capped.sh: RB_MEM_MAX=2G GOMAXPROCS=2; no docker). On the stand-in
# hot package (fixtures/hot): the scratch module with a go.mod of module + go lines only builds offline under
# GOFLAGS=-mod=mod GOPROXY=off; tests and hidden count real '--- PASS/FAIL' lines; a wrong candidate fails the hidden
# tests; the bench compiles each tree once and parses 5 interleaved rounds of real benchmark lines. About 1-2 min cold.
#   bash tools1/tests/bench/t_sbx_go.sh        (scratch $HOME/rbd-dev/tmp/t_sbx_go.*; Go's cache in
#                                               $HOME/rbd-dev/tmp/sbx-go-cache, kept between runs)
set -uo pipefail
H=$(cd "$(dirname "$0")" && pwd); DEMO=$(cd "$H/../../.." && pwd)
F=$H/fixtures
CAPPED=${CAPPED:-$HOME/rbd-dev/capped.sh}
GOBIN=$(dirname "$(command -v go || echo go)")
[[ -x $GOBIN/go && -r $CAPPED ]] || { echo "t_sbx_go: needs go and $CAPPED"; exit 1; }
mkdir -p "$HOME"/rbd-dev/tmp; T=$(mktemp -d "$HOME"/rbd-dev/tmp/t_sbx_go.XXXXXX)
[[ -n ${KEEP_T:-} ]] && echo "T=$T"
cleanup() { [[ -n ${KEEP_T:-} ]] || rm -rf "$T"; }
trap cleanup EXIT
pass=0 fail=0
check() { local d=$1; shift; if "$@" > /dev/null 2>&1; then pass=$((pass + 1)); else fail=$((fail + 1)); echo "FAIL: $d"; fi; }
D1=$DEMO/tools1/tests/ci/fixtures/repo-day1/kshop/app   # frozen day-1 main (repo/ follows GitHub main)
mkdir -p "$T/main/kshop/app/internal/hot"; cp "$D1/go.mod" "$D1/go.sum" "$T/main/kshop/app/"
cp "$F/hot/rank.go" "$F/hot/rank_test.go" "$T/main/kshop/app/internal/hot/"
cp -r "$T/main" "$T/good"; cp -r "$T/main" "$T/wrong"
(cd "$T/wrong" && git init -q && git apply "$F/task-tb1/refs/wrong.patch") || { echo "t_sbx_go: cannot apply wrong.patch"; exit 1; }
sx() {   # sx MODE TREE OUT
  env SBX_DOCKER="$H/fakebin/docker-local" LOCAL_TMP="$HOME"/rbd-dev/tmp/sbx-go-cache CAPPED="$CAPPED" GO_BIN_DIR="$GOBIN" \
    SBX_DOCKERFILE="$DEMO/tools1/kshop/Dockerfile" SBX_BASE_TREE="$T/main" SBX_LOCK="$T/bench.lock" \
    bash "$DEMO/tools1/bench/sbx.sh" "$1" "$2" "$F/task-tb1" "$3" > "$3.stdout" 2> "$3.stderr"
}
r() { python3 -I -c 'import json,sys; r=json.load(open(sys.argv[1])); exec(sys.argv[2])' "$1/result.json" "$2"; }
sx tests "$T/good" "$T/o-tests"; rc=$?
[[ $rc -eq 0 ]] || tail -n 20 "$T/o-tests/output.txt" "$T/o-tests.stderr"
check "real go: visible tests pass offline in the minimal module (exit 0, 1 passed)" r "$T/o-tests" 'assert r["ok"] and r["passed"]==1 and r["failed"]==0, r'
sx hidden "$T/good" "$T/o-hidden"
check "real go: hidden tests copied in and passed (2 passed: visible + hidden)" r "$T/o-hidden" 'assert r["ok"] and r["passed"]==2, r'
sx hidden "$T/wrong" "$T/o-wrong"; rc=$?
check "real go: the wrong reference fails its hidden test (exit 1, failed counted)" bash -c "[ $rc -eq 1 ] && python3 -I -c 'import json,sys; r=json.load(open(sys.argv[1])); assert not r[\"ok\"] and r[\"failed\"]>=2, r' '$T/o-wrong/result.json'"
sx bench "$T/good" "$T/o-bench"; rc=$?
[[ $rc -eq 0 ]] || tail -n 20 "$T/o-bench/output.txt" "$T/o-bench.stderr"
check "real go: bench compiled once per tree, 5 interleaved rounds parsed (ns/op > 0, allocs, spread)" r "$T/o-bench" '
b=r["bench"]["BenchmarkRank"]; assert r["ok"] and b["base_ns"]>0 and b["cand_ns"]>0 and b["spread_ms"]>=0 and b["base_allocs"]==0, r
import re; t=open(sys.argv[1].replace("result.json","output.txt")).read()
assert len(re.findall(r"^BenchmarkRank-\d+\s", t, re.M))==10 and t.count("== sbx base")==5'
echo "== t_sbx_go: $pass passed, $fail failed"
[[ $fail -eq 0 ]]
