#!/usr/bin/env bash
# verify/tests/run.sh: every offline test of the verifier (part E): bash -n, shellcheck, score.py's unit tests, the stubbed
# truth/aa/collect tests. Scratch under VERIFY_SCRATCH [$HOME/rbd-dev/tmp/verify]. usage: bash verify/tests/run.sh
set -uo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
V=$(dirname "$HERE")
rc=0
for f in "$V"/truth.sh "$V"/aa.sh "$V"/collect.sh "$V"/vlib.sh "$HERE"/test_truth.sh "$HERE"/stubs/kubectl "$HERE"/stubs/capture.sh; do
  bash -n "$f" || { echo "bash -n failed: $f"; rc=1; }
done
(cd "$V" && shellcheck -x truth.sh aa.sh collect.sh vlib.sh tests/test_truth.sh tests/run.sh tests/stubs/kubectl tests/stubs/capture.sh) &&
  echo "shellcheck: clean" || rc=1
if grep -En '^[^#]*\b(import|from)\b.*rhobound' "$V/score.py"; then echo "score.py imports rhobound code"; rc=1; fi
python3 -I -W error::ResourceWarning "$HERE/test_score.py" || rc=1
bash "$HERE/test_truth.sh" || rc=1
((rc == 0)) && echo "verify tests: ALL PASSED" || echo "verify tests: FAILED"
exit "$rc"
