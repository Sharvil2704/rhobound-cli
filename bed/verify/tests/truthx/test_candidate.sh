#!/usr/bin/env bash
# Offline tests of candidate.sh against a fake tools1 (runs/HEAD as tools1/ci/pr-check.sh and build.sh write it). Nothing
# reaches a cluster or AWS. usage: bash test_candidate.sh   (scratch under VERIFY_SCRATCH [$RBD_SCRATCH/verify])
set -uo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
V=$(cd "$HERE/../.." && pwd)
SCR=${VERIFY_SCRATCH:-${RBD_SCRATCH:-${TMPDIR:-/tmp}/rbd}/verify}
mkdir -p "$SCR"
ECR=registry.example.invalid/rhobound-demo/maze
dg() { echo "sha256:$(printf '%s' "$1" | sha256sum | cut -d' ' -f1)"; }
sha() { printf '%s' "$1" | sha1sum | cut -d' ' -f1; }
H=$(sha head1); MAIN=$(sha main); D=$(dg img1); BASE=$(dg base)
fails=0; n=0
ok() { n=$((n + 1)); echo "ok   $n $*"; }
bad() { n=$((n + 1)); fails=$((fails + 1)); echo "FAIL $n $*"; }
check() { local what=$1; shift; if "$@"; then ok "$what"; else bad "$what"; fi; }

setup() {   # a fresh tools1 in $T; runs/$H/ empty
  T=$(mktemp -d "$SCR/cand-XXXXXX")
  mkdir -p "$T/lib" "$T/home/runs/$H/logs" "$T/home/src"
  echo "export RBD_HOME=$T/home RBD_ECR=$ECR RBD_ACCOUNT=acct-example" > "$T/lib/rbd-env.sh"
  echo "$MAIN" > "$T/home/src/main.sha"
  R=$T/home/runs/$H
}
pr() {   # pr SVC...: pr-check's record of the change request
  jq -n --arg h "$H" --arg m "$MAIN" '{schema: "rbd.pr-check/v1", request_schema: "rbd.change-request/v2", head_sha: $h,
    base_sha: $m, service: $ARGS.positional[0], services: $ARGS.positional, base: null, base_image: null}' --args "$@" > "$R/pr.json"
}
cand() {   # cand SVC DIGEST SVCS-CSV [GIT_SHA [IMAGE]]: build.sh's candidate-SVC.json
  jq -n --arg s "$1" --arg d "$2" --arg l "$3" --arg g "${4:-$H}" --arg i "${5:-$ECR@$2}" --arg b "$BASE" '{schema: "rbd.candidate/v1",
    service: $s, services: ($l | split(",")), git_sha: $g, tag: "\($s)-\($g)", digest: $d, image: $i, baseline_digest: $b,
    baselines: {}, lib: "maze_v11", base: null, go_image: null, built_at: "2026-11-02T14:42:25Z"}' > "$R/.c.tmp" && mv "$R/.c.tmp" "$R/candidate-$1.json"
}
built() {   # built SVC... : every record, then candidate.json (the first service's), as build.sh writes them
  local l s; l=$(IFS=,; echo "$*")
  for s in "$@"; do cand "$s" "$D" "$l"; done
  cp "$R/candidate-$1.json" "$R/.cj.tmp" && mv "$R/.cj.tmp" "$R/candidate.json"
}
run() {   # run ARGS...: candidate.sh; stdout -> $T/out, stderr -> $T/err, exit -> RC
  env RBD_LIB="$T/lib" RBD_CAND_POLL=1 "$V/candidate.sh" "$@" > "$T/out" 2> "$T/err"
  RC=$?
}
snap() { (cd "$R" && find . -printf '%p %s %T@ %m\n' | sort && find . -type f ! -name .lock -exec sha256sum {} + | sort); }

# 1. finished build of a two-service change: one line per service, in pr.json's order; nothing in runs/HEAD changes
setup; pr index-b index-a; built index-b index-a; : > "$R/.lock"
before=$(snap)
run "$H" --wait 0
check "built: exit 0 ($RC)" test "$RC" = 0
check "built: SVC=DIGEST lines in the change's order" test "$(cat "$T/out")" = "index-b=$D"$'\n'"index-a=$D"
check "built: every stdout line is SVC=sha256:<64 hex>" test "$(grep -cvE '^[a-z][a-z0-9-]*=sha256:[0-9a-f]{64}$' "$T/out")" = 0
check "built: runs/HEAD unchanged (read-only)" test "$(snap)" = "$before"
check "built: the build time on stderr" grep -q "built 2026-11-02T14:42:25Z" "$T/err"

# 2. the build finishes while candidate.sh waits (records written 2 s later, candidate.json last)
setup; pr web
( sleep 2; built web ) &
w=$!
t0=$SECONDS
run "$H" --wait 30
wait "$w"
check "delayed build: exit 0 after the records appear ($RC, $((SECONDS - t0)) s)" test "$RC" = 0 -a $((SECONDS - t0)) -ge 2
check "delayed build: the line" test "$(cat "$T/out")" = "web=$D"
check "delayed build: said what it waits for" grep -q "waiting: .*pr.json\|waiting: .*has not finished" "$T/err"

# 3. a CI step holds runs/HEAD/.lock (mode 000 after it opened it): candidate.sh never opens it, so it still answers
setup; pr web; built web; : > "$R/.lock"
flock "$R/.lock" sleep 10 &
holder=$!; sleep 0.3; chmod 000 "$R/.lock"
run "$H" --wait 0
check "lock held by a CI step: exit 0 anyway ($RC)" test "$RC" = 0
check "lock held by a CI step: the holder still holds it" kill -0 "$holder"
kill "$holder" 2> /dev/null; wait "$holder" 2> /dev/null; chmod 600 "$R/.lock"

