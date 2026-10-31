#!/usr/bin/env bash
# verify/collect.sh: put the files score.py reads into the verifier's bundle ($RBD_HOME/verify). On rbd-tools1 as user rbd. Reads only.
#   collect.sh run CHANGE RUN   RUN's prediction.json and gate/{gate.json,verdict.txt,summary.md} into verify/truth/CHANGE/
#                               (RUN: a run id under $RBD_HOME/runs/, or a directory holding prediction.json and gate/)
#   collect.sh aa CAPTURE       an existing baseline capture's meta/load.json as an A/A window: the refit's (prod-0) and
#                               each bracket's B0 (truth-CHANGE-b0); a B0 whose capture.sh failed after its window (kept as
#                               CAPTURE.failed-<epoch>, used by truth.sh with a warning) is taken from there, as truth.sh does
# Then, from the orchestrator: orch/rbd.sh get /var/lib/rbd/verify/aa verify/data; orch/rbd.sh get /var/lib/rbd/verify/truth
#   verify/data; python3 -I verify/score.py --bundle verify/data --out verify/out
# Exit: 0 ok; 1 a file is missing; 2 usage. Copies by temp + rename; a re-run overwrites with the same files.
set -euo pipefail
usage() { echo "usage: $0 run CHANGE RUN | aa CAPTURE" >&2; exit 2; }
[[ ${1:-} == -h || ${1:-} == --help ]] && { sed -n '2,10p' "$0"; exit 0; }
WHO=collect
# shellcheck source=vlib.sh
. "$(dirname "$(readlink -f "$0")")/vlib.sh"
case ${1:-} in
  run)
    (($# == 3)) || usage
    valid_name "$2" || usage
    env_load
    if [[ $3 == /* ]]; then R=$3; else
      [[ $3 =~ ^[A-Za-z0-9._-]+$ ]] || usage
      R=$RBD_HOME/runs/$3
    fi
    D=$RBD_HOME/verify/truth/$2
    [[ -d $D ]] || vdie "no $D: run truth.sh $2 first"
    for f in prediction.json gate/gate.json gate/verdict.txt; do [[ -s $R/$f ]] || vdie "no $R/$f"; done
    mkdir -p "$D/gate"
    put "$D/prediction.json" < "$R/prediction.json"
    for f in gate.json verdict.txt summary.md; do [[ ! -f $R/gate/$f ]] || put "$D/gate/$f" < "$R/gate/$f"; done
    printf '%s\n' "$R" | put "$D/run.txt"
    vlog "run $R -> $D"
    ;;
  aa)
    (($# == 2)) || usage
    valid_capture "$2" || usage
    env_load
    lj=$RBD_HOME/captures/$2/meta/load.json
    if ! load_ok "$lj"; then   # the newest CAPTURE.failed-<epoch> (part B's kept capture), as vlib.sh's capture() reads it
      d=$(find "$RBD_HOME/captures" -maxdepth 1 -name "$2.failed-*" -printf '%T@ %p\n' 2> /dev/null | sort -n | tail -n 1 | cut -d' ' -f2-)
      if [[ -z $d ]] || ! load_ok "$d/meta/load.json"; then vdie "no finished $lj"; fi
      vlog "WARN: $2 has no finished meta/load.json; the window of its kept failed capture is used: $d"
      lj=$d/meta/load.json
    fi
    mkdir -p "$RBD_HOME/verify/aa"
    put "$RBD_HOME/verify/aa/$2.load.json" < "$lj"
    vlog "A/A window $2 added"
    ;;
  *) usage ;;
esac
