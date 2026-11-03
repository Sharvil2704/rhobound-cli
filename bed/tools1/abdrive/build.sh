#!/usr/bin/env bash
# Test abdrive, then cross-compile it for the machines (linux/amd64, static) into bin/abdrive; prints its sha256.
# usage: bash tools1/abdrive/build.sh [--no-test]      (on your workstation; Go through capped.sh only)
set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
GO=${GO:-$(command -v go || echo go)}
CAPPED=${CAPPED:-$(cd "$(dirname "$0")/../.." && pwd)/orch/capped.sh}
export GOTMPDIR=${GOTMPDIR:-${TMPDIR:-/tmp}} GOTOOLCHAIN=local GOPROXY=off GOFLAGS=-buildvcs=false
mkdir -p "$GOTMPDIR" "$HERE/bin"
cd "$HERE"
[[ -z $("$(dirname "$GO")/gofmt" -l .) ]] || { echo "build.sh: gofmt -l is not empty" >&2; exit 1; }
if [[ ${1:-} != --no-test ]]; then
  RB_MEM_MAX=2G GOMAXPROCS=2 bash "$CAPPED" "$GO" vet ./...
  RB_MEM_MAX=2G GOMAXPROCS=2 bash "$CAPPED" "$GO" test -count=1 ./...
fi
RB_MEM_MAX=2G GOMAXPROCS=2 GOOS=linux GOARCH=amd64 CGO_ENABLED=0 bash "$CAPPED" "$GO" build -trimpath \
  -ldflags='-s -w' -o bin/abdrive.new .
mv bin/abdrive.new bin/abdrive
sha256sum bin/abdrive
