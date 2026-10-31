#!/usr/bin/env bash
# t_agent_take_bench.sh: orch/agent_take.sh takes the bench funnel's pick (SPEC2 S6) in a copy of the kit: CHANGE cN-bench and a
# rhobound-change.json v2 {schema v2, services [the manifest's service, + up to 2 more of spec.json], summary, base?}; it still
# refuses a v2 whose first service is not the manifest's, an unknown service, a fourth service, an unknown key, and a CHANGE
# that is neither cN-model nor cN-bench (all before any compile). One compile (Go through capped.sh, offline).
set -uo pipefail
# shellcheck source=tools1/tests/bench/s8lib.sh
. "$(dirname "$0")/s8lib.sh"
echo "== agent_take.sh: cN-bench, rhobound-change.json v2"
mkenv8 take-bench
K=$T/kit
mkdir -p "$K/orch" "$K/changes" "$K/state"
cp "$KIT/orch/agent_take.sh" "$K/orch/"
cp -r "$KIT/tools1/tests/ci/fixtures/repo-day1" "$K/repo"
printf '%040d\n' 7 > "$K/state/main.sha"
mkdir -p "$K/tools1/kshop"; cp "$KIT/tools1/kshop/bases.json" "$K/tools1/kshop/"   # agent_take checks a v2 base against it
O=$T/out
F=kshop/app/internal/work/lib_v11.go
mkdir -p "$O/files/$(dirname "$F")"
sed 's/^package work$/package work\n\n\/\/ bench: a comment-only pick/' "$K/repo/$F" > "$O/files/$F"
python3 -I - "$O" "$F" << 'PY'
import hashlib, json, sys
o, f = sys.argv[1], sys.argv[2]
b = open(o + "/files/" + f, "rb").read()
summ = "bench pick: a comment"
json.dump({"ok": True}, open(o + "/result.json", "w"))
json.dump({"schema": "rbd.agent-change/v1", "provider": "meta", "model": "muse-spark-1.3", "served_by": ["muse-spark-1.3"],
           "base_sha": "%040d" % 7, "service": "auth", "title": "bench pick", "summary": summ,
           "files": [{"path": f, "sha256": hashlib.sha256(b).hexdigest(), "bytes": len(b), "new": False}], "turns": 3,
           "mcp_calls": []}, open(o + "/manifest.json", "w"))
json.dump({"schema": "rbd.change-request/v2", "services": ["auth", "payments"], "summary": summ, "base": "go127"},
          open(o + "/rhobound-change.json", "w"))
PY
rq() { python3 -I -c 'import json,sys; d=json.load(open(sys.argv[1])); d.update(json.loads(sys.argv[2])); [d.pop(k) for k in sys.argv[3:]]; json.dump(d, open(sys.argv[1], "w"))' "$O/rhobound-change.json" "$@"; }
take() { RBD_AGENT_LOCAL=$O bash "$K/orch/agent_take.sh" "$@" > "$T/take.out" 2> "$T/take.err"; echo $?; }
cp "$O/rhobound-change.json" "$T/good.json"
for bad in '{"services": ["payments", "auth"]}' '{"services": ["auth", "nosuch"]}' '{"services": ["auth", "payments", "pricing", "catalog"]}' \
  '{"dockerfile": "FROM x"}' '{"base": "../x"}' '{"services": ["auth", "auth"]}'; do
  cp "$T/good.json" "$O/rhobound-change.json"
  rq "$bad"
  rc=$(take r1 c7-bench)
  check "v2 refused before any compile: $bad (exit $rc)" bash -c "[ $rc -eq 1 ] && grep -q 'rhobound-change.json' '$T/take.err' && [ ! -e '$K/changes/c7-bench' ]"
done
cp "$T/good.json" "$O/rhobound-change.json"
rc=$(take r1 c7-other)
check "CHANGE c7-other: refused (exit $rc)" bash -c "[ $rc -eq 1 ] && grep -q 'cN-model or cN-bench' '$T/take.err'"
rc=$(take r1 c7-bench)
check "c7-bench with a v2 request: taken, compiled (exit $rc)" test "$rc" -eq 0
check "...changes/c7-bench: change.patch, title.txt, manifest.json, the v2 request as written" bash -c "
  [ -s '$K/changes/c7-bench/change.patch' ] && [ \"\$(cat '$K/changes/c7-bench/title.txt')\" = 'bench pick' ] &&
  cmp -s '$K/changes/c7-bench/rhobound-change.json' '$T/good.json' && [ -s '$K/changes/c7-bench/manifest.json' ]"
rq '{}' base
rc=$(take r2 c8-bench)
check "a v2 request without base: taken (exit $rc)" test "$rc" -eq 0
done_summary
