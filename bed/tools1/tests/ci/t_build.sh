#!/usr/bin/env bash
# build.sh with stub docker/aws: the kit's Dockerfile, the build args and label, the tag (the full sha), the digest from the
# push and the registry agreeing, candidate.json; kshop-load; the refusals; no account id in what goes to GitHub. The context
# is GIT_SHA's git objects (git archive in a temporary RBD_HOME/tmp/build.* folder, removed after), never the checkout's
# working tree or HEAD; nothing the runner-owned .git/ or the caller's GIT_* names runs (round-1 recheck finding 1); a plain
# tree only as RBD_HOME/src/main of the commit in src/main.sha (its resolved path); from a checkout never kshop-load nor main's
# commit; every object re-hashed (a forged object in the checkout's store is refused); no VCS metadata in the tree; no
# rebuild once the run holds a prediction; the run lock. CI v2: with pr-check's pr.json, ONE image for every listed service
# (candidate-<svc>.json each), SERVICE = the first; a base -> --build-arg GO_IMAGE (refused without ARG GO_IMAGE in the kit's
# Dockerfile, or when bases.json moved since pr-check).
set -uo pipefail
# shellcheck source=tools1/tests/ci/lib.sh
. "$(dirname "$0")/lib.sh"
echo "== build"
mkenv build
S=$T/src
mkrepo "$S"
mkbaseline
H=$(branch "$S" c2 "git apply $KIT/changes/c2-auth-small/change.patch")
LIB=kshop/app/internal/work/lib_v11.go
ctxsub=kshop/app ctxrel=app/
grep -q '^COPY app/' "$TROOT/kshop/Dockerfile" && ctxsub=kshop ctxrel=
tmpclean() { [[ -z $(ls -A "$THOME/tmp" 2> /dev/null) ]]; }
# ctx_has PATH: the last build's context holds PATH (relative to kshop/) with the bytes of GIT_SHA's blob
ctx_has() { grep -q "^$(git -C "$S" show "$H:kshop/$1" | sha256sum | cut -d' ' -f1)  ./${1#"$ctxrel"}$" "$T/stub/images/last-ctx"; }
"$CI/build.sh" "$S" "$H" auth > "$T/out" 2> "$T/err"
rc=$?
check "builds and pushes auth (exit $rc)" test "$rc" -eq 0
b=$(cat "$T/stub/images/last-build" 2> /dev/null)
check "uses the KIT's Dockerfile and a context made by git archive: RBD_HOME/tmp/build.*/src/$ctxsub" \
  grep -qE -- "-f $TROOT/kshop/Dockerfile .* $THOME/tmp/build\.[A-Za-z0-9]{6}/src/$ctxsub$" <<< "$b"
check "the context holds GIT_SHA's files (lib_v11.go = the commit's blob)" ctx_has app/internal/work/lib_v11.go
check "the temporary context folder is removed after the build" tmpclean
check "LIB=kshop_v11, SERVICE=auth, CMD=kshop-svc, revision label" grep -q -- \
  "--build-arg LIB=kshop_v11 --build-arg SERVICE=auth --build-arg CMD=kshop-svc --label org.opencontainers.image.revision=$H" <<< "$b"
check "tag RBD_ECR:auth-<the full 40-hex sha>" grep -q -- "-t 123456789012.dkr.ecr.ap-south-1.amazonaws.com/rhobound-demo/kshop:auth-$H " <<< "$b"
check "logs in to ECR before the build" grep -q "docker login --username AWS --password-stdin 123456789012.dkr.ecr" "$T/stub/calls.log"
want=$(cat "$T/stub/ecr/auth-$H.digest")
check "digest = the push's own = the registry's (describe-images) = $(cut -c1-19 <<< "$want")..." test "$(fget "$T/out" digest)" = "$want"
check "describe-images was asked for the full-sha tag" grep -q "describe-images .*imageTag=auth-$H " "$T/stub/calls.log"
base=$(python3 -I -c 'import json,sys; print(json.load(open(sys.argv[1]))["services"]["auth"])' "$THOME/baseline.json")
check "prints baseline_digest = production's auth" test "$(fget "$T/out" baseline_digest)" = "$base"
check "candidate.json = candidate-auth.json, with service/digest/git_sha" python3 -I -c '
import json,sys; a=json.load(open(sys.argv[1])); b=json.load(open(sys.argv[2]))
sys.exit(not (a==b and a["service"]=="auth" and a["digest"]==sys.argv[3] and a["git_sha"]==sys.argv[4] and a["lib"]=="kshop_v11"))' \
  "$THOME/runs/$H/candidate.json" "$THOME/runs/$H/candidate-auth.json" "$want" "$H"
