#!/usr/bin/env bash
# Fake copy_traces.sh SINCE_NS UNTIL_NS OUTDIR for test_ab.sh (part B's interface): records its call; OUTDIR/traces/ gets
# the synthetic mixed capture; the last line is {"copied", "bytes", "files"} as the real one prints.
set -euo pipefail
printf '%s\n' "$*" >>"${FAKE_T:?}/copy_traces.log"
[[ $# == 3 && $1 =~ ^[0-9]{10,20}$ && $2 =~ ^[0-9]{10,20}$ ]] || { echo "usage: copy_traces.sh SINCE_NS UNTIL_NS OUTDIR" >&2; exit 2; }
mkdir -p "$3/traces"
[[ -z $(ls -A "$3/traces") ]] || { echo "copy_traces: $3/traces is not empty" >&2; exit 1; }
cp "${FAKE_MIXED:?}"/traces/* "$3/traces/"
find "$3/traces" -type f -printf '%f\n' | jq -Rnc '[inputs] | {copied: length, bytes: 0, files: .}'
