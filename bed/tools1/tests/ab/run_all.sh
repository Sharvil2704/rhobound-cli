#!/usr/bin/env bash
# Part C's offline tests, in order: abdrive (go vet + test, then the linux/amd64 build), splitarms unit, abmix on the
# real kshop capture, splitarms + real CLI reproduction of the offline proof, ab.sh end to end. Scratch: $WORK.
# usage: bash tools1/tests/ab/run_all.sh [--keep]      (on the orchestrator; never touches AWS or a cluster)
set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
CAPPED=${CAPPED:-$HOME/rbd-dev/capped.sh}
export WORK=${WORK:-$HOME/rbd-dev/tmp/partC/repro}
mkdir -p "$WORK"
bash "$HERE/../../abdrive/build.sh"
python3 -I "$HERE/test_splitarms_unit.py"
for t in test_abmix.sh test_repro.sh test_ab.sh; do
  RB_MEM_MAX=3G bash "$CAPPED" bash "$HERE/$t"
done
shellcheck "$HERE"/../../ci/ab.sh "$HERE"/*.sh "$HERE"/fake/kubectl "$HERE"/fake/*.sh "$HERE"/../../abdrive/build.sh
[[ ${1:-} == --keep ]] || rm -rf "$WORK"
echo "PASS part C (all)"
