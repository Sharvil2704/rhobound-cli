#!/usr/bin/env bash
# The four prepared changes: each applies cleanly to repo/ main (git apply --check in a temp clone), carries the request
# make_prs.sh writes, edits what SPEC 6's table says, passes pr-check, and compiles for linux/amd64 with LIB=maze_v11.
# Then make_prs.sh against a local bare repo with a stub gh: branch rbd/<name> from the current main, no force push,
# refusals (public repo, squash allowed, branch exists), an open PR is not re-created, c2 after c1 was merged.
set -uo pipefail
# shellcheck source=tools1/tests/ci/lib.sh
. "$(dirname "$0")/lib.sh"
echo "== changes"
mkenv patches
cp "$HERE/fakebin/gh" "$TROOT/bin/gh"
S=$T/src
mkrepo "$S"
# the kit's make_prs.sh and plant.py beside the fixture changes (make_prs.sh reads changes/NAME next to itself)
CH=$T/changes
mkdir -p "$CH"
cp -a "$HERE/fixtures/changes/." "$CH/"
cp "$KIT/changes/make_prs.sh" "$KIT/changes/plant.py" "$CH/"
GO=${GO:-$(command -v go || echo go)}
CAP=$(cd "$(dirname "$0")/../../.." && pwd)/orch/capped.sh
gobuild() { # gobuild DIR CMD
  (cd "$1/maze/app" && GOTMPDIR=${GOTMPDIR:-${TMPDIR:-/tmp}} GOFLAGS=-mod=readonly GOPROXY=off GOTOOLCHAIN=local GOOS=linux GOARCH=amd64 \
    CGO_ENABLED=0 RB_MEM_MAX=2G GOMAXPROCS=2 bash "$CAP" "$GO" build -trimpath -tags maze_v11 -o "$T/bin-$2" "./cmd/$2")
}
# the builds are offline (GOPROXY=off): the maze's modules come into the cache first, once, from the module proxy (a fresh
# machine has none); the download checks them against go.sum
if [[ -x $GO && -f $CAP ]]; then
  (cd "$S/maze/app" && GOFLAGS=-mod=readonly GOTOOLCHAIN=local "$GO" mod download) > "$T/gomod.log" 2>&1 ||
    echo "  NOTE go mod download failed (no network?): the compile checks below need the maze's modules ($T/gomod.log)"
fi
declare -A WANT=([c1-noop]='^[-+]// Library version 1.1' [c2-auth-small]='^\+.*pbkdf2\.Key\(.*, 6927, 32\)'
  [c3-auth-mid]='^\+.*pbkdf2\.Key\(.*, 20780, 32\)' [c4-pay-wait]='^\+.*time\.Sleep\(15 \* time\.Millisecond\)')
for n in c1-noop c2-auth-small c3-auth-mid c4-pay-wait; do
  p=$CH/$n/change.patch
  git -C "$S" checkout -q main
  check "$n: git apply --check on main" git -C "$S" apply --check "$p"
  check "$n: changes only maze/app/internal/work/lib_v11.go and adds rhobound-change.json" test \
    "$(git -C "$S" apply --numstat "$p" | awk '{print $3}' | tr '\n' ' ')" = "maze/app/internal/work/lib_v11.go rhobound-change.json "
  check "$n: the edit is SPEC 6's (${WANT[$n]})" grep -qE "${WANT[$n]}" "$p"
  if [[ $n == c1-noop ]]; then
    check "c1-noop: every changed code line is a comment" bash -c "! grep -E '^[-+][^-+]' '$p' | grep -v '^[-+]//' | grep -v '^+{\"schema\"' | grep -q ."
  fi
  h=$(branch "$S" "$n" "git apply $p")
  check "$n: the patch's rhobound-change.json = changes/$n/rhobound-change.json" cmp -s "$S/rhobound-change.json" "$CH/$n/rhobound-change.json"
  "$CI/pr-check.sh" "$S" "$(git -C "$S" rev-parse main)" "$h" > "$T/out" 2> "$T/err"
  check "$n: pr-check admits it (service $(fget "$T/out" service))" test "$(fget "$T/out" ok)" = true
  if [[ -x $GO && -f $CAP ]]; then
    gobuild "$S" maze-svc > "$T/go.log" 2>&1
    check "$n: maze-svc compiles (linux/amd64, -tags maze_v11)" test -s "$T/bin-maze-svc"
    rm -f "$T/bin-maze-svc"
  fi
done
git -C "$S" checkout -q main
if [[ -x $GO && -f $CAP ]]; then
  gobuild "$S" maze-load > "$T/go.log" 2>&1
  check "main: maze-load compiles (linux/amd64)" test -s "$T/bin-maze-load"
fi

