#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
#
# bench_sweep.sh: what-if throughput. rhobound has no sweep command: the Go way to evaluate a grid is one
# `rhobound model TOPOLOGY --rps R [--patch P] [--plain] --json` per point. This times
#   * rbfast sweep over the grid at 1 and 8 threads (median of 3 runs), and
#   * the same points through the Go binary, one process each, run one at a time and 8 at a time (a Python thread
#     pool), one run each (they take long), checking that every Go result equals rbfast's line;
#   * the same evaluations inside one Go process (RBFAST_GO_SWEEP, optional: a Go driver made for the comparison,
#     not published, that calls model.AnalyticWith and ChangePatchWith in a loop for a manifest of loads and
#     changes, GOMAXPROCS=1, median of 3 repetitions in the process; it also evaluates the changes at the refused
#     loads, which rbfast skips), the like-for-like comparison of per-call speed;
# and `model` / `predict` single calls (median of 10 processes) for the per-call cost.
#
#   RBFAST_GO=rhobound scripts/bench_sweep.sh OUTDIR [TOPOLOGY.json] [CAPTURE]
# Defaults: the topology the oracle inferred for its largest capture (test-bed run 3; needs RBFAST_ORACLE), the
# repository's testdata/capture-chain; loads 50:150:2 (51), the 21 changes of RBFAST_SWEEP_GRID (default: the
# test bed's services pricing and recommend), both models (2244 lines).
# Environment: RBFAST_GO (required), RBFAST_BIN, RBFAST_TIMER, RBFAST_WRAP as in bench.sh; RBFAST_GO_SWEEP.
set -uo pipefail
WS=$(cd "$(dirname "$0")/.." && pwd)
OUT=${1:?usage: bench_sweep.sh OUTDIR [TOPOLOGY.json] [CAPTURE]}
largest() { # the infer.json of the oracle capture with the most spans
  python3 -I - "${RBFAST_ORACLE:?give TOPOLOGY.json or set RBFAST_ORACLE}" <<'PY'
import json, os, sys
o = sys.argv[1]
def spans(d):
    try:
        return json.load(open(os.path.join(o, d, "counters.json")))["spans"]
    except (OSError, ValueError, KeyError):
        return 0
ds = [d for d in os.listdir(o) if os.path.isfile(os.path.join(o, d, "infer.json"))]
print(os.path.join(o, max(ds, key=spans), "infer.json"))
PY
}
TOPO=${2:-$(largest)}
CAP=${3:-$WS/../testdata/capture-chain}
[ -f "$TOPO" ] || { echo "bench_sweep.sh: no topology file ($TOPO)" >&2; exit 2; }
mkdir -p "$OUT"
read -r -a WRAP <<< "${RBFAST_WRAP:-}"
read -r -a RUNSTAT <<< "${RBFAST_TIMER:-python3 -I $WS/scripts/timer.py}"
GO=${RBFAST_GO:?set RBFAST_GO to the rhobound binary}
RB=${RBFAST_BIN:-${CARGO_TARGET_DIR:-$WS/target}/release/rbfast}
GOSWEEP=${RBFAST_GO_SWEEP:-}
wrap() { ${WRAP[@]+"${WRAP[@]}"} "$@"; }
log() { echo "$(date -Is) $*" | tee -a "$OUT/bench.log"; }
HZ=$(getconf CLK_TCK)
busy() { # average busy cores over $1 seconds
  read -r _ a1 a2 a3 _ _ a6 a7 a8 _ < /proc/stat; sleep "$1"; read -r _ b1 b2 b3 _ _ b6 b7 b8 _ < /proc/stat
  awk -v b=$(( (b1+b2+b3+b6+b7+b8) - (a1+a2+a3+a6+a7+a8) )) -v hz=$HZ -v s=$1 'BEGIN{printf "%.2f\n", b/hz/s}'
}
# the quiet-machine rule of bench.sh: 1-minute load < 1.5, < 0.4 busy cores; up to 45 min
deadline=$(( $(date +%s) + 2700 ))
while :; do
  l=$(cut -d' ' -f1 /proc/loadavg); b=$(busy 3)
  log "WAIT load1=$l busy3s=$b"
  if awk -v l="$l" -v b="$b" 'BEGIN{exit !(l<1.5 && b<0.4)}'; then log "QUIET"; break; fi
  if [ "$(date +%s)" -ge "$deadline" ]; then log "DEADLINE: still busy after 45 minutes, running anyway (NOISY)"; break; fi
  sleep 120
