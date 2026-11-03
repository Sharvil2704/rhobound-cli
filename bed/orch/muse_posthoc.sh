#!/usr/bin/env bash
# muse_posthoc.sh (as run from state/logs/muse-posthoc.sh on 2026-11-03): POST-HOC (not in DECLARE.md, not in the sealed scoring) truth brackets of the two candidates the
# rhobound gate held as inconclusive (doubt_holds:profile.variance_changed): T5 R i2 (PR 24) and T4 R i1 (PR 26).
# Same protocol as every arm's deploy (verify/truthx.sh: B0 300 s, the candidate, warm-up, C 300 s, rollback), started
# only after the last arm's driver has exited. -> state/muse-posthoc/NAME/{b0,c}.load.json, regress.json, truth-brief.json
# shellcheck disable=SC2009  # ps, not pgrep -f: pgrep matched its own caller (2026-11-02)
cd "$(dirname "$(readlink -f "$0")")/.." || exit 1
while ps -eo args | grep -q '^bash orch/muse_[a]rm.sh'; do sleep 20; done
[ -e state/muse/STOP ] && { echo "[posthoc] kill switch"; exit 1; }
end=$(date -u +%H%M); if [ "$end" -ge 0445 ] && [ "$end" -lt 1200 ]; then echo "[posthoc] after 04:45Z: too late"; exit 1; fi
for spec in "px-t5-r-i2:T5-R/iter-02" "px-t4-r-i1:T4-R/iter-01"; do
  n=${spec%%:*} d=state/muse/${spec#*:}
  dig=$(python3 -I -c 'import json,sys,re; g=json.load(open(sys.argv[1])); d=g["candidate_digest"]; assert re.fullmatch(r"sha256:[0-9a-f]{64}", d); print(d)' "$d/gate/gate-summary.json") || { echo "[posthoc] $n: no candidate digest"; exit 1; }
  now=$(date -u +%H%M); if [ "$now" -ge 0445 ] && [ "$now" -lt 1200 ]; then echo "[posthoc] $n: after 04:45Z, not started"; exit 1; fi
  echo "[posthoc $(date -u +%H:%M:%S)] $n: catalog=$dig"
  bash orch/rbd.sh bg "muse-$n" env RBD_LOCK_WAIT=1800 /opt/rbd/verify/truthx.sh "$n" "catalog=$dig" > /dev/null || { echo "[posthoc] $n: cannot start"; exit 1; }
  t0=$(date +%s); rc=
  while :; do
    line=$(bash orch/rbd.sh tail "muse-$n" 3 2> /dev/null) || line=""; line=${line%%$'\n'*}
    if [[ $line =~ ^==\ .*:\ done,\ exit\ ([0-9]+)$ ]]; then rc=${BASH_REMATCH[1]}; break; fi
    (( $(date +%s) - t0 < 3000 )) || { echo "[posthoc] $n: STILL RUNNING after 3000 s: check production by hand"; exit 4; }
    sleep 20
  done
  o=state/muse-posthoc/$n; mkdir -p "$o"
  bash orch/rbd.sh tail "muse-$n" 200 > "$o/truthx.log" 2>&1 || true
  sed -i -E 's/[0-9]{12}\.dkr\.ecr/<n12>.dkr.ecr/g' "$o/truthx.log"
  for f in b0.load.json c.load.json; do
    bash orch/rbd.sh run bash -c 'f=$1; [ -f "$f" ] && [ ! -L "$f" ] || exit 3; head -c 4000000 "$f"' x "/var/lib/rbd/verify/truthx/$n/$f" > "$o/$f" 2> /dev/null || true
  done
  bash orch/rbd.sh run bash -c 'f=$1; [ -f "$f" ] && [ ! -L "$f" ] || exit 3; head -c 1000000 "$f"' x "/var/lib/rbd/verify/truthx/$n/truth.json" 2> /dev/null |
    python3 -I -c 'import json,sys; t=json.load(sys.stdin); print(json.dumps({k: t.get(k) for k in ("status","change","services","cand_digests","times","window_s")}, indent=1))' > "$o/truth-brief.json" || true
  echo "[posthoc $(date -u +%H:%M:%S)] $n: truthx exit $rc, status $(python3 -I -c 'import json,sys; print(json.load(open(sys.argv[1])).get("status"))' "$o/truth-brief.json" 2>/dev/null)"
  [ "$rc" = 4 ] && { echo "[posthoc] $n: ROLLBACK FAILED: restore production by hand"; exit 4; }
  python3 -I verify/regress.py --b0 "$o/b0.load.json" --c "$o/c.load.json" --policy repo/policy/gate.json --out "$o/regress.json" > /dev/null 2> "$o/regress.err"
  python3 -I -c 'import json,sys; r=json.load(open(sys.argv[1])); print("[posthoc]", sys.argv[2], "production_ok", r.get("production_ok"), "worst", json.dumps(r.get("worst")), "|", " ".join("%s %+.2f" % (e["entry"], e["change_ms"]) for e in r["entries"]))' "$o/regress.json" "$n" || true
done
echo "[posthoc $(date -u +%H:%M:%S)] done"
