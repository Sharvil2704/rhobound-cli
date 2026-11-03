# shellcheck shell=bash
# shellcheck disable=SC1090,SC1091,SC2012,SC2015,SC2016,SC2088,SC2155  # test code
# lib.sh: shared by the offline tests. A scratch dir T under $RBD_SCRATCH/partB (default $TMPDIR/rbd/partB), stubs first on PATH:
# kubectl (orch/tests/stubs/kubectl), and ssh, gh, aws, docker that fail loudly (exit 97) if anything calls them; RBD_LOAD_RPS
# and RBD_LOAD_MIX unset (the load setting comes from the test's own load.env, or none).
DEMO=${RBD_DEMO:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}
TESTS=$DEMO/orch/tests
SCR=${RBD_SCRATCH:-${TMPDIR:-/tmp}/rbd}/partB
mkdir -p "$SCR"
T=$(mktemp -d "$SCR/t.XXXXXX")
export TMPDIR=$T
mkdir -p "$T/bin" "$T/stub"
cp "$TESTS/stubs/kubectl" "$T/bin/kubectl"
for c in ssh gh aws docker; do cp "$TESTS/stubs/fail-loudly" "$T/bin/$c"; done
chmod +x "$T/bin/"*
export PATH="$T/bin:$PATH" STUB_LOG=$T/stub.log STUB_DIR=$T/stub
export AWS_EC2_METADATA_DISABLED=true AWS_SHARED_CREDENTIALS_FILE=/dev/null AWS_CONFIG_FILE=/dev/null
# no load setting from the caller's shell (SPEC3 F6a): capture.sh, bgload.sh and load.sh refuse RBD_LOAD_RPS/RBD_LOAD_MIX that
# differ from load.env, so a stray export would fail unrelated suites; test_load.sh sets them per command where it means to
unset RBD_LOAD_RPS RBD_LOAD_MIX
[ "$(command -v aws)" = "$T/bin/aws" ] && [ "$(command -v kubectl)" = "$T/bin/kubectl" ] || { echo "stubs are not first on PATH" >&2; exit 2; }
: > "$STUB_LOG"
# the policy pins rbd.env carries for repo/policy/gate.json: its sha256, and the effective-policy digest the CLI writes as
# gate.json digests.policy (the offline proof's testdata/leaf/gate/gate.json says the same)
PIN_SHA=$(sha256sum < "$DEMO/repo/policy/gate.json" | cut -d' ' -f1)
PIN_DIGEST=sha256:ccfbd1e11a48e23dd1db5ead4312578016722836c5a70c5ccbbd26076ed0dbdc   # 2026-11-02 cluster test 3: + profile.route_heterogeneous, ab.payload_changed (CLI 91a039e2); SPEC3 F1 sha256:c25759e8: + block_band model (CLI 19baaed); F2/F3 strict was sha256:bcb4f9e9...; max_entry_mean_change_ms 4.0, profile.variance_changed restored, ab.errors_differ (demo2 relaxed: sha256:6318343c...; day 1: sha256:67fdf7dc...d633)
PASS=0 FAILN=0
ok() { PASS=$((PASS + 1)); echo "  ok   $*"; }
bad() { FAILN=$((FAILN + 1)); echo "  FAIL $*"; }
check() { local what=$1; shift; if "$@"; then ok "$what"; else bad "$what"; fi; }
finish() {
  echo "$(basename "$0"): $PASS passed, $FAILN failed"
  [ -n "${KEEP:-}" ] || rm -rf "$T"
  [ "$FAILN" = 0 ]
}
# a tools1 env file for the scripts (RBD_ENV_FILE), RBD_HOME under T
mk_env() {
  mkdir -p "$T/home/state" "$T/home/captures" "$T/home/runs" "$T/home/ledger"
  cat > "$T/rbd.env" << EOF
RBD_REGION=ap-south-1
RBD_ACCOUNT=123456789012
RBD_BUCKET=rhobound-research-123456789012-ap-south-1
RBD_ECR=123456789012.dkr.ecr.ap-south-1.amazonaws.com/rhobound-demo/maze
RBD_KMS=awskms:///alias/rhobound-demo-verdict
KUBECONFIG=$T/kubeconfig
RHOBOUND_STATE=$T/home/state
RBD_HOME=$T/home
RBD_REPO=Sharvil2704/rhobound-maze-bed
RBD_POLICY_SHA256=$PIN_SHA
RBD_POLICY_DIGEST=$PIN_DIGEST
EOF
  export RBD_ENV_FILE=$T/rbd.env RBD_OPT=$DEMO/tools1 RBD_CLI=${RBD_LOCAL_CLI:-$DEMO/build/rhobound-local}
}
