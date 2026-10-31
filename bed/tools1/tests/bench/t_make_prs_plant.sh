#!/usr/bin/env bash
# t_make_prs_plant.sh: changes/make_prs.sh for planted changes (cN-plant, SPEC3 F9: changes/plant.py --no-compile in a copy of
# the kit holding the CURRENT repo/) against a local bare repo cut from repo/ with part D's stub gh: DRYRUN commits in the temp
# clone and SAYS the label (rbd-plant) and the draft state, with no label call, push or PR; a real run creates the label
# rbd-plant when missing (never rbd-bench), pushes rbd/cN-plant and opens a DRAFT PR labelled rbd-plant whose body says never
# merge; the request is written as plant.py wrote it; a plant folder without plant.py's manifest is refused; bench changes keep
# their label (rbd-bench) and are never drafts. A plant made with --no-compile is refused unless PLANT_UNCOMPILED=1 (set
# here for the rest); one whose manifest says compiled true (plant.py's production path) is accepted without it; a change.patch
# edited after plant.py wrote it (its sha256 is not the manifest's patch_sha256) is refused either way. A reused name: an open
# PR of rbd/cN-plant is accepted only when it holds exactly the folder's change on its base (also after main moved on); after
# plant.py --force rewrote the folder, or with no such branch, it is refused and nothing is pushed or created.
set -uo pipefail
# shellcheck source=tools1/tests/ci/lib.sh
. "$(dirname "$0")/../ci/lib.sh"
echo "== make_prs.sh: cN-plant"
mkenv patches-plant
cp "$HERE/fakebin/gh" "$TROOT/bin/gh"
K=$T/kit
mkdir -p "$K/changes" "$K/orch" "$K/state"
cp "$KIT/changes/plant.py" "$KIT/changes/make_prs.sh" "$K/changes/"
cp "$KIT/orch/gocheck.sh" "$K/orch/"
cp -r "$KIT/repo" "$K/repo"
printf '%040d\n' 7 > "$K/state/main.sha"
S=$T/src   # main = the current repo/ (the frozen main the plants are cut from)
mkdir -p "$S"
cp -a "$KIT/repo/." "$S/"
git -C "$S" init -q -b main
git -C "$S" add -A
git -C "$S" -c user.name=t -c user.email=t@example.com commit -qm "main"
BARE=$T/bare.git
git clone -q --bare "$S" "$BARE"
export URL=$BARE WORK=$T/mp
unset PLANT_UNCOMPILED DRYRUN
pl() { python3 -I "$K/changes/plant.py" "$@" --no-compile > "$T/pl.out" 2> "$T/pl.err"; echo $?; }
mp() { bash "$K/changes/make_prs.sh" "$@" > "$T/mp.out" 2> "$T/mp.err"; echo $?; }
mset() { # mset NAME KEY JSON: one key of changes/NAME/manifest.json (null: removed)
  python3 -I -c 'import json,sys; p=sys.argv[1]; m=json.load(open(p)); v=json.loads(sys.argv[3])
if v is None: m.pop(sys.argv[2], None)
else: m[sys.argv[2]] = v
open(p, "w").write(json.dumps(m, indent=1) + "\n")' "$K/changes/$1/manifest.json" "$2" "$3"
}
rc=$(pl c30-plant --service payments --mechanism sleep --dose 3)
check "plant.py c30-plant (payments +3 ms sleep, --no-compile; exit $rc)" test "$rc" -eq 0
rc=$(DRYRUN=1 mp c30-plant)
check "a plant never compiled here (--no-compile) is refused before anything (exit $rc)" bash -c "[ $rc -eq 1 ] && grep -q 'never compiled here' '$T/mp.err' &&
  ! grep -q '^gh repo view' '$STUB_DIR/calls.log'"
# the production path: a plant plant.py compiled (manifest compiled true; no PLANT_UNCOMPILED) is accepted
rc=$(pl c33-plant --service payments --mechanism sleep --dose 3)
mset c33-plant compiled true
: > "$STUB_DIR/calls.log"
rc2=$(DRYRUN=1 mp c33-plant)
check "a plant whose manifest says compiled true, no PLANT_UNCOMPILED (production): DRYRUN accepts it (exit $rc $rc2)" bash -c "[ $rc -eq 0 ] && [ $rc2 -eq 0 ] &&
  grep -q 'c33-plant: DRYRUN, not pushed; the PR would be opened with: --label rbd-plant --draft' '$T/mp.err' && ! grep -q 'never compiled' '$T/mp.err'"
