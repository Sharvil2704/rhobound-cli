#!/usr/bin/env bash
# t_bench_driver.sh: orch/bench.sh end to end with stand-ins: rbd-tools1 is a folder (fakebin/rbd.sh: the funnel's funnel.json,
# baseline.json before and after the deploy, the gate's run folder), agent_take.sh and make_prs.sh are stubs (make_prs adds the
# PR to the fake GitHub), and the REAL orch/automerge.sh and tools1/bench/prodcheck.py run against the fake GitHub and the ci
# fixture fit; then verify/bench_score.py reads what the driver left. Also: nothing selected, a failed or slow funnel and the
# resume, a block verdict, the kill switch, a compile failure, a funnel that selects a stranger, a task the kit does not ship.
set -uo pipefail
# shellcheck source=tools1/tests/bench/s8lib.sh
. "$(dirname "$0")/s8lib.sh"
B=$KIT/orch/bench.sh
FXS=$H8/fixtures/score
HD=7777777777777777777777777777777777777777
echo "== bench.sh (stub rbd.sh, agent_take.sh, make_prs.sh; real automerge.sh, prodcheck.py)"

setup() { # setup NAME: a fresh env, the fake rbd-tools1, the stubs
  mkenv8 "$1"
  export FAKE_RBD_HOME=$T/tools1 BENCH_CHANGES=$T/changes BENCH_TASKS=$T/tasks RBD_SH=$H8/fakebin/rbd.sh
  export BENCH_AGENT_TAKE=$T/bin/agent_take.sh BENCH_MAKE_PRS=$T/bin/make_prs.sh BENCH_POLL=0 BENCH_GATE_WAIT=60
  export STUB_FUNNEL=$FXS/state/T1-rank/funnel.json STUB_VERDICT=pass
  unset STUB_BG_RC STUB_TAIL_RUNNING STUB_TAKE_RC BENCH_WAIT
  local F=$FAKE_RBD_HOME
  mkdir -p "$F/captures/prod-0/fit" "$F/captures/prod-1/fit" "$F/runs/$HD/ab-catalog/raw-a" "$BENCH_CHANGES/c6-model" "$T/tasks"
  cp -R "$FXS/tasks/T1-rank" "$FXS/tasks/T3-fold" "$T/tasks/"
  cp "$KIT/tools1/tests/ci/fixtures/fit.json" "$F/captures/prod-0/fit/fit.json"
  python3 -I - "$F" << 'PY'
import json, sys
F = sys.argv[1]
fit = json.load(open(F + "/captures/prod-0/fit/fit.json"))
for s in fit["inference"]["stats"]:
    if s["name"] == "catalog":
        s["own_mean_ms"] -= 4.5; s["observed_server_ms"] -= 4.5
    if s["name"] == "storefront":
        s["observed_server_ms"] -= 4.2
json.dump(fit, open(F + "/captures/prod-1/fit/fit.json", "w"))
for name, cap in (("baseline.json", "prod-0"), ("baseline.after.json", "prod-1")):
    json.dump({"schema": "rbd.baseline/v1", "services": {}, "capture": cap,
               "fit": {"dir": "/var/lib/rbd/captures/%s/fit" % cap, "digest": "sha256:" + cap * 8}}, open(F + "/" + name, "w"))
PY
  cp -R "$FXS/state/runs/1111111111111111111111111111111111111111/." "$F/runs/$HD/"
  head -c 300000 /dev/zero > "$F/runs/$HD/ab-catalog/raw-a/spans.jsonl"   # the A/B's raw traces: never fetched
  printf '%040d\n' 5 > "$RBD_STATE/main.sha"
  # shellcheck disable=SC2119  # no PR yet: an empty fake GitHub
  world
  cat > "$T/bin/agent_take.sh" << 'EOF'
#!/usr/bin/env bash
echo "agent_take $*" >> "$STUB_DIR/take.log"
[[ ${STUB_TAKE_RC:-0} == 0 ]] || exit "$STUB_TAKE_RC"
mkdir -p "$BENCH_CHANGES/$2"
printf '{"schema": "rbd.change-request/v2", "services": ["catalog"], "summary": "inverted index"}\n' > "$BENCH_CHANGES/$2/rhobound-change.json"
echo "inverted index for Rank" > "$BENCH_CHANGES/$2/title.txt"
EOF
  cat > "$T/bin/make_prs.sh" << EOF
#!/usr/bin/env bash
echo "make_prs DRYRUN=\${DRYRUN:-0} \$*" >> "\$STUB_DIR/mkpr.log"
[[ \${DRYRUN:-0} == 1 ]] && exit 0
python3 -I "$H8/fakegh.py" __add "7:branch=rbd/\$1,head=$HD,verdict=\$STUB_VERDICT"
EOF
  chmod +x "$T/bin/agent_take.sh" "$T/bin/make_prs.sh"
}
bn() { bash "$B" "$@" > "$T/b.out" 2> "$T/b.err"; echo $?; }
TD() { echo "$RBD_STATE/bench/T1-rank"; }

