#!/usr/bin/env bash
# bench.sh TASK [--from STEP]   (SPEC2 S0-S10, driven from this box) one bench task end to end: the funnel on rbd-tools1, the
#   selected approach as a PR, the gate, the auto-merge, the deploy, the production check. Every step writes under
#   state/bench/TASK/; --from STEP restarts at STEP with what the earlier steps recorded (run.json, pr.json, ...).
#    1 check   the task ships with the kit (tools1/bench/tasks/TASK/task.json whose id is TASK; rbd_bootstrap.sh kit installs
#              it as /opt/rbd/bench/tasks/TASK); state/main.sha; no kill switch. RUN = b-TASK-<UTC ddHHMM> (agent_take.sh's
#              RUN pattern), CHANGE = the next free cN-bench -> state/bench/TASK/run.json
#    2 before  orch/rbd.sh run cat baseline.json -> baseline-before.json (S10's previous production fit)
#    3 funnel  orch/rbd.sh bg RUN python3 -I /opt/rbd/bench/run_task.py /opt/rbd/bench/tasks/TASK /var/lib/rbd/bench/RUN
#              --policy <main's policy/gate.json> --take-out /var/lib/rbd/agent/RUN (as rbd,
#              detached: S0 plan .. S6 select). Its contract here: /var/lib/rbd/bench/RUN/funnel.json (rbd.bench-funnel/v1)
#              and, when it selects an approach, that approach's OUT in agent.py's format at /var/lib/rbd/agent/RUN
#    4 wait    orch/rbd.sh tail RUN every BENCH_POLL s until 'done, exit N' (at most BENCH_WAIT s); N != 0: stop
#    5 fetch   orch/rbd.sh get /var/lib/rbd/bench/RUN/funnel.json -> funnel.json (read as data); selected null: stop (exit 3,
#              every approach was cut; the scoreboard reads the funnel)
#    6 take    orch/agent_take.sh RUN CHANGE: the OUT as untrusted data (tree and content checks, compiled, never run) ->
#              changes/CHANGE/{change.patch, rhobound-change.json (v2 as written), title.txt, manifest.json}
#    7 pr      changes/make_prs.sh CHANGE (branch rbd/CHANGE, label rbd-bench); gh pr list --head rbd/CHANGE -> pr.json
#              {task, change, branch, pr, head, url, run, approach}: the only PRs orch/automerge.sh merges
#    8 merge   orch/automerge.sh pr N --task TASK: waits for the gate's rhobound/verdict on that head, merges a pass, waits
#              for the merge's deploy.yml run (deploy.sh v2 + settle + refit) -> timeline.json
#    9 gate    the gate's artifacts for the scoreboard (any verdict): runs/HEAD/{predict.json, prediction.json, gate/,
#              ab*/ab.json} -> state/bench/runs/HEAD/ (file by file: never the run folder, its A/B traces are hundreds of MB)
#   10 prod    after a successful deploy: baseline-after.json, then tools1/bench/prodcheck.py on rbd-tools1 (--previous the
#              before fit, --current the after fit, --services of rhobound-change.json, --prediction the gate's) ->
#              prodcheck.json (S10, report-only)
# Then: python3 -I verify/bench_score.py (the scoreboard; reads state/bench/).
# This box never runs kubectl, aws or docker: rbd-tools1 is reached through orch/rbd.sh (ssh), GitHub through gh.
# Exit 0 deployed and checked; 1 a step failed; 3 nothing merged (every approach cut, or a non-pass verdict: recorded, the PR
# left open); 4 timed out; 5 kill switch (state/automerge.stop). It runs for hours: detached, as the RUNBOOK does:
#   setsid nohup bash orch/bench.sh TASK > state/logs/bench-TASK.log 2>&1 < /dev/null &
# Env: RBD_SH [orch/rbd.sh]  BENCH_AGENT_TAKE [orch/agent_take.sh]  BENCH_MAKE_PRS [changes/make_prs.sh]  BENCH_AUTOMERGE
#      [orch/automerge.sh]  BENCH_CHANGES [changes/]  BENCH_TASKS [tools1/bench/tasks] (tests: stand-ins)  BENCH_POLL [60 s]  BENCH_WAIT [14400 s]
#      BENCH_GATE_WAIT [7200 s]  REPO [Sharvil2704/rhobound-demo]  RBD_STATE [kit/state]  DRYRUN [0: 1 stops after make_prs.sh's dry run]
set -euo pipefail
DEMO=$(cd "$(dirname "$0")/.." && pwd)
RBD=${RBD_SH:-$DEMO/orch/rbd.sh}
TAKE=${BENCH_AGENT_TAKE:-$DEMO/orch/agent_take.sh}
MKPR=${BENCH_MAKE_PRS:-$DEMO/changes/make_prs.sh}
AUTOM=${BENCH_AUTOMERGE:-$DEMO/orch/automerge.sh}
CHANGES=${BENCH_CHANGES:-$DEMO/changes}
TASKS=${BENCH_TASKS:-$DEMO/tools1/bench/tasks}
STATE=${RBD_STATE:-$DEMO/state}
REPO=${REPO:-Sharvil2704/rhobound-demo}
POLL=${BENCH_POLL:-60}
WAITS=${BENCH_WAIT:-14400}
GWAIT=${BENCH_GATE_WAIT:-7200}
DRYRUN=${DRYRUN:-0}
say() { echo "[bench $(date -u +%H:%M:%S)] $*" >&2; }
die() { echo "bench: error: $*" >&2; exit "${2:-1}"; }
[[ $# -ge 1 && $1 =~ ^[A-Za-z0-9][A-Za-z0-9_.-]{0,20}$ ]] || die "usage: bench.sh TASK [--from STEP] (TASK: a folder of tools1/bench/tasks)" 2
TASK=$1 FROM=1
shift
if [[ $# -eq 2 && $1 == --from && $2 =~ ^([1-9]|10)$ ]]; then FROM=$2; elif [[ $# -ne 0 ]]; then die "usage: bench.sh TASK [--from STEP]" 2; fi
[[ $POLL =~ ^[0-9]+$ && $WAITS =~ ^[0-9]+$ && $GWAIT =~ ^[0-9]+$ ]] || die "BENCH_POLL, BENCH_WAIT, BENCH_GATE_WAIT: whole seconds" 2
TD=$STATE/bench/$TASK
mkdir -p "$TD"
rbd() { bash "$RBD" "$@"; }
stopped() { [[ -e $STATE/automerge.stop ]]; }
jf() { python3 -I -c 'import json,sys; v=json.load(open(sys.argv[1])).get(sys.argv[2]); print("" if v is None else v)' "$1" "$2"; }
mark() { echo "$(date -u +%Y-%m-%dT%H:%M:%SZ) step $1 done${2:+: $2}" >> "$TD/steps.log"; say "step $1 done${2:+: $2}"; }
run_step() { [[ $1 -ge $FROM ]]; }

# 1 check -----------------------------------------------------------------------------------------------------------------
if run_step 1; then
  python3 -I -c 'import json,sys; d=json.load(open(sys.argv[1])); sys.exit(0 if d.get("id") == sys.argv[2] else 1)' \
    "$TASKS/$TASK/task.json" "$TASK" 2> /dev/null ||
    die "tools1/bench/tasks/$TASK/task.json is missing or its id is not $TASK (tasks ship with the kit: rbd_bootstrap.sh kit)"
  [[ -s $STATE/main.sha ]] || die "no state/main.sha (orch/publish_main.sh writes it; agent_take.sh needs it)"
  stopped && die "kill switch state/automerge.stop is set: remove it to run a bench task" 5
  [[ ! -e $TD/run.json ]] || die "state/bench/$TASK/run.json exists: this task already started; --from STEP resumes it, or move state/bench/$TASK away"
  RUN=b-$TASK-$(date -u +%d%H%M)
  n=$(find "$CHANGES" -maxdepth 1 -type d -name 'c[0-9]*-*' -printf '%f\n' 2> /dev/null | sed -n 's/^c\([0-9]\{1,2\}\)-.*/\1/p' | sort -n | tail -n 1)
  CHANGE=c$(( ${n:-6} + 1 ))-bench
  [[ $CHANGE =~ ^c[0-9]{1,2}-bench$ ]] || die "no free cN-bench name under changes/ (c99 reached)"
  python3 -I -c 'import json,sys,time; json.dump({"task": sys.argv[1], "run": sys.argv[2], "change": sys.argv[3],
    "started_at": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())}, open(sys.argv[4], "w"), indent=1)' "$TASK" "$RUN" "$CHANGE" "$TD/run.json"
  mark 1 "run $RUN, change $CHANGE"
fi
[[ -s $TD/run.json ]] || die "no state/bench/$TASK/run.json: start at step 1"
RUN=$(jf "$TD/run.json" run) CHANGE=$(jf "$TD/run.json" change)
[[ $RUN =~ ^[A-Za-z0-9][A-Za-z0-9_-]{0,31}$ && $CHANGE =~ ^c[0-9]{1,2}-bench$ ]] || die "state/bench/$TASK/run.json: bad run or change"

# 2 before: the production fit S10 compares against ------------------------------------------------------------------------
if run_step 2; then
  rbd run cat baseline.json > "$TD/baseline-before.json.tmp" || die "cannot read baseline.json on rbd-tools1 (orch/rbd.sh run)"
  python3 -I -c 'import json,sys; d=json.load(open(sys.argv[1])); assert d["fit"]["dir"]' "$TD/baseline-before.json.tmp" 2> /dev/null ||
    die "baseline.json on rbd-tools1 has no fit.dir"
  mv -f "$TD/baseline-before.json.tmp" "$TD/baseline-before.json"
  mark 2 "fit $(python3 -I -c 'import json,sys; print(json.load(open(sys.argv[1]))["fit"]["digest"])' "$TD/baseline-before.json")"
fi

# 3 funnel (detached on rbd-tools1) ------------------------------------------------------------------------------------------
if run_step 3; then
  stopped && die "kill switch state/automerge.stop" 5
  rbd bg "$RUN" python3 -I /opt/rbd/bench/run_task.py "/opt/rbd/bench/tasks/$TASK" "/var/lib/rbd/bench/$RUN" \
    --policy /var/lib/rbd/src/main/policy/gate.json --take-out "/var/lib/rbd/agent/$RUN" ||
    die "cannot start the funnel on rbd-tools1 (orch/rbd.sh bg)"
  mark 3 "run_task.py started as $RUN"
fi

# 4 wait ---------------------------------------------------------------------------------------------------------------------
if run_step 4; then
  t0=$(date +%s)
  while :; do
    line=$(rbd tail "$RUN" 3) || line=""   # no pipe into head: a SIGPIPE under pipefail would drop the line
    line=${line%%$'\n'*}
    if [[ $line =~ ^==\ .*:\ done,\ exit\ ([0-9]+)$ ]]; then
      rc=${BASH_REMATCH[1]}
      [[ $rc == 0 ]] || die "the funnel ended with exit $rc: orch/rbd.sh tail $RUN 50"
      break
    fi
    (($(date +%s) - t0 < WAITS)) || die "the funnel $RUN still runs after ${WAITS} s (orch/rbd.sh tail $RUN): not waiting longer; --from 4 later" 4
    sleep "$POLL"
  done
  mark 4 "the funnel ended (exit 0)"
fi

# 5 fetch funnel.json --------------------------------------------------------------------------------------------------------
if run_step 5; then
  rm -rf "$TD/fetch"
  mkdir -p "$TD/fetch"
  rbd get "/var/lib/rbd/bench/$RUN/funnel.json" "$TD/fetch" || die "cannot fetch /var/lib/rbd/bench/$RUN/funnel.json"
  [[ -f $TD/fetch/funnel.json && ! -L $TD/fetch/funnel.json ]] || die "the fetch brought no funnel.json"
  (($(stat -c %s "$TD/fetch/funnel.json") < 4000000)) || die "funnel.json over 4 MB: refused"
  python3 -I - "$TD/fetch/funnel.json" "$TASK" << 'PY' || die "funnel.json is refused (above)"
import json, re, sys
d = json.load(open(sys.argv[1]))
if d.get("task") != sys.argv[2] or not isinstance(d.get("approaches"), list):
    sys.exit("bench: funnel.json is not task %s's (task %r)" % (sys.argv[2], d.get("task")))
s = d.get("selected")
if s is not None and (not isinstance(s, str) or not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9_.-]{0,63}", s)
                      or s not in [a.get("id") for a in d["approaches"] if isinstance(a, dict)]):
    sys.exit("bench: funnel.json selects %r, not one of its approaches" % (s,))