check "no account id on stdout/stderr (redacted)" bash -c "! grep -q 123456789012 '$T/out' '$T/err'"
nb=$(grep -c '^docker build' "$T/stub/calls.log")
"$CI/build.sh" "$S" "$H" kshop-load > "$T/out" 2> "$T/err"
rc=$?
check "refuses kshop-load from a checkout: the load generator is built only from src/main (exit $rc, no docker build)" bash -c "[ $rc -eq 1 ] &&
  grep -q 'kshop-load is built only from' '$T/err' && [ \$(grep -c '^docker build' '$T/stub/calls.log') -eq $nb ]"
"$CI/build.sh" "$S" "$H" billing > "$T/out" 2> "$T/err"
check "refuses an unknown service (exit $?)" grep -q "unknown service" "$T/err"
# the working tree is the runner's: an edit or an untracked file there never reaches the image
echo '// not committed' >> "$S/$LIB"
echo 'package work' > "$S/kshop/app/extra.go"
"$CI/build.sh" "$S" "$H" auth > "$T/out" 2> "$T/err"
rc=$?
check "a modified and an untracked file in the checkout: built from GIT_SHA anyway (exit $rc)" test "$rc" -eq 0
check "  the context has the committed lib_v11.go, not the edited one" ctx_has app/internal/work/lib_v11.go
check "  the untracked extra.go is not in the context" bash -c "! grep -q 'extra.go' '$T/stub/images/last-ctx'"
git -C "$S" checkout -q -- "$LIB"
rm -f "$S/kshop/app/extra.go"
# a filter (smudge) or fsmonitor named in the runner-owned .git/config never runs as rbd
git -C "$S" config filter.ev.smudge "sh -c 'touch $T/SMUDGED; cat'"
git -C "$S" config core.fsmonitor "touch $T/FSMONITOR #"
printf '* filter=ev\n' > "$S/.git/info/attributes"
"$CI/build.sh" "$S" "$H" auth > "$T/out" 2> "$T/err"
rc=$?
check "a smudge filter and core.fsmonitor in the checkout's .git/config: neither runs (exit $rc)" \
  test "$rc" -eq 0 -a ! -e "$T/SMUDGED" -a ! -e "$T/FSMONITOR"
