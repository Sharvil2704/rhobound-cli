#!/usr/bin/env bash
# Part D's offline tests: shellcheck, pr-check, build, the pipeline end to end with the REAL rhobound CLI (predict, gate)
# and stub cosign/aws/kubectl (sign, report, deploy, judge), the sudo guards and ab.sh's run rules, the four patches +
# make_prs.sh, the workflows.
#   bash tools1/tests/ci/run_tests.sh            (scratch: $RBD_SCRATCH/partD [$TMPDIR/rbd/partD], removed at the end unless KEEP=1)
# Never runs aws, docker, kubectl or cosign: lib.sh refuses to start unless the stubs come first on PATH.
set -uo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
KIT=$(cd "$HERE/../../.." && pwd)
export SCRATCH=${SCRATCH:-${RBD_SCRATCH:-${TMPDIR:-/tmp}/rbd}/partD}
mkdir -p "$SCRATCH"
# the REAL rhobound CLI the flow tests run: RHOBOUND, else one built from this repository's root (bed/ lives in it)
if [[ -z ${RHOBOUND:-} ]]; then
  echo "== building rhobound from $(cd "$KIT/.." && pwd) for the tests"
  (cd "$KIT/.." && GOFLAGS=-mod=readonly go build -o "$SCRATCH/bin/rhobound" ./cmd/rhobound) || { echo "  FAIL go build ./cmd/rhobound"; exit 1; }
  export RHOBOUND=$SCRATCH/bin/rhobound
fi
rc=0
echo "== shellcheck"
# from the kit's root: the scripts' "shellcheck source=" paths are relative to it
if (cd "$KIT" && shellcheck -x tools1/ci/{pr-check,build,predict,sign,report,deploy,judge}.sh changes/make_prs.sh \
  tools1/tests/ci/*.sh tools1/tests/ci/fakebin/{aws,docker,kubectl,gh,refit.sh}); then echo "  ok   all part D scripts"; else echo "  FAIL shellcheck"; rc=1; fi
for t in t_prcheck.sh t_build.sh t_flow.sh t_routes.sh t_judge.sh t_guards.sh t_patches.sh; do
  bash "$HERE/$t" || rc=1
done
python3 -I "$HERE/t_workflows.py" || rc=1
[[ ${KEEP:-0} == 1 ]] || rm -rf "$SCRATCH"/t-*
echo "== part D: $([[ $rc -eq 0 ]] && echo ALL PASSED || echo FAILURES)"
exit "$rc"