PY
  mv -f "$TD/fetch/funnel.json" "$TD/funnel.json"
  rm -rf "$TD/fetch"
  sel=$(jf "$TD/funnel.json" selected)
  if [[ -z $sel ]]; then
    mark 5 "no approach selected: every approach was cut"
    say "nothing to merge for $TASK (the funnel cut every approach); next: python3 -I verify/bench_score.py"
    exit 3
  fi
  mark 5 "selected $sel"
fi
SEL=$(jf "$TD/funnel.json" selected)

# 6 take ----------------------------------------------------------------------------------------------------------------------
if run_step 6; then
  rc=0
  bash "$TAKE" "$RUN" "$CHANGE" || rc=$?
  ((rc == 0)) || die "agent_take.sh $RUN $CHANGE exited $rc (3: does not compile; state/agent/$RUN.compile.txt)"
  [[ -s $CHANGES/$CHANGE/rhobound-change.json ]] || die "agent_take.sh wrote no changes/$CHANGE/rhobound-change.json"
  mark 6 "changes/$CHANGE"
fi

# 7 pr ------------------------------------------------------------------------------------------------------------------------
if run_step 7; then
  stopped && die "kill switch state/automerge.stop" 5
  DRYRUN=$DRYRUN bash "$MKPR" "$CHANGE" || die "make_prs.sh $CHANGE failed"
  if [[ $DRYRUN == 1 ]]; then say "DRYRUN: make_prs.sh ran dry; no PR, stopping here"; exit 0; fi
  gh pr list --repo "$REPO" --head "rbd/$CHANGE" --state open --json number,headRefOid,url > "$TD/pr-list.json" ||
    die "gh pr list --head rbd/$CHANGE failed"
  python3 -I - "$TD/pr-list.json" "$TASK" "$CHANGE" "$RUN" "$SEL" "$TD/pr.json" << 'PY' || die "no open PR for rbd/$CHANGE (above)"
