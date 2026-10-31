#!/usr/bin/env bash
# test_copy_traces.sh: copy_traces.sh's file selection on fake Collector files with set mtimes, then the copy through the kubectl
# stub (exec on a local folder), the cut of an unfinished last line, a copy that fails once (retried), the open file first to tar,
# a rotation between the listing and tar (found by the re-listing, copied again), and the refusals.
# shellcheck disable=SC1090,SC1091,SC2012,SC2015,SC2016,SC2088,SC2155  # test code
set -uo pipefail
# shellcheck source=lib.sh
. "$(dirname "$(readlink -f "$0")")/lib.sh"
CT=$DEMO/tools1/lib/copy_traces.sh
D=$T/data; mkdir -p "$D"; export FAKE_DATA=$D
ns() { echo "$(date -u -d "$1" +%s)000000000"; }
mk() { printf '%s\n' "$2" > "$D/$1"; touch -d "$3" "$D/$1"; }
# rotation every few minutes; the window 10:00:00 .. 10:10:00 (margins: 09:58:00 .. 10:11:00)
mk spans-2026-10-30T09-30-00.000.jsonl '{"old":1}' 2026-10-30T09:30:00Z     # covers (0, 09:30]          -> no
mk spans-2026-10-30T09-50-00.000.jsonl '{"a":1}'   2026-10-30T09:50:00Z     # (09:30, 09:50]             -> no (ends before 09:58)
mk spans-2026-10-30T09-58-30.000.jsonl '{"b":1}'   2026-10-30T09:58:30Z     # (09:50, 09:58:30]          -> yes
mk spans-2026-10-30T10-05-00.000.jsonl '{"c":1}'   2026-10-30T10:05:00Z     # (09:58:30, 10:05]          -> yes
mk spans-2026-10-30T10-10-30.000.jsonl '{"d":1}'   2026-10-30T10:10:30Z     # (10:05, 10:10:30]          -> yes
mk spans-2026-10-30T10-20-00.000.jsonl '{"e":1}'   2026-10-30T10:20:00Z     # (10:10:30, 10:20]          -> yes (starts before 10:11)
mk spans-2026-10-30T10-40-00.000.jsonl '{"f":1}'   2026-10-30T10:40:00Z     # (10:20, 10:40]             -> no (starts after 10:11)
printf '{"g":1}\n{"partial":' > "$D/spans.jsonl"; touch -d 2026-10-30T10:50:00Z "$D/spans.jsonl"   # the open file  -> no
echo junk > "$D/other.txt"
S=$(ns 2026-10-30T10:00:00Z) E=$(ns 2026-10-30T10:10:00Z)
listing=$(cd "$D" && for f in spans*.jsonl; do stat -c '%Y %s %n' "$f"; done)
got=$(bash "$CT" --select "$S" "$E" <<< "$listing" | tr '\n' ' ')
want="spans-2026-10-30T09-58-30.000.jsonl spans-2026-10-30T10-05-00.000.jsonl spans-2026-10-30T10-10-30.000.jsonl spans-2026-10-30T10-20-00.000.jsonl "
check "selection by mtime: $got" [ "$got" = "$want" ]
# the open file is chosen when the window reaches it; listing order does not matter
got=$(bash "$CT" --select "$(ns 2026-10-30T10:30:00Z)" "$(ns 2026-10-30T10:45:00Z)" <<< "$(tac <<< "$listing")" | tr '\n' ' ')
check "late window: rotated 10:20..10:40 and the open file ($got)" [ "$got" = "spans-2026-10-30T10-40-00.000.jsonl spans.jsonl " ]
got=$(bash "$CT" --select "$(ns 2026-10-30T08:00:00Z)" "$(ns 2026-10-30T08:10:00Z)" <<< "$listing" | tr '\n' ' ')
check "early window: only the first file ($got)" [ "$got" = "spans-2026-10-30T09-30-00.000.jsonl " ]
bash "$CT" --select 12 "$E" < /dev/null > /dev/null 2>&1; check "bad SINCE -> usage exit 2" [ $? = 2 ]