rm -f "$S/.git/info/attributes"
git -C "$S" config --unset filter.ev.smudge
git -C "$S" config --unset core.fsmonitor
HA=$(branch "$S" attrs "git apply $KIT/changes/c2-auth-small/change.patch; echo '*.go export-ignore' > kshop/app/.gitattributes")
"$CI/build.sh" "$S" "$HA" auth > "$T/out" 2> "$T/err"
check "refuses a commit with a .gitattributes (export-ignore/export-subst; exit $?)" grep -q "has a .gitattributes" "$T/err"
check "  and leaves no temporary folder" tmpclean
git -C "$S" checkout -q c2
P=$T/plain
mkdir -p "$P"
git -C "$S" archive "$H" | tar -x -C "$P"
"$CI/build.sh" "$P" "$H" auth > "$T/out" 2> "$T/err"
check "refuses a plain tree that is not the bootstrap's main tree (exit $?)" grep -q "built from git objects only" "$T/err"
M=$THOME/src/main
MS=$(git -C "$S" rev-parse main)
mkdir -p "$M"
git -C "$S" archive "$MS" | tar -x -C "$M"
"$CI/build.sh" "$M" "$MS" auth > "$T/out" 2> "$T/err"
check "refuses the plain tree RBD_HOME/src/main without src/main.sha (its commit unknown; exit $?)" grep -q "main.sha .* is missing" "$T/err"
echo "$MS" > "$THOME/src/main.sha"
"$CI/build.sh" "$M" "$H" auth > "$T/out" 2> "$T/err"
check "refuses the plain tree labelled with another commit than src/main.sha's (exit $?)" grep -q "holds commit .*, not GIT_SHA $H" "$T/err"
"$CI/build.sh" "$M" "$MS" auth > "$T/out" 2> "$T/err"
check "builds the plain tree RBD_HOME/src/main as src/main.sha's commit (bootstrap's upload of main; exit $?)" bash -c "[ \"\$(sed -n '\$p' '$T/out' | python3 -I -c 'import json,sys; print(json.load(sys.stdin)[\"ok\"])')\" = True ] && grep -q \"bootstrap's main tree\" '$T/err' && grep -q -- ' $M/$ctxsub\$' '$T/stub/images/last-build'"
"$CI/build.sh" "$M" "$MS" kshop-load > "$T/out" 2> "$T/err"
rc=$?
check "builds kshop-load from src/main with CMD=kshop-load (exit $rc)" bash -c "[ $rc -eq 0 ] && grep -q -- '--build-arg CMD=kshop-load' '$T/stub/images/last-build'"
check "kshop-load has no baseline digest" test "$(fget "$T/out" baseline_digest)" = ""
# a caller's symlink to src/main: the context is the resolved src/main, so a repoint after the check is never read
# (round-2 recheck B, poc_maintag part b)
ln -sfn "$M" "$T/mainlink"
"$CI/build.sh" "$T/mainlink" "$MS" auth > "$T/out" 2> "$T/err"
check "a symlink to src/main: built from the resolved src/main, not the link (exit $?)" bash -c "grep -q -- ' $M/$ctxsub\$' '$T/stub/images/last-build' && ! grep -q -- 'mainlink' '$T/stub/images/last-build'"
nb=$(grep -c '^docker build' "$T/stub/calls.log")
"$CI/build.sh" "$S" "$MS" auth > "$T/out" 2> "$T/err"
rc=$?
check "refuses main's commit (src/main.sha) from a checkout: main's tags are images.sh's (exit $rc, no docker build)" bash -c "[ $rc -eq 1 ] &&
  grep -q 'main as the bootstrap uploaded it' '$T/err' && [ \$(grep -c '^docker build' '$T/stub/calls.log') -eq $nb ]"
# everything is read by sha, never through the checkout's HEAD: a working tree at main still builds GIT_SHA's objects
git -C "$S" checkout -q main
"$CI/build.sh" "$S" "$H" auth > "$T/out" 2> "$T/err"
check "a checkout whose working tree is at main: GIT_SHA's objects are built (exit $?)" ctx_has app/internal/work/lib_v11.go
git -C "$S" checkout -q c2
"$CI/build.sh" "$S" "$(printf nocommit | sha1sum | cut -d' ' -f1)" auth > "$T/out" 2> "$T/err"
check "refuses a GIT_SHA that is not a commit in the checkout (exit $?)" grep -q "is not a commit in" "$T/err"
STUB_BUILD_RC=1 "$CI/build.sh" "$S" "$H" auth > "$T/out" 2> "$T/err"
rc=$?
check "a failed docker build fails the step loudly (exit $rc, ok=false, log tail shown)" \
  test "$rc" -eq 1 -a "$(fget "$T/out" ok)" = false -a -n "$(grep 'last lines of the log' "$T/err")"
