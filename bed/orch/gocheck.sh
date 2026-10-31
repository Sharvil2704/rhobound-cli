#!/usr/bin/env bash
# gocheck.sh ROOT LOG [FILE...]   compile (never run) the kshop module at ROOT/kshop/app, capped and offline: the compile
#   step of orch/agent_take.sh (its step 5, the same go environment and commands, kept in step by
#   tools1/tests/bench/t_plant.sh), for the changes the kit writes itself (changes/plant.py, SPEC3 F9).
#   1. go build -trimpath -buildvcs=false -o /dev/null ./... under the default tags and under kshop_v11 (production's
#      library), then go vet -tags kshop_v11 ./...; offline and for the image's target: env -i, GOPROXY=off
#      GOFLAGS=-mod=readonly GOTOOLCHAIN=local CGO_ENABLED=0 GOOS=linux GOARCH=amd64 GOMAXPROCS=2; every go command inside
#      capped.sh (RB_MEM_MAX=2G) and timeout 600 s, every file it writes capped at 256 MB (ulimit -f); go's work files in a
#      fresh folder on disk (never the /tmp tmpfs); the build cache GOCHECK_CACHE, trimmed when over 3 GB, and the check
#      refused with less than 4 GB free. This box's Go is newer than the image's (1.26.9): an API newer than 1.26 compiles
#      here and fails in the CI build.
#   2. FILE... (paths relative to ROOT, kshop/app/...go: the files the change touched): each must be compiled under the
#      default tags or kshop_v11 (go list); a changed file that neither tag set builds was never checked: refused.
# LOG is written fresh with every go command's output (atomic replace), whatever the result.
# Exit 0 compiles; 1 refused (usage, ROOT, disk space, a changed file compiled under neither tag set); 3 does not compile.
# Env: RBD_CAPPED [$HOME/rbd-dev/capped.sh; "" = none (tests)]
#      GOCHECK_CACHE [kit/../.tmp-bed/agent-gocache: agent_take.sh's build cache]
# shellcheck disable=SC2016  # go list templates are single-quoted
set -euo pipefail
DEMO=$(cd "$(dirname "$0")/.." && pwd)
CAPPED=${RBD_CAPPED-$HOME/rbd-dev/capped.sh}
say() { echo "[gocheck $(date -u +%H:%M:%S)] $*" >&2; }
die() { echo "gocheck: error: $1" >&2; exit "${2:-1}"; }
[[ $# -ge 2 ]] || die "usage: gocheck.sh ROOT LOG [FILE...] (ROOT holds kshop/app; FILE: kshop/app/...go, relative to ROOT)"
[[ -d $1 ]] || die "ROOT $1 is not a folder"
ROOT=$(cd "$1" && pwd -P)   # canonical: go list prints real paths
LOG=$2
shift 2
[[ -f $ROOT/kshop/app/go.mod ]] || die "$ROOT/kshop/app/go.mod missing: ROOT must hold kshop/app"
for f in "$@"; do
  [[ $f =~ ^kshop/app/[A-Za-z0-9_./-]+\.go$ && /$f/ != */../* && /$f/ != */./* ]] || die "FILE $f is not a kshop/app/...go path"
done
command -v go > /dev/null || die "go is required"
[[ -z $CAPPED || -f $CAPPED ]] || die "capped.sh $CAPPED missing (RBD_CAPPED= for none)"
mkdir -p "$DEMO/../.tmp-bed"; W=$(mktemp -d "$DEMO/../.tmp-bed/gocheck.XXXXXX") || die "mktemp"
trap 'rm -rf "$W"' EXIT
G=$ROOT
mkdir -p "$W/gotmp"   # go's work files on disk, never the /tmp tmpfs (it fills: orchestrator pitfalls)
GC=${GOCHECK_CACHE:-$DEMO/../.tmp-bed/agent-gocache}; mkdir -p "$GC"
(( $(du -sm "$GC" | cut -f1) < 3000 )) || { say "trimming $GC"; rm -rf "$GC"; mkdir -p "$GC"; }
(( $(df -Pm "$GC" | awk 'NR==2 {print $4}') > 4000 )) || die "less than 4 GB free for the compile: refused (free space first)"
goenv=(env -i "PATH=$PATH" "HOME=$HOME" "GOPATH=$(go env GOPATH)" "GOCACHE=$GC" "GOMODCACHE=$(go env GOMODCACHE)"
  "GOTMPDIR=$W/gotmp" "TMPDIR=$W/gotmp" GOMAXPROCS=2 GOTOOLCHAIN=local GOFLAGS=-mod=readonly GOPROXY=off CGO_ENABLED=0
  GOOS=linux GOARCH=amd64)
cap=()
[[ -z $CAPPED ]] || cap=(env RB_MEM_MAX=2G bash "$CAPPED")
: > "$W/compile.txt"
ok=1
gorun() { (cd "$G/kshop/app" && ulimit -f 262144 && "${cap[@]}" timeout 600 "${goenv[@]}" "$@"); }
say "compiling (never running) $G/kshop/app, capped: go build (default, kshop_v11), go vet -tags kshop_v11"
for tags in "" kshop_v11; do
  (gorun go build -trimpath -buildvcs=false -tags "$tags" -o /dev/null ./...) >> "$W/compile.txt" 2>&1 ||
    { ok=0; echo "(go build -tags '$tags' failed)" >> "$W/compile.txt"; }
done
(gorun go vet -tags kshop_v11 ./...) >> "$W/compile.txt" 2>&1 ||
  { ok=0; echo "(go vet -tags kshop_v11 failed)" >> "$W/compile.txt"; }
if [[ $ok == 1 && $# -gt 0 ]]; then   # a changed file that neither tag set compiles here was never checked: refused
  : > "$W/built.txt"
  for tags in "" kshop_v11; do
    gorun go list -tags "$tags" -f '{{$d := .Dir}}{{range .GoFiles}}{{$d}}/{{.}}{{"\n"}}{{end}}' ./... >> "$W/built.txt" 2>> "$W/compile.txt" ||
      { ok=0; echo "(go list -tags '$tags' failed)" >> "$W/compile.txt"; }
  done
fi
cp "$W/compile.txt" "$LOG.tmp" && mv -f "$LOG.tmp" "$LOG"
if [[ $ok != 1 ]]; then
  sed 's/[^[:print:]\t]//g' "$W/compile.txt" | tail -30 >&2
  die "does not compile: $LOG" 3
fi
for f in "$@"; do
  grep -qxF "$G/$f" "$W/built.txt" || die "$f is compiled under neither the default tags nor kshop_v11 here: it was never checked (refused)"
done
say "compiles: go build (default, kshop_v11) and go vet -tags kshop_v11 clean"
