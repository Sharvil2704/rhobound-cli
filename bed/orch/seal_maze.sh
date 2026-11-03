#!/usr/bin/env bash
# seal_maze.sh PR...: the maze live run's gate verdicts and predictions, written to reports/maze-live/SEALED.md before any
# truth bracket runs (cluster test 2, step 6 of its runbook). For each PR: its branch, commit status, the A/B deltas, every entry's change and
# band, the candidate digest, and the sha256 of prediction.json (the gate's prediction digest is that of the file without
# its final newline). Fetches only the run's small files (prediction.json, change.json, candidate.json, A/B records).
set -euo pipefail
K=$(cd "$(dirname "$0")/.." && pwd)
R=${REPO:-Sharvil2704/rhobound-maze-bed}
OUT=${SEAL_OUT:-$K/reports/maze-live/SEALED.md}
mkdir -p "$K/reports/maze-live" "$K/state/runs"
{
  echo "# Maze live run: gate verdicts and predictions, sealed before any truth bracket ($(date -u +%Y-%m-%dT%H:%MZ))"
  echo
  echo "Fit prod-0 (300 s at 120 req/s). Policy: repo/policy/gate.json (4.0 ms, block_band model, strict doubts)."
  echo "change = predicted change band of the entry's mean (ms); band = with the model's documented error."
  echo
  for pr in "$@"; do
    H=$(gh pr view "$pr" -R "$R" --json headRefOid -q .headRefOid)
    B=$(gh pr view "$pr" -R "$R" --json headRefName -q .headRefName)
    S=$(gh api "repos/$R/commits/$H/statuses" --jq '.[0].description')
    D=$K/state/runs/$H
    mkdir -p "$D"
    for f in prediction.json change.json candidate.json; do bash "$K/orch/rbd.sh" get "/var/lib/rbd/runs/$H/$f" "$D/" > /dev/null 2>&1; done
    echo "## PR $pr \`$B\` -> $S"
    echo
    echo "head $H, candidate $(jq -r .digest "$D/candidate.json"), services $(jq -r '.services | join(",")' "$D/candidate.json")"
    for a in $(jq -r '.items[].service' "$D/change.json"); do
      mkdir -p "$D/ab-$a/record"
      bash "$K/orch/rbd.sh" get "/var/lib/rbd/runs/$H/ab-$a/record/ab-record.json" "$D/ab-$a/record/" > /dev/null 2>&1
      jq -r --arg s "$a" '.services[] | select(.service == $s) | "A/B \(.service): own_ms \(.own_ms.delta*1000|round/1000) +- \(.own_ms.se*1000|round/1000)"' \
        "$D/ab-$a/record/ab-record.json"
    done
    echo
    echo "| entry | change | band |"
    echo "|---|---|---|"
    jq -r '.entries[] | "| \(.name) | \(.change_ms.lo*100|round/100)..\(.change_ms.hi*100|round/100) | \(.band_ms.lo*100|round/100)..\(.band_ms.hi*100|round/100) |"' "$D/prediction.json"
    echo
    echo "prediction.json sha256 $(sha256sum "$D/prediction.json" | cut -d' ' -f1)"
    echo
  done
} > "$OUT"
echo "$OUT"