check "  and leaves no temporary folder" tmpclean
# once the run holds a prediction, candidate.json is what was measured: no rebuild (sign.sh signs only that image)
"$CI/build.sh" "$S" "$H" auth > "$T/out" 2> "$T/err"
cp "$THOME/runs/$H/candidate.json" "$T/cand.keep"
nb=$(grep -c '^docker build' "$T/stub/calls.log")
for x in predict.json gate; do
  if [[ $x == gate ]]; then mkdir "$THOME/runs/$H/gate"; else echo '{}' > "$THOME/runs/$H/$x"; fi
  "$CI/build.sh" "$S" "$H" auth > "$T/out" 2> "$T/err"
  rc=$?
  check "refuses to rebuild once runs/GIT_SHA/$x exists (exit $rc, no docker build, candidate.json unchanged)" bash -c "[ $rc -eq 1 ] &&
    grep -q 'already holds a prediction' '$T/err' && [ \$(grep -c '^docker build' '$T/stub/calls.log') -eq $nb ] && cmp -s '$T/cand.keep' '$THOME/runs/$H/candidate.json'"
  rm -rf "${THOME:?}/runs/$H/$x"
done
# ---- the digest is the push's own; the registry must agree (round-1 recheck1 finding 4) ----
nb=$(grep -c '^docker build' "$T/stub/calls.log")
STUB_DESCRIBE_DIGEST=sha256:$(printf other | sha256sum | cut -d' ' -f1) "$CI/build.sh" "$S" "$H" auth > "$T/out" 2> "$T/err"
rc=$?
check "refuses when describe-images names another digest than the push (the tag moved; exit $rc), candidate.json unchanged" \
  bash -c "[ $rc -eq 1 ] && grep -q 'not the digest this build pushed' '$T/err' && cmp -s '$T/cand.keep' '$THOME/runs/$H/candidate.json'"
STUB_PUSH_QUIET=1 "$CI/build.sh" "$S" "$H" auth > "$T/out" 2> "$T/err"
rc=$?
check "a push that prints no digest: the image's one repo digest is the push's (exit $rc, = describe-images)" \
  test "$rc" -eq 0 -a "$(fget "$T/out" digest)" = "$(cat "$T/stub/ecr/auth-$H.digest")"
STUB_PUSH_QUIET=1 STUB_NO_REPODIGEST=1 "$CI/build.sh" "$S" "$H" auth > "$T/out" 2> "$T/err"
rc=$?
check "refuses when neither the push nor the image names a digest (exit $rc)" bash -c "[ $rc -eq 1 ] && grep -q 'printed no digest' '$T/err'"
# ---- the runner-owned .git/ and the caller's GIT_* (round-1 recheck1 PoC poc_build_config.sh, extended) ----
MK=$T/marks
X=$T/hostile
git clone -q "$S" "$X"
hostile_git "$X" "$MK"
rm -rf "$MK" && mkdir -p "$MK"
cleanb() { [[ $1 -eq $2 ]] && nomarks "$MK" && { [[ -z ${3:-} ]] || grep -q -- "$3" "$T/err"; }; }
"$CI/build.sh" "$X" "$H" auth > "$T/out" 2> "$T/err"
rc=$?
check "every hostile key, hook, include and attribute in the checkout's .git: built from GIT_SHA, nothing ran (exit $rc, marks: $(marks "$MK"))" \
  cleanb "$rc" 0
check "  the context is GIT_SHA's committed files" ctx_has app/internal/work/lib_v11.go
NOSHA=0000000000000000000000000000000000000001
"$CI/build.sh" "$X" "$NOSHA" auth > "$T/out" 2> "$T/err"
rc=$?
check "  a GIT_SHA missing from the checkout (the partial-clone lazy fetch's trigger): refused, nothing ran (exit $rc)" \
  cleanb "$rc" 1 "is not a commit in"
hostile_env "$MK" "$X" "$CI/build.sh" "$X" "$NOSHA" auth > "$T/out" 2> "$T/err"
rc=$?
check "the caller's GIT_CONFIG_COUNT/GIT_CONFIG_PARAMETERS/GIT_DIR with a missing GIT_SHA: refused, nothing ran (exit $rc)" \
  cleanb "$rc" 1 "is not a commit in"
