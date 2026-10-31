#!/usr/bin/env bash
# What sudo hands the steps (round-1 recheck1 finding 4, recheck2 finding 5) and ab.sh's run rules (recheck1 finding 3):
# every sudo-able step is #!/bin/bash and ignores RBD_OPT (the kit root) when SUDO_USER is set; ab.sh takes runs/RUN/.lock
# and refuses a run that holds a prediction before any cluster call, while a run without one may be re-run; its 5th
# argument AB_DIR (CI v2) is ab or ab-SERVICE only.
set -uo pipefail
# shellcheck source=tools1/tests/ci/lib.sh
. "$(dirname "$0")/lib.sh"
echo "== guards: shebang, RBD_OPT under sudo, ab.sh's run lock and no re-roll"
mkenv guards
STEPS=(pr-check build ab predict sign report deploy)   # the sudoers drop-in's seven
for s in "${STEPS[@]}"; do
  check "$s.sh starts with #!/bin/bash (no PATH lookup of bash under sudo)" test "$(head -n 1 "$CI/$s.sh")" = '#!/bin/bash'
done
H=0123456789abcdef0123456789abcdef01234567 D=sha256:$(printf d | sha256sum | cut -d' ' -f1)
args() { # the step's arguments
  case $1 in
    pr-check) echo "$T $H $H" ;; build) echo "$T $H auth" ;; ab) echo "$H auth $D $D" ;; deploy) echo "auth $D" ;; *) echo "$H" ;;
  esac
}
if [[ -e /opt/rbd ]]; then
  bad "/opt/rbd exists on this machine: the RBD_OPT-under-sudo checks would run the real kit; not run"
else
  for s in "${STEPS[@]}"; do
    # shellcheck disable=SC2046  # the arguments are words
    SUDO_USER=someone "$CI/$s.sh" $(args "$s") > "$T/out" 2> "$T/err"
    rc=$?
    check "$s.sh with SUDO_USER set ignores RBD_OPT=$TROOT: it looks for /opt/rbd/lib/rbd-env.sh and refuses (exit $rc)" \
      bash -c "[ $rc -ne 0 ] && grep -q '/opt/rbd/lib/rbd-env.sh' '$T/err' && ! grep -q 'kubectl' '$STUB_DIR/calls.log'"
  done
fi

# ab.sh in the test kit: part B's lib and part C's helpers, the stubs; it is refused before any cluster call here
cp "$KIT/tools1/lib/copy_traces.sh" "$KIT/tools1/lib/abmix.py" "$KIT/tools1/lib/splitarms.py" "$TROOT/lib/"
printf '{"abdrive": "123456789012.dkr.ecr.ap-south-1.amazonaws.com/rhobound-demo/kshop@sha256:%064d"}\n' 1 > "$THOME/images.json"
mkbaseline
runab() { AB_LOCK_WAIT=1 bash "$CI/ab.sh" "$@" > "$T/out" 2> "$T/err"; echo $?; }
abref() { # abref RC STAGE TEXT: ab.sh exit 1 at STAGE with TEXT on stderr, and no kubectl call
  [[ $1 -eq 1 && $(tail -n 1 "$T/out" | python3 -I -c 'import json,sys; print(json.load(sys.stdin)["stage"])') == "$2" ]] &&
    grep -q -- "$3" "$T/err" && ! grep -q '^kubectl' "$STUB_DIR/calls.log"
}
R=$THOME/runs/$H
mkdir -p "$R"
for x in predict.json gate; do
  if [[ $x == gate ]]; then mkdir "$R/gate"; else echo '{}' > "$R/$x"; fi
  rc=$(runab "$H" auth "$D" "$D")
  check "ab.sh refuses a run that holds $x (no re-roll; exit $rc, stage run, no kubectl call, no ab/)" abref "$rc" run \
    'already holds a prediction (predict.json or gate/): its A/B is not re-run; a re-gate needs a new commit'
  check "  and wrote nothing under runs/RUN/ab" test ! -e "$R/ab"
  rm -rf "${R:?}/$x"
done
lockrun "$R/.lock" || bad "lockrun: the holder never took the lock"
rc=$(runab "$H" auth "$D" "$D")
unlockrun
check "ab.sh refuses while another step of the same run holds runs/RUN/.lock (exit $rc, stage run, no kubectl call)" \
  abref "$rc" run "another step of runs/$H is running"
# a run without a prediction is not refused by those rules (a 'gh run rerun' of a job that failed before predict.sh): it goes
# on to the cluster lock, held here by another job, so still nothing reaches the cluster
exec 6>> "$THOME/lock"
flock -n 6 || bad "cannot take the cluster lock for the test"
rc=$(runab "$H" auth "$D" "$D")
flock -u 6
exec 6>&-
check "ab.sh on a run without a prediction passes the run rules and waits for the cluster lock (exit $rc, stage lock)" \
  abref "$rc" lock "cluster lock is held"
# CI v2: a 5th argument AB_DIR (ab, the default, or ab-SERVICE) so the A/Bs of a multi-service change live side by side
for bad in ab-pricing ../ab ab-auth/x abx ab-; do
  rc=$(runab "$H" auth "$D" "$D" "$bad")
  check "ab.sh refuses AB_DIR '$bad' for service auth (want ab or ab-auth; exit $rc, stage usage, no kubectl call)" \
    abref "$rc" usage "AB_DIR .*: want ab or ab-auth"
done
check "  and created no folder for them under runs/RUN" bash -c "! ls -A '$R' | grep -qv '^\.lock\$'"
rc=$(runab "$H" auth "$D" "$D" ab-auth extra)
check "ab.sh refuses 6 arguments (exit $rc, stage usage)" abref "$rc" usage "usage: ab.sh RUN SERVICE BASE_DIGEST CAND_DIGEST \[AB_DIR\]"
echo '{}' > "$R/predict.json"
rc=$(runab "$H" auth "$D" "$D" ab-auth)
check "ab.sh with AB_DIR ab-auth refuses a run that holds a prediction (exit $rc, stage run, no kubectl call)" \
  abref "$rc" run "already holds a prediction"
check "  and wrote nothing under runs/RUN/ab-auth" test ! -e "$R/ab-auth"
rm -f "$R/predict.json"
exec 6>> "$THOME/lock"
flock -n 6 || bad "cannot take the cluster lock for the test"
rc=$(runab "$H" auth "$D" "$D" ab-auth)
flock -u 6
exec 6>&-
check "ab.sh with AB_DIR ab-auth passes the run rules and waits for the cluster lock (exit $rc, stage lock)" \
  abref "$rc" lock "cluster lock is held"
done_summary