echo "== make_prs.sh (local bare repo, stub gh)"
BARE=$T/bare.git
git clone -q --bare "$S" "$BARE"
export URL=$BARE WORK=$T/mp
mp() { bash "$CH/make_prs.sh" "$@" > "$T/mp.out" 2> "$T/mp.err"; echo $?; }
rc=$(STUB_GH_VIS=PUBLIC mp c1-noop)
check "refuses a repo that is not private (exit $rc)" bash -c "[ $rc -eq 1 ] && grep -q 'not PRIVATE' '$T/mp.err'"
rc=$(STUB_GH_SQUASH=true mp c1-noop)
check "refuses a repo that allows squash merges (exit $rc)" bash -c "[ $rc -eq 1 ] && grep -q 'merge commits only' '$T/mp.err'"
rc=$(mp c9-nope)
check "refuses an unknown change (exit $rc)" test "$rc" -eq 1
rc=$(mp c1-noop)
check "c1-noop: branch rbd/c1-noop pushed, PR created (exit $rc)" bash -c "[ $rc -eq 0 ] &&
  git -C '$BARE' rev-parse -q --verify refs/heads/rbd/c1-noop > /dev/null && grep -q 'gh pr create --repo Sharvil2704/rhobound-maze-bed --base main --head rbd/c1-noop' '$T/stub/calls.log'"
check "main on the remote is untouched" test "$(git -C "$BARE" rev-parse main)" = "$(git -C "$S" rev-parse main)"
rc=$(mp c1-noop)
check "a second run for c1 refuses: the branch exists (no force push; exit $rc)" bash -c "[ $rc -eq 1 ] && grep -q 'exists on' '$T/mp.err'"
rc=$(STUB_GH_OPEN_PR=https://github.com/Sharvil2704/rhobound-maze-bed/pull/7 mp c1-noop)
check "an open PR for the branch is reported, not re-created (exit $rc)" bash -c "[ $rc -eq 0 ] && grep -q 'already open' '$T/mp.err'"
# merge c1 into main on the remote (a merge commit, as GitHub would), then c2 from the new main
W2=$T/merge
git clone -q "$BARE" "$W2"
git -C "$W2" -c user.name=t -c user.email=t@example.com merge -q --no-ff origin/rbd/c1-noop -m "Merge c1"
git -C "$W2" push -q origin main
rc=$(mp c2-auth-small)
check "c2 on a main that already holds c1's request: applies, request replaced (exit $rc)" bash -c "[ $rc -eq 0 ] &&
  git -C '$BARE' show rbd/c2-auth-small:rhobound-change.json | cmp -s - '$CH/c2-auth-small/rhobound-change.json'"
check "the c2 commit's second parent is not needed: its parent is the merged main" \
  test "$(git -C "$BARE" rev-parse rbd/c2-auth-small^)" = "$(git -C "$BARE" rev-parse main)"
git -C "$W2" fetch -q origin
check "c2's branch merges into main without a conflict" git -C "$W2" -c user.name=t -c user.email=t@example.com merge -q --no-ff origin/rbd/c2-auth-small -m "Merge c2"
check "the merge commit's second parent is the PR head (what deploy.yml reads)" \
  test "$(git -C "$W2" rev-parse HEAD^2)" = "$(git -C "$BARE" rev-parse rbd/c2-auth-small)"
check "the commit carries no co-author trailer" bash -c "! git -C '$BARE' log -1 --format=%B rbd/c2-auth-small | grep -qi '^Co-Authored-By:'"
# a change (prepared or model-written) that reaches outside maze/app/ is refused before any commit or push
CX=$T/ch
cp -a "$CH" "$CX"
X=$T/x
git clone -q "$BARE" "$X"
(cd "$X" && sed -i 's/2500, 32/2600, 32/' maze/app/internal/work/lib_v11.go && echo '# x' >> .github/workflows/gate.yml && git diff) \
  > "$CX/c3-auth-mid/change.patch"
git -C "$X" checkout -q -- .
(cd "$X" && sed -i 's/2500, 32/2600, 32/' maze/app/internal/work/lib_v11.go && sed -i 's/: 5/: 1000/' policy/gate.json && git diff) \
  > "$CX/c4-pay-wait/change.patch"
for n in c3-auth-mid c4-pay-wait; do
  what=.github/workflows/gate.yml
  [[ $n == c4-pay-wait ]] && what=policy/gate.json
  for dry in 0 1; do
    rc=$(DRYRUN=$dry bash "$CX/make_prs.sh" "$n" > "$T/mp.out" 2> "$T/mp.err"; echo $?)
    check "make_prs.sh refuses a patch that touches $what (DRYRUN=$dry; exit $rc, nothing committed or pushed)" bash -c "[ $rc -eq 1 ] &&
      grep -q 'outside maze/app/' '$T/mp.err' && grep -q '$what' '$T/mp.err' && ! git -C '$BARE' rev-parse -q --verify refs/heads/rbd/$n > /dev/null &&
      [ \"\$(git -C '$T/mp/clone' rev-parse rbd/$n)\" = \"\$(git -C '$BARE' rev-parse main)\" ]"
  done
done
done_summary
