#!/usr/bin/env bash
# verify/candidate.sh: the image digests the bed's CI built for a PR head, as truthx.sh's input. On rbd-tools1 as user rbd;
# READ-ONLY (files and /proc/locks only: it writes nothing, takes no lock, runs no kubectl, docker or aws).
#   candidate.sh HEAD_SHA [--wait S] [--poll S]
# Waits (bounded: --wait S, RBD_CAND_WAIT [1200] s; 0 = look once) until the gate's build step has finished for HEAD_SHA, then
# prints one line per service of the change, in the change request's order:   SVC=sha256:<64 hex>
# (stdout holds only those lines: truthx.sh NAME $(candidate.sh HEAD) is the intended use; messages go to stderr).
# Where the build step records them (tools1/ci/build.sh, called by the bed's gate.yml 'build the candidate image' step):
#   $RBD_HOME/runs/HEAD/pr.json              pr-check's record (rbd.pr-check/v1): head_sha, services (the change's services)
#   $RBD_HOME/runs/HEAD/candidate-SVC.json   rbd.candidate/v1 per listed service: git_sha, service, services, digest, image
#   $RBD_HOME/runs/HEAD/candidate.json       the first service's record, written LAST (each file by temp + rename): its
#                                            presence means the build step finished and every candidate-SVC.json is there
# Checked: pr.json's head_sha is HEAD; each record's schema, service, git_sha (= HEAD), services (= pr.json's), digest
# (sha256:<64 hex>) and image (= RBD_ECR@digest). A build that failed leaves no candidate.json: once its log
# (logs/build-<first service>.log, not older than pr.json) exists and no CI step holds runs/HEAD/.lock any more (seen in
# /proc/locks, never by taking it: every CI step takes that lock with flock -n, so even a probe could make a starting step
# fail), the build is over.
# Exit: 0 printed; 1 refused or the build ended without a candidate (or records disagree); 2 usage; 4 timed out (the tail of
# the build log, if any, on stderr). Env: RBD_LIB [/opt/rbd/lib] (rbd-env.sh: RBD_HOME, RBD_ECR), RBD_CAND_WAIT, RBD_CAND_POLL [5].
set -euo pipefail
usage() { echo "usage: $0 HEAD_SHA [--wait S] [--poll S]" >&2; exit 2; }
WHO=candidate
# shellcheck source=vlib.sh
. "$(dirname "$(readlink -f "$0")")/vlib.sh"
WAIT=${RBD_CAND_WAIT:-1200}; POLL=${RBD_CAND_POLL:-5}; HEAD=
while (($#)); do
  case $1 in
    --wait) (($# >= 2)) || usage; WAIT=$2; shift 2 ;;
    --poll) (($# >= 2)) || usage; POLL=$2; shift 2 ;;
    -h | --help) sed -n '2,19p' "$0"; exit 0 ;;
    -*) usage ;;
    *) [[ -z $HEAD ]] || usage; HEAD=$1; shift ;;
  esac
done
[[ $HEAD =~ ^[0-9a-f]{40}$ ]] || { echo "HEAD_SHA: a 40-hex commit id" >&2; usage; }
if ! [[ $WAIT =~ ^[0-9]+$ && $POLL =~ ^[1-9][0-9]*$ ]]; then echo "--wait, --poll: whole seconds (poll >= 1)" >&2; usage; fi
env_load
RUN=$RBD_HOME/runs/$HEAD
[[ $HEAD != "$(head -c 64 -- "$RBD_HOME/src/main.sha" 2> /dev/null || true)" ]] ||
  vdie "$HEAD is main as the bootstrap uploaded it (src/main.sha): production's own images, nothing to deploy"

red() { if [[ -n ${RBD_ACCOUNT:-} ]]; then sed -e "s/${RBD_ACCOUNT}/<account>/g"; else cat; fi | sed -E 's/[0-9]{12}(\.dkr\.ecr)/<account>\1/g'; }

inspect() {   # one look at runs/HEAD, as data: "READY" then SVC=DIGEST lines | "WAIT reason" | "NOCAND first-service" | "FAIL reason"
  python3 -I - "$RUN" "$HEAD" "$RBD_ECR" << 'PY'
import json, os, re, sys
run, head, ecr = sys.argv[1:4]
def out(*lines):
    print("\n".join(lines)); sys.exit(0)
def load(name):
    p = os.path.join(run, name)
    try:
        if os.path.getsize(p) > 1 << 20:
            out(f"FAIL runs/{head}/{name}: larger than 1 MiB")
        with open(p, encoding="utf-8") as f:
            return json.load(f)
    except FileNotFoundError:
        return None
    except (OSError, ValueError) as e:
        out(f"FAIL runs/{head}/{name}: not readable JSON ({e.__class__.__name__})")
SVC = re.compile(r"[a-z][a-z0-9-]{0,45}")
pr = load("pr.json")
if pr is None:
    out("WAIT no runs/HEAD/pr.json yet: pr-check has not admitted this head (gate queued, or refused)")
if not isinstance(pr, dict):
    out("FAIL pr.json is not an object")
if pr.get("head_sha") != head:
    out(f"FAIL pr.json head_sha {pr.get('head_sha')!r} is not {head}")
svcs = pr.get("services") or [pr.get("service")]
if not isinstance(svcs, list) or not svcs or not all(isinstance(s, str) and SVC.fullmatch(s) for s in svcs) \
        or len(set(svcs)) != len(svcs):
    out(f"FAIL pr.json services {svcs!r}: not a list of distinct service names")
first = load("candidate.json")
if first is None:
    out("NOCAND " + svcs[0])
lines = []
for s in svcs:
    rec = load(f"candidate-{s}.json")
    if rec is None:
        out(f"FAIL candidate.json exists but candidate-{s}.json does not (the build writes every service's record first)")
    if not isinstance(rec, dict) or rec.get("schema") != "rbd.candidate/v1":
        out(f"FAIL candidate-{s}.json is not rbd.candidate/v1")
    if rec.get("service") != s or rec.get("git_sha") != head:
        out(f"FAIL candidate-{s}.json names service {rec.get('service')!r} at {rec.get('git_sha')!r}, not {s} at {head}")
    if rec.get("services", [s]) != svcs:
        out(f"FAIL candidate-{s}.json services {rec.get('services')!r} differ from pr.json's {svcs!r}")
    d = rec.get("digest")
    if not isinstance(d, str) or not re.fullmatch(r"sha256:[0-9a-f]{64}", d):
        out(f"FAIL candidate-{s}.json digest {d!r} is not sha256:<64 hex>")
    if rec.get("image") != f"{ecr}@{d}":
        out(f"FAIL candidate-{s}.json image is not RBD_ECR@its digest")
    if rec.get("baseline_digest") == d:
        out(f"FAIL candidate-{s}.json: the candidate is production's own digest")
    print(f"candidate: {s} {d} (tag {rec.get('tag')}, built {rec.get('built_at')})", file=sys.stderr)
    lines.append(f"{s}={d}")
if not isinstance(first, dict) or first.get("git_sha") != head or first.get("service") != svcs[0] \
        or first.get("digest") != lines[0].split("=", 1)[1]:
    out(f"FAIL candidate.json is not candidate-{svcs[0]}.json of {head}")
out("READY", *lines)
PY
}

lock_held() {   # 0 if some process holds a flock on runs/HEAD/.lock now (/proc/locks holder rows; nothing is taken)
  local ino
  ino=$(stat -c %i -- "$RUN/.lock" 2> /dev/null) || return 1
  awk -v i=":$ino" '$2 == "FLOCK" && substr($6, length($6) - length(i) + 1) == i {f = 1} END {exit !f}' /proc/locks 2> /dev/null
}

t_end=$(($(date +%s) + WAIT)); said=
while :; do
  r=$(inspect) || vdie "cannot read runs/$HEAD (python3 failed)"
  kind=${r%%[$' \n']*}
  case $kind in
    READY) sed -n '2,$p' <<< "$r"; exit 0 ;;
    FAIL) vdie "${r#FAIL }" ;;
    NOCAND)
      blog=$RUN/logs/build-${r#NOCAND }.log
      why="the build step for runs/$HEAD has not finished (no candidate.json)"
      # the build ran (its log is not older than pr.json: a re-run's pr-check rewrites pr.json before its build starts) and no
      # step holds the run now: look once more (build.sh writes candidate.json before it exits), then it failed
      if [[ -e $blog && ! $RUN/pr.json -nt $blog ]] && ! lock_held; then
        r=$(inspect) || vdie "cannot read runs/$HEAD (python3 failed)"
        [[ ${r%%$'\n'*} != READY ]] || { sed -n '2,$p' <<< "$r"; exit 0; }
        { echo "--- last lines of $blog ---"; tail -n 15 -- "$blog" | red; } >&2 || true
        vdie "the build step for $HEAD ended without a candidate (no candidate.json, runs/$HEAD/.lock free): it failed"
      fi ;;
    WAIT) why=${r#WAIT } ;;
    *) vdie "unexpected answer from the record check: ${r:0:200}" ;;
  esac
  [[ $why == "$said" ]] || { vlog "waiting: $why"; said=$why; }
  if (($(date +%s) >= t_end)); then
    for blog in "$RUN"/logs/build-*.log; do
      [[ ! -f $blog ]] || { echo "--- last lines of $blog ---"; tail -n 15 -- "$blog" | red; } >&2 || true
    done
    vlog "FAIL: timed out after ${WAIT}s: $why"
    exit 4
  fi
  sleep "$POLL"
done
