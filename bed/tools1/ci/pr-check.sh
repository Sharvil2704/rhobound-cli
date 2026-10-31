#!/bin/bash
# pr-check: a PR may change only kshop/app/** and rhobound-change.json, and must add or update a valid change request:
#   rbd.change-request/v1 {schema, services: [exactly one service of the kit's spec.json], summary}, or
#   rbd.change-request/v2 {schema, services: [1..5 distinct services of spec.json], summary, base?}: base (optional) is a key
#   of the kit's kshop/bases.json (/opt/rbd/kshop/bases.json, root-owned: KEY -> Go builder image REF@sha256:<64 hex>; keys
#   starting with _ are not bases), the builder build.sh passes as --build-arg GO_IMAGE. summary: non-empty, <= 1000 chars.
# A PR whose only change is rhobound-change.json is admitted only when it names a base (SPEC2 T4: a builder change on the same
# code); without one there is nothing to build that main does not already run. A PR never carries a Dockerfile.
#   sudo -n -u rbd /opt/rbd/ci/pr-check.sh CHECKOUT BASE_SHA HEAD_SHA
# pr.json records service (the first), services (the list), base (null or the key), base_image and request_schema; the last
# stdout line names service, services (a list; gate.yml writes service= and services=a,b to GITHUB_OUTPUT) and base.
# Reads git objects only, by the two shas (never the working tree, never the checkout's HEAD: a symlink in a PR cannot point
# the step at a local file), through a fresh rbd-owned bare repository (RBD_HOME/tmp/pr-check.XXXXXX, removed after) that
# borrows the checkout's objects (objects/info/alternates): no config, hook, attribute or replace ref of the runner-owned .git/
# applies, so nothing it names (a lazy fetch's uploadpack, an fsmonitor, a filter) runs as rbd, and no GIT_* of the caller's
# environment is kept. The two shas' history is copied out of it as one pack into a second rbd-owned repository, where
# index-pack --strict names every object by its hashed content (git re-hashes no tree or blob read through alternates): a
# forged object in the runner-owned store is refused, and every later read is of rbd's copy. CHECKOUT/.git must be a real
# folder (not a gitdir: file or a symlink) with a real objects/ folder and no alternates of its own. A changed path with a VCS
# metadata component (.git .hg .svn .bzr .fslckout _FOSSIL_) is refused: go build would run that VCS's tool. Writes runs/HEAD_SHA/pr.json and runs/HEAD_SHA/policy.json (policy/gate.json at BASE_SHA, the
# policy predict.sh uses: the verified bytes, written to a fresh temporary file and renamed). That policy must be the pinned
# one: its sha256 = RBD_POLICY_SHA256 (rbd.env, written at bootstrap from main's policy/gate.json); refused otherwise or unset.
# Under runs/HEAD_SHA/.lock (flock; one step of a run at a time: pr-check, build, ab, predict, sign).
# Exit 0 admitted, 1 refused or failed. Last stdout line: one JSON object.
set -euo pipefail
STEP=pr-check
ci_jstr() { python3 -I -c 'import json,sys; print(json.dumps(sys.argv[1]))' "$1"; }
ci_fail() { echo "$STEP: refused: $1" >&2; printf '{"step":"%s","ok":false,"error":%s}\n' "$STEP" "$(ci_jstr "$1")"; exit 1; }
[[ $# -eq 3 ]] || ci_fail "usage: pr-check.sh CHECKOUT BASE_SHA HEAD_SHA"
CHECKOUT=$1 BASE=$2 HEAD=$3

RBD_ROOT=/opt/rbd
[[ -z ${SUDO_USER:-} && -n ${RBD_OPT:-} ]] && RBD_ROOT=$RBD_OPT   # tests only; sudo's env_reset never passes it
[[ -r $RBD_ROOT/lib/rbd-env.sh ]] || ci_fail "$RBD_ROOT/lib/rbd-env.sh missing"
# shellcheck source=/dev/null
ci_msg=$(. "$RBD_ROOT/lib/rbd-env.sh" 2>&1 > /dev/null) || ci_fail "rbd-env.sh: $ci_msg"
# shellcheck source=/dev/null
. "$RBD_ROOT/lib/rbd-env.sh"
[[ -n ${RBD_HOME:-} ]] || ci_fail "RBD_HOME not set by rbd-env.sh"
[[ ${RBD_POLICY_SHA256:-} =~ ^[0-9a-f]{64}$ ]] ||
  ci_fail "RBD_POLICY_SHA256 is not set to a sha256 (64 hex) in rbd.env (the bootstrap writes it): no policy without the pin"
SPEC_JSON=$RBD_ROOT/kshop/spec.json
[[ -r $SPEC_JSON ]] || ci_fail "$SPEC_JSON missing (the kit's kshop copy)"
BASES_JSON=$RBD_ROOT/kshop/bases.json   # read only when a v2 request names a base

[[ $BASE =~ ^[0-9a-f]{40}$ && $HEAD =~ ^[0-9a-f]{40}$ ]] || ci_fail "BASE_SHA and HEAD_SHA must be 40-hex commit ids"
# git as rbd never takes the caller's environment (GIT_CONFIG_*, GIT_DIR, ...), a system or global config, a lazy fetch or a
# replace ref
unset "${!GIT_@}"
export GIT_NO_LAZY_FETCH=1 GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null GIT_NO_REPLACE_OBJECTS=1 GIT_TERMINAL_PROMPT=0
CO=$(readlink -f -- "$CHECKOUT" || true)
OBJ=$CO/.git/objects
[[ -n $CO && $CO != *$'\n'* && -d $CO/.git && -d $OBJ && $(readlink -f -- "$OBJ") == "$OBJ" ]] ||
  ci_fail "$CHECKOUT is not a git checkout readable by $(id -un) with a real .git/objects folder (a .git 'gitdir:' file or a symlinked .git or objects/ is refused; the runner's _work must be o+rx)"
[[ ! -e $OBJ/info/alternates && ! -L $OBJ/info/alternates ]] ||
  ci_fail "$CHECKOUT/.git/objects/info/alternates exists: refused (pr-check reads the checkout's own objects only)"

RUN=$RBD_HOME/runs/$HEAD
mkdir -p "$RUN"
# one step of a run at a time (pr-check, build, ab, predict, sign): a flock on runs/RUN/.lock, held until this step exits
exec 7>> "$RUN/.lock" || ci_fail "cannot open runs/$HEAD/.lock"
flock -n 7 || ci_fail "another step of runs/$HEAD is running (runs/$HEAD/.lock is held): one step of a run at a time"
mkdir -p "$RBD_HOME/tmp"
BTMP=$(mktemp -d "$RBD_HOME/tmp/pr-check.XXXXXX") || ci_fail "cannot make a folder in $RBD_HOME/tmp"
trap 'rm -rf "$BTMP"' EXIT
{ git init -q --bare --template= --initial-branch=main "$BTMP/alt" && printf '%s\n' "$OBJ" > "$BTMP/alt/objects/info/alternates" &&
  git init -q --bare --template= --initial-branch=main "$BTMP/git"; } \
  2> "$BTMP/init.err" || ci_fail "cannot set up pr-check's repositories in $BTMP: $(tail -n 1 "$BTMP/init.err")"
ag() { git --git-dir="$BTMP/alt" "$@"; }   # borrows the checkout's objects: only read to pack the two shas' history
g() { git --git-dir="$BTMP/git" "$@"; }    # rbd's own copy, every object re-hashed: all reads after the copy
ag cat-file -e "$HEAD^{commit}" 2> /dev/null || ci_fail "HEAD_SHA $HEAD is not a commit in $CHECKOUT"
ag cat-file -e "$BASE^{commit}" 2> /dev/null || ci_fail "BASE_SHA $BASE is not in the checkout (fetch-depth 0?)"
{ printf '%s\n' "$BASE" "$HEAD" | ag pack-objects --revs --stdout | git --git-dir="$BTMP/git" index-pack --stdin --strict; } \
  > "$BTMP/pack.log" 2>&1 ||
  ci_fail "the objects of BASE_SHA and HEAD_SHA in $CHECKOUT fail index-pack --strict (a forged, broken or missing object): $(tail -n 1 "$BTMP/pack.log")"
raw=$(g diff --raw -z --no-renames --no-abbrev "$BASE...$HEAD" | tr '\0' '\n') || ci_fail "git diff $BASE...$HEAD failed"
req=$(g cat-file blob "$HEAD:rhobound-change.json" 2> /dev/null) || ci_fail "no rhobound-change.json at the PR head"
g cat-file blob "$BASE:policy/gate.json" > "$BTMP/policy.json" 2> /dev/null || ci_fail "no policy/gate.json at BASE_SHA"

RAW=$raw REQ=$req python3 -I - "$SPEC_JSON" "$RUN" "$BASE" "$HEAD" "$RBD_POLICY_SHA256" "$BTMP/policy.json" "$BASES_JSON" <<'PY'
import datetime, hashlib, json, os, re, sys, tempfile
spec_path, run, base, head, pin, pol_path, bases_path = sys.argv[1:8]
def refuse(msg):
    print("pr-check: refused: " + msg, file=sys.stderr)
    print(json.dumps({"step": "pr-check", "ok": False, "error": msg}))
    sys.exit(1)
def put(name, data):  # a fresh temporary file of these bytes, renamed: never a path written or checked earlier
    fd, tmp = tempfile.mkstemp(dir=run, prefix="." + name + ".")
    with os.fdopen(fd, "wb") as f:
        f.write(data)
    os.chmod(tmp, 0o644)
    os.replace(tmp, os.path.join(run, name))
# --raw -z lines: ":oldmode newmode oldsha newsha STATUS" then the path
lines = os.environ["RAW"].split("\n")
files, i = [], 0
while i < len(lines):
    if not lines[i].startswith(":"):
        i += 1
        continue
    meta, path = lines[i][1:].split(" "), lines[i + 1]
    files.append((meta[4], meta[1], path))
    i += 2
if not files:
    refuse("the PR changes no file")
bad = [p for (_, _, p) in files if not (p == "rhobound-change.json" or p.startswith("kshop/app/"))]
if bad:
    refuse("files outside kshop/app/** and rhobound-change.json: " + ", ".join(sorted(bad))[:400])
vcs = [p for (_, _, p) in files if {".git", ".hg", ".svn", ".bzr", ".fslckout", "_FOSSIL_"} & set(p.split("/"))]
if vcs:
    refuse("VCS metadata is not allowed (go build would run that VCS's tool): " + ", ".join(sorted(vcs))[:400])
links = [p for (_, m, p) in files if m in ("120000", "160000")]
if links:
    refuse("symlinks or submodules are not allowed: " + ", ".join(sorted(links))[:400])
st = {p: s for (s, _, p) in files}
if st.get("rhobound-change.json", "D") == "D":
    refuse("the PR must add or update rhobound-change.json (the change request of THIS change)")
try:
    req = json.loads(os.environ["REQ"])
except ValueError as e:
    refuse("rhobound-change.json is not JSON: %s" % e)
V1, V2 = "rbd.change-request/v1", "rbd.change-request/v2"
schema = req.get("schema") if isinstance(req, dict) else None
if schema not in (V1, V2):
    refuse('rhobound-change.json: "schema" must be "%s" or "%s"' % (V1, V2))
extra = sorted(set(req) - ({"schema", "services", "summary"} | ({"base"} if schema == V2 else set())))
if extra:
    refuse("rhobound-change.json: unknown keys " + ", ".join(extra))
names = sorted(json.load(open(spec_path))["services"])
svcs = req.get("services")
if schema == V1:
    if not isinstance(svcs, list) or len(svcs) != 1 or not isinstance(svcs[0], str):
        refuse('rhobound-change.json: "services" must list exactly one service (v1)')
elif (not isinstance(svcs, list) or not 1 <= len(svcs) <= 5 or not all(isinstance(x, str) for x in svcs)
      or len(set(svcs)) != len(svcs)):
    refuse('rhobound-change.json: "services" must list 1 to 5 distinct services (v2)')
for x in svcs:
    if x not in names:
        refuse("rhobound-change.json: unknown service %r (one of: %s)" % (x, ", ".join(names)))
summ = req.get("summary")
if not isinstance(summ, str) or not summ.strip():
    refuse('rhobound-change.json: "summary" must be a non-empty string')
if len(summ) > 1000:
    refuse('rhobound-change.json: "summary" is longer than 1000 characters')
bkey = req.get("base")   # v2 only (v1 refuses the key above); null = no base
bimage = None
if bkey is not None:
    if not isinstance(bkey, str) or not re.fullmatch(r"[a-z0-9][a-z0-9._-]{0,31}", bkey):
        refuse('rhobound-change.json: "base" must be a key of the kit\'s kshop/bases.json (lower-case letters, digits, . _ -)')
    try:
        bases = json.load(open(bases_path))
    except (OSError, ValueError) as e:
        refuse("the kit's %s is missing or not JSON (%s): no base can be admitted" % (bases_path, e))
    if not isinstance(bases, dict) or bkey not in bases:
        known = sorted(k for k in (bases if isinstance(bases, dict) else {}) if not k.startswith("_"))
        refuse("rhobound-change.json: unknown base %r (one of: %s)" % (bkey, ", ".join(known)))
    bimage = bases[bkey].get("image") if isinstance(bases[bkey], dict) else bases[bkey]
    if not isinstance(bimage, str) or not re.fullmatch(r"[a-z0-9][a-z0-9._/:-]*@sha256:[0-9a-f]{64}", bimage):
        refuse("the kit's bases.json %r is not an image pinned by digest (REF@sha256:<64 hex>): %r" % (bkey, bimage))
if all(p == "rhobound-change.json" for (_, _, p) in files) and bkey is None:
    refuse("the PR changes only rhobound-change.json and names no base: nothing to build that main does not already run"
           " (change kshop/app, or name a base of the kit's bases.json)")
pol = open(pol_path, "rb").read()   # read once: these bytes are checked and written
psha = hashlib.sha256(pol).hexdigest()
if pin != psha:
    refuse("policy/gate.json at BASE_SHA (sha256 %s) is not the pinned policy RBD_POLICY_SHA256 (%s)" % (psha, pin))
try:
    json.loads(pol)
except ValueError:
    refuse("policy/gate.json at BASE_SHA is not JSON")
now = datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
rec = {"schema": "rbd.pr-check/v1", "base_sha": base, "head_sha": head, "service": svcs[0], "services": svcs,
       "base": bkey, "base_image": bimage, "request_schema": schema, "summary": summ.strip(),
       "files": [{"path": p, "status": s} for (s, _, p) in files], "policy_sha256": "sha256:" + psha, "checked_at": now}
put("policy.json", pol)
put("pr.json", (json.dumps(rec, indent=1, sort_keys=True) + "\n").encode())
print("pr-check: ok: %s%s, %d file(s), policy sha256:%s" % (",".join(svcs), "" if bkey is None else " (base %s)" % bkey,
      len(files), psha[:12]), file=sys.stderr)
print(json.dumps({"step": "pr-check", "ok": True, "service": svcs[0], "services": svcs, "base": bkey, "files": len(files),
                  "head_sha": head}))
PY
