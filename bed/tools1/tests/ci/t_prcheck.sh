#!/usr/bin/env bash
# pr-check.sh on a temp git repo (repo/ as main): an allowed PR and the refused ones. Then the runner-owned .git/ (round-1
# recheck finding 1): its config, hooks, includes, attributes and replace refs, and the caller's GIT_* environment, run and
# change nothing (an rbd-owned bare repository borrows the checkout's objects); the per-run lock; the policy's bytes. CI v2:
# rbd.change-request/v2 (1..5 services, an optional base key of the kit's bases.json; a request-only PR only with a base).
set -uo pipefail
# shellcheck source=tools1/tests/ci/lib.sh
. "$(dirname "$0")/lib.sh"
echo "== pr-check"
mkenv prcheck
S=$T/src
mkrepo "$S"
BASE=$(git -C "$S" rev-parse main)
CH=$KIT/changes

run() { "$CI/pr-check.sh" "$S" "$BASE" "$1" > "$T/out" 2> "$T/err"; echo $?; }
refused() { # refused DESC HEAD EXPECTED-TEXT
  local rc; rc=$(run "$2")
  if [[ $rc -eq 1 ]] && [[ $(fget "$T/out" ok) == false ]] && grep -q -- "$3" "$T/err"; then ok "refuses $1 ($(fget "$T/out" error | cut -c1-90))"
  else bad "refuses $1: rc=$rc out=$(cat "$T/out") err=$(cat "$T/err")"; fi
}

H=$(branch "$S" ok "git apply $CH/c2-auth-small/change.patch")
rc=$(run "$H")
check "admits c2-auth-small (exit $rc, service $(fget "$T/out" service))" test "$rc" -eq 0 -a "$(fget "$T/out" service)" = auth
check "writes runs/HEAD/pr.json (service, summary, 2 files)" python3 -I -c '
import json,sys; d=json.load(open(sys.argv[1])); sys.exit(not (d["service"]=="auth" and d["summary"] and len(d["files"])==2))' "$THOME/runs/$H/pr.json"
check "snapshots policy/gate.json of BASE as runs/HEAD/policy.json" cmp -s "$THOME/runs/$H/policy.json" "$REPO0/policy/gate.json"
H4=$(branch "$S" ok4 "git apply $CH/c4-pay-wait/change.patch")
rc=$(run "$H4")
check "admits c4-pay-wait (service $(fget "$T/out" service))" test "$rc" -eq 0 -a "$(fget "$T/out" service)" = payments