check "...no label call, no push, no PR" bash -c "! grep -qE '^gh (label|pr create)' '$STUB_DIR/calls.log' && ! git -C '$BARE' rev-parse -q --verify refs/heads/rbd/c33-plant > /dev/null"
# change.patch edited after plant.py wrote (and compiled) it: refused, whatever compiled says
cp "$K/changes/c33-plant/change.patch" "$T/c33.patch"
sed -i 's/^+const plantHoldFor = 3 \* time.Millisecond$/+const plantHoldFor = 3 * time.Millisecondx/' "$K/changes/c33-plant/change.patch"
: > "$STUB_DIR/calls.log"
rc=$(DRYRUN=1 mp c33-plant)
check "a compiled plant whose change.patch was edited afterwards (sha256 is not the manifest's patch_sha256): refused before any gh call (exit $rc)" bash -c "
  grep -q 'Millisecondx' '$K/changes/c33-plant/change.patch' && [ $rc -eq 1 ] && grep -q 'c33-plant: change.patch changed since changes/plant.py wrote it' '$T/mp.err' &&
  ! grep -qE '^gh (repo view|label|pr create)' '$STUB_DIR/calls.log'"
cp "$T/c33.patch" "$K/changes/c33-plant/change.patch"
mset c33-plant patch_sha256 null
rc=$(DRYRUN=1 mp c33-plant)
check "...a manifest without patch_sha256: refused the same way (exit $rc)" bash -c "[ $rc -eq 1 ] && grep -q 'c33-plant: change.patch changed since changes/plant.py wrote it' '$T/mp.err'"
export PLANT_UNCOMPILED=1   # tests only: the rest uses --no-compile plants
cp "$K/changes/c30-plant/change.patch" "$T/c30.patch"
printf '%s\n' '+// an extra line' >> "$K/changes/c30-plant/change.patch"
rc=$(DRYRUN=1 mp c30-plant)
check "...the patch check holds under PLANT_UNCOMPILED=1 too (c30-plant, a line added to its patch; exit $rc)" bash -c "[ $rc -eq 1 ] && grep -q 'c30-plant: change.patch changed since changes/plant.py wrote it' '$T/mp.err'"
cp "$T/c30.patch" "$K/changes/c30-plant/change.patch"