# 4. the build ran and failed: its log, no candidate.json, the lock free -> exit 1 at once, the log tail redacted
setup; pr web; : > "$R/.lock"
acct=$(printf '%012d' 42)
printf 'step 1\npush to %s.dkr.ecr.example/x for acct-example\nERROR: docker build failed\n' "$acct" > "$R/logs/build-web.log"
t0=$SECONDS
run "$H" --wait 30
check "failed build: exit 1 without waiting ($RC, $((SECONDS - t0)) s)" test "$RC" = 1 -a $((SECONDS - t0)) -lt 5
check "failed build: message" grep -q "ended without a candidate" "$T/err"
check "failed build: the log tail on stderr" grep -q "ERROR: docker build failed" "$T/err"
check "failed build: account redacted" test "$(grep -c "$acct\|acct-example" "$T/err") $(grep -c '<account>.dkr.ecr' "$T/err")" = "0 1"
check "failed build: stdout empty" test ! -s "$T/out"

# 5. the build is still running (its log, the lock held): waits, then times out (exit 4)
setup; pr web; : > "$R/.lock"; echo "building" > "$R/logs/build-web.log"
flock "$R/.lock" sleep 10 &
holder=$!; sleep 0.3; chmod 000 "$R/.lock"   # seen through /proc/locks only: an open of it would fail
run "$H" --wait 2
kill "$holder" 2> /dev/null; wait "$holder" 2> /dev/null; chmod 600 "$R/.lock"
check "build running: timed out, exit 4 ($RC)" test "$RC" = 4
check "build running: says so" grep -q "timed out after 2s: the build step .* has not finished" "$T/err"
check "build running: the log tail" grep -q "building" "$T/err"

# 5b. a gate re-run after a failed build: pr-check rewrote pr.json, the old build log is older, the lock free between the
#     steps -> not a failure yet (waits; times out here)
setup; pr web; : > "$R/.lock"; echo "ERROR: docker build failed" > "$R/logs/build-web.log"
touch -d '-1 min' "$R/logs/build-web.log"
run "$H" --wait 2
check "re-run, old build log older than pr.json: waits, exit 4 not 1 ($RC)" test "$RC" = 4
touch "$R/logs/build-web.log"
run "$H" --wait 2
check "then the new build's log (newer than pr.json), lock free: failed, exit 1 ($RC)" test "$RC" = 1

# 6. no pr.json (the gate has not reached pr-check, or refused it)
setup
run "$H" --wait 0
check "no pr.json: exit 4 ($RC)" test "$RC" = 4
check "no pr.json: says pr-check" grep -q "pr-check has not admitted" "$T/err"

# 7. records that disagree -> exit 1
setup; pr web; cand web "$D" web "$(sha other)"; cp "$R/candidate-web.json" "$R/candidate.json"
run "$H" --wait 0; check "git_sha mismatch: exit 1 ($RC)" test "$RC" = 1
check "git_sha mismatch: message" grep -q "not web at $H" "$T/err"
setup; pr web; built web
jq --arg h "$(sha other)" '.head_sha = $h' "$R/pr.json" > "$R/p" && mv "$R/p" "$R/pr.json"
run "$H" --wait 0; check "pr.json head_sha mismatch: exit 1 ($RC)" test "$RC" = 1
setup; pr web auth; cand web "$D" web,auth; cp "$R/candidate-web.json" "$R/candidate.json"
run "$H" --wait 0; check "candidate.json but a service's record missing: exit 1 ($RC)" test "$RC" = 1
setup; pr web; cand web "$D" web "$H" "other.example/maze@$D"; cp "$R/candidate-web.json" "$R/candidate.json"
run "$H" --wait 0; check "image not RBD_ECR@digest: exit 1 ($RC)" test "$RC" = 1
setup; pr web; cand web sha256:abc web; cp "$R/candidate-web.json" "$R/candidate.json"
run "$H" --wait 0; check "bad digest: exit 1 ($RC)" test "$RC" = 1
setup; pr web; cand web "$BASE" web; cp "$R/candidate-web.json" "$R/candidate.json"
run "$H" --wait 0; check "candidate = production's digest: exit 1 ($RC)" test "$RC" = 1
setup; pr web auth; cand web "$D" web; cand auth "$D" web,auth; cp "$R/candidate-web.json" "$R/candidate.json"
run "$H" --wait 0; check "a record's services differ from pr.json's: exit 1 ($RC)" test "$RC" = 1
setup; echo '{not json' > "$R/pr.json"
run "$H" --wait 0; check "pr.json not JSON: exit 1 ($RC)" test "$RC" = 1
check "nothing printed on any refusal" test ! -s "$T/out"

# 8. usage, main's own commit
setup
run; check "no HEAD: usage 2 ($RC)" test "$RC" = 2
run abc; check "short HEAD: usage 2 ($RC)" test "$RC" = 2
run "$H" --wait x; check "bad --wait: usage 2 ($RC)" test "$RC" = 2
run "$H" --poll 0; check "--poll 0: usage 2 ($RC)" test "$RC" = 2
run "$H" "$H"; check "two HEADs: usage 2 ($RC)" test "$RC" = 2
run "$MAIN" --wait 0; check "main's commit refused ($RC)" test "$RC" = 1
check "main's commit: message" grep -q "src/main.sha" "$T/err"

echo "$((n - fails))/$n passed"
if ((fails == 0)) && [[ -z ${VERIFY_KEEP:-} ]]; then rm -rf "$SCR"/cand-*; fi
((fails == 0))
