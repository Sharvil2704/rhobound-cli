#!/usr/bin/env bash
# copy_traces.sh SINCE_NS UNTIL_NS OUTDIR   every Collector file that may hold spans of [SINCE-120 s, UNTIL+60 s] -> OUTDIR/traces/
#   The files live on edge1 (/var/lib/rbd/traces); they are read through the spans-reader pod (kubectl exec ... tar), no ssh.
#   A file covers (mtime of the file written before it, its own mtime]: rotated files are spans-<time>.jsonl, the open one spans.jsonl.
#   An unfinished last line (the open file being written) is cut off. Last line: {"copied": N, "bytes": B, "files": [...]}.
#   A rotation during the copy (the background load keeps writing during an A/B) would rename the listed spans.jsonl to a
#   spans-<time>.jsonl tar was not given: spans.jsonl goes FIRST to tar, and after the copy the files are listed again; a new
#   file covering the window means the copy may lack the window's tail: it is done again (within the 3 tries).
# copy_traces.sh --select SINCE_NS UNTIL_NS < LISTING   the selection only: LISTING lines "MTIME_S SIZE NAME"; prints the names
# Exit 0; 1 when nothing covers the window or the copy fails (3 tries); 2 usage.
# shellcheck disable=SC2015
set -euo pipefail
MARGIN_BEFORE=${RBD_TRACE_MARGIN_BEFORE:-120}
MARGIN_AFTER=${RBD_TRACE_MARGIN_AFTER:-60}
OBS_NS=${RBD_OBS_NS:-maze-obs}
POD=${RBD_SPANS_POD:-spans-reader}
CTR=${RBD_SPANS_CONTAINER:-reader}
usage() { echo "usage: copy_traces.sh SINCE_NS UNTIL_NS OUTDIR | copy_traces.sh --select SINCE_NS UNTIL_NS < LISTING" >&2; exit 2; }
say() { echo "[$(date -u +%H:%M:%S)] copy_traces: $*" >&2; }

select_files() {   # $1 since_ns $2 until_ns; stdin: listing
  local lo=$(( $1 / 1000000000 - MARGIN_BEFORE )) hi=$(( $2 / 1000000000 + MARGIN_AFTER ))
  grep -E '^[0-9]+ [0-9]+ spans[A-Za-z0-9._-]*\.jsonl$' | sort -k1,1n -k3,3 \
    | awk -v lo="$lo" -v hi="$hi" '{ start = (NR == 1) ? 0 : prev; if ($1 + 0 >= lo && start <= hi) print $3; prev = $1 + 0 }'
}

trim_partial() {   # cut an unfinished last line (no trailing newline) off each file
  python3 -I - "$@" << 'PY'
import os, sys
for p in sys.argv[1:]:
    n = os.path.getsize(p)
    if n == 0:
        continue
    with open(p, "rb+") as f:
        f.seek(-1, 2)
        if f.read(1) == b"\n":
            continue
        keep, pos, step = 0, n, 1 << 16
        while pos > 0:
            pos = max(0, pos - step)
            f.seek(pos)
            i = f.read(min(step, n - pos)).rfind(b"\n")
            if i >= 0:
                keep = pos + i + 1
                break
        f.truncate(keep)
        print(f"copy_traces: cut {n - keep} bytes of an unfinished line off {os.path.basename(p)}", file=sys.stderr)
PY
}

if [ "${1:-}" = --select ]; then
  [ $# = 3 ] && [[ $2 =~ ^[0-9]{10,20}$ && $3 =~ ^[0-9]{10,20}$ ]] || usage
  select_files "$2" "$3"; exit 0
fi
[ $# = 3 ] && [[ $1 =~ ^[0-9]{10,20}$ && $2 =~ ^[0-9]{10,20}$ ]] || usage
SINCE=$1 UNTIL=$2 OUT=$3
[ "$UNTIL" -gt "$SINCE" ] || { say "UNTIL_NS must be after SINCE_NS"; exit 2; }
mkdir -p "$OUT/traces"
[ -z "$(ls -A "$OUT/traces")" ] || { say "$OUT/traces is not empty: refusing to mix copies"; exit 1; }
kubectl -n "$OBS_NS" wait --for=condition=Ready "pod/$POD" --timeout=120s > /dev/null || { say "pod $OBS_NS/$POD is not ready"; exit 1; }

# shellcheck disable=SC2016  # expanded by the pod's shell
LIST='cd /data && for f in spans*.jsonl; do [ -f "$f" ] && stat -c "%Y %s %n" "$f"; done; true'
for try in 1 2 3; do
  listing=$(kubectl -n "$OBS_NS" exec "$POD" -c "$CTR" -- sh -c "$LIST") || { say "listing failed (try $try)"; sleep 5; continue; }
  mapfile -t files < <(select_files "$SINCE" "$UNTIL" <<< "$listing")
  if [ "${#files[@]}" = 0 ] || [ -z "${files[0]}" ]; then
    say "no Collector file covers $(date -u -d "@$((SINCE / 1000000000))" +%FT%TZ) .. $(date -u -d "@$((UNTIL / 1000000000))" +%FT%TZ) (files: $(wc -l <<< "$listing"))"; exit 1
  fi
  # the open file first: tar opens it within a second of the listing, before the Collector can rotate it away
  order=(); for f in "${files[@]}"; do [ "$f" != spans.jsonl ] || order=(spans.jsonl); done
  for f in "${files[@]}"; do [ "$f" = spans.jsonl ] || order+=("$f"); done
  say "copying ${#files[@]} file(s): ${order[*]}"
  if kubectl -n "$OBS_NS" exec "$POD" -c "$CTR" -- tar cf - -C /data "${order[@]}" | tar xf - -C "$OUT/traces" --no-same-owner; then
    # listed again: a rotated file that covers the window and was not copied appeared during the copy
    if relist=$(kubectl -n "$OBS_NS" exec "$POD" -c "$CTR" -- sh -c "$LIST"); then
      new=$(select_files "$SINCE" "$UNTIL" <<< "$relist" | grep -vxF -f <(printf '%s\n' "${files[@]}") || true)
      [ -n "$new" ] || { ok=1; break; }
      say "a rotation during the copy (new: $(tr '\n' ' ' <<< "$new")): again (try $try)"
    else
      say "listing after the copy failed (try $try): again"
    fi
  else
    say "copy failed (try $try; a rotation during the copy?): again"
  fi
  find "$OUT/traces" -mindepth 1 -delete; sleep 3
done
[ "${ok:-}" = 1 ] || { say "copy failed 3 times"; exit 1; }
paths=(); for f in "${files[@]}"; do [ -f "$OUT/traces/$f" ] || { say "$f missing after the copy"; exit 1; }; paths+=("$OUT/traces/$f"); done
trim_partial "${paths[@]}"
bytes=$(du -cb "${paths[@]}" | tail -n 1 | cut -f1)
printf '%s\n' "${files[@]}" | jq -Rnc --argjson b "$bytes" '[inputs] | {copied: length, bytes: $b, files: .}'
