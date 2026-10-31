# shellcheck shell=bash disable=SC2034,SC2016  # KIT: used by the tests that source this; stub text is literal
# s8lib.sh: shared by the SPEC2 S8-S10 + scoreboard tests (sourced). A scratch folder T under S8_SCRATCH
# [$HOME/rbd-dev/tmp/s8] (never /tmp), the stateful fake gh (fakebin/gh -> fakegh.py) first on PATH, and ssh, aws,
# docker, kubectl stubs that fail loudly (exit 97) if anything calls them. The kit under test is this file's own kit.
H8=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
KIT=$(cd "$H8/../../.." && pwd)
S8=${S8_SCRATCH:-$HOME/rbd-dev/tmp/s8}
PASS=0 FAILS=0
ok() { PASS=$((PASS + 1)); echo "  ok   $*"; }
bad() { FAILS=$((FAILS + 1)); echo "  FAIL $*"; }
check() { local d=$1; shift; if "$@"; then ok "$d"; else bad "$d"; fi; }
done_summary() { echo "  -- $PASS passed, $FAILS failed"; [[ $FAILS -eq 0 ]]; }
jq1() { python3 -I -c 'import json,sys; d=json.load(open(sys.argv[1]))
for k in sys.argv[2].split("."): d=d[int(k)] if isinstance(d,list) else d.get(k)
print("" if d is None else (json.dumps(d) if isinstance(d,(dict,list,bool)) else d))' "$1" "$2"; }

mkenv8() { # mkenv8 NAME: T (scratch), T/state (RBD_STATE), T/stub (STUB_DIR, calls.log), STUB_WORLD
  T=$S8/t-$1
  rm -rf "$T"
  mkdir -p "$T/bin" "$T/stub" "$T/state/bench"
  local c
  for c in ssh aws docker kubectl; do
    printf '#!/usr/bin/env bash\necho "STUB: %s $* must not run in this test" >&2\necho "%s $*" >> "$STUB_DIR/forbidden.log"\nexit 97\n' "$c" "$c" > "$T/bin/$c"
  done
  chmod +x "$T/bin/"*
  ln -s "$H8/fakebin/gh" "$T/bin/gh"   # a link: fakebin/gh finds fakegh.py next to its own real path
  : > "$T/stub/calls.log"
  export PATH=$T/bin:$PATH STUB_DIR=$T/stub STUB_WORLD=$T/stub/world.json RBD_STATE=$T/state
  unset DRYRUN REPO AUTOMERGE_STATUS_CREATOR
  export AUTOMERGE_POLL=0 AUTOMERGE_DEPLOY_WAIT=600 AUTOMERGE_LOCK_WAIT=5 AUTOMERGE_GUARD=   # no variance guard unless a test sets one
  [[ $(command -v gh) == "$T/bin/gh" && $(command -v ssh) == "$T/bin/ssh" ]] || { echo "stubs are not first on PATH: refusing to run" >&2; exit 2; }
}

# world PR...: a fresh fake GitHub; each PR is 'N:KEY=VALUE,...' over a default open, labelled, mergeable bench PR of
# rbd-demo-bot whose head is cut from main and whose rhobound/verdict says pass. KEY: verdict (pass|block|inconclusive|
# error|none), desc, creator, pending (reads), behind, mergeable, label (0: none), labels (a|b names: in place of the default
# rbd-bench), labels2 (a|b names: the labels from the PR's first gh pr view on: relabelled between two reads), branch, author,
# files (a|b paths), draft, base, cross. Then: world_set KEY JSON for top-level keys (deploy_polls, deploy_final, merge_fails,
# ...).
world() { python3 -I "$H8/fakegh.py" __world "$@"; }
add_pr() { python3 -I "$H8/fakegh.py" __add "$@"; }   # add_pr SPEC: one more PR in the current world
world_set() { python3 -I -c 'import json,sys; w=json.load(open(sys.argv[1])); w[sys.argv[2]]=json.loads(sys.argv[3]); json.dump(w,open(sys.argv[1],"w"))' "$STUB_WORLD" "$1" "$2"; }
headof() { python3 -I -c 'import json,sys; print(json.load(open(sys.argv[1]))["prs"][sys.argv[2]]["headRefOid"])' "$STUB_WORLD" "$1"; }
prstate() { python3 -I -c 'import json,sys; print(json.load(open(sys.argv[1]))["prs"][sys.argv[2]]["state"])' "$STUB_WORLD" "$1"; }
merges() { grep -c '^gh pr merge' "$STUB_DIR/calls.log"; }
