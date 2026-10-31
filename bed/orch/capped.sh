#!/usr/bin/env bash
# Run a build or test job in a memory-capped, low-priority scope (RB_MEM_MAX, default 6G); plain nice without systemd.
set -euo pipefail
if command -v systemd-run > /dev/null && systemctl --user show-environment > /dev/null 2>&1; then
  exec systemd-run --user --scope -p MemoryMax="${RB_MEM_MAX:-6G}" -p MemorySwapMax=0 -p CPUWeight=50 --quiet -- nice -n 10 "$@"
fi
exec nice -n 10 "$@"
