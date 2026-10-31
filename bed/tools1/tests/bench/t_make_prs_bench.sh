#!/usr/bin/env bash
# t_make_prs_bench.sh: changes/make_prs.sh for bench changes (cN-bench, SPEC2 S6/S8) against a local bare repo with part D's
# stub gh: title from title.txt, the PR labelled rbd-bench (the label created only when missing, never under DRYRUN),
# rhobound-change.json v2 written as given, a base-only change (no code part) committed as the request alone, a v2 request
# with 6 services refused, and the model and prepared changes unchanged (t_patches.sh covers those).
set -uo pipefail
# shellcheck source=tools1/tests/ci/lib.sh
. "$(dirname "$0")/../ci/lib.sh"
echo "== make_prs.sh: cN-bench"
mkenv patches-bench
cp "$HERE/fakebin/gh" "$TROOT/bin/gh"
S=$T/src
mkrepo "$S"
BARE=$T/bare.git
git clone -q --bare "$S" "$BARE"
CX=$T/ch
mkdir -p "$CX"
cp "$KIT/changes/make_prs.sh" "$CX/"
export URL=$BARE WORK=$T/mp
X=$T/x
git clone -q "$BARE" "$X"
mkch() { # mkch NAME SED-ON-lib_v11.go REQUEST-JSON: a bench change folder like orch/agent_take.sh writes
  mkdir -p "$CX/$1"
  if [[ -n $2 ]]; then (cd "$X" && sed -i "$2" kshop/app/internal/work/lib_v11.go && git diff > "$CX/$1/change.patch" && git checkout -q -- .)
  else : > "$CX/$1/change.patch"; fi
  printf '%s\n' "$3" > "$CX/$1/rhobound-change.json"
  echo "bench pick for $1" > "$CX/$1/title.txt"
}
V2='{"schema": "rbd.change-request/v2", "services": ["auth", "payments"], "summary": "a bench change", "base": "go127"}'
mkch c9-bench 's/2500, 32/2400, 32/' "$V2"
mp() { bash "$CX/make_prs.sh" "$@" > "$T/mp.out" 2> "$T/mp.err"; echo $?; }
rc=$(STUB_GH_LABELS='[{"name": "bug"}]' mp c9-bench)
check "c9-bench: pushed, PR created (exit $rc)" bash -c "[ $rc -eq 0 ] && git -C '$BARE' rev-parse -q --verify refs/heads/rbd/c9-bench > /dev/null"
check "...the label rbd-bench is created when missing" grep -q '^gh label create rbd-bench --repo Sharvil2704/rhobound-demo' "$STUB_DIR/calls.log"
check "...gh pr create carries the title from title.txt and --label rbd-bench (after the multi-line body)" bash -c "
  grep -q '^gh pr create --repo Sharvil2704/rhobound-demo --base main --head rbd/c9-bench --title c9-bench: bench pick for c9-bench --body ' '$STUB_DIR/calls.log' &&
  grep -q 'Generated with .* --label rbd-bench\$' '$STUB_DIR/calls.log'"
check "...rhobound-change.json v2 written exactly as given" bash -c "git -C '$BARE' show rbd/c9-bench:rhobound-change.json | cmp -s - '$CX/c9-bench/rhobound-change.json'"
check "...the code part applied (2400 in lib_v11.go)" bash -c "git -C '$BARE' show rbd/c9-bench:kshop/app/internal/work/lib_v11.go | grep -q '2400, 32'"
check "...the PR body names the bench funnel and automerge.sh" grep -q 'rbd-bench funnel' "$STUB_DIR/calls.log"
: > "$STUB_DIR/calls.log"
mkch c10-bench '' '{"schema": "rbd.change-request/v2", "services": ["catalog", "pricing"], "summary": "builder to go 1.27", "base": "go127"}'
rc=$(STUB_GH_LABELS='[{"name": "rbd-bench"}]' mp c10-bench)
check "c10-bench (base-only: no code part): the request alone is committed (exit $rc)" bash -c "[ $rc -eq 0 ] &&
  [ \"\$(git -C '$BARE' diff --name-only main rbd/c10-bench)\" = rhobound-change.json ]"
check "...an existing rbd-bench label is not created again" bash -c "! grep -q '^gh label create' '$STUB_DIR/calls.log'"
: > "$STUB_DIR/calls.log"
mkch c11-bench 's/2500, 32/2300, 32/' "$V2"
rc=$(DRYRUN=1 mp c11-bench)
check "DRYRUN=1: committed in the temp clone, no push, no label call, no PR (exit $rc)" bash -c "[ $rc -eq 0 ] &&
  ! git -C '$BARE' rev-parse -q --verify refs/heads/rbd/c11-bench > /dev/null && ! grep -qE '^gh (label|pr create)' '$STUB_DIR/calls.log'"
mkch c12-bench 's/2500, 32/2200, 32/' '{"schema": "rbd.change-request/v2", "services": ["auth", "payments", "pricing", "catalog", "inventory", "cart"], "summary": "x"}'
rc=$(mp c12-bench)
check "a v2 request with 6 services is refused before any push (exit $rc)" bash -c "[ $rc -eq 1 ] && grep -q 'not a v1 (one service) or v2' '$T/mp.err' &&
  ! git -C '$BARE' rev-parse -q --verify refs/heads/rbd/c12-bench > /dev/null"
mkch c13-bench 's/2500, 32/2100, 32/' '{"schema": "rbd.change-request/v2", "services": ["auth"], "summary": "x", "dockerfile": "FROM x"}'
rc=$(mp c13-bench)
check "a v2 request with an unknown key (a Dockerfile) is refused (exit $rc)" test "$rc" -eq 1
mkch c14-bench 's/2500, 32/2000, 32/' '{"schema": "rbd.change-request/v1", "services": ["auth", "payments"], "summary": "x"}'
rc=$(mp c14-bench)
check "a v1 request with 2 services is refused (exit $rc)" test "$rc" -eq 1
(cd "$X" && sed -i 's/2500, 32/2600, 32/' kshop/app/internal/work/lib_v11.go && echo '# x' >> .github/workflows/gate.yml && git diff > "$T/evil.patch" && git checkout -q -- .)
mkch c15-bench '' "$V2"
cp "$T/evil.patch" "$CX/c15-bench/change.patch"
rc=$(mp c15-bench)
check "a bench patch that touches .github/ is refused like any other (exit $rc)" bash -c "[ $rc -eq 1 ] && grep -q 'outside kshop/app/' '$T/mp.err'"
done_summary
