#!/usr/bin/env bash
# verify/tests/truthx/run.sh: every offline test of truthx.sh, regress.py and candidate.sh (the Muse experiment's
# measurement): bash -n, shellcheck, regress.py's unit tests, the stubbed truthx and candidate tests. Scratch under
# VERIFY_SCRATCH [$RBD_SCRATCH/verify]. usage: bash verify/tests/truthx/run.sh
set -uo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
V=$(cd "$HERE/../.." && pwd)
rc=0
for f in "$V"/truthx.sh "$V"/stagedx.sh "$V"/candidate.sh "$HERE"/run.sh "$HERE"/test_truthx.sh "$HERE"/test_stagedx.sh "$HERE"/test_candidate.sh "$HERE"/stubs/capture.sh; do
  bash -n "$f" || { echo "bash -n failed: $f"; rc=1; }
done
(cd "$V" && shellcheck -x truthx.sh stagedx.sh candidate.sh vlib.sh tests/truthx/run.sh tests/truthx/test_truthx.sh \
  tests/truthx/test_stagedx.sh \
  tests/truthx/test_candidate.sh tests/truthx/stubs/capture.sh) && echo "shellcheck: clean" || rc=1
if grep -En '^[^#]*\b(import|from)\b.*rhobound' "$V/regress.py"; then echo "regress.py imports rhobound code"; rc=1; fi
python3 -I -W error::ResourceWarning "$HERE/test_regress.py" || rc=1
bash "$HERE/test_truthx.sh" || rc=1
bash "$HERE/test_stagedx.sh" || rc=1
bash "$HERE/test_candidate.sh" || rc=1
((rc == 0)) && echo "truthx tests: ALL PASSED" || echo "truthx tests: FAILED"
exit "$rc"
