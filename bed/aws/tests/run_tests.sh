#!/usr/bin/env bash
# run_tests.sh: offline tests of aws/spawn_two.sh against the stateful fake aws (tests/fake/aws). Nothing here can reach AWS:
# the fake is first on PATH (checked), the script runs under env -i with no credentials, IMDS disabled and every endpoint/proxy
# pointed at a dead local port. Worlds live under $SCRATCH (default $RBD_SCRATCH/aws-tests, else $TMPDIR/rbd/aws-tests).
#   bash aws/tests/run_tests.sh
set -uo pipefail
TESTS=$(cd "$(dirname "$0")" && pwd)
AWSDIR=$(dirname "$TESTS")
SCRIPT=$AWSDIR/spawn_two.sh
SCRATCH=${SCRATCH:-${RBD_SCRATCH:-${TMPDIR:-/tmp}/rbd}/aws-tests}
FAKE=$TESTS/fake
FAKEBIN=$TESTS/fakebin
ORCH=198.18.0.7      # RFC 2544 benchmarking range: no one's host, and not a documentation range the script refuses
chmod +x "$FAKE/aws" "$FAKEBIN/sleep"
SPATH="$FAKEBIN:$FAKE:/usr/bin:/bin"
[[ $(PATH=$SPATH command -v aws) == "$FAKE/aws" ]] || { echo "refusing to run: aws on the test PATH is not the fake" >&2; exit 2; }
mkdir -p "$SCRATCH"
W=$(mktemp -d "$SCRATCH/world.XXXXXX"); mkdir -p "$W/home" "$W/tmp" "$W/state"
pass=0 fail=0
ok() { pass=$((pass + 1)); echo "  ok   $*"; }
bad() { fail=$((fail + 1)); echo "  FAIL $*"; }
check() { local d=$1; shift; if "$@"; then ok "$d"; else bad "$d"; fi; }
run() { # run [VAR=value ...] -- ARGS...: spawn_two.sh under env -i; sets RC and OUT
  local envs=() n
  while [[ $1 != -- ]]; do envs+=("$1"); shift; done; shift
  n=$(find "$W" -maxdepth 1 -name 'out*.txt' | wc -l); OUT=$W/out$((n + 1)).txt
  env -i PATH="$SPATH" HOME="$W/home" TMPDIR="$W/tmp" LANG=C.UTF-8 FAKE_STATE="$W/state" \
    AWS_EC2_METADATA_DISABLED=true AWS_CONFIG_FILE=/dev/null AWS_SHARED_CREDENTIALS_FILE=/dev/null \
    AWS_ENDPOINT_URL=http://127.0.0.1:9 HTTPS_PROXY=http://127.0.0.1:9 HTTP_PROXY=http://127.0.0.1:9 \
    "${envs[@]}" timeout 120 bash "$SCRIPT" "$@" < /dev/null > "$OUT" 2>&1
  RC=$?
}
has() { grep -qE -- "$1" "$OUT"; }
world() { python3 -I -c "import json,sys; W=json.load(open(sys.argv[1])); $1" "$W/state/world.json" "${@:2}"; }
live() { # live BED-TAG: the names of that bed's machines that are not terminated, sorted
  world 'print(" ".join(sorted(t["Name"] for i in W["instances"] for t in [{x["Key"]: x["Value"] for x in i.get("Tags", [])}]
    if t.get("cluster") == sys.argv[2] and i["State"]["Name"] not in ("terminated", "shutting-down"))))' "$1"; }

echo "== static"
check "bash -n spawn_two.sh" bash -n "$SCRIPT"
if command -v shellcheck > /dev/null; then check "shellcheck spawn_two.sh run_tests.sh" shellcheck "$SCRIPT" "$TESTS/run_tests.sh"; fi
check "no 12-digit account id in spawn_two.sh" bash -c "! grep -qE '(^|[^0-9])[0-9]{12}([^0-9]|$)' '$SCRIPT'"

echo "== refusals"
run ORCH_IP=$ORCH -- plan; check "BED is required (exit $RC)" bash -c "[ $RC -ne 0 ] && grep -q 'BED' '$OUT'"
run BED=1 ORCH_IP=203.0.113.7 -- plan; check "a documentation-range ORCH_IP is refused (exit $RC)" bash -c "[ $RC -ne 0 ] && grep -q 'not a public IPv4' '$OUT'"
run BED=1 ORCH_IP=$ORCH AB_NODE=4 -- plan; check "AB_NODE=4 is refused (exit $RC)" bash -c "[ $RC -ne 0 ] && grep -q 'AB_NODE must be 0, 1, 2 or 3' '$OUT'"
run BED=1 -- destroy; check "destroy is refused (the beds share roles, ECR, KMS; exit $RC)" bash -c "[ $RC -ne 0 ] && grep -q 'destroy is refused' '$OUT'"
run BED=1 ORCH_IP=$ORCH ORCH_PUBKEY_FILE="$W/no-such.pub" -- plan; check "a missing ORCH_PUBKEY_FILE is refused (exit $RC)" bash -c "[ $RC -ne 0 ] && grep -q 'no such readable file' '$OUT'"
ssh-keygen -q -t ed25519 -N '' -C judge -f "$W/judge" < /dev/null
JFPR=$(ssh-keygen -lf "$W/judge.pub" | awk '{print $2}')

