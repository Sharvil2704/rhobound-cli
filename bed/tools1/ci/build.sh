#!/bin/bash
# build: one kshop image from a checkout, with the KIT's Dockerfile (never the PR's), pushed to ECR; digest from the push.
#   sudo -n -u rbd /opt/rbd/ci/build.sh CHECKOUT GIT_SHA SERVICE      (SERVICE: one of spec.json's 10, or kshop-load)
# LIB=kshop_v11 (library 1.1, production), label org.opencontainers.image.revision=GIT_SHA, tag RBD_ECR:SERVICE-<GIT_SHA>
# (all 40 hex). Writes runs/GIT_SHA/candidate-SERVICE.json and candidate.json (the same; the last build of the run). Log:
# runs/GIT_SHA/logs/. The digest is the push's own (docker push's output, else the image's one RepoDigest in RBD_ECR), and
# the registry's describe-images of the tag must name the same digest: refused otherwise (the tag moved).
# CI v2 (SPEC2 4): when runs/GIT_SHA/pr.json exists (pr-check's record of the change request), SERVICE must be its first
# service, and ONE image is built for every service it lists: candidate-<svc>.json for each listed service (the same digest,
# that service's production digest from baseline.json as baseline_digest; every file also lists services and baselines),
# and candidate.json = the first service's file. When pr.json names a base (a key of the kit's kshop/bases.json), the image
# is built with --build-arg GO_IMAGE=<that key's REF@sha256> from the kit's bases.json (refused unless it is still the image
# pr-check admitted, pinned by digest, and the kit's Dockerfile has ARG GO_IMAGE and FROM ${GO_IMAGE}: a base never silently
# falls back to the default builder). No pr.json (the bootstrap's main tree): SERVICE alone, the Dockerfile's own builder.
# Built from GIT_SHA's git objects only, by sha, never the runner's working tree or its HEAD: git archive into a fresh
# rbd-owned folder (RBD_HOME/tmp/build.XXXXXX, removed after). The objects are read once, through a temporary rbd-owned bare
# repository that borrows the checkout's objects (objects/info/alternates), and copied as one pack into a second rbd-owned
# repository where index-pack --strict names every object by its hashed content (git re-hashes no tree or blob it reads
# through alternates: a forged object in the runner-owned store is refused, and nothing the runner writes later is read).
# No config, filter, hook, attribute or replace ref of the runner-owned .git/ runs or applies, and no GIT_* of the caller's
# environment is kept; CHECKOUT/.git must be a real folder (not a gitdir: file or a symlink) with a real objects/ folder and
# no alternates of its own; a tree with a .gitattributes (export-subst/export-ignore) or with VCS metadata (.git .hg .svn
# .bzr .fslckout _FOSSIL_: go build would run that VCS's tool on it) is refused. From a checkout: not kshop-load and not
# main's commit (RBD_HOME/src/main.sha), so a PR job never pushes a tag the bootstrap's images.sh owns. A plain tree (no
# .git) only when it is the bootstrap's upload of main, RBD_HOME/src/main (rbd's own; built from its resolved path), and
# GIT_SHA is the commit it holds (RBD_HOME/src/main.sha, written by the bootstrap).
# Refused once runs/GIT_SHA holds a prediction (predict.json or gate/): candidate.json is what predict.sh measured and
# sign.sh signs; gate a rebuilt image from a new commit. Under runs/GIT_SHA/.lock (flock; one step of a run at a time).
# Exit 0 built and pushed, 1 refused or failed. Last stdout line: one JSON object (digest, baseline_digest for ab.sh).
set -euo pipefail
STEP=build
ci_red() { if [[ -n ${RBD_ACCOUNT:-} ]]; then sed "s/${RBD_ACCOUNT}/<account>/g"; else cat; fi; }
ci_jstr() { python3 -I -c 'import json,sys; print(json.dumps(sys.argv[1]))' "$1"; }
ci_fail() {
  local m; m=$(printf '%s' "$1" | ci_red)
  if [[ -n ${LOG:-} && -s ${LOG:-} ]]; then echo "--- last lines of the log ---" >&2; tail -n 25 "$LOG" | ci_red >&2; fi
  echo "$STEP: error: $m" >&2; printf '{"step":"%s","ok":false,"error":%s}\n' "$STEP" "$(ci_jstr "$m")"; exit 1
}
[[ $# -eq 3 ]] || ci_fail "usage: build.sh CHECKOUT GIT_SHA SERVICE"
CHECKOUT=$1 SHA=$2 SERVICE=$3

RBD_ROOT=/opt/rbd
[[ -z ${SUDO_USER:-} && -n ${RBD_OPT:-} ]] && RBD_ROOT=$RBD_OPT   # tests only; sudo's env_reset never passes it
[[ -r $RBD_ROOT/lib/rbd-env.sh ]] || ci_fail "$RBD_ROOT/lib/rbd-env.sh missing"
# shellcheck source=/dev/null
ci_msg=$(. "$RBD_ROOT/lib/rbd-env.sh" 2>&1 > /dev/null) || ci_fail "rbd-env.sh: $ci_msg"
# shellcheck source=/dev/null
. "$RBD_ROOT/lib/rbd-env.sh"
PATH=$RBD_ROOT/bin:$PATH
for v in RBD_REGION RBD_ECR RBD_HOME; do [[ -n ${!v:-} ]] || ci_fail "$v not set by rbd-env.sh"; done
DOCKERFILE=$RBD_ROOT/kshop/Dockerfile
[[ -r $DOCKERFILE && -r $RBD_ROOT/kshop/spec.json ]] || ci_fail "the kit's kshop copy ($RBD_ROOT/kshop) is missing"

[[ $SHA =~ ^[0-9a-f]{40}$ ]] || ci_fail "GIT_SHA must be a 40-hex commit id"
if [[ $SERVICE == kshop-load ]]; then CMD=kshop-load
else
  python3 -I -c 'import json,sys; sys.exit(sys.argv[2] not in json.load(open(sys.argv[1]))["services"])' \
    "$RBD_ROOT/kshop/spec.json" "$SERVICE" || ci_fail "unknown service '$SERVICE' (spec.json's 10, or kshop-load)"
  CMD=kshop-svc
fi
# git as rbd never takes the caller's environment (GIT_CONFIG_*, GIT_DIR, ...), a system or global config, a lazy fetch or a
# replace ref
unset "${!GIT_@}"
export GIT_NO_LAZY_FETCH=1 GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null GIT_NO_REPLACE_OBJECTS=1 GIT_TERMINAL_PROMPT=0
# a git checkout (the gate) is read as GIT_SHA's git objects; a plain tree only as the bootstrap's main tree of GIT_SHA
main_tree=$(readlink -f -- "$RBD_HOME/src/main" || true)
CO=$(readlink -f -- "$CHECKOUT" || true)
if [[ -e $CHECKOUT/.git || -L $CHECKOUT/.git ]]; then
  OBJ=$CO/.git/objects
  [[ -n $CO && $CO != *$'\n'* && -d $CO/.git && -d $OBJ && $(readlink -f -- "$OBJ") == "$OBJ" ]] ||
    ci_fail "$CHECKOUT is not a git checkout readable by $(id -un) with a real .git/objects folder (a .git 'gitdir:' file or a symlinked .git or objects/ is refused; the runner's _work must be o+rx)"
  [[ ! -e $OBJ/info/alternates && ! -L $OBJ/info/alternates ]] ||
    ci_fail "$CHECKOUT/.git/objects/info/alternates exists: refused (build reads the checkout's own objects only)"
  # main's tags (SERVICE-<main.sha>, kshop-load-<main.sha>) are the bootstrap's: images.sh builds them from src/main
  [[ $SERVICE != kshop-load ]] ||
    ci_fail "kshop-load is built only from the bootstrap's main tree $RBD_HOME/src/main (images.sh), never from a checkout"
  [[ $SHA != "$(head -c 64 -- "$RBD_HOME/src/main.sha" 2> /dev/null || true)" ]] ||
    ci_fail "GIT_SHA $SHA is main as the bootstrap uploaded it (src/main.sha): main's images are built only from $RBD_HOME/src/main"
  SRC=git
elif [[ -n $main_tree && -d $main_tree && $CO == "$main_tree" ]]; then
  msha=$(head -c 64 -- "$RBD_HOME/src/main.sha" 2> /dev/null || true)
  [[ $msha =~ ^[0-9a-f]{40}$ ]] ||
    ci_fail "$RBD_HOME/src/main.sha (the commit the bootstrap uploaded as src/main) is missing or not 40 hex: the main tree's commit is unknown"
  [[ $msha == "$SHA" ]] ||
    ci_fail "the bootstrap's main tree $RBD_HOME/src/main holds commit $msha, not GIT_SHA $SHA: a plain tree is built only as its own commit"
  [[ -r $CHECKOUT/kshop/app/go.mod ]] || ci_fail "$CHECKOUT/kshop/app/go.mod missing"
  echo "build: $CHECKOUT is the bootstrap's main tree (no .git) of $SHA (src/main.sha): built as given" >&2
  SRC=tree
else
  ci_fail "$CHECKOUT is neither a git checkout readable by $(id -un) (the runner's _work must be o+rx) nor the bootstrap's main tree $RBD_HOME/src/main: images are built from git objects only"
fi

RUN=$RBD_HOME/runs/$SHA
mkdir -p "$RUN/logs"
# one step of a run at a time (pr-check, build, ab, predict, sign): a flock on runs/RUN/.lock, held until this step exits
exec 7>> "$RUN/.lock" || ci_fail "cannot open runs/$SHA/.lock"
flock -n 7 || ci_fail "another step of runs/$SHA is running (runs/$SHA/.lock is held): one step of a run at a time"
[[ ! -e $RUN/predict.json && ! -e $RUN/gate ]] ||
  ci_fail "runs/$SHA already holds a prediction: its candidate.json is not rebuilt (push a new commit to gate a new build)"
LOG=$RUN/logs/build-$SERVICE.log
: > "$LOG"
# the change request pr-check admitted for this commit: the services this one image is for, and the Go builder (base)
SERVICES=$SERVICE BASEKEY="" GOIMG="" GOARG=()
if [[ -e $RUN/pr.json ]]; then
  prq=$(python3 -I - "$RUN/pr.json" "$SERVICE" "$RBD_ROOT/kshop/bases.json" "$DOCKERFILE" 2>> "$LOG" <<'PY'
import json, re, sys
prp, svc, bases_path, df = sys.argv[1:5]
def fail(m):
    print(m, file=sys.stderr); sys.exit(1)
try:
    pr = json.load(open(prp))
except (OSError, ValueError) as e:
    fail("runs/GIT_SHA/pr.json is not readable JSON: %s" % e)
svcs = pr.get("services") or [pr.get("service")]
if not isinstance(svcs, list) or not all(isinstance(x, str) and re.fullmatch(r"[a-z][a-z0-9-]{0,45}", x) for x in svcs):
    fail("runs/GIT_SHA/pr.json names no valid services: %r" % (svcs,))
if svcs[0] != svc:
    fail("SERVICE %s is not the change request's first service %s (pr.json services %s): one image per change, labelled "
         "with its first service" % (svc, svcs[0], ",".join(svcs)))
key, img = pr.get("base"), ""
if key is not None:
    try:
        bases = json.load(open(bases_path))
        v = bases[key]
    except (OSError, ValueError, KeyError, TypeError) as e:
        fail("base %r: not in the kit's %s (%s)" % (key, bases_path, e))
    img = v.get("image") if isinstance(v, dict) else v
    if not isinstance(img, str) or not re.fullmatch(r"[a-z0-9][a-z0-9._/:-]*@sha256:[0-9a-f]{64}", img):
        fail("base %r: the kit's bases.json value %r is not an image pinned by digest" % (key, img))
    if pr.get("base_image") != img:
        fail("base %r: the kit's bases.json names %s, pr-check admitted %s: re-run the gate" % (key, img, pr.get("base_image")))
    text = open(df).read()
    if not re.search(r"(?m)^ARG GO_IMAGE(=\S*)?\s*$", text) or not re.search(r"(?m)^FROM \$\{?GO_IMAGE\}?(\s|$)", text):
        fail("base %r: the kit's Dockerfile has no 'ARG GO_IMAGE' and 'FROM ${GO_IMAGE}': the base cannot be applied (it would "
             "build on the default builder)" % key)
print("%s|%s|%s" % (",".join(svcs), key or "", img))
PY
  ) || ci_fail "the change request (runs/$SHA/pr.json): $(tail -n 1 "$LOG")"
  IFS='|' read -r SERVICES BASEKEY GOIMG <<< "$prq"
  [[ -z $GOIMG ]] || GOARG=(--build-arg "GO_IMAGE=$GOIMG")
fi
TAG=$SERVICE-$SHA
REF=$RBD_ECR:$TAG
REGISTRY=${RBD_ECR%%/*}
REPO=${RBD_ECR#*/}
pub=$(printf '%s' "$REF" | ci_red)

if [[ $SRC == git ]]; then
  mkdir -p "$RBD_HOME/tmp"
  BTMP=$(mktemp -d "$RBD_HOME/tmp/build.XXXXXX") || ci_fail "cannot make a folder in $RBD_HOME/tmp"
  trap 'rm -rf "$BTMP"' EXIT
  ag() { git --git-dir="$BTMP/alt" "$@"; }   # borrows the checkout's objects: only read to pack GIT_SHA's history
  bg() { git --git-dir="$BTMP/git" "$@"; }   # rbd's own copy, every object re-hashed: all reads after the copy
  { git init -q --bare --template= --initial-branch=main "$BTMP/alt" && printf '%s\n' "$OBJ" > "$BTMP/alt/objects/info/alternates" &&
    git init -q --bare --template= --initial-branch=main "$BTMP/git"; } >> "$LOG" 2>&1 ||
    ci_fail "cannot set up the build's repositories in $BTMP"
  ag cat-file -e "$SHA^{commit}" 2> /dev/null || ci_fail "GIT_SHA $SHA is not a commit in $CHECKOUT"
  { printf '%s\n' "$SHA" | ag pack-objects --revs --stdout | git --git-dir="$BTMP/git" index-pack --stdin --strict; } >> "$LOG" 2>&1 ||
    ci_fail "GIT_SHA $SHA's objects in $CHECKOUT fail index-pack --strict (a forged, broken or missing object): not built"
  bg cat-file -e "$SHA^{commit}" 2> /dev/null || ci_fail "GIT_SHA $SHA is not in the re-hashed copy of its objects"
  bg cat-file -e "$SHA:kshop/app/go.mod" 2> /dev/null || ci_fail "no kshop/app/go.mod at GIT_SHA $SHA"
  attrs=$(bg ls-tree -r -z --name-only "$SHA" | tr '\0' '\n' | grep -E '(^|/)\.gitattributes$' || true)
  [[ -z $attrs ]] || ci_fail "GIT_SHA has a .gitattributes ($(tr '\n' ' ' <<< "$attrs")): git archive would not give its files as committed"
  vcs=$(bg ls-tree -r -z --name-only "$SHA" | tr '\0' '\n' | grep -E '(^|/)(\.git|\.hg|\.svn|\.bzr|\.fslckout|_FOSSIL_)(/|$)' || true)
  [[ -z $vcs ]] || ci_fail "GIT_SHA has VCS metadata ($(head -n 3 <<< "$vcs" | tr '\n' ' ')): go build would run that VCS's tool on it"
  mkdir "$BTMP/src"
  bg archive --format=tar "$SHA" kshop 2>> "$LOG" | tar -x -C "$BTMP/src" 2>> "$LOG" || ci_fail "git archive $SHA kshop failed"
  ROOT=$BTMP/src
else
  ROOT=$CO   # the resolved src/main, checked above: a caller's symlink repointed after the check is never read
fi
# the context the kit's Dockerfile expects: kshop/ when it copies app/..., else kshop/app
if grep -q '^COPY app/' "$DOCKERFILE"; then CTX=$ROOT/kshop; else CTX=$ROOT/kshop/app; fi

echo "build: $SERVICE at ${SHA:0:12} -> $pub (for $SERVICES${BASEKEY:+; base $BASEKEY})" >&2
{ aws ecr get-login-password --region "$RBD_REGION" | docker login --username AWS --password-stdin "$REGISTRY"; } >> "$LOG" 2>&1 ||
  ci_fail "ECR login failed"
docker build -f "$DOCKERFILE" ${GOARG[@]+"${GOARG[@]}"} --build-arg LIB=kshop_v11 --build-arg "SERVICE=$SERVICE" \
  --build-arg "CMD=$CMD" --label "org.opencontainers.image.revision=$SHA" -t "$REF" "$CTX" >> "$LOG" 2>&1 ||
  ci_fail "docker build failed"
pout=$(docker push "$REF" 2>> "$LOG") || { printf '%s\n' "$pout" >> "$LOG"; ci_fail "docker push failed"; }
printf '%s\n' "$pout" >> "$LOG"
# the digest is the push's own: its "TAG: digest: sha256:... size: N" line, else the image's one repo digest in RBD_ECR
pushed="" re="^$TAG: digest: (sha256:[0-9a-f]{64}) size: [0-9]+\$"
while IFS= read -r l; do if [[ $l =~ $re ]]; then pushed=${BASH_REMATCH[1]}; fi; done <<< "$pout"
if [[ -z $pushed ]]; then
  n=0
  while IFS= read -r l; do
    d=${l#"$RBD_ECR@"}
    if [[ $l == "$RBD_ECR@"* && $d =~ ^sha256:[0-9a-f]{64}$ && $d != "$pushed" ]]; then pushed=$d n=$((n + 1)); fi
  done < <(docker inspect --format '{{range .RepoDigests}}{{println .}}{{end}}' "$REF" 2>> "$LOG" || true)
  [[ $n -eq 1 ]] || ci_fail "docker push printed no digest for $TAG and the image lists $n repo digests in RBD_ECR (want one)"
fi
digest=$(aws ecr describe-images --region "$RBD_REGION" --repository-name "$REPO" --image-ids "imageTag=$TAG" \
  --query 'imageDetails[0].imageDigest' --output text 2>> "$LOG") || ci_fail "ecr describe-images failed"
[[ $digest =~ ^sha256:[0-9a-f]{64}$ ]] || ci_fail "registry returned no digest for $TAG ('$digest')"
[[ $digest == "$pushed" ]] ||
  ci_fail "the registry's $TAG is $digest, not the digest this build pushed ($pushed): the tag moved (another push of it?)"

python3 -I - "$RUN" "$SERVICE" "$SHA" "$TAG" "$RBD_ECR" "$digest" "$RBD_HOME/baseline.json" "$DOCKERFILE" "$SERVICES" \
  "$BASEKEY" "$GOIMG" <<'PY'
import datetime, hashlib, json, os, sys
run, svc, sha, tag, ecr, digest, base_path, dockerfile, services, bkey, goimg = sys.argv[1:12]
if os.path.exists(os.path.join(run, "predict.json")) or os.path.exists(os.path.join(run, "gate")):
    msg = "runs/%s got a prediction during the build: candidate.json is not replaced (push a new commit)" % sha
    print("build: error: " + msg, file=sys.stderr)
    print(json.dumps({"step": "build", "ok": False, "error": msg}))
    sys.exit(1)
svcs = services.split(",")   # the first is svc (checked against pr.json above)
prod = json.load(open(base_path)).get("services", {}) if os.path.exists(base_path) else {}
bases = {s: prod.get(s) for s in svcs}
now = datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
dsha = "sha256:" + hashlib.sha256(open(dockerfile, "rb").read()).hexdigest()
def write(name, data):
    tmp = os.path.join(run, "." + name + ".tmp")
    with open(tmp, "wb") as f:
        f.write(data)
    os.replace(tmp, os.path.join(run, name))
first = None
for s in svcs:   # one image, one record per service it is for (its own production digest as the baseline)
    rec = {"schema": "rbd.candidate/v1", "service": s, "services": svcs, "baselines": bases, "git_sha": sha, "tag": tag,
           "digest": digest, "image": ecr + "@" + digest, "baseline_digest": bases[s], "lib": "kshop_v11",
           "base": bkey or None, "go_image": goimg or None, "dockerfile_sha256": dsha, "built_at": now}
    data = (json.dumps(rec, indent=1, sort_keys=True) + "\n").encode()
    write("candidate-%s.json" % s, data)
    first = first or data
write("candidate.json", first)
print(json.dumps({"step": "build", "ok": True, "service": svc, "services": svcs, "git_sha": sha, "tag": tag, "digest": digest,
                  "baseline_digest": bases[svc], "baselines": bases, "base": bkey or None}))
PY
echo "build: pushed $pub = $digest" >&2
