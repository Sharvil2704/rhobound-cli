#!/usr/bin/env bash
# muse_arm.sh TICKET ARM [--max-iter N] [--tag T]   one arm of the Muse Code experiment (reports/muse-live/DECLARE.md), driven from
#   your workstation: the agent on rbd-tools1, the untrusted-output checks here, the hidden tests, a PR, then the arm's way to
#   production, measured by the truth bracket; at most N iterations (default 3 = 1 + 2 revisions). ARM: R (rhobound) or C
#   (chaotic). Every phase is appended to state/muse/TICKET-ARM/timeline.json at once (UTC timestamps, atomic replace), so
#   a run cut short (the machines stop at about 05:20Z) still leaves a scorable record; one folder per iteration (iter-0i).
# muse_arm.sh TICKET C --collect [--tag T] arm C's counterfactual only: for every head of the timeline that has no final gate
#   verdict yet, wait (MUSE_CF_WAIT) for the rhobound/verdict CI computed anyway and fetch its gate artifacts; then close the
#   superseded PRs whose verdict is in
# --max-iter N: 1..3 (task.sh's MUSE_MAX_ITER is 3, and sudo keeps no environment). --tag T ([a-z0-9], at most 6): a new
#   attempt of an arm that already ran: RUN = mx-TICKET-ARM-T, state/muse/TICKET-ARM-T (task.sh refuses a RUN-iI session that
#   ran, truthx.sh a NAME that exists: an attempt is never re-run under its old names)
# Iteration i (RUN = mx-TICKET-ARM; RI = RUN-ii, e.g. mx-T5-R-i1: task.sh's OUT name; OUT = /var/lib/rbd/agent/RI on
# rbd-tools1, Muse's own records in /var/lib/rbd/muse/runs/RUN/ii; here: state/muse/TICKET-ARM/iter-0i):
#   preflight  the arguments; one arm at a time; no earlier timeline for TICKET-ARM[-T]; no kill switch; the threshold; gh
#              logged in; MUSE_TASK, MUSE_HIDDEN, MUSE_TRUTHX and MUSE_CANDIDATE executable on rbd-tools1 and its
#              src/main.sha = MUSE_MAIN_SHA [kit/state/main.sha] (what agent_take.sh compares; read-only, as rbd)
#   0 names    CHANGE = the next free cN-muse (reserved under a lock), the truth name = lowercase mx-ticket-arm-ii
#   1 agent    on rbd-tools1 as root, detached: MUSE_TASK ARM TICKET i RUN [FEEDBACK] (tools1/muse/task.sh; the previous
#              iteration's feedback put to /var/lib/rbd/muse/feedback/RI.feedback.md); waits for its exit. OUT's result.json
#              and usage.json (rbd.muse-usage/v1), read here as data -> iter-II/agent.json: model steps, tool calls, tokens,
#              rhobound MCP calls, Stop reminders, session wall time (no usage.json: Muse's raw events.jsonl/session.jsonl
#              from the runs folder, kept verbatim as iter-II/agent/*.raw, the only files here that are not redacted).
#              Exit 0 a change is in OUT; 1 OUT holds result.json ok:false: its errors are the feedback (no take); 2, 3, 4
#              (usage or state, the export failed, the user's lock) are the harness's: the arm stops
#   2 take     MUSE_AGENT_TAKE RI CHANGE (orch/agent_take.sh: the untrusted-output checks, compiled, never run). Exit 3: the
#              compile errors (state/agent/RI.compile.txt) are the next iteration's feedback; exit 1: its refusal lines are
#              (a fetch, size, base or main.sha failure is the harness's: the arm stops)
#   3 hidden   on rbd-tools1 as root, detached: MUSE_HIDDEN ARM TICKET RUN i (tools1/muse/hidden.sh). Exit 0 pass; 1 fail:
#              its runs/RUN/ii/hidden.json (failed tests, missing, build_failed, output_tail) is the feedback, nothing is
#              deployed; any other exit (3 the check could not run, 2, 4) stops the arm (the harness, not the agent)
#   4 pr       MUSE_MAKE_PRS CHANGE (changes/make_prs.sh: label rbd-muse, never merged); gh pr list -> the PR and its head.
#              Arm R closes the superseded PR (the previous iteration's) here; arm C after its counterfactual verdict is in
#   5 R gate   the newest commit status rhobound/verdict on that head (created by MUSE_STATUS_CREATOR), waited for up to
#              MUSE_GATE_WAIT s; the gate.yml run's times; runs/HEAD/{predict.json, gate/gate.json} from rbd-tools1 file by
#              file. Not pass -> the feedback is the verdict, the rules that decided it and decide_with; next iteration. An
#              'error' status at pr-check or build is the agent's (fed back); after the build it is the harness's (stop).
#              Then MUSE_CANDIDATE names the images; the passed digest must be the gate's candidate_digest
#     C build  only the image: MUSE_CANDIDATE HEAD --wait 0 on rbd-tools1 as rbd (verify/candidate.sh: SVC=DIGEST lines; exit
#              4 not yet, 1 the build ended without an image; MUSE_CANDIDATE empty: runs/HEAD/candidate.json read directly),
#              polled up to MUSE_BUILD_WAIT s; a build that failed (the gate's status 'no signed verdict: pr-check|build') is
#              fed back. The gate keeps running in CI: its verdict is the counterfactual, recorded later
#   6 measure  orch/rbd.sh bg: env RBD_LOCK_WAIT=MUSE_LOCK_WAIT MUSE_TRUTHX NAME SVC=DIGEST... (verify/truthx.sh: B0 window,
#              every listed service on its candidate, warm-up, C window, rollback); then verify/truthx/NAME/{truth.json,
#              b0.load.json, c.load.json} fetched and MUSE_REGRESS --b0 B0 --c C --policy MUSE_POLICY --out FILE
#              (verify/regress.py, rbd.regress/v1; absent: the same rule here: an entry regresses when C - B0 > T, T =
#              max_entry_mean_change_ms; errors up when C's error share exceeds B0's by more than 1 point). The bracket's
#              phases (lock wait, B0 settle, B0, rollout, warm-up, C, rollback, settle) join the timeline from truth.json.
#              truthx exit 4 (the rollback failed) stops everything (exit 4); any other failure stops the arm
#   7 outcome  accepted = deployed + hidden pass + production_ok (no entry over its threshold, no error increase): the arm
#              stops. Otherwise (either arm) the feedback is the measured entry changes and 'rolled back'; next iteration
# After the last iteration: arm C waits up to MUSE_CF_WAIT s for the counterfactual verdict of each head (as --collect).
# PRs: superseded ones are closed (gh pr close, never merged, the branch kept: its commit statuses stay readable); the last
# iteration's PR is left open for the record. Nothing here merges, pushes main, or runs kubectl, aws or docker.
# Kill switch: state/muse/STOP (checked before every agent session, PR and deploy): exit 5. state/automerge.stop is not
# one: it stops merges, and nothing here merges.
# One arm at a time (flock state/muse/.driver.lock): two arms on one cluster would share its lock and spoil the timings.
# Model output is untrusted data: everything fetched is read with python3 -I, regular files only, size-capped; the feedback
# fed back is printable text, capped; every file written here has public IPv4 addresses and 12-digit numbers redacted
# (candidate.json/truth.json image refs carry the account id: only digests are kept).
# Exit: 0 accepted; 1 error; 2 usage; 3 not accepted within N iterations; 4 a wait timed out or a rollback failed; 5 kill switch.
# Run it detached:  setsid nohup bash orch/muse_arm.sh T5 C > state/logs/muse-T5-C.log 2>&1 < /dev/null &
# Env: MUSE_MAIN_SHA [kit/state/main.sha]  RBD_SH [orch/rbd.sh]  MUSE_AGENT_TAKE [orch/agent_take.sh]  MUSE_MAKE_PRS [changes/make_prs.sh]  MUSE_CHANGES [changes/]
#      RBD_STATE [kit/state]  MUSE_AGENT_STATE [kit/state/agent: agent_take.sh's RI.compile.txt]  MUSE_POLICY
#      [repo/policy/gate.json]  MUSE_REGRESS [verify/regress.py; "" = the rule here]  MUSE_TASK [/opt/muse/task.sh]
#      MUSE_HIDDEN [/opt/muse/hidden.sh]  MUSE_TRUTHX [/opt/rbd/verify/truthx.sh]  MUSE_CANDIDATE [/opt/rbd/verify/candidate.sh;
#      "" = read runs/HEAD/candidate.json]  MUSE_ROOT_SH [none: ssh + sudo -n to rbd-tools1 as rbd_lib.sh's rsh; tests: a
#      stand-in run as 'bash MUSE_ROOT_SH CMD...']  MUSE_ROOT_LOGS [/var/log/rbd-muse: root jobs' NAME.out/NAME.rc]
#      REPO [Sharvil2704/rhobound-maze-bed]  MUSE_STATUS_CREATOR [github-actions[bot]; "" = not checked]  MUSE_POLL [30 s]
#      MUSE_AGENT_WAIT [4200]  MUSE_HIDDEN_WAIT [1800]  MUSE_GATE_WAIT [5400]  MUSE_BUILD_WAIT [2400]  MUSE_MEASURE_WAIT [4800]
#      MUSE_CF_WAIT [7200]  MUSE_LOCK_WAIT [3600: truthx's cluster-lock wait; arm C's bracket queues behind its own gate's A/B]
#      MUSE_EVENTS_CAP [33554432 bytes per fetched event log]
# shellcheck disable=SC2015,SC2317  # A && B || C is meant; on_exit runs from the EXIT trap
set -euo pipefail
DEMO=$(cd "$(dirname "$0")/.." && pwd)
RBD=${RBD_SH:-$DEMO/orch/rbd.sh}
TAKE=${MUSE_AGENT_TAKE:-$DEMO/orch/agent_take.sh}
MKPR=${MUSE_MAKE_PRS:-$DEMO/changes/make_prs.sh}
CHANGES=${MUSE_CHANGES:-$DEMO/changes}
STATE=${RBD_STATE:-$DEMO/state}
AGSTATE=${MUSE_AGENT_STATE:-$DEMO/state/agent}
POLICY=${MUSE_POLICY:-$DEMO/repo/policy/gate.json}
REGRESS=${MUSE_REGRESS-$DEMO/verify/regress.py}
TASKSH=${MUSE_TASK:-/opt/muse/task.sh}
HIDDEN=${MUSE_HIDDEN:-/opt/muse/hidden.sh}
TRUTHX=${MUSE_TRUTHX:-/opt/rbd/verify/truthx.sh}
CANDSH=${MUSE_CANDIDATE-/opt/rbd/verify/candidate.sh}
ROOTSH=${MUSE_ROOT_SH:-}
RLOGS=${MUSE_ROOT_LOGS:-/var/log/rbd-muse}
RHOME=/var/lib/rbd
REPO=${REPO:-Sharvil2704/rhobound-maze-bed}
CREATOR=${MUSE_STATUS_CREATOR-github-actions[bot]}
POLL=${MUSE_POLL:-30}
AGENT_WAIT=${MUSE_AGENT_WAIT:-4200}
HIDDEN_WAIT=${MUSE_HIDDEN_WAIT:-1800}
GATE_WAIT=${MUSE_GATE_WAIT:-5400}
BUILD_WAIT=${MUSE_BUILD_WAIT:-2400}
MEASURE_WAIT=${MUSE_MEASURE_WAIT:-4800}
CF_WAIT=${MUSE_CF_WAIT:-7200}
LOCKW=${MUSE_LOCK_WAIT:-3600}
EVCAP=${MUSE_EVENTS_CAP:-33554432}
FINISHED=0 OWN=0 CUR_I=0 TL="" W=""
say() { echo "[muse_arm ${TICKET:-?}-${ARM:-?} $(date -u +%H:%M:%S)] $*" >&2; }
usage() { sed -n '2,/^# Env:/p' "$0" | sed 's/^# \{0,1\}//' >&2; exit 2; }