done
log "STATE load=$(cut -d' ' -f1-3 /proc/loadavg)"
GRID=${RBFAST_SWEEP_GRID:-'pricing=0:9:1%;recommend=+0.5ms|+1ms|+2ms|+4ms|+8ms;pricing=+5%,recommend=+1ms|+2ms|+4ms|-1ms|-2ms|-4ms'}
ARGS=(sweep "$TOPO" --rps 50:150:2 --patch-grid "$GRID" --both)
"$RB" "${ARGS[@]}" > "$OUT/sweep.jsonl"
log "GRID $(wc -l < "$OUT/sweep.jsonl") lines: ${ARGS[*]}"
for t in 1 8; do
  wrap "${RUNSTAT[@]}" -n 3 -label "rbfast sweep threads=$t" -- "$RB" "${ARGS[@]}" --threads $t | tee -a "$OUT/bench.log"
done
# the same points through the Go binary, one process per point (a Python thread pool starts them), checked
# against rbfast's lines
for p in 1 8; do
  wrap python3 -I - "$OUT/sweep.jsonl" "$TOPO" "$GO" $p <<'PY' | tee -a "$OUT/bench.log"
import concurrent.futures as cf, json, subprocess, sys, time
lines = [json.loads(x) for x in open(sys.argv[1])]
topo, go, par = sys.argv[2], sys.argv[3], int(sys.argv[4])
def args(d):
    a = [go, "model", topo, "--rps", repr(d["rps"]), "--json"]
    if d["model"] == "basic":
        a.append("--plain")
    if d["patch"] is not None:
        a += ["--patch", d["patch"]]
    return a
def one(d):
    return d, subprocess.run(args(d), capture_output=True)
t0 = time.time()
with cf.ThreadPoolExecutor(par) as ex:
    res = list(ex.map(one, lines))
t1 = time.time()
bad = 0
for d, p in res:
    if d["status"] != "ok":
        bad += p.returncode != 1 or p.stderr.decode().strip() != "rhobound: " + d["message"]
        continue
    r = json.loads(p.stdout)
    for s, g in zip(d["services"], r["services"]):
        bad += any(s.get(k) != g.get(k) for k in ("utilization", "model_ms", "after_ms", "change_ms", "change_pct"))
print(f"GO one process per point, {par} at a time: {len(lines)} points in {t1 - t0:.2f} s; lines differing from rbfast's: {bad}")
PY
done
# the same evaluations in one Go process (the Go driver's sweep): the loads and specs of rbfast's lines, in grid
# order
python3 -I - "$OUT/sweep.jsonl" "$TOPO" "$OUT/go-sweep-manifest.json" <<'PY'
import json, sys
rps, specs = [], []
for x in open(sys.argv[1]):
    d = json.loads(x)
    if d["rps"] not in rps:
        rps.append(d["rps"])
    if d["patch"] is not None and d["patch"] not in specs:
        specs.append(d["patch"])
json.dump([{"name": "sweep", "topology_path": sys.argv[2], "rps": rps, "patches": specs}], open(sys.argv[3], "w"))
PY
if [ -n "$GOSWEEP" ]; then
  GOMAXPROCS=1 wrap "$GOSWEEP" sweep "$OUT/go-sweep-manifest.json" "$OUT/go-sweep.json" 3 | sed 's/^/GO in one process (Go model driver sweep, GOMAXPROCS=1): /' | tee -a "$OUT/bench.log"
else
  log "RBFAST_GO_SWEEP not set: no in-process Go row"
fi
for who in go rb; do
  b=$GO; [ $who = rb ] && b=$RB
  wrap "${RUNSTAT[@]}" -n 10 -label "$who model one call" -- "$b" model "$TOPO" --rps 101.1 --json | grep MEDIAN | tee -a "$OUT/bench.log"
  wrap "${RUNSTAT[@]}" -n 10 -label "$who model one call --patch" -- "$b" model "$TOPO" --rps 101.1 --json --patch pricing=+5% | grep MEDIAN | tee -a "$OUT/bench.log"
  wrap "${RUNSTAT[@]}" -n 10 -label "$who predict small capture" -- "$b" predict "$CAP" --json | grep MEDIAN | tee -a "$OUT/bench.log"
  wrap "${RUNSTAT[@]}" -n 10 -label "$who version (process start)" -- "$b" version | grep MEDIAN | tee -a "$OUT/bench.log"
done
log "STATE load=$(cut -d' ' -f1-3 /proc/loadavg)"