import json, os, re, sys
lst, task, change, run, sel, out = sys.argv[1:7]
prs = json.load(open(lst))
if len(prs) != 1 or not isinstance(prs[0].get("number"), int) or not re.fullmatch("[0-9a-f]{40}", prs[0].get("headRefOid") or ""):
    sys.exit("bench: %d open PRs for rbd/%s: %s" % (len(prs), change, json.dumps(prs)[:300]))
p = prs[0]
d = {"task": task, "change": change, "branch": "rbd/" + change, "pr": p["number"], "head": p["headRefOid"], "url": p.get("url"),
     "run": run, "approach": sel}
with open(out + ".tmp", "w") as f:
    json.dump(d, f, indent=1)
os.replace(out + ".tmp", out)
PY
  mark 7 "PR $(jf "$TD/pr.json" pr) at $(jf "$TD/pr.json" head)"
fi
[[ -s $TD/pr.json ]] || die "no state/bench/$TASK/pr.json (step 7)"
PRN=$(jf "$TD/pr.json" pr)

# 8 merge ---------------------------------------------------------------------------------------------------------------------
MRC=0
if run_step 8; then
  bash "$AUTOM" pr "$PRN" --task "$TASK" --wait "$GWAIT" || MRC=$?
  echo "$MRC" > "$TD/automerge.rc"
  mark 8 "automerge.sh exit $MRC"