# ---- arguments ----------------------------------------------------------------------------------------------------------
[[ $# -ge 2 ]] || usage
TICKET=$1 ARM=$2
shift 2
[[ $TICKET =~ ^[A-Za-z0-9][A-Za-z0-9-]{0,15}$ ]] || { echo "muse_arm: TICKET: letters, digits and -, at most 16 (T5, T4-typos)" >&2; exit 2; }
[[ $ARM == R || $ARM == C ]] || { echo "muse_arm: ARM: R (rhobound) or C (chaotic)" >&2; exit 2; }
MAXI=3 COLLECT=0 TAG=
while [[ $# -gt 0 ]]; do
  case $1 in
    --max-iter) [[ $# -ge 2 && $2 =~ ^[1-3]$ ]] || { echo "muse_arm: --max-iter N (1..3: task.sh's iteration cap)" >&2; exit 2; }; MAXI=$2; shift 2 ;;
    --tag) [[ $# -ge 2 && $2 =~ ^[a-z0-9]{1,6}$ ]] || { echo "muse_arm: --tag T ([a-z0-9], at most 6)" >&2; exit 2; }; TAG=$2; shift 2 ;;
    --collect) COLLECT=1; shift ;;
    *) usage ;;
  esac
done
[[ $COLLECT == 0 || $ARM == C ]] || { echo "muse_arm: --collect is arm C's (arm R's verdicts are read as it goes)" >&2; exit 2; }
[[ -z ${MUSE_DEADLINE:-} || $MUSE_DEADLINE =~ ^[0-9]{10}$ ]] || { echo "muse_arm: MUSE_DEADLINE must be epoch seconds" >&2; exit 2; }
for v in POLL AGENT_WAIT HIDDEN_WAIT GATE_WAIT BUILD_WAIT MEASURE_WAIT CF_WAIT LOCKW EVCAP; do
  [[ ${!v} =~ ^[0-9]+$ ]] || { echo "muse_arm: MUSE_* waits and caps are whole numbers ($v=${!v})" >&2; exit 2; }
done
RUN=mx-$TICKET-$ARM${TAG:+-$TAG}
MAINSHA=${MUSE_MAIN_SHA:-$DEMO/state/main.sha}
TBASE=$(tr '[:upper:]' '[:lower:]' <<< "$RUN" | tr -c 'a-z0-9-\n' '-')
TD=$STATE/muse/$TICKET-$ARM${TAG:+-$TAG}
TL=$TD/timeline.json
mkdir -p "$STATE/muse" "$TD"

# ---- python helpers (python3 -I; everything written is redacted) --------------------------------------------------------
PYLIB='
import ipaddress, json, os, re, stat, sys, time, calendar
_OK = [ipaddress.ip_network(n) for n in ("127.0.0.0/8", "0.0.0.0/32", "10.0.0.0/8", "172.16.0.0/12", "192.168.0.0/16",
                                         "192.0.2.0/24", "198.51.100.0/24", "203.0.113.0/24")]
_IP = re.compile(r"(?<![0-9.])[0-9]{1,3}(?:\.[0-9]{1,3}){3}(?![0-9])(?!\.[0-9])")
_N12 = re.compile(r"(?<![0-9A-Za-z_])(?<![0-9]\.)[0-9]{12}(?![0-9A-Za-z_])(?!\.[0-9])")
def _ipsub(m):
    try:
        a = ipaddress.ip_address(m.group())
    except ValueError:
        return m.group()
    return m.group() if any(a in n for n in _OK) else "<ip>"
def red(s):
    return _N12.sub("<n12>", _IP.sub(_ipsub, s))
def redact(o):
    if isinstance(o, str):
        return red(o)
    if isinstance(o, bool) or o is None or isinstance(o, float):
        return o
    if isinstance(o, int):
        return "<n12>" if len(str(abs(o))) == 12 else o
    if isinstance(o, list):
        return [redact(x) for x in o]
    if isinstance(o, dict):
        return {red(str(k)): redact(v) for k, v in o.items()}
    return o
def now():
    return time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())
def ts(s):
    try:
        return calendar.timegm(time.strptime(s, "%Y-%m-%dT%H:%M:%SZ"))
    except (TypeError, ValueError):
        return None
def secs(a, b):
    x, y = ts(a), ts(b)
    return None if x is None or y is None else y - x
def dump(path, obj):
    tmp = path + ".tmp"
    with open(tmp, "w") as f:
        f.write(json.dumps(redact(obj), indent=1) + "\n")
    os.replace(tmp, path)
def regular(path, cap):
    try:
        st = os.lstat(path)
    except OSError:
        return False
    return stat.S_ISREG(st.st_mode) and st.st_size <= cap
def jload(path, cap=4_000_000):
    if not regular(path, cap):
        return None
    try:
        return json.loads(open(path, "rb").read().decode("utf-8"))
    except (ValueError, UnicodeDecodeError):
        return None
def text(s, cap):
    s = "".join(c if (c.isprintable() or c in "\n\t") else "?" for c in str(s))
    return red(s if len(s) <= cap else s[: cap] + "\n[... cut at %d characters]" % cap)
'
py() { local s=$1; shift; python3 -I -c "$PYLIB$s" "$@"; }
# jo K V ...: a JSON object of string values; a key ending in # takes its value as JSON
jo() { py '
a, d = sys.argv[1:], {}
for i in range(0, len(a) - 1, 2):
    k, v = a[i], a[i + 1]
    if k.endswith("#"):
        d[k[:-1]] = json.loads(v) if v != "" else None
    else:
        d[k] = v
print(json.dumps(d))' "$@"; }
TLPY='
path, op, a = sys.argv[1], sys.argv[2], sys.argv[3:]
tl = jload(path, 64_000_000) if os.path.exists(path) else None
if op == "init":
    if tl is not None:
        sys.exit("muse_arm: %s exists" % path)
    tl = json.loads(a[0])
    tl.setdefault("phases", [])
    tl.setdefault("iterations", [])
elif tl is None:
    sys.exit("muse_arm: no readable timeline %s" % path)
def it(i):
    i = int(i)
    while len(tl["iterations"]) < i:
        tl["iterations"].append({"iter": len(tl["iterations"]) + 1})
    return tl["iterations"][i - 1]
def merge(d, p):
    for k, v in p.items():
        if isinstance(v, dict) and isinstance(d.get(k), dict):
            merge(d[k], v)
        else:
            d[k] = v
if op == "get":
    v = tl
    for k in a[0].split("."):
        v = (v[int(k)] if int(k) < len(v) else None) if isinstance(v, list) else (v.get(k) if isinstance(v, dict) else None)
    print("" if v is None else (json.dumps(v) if isinstance(v, (dict, list, bool)) else v))
    sys.exit(0)
if op == "init":
    pass
elif op == "ph-start":
    tl["phases"].append({"iter": int(a[0]), "phase": a[1], "started_at": now(), "ended_at": None, "status": "running"})
elif op == "ph-end":
    i, ph, status = int(a[0]), a[1], a[2]
    det = json.loads(a[3]) if len(a) > 3 and a[3] else None
    e = next((p for p in reversed(tl["phases"]) if p["iter"] == i and p["phase"] == ph and p.get("ended_at") is None), None)
    if e is None:
        e = {"iter": i, "phase": ph, "started_at": None}
        tl["phases"].append(e)
    e["ended_at"], e["status"] = now(), status
    e["seconds"] = secs(e.get("started_at"), e["ended_at"])
    if det:
        e["detail"] = det
elif op == "ph-add":
    for p in json.loads(a[1]):
        p = dict(p, iter=int(a[0]))
        p["seconds"] = secs(p.get("started_at"), p.get("ended_at"))
        tl["phases"].append(p)
elif op == "iter-set":
    merge(it(a[0]), json.loads(a[1]))
elif op == "iter-stop":
    x = it(a[0])
    if x.get("outcome") in (None, "running"):
        x.update(outcome=a[1], ended_at=now())
elif op == "top-set":
    merge(tl, json.loads(a[0]))
else:
    sys.exit("muse_arm: timeline op %r?" % op)
tl["updated_at"] = now()
dump(path, tl)
'
tl() { py "$TLPY" "$TL" "$@"; }
utc() { date -u +%Y-%m-%dT%H:%M:%SZ; }
# sanitize CAP < in > out: printable text, capped, redacted (model, compile and test output fed back or kept)
sanitize() { py 'sys.stdout.write(text(sys.stdin.read(), int(sys.argv[1])))' "$1"; }

finish() { # STATUS EXIT [MESSAGE]: the arm's end, recorded
  FINISHED=1
  if [[ $OWN == 1 ]]; then
    ((CUR_I == 0)) || tl iter-stop "$CUR_I" "$1" || true
    tl top-set "$(jo status "$1" exit# "$2" ended_at "$(utc)" error "${3:-}")" || true
  fi
  [[ -z ${3:-} ]] || echo "muse_arm: $3" >&2
  exit "$2"
}
fail() { finish error "${2:-1}" "error: $1"; }
on_exit() {
  local rc=$?
  [[ -n $W ]] && rm -rf "$W"
  if [[ $FINISHED == 0 && $OWN == 1 ]]; then
    ((CUR_I == 0)) || tl iter-stop "$CUR_I" died 2> /dev/null || true
    tl top-set "$(jo status died exit# "$rc" ended_at "$(utc)" error "the driver ended unexpectedly (exit $rc): see the log")" 2> /dev/null || true
  fi
}
trap on_exit EXIT
stopped() { [[ -e $STATE/muse/STOP ]]; }   # state/automerge.stop stops merges; nothing here merges
rbd() { bash "$RBD" "$@" 8>&- 9>&-; }

# ---- rbd-tools1 as root (ssh + sudo -n, rbd_lib.sh's rsh) ---------------------------------------------------------------
ROOT_READY=0
root_run() { # CMD...: on rbd-tools1 as root; its output on stdout
  if [[ -n $ROOTSH ]]; then bash "$ROOTSH" "$@" 8>&- 9>&-; return; fi
  if [[ $ROOT_READY == 0 ]]; then
    # shellcheck disable=SC2034  # read by rbd_lib.sh
    RBD_ME=muse_arm
    # shellcheck source=orch/rbd_lib.sh
    . "$DEMO/orch/rbd_lib.sh"
    need_seed
    TOOLS=$(one_role tools)
    ROOT_READY=1
  fi
  rsh "$TOOLS" "sudo -n $(rbd_q "$@")" 8>&- 9>&-
}
# root_bg NAME CMD...: detached as root (setsid nohup: a dropped ssh does not stop it), output in MUSE_ROOT_LOGS/NAME.out
# (root-owned folder), exit code in NAME.rc; root_tail NAME [N]: rbd.sh tail's format
# shellcheck disable=SC2016  # expanded on rbd-tools1
ROOTBG='n=$1 L=$2; shift 2; umask 077; install -d -m 0700 "$L" && chmod 0700 "$L" || exit 1; rm -f "$L/$n.rc"; setsid nohup bash -c '"'"'"$@" > "$0.out" 2>&1 < /dev/null; echo $? > "$0.rc"'"'"' "$L/$n" "$@" > /dev/null 2>&1 < /dev/null & echo "started $n (pid $!)"'
# shellcheck disable=SC2016
ROOTTAIL='n=$1 L=$2 k=$3; if [ -f "$L/$n.rc" ]; then echo "== $n: done, exit $(cat "$L/$n.rc")"; else echo "== $n: running (or never started)"; fi; tail -n "$k" "$L/$n.out" 2> /dev/null; true'
root_bg() { local n=$1; shift; root_run bash -c "$ROOTBG" rootbg "$n" "$RLOGS" "$@"; }
root_tail() { root_run bash -c "$ROOTTAIL" roottail "$1" "$RLOGS" "${2:-20}"; }
# wait_job root|rbd NAME WAIT_S: polls the job until 'done, exit N' -> JOB_RC=N (0), or 4 after WAIT_S
JOB_RC=""
wait_job() {
  local kind=$1 n=$2 w=$3 t0 line
  t0=$(date +%s)
  while :; do
    if [[ $kind == root ]]; then line=$(root_tail "$n" 3) || line=""; else line=$(rbd tail "$n" 3) || line=""; fi
    line=${line%%$'\n'*}   # no pipe into head: a SIGPIPE under pipefail would drop the line
    if [[ $line =~ ^==\ .*:\ done,\ exit\ ([0-9]+)$ ]]; then JOB_RC=${BASH_REMATCH[1]}; return 0; fi
    (($(date +%s) - t0 < w)) || return 4
    sleep "$POLL"
  done
}
# fetch REMOTE LOCAL CAP: one regular file of rbd-tools1 (as rbd; never a link), at most CAP bytes; 1 when absent
# shellcheck disable=SC2016
FETCHSH='f=$1 c=$2; [ -f "$f" ] && [ ! -L "$f" ] || exit 3; head -c "$c" "$f"'
fetch() {
  local rc=0
  rbd run bash -c "$FETCHSH" fetch "$1" "$3" > "$2.part" 2> /dev/null || rc=$?
  if ((rc != 0)); then rm -f "$2.part"; return 1; fi
  mv -f "$2.part" "$2"
}
# fetch_json REMOTE LOCAL: a JSON file of rbd-tools1, kept redacted (image refs carry the account id); 1 when absent or not JSON
fetch_json() {
  fetch "$1" "$W/fj" 4000000 || return 1
  py 'd = jload(sys.argv[1])
if d is None:
    sys.exit(1)
dump(sys.argv[2], d)' "$W/fj" "$2" || { rm -f "$W/fj"; return 1; }
  rm -f "$W/fj"
}

# ---- GitHub (gh: typed state only) ---------------------------------------------------------------------------------------
# verdict HEAD OUT: the newest rhobound/verdict status on HEAD (by CREATOR) and the gate.yml run -> OUT {final, state,
# verdict, rule, description, gate_run, gate_created, gate_started, gate_ended}; 1 when gh failed
verdict() {
  gh api "repos/$REPO/commits/$1/statuses?per_page=100" > "$W/st.json" 2> "$W/gh.err" || { say "gh statuses of ${1:0:12}: $(head -c 200 "$W/gh.err")"; return 1; }
  gh run list --repo "$REPO" --workflow gate.yml --commit "$1" --limit 1 \
    --json databaseId,status,conclusion,createdAt,startedAt,updatedAt,headSha > "$W/gr.json" 2> "$W/gh.err" || echo '[]' > "$W/gr.json"
  py '
st, gr = jload(sys.argv[1]) or [], jload(sys.argv[2]) or []
head, creator, out = sys.argv[3], sys.argv[4], sys.argv[5]
mine = [x for x in st if isinstance(x, dict) and x.get("context") == "rhobound/verdict"
        and (not creator or (x.get("creator") or {}).get("login") == creator)] if isinstance(st, list) else []
s = mine[0] if mine else None
v = {"final": False, "state": None, "verdict": "pending", "rule": None, "description": None, "status_at": None,
     "gate_run": None, "gate_created": None, "gate_started": None, "gate_ended": None, "gate_conclusion": None}
if s is not None:
    d = str(s.get("description") or "")
    m = re.match(r"(pass|block|inconclusive): ([A-Za-z0-9_@.:-]{0,64})", d)
    v.update(state=s.get("state"), description=text(d, 300), status_at=s.get("updated_at") or s.get("created_at"))
    if s.get("state") == "success":
        v.update(final=True, verdict=m.group(1) if m else "error", rule=m.group(2) if m else None)
        if v["verdict"] != "pass":
            v["verdict"] = "error"
    elif s.get("state") == "failure" and m and m.group(1) != "pass":
        v.update(final=True, verdict=m.group(1), rule=m.group(2))
    elif s.get("state") in ("failure", "error"):
        v.update(final=True, verdict="error")
runs = [r for r in gr if isinstance(r, dict) and r.get("headSha") == head] if isinstance(gr, list) else []
if runs:
    r = runs[0]
    v.update(gate_run=r.get("databaseId"), gate_created=r.get("createdAt"), gate_started=r.get("startedAt") or r.get("createdAt"),
             gate_ended=r.get("updatedAt") if r.get("status") == "completed" else None, gate_conclusion=r.get("conclusion"))
dump(out, v)' "$W/st.json" "$W/gr.json" "$1" "$CREATOR" "$2"
}
# gate_artifacts HEAD DIR: runs/HEAD/{predict.json, gate/gate.json} (file by file, redacted) -> DIR/gate-summary.json
# {verdict, rule, deciding_rules, other_rules, decide_with, candidate_digest}
gate_artifacts() {
  mkdir -p "$2"
  fetch_json "$RHOME/runs/$1/predict.json" "$2/predict.json" || say "runs/${1:0:12}/predict.json: none on rbd-tools1"
  fetch_json "$RHOME/runs/$1/gate/gate.json" "$2/gate.json" || say "runs/${1:0:12}/gate/gate.json: none on rbd-tools1"
  py '
d = sys.argv[1]
g, p = jload(os.path.join(d, "gate.json")) or {}, jload(os.path.join(d, "predict.json")) or {}
verdict = g.get("verdict") or p.get("verdict")
keep = ("rule", "effect", "entry", "code", "value", "threshold", "variant", "number")
rules = [{k: r[k] for k in keep if k in r} for r in g.get("rules", []) if isinstance(r, dict) and r.get("evaluated")]
deciding = [r for r in rules if r.get("effect") == verdict and verdict != "pass"]
if verdict == "pass":
    deciding = [r for r in rules if r.get("rule") == "mean_change"][:1]
others = [r for r in rules if r.get("effect") in ("block", "inconclusive") and r not in deciding]
dw = g.get("decide_with")
dump(os.path.join(d, "gate-summary.json"), {"verdict": verdict, "rule": p.get("rule"), "deciding_rules": deciding,
     "other_rules": others, "decide_with": [text(x, 400) for x in dw] if isinstance(dw, list) else [],
     "candidate_digest": p.get("candidate_digest"), "services": p.get("services"), "advisory": g.get("advisory"),
     "have_gate_json": bool(g), "have_predict_json": bool(p)})' "$2"
}
pr_state() { gh pr view "$1" --repo "$REPO" --json state -q .state 2> /dev/null || echo UNKNOWN; }
close_pr() { # N WHY: close (never merge) an open PR; the branch is kept
  [[ $(pr_state "$1") == OPEN ]] || return 0
  if gh pr close "$1" --repo "$REPO" --comment "$2" > /dev/null 2> "$W/gh.err"; then say "PR $1 closed: $2"
  else say "WARNING: could not close PR $1: $(head -c 200 "$W/gh.err")"; fi
}

# ---- the candidate image (both arms) -------------------------------------------------------------------------------------
# candidate HEAD OUT: HEAD's images -> OUT {digest (the first service's), digests {svc: digest}, services} (never an image
# ref). 0 built; 1 not yet; 2 the build ended without an image (candidate.sh exit 1); 3 candidate.sh failed otherwise
candidate() {
  local rc=0
  if [[ -n $CANDSH ]]; then
    rbd run "$CANDSH" "$1" --wait 0 > "$W/cand.out" 2> "$W/cand.err" || rc=$?
    case $rc in 0) ;; 4) return 1 ;; 1) return 2 ;; *) return 3 ;; esac
  else
    rbd run bash -c "$FETCHSH" fetch "runs/$1/candidate.json" 4000000 > "$W/cand.out" 2> /dev/null || return 1
  fi
  py '
raw = open(sys.argv[1], "rb").read(4_000_001).decode("utf-8", "replace")
dig, order = {}, []
pat = re.compile(r"([a-z][a-z0-9-]{0,30})=(sha256:[0-9a-f]{64})")
for line in raw.splitlines():
    m = pat.fullmatch(line.strip())
    if m and m.group(1) not in dig:
        dig[m.group(1)] = m.group(2)
        order.append(m.group(1))
if not dig:   # runs/HEAD/candidate.json (MUSE_CANDIDATE empty): one image for every service it lists
    try:
        d = json.loads(raw)
    except ValueError:
        sys.exit(1)
    if not isinstance(d, dict) or not (isinstance(d.get("digest"), str) and re.fullmatch(r"sha256:[0-9a-f]{64}", d["digest"])) \
            or d.get("git_sha") not in (None, sys.argv[2]):
        sys.exit(1)
    for s in d.get("services") or ([d["service"]] if d.get("service") else []):
        if isinstance(s, str) and re.fullmatch(r"[a-z][a-z0-9-]{0,30}", s) and s not in dig:
            dig[s] = d["digest"]
            order.append(s)
if not 1 <= len(order) <= 32:
    sys.exit(1)
dump(sys.argv[3], {"digest": dig[order[0]], "digests": dig, "services": order, "git_sha": sys.argv[2]})' "$W/cand.out" "$1" "$2" || return 3
}

