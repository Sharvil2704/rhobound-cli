#!/usr/bin/env bash
# What sudo hands the steps (round-1 recheck1 finding 4, recheck2 finding 5) and ab.sh's run rules (recheck1 finding 3):
# every sudo-able step is #!/bin/bash and ignores RBD_OPT (the kit root) when SUDO_USER is set; ab.sh takes runs/RUN/.lock
# and refuses a run that holds a prediction before any cluster call, while a run without one may be re-run; its 5th
# argument AB_DIR (CI v2) is ab or ab-SERVICE only.
set -uo pipefail
# shellcheck source=tools1/tests/ci/lib.sh
. "$(dirname "$0")/lib.sh"
echo "== guards: shebang, RBD_OPT under sudo, ab.sh's run lock and no re-roll"
mkenv guards
STEPS=(pr-check build ab predict sign report deploy)   # the sudoers drop-in's seven
for s in "${STEPS[@]}"; do
  check "$s.sh starts with #!/bin/bash (no PATH lookup of bash under sudo)" test "$(head -n 1 "$CI/$s.sh")" = '#!/bin/bash'
done
H=0123456789abcdef0123456789abcdef01234567 D=sha256:$(printf d | sha256sum | cut -d' ' -f1)
args() { # the step's arguments
  case $1 in
    pr-check) echo "$T $H $H" ;; build) echo "$T $H auth" ;; ab) echo "$H auth $D $D" ;; deploy) echo "auth $D" ;; *) echo "$H" ;;
  esac
}
if [[ -e /opt/rbd ]]; then
  bad "/opt/rbd exists on this machine: the RBD_OPT-under-sudo checks would run the real kit; not run"
else
  for s in "${STEPS[@]}"; do
    # shellcheck disable=SC2046  # the arguments are words
    SUDO_USER=someone "$CI/$s.sh" $(args "$s") > "$T/out" 2> "$T/err"
    rc=$?
    check "$s.sh with SUDO_USER set ignores RBD_OPT=$TROOT: it looks for /opt/rbd/lib/rbd-env.sh and refuses (exit $rc)" \
      bash -c "[ $rc -ne 0 ] && grep -q '/opt/rbd/lib/rbd-env.sh' '$T/err' && ! grep -q 'kubectl' '$STUB_DIR/calls.log'"
  done
fi

# ab.sh in the test kit: part B's lib and part C's helpers, the stubs; it is refused before any cluster call here
cp "$KIT/tools1/lib/copy_traces.sh" "$KIT/tools1/lib/abmix.py" "$KIT/tools1/lib/splitarms.py" "$TROOT/lib/"
printf '{"abdrive": "123456789012.dkr.ecr.ap-south-1.amazonaws.com/rhobound-demo/maze@sha256:%064d"}\n' 1 > "$THOME/images.json"
mkbaseline
runab() { AB_LOCK_WAIT=1 bash "$CI/ab.sh" "$@" > "$T/out" 2> "$T/err"; echo $?; }
abref() { # abref RC STAGE TEXT: ab.sh exit 1 at STAGE with TEXT on stderr, and no kubectl call
  [[ $1 -eq 1 && $(tail -n 1 "$T/out" | python3 -I -c 'import json,sys; print(json.load(sys.stdin)["stage"])') == "$2" ]] &&
    grep -q -- "$3" "$T/err" && ! grep -q '^kubectl' "$STUB_DIR/calls.log"
}
R=$THOME/runs/$H
mkdir -p "$R"
for x in predict.json gate; do
  if [[ $x == gate ]]; then mkdir "$R/gate"; else echo '{}' > "$R/$x"; fi
  rc=$(runab "$H" auth "$D" "$D")
  check "ab.sh refuses a run that holds $x (no re-roll; exit $rc, stage run, no kubectl call, no ab/)" abref "$rc" run \
    'already holds a prediction (predict.json or gate/): its A/B is not re-run; a re-gate needs a new commit'
  check "  and wrote nothing under runs/RUN/ab" test ! -e "$R/ab"
  rm -rf "${R:?}/$x"
