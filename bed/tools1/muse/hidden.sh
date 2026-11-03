#!/usr/bin/env bash
# hidden.sh ARM TICKET RUN ITER   (root, on rbd-tools1; installed as /opt/muse/hidden.sh)
#   The ticket's hidden tests against iteration ITER's change, on a COPY, never in the agent's workspace (which never sees
#   them): a fresh folder /var/tmp/muse-hidden-USER.XXXXXX holding main's maze/app from the run's snapshot
#   (/var/lib/rbd/muse/runs/RUN/base), the iteration's exported files over it (/var/lib/rbd/agent/RUN-iITER, as its
#   manifest lists them: exactly what the pull request carries) and the hidden tests
#   (/opt/muse/tickets/TICKET/hidden/maze/app/**/*_test.go). Removed afterwards with its build cache, so no compiled test
#   stays where the agent could read it.
#   go test -json -count=1 -tags TAGS -timeout 300s on the hidden tests' packages (TAGS: the ticket's meta.json test_tags,
#   default hidden; the packages' own tests run too, as the campaign's hidden_check.sh), as the arm's user (setpriv, no new privileges) in a network namespace of its own (loopback only),
#   offline: GOPROXY=off GOFLAGS=-mod=readonly GOTOOLCHAIN=local GOWORK=off GOENV=off CGO_ENABLED=0 (no -race: tools1 has
#   no C compiler), the user's module cache, a fresh GOCACHE; then go mod verify (recorded as modcache_verified).
#   -> /var/lib/rbd/muse/runs/RUN/iITER/hidden.json (rbd) and the same object as the last stdout line:
#   {schema rbd.muse-hidden/v1, run, iteration, ticket, arm, pass, failed: [test names], ran, passed, expected, missing,
#    build_failed, packages_failed, go_test_rc, error, race: false, modcache_verified, packages, overwrote, wall_s, go,
#    output_tail}. pass: go test exited 0 and every Test function of the hidden files passed.
#   error non-null: the check could not run or cannot be trusted (no test ran, a timeout): not a test failure.
# Exit 0 pass, 1 fail (a test failed or the tests do not compile against the change: feed it back), 3 error (hidden.json's
# error), 2 usage or setup error (no hidden.json), 4 a session or hidden run of this user holds its lock.
# Env: MUSE_TEST_ROOT (tests only, as task.sh), MUSE_TEST_GO, MUSE_TEST_GOMODCACHE, MUSE_TEST_GOCACHE, MUSE_TEST_WRAP.
# shellcheck disable=SC2015  # A && B || die is meant
set -euo pipefail
umask 027
die() { echo "hidden.sh: error: $*" >&2; exit "${2:-2}"; }
say() { echo "[hidden.sh $(date -u +%H:%M:%S)] $*" >&2; }
[ $# = 4 ] || die "usage: hidden.sh ARM TICKET RUN ITER"
ARM=$1 TICKET=$2 RUN=$3 ITER=$4
case $ARM in R) U=muser ;; C) U=musec ;; *) die "ARM must be R or C, not $ARM" ;; esac
[[ $TICKET =~ ^[A-Za-z0-9][A-Za-z0-9_-]{0,31}$ ]] || die "TICKET: letters, digits, - _"
[[ $RUN =~ ^[A-Za-z0-9][A-Za-z0-9_-]{0,27}$ ]] || die "RUN: letters, digits, - _ (at most 28)"
[[ $ITER =~ ^[1-9]$ ]] || die "ITER must be 1..9"
if [ -n "${MUSE_TEST_ROOT:-}" ]; then
  TR=$MUSE_TEST_ROOT OPT=$MUSE_TEST_ROOT/opt-muse HOMES=$MUSE_TEST_ROOT/home RBD=$MUSE_TEST_ROOT/rbd HTMP=$MUSE_TEST_ROOT/vartmp
  GO=${MUSE_TEST_GO:-$(command -v go)}
else
  [ "$(id -u)" = 0 ] || die "run as root (sudo /opt/muse/hidden.sh ...)"
  TR="" OPT=/opt/muse HOMES=/home RBD=/var/lib/rbd HTMP=/var/tmp GO=/opt/muse/go/bin/go
fi
EXPORT=$OPT/export.py TD=$OPT/tickets/$TICKET
RD=$RBD/muse/runs/$RUN ID=$RBD/muse/runs/$RUN/i$ITER OUT=$RBD/agent/$RUN-i$ITER
[ -f "$EXPORT" ] && [ -x "$GO" ] || die "no $EXPORT or $GO"
[ -d "$TD/hidden" ] && [ ! -L "$TD/hidden" ] || die "ticket $TICKET has no hidden/ ($TD/hidden)"
[ -f "$RD/run.json" ] && [ -d "$RD/base" ] && [ -d "$ID" ] || die "no run $RUN iteration $ITER ($RD)"
python3 -I -c 'import json,sys; r=json.load(open(sys.argv[1])); sys.exit(0 if (r["arm"], r["ticket"], r["user"]) == tuple(sys.argv[2:5]) else 1)' \
  "$RD/run.json" "$ARM" "$TICKET" "$U" || die "$RUN is not arm $ARM, ticket $TICKET ($RD/run.json)"
python3 -I -c 'import json,sys; sys.exit(0 if json.load(open(sys.argv[1])).get("ok") is True else 1)' "$OUT/result.json" 2> /dev/null ||
  die "$OUT holds no exported change (result.json ok is not true): nothing to test"
