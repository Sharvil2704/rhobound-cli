#!/usr/bin/env bash
# rbd.sh CMD ...   your workstation's helpers for rbd-tools1 (ssh only: the workstation never runs kubectl, aws or docker itself)
#   rbd.sh run CMD...                     CMD on rbd-tools1 as rbd, /opt/rbd/lib/rbd-env.sh sourced (kubectl, aws, rhobound on PATH)
#   rbd.sh kubectl ARGS...                kubectl on rbd-tools1 as rbd
#   rbd.sh capture NAME [SECONDS [SEED]]  /opt/rbd/ci/capture.sh (600 s; seed from NAME as refit.sh makes it)
#   rbd.sh refit NAME                     /opt/rbd/ci/refit.sh (the production fit)
#   rbd.sh step SCRIPT ARGS...            /opt/rbd/ci/SCRIPT as rbd (ab.sh, predict.sh, ...): its output, its exit code
#   rbd.sh bg NAME CMD...                 CMD as rbd, detached (setsid nohup: a dropped ssh does not stop it), output in
#                                         /var/lib/rbd/logs/NAME.out, exit code in NAME.rc when it ends
#   rbd.sh tail NAME [N]                  running or done (NAME.rc), and the last N (20) lines of NAME.out
#   rbd.sh put LOCAL REMOTE_DIR           a file or folder from here into REMOTE_DIR (under /var/lib/rbd) on rbd-tools1, owned by rbd
#   rbd.sh get REMOTE_PATH LOCAL_DIR      a file or folder of rbd-tools1 (as rbd) into LOCAL_DIR here
#   rbd.sh lock                           who holds the cluster lock
#   rbd.sh tunnel [PORT]                  ssh -L PORT(8765):127.0.0.1:8765 to rhobound-mcp, in the foreground (Ctrl-C ends it)
#   rbd.sh mcp list | mcp TOOL [JSON]     one MCP call through a short-lived tunnel; the token is read into memory, never stored here
#   rbd.sh status                         rbd_bootstrap.sh status
# RBD_DRY=1 prints the remote commands instead.
# shellcheck disable=SC2015,SC2016,SC2029
set -uo pipefail
RBD_ME=rbd
HERE=$(dirname "$(readlink -f "$0")")
# shellcheck source=rbd_lib.sh
. "$HERE/rbd_lib.sh"
usage() { sed -n '2,/^# RBD_DRY/p' "$0" | sed 's/^# \{0,1\}//'; exit 2; }
[ $# -ge 1 ] || usage
need_seed
T=$(one_role tools)
as_rbd() { rsh "$T" "sudo -u rbd -H bash -c '. /opt/rbd/lib/rbd-env.sh; cd /var/lib/rbd; \"\$@\"' rbd $(rbd_q "$@")"; }
seed_of() { echo $(( 16#$(printf '%s' "$1" | sha256sum | cut -c1-7) % 1000000 + 1 )); }

cmd=$1; shift
case $cmd in
  run) [ $# -ge 1 ] || usage; as_rbd "$@" ;;
  kubectl) as_rbd kubectl "$@" ;;
  capture) [ $# -ge 1 ] || usage; as_rbd /opt/rbd/ci/capture.sh "$1" "${2:-600}" "${3:-$(seed_of "$1")}" ;;
  refit) [ $# = 1 ] || usage; as_rbd /opt/rbd/ci/refit.sh "$1" ;;
  step) [ $# -ge 1 ] && [[ $1 =~ ^[a-z0-9_-]+\.(sh|py)$ ]] || die "usage: rbd.sh step SCRIPT ARGS... (a script of /opt/rbd/ci)" 2
        s=$1; shift; as_rbd "/opt/rbd/ci/$s" "$@" ;;
  bg) [ $# -ge 2 ] && [[ $1 =~ ^[A-Za-z0-9._-]+$ ]] || usage
      n=$1; shift
      as_rbd bash -c 'n=$1; shift; mkdir -p logs; rm -f "logs/$n.rc"; setsid nohup bash -c '"'"'"$@" > "logs/$0.out" 2>&1 < /dev/null; echo $? > "logs/$0.rc"'"'"' "$n" "$@" > /dev/null 2>&1 < /dev/null & echo "started $n (pid $!): rbd.sh tail $n"' bg "$n" "$@" ;;
  tail) [ $# -ge 1 ] && [[ $1 =~ ^[A-Za-z0-9._-]+$ ]] || usage
        as_rbd bash -c 'if [ -f "logs/$1.rc" ]; then echo "== $1: done, exit $(cat "logs/$1.rc")"; else echo "== $1: running (or never started)"; fi; tail -n "$2" "logs/$1.out" 2> /dev/null' tail "$1" "${2:-20}" ;;
  put) [ $# = 2 ] && [ -e "$1" ] && [[ $2 == /var/lib/rbd/* ]] || die "usage: rbd.sh put LOCAL REMOTE_DIR (REMOTE_DIR under /var/lib/rbd)" 2
       tar -C "$(dirname "$(readlink -f "$1")")" -cf - "$(basename "$1")" | rsh_in "$T" "sudo -u rbd -H sh -c $(rbd_q "mkdir -p $(rbd_q "$2") && tar -xf - -C $(rbd_q "$2")")" ;;
  get) [ $# = 2 ] || usage; mkdir -p "$2" || die "cannot create $2"
       if [ -n "$DRY" ]; then rsh "$T" "sudo -u rbd -H tar -C $(rbd_q "$(dirname "$1")") -cf - $(rbd_q "$(basename "$1")")"
       else rsh "$T" "sudo -u rbd -H tar -C $(rbd_q "$(dirname "$1")") -cf - $(rbd_q "$(basename "$1")")" | tar -xf - -C "$2"; fi ;;
  lock) as_rbd bash -c '. /opt/rbd/lib/lock.sh; rbd_lock_holder' ;;
  tunnel) p=${1:-8765}; log "rhobound-mcp on http://127.0.0.1:$p/mcp (Ctrl-C to close)"
          [ -n "$DRY" ] && { echo "DRY ssh -N -L $p:127.0.0.1:8765 $T" >&2; exit 0; }
          exec ssh "${SSHO[@]}" -N -o ExitOnForwardFailure=yes -L "$p:127.0.0.1:8765" "$T" ;;
  mcp) [ $# -ge 1 ] || usage
       if [ -n "$DRY" ]; then echo "DRY ssh -N -L PORT:127.0.0.1:8765 $T; ssh $T sudo cat /var/lib/rbd/mcp/token; mcp_call.py $*" >&2; exit 0; fi
       p=$((30000 + RANDOM % 20000))
       ssh "${SSHO[@]}" -N -o ExitOnForwardFailure=yes -L "$p:127.0.0.1:8765" "$T" & tp=$!
       trap 'kill $tp 2> /dev/null' EXIT
       for _ in $(seq 1 30); do curl -s -o /dev/null -m 1 "http://127.0.0.1:$p/mcp" && break; sleep 0.5; done
       tok=$(rsh "$T" 'sudo cat /var/lib/rbd/mcp/token') || die "cannot read the MCP token on $T"
       if [ "$1" = list ]; then RBD_MCP_TOKEN=$tok python3 -I "$HERE/mcp_call.py" --url "http://127.0.0.1:$p/mcp" list
       else RBD_MCP_TOKEN=$tok python3 -I "$HERE/mcp_call.py" --url "http://127.0.0.1:$p/mcp" call "$1" "${2:-{\}}"; fi ;;
  status) exec "$HERE/rbd_bootstrap.sh" status ;;
  *) usage ;;
esac