done
lockrun "$R/.lock" || bad "lockrun: the holder never took the lock"
rc=$(runab "$H" auth "$D" "$D")
unlockrun
check "ab.sh refuses while another step of the same run holds runs/RUN/.lock (exit $rc, stage run, no kubectl call)" \
  abref "$rc" run "another step of runs/$H is running"
# a run without a prediction is not refused by those rules (a 'gh run rerun' of a job that failed before predict.sh): it goes
# on to the cluster lock, held here by another job, so still nothing reaches the cluster
exec 6>> "$THOME/lock"
flock -n 6 || bad "cannot take the cluster lock for the test"
rc=$(runab "$H" auth "$D" "$D")
flock -u 6
exec 6>&-
check "ab.sh on a run without a prediction passes the run rules and waits for the cluster lock (exit $rc, stage lock)" \
  abref "$rc" lock "cluster lock is held"
# CI v2: a 5th argument AB_DIR (ab, the default, or ab-SERVICE) so the A/Bs of a multi-service change live side by side
for bad in ab-pricing ../ab ab-auth/x abx ab-; do
  rc=$(runab "$H" auth "$D" "$D" "$bad")
  check "ab.sh refuses AB_DIR '$bad' for service auth (want ab or ab-auth; exit $rc, stage usage, no kubectl call)" \
    abref "$rc" usage "AB_DIR .*: want ab or ab-auth"
done
check "  and created no folder for them under runs/RUN" bash -c "! ls -A '$R' | grep -qv '^\.lock\$'"
rc=$(runab "$H" auth "$D" "$D" ab-auth preview extra)
check "ab.sh refuses 7 arguments (exit $rc, stage usage)" abref "$rc" usage "usage: ab.sh RUN SERVICE BASE_DIGEST CAND_DIGEST \[AB_DIR \[preview|SECONDS\]\]"
rc=$(runab "$H" auth "$D" "$D" ab-auth bogus)
check "ab.sh refuses a 6th argument that is neither preview nor SECONDS (exit $rc, stage usage)" abref "$rc" usage "want preview or SECONDS"
rc=$(runab "$H" --all 600 extra)
check "ab.sh --all takes RUN and at most SECONDS (exit $rc, stage usage)" abref "$rc" usage "ab.sh RUN --all \[SECONDS\]"
echo '{}' > "$R/predict.json"
rc=$(runab "$H" auth "$D" "$D" ab-auth)
check "ab.sh with AB_DIR ab-auth refuses a run that holds a prediction (exit $rc, stage run, no kubectl call)" \
  abref "$rc" run "already holds a prediction"
check "  and wrote nothing under runs/RUN/ab-auth" test ! -e "$R/ab-auth"
rm -f "$R/predict.json"
exec 6>> "$THOME/lock"
flock -n 6 || bad "cannot take the cluster lock for the test"
rc=$(runab "$H" auth "$D" "$D" ab-auth)
flock -u 6
exec 6>&-
check "ab.sh with AB_DIR ab-auth passes the run rules and waits for the cluster lock (exit $rc, stage lock)" \
  abref "$rc" lock "cluster lock is held"

# ab.sh --all (parallel A/Bs, 2026-11-03): the parent's plan, locks, nodes and queue, with a stand-in child (AB_TEST_CHILD)
# and a kubectl that serves the A/B pool's nodes; the real child's checks (token, inherited run lock) on ab.sh itself
H2=89abcdef0123456789abcdef0123456789abcdef R2=$THOME/runs/$H2
mkdir -p "$R2" "$T/abbin"
python3 -I - "$R2" << 'PY'
import hashlib, json, os, sys
run = sys.argv[1]
dg = lambda x: "sha256:" + hashlib.sha256(x.encode()).hexdigest()
svcs = ["auth", "catalog", "pricing"]
json.dump({"services": svcs, "service": "auth"}, open(os.path.join(run, "pr.json"), "w"))
for s in svcs:
    json.dump({"service": s, "digest": dg("cand-" + ("auth" if s == "auth" else "hot")), "baseline_digest": dg("base-" + s)},
              open(os.path.join(run, "candidate-%s.json" % s), "w"))
