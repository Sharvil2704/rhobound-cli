#!/usr/bin/env bash
# extra measurements: stage times at 1 and 8 threads, pread vs mmap read, sort modes
# (as run on 2026-10-20; machine paths replaced by variables for publication: RBFAST_SCRATCH holds target/ (this
# tree's build) and target-mmap/ (the same decoder with a memory-mapped reader), RBFAST_BENCH_RUN3 and
# RBFAST_BENCH_BIG are test-bed run 3's before capture and big8-run3, RBFAST_WRAP the memory-capped scope)
cd "$RBFAST_SCRATCH"
L=bench/extra/extra.log
RUN3=$RBFAST_BENCH_RUN3
BIG=$RBFAST_BENCH_BIG
WRAP=$RBFAST_WRAP
until awk '{exit !($1 < 1.0)}' /proc/loadavg; do sleep 20; done
echo "$(date -Is) START load=$(cut -d' ' -f1-3 /proc/loadavg) rbfast sha=$(sha256sum < target/release/rbfast | cut -c1-16) mmap-variant sha=$(sha256sum < target-mmap/release/rbfast | cut -c1-16)" >> $L
cat $RUN3/traces/* $BIG/traces/* > /dev/null
for c in RUN3 BIG; do
  for t in 1 8; do
    for k in 1 2 3; do
      echo "TIMES $c t=$t $(RBFAST_TIMES=1 $WRAP target/release/rbfast predict ${!c} --json --threads $t 2>&1 >/dev/null)" >> $L
    done
    for m in default stable; do
      s=""; [ $m = stable ] && s=stable
      for k in 1 2 3; do
        echo "SORT $c t=$t $m $(RBFAST_SORT=$s RBFAST_STAGES=1 $WRAP target/release/rbfast infer ${!c} --threads $t 2>&1 >/dev/null | grep -o 'sort=[0-9.]*')" >> $L
      done
    done
  done
done
for t in 1 8; do
  for b in target-mmap target target-mmap target; do
    echo "READ RUN3 t=$t $b $($WRAP $b/release/rbfast read $RUN3 --threads $t --reps 9 | grep '^read')" >> $L
  done
done
echo "$(date -Is) END load=$(cut -d' ' -f1-3 /proc/loadavg)" >> $L