else
  MRC=$(cat "$TD/automerge.rc" 2> /dev/null || echo 1)
fi
[[ -s $TD/timeline.json ]] || die "automerge.sh wrote no timeline.json (exit $MRC)" "$((MRC ? MRC : 1))"
HEAD=$(jf "$TD/timeline.json" head)
[[ $HEAD =~ ^[0-9a-f]{40}$ ]] || die "timeline.json has no head sha"

# 9 the gate's artifacts ------------------------------------------------------------------------------------------------------
if run_step 9 && [[ -n $(jf "$TD/timeline.json" verdict) && $(jf "$TD/timeline.json" verdict) != pending ]]; then
  G=$STATE/bench/runs/$HEAD
  mkdir -p "$G"
  # shellcheck disable=SC2016  # expanded on rbd-tools1
  have=$(rbd run bash -c 'cd "runs/$1" 2> /dev/null && ls -d predict.json prediction.json gate ab ab-* 2> /dev/null; true' _ "$HEAD") || have=""
  [[ -n $have ]] || say "WARNING: runs/$HEAD on rbd-tools1 listed nothing: the gate's artifacts are NOT fetched (the scoreboard loses this chain); --from 9 later"
  for x in $have; do
    case $x in
      predict.json | prediction.json | gate) rbd get "/var/lib/rbd/runs/$HEAD/$x" "$G" || say "could not fetch runs/$HEAD/$x" ;;
      ab | ab-[a-z]*) mkdir -p "$G/$x"; rbd get "/var/lib/rbd/runs/$HEAD/$x/ab.json" "$G/$x" || say "could not fetch runs/$HEAD/$x/ab.json" ;;
      *) say "skipping an odd name in runs/$HEAD: $x" ;;
    esac
  done
  mark 9 "runs/$HEAD: $(tr '\n' ' ' <<< "$have")"