# ---- one iteration -------------------------------------------------------------------------------------------------------
alloc_change() { # the next free cN-muse, reserved (its folder) under a lock; names in any muse timeline count as taken
  (
    flock -w 60 7 || exit 1
    n=$(
      {
        find "$CHANGES" -maxdepth 1 -type d -name 'c[0-9]*-*' -printf '%f\n' 2> /dev/null
        cat "$STATE"/muse/*/timeline.json 2> /dev/null | grep -o '"change": "c[0-9]*-muse"' | grep -o 'c[0-9]*-muse' || true
      } | sed -n 's/^c\([0-9]\{1,2\}\)-.*/\1/p' | sort -n | tail -n 1
    )
    c=c$((${n:-6} + 1))-muse
    [[ $c =~ ^c[0-9]{1,2}-muse$ ]] || exit 1
    mkdir "$CHANGES/$c" && printf '%s\n' "$RI" > "$CHANGES/$c/.muse-reserved" || exit 1
    echo "$c"
  ) 7>> "$STATE/muse/.names.lock"
}
# outcome I OUTCOME KIND FEEDBACK_FILE: the iteration did not end accepted; FEEDBACK_FILE becomes the next one's feedback
outcome() {
  local i=$1 o=$2 k=$3 f=$4
  sanitize 12000 < "$f" > "$ID/feedback-out.md"
  tl iter-set "$i" "$(jo outcome "$o" feedback_kind "$k" feedback_bytes# "$(wc -c < "$ID/feedback-out.md")" ended_at "$(utc)")"
  say "iteration $i: $o (feedback: $k)"
}
agent_stats() { # RC: OUT's result.json and usage.json (task.sh/export.py: rbd.muse-usage/v1) as data -> ID/agent.json; without
  # a usage.json, Muse's raw events and session log (/var/lib/rbd/muse/runs/RUN/iI, kept verbatim as ID/agent/*.raw)
  local f
  mkdir -p "$ID/agent"
  fetch_json "$RHOME/agent/$RI/result.json" "$ID/agent/result.json" || true
  fetch_json "$RHOME/agent/$RI/usage.json" "$ID/agent/usage.json" || true
  if [[ ! -s $ID/agent/usage.json ]]; then
    for f in events.jsonl session.jsonl; do fetch "$RHOME/muse/runs/$RUN/i$CUR_I/$f" "$ID/agent/$f.raw" "$EVCAP" || true; done
  fi
  py '
d, out, arc = sys.argv[1], sys.argv[2], int(sys.argv[3])
def n(v):
    return v if isinstance(v, (int, float)) and not isinstance(v, bool) else None
def tool(x):
    x = str(x)
    return x[len("mcp__rhobound__"):] if x.startswith("mcp__rhobound__") else x
def leaves(o, path=()):
    if isinstance(o, dict):
        for k, v in o.items():
            yield from leaves(v, path + (str(k),))
    elif isinstance(o, list):
        for x in o:
            yield from leaves(x, path)
    elif n(o) is not None:
        yield path, o
def tokens(u):
    by = {".".join(p): v for p, v in leaves(u) if p and "token" in ".".join(p).lower()}
    if not by:
        return None
    last = lambda k: k.split(".")[-1].lower()
    inp = sum(v for k, v in by.items() if "input" in last(k) or "prompt" in last(k)) if any("input" in last(k) or "prompt" in last(k) for k in by) else None
    outp = sum(v for k, v in by.items() if "output" in last(k) or "completion" in last(k)) if any("output" in last(k) or "completion" in last(k) for k in by) else None
    tot = [v for k, v in by.items() if "total" in k.lower()]
    return {"input": inp, "output": outp, "total": max(tot) if tot else (inp + outp if inp is not None and outp is not None else None)}
def walk(o):
    if isinstance(o, dict):
        yield o
        for v in o.values():
            yield from walk(v)
    elif isinstance(o, list):
        for x in o:
            yield from walk(x)
s = {"rc": arc, "result_ok": None, "error": None, "errors": None, "steps": None, "steps_completed": None, "tool_calls": None,
     "tokens": None, "mcp_calls": None, "mcp_offered": None, "stop_reminders": None, "session_rc": None, "timed_out": None,
     "muse_started": None, "muse_ended": None, "muse_seconds": None, "usage_event": None, "source": None}
r = jload(os.path.join(d, "result.json"), 1_000_000)
if isinstance(r, dict):
    s["result_ok"] = r.get("ok") is True
    if r.get("error"):
        s["error"] = text(r["error"], 1000)
    if isinstance(r.get("errors"), list):
        s["errors"] = [text(e, 1000) for e in r["errors"][:20]]
    s["steps"] = n(r.get("turns"))
    if isinstance(r.get("mcp_calls"), list):
        c = {}
        for m in r["mcp_calls"]:
            k = tool(m.get("tool") if isinstance(m, dict) else m)
            c[k] = c.get(k, 0) + 1
        s["mcp_calls"] = c
    if isinstance(r.get("usage"), dict) and any(n(v) is not None for v in r["usage"].values()):
        t = {k: n(r["usage"].get(k)) for k in ("input", "output", "cached", "reasoning", "total")}
        if t["total"] is None and t["input"] is not None and t["output"] is not None:
            t["total"] = t["input"] + t["output"]
        s["tokens"] = t
    s["source"] = "result.json"
u = jload(os.path.join(d, "usage.json"), 4_000_000)
if isinstance(u, dict) and u.get("schema") == "rbd.muse-usage/v1":
    s["source"] = "usage.json"
    s["steps"], s["steps_completed"] = n(u.get("model_steps")), n(u.get("model_steps_completed"))
    if isinstance(u.get("tool_calls_by_kind"), dict):
        s["tool_calls"] = sum(v for v in u["tool_calls_by_kind"].values() if n(v) is not None)
    if isinstance(u.get("tokens"), dict):
        t = {k: n(u["tokens"].get(k)) for k in ("input", "output", "cached", "reasoning", "total")}
        if t["total"] is None and t["input"] is not None and t["output"] is not None:
            t["total"] = t["input"] + t["output"]
        s["tokens"] = t
    if isinstance(u.get("mcp_call_counts"), dict):
        s["mcp_calls"] = {tool(k): v for k, v in u["mcp_call_counts"].items() if n(v) is not None}
    if isinstance(u.get("mcp_offered"), list):
        s["mcp_offered"] = [tool(x) for x in u["mcp_offered"][:40]]
    if isinstance(u.get("hooks"), dict):
        s["stop_reminders"] = n(u["hooks"].get("stop_blocked"))
    se = u.get("session") if isinstance(u.get("session"), dict) else {}
    s.update(muse_started=se.get("started"), muse_ended=se.get("ended"), muse_seconds=n(se.get("wall_s")),
             session_rc=n(se.get("rc")), timed_out=se.get("timed_out"))
    s["usage_event"] = u.get("run_usage")
else:   # no usage.json: the raw logs, read here
    proposed, mcp, stops, usage, seen, have = 0, {}, 0, None, set(), []
    for f in ("events.jsonl", "session.jsonl"):
        p = os.path.join(d, f + ".raw")
        if not regular(p, 1 << 40):
            continue
        have.append(f)
        for line in open(p, "rb"):
            try:
                e = json.loads(line.decode("utf-8"))
            except (ValueError, UnicodeDecodeError):
                continue
            if not isinstance(e, dict):
                continue
            pt = e.get("payload_type")
            if f == "events.jsonl" and pt == "task.lifecycle.proposed":
                proposed += 1
                m = re.search(r"mcp__rhobound__([a-z_]{1,40})", json.dumps(e.get("payload")))
                if m:
                    mcp[m.group(1)] = mcp.get(m.group(1), 0) + 1
            if f == "events.jsonl" and pt == "run.usage" and isinstance(e.get("payload"), dict):
                usage = e["payload"]
            for h in walk(e):
                k = str(h.get("kind") or "")
                if k.startswith("hook_run") and not k.endswith("started") and h.get("event") == "Stop":
                    code = h.get("exit_code", h.get("exit", h.get("code")))
                    blocked = code == 2 or "block" in json.dumps({x: h.get(x) for x in ("outcome", "status", "result", "decision", "kind")}).lower()
                    key = (str(e.get("id") or e.get("sequence")), k, str(h.get("hook_key")))
                    if blocked and key not in seen:
                        seen.add(key)
                        stops += 1
    if have:
        s["source"] = "raw logs (%s)" % ", ".join(have)
        s["tool_calls"], s["stop_reminders"] = proposed, stops
        if "events.jsonl" in have:
            s["mcp_calls"] = mcp
        if usage is not None:
            s["usage_event"], s["tokens"] = usage, tokens(usage) or s["tokens"]
s["muse_seconds"] = s["muse_seconds"] if s["muse_seconds"] is not None else secs(s["muse_started"], s["muse_ended"])
dump(out, s)' "$ID/agent" "$ID/agent.json" "$1"
}

ID="" RI="" CH=""
ITER_ACC=0
iterate() { # I: one iteration (always returns 0; ITER_ACC=1 when accepted); exits on an error
  local i=$1 ii TN prev rc fbr="" head prn hrc trc
  ii=$(printf '%02d' "$i")
  CUR_I=$i RI=$RUN-i$i TN=$TBASE-i$i ID=$TD/iter-$ii
  mkdir -p "$ID"
  CH=$(alloc_change) || fail "no free cN-muse name under $CHANGES"
  tl iter-set "$i" "$(jo iter# "$i" run "$RI" change "$CH" truth_name "$TN" started_at "$(utc)" outcome running)"
  say "iteration $i: run $RI, change $CH"
  prev=$TD/iter-$(printf '%02d' $((i - 1)))
  if ((i > 1)) && [[ -s $prev/feedback-out.md ]]; then cp "$prev/feedback-out.md" "$ID/feedback-in.md"; fi

  # 1 agent -----------------------------------------------------------------------------------------------------------
  stopped && finish stopped 5 "kill switch (state/muse/STOP)"
  tl ph-start "$i" agent
  if [[ -s $ID/feedback-in.md ]]; then
    mkdir -p "$W/fb"
    cp "$ID/feedback-in.md" "$W/fb/$RI.feedback.md"
    rbd put "$W/fb/$RI.feedback.md" "$RHOME/muse/feedback" || fail "cannot put the feedback on rbd-tools1"
    fbr=$RHOME/muse/feedback/$RI.feedback.md
  fi
  root_bg "muse-$RI-agent" "$TASKSH" "$ARM" "$TICKET" "$i" "$RUN" ${fbr:+"$fbr"} > /dev/null ||
    fail "cannot start $TASKSH on rbd-tools1 (as root)"
  if ! wait_job root "muse-$RI-agent" "$AGENT_WAIT"; then
    tl ph-end "$i" agent timeout
    fail "task.sh $RI still runs after ${AGENT_WAIT} s (root tail muse-$RI-agent): not waiting longer" 4
  fi
  rc=$JOB_RC
  root_tail "muse-$RI-agent" 200 2> /dev/null | sanitize 40000 > "$ID/agent.log" || true
  agent_stats "$rc"
  tl ph-end "$i" agent "$( ((rc == 0)) && echo ok || echo "exit-$rc")" "$(cat "$ID/agent.json")"
  tl iter-set "$i" "$(jo agent# "$(cat "$ID/agent.json")")"
  case $rc in
    0) ;;
    1)   # OUT holds result.json ok:false: the session left no change the pipeline can take (export.py says why)
      { echo "Your session ended without a change that can be taken (nothing was built or deployed):"; echo
        py 'a = jload(sys.argv[1]) or {}
for e in (a.get("errors") or ([a["error"]] if a.get("error") else ["(no reason recorded)"])):
    print("- " + e)' "$ID/agent.json"; echo
        echo "Make the change the ticket asks for, in the files it allows; the acceptance criteria still hold."; } > "$W/fb.txt"
      outcome "$i" no_change agent "$W/fb.txt"; return 0 ;;
    *) fail "task.sh exited $rc for $RI (2 usage or state, 3 the export failed, 4 the user's lock is held): the harness, not the agent; see $ID/agent.log" ;;
  esac

  # 2 take (the untrusted-output checks) ------------------------------------------------------------------------------
  tl ph-start "$i" take
  rc=0
  bash "$TAKE" "$RI" "$CH" > "$ID/take.out" 2> "$ID/take.err" || rc=$?
  sanitize 20000 < "$ID/take.err" > "$ID/take.log"; rm -f "$ID/take.err"
  case $rc in
    0)
      [[ -s $CHANGES/$CH/rhobound-change.json && -s $CHANGES/$CH/change.patch ]] || fail "agent_take.sh wrote no changes/$CH"
      rm -f "$CHANGES/$CH/.muse-reserved"
      tl ph-end "$i" take ok "$(jo change "$CH" patch_lines# "$(wc -l < "$CHANGES/$CH/change.patch")")" ;;
    3)
      tl ph-end "$i" take no-compile
      { echo "Your change does not compile (go build and go vet, linux/amd64, offline). The compiler said:"; echo
        tail -n 80 "$AGSTATE/$RI.compile.txt" 2> /dev/null || echo "(no compile log)"; echo
        echo "Fix the change so that it compiles; the ticket's acceptance criteria still hold."; } > "$W/fb.txt"
      outcome "$i" no_compile compile "$W/fb.txt"; return 0 ;;
    1)
      if grep -qE 'cannot fetch|cannot unpack|the fetch holds|tar stream is over|at most 5 MB|no state/main.sha|re-run it on the current main|mktemp|less than 4 GB|CHANGE must be|no result.json' "$ID/take.log"; then
        tl ph-end "$i" take error
        fail "agent_take.sh failed for a reason that is not the agent's: $(grep -m1 'error' "$ID/take.log" | head -c 300)"
      fi
      tl ph-end "$i" take refused
      { echo "Your change was refused by the checks before any build or deploy:"; echo
        { grep -E 'refused|error' "$ID/take.log" || true; } | tail -n 40; echo
        echo "Revise the change so that it passes these checks; the ticket's acceptance criteria still hold."; } > "$W/fb.txt"
      outcome "$i" refused take "$W/fb.txt"; return 0 ;;
    *) tl ph-end "$i" take error; fail "agent_take.sh $RI $CH exited $rc (see $ID/take.log)" ;;
  esac

  # 3 hidden tests ---------------------------------------------------------------------------------------------------
  tl ph-start "$i" hidden
  root_bg "muse-$RI-hidden" "$HIDDEN" "$ARM" "$TICKET" "$RUN" "$i" > /dev/null || fail "cannot start $HIDDEN on rbd-tools1"
  if ! wait_job root "muse-$RI-hidden" "$HIDDEN_WAIT"; then
    tl ph-end "$i" hidden timeout
    fail "hidden.sh $RI still runs after ${HIDDEN_WAIT} s" 4
  fi
  hrc=$JOB_RC
  root_tail "muse-$RI-hidden" 300 2> /dev/null | sed '1{/^== /d}' | sanitize 60000 > "$ID/hidden.log" || true
  fetch_json "$RHOME/muse/runs/$RUN/i$i/hidden.json" "$ID/hidden-full.json" || true
  py '
