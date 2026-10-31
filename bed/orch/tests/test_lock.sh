#!/usr/bin/env bash
# test_lock.sh: lock.sh with two processes (busy -> timeout with the holder named, then free), a nested child step, try-lock.
# shellcheck disable=SC1090,SC1091,SC2012,SC2015,SC2016,SC2088,SC2155  # test code
set -uo pipefail
# shellcheck source=lib.sh
. "$(dirname "$(readlink -f "$0")")/lib.sh"
export RBD_HOME=$T/home RBD_LOCK_FILE=$T/home/lock; mkdir -p "$RBD_HOME"
L=$DEMO/tools1/lib/lock.sh
# holder: takes the lock, signals, holds it 4 s
( . "$L"; rbd_lock 5 holder-A || exit 9; touch "$T/held"; sleep 4 ) &
hp=$!
for _ in $(seq 1 50); do [ -e "$T/held" ] && break; sleep 0.1; done
check "holder took the lock" [ -e "$T/held" ]
t0=$(date +%s%N)
( . "$L"; rbd_lock 1 waiter-B ) 2> "$T/b.err"; rc=$?
dt=$(( ($(date +%s%N) - t0) / 1000000 ))
check "a second job waits 1 s and is refused (rc $rc, ${dt} ms)" [ $rc = 1 ] && check "...after about 1 s" [ "$dt" -ge 900 ] && [ "$dt" -lt 3000 ]
check "the refusal names the holder" grep -q "holder-A pid" "$T/b.err"
( . "$L"; rbd_lock_try ensure-C ) 2> /dev/null; check "try-lock while held -> 1 at once" [ $? = 1 ]
( . "$L"; rbd_lock 10 waiter-D && echo "got" > "$T/d.out" ); check "a job that waits long enough gets it" grep -q got "$T/d.out"
wait "$hp"
# nested: a step that holds the lock runs a child step that takes it again: no wait, no deadlock
cat > "$T/child.sh" << EOF
#!/usr/bin/env bash
. "$L"
rbd_lock 1 child && echo child-ok
EOF
chmod +x "$T/child.sh"
out=$( . "$L"; rbd_lock 2 parent && "$T/child.sh" ); check "nested child step gets the parent's lock at once ($out)" [ "$out" = child-ok ]
out=$( RBD_LOCK_HELD=12345 "$T/child.sh" 2>&1 ); check "a forged RBD_LOCK_HELD without fd 9 is not trusted (the lock is simply taken)" [ "$out" = child-ok ]
( . "$L"; rbd_lock 2 holder-E; sleep 3 ) & hp=$!; sleep 0.5
out=$( RBD_LOCK_HELD=12345 "$T/child.sh" 2>&1 ); check "...and with the lock held elsewhere it waits and is refused" bash -c "grep -q 'held by holder-E' <<< '$out'"
wait "$hp"
out=$( . "$L"; rbd_lock 2 x; rbd_unlock; rbd_lock_holder ); check "rbd_unlock frees it ($out)" [ "$out" = free ]
finish
