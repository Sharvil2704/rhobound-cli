#!/usr/bin/env bash
# run_s8.sh: every offline test of SPEC2 S8-S10 and the scoreboard (section 5): orch/automerge.sh, orch/bench.sh,
# tools1/bench/prodcheck.py, verify/bench_score.py, changes/make_prs.sh and orch/agent_take.sh for cN-bench; SPEC3 F9's planted
# changes: changes/plant.py + orch/gocheck.sh (t_plant.sh), make_prs.sh for cN-plant, automerge.sh's rbd-plant refusal.
#   bash tools1/tests/bench/run_s8.sh [--quick]     (--quick skips t_agent_take_bench.sh and t_plant.sh: they compile kshop
#                                                    through capped.sh)
# Scratch: S8_SCRATCH [$HOME/rbd-dev/tmp/s8], removed at the end unless KEEP=1. No ssh, aws, docker, kubectl or real
# gh runs: the stubs come first on PATH (s8lib.sh, ci/lib.sh refuse to start otherwise).
set -uo pipefail
H=$(cd "$(dirname "$0")" && pwd)
KIT=$(cd "$H/../../.." && pwd)
export S8_SCRATCH=${S8_SCRATCH:-$HOME/rbd-dev/tmp/s8}
export SCRATCH=${SCRATCH:-$S8_SCRATCH/partD}   # ci/lib.sh's scratch (t_make_prs_bench.sh)
mkdir -p "$S8_SCRATCH" "$SCRATCH"
rc=0
echo "== shellcheck"
if shellcheck -x "$KIT/orch/automerge.sh" "$KIT/orch/bench.sh" "$KIT/orch/agent_take.sh" "$KIT/orch/gocheck.sh" "$KIT/changes/make_prs.sh" \
  "$H"/*.sh "$H/fakebin/gh" "$H/fakebin/rbd.sh"; then echo "  ok   S8-S10 scripts"; else echo "  FAIL shellcheck"; rc=1; fi
for f in "$KIT/tools1/bench/prodcheck.py" "$KIT/verify/bench_score.py" "$KIT/changes/plant.py" "$H/fakegh.py" "$H/t_bench_score.py" "$H/fixtures/score/mkscore.py"; do
  python3 -I -c 'import ast, sys; ast.parse(open(sys.argv[1]).read(), sys.argv[1])' "$f" || { echo "  FAIL python syntax $f"; rc=1; }
done
bash "$H/t_automerge.sh" || rc=1
bash "$H/t_bench_driver.sh" || rc=1
bash "$H/t_make_prs_bench.sh" || rc=1
bash "$H/t_make_prs_plant.sh" || rc=1
python3 -I "$H/t_bench_score.py" || rc=1
[[ ${1:-} == --quick ]] || bash "$H/t_agent_take_bench.sh" || rc=1
[[ ${1:-} == --quick ]] || bash "$H/t_plant.sh" || rc=1
[[ ${KEEP:-0} == 1 ]] || rm -rf "$S8_SCRATCH"/t-* "$SCRATCH"/t-*
echo "== S8-S10 + scoreboard: $([[ $rc -eq 0 ]] && echo ALL PASSED || echo FAILURES)"
exit "$rc"