full = jload(sys.argv[1])
if not isinstance(full, dict):   # else the last JSON line of its output
    full = {}
    for l in reversed(open(sys.argv[2]).read().splitlines()):
        if l.startswith("{"):
            try:
                full = json.loads(l)
                break
            except ValueError:
                pass
full = full if isinstance(full, dict) else {}
keep = ("pass", "ran", "passed", "expected", "missing", "build_failed", "packages_failed", "go_test_rc", "error", "wall_s", "modcache_verified")
h = {k: full[k] for k in keep if k in full}
if isinstance(full.get("failed"), list):
    h["failed"] = [text(x, 200) for x in full["failed"][:50]]
h["rc"] = int(sys.argv[3])
dump(sys.argv[4], h)
lines = ["The hidden acceptance tests failed on your change (nothing was deployed)."]
if full.get("build_failed"):
    lines.append("They do not compile against your change.")
if h.get("failed"):
    lines.append("Failed: " + ", ".join(h["failed"]))
mi = full.get("missing")
if mi:
    lines.append("Did not run: " + (", ".join(text(x, 200) for x in mi[:50]) if isinstance(mi, list) else text(mi, 300)))
tail = full.get("output_tail")
if isinstance(tail, list):
    tail = "\n".join(str(x) for x in tail)