rc=$(DRYRUN=1 mp c30-plant)
check "DRYRUN=1: exit 0, the change committed in the temp clone (title from title.txt)" bash -c "[ $rc -eq 0 ] &&
  [ \"\$(git -C '$T/mp/clone' log -1 --format=%s rbd/c30-plant)\" = 'c30-plant: PLANT do-not-merge: payments RiskCheck +3 ms sleep' ]"
check "...the dry run says the PR's label and draft state: --label rbd-plant --draft" grep -q 'c30-plant: DRYRUN, not pushed; the PR would be opened with: --label rbd-plant --draft' "$T/mp.err"
check "...no label call, no push, no PR" bash -c "! grep -qE '^gh (label|pr create)' '$STUB_DIR/calls.log' && ! git -C '$BARE' rev-parse -q --verify refs/heads/rbd/c30-plant > /dev/null"
check "...the commit = the patch's code (lib_v11.go, plant.go) + rhobound-change.json as plant.py wrote it" bash -c "
  [ \"\$(git -C '$T/mp/clone' diff --name-only main rbd/c30-plant | tr '\n' ' ')\" = 'kshop/app/internal/work/lib_v11.go kshop/app/internal/work/plant.go rhobound-change.json ' ] &&
  git -C '$T/mp/clone' show rbd/c30-plant:rhobound-change.json | cmp -s - '$K/changes/c30-plant/rhobound-change.json'"

: > "$STUB_DIR/calls.log"
rc=$(STUB_GH_LABELS='[{"name": "rbd-bench"}]' mp c30-plant)
check "c30-plant: pushed, PR created (exit $rc)" bash -c "[ $rc -eq 0 ] && git -C '$BARE' rev-parse -q --verify refs/heads/rbd/c30-plant > /dev/null"
check "...the label rbd-plant is created when missing (and rbd-bench is not touched)" bash -c "grep -q '^gh label create rbd-plant --repo Sharvil2704/rhobound-demo --color b60205 --description rbd planted change' '$STUB_DIR/calls.log' &&
  ! grep -q '^gh label create rbd-bench' '$STUB_DIR/calls.log'"
check "...gh pr create: the title from title.txt, then --label rbd-plant --draft (after the multi-line body)" bash -c "
  grep -q '^gh pr create --repo Sharvil2704/rhobound-demo --base main --head rbd/c30-plant --title c30-plant: PLANT do-not-merge: payments RiskCheck +3 ms sleep --body ' '$STUB_DIR/calls.log' &&
  grep -q 'Generated with .* --label rbd-plant --draft\$' '$STUB_DIR/calls.log' && ! grep -q 'rbd-bench' <(grep -A30 '^gh pr create' '$STUB_DIR/calls.log')"
check "...the PR body says never merge, the rbd-plant refusal and the dose rule" bash -c "grep -q 'NEVER merge it: a draft labelled rbd-plant, which orch/automerge.sh refuses whatever its verdict' '$STUB_DIR/calls.log' &&
  grep -q 'Planted change .changes/c30-plant. (SPEC3 F9, changes/plant.py: sleep at payments RiskCheck, top of RiskCheck' '$STUB_DIR/calls.log' &&
  grep -q 'registered dose is the A/B-measured own-time delta, not the knob' '$STUB_DIR/calls.log'"
check "...main on the remote is untouched" test "$(git -C "$BARE" rev-parse main)" = "$(git -C "$S" rev-parse main)"

# a reused name: the open PR of rbd/c30-plant must hold exactly changes/c30-plant's change on its base
B0=$(git -C "$BARE" rev-parse rbd/c30-plant)
OPEN=https://github.com/Sharvil2704/rhobound-demo/pull/77
export STUB_GH_LABELS='[{"name": "rbd-plant"}]'   # the open PR's label exists
: > "$STUB_DIR/calls.log"
rc=$(STUB_GH_OPEN_PR=$OPEN mp c30-plant)
check "c30-plant open, its folder unchanged: 'already open with this same change', exit 0, nothing pushed or created (exit $rc)" bash -c "[ $rc -eq 0 ] &&
  grep -q 'c30-plant: already open with this same change: $OPEN' '$T/mp.err' && ! grep -qE '^gh (pr create|label create)' '$STUB_DIR/calls.log' &&
  [ \"\$(git -C '$BARE' rev-parse rbd/c30-plant)\" = '$B0' ]"
echo "another change on main" > "$S/NOTES.txt"
git -C "$S" add NOTES.txt && git -C "$S" -c user.name=t -c user.email=t@example.com commit -qm "main moves on" && git -C "$S" push -q "$BARE" main
rc=$(STUB_GH_OPEN_PR=$OPEN mp c30-plant)
check "...main moved on since the PR was opened: still the same change on the PR's base (exit $rc)" bash -c "[ $rc -eq 0 ] && grep -q 'c30-plant: already open with this same change' '$T/mp.err' &&
  [ \"\$(git -C '$BARE' rev-parse main)\" = \"\$(git -C '$S' rev-parse main)\" ]"
rc=$(pl c30-plant --service payments --mechanism sleep --dose 9 --force)
: > "$STUB_DIR/calls.log"
rc2=$(STUB_GH_OPEN_PR=$OPEN mp c30-plant)
check "plant.py --force rewrote c30-plant (+9 ms) while its PR (+3 ms) is open: refused, exit 1 (exit $rc $rc2)" bash -c "[ $rc -eq 0 ] && [ $rc2 -eq 1 ] &&
  grep -q 'c30-plant: already open with ANOTHER change ($OPEN): rbd/c30-plant is not changes/c30-plant' '$T/mp.err' && grep -q 'use a new name' '$T/mp.err'"
check "...nothing pushed or created: the open PR's branch still holds the old patch (3 ms), the manifest says 9 ms" bash -c "! grep -qE '^gh (pr create|label create)' '$STUB_DIR/calls.log' &&
  [ \"\$(git -C '$BARE' rev-parse rbd/c30-plant)\" = '$B0' ] && git -C '$BARE' show rbd/c30-plant:kshop/app/internal/work/plant.go | grep -q 'plantHoldFor = 3 \* time.Millisecond' &&
  grep -q '\"hold_ms\": 9.0' '$K/changes/c30-plant/manifest.json'"
rc=$(DRYRUN=1 STUB_GH_OPEN_PR=$OPEN mp c30-plant)
check "...under DRYRUN too (exit $rc)" bash -c "[ $rc -eq 1 ] && grep -q 'already open with ANOTHER change' '$T/mp.err'"
rc=$(pl c34-plant --service inventory --mechanism noop)
rc2=$(STUB_GH_OPEN_PR=$OPEN mp c34-plant)
check "an open PR is reported for rbd/c34-plant but the branch is not on the remote: cannot be checked, refused (exit $rc $rc2)" bash -c "[ $rc -eq 0 ] && [ $rc2 -eq 1 ] &&
  grep -q 'c34-plant: already open with ANOTHER change' '$T/mp.err' && ! git -C '$BARE' rev-parse -q --verify refs/heads/rbd/c34-plant > /dev/null"
unset STUB_GH_LABELS

: > "$STUB_DIR/calls.log"
rc=$(pl c31-plant --service catalog --mechanism spin --dose 6)
rc2=$(STUB_GH_LABELS='[{"name": "rbd-plant"}, {"name": "rbd-bench"}]' mp c31-plant)
check "c31-plant (catalog spin, a hot/*.go change on the current main): applied and opened (exit $rc $rc2)" bash -c "[ $rc -eq 0 ] && [ $rc2 -eq 0 ] &&
  git -C '$BARE' show rbd/c31-plant:kshop/app/internal/hot/plant.go | grep -q 'plantSpinCPU = 6 \* time.Millisecond'"
check "...an existing rbd-plant label is not created again" bash -c "! grep -q '^gh label create' '$STUB_DIR/calls.log'"

# a plant folder whose manifest is not plant.py's (or says never_merge false) is refused before anything
mkdir -p "$K/changes/c32-plant"
cp "$K/changes/c30-plant/change.patch" "$K/changes/c30-plant/rhobound-change.json" "$K/changes/c30-plant/title.txt" "$K/changes/c32-plant/"
for m in '{"schema": "rbd.agent-change/v1", "name": "c32-plant"}' '{"schema": "rbd.plant-change/v1", "name": "c32-plant", "never_merge": false}' \
  '{"schema": "rbd.plant-change/v1", "name": "c30-plant", "never_merge": true}'; do
  printf '%s\n' "$m" > "$K/changes/c32-plant/manifest.json"
  : > "$STUB_DIR/calls.log"
  rc=$(mp c32-plant)
  check "refused: c32-plant with manifest $m (exit $rc, no gh repo call)" bash -c "[ $rc -eq 1 ] && grep -q 'manifest.json is not changes/plant.py' '$T/mp.err' && ! grep -q '^gh repo view' '$STUB_DIR/calls.log'"
done
rm -f "$K/changes/c32-plant/manifest.json"
rc=$(mp c32-plant)
check "refused: a plant without manifest.json (exit $rc)" test "$rc" -eq 1
rm -f "$K/changes/c32-plant/title.txt"
rc=$(mp c32-plant)
check "refused: a plant without title.txt is an unknown change (exit $rc)" bash -c "[ $rc -eq 1 ] && grep -q \"unknown change 'c32-plant'\" '$T/mp.err'"

# bench changes keep their label and are never drafts
mkdir -p "$K/changes/c9-bench"
: > "$K/changes/c9-bench/change.patch"   # a base-only bench change (no code part)
printf '%s\n' '{"schema": "rbd.change-request/v2", "services": ["catalog", "pricing"], "summary": "builder to go 1.27", "base": "go127"}' > "$K/changes/c9-bench/rhobound-change.json"
echo "bench pick" > "$K/changes/c9-bench/title.txt"
rc=$(DRYRUN=1 mp c9-bench)
check "a bench change under DRYRUN: says --label rbd-bench, no --draft (exit $rc)" bash -c "[ $rc -eq 0 ] && grep -q 'c9-bench: DRYRUN, not pushed; the PR would be opened with: --label rbd-bench\$' '$T/mp.err'"
: > "$STUB_DIR/calls.log"
rc=$(STUB_GH_LABELS='[{"name": "rbd-bench"}]' mp c9-bench)
check "...a real run: --label rbd-bench, never --draft, no rbd-plant label made (exit $rc)" bash -c "[ $rc -eq 0 ] && grep -q 'Generated with .* --label rbd-bench\$' '$STUB_DIR/calls.log' &&
  ! grep -qE -- '--draft|rbd-plant' '$STUB_DIR/calls.log'"
check "nothing forbidden ran (aws, docker, kubectl: no stub calls)" bash -c "! grep -qE '^(aws|docker|kubectl|cosign) ' '$STUB_DIR/calls.log'"
done_summary
