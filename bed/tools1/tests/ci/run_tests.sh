#!/usr/bin/env bash
# Part D's offline tests: shellcheck, pr-check, build, the pipeline end to end with the REAL rhobound CLI (predict, gate)
# and stub cosign/aws/kubectl (sign, report, deploy, judge), the sudo guards and ab.sh's run rules, the four patches +
# make_prs.sh, the workflows.
#   bash tools1/tests/ci/run_tests.sh            (scratch: $HOME/rbd-dev/tmp/partD, removed at the end unless KEEP=1)
# Never runs aws, docker, kubectl or cosign: lib.sh refuses to start unless the stubs come first on PATH.
set -uo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
KIT=$(cd "$HERE/../../.." && pwd)
export SCRATCH=${SCRATCH:-$HOME/rbd-dev/tmp/partD}
mkdir -p "$SCRATCH"
rc=0
echo "== shellcheck"
if shellcheck -x "$KIT"/tools1/ci/{pr-check,build,predict,sign,report,deploy,judge}.sh "$KIT/changes/make_prs.sh" \
  "$HERE"/*.sh "$HERE"/fakebin/{aws,docker,kubectl,gh,refit.sh}; then echo "  ok   all part D scripts"; else echo "  FAIL shellcheck"; rc=1; fi
for t in t_prcheck.sh t_build.sh t_flow.sh t_judge.sh t_guards.sh t_patches.sh; do
  bash "$HERE/$t" || rc=1
done
python3 -I "$HERE/t_workflows.py" || rc=1
[[ ${KEEP:-0} == 1 ]] || rm -rf "$SCRATCH"/t-*
echo "== part D: $([[ $rc -eq 0 ]] && echo ALL PASSED || echo FAILURES)"
exit "$rc"