if not tail:
    tail = "\n".join(l for l in open(sys.argv[2]).read().splitlines() if not l.startswith("{"))[-6000:]
lines += ["", "The end of their output:", "", text(tail, 6000), "",
          "Revise the change so that it meets every acceptance criterion of the ticket."]
open(sys.argv[5], "w").write("\n".join(lines) + "\n")' "$ID/hidden-full.json" "$ID/hidden.log" "$hrc" "$ID/hidden.json" "$W/fb.txt"
  tl iter-set "$i" "$(jo hidden# "$(cat "$ID/hidden.json")")"
  case $hrc in
    0) tl ph-end "$i" hidden pass "$(cat "$ID/hidden.json")" ;;
    1) tl ph-end "$i" hidden fail "$(cat "$ID/hidden.json")"
       outcome "$i" hidden_fail hidden "$W/fb.txt"; return 0 ;;
    *) tl ph-end "$i" hidden error; fail "hidden.sh exited $hrc for $RI (3 the check could not run, 2 usage, 4 the user's lock): the harness, not the agent; see $ID/hidden.log" ;;
  esac

  # 4 pr ----------------------------------------------------------------------------------------------------------------
  stopped && finish stopped 5 "kill switch (state/muse/STOP)"
  tl ph-start "$i" pr
  bash "$MKPR" "$CH" > "$ID/make_prs.out" 2> "$ID/make_prs.err" || { tl ph-end "$i" pr error; fail "make_prs.sh $CH failed: $(tail -n 3 "$ID/make_prs.err" | head -c 400)"; }
  gh pr list --repo "$REPO" --head "rbd/$CH" --state open --json number,headRefOid,url,createdAt > "$ID/pr-list.json" ||
    fail "gh pr list --head rbd/$CH failed"
  py 'prs = jload(sys.argv[1])