hostile_env "$MK" "$X" "$CI/build.sh" "$X" "$H" auth > "$T/out" 2> "$T/err"
rc=$?
check "  and with GIT_SHA: built, nothing ran (exit $rc)" cleanb "$rc" 0
Z=$T/gitfile
mkdir -p "$Z"
printf 'gitdir: %s/.git\n' "$S" > "$Z/.git"
"$CI/build.sh" "$Z" "$H" auth > "$T/out" 2> "$T/err"
check "refuses a .git that is a 'gitdir:' file (exit $?)" grep -q "gitdir:' file" "$T/err"
O=$T/objlink
git clone -q "$S" "$O"
rm -rf "$O/.git/objects" && ln -s "$S/.git/objects" "$O/.git/objects"
"$CI/build.sh" "$O" "$H" auth > "$T/out" 2> "$T/err"
check "refuses a .git/objects that is a symlink out of the checkout (exit $?)" grep -q "symlinked .git or objects" "$T/err"
A=$T/shared
git clone -q --shared "$S" "$A"
"$CI/build.sh" "$A" "$H" auth > "$T/out" 2> "$T/err"
check "refuses a checkout whose objects/info/alternates borrows other objects (exit $?)" grep -q "alternates exists" "$T/err"
check "  and leaves no temporary folder" tmpclean
# ---- every object is re-hashed into rbd's own store (round-2 recheck B finding 1, objforge.sh): git checks no tree or blob
# it reads through alternates, so a forged loose object in the runner-owned store changed the image; index-pack refuses it ----
FG=$T/forged
git clone -q --no-local "$S" "$FG"
git -C "$FG" rev-parse -q --verify refs/heads/main > /dev/null || git -C "$FG" branch -q main origin/main
HF=$(branch "$FG" forged "git apply $KIT/changes/c2-auth-small/change.patch; echo '// forged-test' >> $LIB")
"$CI/build.sh" "$FG" "$HF" auth > "$T/out" 2> "$T/err"
check "the control: an untouched new commit in a fresh clone builds (exit $?)" grep -q 'build: auth at' "$T/err"
FB=$(git -C "$FG" rev-parse "$HF:$LIB")
FP=$FG/.git/objects/${FB:0:2}/${FB:2}
chmod u+w "$FP"
python3 -I -c 'import zlib,sys; d=b"package work // ATTACKER BYTES\n"; open(sys.argv[1],"wb").write(zlib.compress(b"blob %d\0"%len(d)+d))' "$FP"
nb=$(grep -c '^docker build' "$T/stub/calls.log")
"$CI/build.sh" "$FG" "$HF" auth > "$T/out" 2> "$T/err"
rc=$?
check "a loose blob of GIT_SHA forged in the checkout's store: refused by index-pack --strict (exit $rc, no docker build)" bash -c "[ $rc -eq 1 ] &&
  grep -q 'fail index-pack --strict' '$T/err' && [ \$(grep -c '^docker build' '$T/stub/calls.log') -eq $nb ]"
check "  and leaves no temporary folder" tmpclean
# ---- VCS metadata in the tree: go build's VCS stamping would run hg/svn/bzr/fossil on it (round-2 recheck A) ----
for v in .hg/hgrc internal/.svn/entries .bzr/branch-format _FOSSIL_ .fslckout; do
  HV=$(branch "$S" "vcs${v//[^a-z]/}" "git apply $KIT/changes/c2-auth-small/change.patch; mkdir -p kshop/app/\$(dirname $v); echo x > kshop/app/$v")
  "$CI/build.sh" "$S" "$HV" auth > "$T/out" 2> "$T/err"
  check "refuses a commit with kshop/app/$v (VCS metadata; exit $?)" grep -q "has VCS metadata" "$T/err"