echo "== bed 1"
run BED=1 ORCH_IP=$ORCH ORCH_PUBKEY_FILE="$W/judge.pub" -- plan
check "plan names ORCH_PUBKEY_FILE's fingerprint, not the built-in key's" bash -c "grep -qF 'Its key: $JFPR' '$OUT' && ! grep -q 'u5TBLEp1' '$OUT'"
check "plan: 8 machines, load and ab as spot (*) (exit $RC)" bash -c "[ $RC -eq 0 ] && grep -qE 'rbd-d-load1 +d +load\*' '$OUT' &&
  grep -qE 'rbd-d-ab1 +d +ab\*' '$OUT' && grep -qE 'rbd-d-app3 +d +app ' '$OUT' && grep -qE 'rbd-tools1 +tools +tools ' '$OUT'"
run BED=1 ORCH_IP=$ORCH ORCH_PUBKEY_FILE="$W/judge.pub" YES=1 -- up
check "up on a fresh account (exit $RC)" test "$RC" -eq 0
check "  it imports ORCH_PUBKEY_FILE's key, and says which" grep -qF "(your workstation's key, $JFPR)" "$OUT"
check "  8 machines of demo1: cp1 edge1 load1 app1-3 ab1 tools1" test "$(live demo1)" = "rbd-d-ab1 rbd-d-app1 rbd-d-app2 rbd-d-app3 rbd-d-cp1 rbd-d-edge1 rbd-d-load1 rbd-tools1"
check "  load1 and ab1 are spot, the others on demand" world 'sys.exit(not sorted(t["Name"] for i in W["instances"] for t in [{x["Key"]: x["Value"] for x in i.get("Tags", [])}] if i.get("InstanceLifecycle") == "spot") == ["rbd-d-ab1", "rbd-d-load1"])'
python3 -I "$TESTS/check_world.py" "$W/state/world.json" kms ecr net "$ORCH/32" bucket-untouched > "$W/cw.txt" 2>&1
check "  KMS key, ECR repository, network ($ORCH/32 only), bucket untouched (check_world.py)" bash -c "! grep -q '^FAIL' '$W/cw.txt'"
check "  the node role may write both beds' S3 prefixes (demo1/d/ and demo1/b2/d/), nothing else" world '
p = W["roles"]["rbd-demo1-node"]["policies"]["rbd-node"]["Statement"]
put = [r for st in p if st["Action"] == "s3:PutObject" for r in st["Resource"]]
sys.exit(not (len(put) == 2 and put[0].endswith("/demo1/d/*") and put[1].endswith("/demo1/b2/d/*")))'
run BED=1 ORCH_IP=$ORCH YES=1 -- up
check "up again converges: no machine launched (exit $RC)" bash -c "[ $RC -eq 0 ] && ! grep -q 'launched rbd-' '$OUT' && [ \$(grep -c 'not re-created' '$OUT') -eq 8 ]"
run BED=1 ORCH_IP=$ORCH AB_NODE=3 AB_TYPE=m7i.xlarge SPOT_ROLES= YES=1 -- up
check "AB_NODE=3 on the running bed launches ab2 and ab3 only, on demand (exit $RC)" bash -c "[ $RC -eq 0 ] &&
  [ \$(grep -c 'launched rbd-' '$OUT') -eq 2 ] && grep -q 'launched rbd-d-ab2 (m7i.xlarge on-demand,' '$OUT' && grep -q 'launched rbd-d-ab3 (m7i.xlarge on-demand,' '$OUT'"
run BED=1 -- inventory
check "inventory: 10 RS3_NODE rows and the ECR, KMS and bucket lines (exit $RC)" bash -c "[ $RC -eq 0 ] && [ \$(grep -c '^RS3_NODE ' '$OUT') -eq 10 ] &&
  grep -q '^ecr_repo=' '$OUT' && grep -q '^kms_alias=' '$OUT' && grep -q '^RS3_CAMPAIGN=demo1$' '$OUT'"

echo "== bed 2 beside bed 1"
run BED=2 ORCH_IP=$ORCH FAKE_QUOTA=128 YES=1 -- up
check "bed 2 up (exit $RC): 7 machines, no A/B node" test "$RC $(live demo1-b2 | wc -w)" = "0 7"
check "  its own VPC 10.83.0.0/16; one KMS key and one ECR repository for both beds" world '
v = [x["cidr"] for x in W["have"]["vpcs"] if x.get("tags", {}).get("cluster") == "demo1-b2"]
sys.exit(not (v == ["10.83.0.0/16"] and len(W["repos"]) == 1 and len(W["keys"]) == 1 and len(W["aliases"]) == 1))'
check "  bed 1 untouched: still 10 machines" test "$(live demo1 | wc -w)" = 10
run BED=2 YES=1 -- down
check "down of bed 2 terminates bed 2 only (exit $RC)" test "$RC $(live demo1-b2 | wc -w) $(live demo1 | wc -w)" = "0 0 10"
check "  and says the shared resources stay" has 'the two beds share them'
run BED=1 YES=1 -- down
check "down of bed 1 (exit $RC): nothing left running" test "$RC $(live demo1 | wc -w)" = "0 0"

echo "  -- $pass passed, $fail failed"
[[ $fail -eq 0 ]] && rm -rf "$W"
[[ $fail -eq 0 ]]