if not isinstance(prs, list) or len(prs) != 1 or not isinstance(prs[0].get("number"), int) \
        or not re.fullmatch("[0-9a-f]{40}", str(prs[0].get("headRefOid"))):
    sys.exit("muse_arm: not exactly one open PR for rbd/%s: %s" % (sys.argv[2], json.dumps(prs)[:300]))
p = prs[0]
dump(sys.argv[3], {"pr": p["number"], "head": p["headRefOid"], "url": p.get("url"), "created_at": p.get("createdAt"),
                   "branch": "rbd/" + sys.argv[2]})' "$ID/pr-list.json" "$CH" "$ID/pr.json" || { tl ph-end "$i" pr error; fail "no single open PR for rbd/$CH"; }
  head=$(py 'print(jload(sys.argv[1])["head"])' "$ID/pr.json")
  prn=$(py 'print(jload(sys.argv[1])["pr"])' "$ID/pr.json")
  tl iter-set "$i" "$(jo pr# "$prn" head "$head" pr_url "$(py 'print(jload(sys.argv[1]).get("url") or "")' "$ID/pr.json")" pr_created_at "$(py 'print(jload(sys.argv[1]).get("created_at") or "")' "$ID/pr.json")")"
  tl ph-end "$i" pr ok "$(cat "$ID/pr.json")"
  if [[ $ARM == R ]]; then close_superseded "$i"; fi

  # 5 the way to production -----------------------------------------------------------------------------------------
  if [[ $ARM == R ]]; then
    tl ph-start "$i" gate
    local t0 v
    t0=$(date +%s)
    while :; do
      if verdict "$head" "$ID/verdict.json" && [[ $(py 'print(jload(sys.argv[1])["final"])' "$ID/verdict.json") == True ]]; then break; fi
      if (($(date +%s) - t0 >= GATE_WAIT)); then
        tl ph-end "$i" gate timeout
        fail "no final rhobound/verdict on ${head:0:12} (PR $prn) after ${GATE_WAIT} s" 4
      fi
      sleep "$POLL"
    done
    gate_artifacts "$head" "$ID/gate"
    v=$(py 'print(jload(sys.argv[1])["verdict"])' "$ID/verdict.json")
    tl iter-set "$i" "$(jo gate# "$(py 'v = jload(sys.argv[1]); g = jload(sys.argv[2]) or {}
print(json.dumps(dict(v, deciding_rules=g.get("deciding_rules"), other_rules=g.get("other_rules"), decide_with=g.get("decide_with"))))' "$ID/verdict.json" "$ID/gate/gate-summary.json")")"
    tl ph-end "$i" gate "$v" "$(cat "$ID/verdict.json")"
    if [[ $v == error ]] && ! py 'd = jload(sys.argv[1]).get("description") or ""
sys.exit(0 if re.match(r"no signed verdict: (pr-check|build) ", d) else 1)' "$ID/verdict.json"; then
      fail "the gate of ${head:0:12} (PR $prn) ended without a verdict after the build ($(py 'print(jload(sys.argv[1]).get("description"))' "$ID/verdict.json")): the harness, not the agent"
    fi
    if [[ $v != pass ]]; then
      py '
v, g = jload(sys.argv[1]), jload(sys.argv[2]) or {}
def rl(r):
    s = "- %s" % r.get("rule")
    if r.get("entry"):
        s += " at %s" % r["entry"]
    if isinstance(r.get("value"), (int, float)) and isinstance(r.get("threshold"), (int, float)):
        s += ": %.2f against %s" % (r["value"], r["threshold"])
    return s + " (%s)" % r.get("effect")
out = ["The rhobound gate did not pass your change (PR #%s): it was not deployed." % sys.argv[3], "",
       "Verdict: %s (%s)" % (v["verdict"], v.get("rule") or v.get("description") or "no rule")]
if v["verdict"] == "error":
    out += ["", "The CI produced no signed verdict: %s" % (v.get("description") or "?")]
if g.get("deciding_rules"):
    out += ["", "The rules that decided it:"] + [rl(r) for r in g["deciding_rules"]]
if g.get("other_rules"):
    out += ["", "Other rules that did not pass:"] + [rl(r) for r in g["other_rules"]]
if g.get("decide_with"):
    out += ["", "What would decide it (decide_with):"] + ["- %s" % x for x in g["decide_with"]]
out += ["", "Revise the change so that the gate can pass it; the ticket and its latency SLO still hold."]
print("\n".join(out))' "$ID/verdict.json" "$ID/gate/gate-summary.json" "$prn" > "$W/fb.txt"
      outcome "$i" "gate_$v" gate "$W/fb.txt"
      return 0
    fi
    local crc=0
    candidate "$head" "$ID/candidate.json" || crc=$?
    ((crc == 0)) || fail "the gate passed ${head:0:12} but candidate.sh names no image for it (class $crc): $(sanitize 300 < "$W/cand.err")"
    py 'c, g = jload(sys.argv[1]), jload(sys.argv[2]) or {}
if not (g.get("have_gate_json") and g.get("have_predict_json")) or g.get("verdict") != "pass":
    sys.exit("muse_arm: the gate artifacts do not show a pass for this head (gate %s, predict %s, verdict %s): not deploying"
             % (g.get("have_gate_json"), g.get("have_predict_json"), g.get("verdict")))
if g.get("candidate_digest") != c["digest"]:
    sys.exit("muse_arm: the gate passed %s, the candidate is %s: not deploying" % (g.get("candidate_digest"), c["digest"]))' \
      "$ID/candidate.json" "$ID/gate/gate-summary.json" || fail "the passed digest is not the candidate's"
  else
    tl ph-start "$i" build
    local t0 built=0 crc t1
    t0=$(date +%s)
    while :; do
      crc=0
      candidate "$head" "$ID/candidate.json" || crc=$?
      if ((crc == 0)); then built=1; break; fi
      if ((crc == 3)); then tl ph-end "$i" build error; fail "candidate.sh failed for ${head:0:12}: $(sanitize 300 < "$W/cand.err")"; fi
      if ((crc == 2)); then   # candidate.sh: the build ended without an image; the gate's status says whose failure it is
        t1=$(date +%s)
        while :; do
          if verdict "$head" "$ID/verdict.json"; then
            case $(py 'print(jload(sys.argv[1])["state"])' "$ID/verdict.json") in
              error) break ;;
              success | failure) fail "candidate.sh found no image for ${head:0:12}, yet its gate reached a verdict: the harness" ;;
            esac
          fi
          (($(date +%s) - t1 < 300)) || fail "candidate.sh found no image for ${head:0:12} and its gate showed no error within 300 s: the harness"
          sleep "$POLL"
        done
        py 'd = jload(sys.argv[1]).get("description") or ""
sys.exit(0 if re.match(r"no signed verdict: (pr-check|build) ", d) else 1)' "$ID/verdict.json" ||
          fail "candidate.sh found no image for ${head:0:12}, and its gate failed after the build: the harness"
        break
      fi
      # not built yet: the gate may already have ended at pr-check (no build at all)
      if verdict "$head" "$ID/verdict.json" && [[ $(py 'print(jload(sys.argv[1])["state"])' "$ID/verdict.json") == error ]]; then
        crc=0
        candidate "$head" "$ID/candidate.json" || crc=$?
        if ((crc == 0)); then built=1; break; fi
        py 'd = jload(sys.argv[1]).get("description") or ""