setup drv-pass
rc=$(bn T1-rank)
check "pass flow: exit 0 (rc $rc; $(tail -n 1 "$T/b.err" | cut -c1-120))" test "$rc" -eq 0
check "...steps 1..10 recorded" test "$(grep -c ' step [0-9]* done' "$(TD)/steps.log")" -eq 10
check "...run.json: RUN b-T1-rank-<ddHHMM>, CHANGE c7-bench (next after c6-model)" bash -c "[[ \$(jq1() { :; }; python3 -I -c 'import json,sys; d=json.load(open(sys.argv[1])); print(d[\"run\"], d[\"change\"])' '$(TD)/run.json') =~ ^b-T1-rank-[0-9]{6}\ c7-bench$ ]]"
RUN=$(jq1 "$(TD)/run.json" run)
check "...the funnel started detached on rbd-tools1 as run_task.py TASK_DIR OUT_DIR --policy main's --take-out agent/RUN" \
  grep -qx "rbd.sh bg $RUN python3 -I /opt/rbd/bench/run_task.py /opt/rbd/bench/tasks/T1-rank /var/lib/rbd/bench/$RUN --policy /var/lib/rbd/src/main/policy/gate.json --take-out /var/lib/rbd/agent/$RUN" "$STUB_DIR/rbd.log"
check "...baseline-before.json from rbd-tools1 (prod-0)" test "$(jq1 "$(TD)/baseline-before.json" capture)" = prod-0
check "...funnel.json fetched (selected m2)" test "$(jq1 "$(TD)/funnel.json" selected)" = m2
check "...agent_take.sh RUN c7-bench, then make_prs.sh c7-bench" bash -c "grep -qx 'agent_take $RUN c7-bench' '$STUB_DIR/take.log' && grep -qx 'make_prs DRYRUN=0 c7-bench' '$STUB_DIR/mkpr.log'"
check "...pr.json: PR 7 on rbd/c7-bench at the head, the run and the approach" test \
  "$(jq1 "$(TD)/pr.json" pr) $(jq1 "$(TD)/pr.json" branch) $(jq1 "$(TD)/pr.json" head) $(jq1 "$(TD)/pr.json" approach)" = "7 rbd/c7-bench $HD m2"
check "...automerge merged it at the head and the deploy is in the timeline" bash -c "grep -q '^gh pr merge 7 .*--match-head-commit $HD' '$STUB_DIR/calls.log' &&
  [ '$(jq1 "$(TD)/timeline.json" deploy_ok)' = true ]"
G=$RBD_STATE/bench/runs/$HD
check "...the gate's artifacts fetched: predict.json, prediction.json, gate/gate.json, ab-catalog/ab.json" bash -c \
  "[ -s '$G/predict.json' ] && [ -s '$G/prediction.json' ] && [ -s '$G/gate/gate.json' ] && [ -s '$G/ab-catalog/ab.json' ]"
