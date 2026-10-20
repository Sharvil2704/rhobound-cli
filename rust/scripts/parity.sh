#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
#
# parity.sh: rbfast against the Go reference on every input there is.
#
#   RBFAST_ORACLE=DIR scripts/parity.sh [--quick] [--only GROUPS]
#
# 1. If the oracle has the sha256 list of the Go files it was made from (tools/src/*-files.sha256), checks that the
#    Go source (GO_SRC, default: this repository) still has those files (cmd/, internal/, go.mod, testdata/; no git).
# 2. Builds the Go CLI from GO_SRC (go build -buildvcs=false -o SCRATCH/bin/rhobound ./cmd/rhobound: nothing is
#    written into GO_SRC), or takes RBFAST_GO if set, and records every command line the Go tests in cmd/rhobound
#    run: a copy of cmd/, internal/ and testdata/capture-chain in SCRATCH/go-rec, plus
#    scripts/go/record/zz_record_test.go and one added call at the end of main_test.go's exec(). Records the tie
#    captures (scripts/go/ties/zz_tie_captures_test.go, in the same copy) and writes the edge inputs
#    (scripts/edge_inputs.py).
# 3. Builds rbfast (cargo build --release -p rbfast).
# 4. Runs scripts/parity.py: the oracle captures, the recorded CLI test calls, failing inputs, `model` on every
#    inferred topology, `sweep` lines against `rhobound model`, the edge cases, and (without --quick) the
#    large captures. It prints every difference and a summary; the exit status is 1 if anything differs.
#
# Environment:
#   RBFAST_ORACLE   the oracle folder (required; not in the repository: see rust/README.md, "Parity")
#   RBFAST_GO       a rhobound binary to compare with (default: built from GO_SRC into SCRATCH/bin)
#   GO_SRC          the Go source (default: the repository root, the folder above rust/)
#   RBFAST_SCRATCH  the work folder (default: $CARGO_TARGET_DIR/parity, else rust/target/parity)
#   RBFAST_WRAP     a command prefix for the comparisons, e.g. a memory cap:
#                   "systemd-run --user --scope -p MemoryMax=4G -p MemorySwapMax=0 --quiet -- nice -n 10"
#   CARGO_TARGET_DIR, GOMODCACHE, GOCACHE as usual. Needs go (1.23 or later), cargo and python3 on the PATH.
set -euo pipefail
WS=$(cd "$(dirname "$0")/.." && pwd)
GO_SRC=$(cd "${GO_SRC:-$WS/..}" && pwd)
ORACLE=${RBFAST_ORACLE:?set RBFAST_ORACLE to the oracle folder (see rust/README.md, Parity)}
export CARGO_TARGET_DIR=${CARGO_TARGET_DIR:-$WS/target}
S=${RBFAST_SCRATCH:-$CARGO_TARGET_DIR/parity}
mkdir -p "$S/bin" "$S/tmp"
S=$(cd "$S" && pwd)
export TMPDIR=$S/tmp
read -r -a WRAP <<< "${RBFAST_WRAP:-}"
log() { echo "$(date -Is) $*"; }

log "1. Go source: $GO_SRC"
LIST=$(ls "$ORACLE"/tools/src/*-files.sha256 2>/dev/null | head -1 || true)
if [ -z "$LIST" ]; then
  log "   the oracle has no list of its Go files: not checked"
elif (cd "$GO_SRC" && grep -E '  (cmd/|internal/|go\.mod|testdata/)' "$LIST" | sha256sum -c --quiet); then
  log "   cmd/, internal/, go.mod and testdata/ are byte-identical to the oracle's Go tree"
else
  log "   WARNING: the Go source differs from the oracle's: the oracle files may be stale; the fresh-Go comparisons still hold"
fi

log "2. the Go CLI, and recording the cmd/rhobound tests' command lines"
if [ -n "${RBFAST_GO:-}" ]; then
  GO_BIN=$RBFAST_GO
else
  (cd "$GO_SRC" && go build -buildvcs=false -o "$S/bin/rhobound" ./cmd/rhobound)
  GO_BIN=$S/bin/rhobound
fi
"$GO_BIN" version
rm -rf "$S/go-rec" "$S/cases"
mkdir -p "$S/go-rec/testdata" "$S/cases"
cp -r "$GO_SRC/go.mod" "$GO_SRC/cmd" "$GO_SRC/internal" "$S/go-rec/"
[ -f "$GO_SRC/go.sum" ] && cp "$GO_SRC/go.sum" "$S/go-rec/"
cp -r "$GO_SRC/testdata/capture-chain" "$S/go-rec/testdata/"
cp "$WS/scripts/go/record/zz_record_test.go" "$S/go-rec/cmd/rhobound/"
python3 -I - "$S/go-rec/cmd/rhobound/main_test.go" <<'EOF'
import sys
p = sys.argv[1]
s = open(p).read()
old = "\tcode := run(args, &out, &errw)\n\treturn out.String(), errw.String(), code\n"
assert s.count(old) == 1, "exec() in main_test.go changed: update parity.sh"
s = s.replace(old, "\tcode := run(args, &out, &errw)\n\trecordCall(t, args, out.String(), errw.String(), code)\n\treturn out.String(), errw.String(), code\n")
open(p, "w").write(s)
EOF
(cd "$S/go-rec" && RBFAST_REC_DIR="$S/cases" go test -count=1 ./cmd/rhobound)
log "   recorded $(ls "$S/cases" | wc -l) command lines"

log "2b. recording the tie captures (scripts/go/ties/zz_tie_captures_test.go) and writing the edge inputs"
cp "$WS/scripts/go/ties/zz_tie_captures_test.go" "$S/go-rec/internal/infer/"
rm -rf "$S/edge-go" "$S/edge"
(cd "$S/go-rec" && RBFAST_TIE_CAPTURES="$S/edge-go" go test -count=1 -run TestWriteTieCaptures ./internal/infer)
python3 -I "$WS/scripts/edge_inputs.py" "$GO_SRC/testdata/capture-chain" "$S/edge"

log "3. building rbfast"
(cd "$WS" && nice -n 10 cargo build --release -j 3 -p rbfast)

log "4. comparing"
${WRAP[@]+"${WRAP[@]}"} python3 -I "$WS/scripts/parity.py" --go "$GO_BIN" --rbfast "$CARGO_TARGET_DIR/release/rbfast" \
  --oracle "$ORACLE" --cases "$S/cases" --fixture "$GO_SRC/testdata/capture-chain" --examples "$GO_SRC/examples" \
  --edge "$S/edge" --edge-go "$S/edge-go" --work "$S/work" "$@"