sys.exit(0 if re.match(r"no signed verdict: (pr-check|build) ", d) else 1)' "$ID/verdict.json" ||
          fail "the gate of ${head:0:12} (PR $prn) ended in an error with no image and not at pr-check or build: the harness"
        break
      fi
      if (($(date +%s) - t0 >= BUILD_WAIT)); then
        tl ph-end "$i" build timeout
        fail "no image for ${head:0:12} (PR $prn) after ${BUILD_WAIT} s" 4
      fi
      sleep "$POLL"
    done
    if [[ $built == 0 ]]; then
      tl ph-end "$i" build failed "$(cat "$ID/verdict.json")"
      { echo "The CI could not build your change into an image (PR #$prn), so it was not deployed:"
        py 'print(jload(sys.argv[1]).get("description") or "?")' "$ID/verdict.json"; echo
        if [[ -s $W/cand.err ]]; then echo "The end of the build's output:"; echo; tail -n 60 "$W/cand.err"; echo; fi
        echo "Fix the change so that it builds (Go 1.26, the module's own dependencies only)."; } > "$W/fb.txt"
      outcome "$i" build_failed build "$W/fb.txt"
      return 0
    fi
    tl ph-end "$i" build ok "$(cat "$ID/candidate.json")"
  fi
  tl iter-set "$i" "$(jo candidate# "$(cat "$ID/candidate.json")")"

  # 6 deploy + measure ------------------------------------------------------------------------------------------------
  stopped && finish stopped 5 "kill switch (state/muse/STOP)"
  local svcs launched pairs=()
  svcs=$(py 'print(",".join(jload(sys.argv[1])["services"]))' "$ID/candidate.json")
  mapfile -t pairs < <(py 'c = jload(sys.argv[1])
print("\n".join("%s=%s" % (s, c["digests"][s]) for s in c["services"]))' "$ID/candidate.json")
  tl ph-start "$i" measure
  launched=$(utc)
  rbd bg "muse-$TN" env "RBD_LOCK_WAIT=$LOCKW" "$TRUTHX" "$TN" "${pairs[@]}" > /dev/null || fail "cannot start truthx.sh on rbd-tools1"
  if ! wait_job rbd "muse-$TN" "$MEASURE_WAIT"; then
    tl ph-end "$i" measure timeout
    fail "truthx $TN still runs after ${MEASURE_WAIT} s: production may run the candidate; rbd.sh tail muse-$TN" 4
  fi
  trc=$JOB_RC
  rbd tail "muse-$TN" 200 2> /dev/null | sanitize 40000 > "$ID/measure.log" || true
  mkdir -p "$ID/truth"
  fetch_json "$RHOME/verify/truthx/$TN/truth.json" "$ID/truth/truth.json" || true
  local f
  for f in b0.load.json c.load.json; do
    if fetch "$RHOME/verify/truthx/$TN/$f" "$W/load.part" 4000000; then sanitize 4000000 < "$W/load.part" > "$ID/truth/$f"; fi
  done
  tl iter-set "$i" "$(jo measure_exit# "$trc" truth_status "$(py 'print((jload(sys.argv[1]) or {}).get("status") or "")' "$ID/truth/truth.json" 2> /dev/null || true)")"
  if ((trc == 4)); then
    tl iter-set "$i" "$(jo deployed# true)"
    tl ph-end "$i" measure rollback-failed
    fail "truthx $TN: THE ROLLBACK FAILED, production may run the candidate on $svcs: restore it by hand (see $ID/measure.log)" 4
  fi
  if ((trc != 0)) || [[ ! -s $ID/truth/b0.load.json || ! -s $ID/truth/c.load.json ]]; then
    tl ph-end "$i" measure failed "$(jo exit# "$trc")"
    local tst
    tst=$(py 'd = jload(sys.argv[1]) or {}; print(d.get("status") or "none", "drift" if d.get("drift_after") else "")' "$ID/truth/truth.json" 2> /dev/null || echo "none")
    case $tst in
      "failed-restored "|"failed-restored") fail "truthx $TN exited $trc (production restored: $tst): $ID/measure.log" ;;
      *) fail "truthx $TN exited $trc and truth.json says '$tst': PRODUCTION MAY RUN THE CANDIDATE; check it by hand: $ID/measure.log" 4 ;;
    esac
  fi
  # the regression rule: verify/regress.py (rbd.regress/v1, the policy's limits), else the same rule here (C - B0 > T)
  local rrc=0 rj=-
  if [[ -n $REGRESS && -f $REGRESS ]]; then
    rj=$ID/regress.json
    python3 -I "$REGRESS" --b0 "$ID/truth/b0.load.json" --c "$ID/truth/c.load.json" --policy "$POLICY" --out "$rj" \
      > /dev/null 2> "$ID/regress.err" || rrc=$?
    ((rrc <= 1)) || { tl ph-end "$i" measure error; fail "regress.py exited $rrc: $(sanitize 300 < "$ID/regress.err")"; }
  fi
  py '
d, thr, launched, rjson, out, name = sys.argv[1], float(sys.argv[2]), sys.argv[3], sys.argv[4], sys.argv[5], sys.argv[6]
def n(v):
    return v if isinstance(v, (int, float)) and not isinstance(v, bool) else None
def load(p):
    rows = {}
    for l in open(p, encoding="utf-8", errors="replace"):
        l = l.strip()
        if not l.startswith("{"):
            continue
        try:
            r = json.loads(l)
        except ValueError:
            continue
        u = r.get("url") if isinstance(r, dict) else None
        if isinstance(u, str) and "//" in u and n(r.get("mean_ms")) is not None:
            rows[u.split("//", 1)[1].split("/")[0].split(":")[0].split(".")[0]] = r
    return rows
b, c = load(os.path.join(d, "b0.load.json")), load(os.path.join(d, "c.load.json"))
if not b or set(b) != set(c):
    sys.exit("muse_arm: the B0 and C windows name different entries: %s vs %s" % (sorted(b), sorted(c)))
mine = {e: c[e]["mean_ms"] - b[e]["mean_ms"] for e in sorted(b)}
def errpct(r):
    ok, er = n(r.get("ok")) or 0, n(r.get("errors")) or 0
    return 100.0 * er / (ok + er) if ok + er else 0.0
rr = jload(rjson) if rjson != "-" else None
if rjson != "-":
    if not isinstance(rr, dict) or rr.get("schema") != "rbd.regress/v1" or not isinstance(rr.get("regressed"), bool) \
            or not isinstance(rr.get("entries"), list):
        sys.exit("muse_arm: regress.py wrote no rbd.regress/v1 document to %s" % rjson)
    rows = [r for r in rr["entries"] if isinstance(r, dict) and isinstance(r.get("entry"), str)]
    entries = {r["entry"]: float(r["change_ms"]) for r in rows if n(r.get("change_ms")) is not None}
    thrs = {r["entry"]: float(r["threshold_ms"]) for r in rows if n(r.get("threshold_ms")) is not None}
    regressed, errors_up = rr["regressed"], [str(x) for x in rr.get("errors_up") or []]
    production_ok = rr.get("production_ok") is True
    w = rr.get("worst") if isinstance(rr.get("worst"), dict) else {}
    unresolved = [str(x) for x in rr.get("unresolved") or []]
    src = "verify/regress.py"
else:
    entries, thrs = mine, {e: thr for e in mine}
    regressed = any(v > thr for v in mine.values())
    errors_up = [e for e in sorted(b) if errpct(c[e]) - errpct(b[e]) > 1.0 or not (n(c[e].get("ok")) or 0)]
    production_ok = not regressed and not errors_up
    w, unresolved = {}, [e for e in mine if abs(mine[e] - thr) < 2.0]
    src = "muse_arm (C - B0 per entry; regress.py absent)"
if not entries:
    sys.exit("muse_arm: no entry with a measured change")
worst = w.get("entry") if w.get("entry") in entries else max(entries, key=lambda e: entries[e] - thrs.get(e, thr))
over = max(0.0, entries[worst] - thrs.get(worst, thr))
t = jload(os.path.join(d, "truth.json")) or {}
T = t.get("times") if isinstance(t.get("times"), dict) else {}
pick = lambda *ks: next((T[k] for k in ks if isinstance(T.get(k), str)), None)
times = {"b0_start": pick("b0_start"), "b0_end": pick("b0_end"), "rollout_start": pick("deploy_started", "rollout_start"),
         "rollout_done": pick("deploy_done", "rollout_done"), "c_start": pick("c_window_start", "c_start"),
         "c_end": pick("c_window_end", "c_end"), "rollback_start": pick("rollback_started", "rollback_start"),
         "rollback_done": pick("rollback_done", "rollback_on_failure_done"), "finished": pick("finished", "complete")}
settle = n(t.get("b0_settle_s")) or 0
lock_end = None
if ts(times["b0_start"]) is not None and ts(launched) is not None:
    lock_end = time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(max(ts(launched), ts(times["b0_start"]) - settle)))
inprod = None
if ts(times["rollout_done"]) is not None and ts(times["rollback_done"]) is not None:
    inprod = (ts(times["rollback_done"]) - ts(times["rollout_done"])) / 60.0
m = {"name": name, "source": src, "threshold_ms": thr, "thresholds_ms": thrs, "entries": entries, "own_entries": mine,
     "worst_entry": worst, "worst_delta_ms": entries[worst], "over_ms": over, "regressed": bool(regressed),
     "errors_up": errors_up, "production_ok": bool(production_ok), "unresolved": unresolved, "noisy_band": worst in unresolved,
     "disagrees_with_own_rule": rr is not None and bool(regressed) != any(v > thr for v in mine.values()),
     "launched_at": launched, "truth_status": t.get("status"), "truth_schema": t.get("schema"), "window_s": t.get("window_s"),
     "b0_window_s": secs(times["b0_start"], times["b0_end"]), "b0_settle_s": settle, "lock_wait_s": secs(launched, lock_end),
     "times": times, "truth_times": T, "in_production_min": inprod,
     "exposure_ms_min": (inprod or 0.0) * over if regressed else 0.0,
     "services": t.get("services"), "cand_digests": t.get("cand_digests"), "warnings": (rr or {}).get("warnings")}
dump(out, m)
P = []
def add(ph, a, b_):
    if ts(a) is not None and ts(b_) is not None:
        P.append({"phase": "measure." + ph, "started_at": a, "ended_at": b_, "status": "ok"})
add("lock_wait", launched, lock_end)
if settle and lock_end:
    add("b0_settle", lock_end, times["b0_start"])
add("b0", times["b0_start"], times["b0_end"])
add("rollout", times["rollout_start"], times["rollout_done"])
add("warmup", times["rollout_done"], times["c_start"])
add("c", times["c_start"], times["c_end"])
add("rollback", times["rollback_start"], times["rollback_done"])
add("settle_back", times["rollback_done"], times["finished"])
print(json.dumps(P))' "$ID/truth" "$THR" "$launched" "$rj" "$ID/measure.json" "$TN" > "$W/sub.json" ||
    { tl ph-end "$i" measure error; fail "cannot score the bracket $TN (above)"; }
  tl ph-add "$i" "$(cat "$W/sub.json")"
  tl iter-set "$i" "$(jo measure# "$(cat "$ID/measure.json")" deployed# true)"
  local pok reg
  pok=$(py 'print(jload(sys.argv[1])["production_ok"])' "$ID/measure.json")
  reg=$(py 'print(jload(sys.argv[1])["regressed"])' "$ID/measure.json")
  tl ph-end "$i" measure "$([[ $pok == True ]] && echo clean || { [[ $reg == True ]] && echo regressed || echo errors-up; })" "$(py 'm = jload(sys.argv[1])
print(json.dumps({k: m[k] for k in ("worst_entry", "worst_delta_ms", "regressed", "errors_up", "production_ok", "lock_wait_s", "b0_window_s", "in_production_min")}))' "$ID/measure.json")"

  # 7 outcome -----------------------------------------------------------------------------------------------------------
  if [[ $pok == True ]]; then
    tl iter-set "$i" "$(jo outcome accepted ended_at "$(utc)")"
    tl top-set "$(jo accepted_iteration# "$i")"
    say "iteration $i: ACCEPTED (deployed, hidden tests pass, no entry over ${THR} ms, no error increase)"
    ITER_ACC=1
    return 0
  fi
  py 'm, prn = jload(sys.argv[1]), sys.argv[2]