fi

case $MRC in
  0) ;;
  3) say "PR $PRN not merged (verdict $(jf "$TD/timeline.json" verdict) $(jf "$TD/timeline.json" rule)): recorded, left open"; exit 3 ;;
  *) die "automerge.sh exited $MRC (state/bench/$TASK/automerge.jsonl)" "$MRC" ;;
esac

# 10 production check (S10) ---------------------------------------------------------------------------------------------------
if run_step 10; then
  rbd run cat baseline.json > "$TD/baseline-after.json.tmp" || die "cannot read baseline.json after the deploy"
  mv -f "$TD/baseline-after.json.tmp" "$TD/baseline-after.json"
  read -r PREV CUR SVCS < <(python3 -I - "$TD/baseline-before.json" "$TD/baseline-after.json" "$CHANGES/$CHANGE/rhobound-change.json" << 'PY'
import json, re, sys
b, a, rc = (json.load(open(p)) for p in sys.argv[1:4])
pat = re.compile(r"/var/lib/rbd/captures/[A-Za-z0-9][A-Za-z0-9._-]{0,63}/fit")
for d in (b, a):
    if not pat.fullmatch(str(d.get("fit", {}).get("dir"))):
        sys.exit("bench: baseline.json fit.dir %r is not a captures/NAME/fit folder" % d.get("fit", {}).get("dir"))
svcs = [s for s in rc.get("services", []) if re.fullmatch(r"[a-z][a-z0-9-]{0,31}", str(s))]
print(b["fit"]["dir"], a["fit"]["dir"], ",".join(svcs) or "-")
PY
  ) || die "cannot read the fit folders of baseline-before/after.json"
  [[ $PREV != "$CUR" ]] || say "WARNING: the fit did not change across the deploy (no refit?): the check compares a fit with itself"
  rbd run python3 -I /opt/rbd/bench/prodcheck.py --previous "$PREV/fit.json" --current "$CUR/fit.json" --services "$SVCS" \
    --prediction "/var/lib/rbd/runs/$HEAD/prediction.json" --out "/var/lib/rbd/bench/$RUN/prodcheck.json" ||
    die "prodcheck.py failed on rbd-tools1"
  rm -rf "$TD/fetch"
  mkdir -p "$TD/fetch"
  rbd get "/var/lib/rbd/bench/$RUN/prodcheck.json" "$TD/fetch" || die "cannot fetch prodcheck.json"
  mv -f "$TD/fetch/prodcheck.json" "$TD/prodcheck.json"
  rm -rf "$TD/fetch"
  mark 10 "prodcheck.json"
fi
say "$TASK: deployed and production-checked; next: python3 -I verify/bench_score.py"