PY
cat > "$T/abbin/kubectl" << 'EOF2'
#!/usr/bin/env bash
# kubectl for ab.sh --all's tests: the A/B pool's nodes ($STUB_DIR/nodes.json), and deletes in rbd-ab (logged)
echo "kubectl $*" >> "$STUB_DIR/calls.log"
case "$*" in
  "get nodes -l rhobound.io/pool=ab -o json") cat "$STUB_DIR/nodes.json" ;;
  "-n rbd-ab delete "*) exit 0 ;;
  *) echo "abbin kubectl: unsupported: $*" >&2; exit 2 ;;
esac
EOF2
cat > "$T/child.sh" << 'EOF2'
#!/usr/bin/env bash
# a stand-in child of ab.sh --all: records its node, digests, folder, the inherited locks and token, and its interval
t0=$(date +%s.%N)
fd7=no; [[ -e /proc/$$/fd/7 && /proc/$$/fd/7 -ef $THOME/runs/$1/.lock ]] && fd7=yes
fd9=no; [[ -n ${RBD_LOCK_HELD:-} && -e /proc/$$/fd/9 ]] && fd9=yes
tok=no; [[ $(head -c 64 "$THOME/runs/$1/.ab-parent" 2>/dev/null) == "${AB_PARENT_TOKEN:-x}" ]] && tok=yes
sleep "${STUB_CHILD_SLEEP:-1}"
echo "$2 slot=${AB_SLOT:-} base=$3 cand=$4 dir=$5 mode=${6:-} fd7=$fd7 fd9=$fd9 token=$tok t0=$t0 t1=$(date +%s.%N)" >> "$STUB_DIR/children.log"
if [[ ${STUB_CHILD_FAIL:-} == "$2" ]]; then echo "{\"step\":\"ab\",\"ok\":false,\"service\":\"$2\"}"; exit 1; fi
echo "{\"step\":\"ab\",\"ok\":true,\"service\":\"$2\"}"
EOF2
chmod +x "$T/abbin/kubectl" "$T/child.sh"
nodes() { # nodes NAME[:NotReady] ...: the A/B pool as kubectl get nodes -o json
  python3 -I -c 'import json,sys
items=[{"metadata":{"name":a.split(":")[0]},"spec":{},"status":{"conditions":[{"type":"Ready","status":"False" if a.endswith(":NotReady") else "True"}]}} for a in sys.argv[1:]]
print(json.dumps({"items":items}))' "$@" > "$STUB_DIR/nodes.json"; }
aball() { # aball [VAR=value ...]: ab.sh RUN2 --all with the stand-in child; rc, out and err in $T
  : > "$STUB_DIR/children.log"
  env "$@" THOME="$THOME" AB_TEST_CHILD="$T/child.sh" AB_LOCK_WAIT=1 STUB_CHILD_SLEEP="${SLP:-1}" \
    bash "$CI/ab.sh" "$H2" --all ${ABSECS:+"$ABSECS"} > "$T/out" 2> "$T/err"; echo $?; }
overlap() { # overlap: the most children running at one moment (children.log intervals)
  python3 -I -c 'import re,sys
iv=[(float(re.search(r"t0=(\S+)",l).group(1)),float(re.search(r"t1=(\S+)",l).group(1))) for l in open(sys.argv[1]) if "t0=" in l]
ev=sorted([(a,1) for a,b in iv]+[(b,-1) for a,b in iv]); n=m=0
for _,d in ev: n+=d; m=max(m,n)
print(m)' "$STUB_DIR/children.log"; }
nodes rbd-d-ab1 rbd-d-ab2 rbd-d-ab3
rc=$(aball)
check "--all, 3 services, 3 A/B nodes: exit $rc, all three at once, each on its own node" bash -c "[ $rc -eq 0 ] &&
  [ \$(wc -l < '$STUB_DIR/children.log') -eq 3 ] && [ $(overlap) -eq 3 ] &&
  [ \$(grep -o 'slot=[^ ]*' '$STUB_DIR/children.log' | sort -u | wc -l) -eq 3 ]"
check "  each child: its candidate file's digests, folder ab-<svc>, the parent's run lock (fd 7), cluster lock (fd 9) and token" python3 -I -c '
import json,os,re,sys; log,run=sys.argv[1:3]; ok=True
for l in open(log):
    s=l.split()[0]; c=json.load(open(os.path.join(run,"candidate-%s.json"%s)))
    ok &= ("base=%s cand=%s dir=ab-%s mode= fd7=yes fd9=yes token=yes" % (c["baseline_digest"], c["digest"], s)) in l
sys.exit(not ok)' "$STUB_DIR/children.log" "$R2"
check "  ab-all.json: parallel 3, three services ok; last line step ab-all ok; the token file is gone" python3 -I -c '
import json,os,sys; a=json.load(open(sys.argv[1])); o=json.loads(open(sys.argv[2]).read().splitlines()[-1])
sys.exit(not (a["parallel"]==3 and [x["service"] for x in a["services"]]==["auth","catalog","pricing"] and all(x["exit"]==0 and x["ab"]["ok"] for x in a["services"])
  and o["step"]=="ab-all" and o["ok"] is True and o["parallel"]==3 and not os.path.exists(sys.argv[3])))' "$R2/ab-all.json" "$T/out" "$R2/.ab-parent"
check "  leftovers in rbd-ab deleted once, unscoped (rbd.ab=1), before the children" bash -c "
  [ \$(grep -c 'kubectl -n rbd-ab delete .* -l rbd.ab=1 ' '$STUB_DIR/calls.log') -ge 1 ]"
nodes rbd-d-ab1
rc=$(aball)
check "--all with one A/B node: exit $rc, one at a time, all on rbd-d-ab1 (as before parallel A/Bs)" bash -c "[ $rc -eq 0 ] && [ $(overlap) -eq 1 ] &&
  [ \$(grep -c 'slot=rbd-d-ab1 ' '$STUB_DIR/children.log') -eq 3 ]"
nodes rbd-d-ab1 rbd-d-ab2
rc=$(aball)
check "--all with two A/B nodes and three services: exit $rc, never more than two at once, the third queued" bash -c "[ $rc -eq 0 ] && [ $(overlap) -eq 2 ] &&
  [ \$(wc -l < '$STUB_DIR/children.log') -eq 3 ]"
nodes rbd-d-ab1 rbd-d-ab2:NotReady rbd-d-ab3
rc=$(aball)
check "--all skips a NotReady node (exit $rc): two at once on ab1 and ab3" bash -c "[ $rc -eq 0 ] && [ $(overlap) -eq 2 ] && ! grep -q 'slot=rbd-d-ab2' '$STUB_DIR/children.log'"
nodes rbd-d-ab1 rbd-d-ab2 rbd-d-ab3
rc=$(aball AB_PARALLEL=1)
check "--all with AB_PARALLEL=1: exit $rc, one at a time" bash -c "[ $rc -eq 0 ] && [ $(overlap) -eq 1 ]"
rc=$(aball STUB_CHILD_FAIL=catalog)
check "--all when catalog's A/B fails: exit $rc, the error names catalog, the others still ran" bash -c "[ $rc -eq 1 ] &&
  grep -q 'the A/B of catalog failed' '$T/err' && [ \$(wc -l < '$STUB_DIR/children.log') -eq 3 ] &&
  python3 -I -c 'import json,sys; a=json.load(open(sys.argv[1])); sys.exit(not [x[\"exit\"] for x in a[\"services\"]]==[0,1,0])' '$R2/ab-all.json'"
rm -f "$R2"/ab-all.json.old-*
rc=$(aball)
rc=$(ABSECS=600 aball)
check "--all 600 (the preview's longer A/B): exit $rc, every child gets SECONDS 600, all three at once" bash -c "[ $rc -eq 0 ] &&
  [ \$(grep -c 'mode=600 ' '$STUB_DIR/children.log') -eq 3 ] && [ $(overlap) -eq 3 ]"
check "  ab-all.json says longer_ab_s 600; the plain run's ab-all.json is kept beside it (the newest ab-all.json.old-*)" python3 -I -c '
import json,glob,sys; a=json.load(open(sys.argv[1])); old=sorted(glob.glob(sys.argv[2]))
sys.exit(not (a["longer_ab_s"]==600 and old and json.load(open(old[-1]))["longer_ab_s"] is None))' \
  "$R2/ab-all.json" "$R2/ab-all.json.old-*"
for x in 30 1801 ten; do
  rc=$(ABSECS=$x aball)
  check "--all $x is refused (60..1800; exit $rc, stage usage, no child)" bash -c "[ $rc -eq 1 ] && grep -q -- '--all SECONDS $x: want 60..1800' '$T/err' && [ ! -s '$STUB_DIR/children.log' ]"
done
nodes
rc=$(aball)
check "--all with no Ready A/B node: refused at stage slots (exit $rc), no child" bash -c "[ $rc -eq 1 ] &&
  [ \"\$(tail -n 1 '$T/out' | python3 -I -c 'import json,sys; print(json.load(sys.stdin)[\"stage\"])')\" = slots ] && [ ! -s '$STUB_DIR/children.log' ]"
nodes rbd-d-ab1 rbd-d-ab2 rbd-d-ab3
exec 6>> "$R2/.lock"; flock -n 6
rc=$(aball)
check "--all while another step holds runs/RUN/.lock: refused at stage run (exit $rc), no child" bash -c "[ $rc -eq 1 ] &&
  grep -q 'another step of runs/$H2 is running' '$T/err' && [ ! -s '$STUB_DIR/children.log' ]"
flock -u 6; exec 6>&-
echo '{}' > "$R2/predict.json"
rc=$(aball)
check "--all on a run that holds a prediction: refused at stage run (exit $rc; no re-roll)" bash -c "[ $rc -eq 1 ] && grep -q 'already holds a prediction' '$T/err'"
rm -f "$R2/predict.json"
# the real child's checks: the parent's token and its run lock (each refused before any kubectl call)
: > "$STUB_DIR/calls.log"
printf '%s' good-token > "$R2/.ab-parent"
rc=$(AB_PARENT_TOKEN=bad-token AB_SLOT=rbd-d-ab1 runab "$H2" auth "$D" "$D" ab-auth)
check "a child with a token that is not runs/RUN/.ab-parent's is refused at stage run (exit $rc)" abref "$rc" run "AB_PARENT_TOKEN does not match"
rc=$(AB_PARENT_TOKEN=good-token AB_SLOT=rbd-d-ab1 runab "$H2" auth "$D" "$D" ab-auth)
check "a child without its parent's runs/RUN/.lock on fd 7 is refused at stage run (exit $rc)" abref "$rc" run "without its parent.s runs/$H2/.lock"
rc=$(exec 7>> "$R2/.lock"; AB_PARENT_TOKEN=good-token runab "$H2" auth "$D" "$D" ab-auth)
check "a child without its A/B node (AB_SLOT) is refused at stage run (exit $rc)" abref "$rc" run "needs its A/B node"
rc=$(exec 7>> "$R2/.lock"; AB_PARENT_TOKEN=good-token AB_SLOT=rbd-d-ab1 runab "$H2" auth "$D" "$D" ab-auth)
check "a child with the token and the run lock gets past stage run (exit $rc, stage $(tail -n 1 "$T/out" | python3 -I -c 'import json,sys; print(json.load(sys.stdin)["stage"])'))" \
  bash -c "[ \"\$(tail -n 1 '$T/out' | python3 -I -c 'import json,sys; print(json.load(sys.stdin)[\"stage\"])')\" != run ]"
rm -f "$R2/.ab-parent"
done_summary