what = "it regressed" if m["regressed"] else "the error rate went up"
out = ["Your change (PR #%s) was deployed to production and measured; %s, and it was rolled back." % (prn, what), "",
       "Mean latency per entry, C window minus B0 window (the SLO: no entry more than %.1f ms slower):" % m["threshold_ms"]]
for e, v in sorted(m["entries"].items(), key=lambda kv: -kv[1]):
    lim = m["thresholds_ms"].get(e, m["threshold_ms"])
    out.append("- %s: %+.2f ms%s" % (e, v, " (over the threshold)" if v > lim else ""))
if m["errors_up"]:
    out += ["", "Errors went up (the C window failed a larger share of requests than B0) at: " + ", ".join(m["errors_up"])]
out += ["", "Single-window noise is about +-2 ms. Revise the change so that no entry is slower by more than %.1f ms; the ticket still holds." % m["threshold_ms"]]
print("\n".join(out))' "$ID/measure.json" "$prn" > "$W/fb.txt"
  outcome "$i" "$([[ $reg == True ]] && echo regressed || echo errors_up)" measured "$W/fb.txt"
  return 0
}

close_superseded() { # UPTO: close every earlier iteration's open PR (arm R: at once; arm C: once its counterfactual is final)
  local upto=$1 j n p last
  n=$(tl get iterations | py 'print(len(json.load(sys.stdin) or []))')
  for ((j = 1; j < upto && j <= n; j++)); do
    p=$(tl get "iterations.$((j - 1)).pr")
    [[ $p =~ ^[0-9]+$ ]] || continue
    [[ $(tl get "iterations.$((j - 1)).closed") != true ]] || continue
    if [[ $ARM == C ]]; then
      [[ $(tl get "iterations.$((j - 1)).counterfactual.final") == true ]] || continue
    fi
    last=$(tl get "iterations.$((upto - 1)).pr")
    close_pr "$p" "Superseded by a later iteration${last:+ (#$last)} of the Muse experiment, ticket $TICKET arm $ARM. Closed, never merged."
    [[ $(pr_state "$p") == OPEN ]] || tl iter-set "$j" "$(jo closed# true closed_at "$(utc)")"
  done
}

cf_collect() { # WAIT_S: arm C's counterfactual: the gate verdict CI computed for every head without a final one yet
  local w=$1 t0 n j head left
  t0=$(date +%s)
  n=$(tl get iterations | py 'print(len(json.load(sys.stdin) or []))')
  while :; do
    left=0
    for ((j = 1; j <= n; j++)); do
      head=$(tl get "iterations.$((j - 1)).head")
      [[ $head =~ ^[0-9a-f]{40}$ ]] || continue
      [[ $(tl get "iterations.$((j - 1)).counterfactual.final") != true ]] || continue
      local CD
      CD=$TD/iter-$(printf '%02d' "$j")/counterfactual
      mkdir -p "$CD"
      if verdict "$head" "$CD/verdict.json" && [[ $(py 'print(jload(sys.argv[1])["final"])' "$CD/verdict.json") == True ]]; then
        gate_artifacts "$head" "$CD"
        tl iter-set "$j" "$(jo counterfactual# "$(py 'v = jload(sys.argv[1]); g = jload(sys.argv[2]) or {}
print(json.dumps(dict(v, deciding_rules=g.get("deciding_rules"), other_rules=g.get("other_rules"), decide_with=g.get("decide_with"), recorded_at=now())))' "$CD/verdict.json" "$CD/gate-summary.json")")"
        say "counterfactual for iteration $j (${head:0:12}): $(py 'v = jload(sys.argv[1]); print(v["verdict"], v.get("rule") or "")' "$CD/verdict.json")"
      else
        [[ -s $CD/verdict.json ]] && tl iter-set "$j" "$(jo counterfactual# "$(cat "$CD/verdict.json")")"
        left=$((left + 1))
      fi
    done
    ((left > 0)) || return 0
    if (($(date +%s) - t0 >= w)); then say "$left counterfactual verdict(s) still pending after ${w} s: muse_arm.sh $TICKET C --collect later"; return 4; fi
    sleep "$POLL"
  done
}

# ---- main ----------------------------------------------------------------------------------------------------------------
for c in gh python3 flock; do command -v "$c" > /dev/null || { echo "muse_arm: $c is required" >&2; exit 1; }; done
W=$(mktemp -d "$STATE/muse/.tmp.XXXXXX")
exec 9>> "$TD/.lock"
flock -n 9 || { echo "muse_arm: another muse_arm.sh holds $TD/.lock" >&2; exit 1; }
if [[ $COLLECT == 1 ]]; then
  [[ -s $TL ]] || { echo "muse_arm: no $TL to collect for" >&2; exit 1; }
  FINISHED=1 OWN=0   # a collection never changes the arm's status
  rc=0
  cf_collect "$CF_WAIT" || rc=$?
  n=$(tl get iterations | py 'print(len(json.load(sys.stdin) or []))')
  close_superseded "$n"
  tl top-set "$(jo counterfactual_collected_at "$(utc)")"
  exit "$rc"
fi
exec 8>> "$STATE/muse/.driver.lock"
flock -n 8 || { echo "muse_arm: another arm runs (state/muse/.driver.lock): one arm at a time" >&2; exit 1; }
[[ ! -e $TL ]] || { echo "muse_arm: $TL exists: this arm already ran; a new attempt needs --tag T (task.sh and truthx.sh refuse names that ran; --collect: arm C's counterfactual)" >&2; exit 1; }
stopped && { echo "muse_arm: kill switch state/muse/STOP is set" >&2; exit 5; }
THR=$(py 'v = (jload(sys.argv[1]) or {}).get("max_entry_mean_change_ms")
if not isinstance(v, (int, float)) or isinstance(v, bool) or v <= 0:
    sys.exit("muse_arm: %s has no max_entry_mean_change_ms" % sys.argv[1])
print(float(v))' "$POLICY") || exit 1
gh auth status > /dev/null 2>&1 || { echo "muse_arm: gh is not logged in" >&2; exit 1; }
# the remote steps exist on rbd-tools1 (read-only, as rbd): a missing one would otherwise surface only as a long wait
pre=("$TASKSH" "$HIDDEN" "$TRUTHX")
[[ -z $CANDSH ]] || pre+=("$CANDSH")
# shellcheck disable=SC2016  # expanded on rbd-tools1
miss=$(rbd run bash -c 'for f; do [ -x "$f" ] || printf "%s " "$f"; done; echo end' pre "${pre[@]}" 2> /dev/null) ||
  { echo "muse_arm: cannot reach rbd-tools1 (orch/rbd.sh run)" >&2; exit 1; }
[[ $miss == end ]] || { echo "muse_arm: missing (or not executable) on rbd-tools1: ${miss% end}" >&2; exit 1; }
# the main the agent works on (tools1's src/main.sha, export.py's base_sha) must be the one agent_take.sh compares with
here_sha=$(head -c 40 "$MAINSHA" 2> /dev/null || true)
[[ $here_sha =~ ^[0-9a-f]{40}$ ]] || { echo "muse_arm: no commit in $MAINSHA (orch/publish_main.sh writes it; agent_take.sh needs it)" >&2; exit 1; }
# shellcheck disable=SC2016  # expanded on rbd-tools1
there_sha=$(rbd run bash -c "$FETCHSH" fetch src/main.sha 200 2> /dev/null | head -c 40) || there_sha=""
[[ $there_sha == "$here_sha" ]] || { echo "muse_arm: rbd-tools1's src/main.sha (${there_sha:-none}) is not $MAINSHA ($here_sha): agent_take.sh would refuse every change; sync main first" >&2; exit 1; }
[[ -n $REGRESS && -f $REGRESS ]] || say "verify/regress.py absent: the regression rule here (C - B0 per entry > ${THR} ms)"
tl init "$(jo schema rbd.muse-arm/v1 ticket "$TICKET" arm "$ARM" run "$RUN" max_iter# "$MAXI" repo "$REPO" threshold_ms# "$THR" \
  started_at "$(utc)" status running accepted_iteration# "" \
  arm_desc "$([[ $ARM == R ]] && echo "rhobound: muser with the plugin and MCP; only a gate pass is deployed" || echo "chaotic: musec, no plugin, no MCP; deployed as soon as the image is built")" \
  main_sha "$here_sha" tag "$TAG")"
OWN=1
say "start: ticket $TICKET, arm $ARM, at most $MAXI iteration(s), threshold ${THR} ms"
ACC=0
for ((i = 1; i <= MAXI; i++)); do
  # the declared time box (DECLARE-2.md): no new iteration at or after MUSE_DEADLINE (epoch seconds)
  if [[ -n ${MUSE_DEADLINE:-} ]] && (($(date +%s) >= MUSE_DEADLINE)); then
    say "time box: no new iteration at or after $(date -u -d "@$MUSE_DEADLINE" +%H:%MZ) (MUSE_DEADLINE)"
    tl top-set "$(jo time_boxed_at "$(utc)" time_boxed_before_iter# "$i")"
    break
  fi
  ITER_ACC=0
  iterate "$i"
  if ((ITER_ACC)); then ACC=$i; break; fi
  if [[ $ARM == C ]]; then cf_collect 0 > /dev/null 2>&1 || true; fi   # an early counterfactual is recorded as soon as it is in
done
last=$(tl get iterations | py 'print(len(json.load(sys.stdin) or []))')
if [[ $ARM == C ]]; then
  cfrc=0
  cf_collect "$CF_WAIT" || cfrc=$?
  tl top-set "$(jo counterfactual_collected_at "$(utc)" counterfactual_complete# "$([[ $cfrc == 0 ]] && echo true || echo false)")"
fi
close_superseded "$last"
if ((ACC > 0)); then finish accepted 0; fi
finish not_accepted 3 "not accepted within $MAXI iteration(s) (state/muse/$TICKET-$ARM/timeline.json)"