done
git -C "$S" checkout -q c2
# ---- one step of a run at a time ----
nb=$(grep -c '^docker build' "$T/stub/calls.log")
lockrun "$THOME/runs/$H/.lock" || bad "lockrun: the holder never took the lock"
"$CI/build.sh" "$S" "$H" auth > "$T/out" 2> "$T/err"
rc=$?
unlockrun
check "refuses while another step of the same run holds runs/GIT_SHA/.lock (exit $rc, no docker build)" bash -c "[ $rc -eq 1 ] &&
  grep -q 'another step of runs/$H is running' '$T/err' && [ \$(grep -c '^docker build' '$T/stub/calls.log') -eq $nb ]"

# ---- CI v2: pr.json (pr-check's record) -> ONE image for every listed service; a base -> --build-arg GO_IMAGE ----
echo "== build v2"
MAIN=$(git -C "$S" rev-parse main)
prc() { "$CI/pr-check.sh" "$S" "$MAIN" "$1" > "$T/prc.out" 2> "$T/prc.err" || { bad "pr-check of ${1:0:12}: $(tail -n 1 "$T/prc.err")"; }; }
nbuilds() { grep -c '^docker build' "$T/stub/calls.log"; }
H2=$(branch "$S" v2 "echo '// fold' >> $LIB; v2req '[\"catalog\", \"pricing\"]'")
prc "$H2"
nb=$(nbuilds)
"$CI/build.sh" "$S" "$H2" catalog > "$T/out" 2> "$T/err"
rc=$?
b=$(cat "$T/stub/images/last-build" 2> /dev/null)
d2=$(cat "$T/stub/ecr/catalog-$H2.digest" 2> /dev/null)
check "v2 catalog + pricing: ONE docker build (exit $rc), tag catalog-<sha>, SERVICE=catalog, no GO_IMAGE (no base)" bash -c "[ $rc -eq 0 ] &&
  [ \$(grep -c '^docker build' '$T/stub/calls.log') -eq $((nb + 1)) ] && grep -q -- '--build-arg SERVICE=catalog ' <<< '$b' &&
  grep -q -- ':catalog-$H2 ' <<< '$b' && ! grep -q GO_IMAGE <<< '$b' && [ ! -e '$T/stub/ecr/pricing-$H2.digest' ]"
check "  candidate-catalog.json and candidate-pricing.json: the same digest, each its own service and production digest" python3 -I -c '
import json,sys; run,d,bp=sys.argv[1:4]; prod=json.load(open(bp))["services"]
c={s: json.load(open("%s/candidate-%s.json" % (run, s))) for s in ("catalog","pricing")}
sys.exit(not all(c[s]["digest"]==d and c[s]["service"]==s and c[s]["baseline_digest"]==prod[s] and c[s]["services"]==["catalog","pricing"]
  and c[s]["baselines"]=={"catalog": prod["catalog"], "pricing": prod["pricing"]} and c[s]["base"] is None for s in c))' \
  "$THOME/runs/$H2" "$d2" "$THOME/baseline.json"
check "  candidate.json = candidate-catalog.json (byte for byte)" cmp -s "$THOME/runs/$H2/candidate.json" "$THOME/runs/$H2/candidate-catalog.json"
check "  the last line names services, baselines (gate.yml's A/B inputs) and the digest" python3 -I -c '
import json,sys; d=json.loads(open(sys.argv[1]).read().splitlines()[-1]); p=json.load(open(sys.argv[2]))["services"]
sys.exit(not (d["ok"] and d["services"]==["catalog","pricing"] and d["baselines"]=={"catalog":p["catalog"],"pricing":p["pricing"]}
  and d["digest"]==sys.argv[3] and d["base"] is None))' "$T/out" "$THOME/baseline.json" "$d2"
nb=$(nbuilds)
"$CI/build.sh" "$S" "$H2" pricing > "$T/out" 2> "$T/err"
rc=$?
check "refuses SERVICE pricing for a request whose first service is catalog (exit $rc, no docker build)" bash -c "[ $rc -eq 1 ] &&
  grep -q 'is not the change request.s first service catalog' '$T/err' && [ \$(grep -c '^docker build' '$T/stub/calls.log') -eq $nb ]"
