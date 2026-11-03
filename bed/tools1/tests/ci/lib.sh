# Shared by the ci tests (sourced): a fake /opt/rbd (RBD_OPT, with part B's rbd-env.sh and lock.sh, the kit's Dockerfile and
# spec.json) and /var/lib/rbd under a scratch folder, the stubs of
# fakebin/ first on PATH (aws, docker, cosign, kubectl never run for real), the REAL rhobound CLI as $TROOT/bin/rhobound.
# shellcheck shell=bash disable=SC2034  # CI, NOW_FIT, ...: used by the tests that source this file
HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
KIT=$(cd "$HERE/../../.." && pwd)
CI=$KIT/tools1/ci
CLI=${RHOBOUND:-$KIT/build/rhobound-local}
SCR=${SCRATCH:-${RBD_SCRATCH:-${TMPDIR:-/tmp}/rbd}/partD}
NOW_FIT=2026-10-22T06:00:00Z   # within max_fit_age_h of the fixture fit (a real 2026-10-22 rs2 window)
PIN=$(sha256sum "$(dirname "${BASH_SOURCE[0]}")/fixtures/repo-day1/policy/gate.json" | cut -d' ' -f1)   # RBD_POLICY_SHA256 of the day-1 main the tests build from (repo/ follows GitHub main)
# RBD_POLICY_DIGEST (contract 1): the CLI's gate.json digests.policy for the pinned policy, as the bootstrap writes it.
# Written here, not computed: t_flow.sh checks the real CLI's gate against it and fails loudly when they differ.
PDIG=sha256:c2ab0e1fa42fd249597a1b9e253340d4cd24d4e18e970183518b0018496805bb
PASS=0 FAILS=0
ok() { PASS=$((PASS + 1)); echo "  ok   $*"; }
bad() { FAILS=$((FAILS + 1)); echo "  FAIL $*"; }
check() { local d=$1; shift; if "$@"; then ok "$d"; else bad "$d"; fi; }
last() { tail -n 1 "$1"; }
jget() { python3 -I -c 'import json,sys; d=json.loads(sys.argv[1])
for k in sys.argv[2].split("."): d=d[int(k)] if isinstance(d,list) else d.get(k)
print("" if d is None else (json.dumps(d) if isinstance(d,(dict,list,bool)) else d))' "$1" "$2"; }
fget() { jget "$(cat "$1")" "$2"; }
done_summary() { echo "  -- $PASS passed, $FAILS failed"; [[ $FAILS -eq 0 ]]; }

mkenv() { # mkenv NAME: T (scratch), TROOT (/opt/rbd), THOME (/var/lib/rbd), STUB_DIR
  T=$SCR/t-$1
  rm -rf "$T"
  TROOT=$T/opt THOME=$T/var
  mkdir -p "$TROOT/bin" "$TROOT/lib" "$TROOT/maze" "$TROOT/ci" "$TROOT/etc" "$THOME/state" "$THOME/runs" \
    "$T/stub/k8s" "$T/stub/ecr" "$T/stub/s3" "$T/stub/att"
  cp "$HERE/fakebin/aws" "$HERE/fakebin/docker" "$HERE/fakebin/cosign" "$HERE/fakebin/kubectl" "$TROOT/bin/"
  ln -s "$CLI" "$TROOT/bin/rhobound"
  cp "$HERE/fakebin/refit.sh" "$TROOT/ci/refit.sh"
  # the kit as part B ships it (tools1/lib, tools1/maze) when present, else stand-ins
  local k
  cp "$KIT/tools1/maze/Dockerfile" "$TROOT/maze/Dockerfile"
  # spec.json: the fixture world's (fixtures/repo-day1: the ten kshop-shaped services, each with an image; catalog and
  # pricing share one), so the tests exercise the generic CI logic and the one-image rules, not maze's 32 services
  cp "$REPO0/maze/spec.json" "$TROOT/maze/spec.json"
  # the kit's bases.json (CI v2 base keys), plus a stand-in go127 when the kit has none yet (never a real digest)
  python3 -I - "$KIT/tools1/maze/bases.json" "$TROOT/maze/bases.json" << 'PY'
import hashlib, json, os, sys
src, dst = sys.argv[1:3]
b = json.load(open(src)) if os.path.exists(src) else {}
b.setdefault("go1269", "golang:1.26.9-bookworm@sha256:d9c68c2c51161e12fd77e4c6320687c9cd86e1af1e3ad6e6cd63ff970641453c")
b.setdefault("go127", "golang:1.27.2-bookworm@sha256:" + hashlib.sha256(b"go127 test stand-in").hexdigest())
json.dump(b, open(dst, "w"), indent=1)
PY
  cat > "$TROOT/etc/rbd.env" << EOF
RBD_REGION=ap-south-1
RBD_ACCOUNT=123456789012
RBD_BUCKET=rhobound-research-123456789012-ap-south-1
RBD_ECR=123456789012.dkr.ecr.ap-south-1.amazonaws.com/rhobound-demo/maze
RBD_KMS=awskms:///alias/rhobound-demo-verdict
KUBECONFIG=$TROOT/etc/kubeconfig
RHOBOUND_STATE=$THOME/state
RBD_HOME=$THOME
RBD_REPO=Sharvil2704/rhobound-maze-bed
RBD_POLICY_SHA256=$PIN
RBD_POLICY_DIGEST=$PDIG
EOF
  if [[ -r $KIT/tools1/lib/rbd-env.sh && -r $KIT/tools1/lib/lock.sh ]]; then
    cp "$KIT/tools1/lib/rbd-env.sh" "$KIT/tools1/lib/lock.sh" "$TROOT/lib/"
    LIBSRC="part B's tools1/lib"
  else
    # shellcheck disable=SC2016  # written literally: the stand-in expands them when sourced
    { echo 'set -a; . "$RBD_ENV_FILE"; set +a'; echo 'export RBD_OPT=${RBD_OPT:-/opt/rbd}'; } > "$TROOT/lib/rbd-env.sh"
    # shellcheck disable=SC2016
    printf '%s\n' 'rbd_lock() { exec 9>> "$RBD_HOME/lock"; flock -w "${1:-60}" 9 && export RBD_LOCK_HELD=$$; }' \
      'rbd_unlock() { flock -u 9; exec 9>&-; unset RBD_LOCK_HELD; }' 'rbd_lock_holder() { echo unknown; }' > "$TROOT/lib/lock.sh"
    LIBSRC="stand-ins (part B's tools1/lib missing)"
  fi
  : > "$T/stub/calls.log"
  export RBD_OPT=$TROOT RBD_ENV_FILE=$TROOT/etc/rbd.env STUB_DIR=$T/stub PATH=$TROOT/bin:$PATH
  unset SUDO_USER RBD_TEST_NOW JUDGE_CMD STUB_ROLLOUT_RC STUB_REFIT_RC STUB_BUILD_RC STUB_COSIGN_VERSION \
    STUB_DESCRIBE_DIGEST STUB_PUSH_QUIET STUB_NO_REPODIGEST STUB_ROLLOUT_FAIL
  [[ $(command -v aws) == "$TROOT/bin/aws" && $(command -v kubectl) == "$TROOT/bin/kubectl" ]] ||
    { echo "stubs are not first on PATH: refusing to run" >&2; exit 2; }
}

setpin() { # setpin [SHA256]: RBD_POLICY_SHA256 in the test rbd.env set to SHA256, or removed (setpin "$PIN" restores it)
  sed -i '/^RBD_POLICY_SHA256=/d' "$TROOT/etc/rbd.env"
  [[ -z ${1:-} ]] || echo "RBD_POLICY_SHA256=$1" >> "$TROOT/etc/rbd.env"
}

setdig() { # setdig [VALUE]: RBD_POLICY_DIGEST in the test rbd.env set to VALUE, or removed (setdig "$PDIG" restores it)
  sed -i '/^RBD_POLICY_DIGEST=/d' "$TROOT/etc/rbd.env"
  [[ -z ${1:-} ]] || echo "RBD_POLICY_DIGEST=$1" >> "$TROOT/etc/rbd.env"
}

# the day-1 main (2026-10-30, 493b9d659ba1) that c1..c4 are cut from: repo/ itself follows GitHub main (after PR 1's merge)
REPO0=$HERE/fixtures/repo-day1
mkrepo() { # mkrepo DIR: the day-1 repo/ as the main branch of a fresh git repo
  rm -rf "$1"
  mkdir -p "$1"
  cp -a "$REPO0/." "$1/"
  git -C "$1" init -q -b main
  git -C "$1" add -A
  git -C "$1" -c user.name=t -c user.email=t@example.com commit -qm "main"
}

branch() { # branch DIR NAME 'shell commands run in DIR' -> prints the head sha; leaves DIR checked out at it
  local dir=$1 name=$2 cmds=$3
  git -C "$dir" checkout -q -B "$name" main
  (cd "$dir" && eval "$cmds")
  git -C "$dir" add -A
  git -C "$dir" -c user.name=t -c user.email=t@example.com commit -qm "$name" --allow-empty
  git -C "$dir" rev-parse HEAD
}

mkbaseline() { # baseline.json: every service at a fake production digest, the fixture fit; the cluster stub runs those images
  local fitdir=$THOME/captures/prod/fit
  mkdir -p "$fitdir"
  cp "$HERE/fixtures/fit.json" "$fitdir/fit.json"
  python3 -I - "$THOME/baseline.json" "$fitdir" "$REPO0/maze/spec.json" "$T/stub/k8s" << 'PY'
import hashlib, json, os, sys
path, fitdir, spec, k8s = sys.argv[1:5]
ecr = "123456789012.dkr.ecr.ap-south-1.amazonaws.com/rhobound-demo/maze"
svcs = {s: "sha256:" + hashlib.sha256(("prod-" + s).encode()).hexdigest() for s in json.load(open(spec))["services"]}
fd = "sha256:" + hashlib.sha256(open(os.path.join(fitdir, "fit.json"), "rb").read()).hexdigest()
json.dump({"schema": "rbd.baseline/v1", "services": svcs, "image_ref": ecr, "fit": {"dir": fitdir, "digest": fd},
           "capture": "prod", "updated_at": "2026-10-22T05:23:00Z"}, open(path, "w"), indent=1)
for s, d in svcs.items():
    open(os.path.join(k8s, s + ".image"), "w").write(ecr + "@" + d)
PY
}

ab_standin() { # ab_standin RUN RECORD [nostore]: what ab.sh leaves: runs/RUN/ab/{ab.json, record/ab-record.json}, the store copy
  mkdir -p "$THOME/runs/$1/ab/record" "$THOME/state/ab"
  cp "$2" "$THOME/runs/$1/ab/record/ab-record.json"
  [[ ${3:-} == nostore ]] || cp "$2" "$THOME/state/ab/$(sha256sum "$2" | cut -d' ' -f1).json"
  python3 -I - "$THOME/runs/$1" "$2" << 'PY'
import hashlib, json, os, sys
run, rec = sys.argv[1:3]
c = json.load(open(os.path.join(run, "candidate.json")))
json.dump({"schema": "rbd.ab/v1", "run": c["git_sha"], "service": c["service"], "ok": True, "base_digest": c["baseline_digest"],
           "cand_digest": c["digest"], "record": {"path": "record/ab-record.json",
           "sha256": "sha256:" + hashlib.sha256(open(rec, "rb").read()).hexdigest()}}, open(os.path.join(run, "ab", "ab.json"), "w"))
PY
}

# ---- CI v2 (multi-service, base key) ----
derive_record() { # derive_record SRC SVC OUT: the auth A/B record SRC as a record of SVC (the service names replaced, bytes
  # otherwise as diff-fit wrote them; the store finds a record by the sha256 of its bytes, so OUT is a distinct record)
  python3 -I - "$1" "$2" "$3" << 'PY'
import sys
src, svc, out = sys.argv[1:4]
b = open(src, "rb").read()
for old, new in ((b'"service":"auth"', b'"service":"%s"'), (b'"auth@a"', b'"%s@a"'), (b'"auth@b"', b'"%s@b"')):
    assert b.count(old) == 1, (src, old)
    b = b.replace(old, new % svc.encode())
open(out, "wb").write(b)
PY
}

ab_standin_svc() { # ab_standin_svc RUN SVC RECORD [nostore] [DIR]: what ab.sh RUN SVC BASE CAND ab-SVC leaves (the arms named
  # by candidate-SVC.json): runs/RUN/DIR/{ab.json, record/ab-record.json} (DIR: ab-SVC), and the store copy
  local d=${5:-ab-$2}
  mkdir -p "$THOME/runs/$1/$d/record" "$THOME/state/ab"
  cp "$3" "$THOME/runs/$1/$d/record/ab-record.json"
  [[ ${4:-} == nostore ]] || cp "$3" "$THOME/state/ab/$(sha256sum "$3" | cut -d' ' -f1).json"
  python3 -I - "$THOME/runs/$1" "$2" "$3" "$d" << 'PY'
import hashlib, json, os, sys
run, svc, rec, d = sys.argv[1:5]
c = json.load(open(os.path.join(run, "candidate-%s.json" % svc)))
json.dump({"schema": "rbd.ab/v1", "run": c["git_sha"], "service": svc, "ab_dir": d, "ok": True,
           "base_digest": c["baseline_digest"], "cand_digest": c["digest"], "record": {"path": "record/ab-record.json",
           "sha256": "sha256:" + hashlib.sha256(open(rec, "rb").read()).hexdigest()}}, open(os.path.join(run, d, "ab.json"), "w"))
PY
}

goimage_dockerfile() { # the test kit's Dockerfile with ARG GO_IMAGE (its default: the FROM image) and FROM ${GO_IMAGE}, when the
  # kit's own does not have them yet (another part adds them to tools1/maze/Dockerfile)
  python3 -I - "$TROOT/maze/Dockerfile" << 'PY'
import re, sys
p = sys.argv[1]
t = open(p).read()
if not re.search(r"(?m)^ARG GO_IMAGE", t):
    t = re.sub(r"(?m)^FROM (\S+@sha256:[0-9a-f]{64}) AS build$", lambda m: "ARG GO_IMAGE=%s\nFROM ${GO_IMAGE} AS build" % m.group(1), t,
               count=1)
    assert re.search(r"(?m)^FROM \$\{GO_IMAGE\} AS build$", t), "no pinned FROM ... AS build line"
    open(p, "w").write(t)
PY
}

v2req() { # v2req SERVICES-JSON-LIST [BASE]: a rbd.change-request/v2 rhobound-change.json in the current folder
  python3 -I -c 'import json,sys; r={"schema": "rbd.change-request/v2", "services": json.loads(sys.argv[1]), "summary": "fold: strip accents"}
if len(sys.argv) > 2: r["base"] = sys.argv[2]
open("rhobound-change.json", "w").write(json.dumps(r) + "\n")' "$@"
}
export -f v2req

# hostile_git REPO MARKS: what a PR's own workflow (ghrunner owns the checkout) can put in the runner-owned .git/: every config
# key, hook, include and attribute that names a command; each command touches MARKS/<name>. Set AFTER the test's own git work
# in REPO (the test's git would run them too). Round-1 recheck PoCs: .tmp-demo/fix1/recheck1/prcheck/poc_*.sh, lazy/poc.sh.
hostile_git() {
  local s=$1 m=$2 h
  mkdir -p "$m" "$s/.git/evil-hooks" "$s/.git/info"
  for h in pre-commit post-checkout post-merge post-rewrite reference-transaction post-index-change pre-auto-gc; do
    printf '#!/bin/sh\ntouch "%s/hook-%s"\n' "$m" "$h" > "$s/.git/evil-hooks/$h"
    chmod +x "$s/.git/evil-hooks/$h"
  done
  printf '[uploadpack]\n\tpackObjectsHook = touch %s/packobjectshook; false\n[core]\n\taskPass = touch %s/askpass\n' "$m" "$m" \
    > "$s/.git/evil-include"
  git -C "$s" config core.repositoryformatversion 1
  git -C "$s" config extensions.partialClone x
  git -C "$s" config remote.x.url "$s"
  git -C "$s" config remote.x.promisor true
  git -C "$s" config remote.x.uploadpack "touch $m/uploadpack; false"
  git -C "$s" config core.fsmonitor "touch $m/fsmonitor; false"
  git -C "$s" config core.hooksPath "$s/.git/evil-hooks"
  git -C "$s" config core.pager "touch $m/pager; cat"
  git -C "$s" config core.sshCommand "touch $m/ssh; false"
  git -C "$s" config core.alternateRefsCommand "touch $m/alternaterefs; false"
  git -C "$s" config diff.external "touch $m/diffexternal; false"
  git -C "$s" config diff.evil.textconv "touch $m/textconv; cat"
  git -C "$s" config diff.evil.command "touch $m/diffcommand; false"
  git -C "$s" config filter.evil.clean "touch $m/clean; cat"
  git -C "$s" config filter.evil.smudge "touch $m/smudge; cat"
  git -C "$s" config filter.evil.process "touch $m/process; false"
  git -C "$s" config include.path "$s/.git/evil-include"
  printf '* filter=evil diff=evil\n' > "$s/.git/info/attributes"
}

# hostile_env MARKS REPO CMD...: CMD with a caller environment whose git config names a command (a lazy fetch's uploadpack,
# an fsmonitor) and points GIT_DIR at REPO. sudo's env_reset drops it; the steps unset GIT_* themselves too.
hostile_env() {
  local m=$1 s=$2
  shift 2
  env GIT_CONFIG_COUNT=4 GIT_CONFIG_KEY_0=extensions.partialClone GIT_CONFIG_VALUE_0=y \
    GIT_CONFIG_KEY_1=remote.y.promisor GIT_CONFIG_VALUE_1=true GIT_CONFIG_KEY_2=remote.y.url GIT_CONFIG_VALUE_2="$s" \
    GIT_CONFIG_KEY_3=remote.y.uploadpack GIT_CONFIG_VALUE_3="touch $m/env-uploadpack; false" \
    GIT_CONFIG_PARAMETERS="'core.fsmonitor'='touch $m/env-fsmonitor; false' 'core.hookspath'='$s/.git/evil-hooks'" \
    GIT_DIR="$s/.git" GIT_WORK_TREE="$s" "$@"
}
nomarks() { [[ -z $(marks "$1") ]]; }   # nomarks MARKS: no hostile command ran
marks() { find "$1" -mindepth 1 -printf '%f ' 2> /dev/null; }   # marks MARKS: the hostile commands that ran

# lockrun FILE: holds a flock on FILE in the background (LOCKPID) until killed, like a concurrent step of the same run
lockrun() {
  (exec 8>> "$1" && flock 8 && exec sleep 60) &   # the holder IS the sleep: killing it releases the lock
  LOCKPID=$!
  local i
  for i in $(seq 1 50); do flock -n "$1" true 2> /dev/null || return 0; sleep 0.1; done
  return 1
}
unlockrun() { kill "$LOCKPID" 2> /dev/null; wait "$LOCKPID" 2> /dev/null; return 0; }