# the copy through the stub
out=$(bash "$CT" "$(ns 2026-10-30T10:30:00Z)" "$(ns 2026-10-30T10:45:00Z)" "$T/c1" 2> "$T/c1.err"); rc=$?
check "copy exit 0" [ $rc = 0 ]
check "copy JSON line names 2 files" [ "$(jq -r .copied <<< "$out")" = 2 ]
check "only traces/ in OUTDIR" [ "$(ls "$T/c1")" = traces ]
check "the open file's unfinished line was cut" [ "$(cat "$T/c1/traces/spans.jsonl")" = '{"g":1}' ]
check "the cut file ends with a newline" [ "$(tail -c 1 "$T/c1/traces/spans.jsonl" | od -An -c | tr -d ' ')" = '\n' ]
check "the source file is untouched" grep -q partial "$D/spans.jsonl"
check "bytes counted" [ "$(jq -r .bytes <<< "$out")" = "$(cat "$T/c1/traces/"* | wc -c)" ]
check "the open file goes first to tar" grep -q "exec spans-reader -c reader -- tar cf - -C /data spans.jsonl spans-2026-10-30T10-40-00.000.jsonl$" "$STUB_LOG"
check "no rotation, no second copy" bash -c "! grep -q 'rotation during the copy' '$T/c1.err' && [ \$(grep -c 'tar cf - -C /data' '$STUB_LOG') = 1 ]"
# the Collector rotates spans.jsonl between the listing and tar: the copy holds the new, nearly empty file; the re-listing finds
# the rotated file (the window's tail) and the copy is done again
cp -a "$D" "$T/data-rot"
out=$(FAKE_DATA=$T/data-rot STUB_TAR_ROTATE_ONCE=$T/rotated-once bash "$CT" "$(ns 2026-10-30T10:30:00Z)" "$(ns 2026-10-30T10:45:00Z)" "$T/c-rot" 2> "$T/c-rot.err"); rc=$?
check "rotation during the copy: exit 0 (rc $rc)" [ $rc = 0 ] && check "...said so and copied again" grep -q "a rotation during the copy (new: spans-2026-10-30T10-50-00.000.jsonl )" "$T/c-rot.err"
check "...the rotated file (the window's tail) was copied, not the new open file ($(jq -c .files <<< "$out"))" [ "$(jq -c .files <<< "$out")" = '["spans-2026-10-30T10-40-00.000.jsonl","spans-2026-10-30T10-50-00.000.jsonl"]' ]
check "...with the tail's spans" [ "$(cat "$T/c-rot/traces/spans-2026-10-30T10-50-00.000.jsonl")" = '{"g":1}' ] && check "...and nothing of the first copy left" [ ! -e "$T/c-rot/traces/spans.jsonl" ]
# a copy that fails once (rotation during the copy) is retried
export STUB_TAR_FAIL_ONCE=$T/failed-once
out=$(bash "$CT" "$S" "$E" "$T/c2" 2> "$T/c2.err"); rc=$?
check "retried after one failed tar (rc $rc)" [ $rc = 0 ] && check "4 files after the retry" [ "$(jq -r .copied <<< "$out")" = 4 ]
check "the retry was logged" grep -q "copy failed (try 1" "$T/c2.err"
unset STUB_TAR_FAIL_ONCE
# refusals
bash "$CT" "$S" "$E" "$T/c2" > /dev/null 2>&1; check "a non-empty OUTDIR/traces is refused (exit 1)" [ $? = 1 ]
bash "$CT" "$(ns 2026-10-31T00:00:00Z)" "$(ns 2026-10-31T00:10:00Z)" "$T/c3" > /dev/null 2> "$T/c3.err"
check "no file covers a window a day late -> exit 1" [ $? = 1 ] && check "...and says so" grep -q "no Collector file covers" "$T/c3.err"
got=$(bash "$CT" --select "$(ns 2026-10-29T00:00:00Z)" "$(ns 2026-10-29T00:10:00Z)" <<< "$listing" | tr '\n' ' ')
check "a window before every file: the first file (its start is unknown) ($got)" [ "$got" = "spans-2026-10-30T09-30-00.000.jsonl " ]
check "every exec went to spans-reader -c reader" bash -c "! grep 'kubectl.* exec ' '$STUB_LOG' | grep -v 'exec spans-reader -c reader --'"
finish