HC=$(branch "$S" v1pr "git apply $KIT/changes/c2-auth-small/change.patch")
prc "$HC"
"$CI/build.sh" "$S" "$HC" auth > "$T/out" 2> "$T/err"
rc=$?
check "a v1 request with pr.json: built as before (exit $rc), services [auth], no GO_IMAGE" bash -c "[ $rc -eq 0 ] &&
  ! grep -q GO_IMAGE '$T/stub/images/last-build' && python3 -I -c 'import json,sys; c=json.load(open(sys.argv[1])); sys.exit(not (c[\"services\"]==[\"auth\"] and c[\"service\"]==\"auth\" and c[\"base\"] is None))' '$THOME/runs/$HC/candidate.json'"
# a base: the kit's Dockerfile must take ARG GO_IMAGE (refused, never silently the default builder, while it does not)
G127=$(python3 -I -c 'import json,sys; print(json.load(open(sys.argv[1]))["go127"])' "$TROOT/kshop/bases.json")
HB=$(branch "$S" v2base "v2req '[\"catalog\", \"pricing\"]' go127")
prc "$HB"
cp "$TROOT/kshop/Dockerfile" "$T/Dockerfile.keep"
python3 -I - "$TROOT/kshop/Dockerfile" "$(python3 -I -c 'import json,sys; print(json.load(open(sys.argv[1]))["go1269"])' "$TROOT/kshop/bases.json")" << 'PY'
import re, sys
p, img = sys.argv[1:3]
t = re.sub(r"(?m)^ARG GO_IMAGE.*\n", "", open(p).read())
open(p, "w").write(re.sub(r"(?m)^FROM \$\{?GO_IMAGE\}?", "FROM " + img, t))
PY
nb=$(nbuilds)
"$CI/build.sh" "$S" "$HB" catalog > "$T/out" 2> "$T/err"
rc=$?
check "a base (go127) with a kit Dockerfile that has no ARG GO_IMAGE: refused, not built on the default builder (exit $rc)" \
  bash -c "[ $rc -eq 1 ] && grep -q \"has no 'ARG GO_IMAGE'\" '$T/err' && [ \$(grep -c '^docker build' '$T/stub/calls.log') -eq $nb ]"
cp "$T/Dockerfile.keep" "$TROOT/kshop/Dockerfile"
goimage_dockerfile
"$CI/build.sh" "$S" "$HB" catalog > "$T/out" 2> "$T/err"
rc=$?
check "a base (go127), the Dockerfile with ARG GO_IMAGE: built with --build-arg GO_IMAGE=<bases.json go127> (exit $rc)" bash -c "[ $rc -eq 0 ] &&
  grep -q -- '--build-arg GO_IMAGE=$G127 --build-arg LIB=kshop_v11 --build-arg SERVICE=catalog ' '$T/stub/images/last-build'"
check "  candidate-catalog/pricing.json record base go127 and the builder image, one digest" python3 -I -c '
import json,sys; run,g=sys.argv[1:3]
c=[json.load(open("%s/candidate-%s.json" % (run, s))) for s in ("catalog","pricing")]
sys.exit(not all(x["base"]=="go127" and x["go_image"]==g and x["digest"]==c[0]["digest"] for x in c))' "$THOME/runs/$HB" "$G127"
python3 -I -c 'import json,sys; b=json.load(open(sys.argv[1])); b["go127"]="golang:1.27.3-bookworm@sha256:"+"9"*64; json.dump(b,open(sys.argv[1],"w"))' \
  "$TROOT/kshop/bases.json"
nb=$(nbuilds)
"$CI/build.sh" "$S" "$HB" catalog > "$T/out" 2> "$T/err"
rc=$?
check "refuses when the kit's bases.json names another image for the base than pr-check admitted (exit $rc, no docker build)" \
  bash -c "[ $rc -eq 1 ] && grep -q 'pr-check admitted' '$T/err' && [ \$(grep -c '^docker build' '$T/stub/calls.log') -eq $nb ]"
done_summary
