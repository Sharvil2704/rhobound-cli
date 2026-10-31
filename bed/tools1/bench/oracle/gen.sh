#!/usr/bin/env bash
# gen.sh [--check]   the rbd-bench oracle: regenerate tasks/<id>/hidden/hidden_test.go for T1-rank, T2-round, T3-fold,
# T4-base from TODAY's repo/kshop/app/internal/hot (the inputs: catalog, query log, generators) and oracle_test.go (the
# answers: brute-force references, see its header). --check regenerates into scratch and fails on any difference with
# the committed files (the goldens are reproducible). Runs Go only through capped.sh (2 GB, GOMAXPROCS=2), module cache
# offline (GOFLAGS=-mod=mod GOPROXY=off). Scratch: $SCRATCH (default $HOME/rbd-dev/tmp/kshop-hot)/oracle.
# Exit 0 ok, 1 a difference (--check) or a failed oracle run.
set -euo pipefail
HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
KIT=$(cd "$HERE/../../.." && pwd)
GO=${GO:-$(command -v go)}
CAPPED=${CAPPED:-$HOME/rbd-dev/capped.sh}
SCR=${SCRATCH:-$HOME/rbd-dev/tmp/kshop-hot}/oracle
TASKS="T1-rank T2-round T3-fold T4-base"
check=0
[[ ${1:-} == --check ]] && check=1

python3 -I "$HERE/foldtable.py" --check || { echo "gen.sh: oracle_test.go's accent table is not foldtable.py's" >&2; exit 1; }
rm -rf "$SCR"
mkdir -p "$SCR/app/internal" "$SCR/out"
cp "$KIT/repo/kshop/app/go.mod" "$KIT/repo/kshop/app/go.sum" "$SCR/app/"
cp -r "$KIT/repo/kshop/app/internal/hot" "$SCR/app/internal/hot"
cp "$KIT"/tools1/bench/base/kshop/app/internal/hot/*.go "$SCR/app/internal/hot/"   # the code the tasks were written against
cp "$HERE/oracle_test.go" "$SCR/app/internal/hot/zz_oracle_test.go"
(
  cd "$SCR/app"
  export GOFLAGS=-mod=mod GOPROXY=off GOTOOLCHAIN=local GOTMPDIR=${GOTMPDIR:-$HOME/rbd-dev/tmp} ORACLE_OUT=$SCR/out
  RB_MEM_MAX=2G GOMAXPROCS=2 bash "$CAPPED" "$GO" test -count=1 -run '^TestOracleGen$' -v ./internal/hot/
) > "$SCR/oracle.log" 2>&1 || { tail -n 30 "$SCR/oracle.log" >&2; echo "gen.sh: the oracle failed" >&2; exit 1; }
grep -E '^\s+zz_oracle_test.go:[0-9]+: ' "$SCR/oracle.log" | sed 's/^ *zz_oracle_test.go:[0-9]*: /gen.sh: /'
rc=0
for t in $TASKS; do
  f=$SCR/out/$t/hidden_test.go
  [[ -s $f ]] || { echo "gen.sh: no output for $t" >&2; exit 1; }
  "$(dirname "$GO")/gofmt" -w "$f"
  dst=$KIT/tools1/bench/tasks/$t/hidden/hidden_test.go
  if ((check)); then
    if cmp -s "$f" "$dst"; then echo "gen.sh: $t hidden_test.go reproduced"; else echo "gen.sh: $t hidden_test.go DIFFERS"; rc=1; fi
  else
    mkdir -p "$(dirname "$dst")"
    cp "$f" "$dst.new" && mv "$dst.new" "$dst"
    echo "gen.sh: wrote $dst ($(wc -l < "$dst") lines)"
  fi
done
exit "$rc"
