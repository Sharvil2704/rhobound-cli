#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
#
# The golden sweep of commit 1a2df09, live: build rhobound from 1a2df09 out of the repository's history, on this
# machine, and compare what it prints with what this tree's CLI prints, byte for byte, on every case of
# testdata/golden-1a2df09/arm64/manifest.json (cmd/rhobound/golden_test.go, TestGoldenLive1a2df09). The stored goldens
# hold linux/arm64's bytes only (floating point differs in the last bits between architectures); this checks the same
# rule on any architecture, with both binaries built by the same Go. It needs the commit in the clone (in CI,
# actions/checkout with fetch-depth: 0), the go command, git and tar. It changes nothing in the repository: the old
# tree is read with git archive into a temporary folder.
#
#   tools/golden-live.sh
set -euo pipefail

commit=1a2df09
root=$(git rev-parse --show-toplevel)
cd "$root"
manifest=testdata/golden-1a2df09/arm64/manifest.json

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
mkdir "$work/src"
git archive "$commit" | tar -x -C "$work/src"
(cd "$work/src" && GOWORK=off go build -o "$work/rhobound-$commit" ./cmd/rhobound)

# Every case of the manifest must run and pass: a renamed test would otherwise match nothing and exit 0.
RHOBOUND_GOLDEN_1A2DF09="$work/rhobound-$commit" GOWORK=off \
	go test -count=1 -v -run '^TestGoldenLive1a2df09$' ./cmd/rhobound | tee "$work/live.log"
want=$(grep -c '"name":' "$manifest")
got=$(grep -c -- '--- PASS: TestGoldenLive1a2df09/' "$work/live.log" || true)
echo "golden sweep of $commit, live on $(go env GOOS)/$(go env GOARCH): $got of $want cases passed"
test "$want" -gt 0 && test "$got" -eq "$want"
