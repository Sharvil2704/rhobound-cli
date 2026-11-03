#!/usr/bin/env bash
# variance_guard.sh HEAD   the "relax the variance rule for improvements" decision (2026-10-30), at merge time. The pinned CLI's
# policy can only drop profile.variance_changed from doubts_that_hold for EVERY change (repo/policy/gate.json does), so a
# variance-changing pass reaches auto-merge whatever its direction; this guard lets orch/automerge.sh merge it only when it
# is an improvement at every measured service: for every A/B of the run (runs/HEAD/ab*/, each ab.json ok with its service),
# own_ms.delta + 2 se < 0 in its record. A run without a profile.variance_changed finding is allowed as before.
# Reads rbd-tools1 through orch/rbd.sh (read-only). Prints one JSON line {"allow", "variance_changed", "services", "reason"}.
# Exit 0 allow; 1 hold (left open for a person); 2 cannot read (automerge treats it as hold).
set -euo pipefail
DEMO=$(cd "$(dirname "$0")/.." && pwd)
[[ $# -eq 1 && $1 =~ ^[0-9a-f]{40}$ ]] || { echo "usage: variance_guard.sh HEAD (40 hex)" >&2; exit 2; }
out=$(bash "$DEMO/orch/rbd.sh" run python3 -I -c '
import glob, json, os, sys
run = os.path.join(os.environ.get("RBD_HOME", "/var/lib/rbd"), "runs", sys.argv[1])
rows, changed = [], []
for d in sorted(glob.glob(os.path.join(run, "ab*"))):
    if not os.path.isdir(d) or ".old-" in d:
        continue
    try:
        ab = json.load(open(os.path.join(d, "ab.json")))
        rec = json.load(open(os.path.join(d, "record", "ab-record.json")))
    except (OSError, ValueError):
        continue
    if ab.get("ok") is not True:
        continue
    svc = ab.get("service")
    own = next((s.get("own_ms") for s in rec.get("services", []) if s.get("service") == svc), None)
    if not own:
        continue
    vc = any(f.get("code") == "profile.variance_changed" for f in rec.get("findings", []))
    changed += [svc] if vc else []
    rows.append({"service": svc, "delta": own["delta"], "se": own["se"], "upper": own["delta"] + 2 * own["se"], "variance_changed": vc})
if not rows:
    print(json.dumps({"allow": False, "reason": "no readable A/B record under runs/" + sys.argv[1]})); sys.exit(2)
if not changed:
    print(json.dumps({"allow": True, "variance_changed": [], "services": rows, "reason": "no variance change"})); sys.exit(0)
worse = [r["service"] for r in rows if not r["upper"] < 0]
if worse:
    print(json.dumps({"allow": False, "variance_changed": changed, "services": rows,
                      "reason": "variance changed and not an improvement at every service (delta + 2 se >= 0: %s)" % ", ".join(worse)}))
    sys.exit(1)
print(json.dumps({"allow": True, "variance_changed": changed, "services": rows,
                  "reason": "variance changed, an improvement at every service (delta + 2 se < 0)"}))
' "$1" 2> /dev/null) || rc=$?
line=$(tail -n 1 <<< "${out:-}")
[[ -n $line ]] || { echo '{"allow": false, "reason": "rbd-tools1 unreadable"}'; exit 2; }
echo "$line"
exit "${rc:-0}"