check "...never the A/B's raw traces" test ! -e "$G/ab-catalog/raw-a"
check "...prodcheck.json: prod-0 -> prod-1, catalog changed, storefront -4.2 ms in the predicted band" bash -c "
  [ \"\$(python3 -I -c 'import json,sys; d=json.load(open(sys.argv[1])); e={x[\"name\"]: x for x in d[\"entries\"]}
print(d[\"services_changed\"], round(e[\"storefront\"][\"delta_ms\"], 3), e[\"storefront\"][\"in_band\"])' '$(TD)/prodcheck.json')\" = \"['catalog'] -4.2 True\" ]"
check "...prodcheck ran with the before/after fits and the gate's prediction (on rbd-tools1)" grep -q \
  "^rbd.sh run python3 -I /opt/rbd/bench/prodcheck.py --previous /var/lib/rbd/captures/prod-0/fit/fit.json --current /var/lib/rbd/captures/prod-1/fit/fit.json --services catalog --prediction /var/lib/rbd/runs/$HD/prediction.json" "$STUB_DIR/rbd.log"
check "...this box ran no ssh, aws, docker or kubectl" test ! -s "$STUB_DIR/forbidden.log"
python3 -I "$KIT/verify/bench_score.py" --state "$RBD_STATE/bench" --tasks "$T/tasks" --truth "$T/none" --aa "$T/none" \
  --out-md "$T/score.md" --out-json "$T/score.json" > /dev/null 2>&1
src=$?
check "...bench_score.py reads what the driver left: exit 0, T1's chain reaches production (rc $src)" bash -c "[ $src -eq 0 ] &&
  python3 -I -c 'import json,sys; t=json.load(open(sys.argv[1]))[\"tasks\"][0]; sys.exit(0 if t[\"chain\"][\"production\"] and t[\"time_to_production\"][\"verified\"] else 1)' '$T/score.json'"
rc=$(bn T1-rank)
check "...a second start of the same task refuses (run.json exists; rc $rc)" bash -c "[ $rc -eq 1 ] && grep -q 'already started' '$T/b.err'"

setup drv-none
STUB_FUNNEL=$FXS/state/T3-fold/funnel.json
rc=$(bn T3-fold)
check "every approach cut (selected null): exit 3 after step 5, no agent_take, no PR (rc $rc)" bash -c "[ $rc -eq 3 ] &&
  [ ! -e '$STUB_DIR/take.log' ] && [ ! -e '$STUB_DIR/mkpr.log' ] && [ -s '$RBD_STATE/bench/T3-fold/funnel.json' ]"

setup drv-fail
rc=$(STUB_BG_RC=1 bn T1-rank)
check "the funnel exits 1: bench.sh exits 1 at step 4 (rc $rc)" bash -c "[ $rc -eq 1 ] && grep -q 'the funnel ended with exit 1' '$T/b.err'"

setup drv-slow
rc=$(STUB_TAIL_RUNNING=5 BENCH_WAIT=0 bn T1-rank)
check "the funnel still runs at BENCH_WAIT: exit 4 (rc $rc)" bash -c "[ $rc -eq 4 ] && [ ! -e '$(TD)/funnel.json' ]"
rc=$(bn T1-rank --from 4)
check "...--from 4 resumes with the same RUN and finishes (rc $rc)" bash -c "[ $rc -eq 0 ] && [ \$(grep -c '^rbd.sh bg ' '$STUB_DIR/rbd.log') -eq 1 ]"

setup drv-block
rc=$(STUB_VERDICT=block bn T1-rank)
check "a block verdict: exit 3, not merged, recorded; the gate's artifacts still fetched; no prodcheck (rc $rc)" bash -c "[ $rc -eq 3 ] &&
  [ '$(jq1 "$(TD)/timeline.json" verdict)' = block ] && ! grep -q '^gh pr merge' '$STUB_DIR/calls.log' &&
  [ -s '$RBD_STATE/bench/runs/$HD/gate/gate.json' ] && [ ! -e '$(TD)/prodcheck.json' ]"

setup drv-stop
echo stop > "$RBD_STATE/automerge.stop"
rc=$(bn T1-rank)
check "kill switch: exit 5 before anything runs (rc $rc)" bash -c "[ $rc -eq 5 ] && [ ! -s '$STUB_DIR/rbd.log' ]"

setup drv-take
rc=$(STUB_TAKE_RC=3 bn T1-rank)
check "agent_take.sh says it does not compile (3): exit 1, no PR (rc $rc)" bash -c "[ $rc -eq 1 ] && [ ! -e '$STUB_DIR/mkpr.log' ]"

setup drv-stranger
python3 -I -c 'import json,sys; d=json.load(open(sys.argv[1])); d["selected"]="../../etc"; json.dump(d,open(sys.argv[2],"w"))' "$STUB_FUNNEL" "$T/f.json"
rc=$(STUB_FUNNEL=$T/f.json bn T1-rank)
check "a funnel that selects no approach of its own is refused (rc $rc)" bash -c "[ $rc -eq 1 ] && grep -q 'not one of its approaches' '$T/b.err'"

setup drv-unknown
rc=$(bn T9-nope)
check "a task the kit does not ship: exit 1 (rc $rc)" bash -c "[ $rc -eq 1 ] && grep -q 'tasks ship with the kit' '$T/b.err'"
rc=$(bn 'x;y')
check "a bad task name: usage, exit 2 (rc $rc)" test "$rc" -eq 2

setup drv-dry
rc=$(DRYRUN=1 bn T1-rank)
check "DRYRUN=1: make_prs.sh runs dry, stop there (no PR, no merge; rc $rc)" bash -c "[ $rc -eq 0 ] && grep -qx 'make_prs DRYRUN=1 c7-bench' '$STUB_DIR/mkpr.log' &&
  [ ! -e '$(TD)/pr.json' ] && ! grep -q '^gh pr merge' '$STUB_DIR/calls.log'"

# the remote commands of steps 9 and 10 through the REAL orch/rbd.sh's quoting (rbd_q, as_rbd): RBD_DRY=1 prints the
# remote command line, which runs here with /var/lib/rbd and /opt/rbd mapped (as test_orch_dry.sh does for the RUNBOOK)
setup drv-real
printf '{"nodes": {"rbd-tools1": {"state": "running", "public": "203.0.113.30", "private": "10.82.1.30", "role": "tools"}}}\n' > "$RBD_STATE/seed.json"
echo "Host rbd-tools1" > "$T/sshc"
cat > "$T/bin/rbd-real.sh" << EOF
#!/usr/bin/env bash
# run (except 'cat baseline.json': the fake serves the after-deploy one) through the real rbd.sh, RBD_DRY=1; the rest: the fake
if [[ \$1 == run && "\$*" != "run cat baseline.json" ]]; then
  echo "rbd.sh \$* (real quoting)" >> "\$STUB_DIR/rbd.log"
  line=\$(RBD_DRY=1 RBD_SSHC="$T/sshc" bash "$KIT/orch/rbd.sh" "\$@" 2>&1 > /dev/null | grep -m 1 'DRY ssh rbd-tools1: ')
  cmd=\${line#*DRY ssh rbd-tools1: sudo -u rbd -H }
  cmd=\${cmd/. \/opt\/rbd\/lib\/rbd-env.sh; /}
  cmd=\${cmd//\/var\/lib\/rbd/\$FAKE_RBD_HOME}
  cmd=\${cmd//\/opt\/rbd/$KIT/tools1}
  echo "\$cmd" >> "\$STUB_DIR/real.log"
  exec bash -c "\$cmd"
fi
exec bash "$H8/fakebin/rbd.sh" "\$@"
EOF
chmod +x "$T/bin/rbd-real.sh"
rc=$(RBD_SH=$T/bin/rbd-real.sh bn T1-rank)
check "real rbd.sh quoting: the pass flow ends 0 (rc $rc)" test "$rc" -eq 0
check "...step 9's listing ran as the real rbd.sh sends it (bash -c 'cd \"runs/\$1\" ...' _ HEAD): all four artifacts fetched" bash -c "
  grep -qF 'predict.json\\ prediction.json\\ gate' '$STUB_DIR/real.log' && [ -s '$RBD_STATE/bench/runs/$HD/predict.json' ] &&
  [ -s '$RBD_STATE/bench/runs/$HD/prediction.json' ] && [ -s '$RBD_STATE/bench/runs/$HD/gate/gate.json' ] && [ -s '$RBD_STATE/bench/runs/$HD/ab-catalog/ab.json' ]"
check "...step 10's prodcheck.py line ran as sent: prodcheck.json with catalog changed" bash -c "grep -q 'prodcheck.py' '$STUB_DIR/real.log' &&
  [ \"\$(python3 -I -c 'import json,sys; print(json.load(open(sys.argv[1]))[\"services_changed\"])' '$(TD)/prodcheck.json')\" = \"['catalog']\" ]"
check "...no WARNING about an empty run listing" bash -c "! grep -q 'listed nothing' '$T/b.err'"
check "...and still no ssh (RBD_DRY=1 prints, never connects)" test ! -s "$STUB_DIR/forbidden.log"
done_summary
