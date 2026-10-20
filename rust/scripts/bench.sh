#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
#
# bench.sh: rbfast against rhobound, end to end: `predict CAPTURE --json`, the whole process (read, inference,
# model, report), at 1, 2, 4 and 8 threads.
#
#   RBFAST_GO=rhobound RBFAST_BENCH_RUN3=DIR ... scripts/bench.sh OUTDIR [CAPTURES...]
#     CAPTURES: RUN3 BIG RUN3GZ BIGGZ RUN3JSON RUN3JSONGZ BIGJSONGZ (default: RUN3 BIG)
#
# Inputs (the captures are not in the repository; set the ones you name):
#   RBFAST_BENCH_RUN3    RUN3: a plain capture (the recorded runs: test-bed run 3's before capture, one 579 MB
#                        .jsonl, 696,949 spans)
#   RBFAST_BENCH_BIG     BIG: a large plain capture (the recorded runs: big8-run3, 8 time-shifted copies of run 3
#                        with remapped ids, 8 files, 4.63 GB, 5,575,592 spans)
#   RBFAST_BENCH_RUN3GZ, RBFAST_BENCH_BIGGZ   RUN3GZ, BIGGZ: the same, gzipped (.jsonl.gz)
#   RUN3JSON, RUN3JSONGZ, BIGJSONGZ: the files of RUN3, RUN3GZ and BIGGZ read as `.json` streams (links named
#   *.json, *.json.gz in OUTDIR/links: one value per line is a stream of values)
#   RBFAST_GO      the rhobound binary (required); RBFAST_BIN the rbfast binary (default: target/release/rbfast)
#   RBFAST_TIMER   the timer (default: python3 -I scripts/timer.py)
#   RBFAST_WRAP    a command prefix for every timed run (the recorded runs: a systemd scope with a 4 GB memory
#                  cap, CPUWeight 50 and nice 10: "systemd-run --user --scope -p MemoryMax=4G -p MemorySwapMax=0
#                  -p CPUWeight=50 --quiet -- nice -n 10")
#
# Method:
#  * The page cache is warmed first (cat > /dev/null), so the numbers are for a warm cache.
#  * Threads: Go with GOMAXPROCS=p; rbfast with --threads p (its reader, inference and model pools).
#  * Each (binary, capture, p) is one untimed warm-up run, then 3 timed runs (the timer: wall time from fork to
#    wait4, user and sys time and peak RSS from rusage); the figure is the median of the 3. Go and rbfast
#    alternate per thread count. Stdout goes to a file; the outputs' SHA-256 are compared, so the benchmark is a
#    parity check too.
#  * Machine load: before starting, waits up to 45 minutes (re-checking every 2 minutes) for a 1-minute load below
#    1.5 and under 0.4 busy cores; before each configuration it waits up to 10 minutes for under 0.4 busy cores.
#    For each configuration it logs how many cores OTHER processes kept busy (busy core-seconds from /proc/stat
#    minus the configuration's own user+sys, over its wall time); one above 0.3 is flagged NOISY in the summary.
#    If the machine never got quiet the summary says so. Linux only (/proc).
#  * The summary (bench_summary.py) is OUTDIR/summary.md.
set -uo pipefail
WS=$(cd "$(dirname "$0")/.." && pwd)
OUT=${1:?usage: bench.sh OUTDIR [CAPTURES...]}; shift
CAPS=${*:-RUN3 BIG}
mkdir -p "$OUT"
read -r -a WRAP <<< "${RBFAST_WRAP:-}"
read -r -a RUNSTAT <<< "${RBFAST_TIMER:-python3 -I $WS/scripts/timer.py}"
GO=${RBFAST_GO:?set RBFAST_GO to the rhobound binary}
RB=${RBFAST_BIN:-${CARGO_TARGET_DIR:-$WS/target}/release/rbfast}
RUN3=${RBFAST_BENCH_RUN3:-}
BIG=${RBFAST_BENCH_BIG:-}
RUN3GZ=${RBFAST_BENCH_RUN3GZ:-}
BIGGZ=${RBFAST_BENCH_BIGGZ:-}
LINKS=$OUT/links
rm -rf "$LINKS"
link() { # SRC_CAPTURE NAME FROM_SUFFIX TO_SUFFIX: a capture of links to SRC's *FROM files, named *TO
  [ -n "$1" ] || return 0
  mkdir -p "$LINKS/$2/traces"
  for f in "$1"/traces/*"$3"; do ln -s "$f" "$LINKS/$2/traces/$(basename "$f" "$3")$4"; done
}
link "$RUN3" run3-json .jsonl .json
link "$RUN3GZ" run3-json-gz .jsonl.gz .json.gz
link "$BIGGZ" big8-run3-json-gz .jsonl.gz .json.gz
RUN3JSON=$LINKS/run3-json
RUN3JSONGZ=$LINKS/run3-json-gz
BIGJSONGZ=$LINKS/big8-run3-json-gz
for c in $CAPS; do
  case $c in RUN3|BIG|RUN3GZ|BIGGZ|RUN3JSON|RUN3JSONGZ|BIGJSONGZ) ;; *) echo "unknown capture $c" >&2; exit 2 ;; esac
  [ -d "${!c}/traces" ] || { echo "$c: no capture (see the RBFAST_BENCH_* variables in bench.sh)" >&2; exit 2; }
done
HZ=$(getconf CLK_TCK)
log() { echo "$(date -Is) $*" | tee -a "$OUT/bench.log"; }
busy() { # average busy cores over $1 seconds (user+nice+system+irq+softirq+steal)
  local a b
  read -r _ a1 a2 a3 _ _ a6 a7 a8 _ < /proc/stat
  sleep "$1"
  read -r _ b1 b2 b3 _ _ b6 b7 b8 _ < /proc/stat
  awk -v b=$(( (b1+b2+b3+b6+b7+b8) - (a1+a2+a3+a6+a7+a8) )) -v hz=$HZ -v s=$1 'BEGIN{printf "%.2f\n", b/hz/s}'
}
state() { log "STATE load=$(cut -d' ' -f1-3 /proc/loadavg) busy3s=$(busy 3) mem_avail_mib=$(awk '/MemAvailable/{print int($2/1024)}' /proc/meminfo)"; }
jiffies() { awk '/^cpu /{print $2+$3+$4+$7+$8+$9}' /proc/stat; }
wrap() { ${WRAP[@]+"${WRAP[@]}"} "$@"; }

log "BINARIES go=$GO ($($GO version)) rbfast=$RB ($($RB version)) sha256: go=$(sha256sum < "$GO" | cut -c1-16) rbfast=$(sha256sum < "$RB" | cut -c1-16)"
log "MACHINE $(nproc) cores, $(awk '/MemTotal/{print int($2/1024)}' /proc/meminfo) MiB, $(uname -m), kernel $(uname -r)"
deadline=$(( $(date +%s) + 2700 ))
while :; do
  l=$(cut -d' ' -f1 /proc/loadavg); b=$(busy 3)
  log "WAIT load1=$l busy3s=$b"
  if awk -v l="$l" -v b="$b" 'BEGIN{exit !(l<1.5 && b<0.4)}'; then log "QUIET"; break; fi
  if [ "$(date +%s)" -ge "$deadline" ]; then log "DEADLINE: still busy after 45 minutes, running anyway (NOISY)"; break; fi
  sleep 120
done
for c in $CAPS; do cat "${!c}"/traces/* > /dev/null; done
log "WARM page cache ($CAPS)"
run() { # label cmd...: the timer's lines, and the other processes' busy cores during it
  local label=$1; shift
  local j0 j1 t0 t1 own
  j0=$(jiffies); t0=$(date +%s%N)
  "$@" > "$OUT/.last" 2>>"$OUT/stderr.txt"
  j1=$(jiffies); t1=$(date +%s%N)
  cat "$OUT/.last" >> "$OUT/runs.txt"
  own=$(awk '/^RUN/{for(i=1;i<=NF;i++){if($i~/^user=/){sub("user=","",$i);u+=$i} if($i~/^sys=/){sub("sys=","",$i);s+=$i}}} END{print u+s}' "$OUT/.last")
  awk -v j=$((j1-j0)) -v hz=$HZ -v own="$own" -v ns=$((t1-t0)) -v label="$label" \
    'BEGIN{w=ns/1e9; o=(j/hz-own)/w; printf "OTHERS %s wall=%.2f busy_total=%.2f own=%.2f others_cores=%.2f\n", label, w, j/hz/w, own/w, o}' | tee -a "$OUT/others.txt"
}
for c in $CAPS; do
  path=${!c}
  for p in 1 2 4 8; do
    for who in go rb; do
      w0=$(date +%s)
      while :; do
        b=$(busy 3)
        awk -v b="$b" 'BEGIN{exit !(b<0.4)}' && break
        if [ $(( $(date +%s) - w0 )) -ge 600 ]; then log "CONFIG-WAIT gave up ($who $c $p busy3s=$b)"; break; fi
        sleep 20
      done
      state
      o="$OUT/out-$who-$c-$p.json"
      if [ $who = go ]; then
        GOMAXPROCS=$p wrap "$GO" predict "$path" --json > /dev/null 2>>"$OUT/stderr.txt"   # warm-up
        GOMAXPROCS=$p run "$who $c $p" wrap "${RUNSTAT[@]}" -n 3 -label "$who $c $p" -o "$o" -- "$GO" predict "$path" --json
      else
        wrap "$RB" predict "$path" --json --threads $p > /dev/null 2>>"$OUT/stderr.txt"      # warm-up
        run "$who $c $p" wrap "${RUNSTAT[@]}" -n 3 -label "$who $c $p" -o "$o" -- "$RB" predict "$path" --json --threads $p
      fi
      echo "HASH $who $c $p $(sha256sum < "$o" | cut -c1-64)" >> "$OUT/hashes.txt"
    done
  done
done
# where rbfast's time goes, at 8 threads (RBFAST_TIMES: read, inference, model, report inside the process)
for c in $CAPS; do
  for rep in 1 2 3; do
    RBFAST_TIMES=1 wrap "$RB" predict "${!c}" --json --threads 8 2>&1 >/dev/null | sed "s|^|STAGES $c |" >> "$OUT/stages.txt"
  done
done
state
python3 -I "$WS/scripts/bench_summary.py" "$OUT" | tee "$OUT/summary.md"
