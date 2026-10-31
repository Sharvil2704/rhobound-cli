#!/usr/bin/env bash
# test stand-in for orch/rbd.sh (orch/bench.sh's tests): rbd-tools1 is a folder FAKE_RBD_HOME here (/var/lib/rbd) and the
# kit's tools1/ (/opt/rbd); every call is logged in STUB_DIR/rbd.log. No ssh.
#   run CMD...       CMD in FAKE_RBD_HOME with /var/lib/rbd and /opt/rbd mapped in its arguments; 'cat baseline.json' answers
#                    baseline.after.json once the fake GitHub (STUB_WORLD) holds a merged PR (the deploy's refit)
#   bg NAME CMD...   the funnel stand-in: copies STUB_FUNNEL to bench/NAME/funnel.json, NAME.rc = STUB_BG_RC [0]
#   tail NAME [N]    running for the first STUB_TAIL_RUNNING [0] calls, then 'done, exit RC'
#   get REMOTE DIR   a file or folder of FAKE_RBD_HOME into DIR
set -euo pipefail
FR=$FAKE_RBD_HOME
KIT=$(cd "$(dirname "$(readlink -f "$0")")/../../../.." && pwd)
echo "rbd.sh $*" >> "$STUB_DIR/rbd.log"
map() { local a=$1; a=${a//\/var\/lib\/rbd/$FR}; printf '%s' "${a//\/opt\/rbd/$KIT/tools1}"; }
cmd=$1
shift
case $cmd in
  run)
    if [[ $* == "cat baseline.json" && -f $FR/baseline.after.json ]] &&
      python3 -I -c 'import json,os,sys; w=json.load(open(os.environ["STUB_WORLD"])); sys.exit(0 if any(p["state"] == "MERGED" for p in w["prs"].values()) else 1)'; then
      cat "$FR/baseline.after.json"
      exit 0
    fi
    args=()
    for a in "$@"; do args+=("$(map "$a")"); done
    cd "$FR" && "${args[@]}" ;;
  bg)
    n=$1
    mkdir -p "$FR/bench/$n" "$FR/logs"
    [[ -z ${STUB_FUNNEL:-} ]] || cp "$STUB_FUNNEL" "$FR/bench/$n/funnel.json"
    echo "${STUB_BG_RC:-0}" > "$FR/logs/$n.rc"
    echo "started $n (pid 4242): rbd.sh tail $n" ;;
  tail)
    c=$(( $(cat "$STUB_DIR/tail.count" 2> /dev/null || echo 0) + 1 ))
    echo "$c" > "$STUB_DIR/tail.count"
    if (( c <= ${STUB_TAIL_RUNNING:-0} )) || [[ ! -f $FR/logs/$1.rc ]]; then echo "== $1: running (or never started)"
    else echo "== $1: done, exit $(cat "$FR/logs/$1.rc")"; fi ;;
  get)
    src=$(map "$1")
    [[ -e $src ]] || { echo "tar: $1: Cannot stat: No such file or directory" >&2; exit 2; }
    mkdir -p "$2" && cp -R "$src" "$2/" ;;
  *) echo "fake rbd.sh: unsupported $cmd" >&2; exit 2 ;;
esac