TAGS=$(python3 -I -c '
import json, re, sys
try:
    t = json.load(open(sys.argv[1])).get("test_tags") or "hidden"
except (OSError, ValueError):
    t = "hidden"
print(t if isinstance(t, str) and re.fullmatch(r"[A-Za-z0-9_.,]{1,64}", t) else "hidden")' "$TD/meta.json")

kill_user() {
  [ -n "$TR" ] && return 0
  pkill -KILL -u "$U" 2> /dev/null || true
  for _ in $(seq 1 40); do pgrep -u "$U" > /dev/null || return 0; sleep 0.25; done
  say "warning: processes of $U still alive after SIGKILL"
}
# root's own scratch (never $RBD/tmp: that is rbd's, CI's pr-check makes its folders there, and a root-made one locks it out)
mkdir -p "$RBD/muse/locks" "$HTMP" "$RBD/muse/tmp"
exec 9> "$RBD/muse/locks/$U.lock"
flock -n 9 || die "a session or hidden run of $U holds $RBD/muse/locks/$U.lock" 4
H=$(mktemp -d "$HTMP/muse-hidden-$U.XXXXXX")
R=$(mktemp -d "$RBD/muse/tmp/muse-hidden-res.XXXXXX")   # results where the user (running the change's code) cannot reach
trap 'kill_user; rm -rf "$H" "$R"' EXIT
trap 'exit 130' INT TERM HUP

python3 -I "$EXPORT" hidden-copy --base "$RD/base" --out "$OUT" --hidden "$TD/hidden" --dest "$H/src" > "$R/copy.json" ||
  die "cannot make the copy (above)"
mapfile -t PKGS < <(python3 -I -c 'import json,sys; print("\n".join(json.load(open(sys.argv[1]))["packages"]))' "$R/copy.json")
[ "${#PKGS[@]}" -ge 1 ] || die "no hidden test package"
mkdir -p "$H/gocache" "$H/gotmp" "$H/tmp"
GC=$H/gocache MC=/home/$U/go/pkg/mod
if [ -n "$TR" ]; then
  GC=${MUSE_TEST_GOCACHE:-$GC} MC=${MUSE_TEST_GOMODCACHE:-$HOMES/$U/go/pkg/mod}
else
  UID_=$(id -u "$U") GID_=$(id -g "$U")
  chown -R "$U:$U" "$H"
  chmod 0700 "$H"
fi
GOV=$("$GO" version 2> /dev/null | head -c 80 || true)
goenv=(env -i "HOME=$HOMES/$U" "PATH=$(dirname "$GO"):/usr/bin:/bin" LANG=C.UTF-8 "GOCACHE=$GC" "GOMODCACHE=$MC"
  "GOTMPDIR=$H/gotmp" "TMPDIR=$H/tmp" GOFLAGS=-mod=readonly GOPROXY=off GOSUMDB=off GOTOOLCHAIN=local GOWORK=off GOENV=off
  GOTELEMETRY=off CGO_ENABLED=0)
offline() {   # CMD...: as the user, no network but loopback, no new privileges; its output goes to the caller's files
  if [ -n "$TR" ]; then
    # shellcheck disable=SC2086  # MUSE_TEST_WRAP is a command line
    (cd "$H/src/maze/app" && ulimit -f 1048576 && ${MUSE_TEST_WRAP:-} "${goenv[@]}" timeout 900 "$@")
  else
    (cd "$H/src/maze/app" && ulimit -f 1048576 && /opt/muse/hide.sh "$U" unshare --net -- sh -c 'ip link set lo up && ip -o link show lo | grep -q "UP" || exit 125; exec "$@"' _ \
      setpriv --reuid="$UID_" --regid="$GID_" --init-groups --no-new-privs --reset-env -- "${goenv[@]}" timeout 900 "$@")
  fi
}
say "hidden tests of $TICKET (tags $TAGS) on $RUN-i$ITER's change: ${PKGS[*]} (as $U, offline)"
t0=$(date +%s.%N)
rc=0
offline "$GO" test -json -count=1 -tags "$TAGS" -timeout 300s "${PKGS[@]}" > "$R/test.json" 2> "$R/test.err" || rc=$?
# 125: the namespace's loopback did not come up: the tests cannot be judged here (a harness error, never the agent's)
[ "$rc" != 125 ] || { say "loopback could not be brought up in the test namespace: cannot judge"; exit 3; }
t1=$(date +%s.%N)
vrc=0
offline "$GO" mod verify > "$R/verify.txt" 2>&1 || vrc=$?
kill_user
# stderr (go's own messages: a module or setup problem) joins the stream the summary reads, as plain lines
sed 's/^/stderr: /' "$R/test.err" | head -c 200000 >> "$R/test.json" || true
[ "$vrc" = 0 ] || say "go mod verify: exit $vrc (recorded as modcache_verified false)"
wall=$(python3 -I -c 'import sys; print(round(float(sys.argv[2]) - float(sys.argv[1]), 1))' "$t0" "$t1")
line=$(python3 -I "$EXPORT" hidden-summary --json "$R/test.json" --rc "$rc" --out "$R/hidden.json" --copy "$R/copy.json" \
  --run "$RUN" --iter "$ITER" --ticket "$TICKET" --arm "$ARM" --verify-rc "$vrc" --strip "$H/src/" --wall "$wall" \
  --go "$GOV") || die "cannot summarise the test output"
cp "$R/hidden.json" "$ID/hidden.json"
[ -n "$TR" ] || chown rbd:rbd "$ID/hidden.json"
echo "$line"
python3 -I -c '
import json, sys
h = json.loads(sys.argv[1])
sys.exit(0 if h["pass"] else 3 if h["error"] else 1)' "$line"
