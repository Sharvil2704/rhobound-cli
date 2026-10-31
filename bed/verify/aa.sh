#!/usr/bin/env bash
# verify/aa.sh: N back-to-back production windows at baseline for the A/A floor (SPEC 7). On rbd-tools1 as user rbd.
#   aa.sh N [PREFIX]   capture.sh PREFIX-i 600 SEED for i = 1..N (PREFIX default aa), under the cluster lock for the whole run
# Refuses (exit 1) when production is not at baseline.json (every service). A window whose capture already exists with a finished
# load.json is reused (a partial run resumes); one that exists without it is refused (re-run under another PREFIX).
# Writes $RBD_HOME/verify/aa/PREFIX-i.load.json (score.py --bundle reads them), aa.log, PREFIX-i.capture.log, PREFIX.json (names,
#   seeds, times). Last stdout line: {"step":"aa","ok",...}. Exit: 0 ok; 1 failed; 2 usage.
# Env: vlib.sh's (RBD_LIB, RBD_CI, RBD_WINDOW_S, RBD_LOCK_WAIT).
set -euo pipefail
usage() { echo "usage: $0 N [PREFIX]" >&2; exit 2; }
[[ ${1:-} == -h || ${1:-} == --help ]] && { sed -n '2,8p' "$0"; exit 0; }
(($# >= 1 && $# <= 2)) || usage
N=$1; PREFIX=${2:-aa}
[[ $N =~ ^[1-9][0-9]?$ ]] || { echo "N: 1..99" >&2; usage; }
WHO="aa $PREFIX"
# shellcheck source=vlib.sh
. "$(dirname "$(readlink -f "$0")")/vlib.sh"
valid_name "$PREFIX-$N" || { echo "PREFIX: [a-z0-9-]" >&2; usage; }
ERR=; DONE=()
on_exit() {
  local rc=$?
  trap - EXIT INT TERM HUP
  [[ -z $CHILD ]] || kill "$CHILD" 2> /dev/null || true
  [[ -n $ERR || $rc == 0 ]] || ERR="exit $rc"
  jq -cn --arg p "$PREFIX" --arg e "$ERR" --argjson rc "$rc" --argjson n "$N" --arg d "${DONE[*]:-}" \
    '{step: "aa", ok: ($rc == 0), prefix: $p, n: $n, done: ($d | split(" ") | map(select(length > 0))), error: $e, exit: $rc}' || true
  exit "$rc"
}
trap on_exit EXIT
trap 'ERR="signal INT"; exit 130' INT
trap 'ERR="signal TERM"; exit 143' TERM
trap 'ERR="signal HUP"; exit 129' HUP

env_load
all_at_baseline
OUT=$RBD_HOME/verify/aa
for i in $(seq 1 "$N"); do
  c=$RBD_HOME/captures/$PREFIX-$i
  [[ ! -e $c ]] || load_ok "$c/meta/load.json" || vdie "$c exists without a finished meta/load.json: use another PREFIX"
done
[[ -x $RBD_CI/capture.sh ]] || vdie "no $RBD_CI/capture.sh"
lock_take "aa-$PREFIX"
mkdir -p "$OUT" || vdie "cannot create $OUT"
VLOG=$OUT/aa.log
rows=()
for i in $(seq 1 "$N"); do
  name=$PREFIX-$i; seed=$(seed_of "$name"); lj=$RBD_HOME/captures/$name/meta/load.json
  t0=$(now)
  if load_ok "$lj"; then
    vlog "$name exists with a finished load.json: reused"
    put "$OUT/$name.load.json" < "$lj" || vdie "cannot write $OUT/$name.load.json"
  else
    capture "$name" "$seed" "$OUT/$name.load.json" "$OUT/$name.capture.log"
  fi
  DONE+=("$name")
  rows+=("$(jq -cn --arg n "$name" --argjson s "$seed" --arg a "$t0" --arg b "$(now)" '{name: $n, seed: $s, start: $a, end: $b}')")
  printf '%s\n' "${rows[@]}" | jq -s --arg p "$PREFIX" '{schema: "rbd.aa/v1", prefix: $p, windows: .}' | put "$OUT/$PREFIX.json"
done
vlog "done: ${DONE[*]}"
