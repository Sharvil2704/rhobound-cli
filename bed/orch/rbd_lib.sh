# shellcheck shell=bash disable=SC2015,SC2029,SC2034
# rbd_lib.sh: sourced by rbd_connect.sh, rbd_bootstrap.sh and rbd.sh (your workstation: ssh only, no aws/kubectl/docker here).
#   rsh NODE CMD       one command on a machine (no stdin)      rsh_in NODE CMD   the same with this shell's stdin passed on
#   RBD_DRY=1          every remote command is printed ("DRY ssh NODE: CMD", stdin as a byte count) instead of run; output is empty
#                      (RBD_DRY_SAVE=DIR also keeps each stdin in DIR, for the tests)
# Files: STATE=<kit>/state (seed.json, logs/), ssh config ~/.ssh/rbd_aws_config, known hosts ~/.ssh/rbd_known_hosts.
# ~/.ssh/config and ~/.kube/config are never written.
DEMO=${RBD_DEMO:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}
STATE=${RBD_STATE:-$DEMO/state}
# a kit copy that drives another bed (the Muse experiment's bed 2) names its own ssh config, known hosts, repo and subnet in
# state/kit.env (KEY=value lines), so that no command of that copy can reach the first bed's machines
# shellcheck source=/dev/null
if [ -f "$STATE/kit.env" ]; then set -a; . "$STATE/kit.env"; set +a; fi
SSHC=${RBD_SSHC:-$HOME/.ssh/rbd_aws_config}
KH=${RBD_KH:-$HOME/.ssh/rbd_known_hosts}
SEED=$STATE/seed.json
KEY=${RBD_KEY:-$HOME/.ssh/id_ed25519_rhobound}
DRY=${RBD_DRY:-}
SSHO=(-F "$SSHC" -o BatchMode=yes -o ConnectTimeout=15 -o ServerAliveInterval=30 -o ServerAliveCountMax=6)

die() { echo "${RBD_ME:-rbd}: $1" >&2; exit "${2:-1}"; }
log() { echo "[$(date -u +%H:%M:%S)] ${RBD_ME:-rbd}: $*" >&2; }
need_seed() { [ -s "$SEED" ] && [ -s "$SSHC" ] || die "no seed yet: paste the output of 'BED=1 bash spawn_two.sh inventory' into a file and run: orch/rbd_connect.sh seed FILE" 2; }
seed_get() { jq -r --arg k "$1" '.[$k] // empty' "$SEED"; }
running() { jq -r '.nodes | to_entries[] | select(.value.state == "running" and .value.public != "-") | .key' "$SEED"; }
by_role() { jq -r --arg r "$1" '.nodes | to_entries[] | select(.value.state == "running" and .value.public != "-" and .value.role == $r) | .key' "$SEED"; }
one_role() {   # the one running machine of a role
  local n; n=$(by_role "$1")
  [ -n "$n" ] || die "no running machine with role $1 in $SEED" 2
  [ "$(wc -l <<< "$n")" = 1 ] || die "more than one machine with role $1: $(tr '\n' ' ' <<< "$n")" 2
  echo "$n"
}
priv() { jq -r --arg n "$1" '.nodes[$n].private // empty' "$SEED"; }

rsh() {   # NODE CMD...
  local n=$1; shift
  if [ -n "$DRY" ]; then echo "DRY ssh $n: $*" >&2; return 0; fi
  ssh "${SSHO[@]}" -n "$n" "$*"
}
rsh_in() {   # NODE CMD...   (stdin -> the remote command)
  local n=$1 b; shift
  if [ -n "$DRY" ]; then
    if [ -n "${RBD_DRY_SAVE:-}" ]; then local f; f=$(mktemp "$RBD_DRY_SAVE/stdin.XXXXXX"); cat > "$f"; b=$(wc -c < "$f"); echo "DRY ssh $n: $* <<< (stdin: $b bytes -> $f)" >&2
    else b=$(wc -c | tr -d ' '); echo "DRY ssh $n: $* <<< (stdin: $b bytes)" >&2; fi
    return 0
  fi
  ssh "${SSHO[@]}" "$n" "$*"
}
# rbd_q ARG...: the arguments quoted for a remote shell
rbd_q() { local a out=""; for a in "$@"; do out+=" $(printf '%q' "$a")"; done; echo "${out# }"; }