req() { printf '%s' "$1" > rhobound-change.json; }
export -f req
H=$(branch "$S" r1 "git apply $CH/c2-auth-small/change.patch; sed -i 's/: 5/: 500/' policy/gate.json")
refused "a policy edit" "$H" "files outside"
H=$(branch "$S" r2 "git apply $CH/c2-auth-small/change.patch; echo '# x' >> .github/workflows/gate.yml")
refused "a workflow edit" "$H" "files outside"
H=$(branch "$S" r3 "git apply --exclude=rhobound-change.json $CH/c2-auth-small/change.patch")
refused "a PR without rhobound-change.json" "$H" "no rhobound-change.json"
H=$(branch "$S" r4 "req '{\"schema\": \"rbd.change-request/v1\", \"services\": [\"auth\", \"payments\"], \"summary\": \"two\"}'")
refused "two services" "$H" "exactly one service"
H=$(branch "$S" r5 "req '{\"schema\": \"rbd.change-request/v1\", \"services\": [\"billing\"], \"summary\": \"x\"}'")
refused "an unknown service" "$H" "unknown service"
H=$(branch "$S" r6 "req '{\"schema\": \"rbd.change-request/v1\", \"services\": [\"auth\"], \"summary\": \"  \"}'")
refused "an empty summary" "$H" "non-empty"
H=$(branch "$S" r7 "req '{\"schema\": \"rbd.change-request/v3\", \"services\": [\"auth\"], \"summary\": \"x\"}'")
refused "a wrong schema (v3)" "$H" "schema"
H=$(branch "$S" r8 "req '{\"schema\": \"rbd.change-request/v1\", \"services\": [\"auth\"], \"summary\": \"x\", \"deploy\": true}'")
refused "an unknown key" "$H" "unknown keys"
H=$(branch "$S" r9 "req 'not json'")
refused "a request that is not JSON" "$H" "not JSON"
H=$(branch "$S" r10 "ln -s /var/lib/rbd/mcp/token rhobound-change.json")
refused "rhobound-change.json as a symlink" "$H" "symlinks"
H=$(branch "$S" r11 "cp $CH/c2-auth-small/rhobound-change.json .; ln -s /etc/passwd kshop/app/x.go")
refused "a symlink under kshop/app" "$H" "symlinks"
# VCS metadata: go build's VCS stamping would run that tool on it in the build container (round-2 recheck A)
H=$(branch "$S" r12 "cp $CH/c2-auth-small/rhobound-change.json .; mkdir -p kshop/app/.hg; echo '[ui]' > kshop/app/.hg/hgrc")
refused "a .hg folder under kshop/app" "$H" "VCS metadata"
H=$(branch "$S" r13 "cp $CH/c2-auth-small/rhobound-change.json .; mkdir -p kshop/app/internal/.svn; echo x > kshop/app/internal/.svn/entries")
refused "a nested .svn folder under kshop/app" "$H" "VCS metadata"
H=$(branch "$S" r14 "cp $CH/c2-auth-small/rhobound-change.json .; echo x > kshop/app/_FOSSIL_")
refused "a fossil checkout marker under kshop/app" "$H" "VCS metadata"
# the policy is pinned (RBD_POLICY_SHA256): a BASE_SHA of the caller's choosing with a lax policy is refused even when the
# diff BASE...HEAD shows only kshop/app (a PR's edited workflow passing its own commit as BASE_SHA)
L=$(branch "$S" lax "sed -i 's/: 5/: 1000/' policy/gate.json")
(cd "$S" && git apply "$CH/c2-auth-small/change.patch")
git -C "$S" add -A
git -C "$S" -c user.name=t -c user.email=t@example.com commit -qm lax-head
HL=$(git -C "$S" rev-parse HEAD)
BASE0=$BASE BASE=$L
refused "a BASE_SHA whose policy/gate.json is not the pinned policy (the diff shows kshop/app only)" "$HL" "not the pinned policy"
BASE=$BASE0
check "  and writes no runs/HEAD/policy.json for it (nor a temporary file)" bash -c "[ ! -e '$THOME/runs/$HL/policy.json' ] &&
  [ -z \"\$(ls -A '$THOME/runs/$HL' | grep -v '^\.lock\$')\" ] && [ -z \"\$(ls -A '$THOME/tmp')\" ]"
H=$(branch "$S" okpin "git apply $CH/c2-auth-small/change.patch")
setpin
refused "any PR when RBD_POLICY_SHA256 is not set in rbd.env" "$H" "RBD_POLICY_SHA256"
setpin "${PIN:0:63}"
refused "any PR when RBD_POLICY_SHA256 is not 64 hex" "$H" "RBD_POLICY_SHA256"
setpin "$(printf other | sha256sum | cut -d' ' -f1)"
refused "main's own policy when the pin names another policy" "$H" "not the pinned policy"
setpin "$PIN"
rc=$(run "$H")
check "admits it again with the pin = sha256 of repo/policy/gate.json (exit $rc)" test "$rc" -eq 0
# a request already on main (an earlier merged PR) and a PR that does not update it
git -C "$S" checkout -q main
git -C "$S" apply "$CH/c1-noop/change.patch"
git -C "$S" add -A
git -C "$S" -c user.name=t -c user.email=t@example.com commit -qm "merge c1"
BASE=$(git -C "$S" rev-parse main)
H=$(branch "$S" r12 "sed -i 's/2500, 32/2600, 32/' kshop/app/internal/work/lib_v11.go")
refused "a stale request left on main by an earlier PR" "$H" "must add or update"
H=$(branch "$S" ok5 "git apply --exclude=rhobound-change.json $CH/c2-auth-small/change.patch; cp $CH/c2-auth-small/rhobound-change.json .")
rc=$(run "$H")
check "admits c2 on a main that already holds c1's request (exit $rc)" test "$rc" -eq 0
# everything is read by sha, never through the checkout's HEAD: a working tree at main still gets HEAD_SHA's files
git -C "$S" checkout -q main
rc=$(run "$H")
check "a checkout whose working tree is at main: HEAD_SHA's objects are what is checked (exit $rc, 2 files)" python3 -I -c '
import json,sys; d=json.load(open(sys.argv[1])); sys.exit(not (d["head_sha"]==sys.argv[2] and len(d["files"])==2))' \
  "$THOME/runs/$H/pr.json" "$H"
refused "a HEAD_SHA that is not a commit in the checkout" "$(printf nocommit | sha1sum | cut -d' ' -f1)" "is not a commit in"
refused "a HEAD_SHA that is not 40 hex" "abc" "40-hex"
"$CI/pr-check.sh" "$S" "0123456789012345678901234567890123456789" "$(git -C "$S" rev-parse HEAD)" > "$T/out" 2> "$T/err"
rc=$?
check "refuses a BASE_SHA missing from the checkout (exit $rc)" test "$rc" -eq 1
check "every refusal printed exactly one JSON object last" python3 -I -c 'import json,sys; json.loads(open(sys.argv[1]).read().splitlines()[-1])' "$T/out"
# ---- the runner-owned .git/ (round-1 recheck1 finding 1 / recheck2 finding 3): nothing it names runs as rbd ----
M=$T/marks
git -C "$S" checkout -q main
C2="git apply --exclude=rhobound-change.json $CH/c2-auth-small/change.patch; cp $CH/c2-auth-small/rhobound-change.json ."
HA=$(branch "$S" attrs "$C2; printf '* filter=evil diff=evil\n' > kshop/app/.gitattributes")
HB=$(branch "$S" badwf "$C2; echo '# x' >> .github/workflows/gate.yml")
HG=$(branch "$S" goodc2 "$C2")
X=$T/hostile
git clone -q "$S" "$X"
hostile_git "$X" "$M"
rm -rf "$M" && mkdir -p "$M"
NOBASE=0000000000000000000000000000000000000001
hrun() { "$CI/pr-check.sh" "$@" > "$T/out" 2> "$T/err"; echo $?; }
clean() { # clean RC WANT [STDERR-TEXT]: exit WANT, the text on stderr, and no hostile command ran
  [[ $1 -eq $2 ]] && nomarks "$M" && { [[ -z ${3:-} ]] || grep -q -- "$3" "$T/err"; }
}
rc=$(hrun "$X" "$NOBASE" "$HA")
check "recheck1 PoC (poc_prcheck_rce.sh): a partial-clone uploadpack + a BASE_SHA missing from the checkout: refused, nothing ran (exit $rc, marks: $(marks "$M"))" \
  clean "$rc" 1 'is not in the checkout'
check "  (the same config does run the uploadpack for a plain 'git -C CHECKOUT cat-file': the attack is real)" bash -c "
  git -C '$X' cat-file -e $NOBASE^{commit} 2> /dev/null; [ -e '$M/uploadpack' ]"
rm -rf "$M" && mkdir -p "$M"
rc=$(hrun "$X" "$BASE" "$HA")
check "every hostile key, hook, include and attribute (fsmonitor, hooksPath, pager, sshCommand, alternateRefsCommand, diff and filter drivers, a committed kshop/app/.gitattributes): admitted, nothing ran (exit $rc, marks: $(marks "$M"))" \
  clean "$rc" 0 'pr-check: ok'
rc=$(hostile_env "$M" "$X" "$CI/pr-check.sh" "$X" "$NOBASE" "$HA" > "$T/out" 2> "$T/err"; echo $?)
check "the caller's GIT_CONFIG_COUNT/GIT_CONFIG_PARAMETERS/GIT_DIR (an uploadpack, an fsmonitor) with a missing BASE_SHA: refused, nothing ran (exit $rc)" \
  clean "$rc" 1 'is not in the checkout'
rc=$(hostile_env "$M" "$X" "$CI/pr-check.sh" "$X" "$BASE" "$HA" > "$T/out" 2> "$T/err"; echo $?)
check "  and with the PR's real BASE_SHA: admitted, nothing ran (exit $rc)" clean "$rc" 0
# replace refs in the checkout: git itself would show HG's diff for HB; the step reads HB as committed
Y=$T/replaced
git clone -q "$S" "$Y"
git -C "$Y" replace "$HB" "$HG"
check "  (in the checkout itself refs/replace makes HB read as HG: only kshop/app and the request)" bash -c "
  ! git -C '$Y' diff --name-only '$BASE...$HB' | grep -q '^.github/'"
rc=$(hrun "$Y" "$BASE" "$HB")
check "a refs/replace/ in the checkout does not change what HEAD_SHA is: the workflow edit is refused (exit $rc)" \
  bash -c "[ $rc -eq 1 ] && grep -q 'files outside' '$T/err'"
# what CHECKOUT/.git may be: a real folder with a real objects/ and no alternates of its own
Z=$T/gitfile
mkdir -p "$Z"
printf 'gitdir: %s/.git\n' "$S" > "$Z/.git"
rc=$(hrun "$Z" "$BASE" "$HG")
check "refuses a .git that is a 'gitdir:' file (exit $rc)" bash -c "[ $rc -eq 1 ] && grep -q \"gitdir:' file\" '$T/err'"
rm -f "$Z/.git" && ln -s "$S/.git" "$Z/.git"
rc=$(hrun "$Z" "$BASE" "$HG")
check "refuses a .git that is a symlink (exit $rc)" bash -c "[ $rc -eq 1 ] && grep -q 'symlinked .git' '$T/err'"
O=$T/objlink
git clone -q "$S" "$O"
rm -rf "$O/.git/objects" && ln -s "$S/.git/objects" "$O/.git/objects"
rc=$(hrun "$O" "$BASE" "$HG")
check "refuses a .git/objects that is a symlink out of the checkout (exit $rc)" bash -c "[ $rc -eq 1 ] && grep -q 'symlinked .git or objects' '$T/err'"
A=$T/shared
git clone -q --shared "$S" "$A"
rc=$(hrun "$A" "$BASE" "$HG")
check "refuses a checkout whose objects/info/alternates borrows other objects (exit $rc)" bash -c "[ $rc -eq 1 ] && grep -q 'alternates exists' '$T/err'"
check "  no temporary folder left in RBD_HOME/tmp after any of them" bash -c "[ -z \"\$(ls -A '$THOME/tmp')\" ]"

# ---- every object is re-hashed into rbd's own store (round-2 recheck B finding 1): git checks no tree or blob it reads
# through alternates, so a forged loose object in the runner-owned store changed what was checked; index-pack refuses it ----
FG=$T/forged
git clone -q --no-local "$S" "$FG"
git -C "$FG" rev-parse -q --verify refs/heads/main > /dev/null || git -C "$FG" branch -q main origin/main
HF=$(branch "$FG" forged "git apply --exclude=rhobound-change.json $CH/c2-auth-small/change.patch; cp $CH/c2-auth-small/rhobound-change.json .; echo '// forged-test' >> kshop/app/internal/work/lib_v11.go")
"$CI/pr-check.sh" "$FG" "$BASE" "$HF" > "$T/out" 2> "$T/err"
check "the control: an untouched new commit in a fresh clone is admitted (exit $?)" test "$(fget "$T/out" ok)" = true
FB=$(git -C "$FG" rev-parse "$HF:kshop/app/internal/work/lib_v11.go")
FP=$FG/.git/objects/${FB:0:2}/${FB:2}
chmod u+w "$FP"
python3 -I -c 'import zlib,sys; d=b"package work // ATTACKER BYTES\n"; open(sys.argv[1],"wb").write(zlib.compress(b"blob %d\0"%len(d)+d))' "$FP"
"$CI/pr-check.sh" "$FG" "$BASE" "$HF" > "$T/out" 2> "$T/err"
rc=$?
check "a loose blob of HEAD_SHA forged in the checkout's store: refused by index-pack --strict (exit $rc)" bash -c "[ $rc -eq 1 ] &&
  grep -q 'fail index-pack --strict' '$T/err'"
check "  no temporary folder left in RBD_HOME/tmp" bash -c "[ -z \"\$(ls -A '$THOME/tmp')\" ]"
# ---- the policy's bytes and the per-run lock (round-1 recheck2 finding 2) ----
P0=$THOME/runs/$HG/policy.json
rc=$(run "$HG")
cp "$P0" "$T/policy.keep"
ln -s "$T/victim" "$THOME/runs/$HG/.policy.json.tmp"
rc=$(run "$HG")
check "no fixed temporary name: a planted runs/HEAD/.policy.json.tmp symlink is not written through (exit $rc)" \
  bash -c "[ $rc -eq 0 ] && [ ! -e '$T/victim' ] && cmp -s '$P0' '$REPO0/policy/gate.json'"
rm -f "$THOME/runs/$HG/.policy.json.tmp"
lockrun "$THOME/runs/$HG/.lock" || bad "lockrun: the holder never took the lock"
rc=$(run "$HG")
unlockrun
check "refuses while another step of the same run holds runs/HEAD/.lock (exit $rc), policy.json untouched" \
  bash -c "[ $rc -eq 1 ] && grep -q 'another step of runs/$HG is running' '$T/err' && cmp -s '$P0' '$T/policy.keep'"
rc=$(run "$HG")
check "  and admits once it is released (exit $rc)" test "$rc" -eq 0

# ---- CI v2: rbd.change-request/v2 (1..5 services, one image; an optional base key of the kit's bases.json) ----
echo "== pr-check v2"
CODE="echo '// fold' >> kshop/app/internal/work/lib_v11.go"
H=$(branch "$S" v2a "$CODE; v2req '[\"catalog\", \"pricing\"]'")
rc=$(run "$H")
check "admits a v2 request of catalog + pricing with a kshop/app change (exit $rc; last line service catalog, services [catalog, pricing], base null)" \
  bash -c "[ $rc -eq 0 ] && [ '$(fget "$T/out" service)' = catalog ] && [ '$(fget "$T/out" services)' = '[\"catalog\", \"pricing\"]' ] &&
  [ -z '$(fget "$T/out" base)' ]"
check "  pr.json records service (the first), services, base null, request_schema v2" python3 -I -c '
import json,sys; d=json.load(open(sys.argv[1]))
sys.exit(not (d["service"]=="catalog" and d["services"]==["catalog","pricing"] and d["base"] is None and d["base_image"] is None
  and d["request_schema"]=="rbd.change-request/v2" and d["summary"]=="fold: strip accents"))' "$THOME/runs/$H/pr.json"
H=$(branch "$S" v2a5 "$CODE; v2req '[\"auth\", \"payments\", \"inventory\", \"catalog\", \"pricing\"]'")
rc=$(run "$H")
check "admits a v2 request of 5 services (a shared-library change; exit $rc)" \
  bash -c "[ $rc -eq 0 ] && [ '$(fget "$T/out" services)' = '[\"auth\", \"payments\", \"inventory\", \"catalog\", \"pricing\"]' ]"
H=$(branch "$S" v2b "v2req '[\"catalog\", \"pricing\"]' go127")
rc=$(run "$H")
G127=$(python3 -I -c 'import json,sys; print(json.load(open(sys.argv[1]))["go127"])' "$TROOT/kshop/bases.json")
check "admits a PR whose only change is rhobound-change.json when it names a base (T4: go127; exit $rc)" \
  bash -c "[ $rc -eq 0 ] && [ '$(fget "$T/out" base)' = go127 ]"
check "  pr.json records base go127 and base_image = the kit's bases.json value (by digest)" python3 -I -c '
import json,sys; d=json.load(open(sys.argv[1])); sys.exit(not (d["base"]=="go127" and d["base_image"]==sys.argv[2] and "@sha256:" in sys.argv[2]
  and [f["path"] for f in d["files"]]==["rhobound-change.json"]))' "$THOME/runs/$H/pr.json" "$G127"
H=$(branch "$S" v2c "v2req '[\"auth\"]'")
refused "a v2 PR whose only change is rhobound-change.json and that names no base" "$H" "names no base"
H=$(branch "$S" v2d "cp $CH/c2-auth-small/rhobound-change.json .")
refused "a v1 PR whose only change is rhobound-change.json (nothing to build that main does not run)" "$H" "names no base"
H=$(branch "$S" v2e "$CODE; v2req '[\"catalog\", \"pricing\", \"auth\", \"cart\", \"payments\", \"inventory\"]'")
refused "a v2 request of 6 services" "$H" "1 to 5 distinct services"
H=$(branch "$S" v2f "$CODE; v2req '[\"catalog\", \"catalog\"]'")
refused "a v2 request that lists a service twice" "$H" "1 to 5 distinct services"
H=$(branch "$S" v2g "$CODE; v2req '[]'")
refused "a v2 request of no service" "$H" "1 to 5 distinct services"
H=$(branch "$S" v2h "$CODE; v2req '[\"catalog\", \"billing\"]'")
refused "a v2 request whose second service is unknown" "$H" "unknown service 'billing'"
H=$(branch "$S" v2i "$CODE; v2req '[\"catalog\"]' go999")
refused "a base that is not a key of the kit's bases.json" "$H" "unknown base 'go999'"
H=$(branch "$S" v2j "$CODE; v2req '[\"catalog\"]' _doc")
refused "a base key starting with _ (bases.json's comment)" "$H" '"base" must be a key'
H=$(branch "$S" v2k "$CODE; req '{\"schema\": \"rbd.change-request/v1\", \"services\": [\"auth\"], \"summary\": \"x\", \"base\": \"go127\"}'")
refused "a base in a v1 request" "$H" "unknown keys base"
H=$(branch "$S" v2l "$CODE; req '{\"schema\": \"rbd.change-request/v2\", \"services\": [\"auth\"], \"summary\": \"x\", \"base\": 127}'")
refused "a base that is not a string" "$H" '"base" must be a key'
H=$(branch "$S" v2m "$CODE; req \"{\\\"schema\\\": \\\"rbd.change-request/v2\\\", \\\"services\\\": [\\\"auth\\\"], \\\"summary\\\": \\\"\$(printf 'x%.0s' \$(seq 1 1001))\\\"}\"")
refused "a v2 summary longer than 1000 characters" "$H" "longer than 1000"
H=$(branch "$S" v2n "$CODE; v2req '[\"catalog\"]' go127")
cp "$TROOT/kshop/bases.json" "$T/bases.keep"
rm "$TROOT/kshop/bases.json"
refused "a base when the kit has no kshop/bases.json" "$H" "bases.json is missing"
python3 -I -c 'import json,sys; b=json.load(open(sys.argv[1])); b["go127"]="golang:1.27.2-bookworm"; json.dump(b,open(sys.argv[2],"w"))' \
  "$T/bases.keep" "$TROOT/kshop/bases.json"
refused "a base whose bases.json value is a tag, not pinned by digest" "$H" "not an image pinned by digest"
cp "$T/bases.keep" "$TROOT/kshop/bases.json"
rc=$(run "$H")
check "  and admits it again with the kit's bases.json (exit $rc)" test "$rc" -eq 0
check "the kit's tools1/kshop/bases.json: every base pinned by digest, go1269 = the builder the kit's Dockerfile names" python3 -I -c '
import json,re,sys; b=json.load(open(sys.argv[1])); df=open(sys.argv[2]).read()
vals={k:v for k,v in b.items() if not k.startswith("_")}
sys.exit(not (vals and all(re.fullmatch(r"[a-z0-9][a-z0-9._/:-]*@sha256:[0-9a-f]{64}", v) for v in vals.values()) and vals["go1269"] in df))' \
  "$KIT/tools1/kshop/bases.json" "$KIT/tools1/kshop/Dockerfile"
done_summary
