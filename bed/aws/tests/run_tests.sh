#!/usr/bin/env bash
# run_tests.sh: offline tests of aws/spawn_demo.sh against the stateful fake aws (tests/fake/aws). Nothing here can reach AWS:
# the fake is first on PATH (checked), the script runs under env -i with no credentials, IMDS disabled and every endpoint/proxy
# pointed at a dead local port. Worlds live under $SCRATCH (default $HOME/rbd-dev/tmp/partA), removed unless KEEP=1.
#   bash aws/tests/run_tests.sh
set -uo pipefail
TESTS=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
AWSDIR=$(dirname "$TESTS")
SCRIPT=$AWSDIR/spawn_demo.sh
FAKE=$TESTS/fake
FAKEBIN=$TESTS/fakebin
SCRATCH=${SCRATCH:-$HOME/rbd-dev/tmp/partA}
mkdir -p "$SCRATCH"
T=$(mktemp -d "$SCRATCH/run.XXXXXX")
[[ ${KEEP:-0} == 1 ]] || trap 'rm -rf "$T"' EXIT
chmod +x "$FAKE/aws" "$FAKEBIN/sleep"
SPATH="$FAKEBIN:$FAKE:/usr/bin:/bin"
[[ $(PATH=$SPATH command -v aws) == "$FAKE/aws" ]] || { echo "refusing to run: aws on the test PATH is not the fake" >&2; exit 2; }

ORCH=198.18.0.7      # RFC 2544 benchmarking range: no one's host, and not a documentation range the script refuses
ACCOUNT=123456789012
BUCKET=rhobound-research-$ACCOUNT-ap-south-1
SECRET_VALUE='s3cr3t-VALUE-7f3a9c1e5b2d4f60a8e1-xyz'
PASS=0; FAIL=0; FAILED=(); CUR=""
ok() { PASS=$((PASS + 1)); printf '  ok   %s\n' "$*"; }
bad() { FAIL=$((FAIL + 1)); FAILED+=("$CUR: $*"); printf '  FAIL %s\n' "$*"; }
section() { CUR=$1; printf '\n== %s\n' "$1"; }
eq() { if [[ $2 == "$3" ]]; then ok "$1"; else bad "$1 (got '$2', wanted '$3')"; fi; }
rcz() { if [[ $RC == 0 ]]; then ok "$1"; else bad "$1 (exit $RC)"; tail -n 6 "$OUT" | sed 's/^/         | /'; fi; }
rcnz() { if [[ $RC != 0 ]]; then ok "$1 (exit $RC)"; else bad "$1 (exit 0: should have refused)"; fi; }
has() { if grep -qE -- "$2" "${3:-$OUT}"; then ok "$1"; else bad "$1 (no /$2/ in ${3:-$OUT})"; fi; }
hasnt() { if grep -qE -- "$2" "${3:-$OUT}" 2> /dev/null; then bad "$1 (/$2/ found in ${3:-$OUT})"; else ok "$1"; fi; }
chk() { local m=$1; shift; if "$@" > /dev/null 2>&1; then ok "$m"; else bad "$m"; fi; }     # passes when the command succeeds
chkn() { local m=$1; shift; if "$@" > /dev/null 2>&1; then bad "$m"; else ok "$m"; fi; }    # passes when the command fails
count() { local n; n=$(grep -cE -- "$2" "${3:-$OUT}" 2> /dev/null); eq "$1" "${n:-0}" "$4"; }
nomuts() { if [[ -s $W/state/muts.log ]]; then bad "$1 (mutations: $(cut -c1-60 "$W/state/muts.log" | head -n 3 | paste -sd'|' -))"; else ok "$1"; fi; }
world() { W=$T/$1; mkdir -p "$W/state" "$W/home" "$W/tmp"; }      # world NAME: a fresh fake AWS account
# run [VAR=value ...] -- ARGS...: the script under env -i, stdin from $IN (default /dev/null); sets RC and OUT
run() {
  local envs=() n
  while [[ $1 != -- ]]; do envs+=("$1"); shift; done; shift
  n=$(find "$W" -maxdepth 1 -name 'out*.txt' | wc -l); OUT=$W/out$((n + 1)).txt
  env -i PATH="$SPATH" HOME="$W/home" TMPDIR="$W/tmp" LANG=C.UTF-8 FAKE_STATE="$W/state" \
    AWS_EC2_METADATA_DISABLED=true AWS_CONFIG_FILE=/dev/null AWS_SHARED_CREDENTIALS_FILE=/dev/null \
    AWS_ENDPOINT_URL=http://127.0.0.1:9 HTTPS_PROXY=http://127.0.0.1:9 HTTP_PROXY=http://127.0.0.1:9 https_proxy=http://127.0.0.1:9 http_proxy=http://127.0.0.1:9 \
    "${envs[@]}" timeout 120 bash "$SCRIPT" "$@" < "${IN:-/dev/null}" > "$OUT" 2>&1
  RC=$?
}
cw() { python3 -I "$TESTS/check_world.py" "$W/state/world.json" "$@" > "$W/cw.txt" 2>&1; local rc=$?; sed 's/^/     /' "$W/cw.txt"
       if [[ $rc == 0 ]]; then ok "world: $*"; else bad "world: $* ($(grep -c '^FAIL' "$W/cw.txt") failed)"; fi; }
pyw() { python3 -I -c "import json,sys; W=json.load(open(sys.argv[1])); $1" "$W/state/world.json"; }

# ----------------------------------------------------------------------------------------------------------------------------- static
section "static: syntax, shellcheck, no real addresses or ids"
chk "bash -n spawn_demo.sh" bash -n "$SCRIPT"
chk "bash -n run_tests.sh" bash -n "$TESTS/run_tests.sh"
if shellcheck "$SCRIPT" > "$T/sc.txt" 2>&1; then ok "shellcheck spawn_demo.sh clean"; else bad "shellcheck spawn_demo.sh"; head -n 20 "$T/sc.txt"; fi
if shellcheck "$TESTS/run_tests.sh" "$FAKEBIN/sleep" > "$T/sc2.txt" 2>&1; then ok "shellcheck run_tests.sh fakebin/sleep clean"; else bad "shellcheck tests"; head -n 20 "$T/sc2.txt"; fi
for p in "$FAKE/aws" "$TESTS/check_world.py"; do
  chk "python parses: ${p#"$AWSDIR"/}" python3 -I -c "import ast,sys; ast.parse(open(sys.argv[1]).read())" "$p"
done
# every IPv4 literal in the deliverables must be one of these (CIDRs of the demo VPC, IMDS, the time server, wildcards, examples)
ips=$(grep -ohE '\b[0-9]{1,3}(\.[0-9]{1,3}){3}\b' "$SCRIPT" "$AWSDIR/STEPS.md" 2> /dev/null | sort -u \
      | grep -vxE '10\.82\.[01]\.0|0\.0\.0\.0|127\.0\.1\.1|169\.254\.169\.(254|123)|203\.0\.113\.[0-9]+|127\.0\.0\.1|192\.0\.2\.[0-9]+|198\.51\.100\.[0-9]+|192\.168\.[0-9.]+|172\.16\.[0-9.]+|10\.0\.0\.[0-9]+' || true)
eq "no real IP address in spawn_demo.sh / STEPS.md" "$ips" ""
ids=$(grep -ohE '\b[0-9]{12}\b' "$SCRIPT" "$AWSDIR/STEPS.md" 2> /dev/null | sort -u | grep -vx 123456789012 || true)
eq "no AWS account id in spawn_demo.sh / STEPS.md" "$ids" ""
hasnt "no ip-172-... hostname in the built-in key" 'ip-172-' "$SCRIPT"

section "help and refusals before any AWS call"
world refuse
run -- help; rcz "help exits 0"; has "help shows the commands" 'spawn_demo.sh secret NAME'
run -- plan; rcnz "plan without ORCH_IP refused"; has "says ORCH_IP is required" 'ORCH_IP is required'
run -- up; rcnz "up without ORCH_IP refused"
for bad_ip in 10.1.2.3 203.0.113.9 192.0.2.4 1.2.3 300.1.1.1 172.16.0.5 '1.2.3.4;id'; do
  run ORCH_IP="$bad_ip" -- plan; rcnz "ORCH_IP=$bad_ip refused"
done
run ORCH_IP=$ORCH ADMIN_CIDR=13.0.0.0/8 -- plan; rcnz "ADMIN_CIDR wider than /24 refused"
run ORCH_IP=$ORCH MAX_HOURS=60 -- plan; rcnz "MAX_HOURS above HARD_MAX_HOURS refused"
run -- frobnicate; rcnz "unknown command refused"
nomuts "no mutation in any refusal"

# ------------------------------------------------------------------------------------------------------------------------------ plan
section "plan"
world plan
run ORCH_IP=$ORCH -- plan; rcz "plan exits 0"
nomuts "plan mutates nothing"
has "plan sees 34 vCPU" 'the whole plan is 34'
has "plan prices about 1.06 USD per hour" 'about 1\.06 USD per hour'
has "plan prints the per-day cost" 'per day \(24 h\): about 25\.[0-9] USD'
has "plan: quota ok" 'QUOTA OK'
has "plan: both roles will be created" 'role rbd-demo1-tools will be created'
has "plan: ECR will be created" 'rhobound-demo/kshop will be created'
has "plan: KMS key will be created" 'alias/rhobound-demo-verdict will be created'
has "plan: done, next is up" 'plan done: nothing was created'
has "plan: 8 machine rows incl. ab1" 'rbd-d-ab1 +d +ab +m6a.xlarge'
cp "$OUT" "$T/plan-output.txt"
world noprice
run ORCH_IP=$ORCH FAKE_NOPRICE=1 -- plan; rcz "plan with no price list"
has "falls back to the high estimate" 'partly estimated'
has "the high estimate still fits the default budget" 'plan done: nothing was created'
world lowquota
run ORCH_IP=$ORCH FAKE_QUOTA=32 YES=1 -- up; rcnz "up refused when the vCPU quota is too low"; has "quota message" 'do not fit the on-demand vCPU quota'
nomuts "quota refusal creates nothing"
world budget
run ORCH_IP=$ORCH BUDGET=0.5 YES=1 -- up; rcnz "up refused over budget"; has "budget message" 'over the budget of 0.5'
nomuts "budget refusal creates nothing"
run ORCH_IP=$ORCH BUDGET=0.5 YES=1 FORCE=1 -- up; rcz "FORCE=1 overrides the budget"

section "DRYRUN=1 up on a fresh account"
world dry
run ORCH_IP=$ORCH DRYRUN=1 -- up; rcz "dry run exits 0"
nomuts "dry run mutates nothing"
count "dry run prints 8 run-instances" 'DRYRUN .* ec2 run-instances' "$OUT" 8
count "dry run prints 2 create-role" 'DRYRUN .* iam create-role' "$OUT" 2
has "dry run prints create-key" 'DRYRUN .* kms create-key --key-spec ECC_NIST_P256 --key-usage SIGN_VERIFY'
has "dry run prints create-repository" 'DRYRUN .* ecr create-repository --repository-name rhobound-demo/kshop'
has "dry run: tools1 gets the tools profile, hop 1" 'iam-instance-profile Name=rbd-demo1-tools .*HttpPutResponseHopLimit=1'
has "dry run: a cluster node gets the node profile, hop 1" 'iam-instance-profile Name=rbd-demo1-node .*HttpPutResponseHopLimit=1'
hasnt "dry run: no machine gets hop 2" 'HttpPutResponseHopLimit=2'

# -------------------------------------------------------------------------------------------------------------------------- up, fresh
section "up on a fresh account (YES=1)"
world main
run ORCH_IP=$ORCH YES=1 -- up; rcz "up exits 0"
has "up says next is inventory" 'Next: bash .* inventory'
cw policies kms ecr machines net "$ORCH/32" bucket-untouched
hasnt "no s3/s3api mutation on the research bucket" '^s3(api)? ' "$W/state/muts.log"
eq "the key pair is the built-in orchestrator key" "$(awk '{print $1, $2}' "$W/state/files/pubkey")" "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIHqk31PYoy8pRICeNSbezHLACtndXUwV3a1K8YrsBH+L"
cp "$W/state/muts.log" "$T/muts-first.log"

section "user-data renders, per role"
for n in rbd-d-cp1 rbd-d-edge1 rbd-d-load1 rbd-d-app1 rbd-d-app2 rbd-d-app3 rbd-d-ab1 rbd-tools1; do
  u=$W/state/files/ud-$n.sh
  [[ -s $u ]] || { bad "$n: no user-data captured"; continue; }
  kc=d; role=$(sed -E 's/^rbd-(d-)?//; s/[0-9]+$//' <<< "$n")
  [[ $n == rbd-tools1 ]] && kc=tools
  chk "$n: bash -n" bash -n "$u"
  if shellcheck -s bash "$u" > "$T/scu.txt" 2>&1; then ok "$n: shellcheck clean"; else bad "$n: shellcheck"; head -n 12 "$T/scu.txt"; fi
  hasnt "$n: no placeholder left" '__[A-Z_]+__' "$u"
  has "$n: hostname" "hostnamectl set-hostname $n\$" "$u"
  has "$n: S3 prefix demo1/$kc/$n" "^RB_PREFIX=demo1/$kc/$n\$" "$u"
  has "$n: role $role" "^RB_ROLE=$role\$" "$u"
  has "$n: bucket" "^RB_BUCKET=$BUCKET\$" "$u"
  has "$n: 16-h cap (960 min)" '^shutdown -h \+960 ' "$u"
  has "$n: 48-h hard ceiling (2880 min)" 'now \+ 2880 \* 60' "$u"
  has "$n: deadline file + rb-deadline" '/usr/local/bin/rb-deadline check' "$u"
done

section "up again converges (no new resource)"
: > "$W/state/muts.log"
run ORCH_IP=$ORCH YES=1 -- up; rcz "second up exits 0"
hasnt "second up creates/launches/authorizes nothing" ' (create-|run-instances|import-|authorize-|attach-)' "$W/state/muts.log"
eq "second up only re-applies the role and key policies" "$(awk '{print $1, $2}' "$W/state/muts.log" | sort | uniq -c | awk '{print $1, $2, $3}' | paste -sd, -)" "2 iam put-role-policy,1 kms put-key-policy"
cw machines kms ecr net "$ORCH/32"

section "inventory (no ORCH_IP given: read from the security group)"
run -- inventory; rcz "inventory exits 0"
INV=$OUT; cp "$INV" "$T/inventory.txt"
has "RS3_ORCH_IP from the security group" "^RS3_ORCH_IP=$ORCH\$"
count "8 RS3_NODE rows" '^RS3_NODE ' "$INV" 8
has "ab1 row with role=ab" '^RS3_NODE rbd-d-ab1 kc=d role=ab type=m6a.xlarge '
has "tools1 row" '^RS3_NODE rbd-tools1 kc=tools role=tools type=m6a.2xlarge '
has "ecr_repo line" "^ecr_repo=$ACCOUNT\.dkr\.ecr\.ap-south-1\.amazonaws\.com/rhobound-demo/kshop\$"
has "kms_alias line" '^kms_alias=alias/rhobound-demo-verdict$'
has "bucket line" "^bucket=$BUCKET\$"
has "account line" "^account=$ACCOUNT\$"
has "RS3_CAMPAIGN=demo1" '^RS3_CAMPAIGN=demo1$'
hasnt "no warning in the block" 'WARNING'

section "status, extend"
run -- status; rcz "status exits 0"
has "status table has ab1" 'rbd-d-ab1 '
has "status shows the KMS key" 'KMS alias/rhobound-demo-verdict: key .*Enabled'
run -- extend 4; rcz "extend 4 exits 0"
# shellcheck disable=SC2016  # the literal line the script prints
has "extend prints the ssh loop over all 8" 'for n in rbd-d-ab1 rbd-d-app1 rbd-d-app2 rbd-d-app3 rbd-d-cp1 rbd-d-edge1 rbd-d-load1 rbd-tools1; do ssh -F ~/.ssh/rbd_aws_config "\$n" sudo rb-deadline extend 4; done'
for a in 0 49 x; do run -- extend "$a"; rcnz "extend $a refused"; done

section "allow-ip, deny-ip, and up with a new ORCH_IP"
run -- allow-ip 10.0.0.5; rcnz "allow-ip of a private address refused"
run -- allow-ip 198.18.0.8; rcz "allow-ip 198.18.0.8"
run -- allow-ip 198.18.0.8; rcz "allow-ip again is a no-op"; has "says already allowed" 'already allowed'
cw net "$ORCH/32,198.18.0.8/32"
run -- deny-ip 198.18.0.8; rcz "deny-ip 198.18.0.8"
run -- deny-ip 198.18.0.8; rcz "deny-ip again is a no-op"
cw net "$ORCH/32"
: > "$W/state/muts.log"
run ORCH_IP=198.18.0.9 YES=1 -- up; rcz "up with a new ORCH_IP"
has "it notes the old address and how to remove it" "deny-ip $ORCH/32"
count "it adds exactly one ssh rule" 'authorize-security-group-ingress' "$W/state/muts.log" 1
hasnt "no machine re-launched" 'run-instances' "$W/state/muts.log"
run -- inventory; has "two orchestrator rules: the block warns" '^# WARNING: ssh is open to several orchestrator addresses'
run -- deny-ip $ORCH; rcz "deny-ip the old address"
cw net "198.18.0.9/32"
run -- inventory; has "inventory follows the orchestrator rule" '^RS3_ORCH_IP=198\.18\.0\.9$'

section "a lost machine is re-launched alone"
pyw "[i['State'].update(Name='terminated') for i in W['instances'] if {'Key':'Name','Value':'rbd-d-app2'} in i['Tags']]; json.dump(W, open(sys.argv[1],'w'))"
: > "$W/state/muts.log"
run ORCH_IP=198.18.0.9 YES=1 -- up; rcz "up after app2 was lost"
count "exactly one run-instances" 'run-instances' "$W/state/muts.log" 1
has "it is app2" 'Value=rbd-d-app2' "$W/state/muts.log"
cw machines

# ---------------------------------------------------------------------------------------------------------------------------- secrets
section "secret NAME (value on stdin: never printed, never in argv)"
printf '  %s  \n' "$SECRET_VALUE" > "$T/secret.in"
IN=$T/secret.in run -- secret judge-key; rcz "secret judge-key stored"
eq "stored value is the trimmed input" "$(pyw "print(W['secrets']['rhobound-demo/judge-key']['values'][-1])")" "$SECRET_VALUE"
eq "secret tagged" "$(pyw "print(W['secrets']['rhobound-demo/judge-key']['tags'])")" "{'project': 'rhobound-demo', 'cluster': 'demo1'}"
eq "the CLI got the value only as a file:// path" "$(pyw "print(all(a.startswith('file://') for a in W['secret_args']))")" "True"
for f in "$W"/out*.txt "$W/state/calls.log" "$W/state/muts.log"; do hasnt "value absent from ${f##*/}" "7f3a9c1e5b2d4f60a8e1" "$f"; done
hasnt "the temp file is gone" '.' <(find "$W/tmp" -name 'secret.val' 2> /dev/null)
printf 'second-%s\n' "$SECRET_VALUE" > "$W/secret2.in"
IN=$W/secret2.in run -- secret judge-key; rcz "secret again stores a new version"
eq "two versions" "$(pyw "print(len(W['secrets']['rhobound-demo/judge-key']['values']))")" "2"
has "put-secret-value used" 'secretsmanager put-secret-value --secret-id rhobound-demo/judge-key --secret-string file://' "$W/state/muts.log"
IN=$T/secret.in run DRYRUN=1 -- secret dry-key; rcz "DRYRUN secret exits 0"
hasnt "DRYRUN line hides the value" "7f3a9c1e5b2d4f60a8e1"
has "DRYRUN line redacts --secret-string" '--secret-string <redacted>'
eq "DRYRUN stored nothing" "$(pyw "print('rhobound-demo/dry-key' in W['secrets'])")" "False"
printf '   \n' > "$W/empty.in"
IN=$W/empty.in run -- secret empty-key; rcnz "an empty value is refused"
for nm in '../x' 'a b' '' 'x/y'; do IN=$T/secret.in run -- secret "$nm"; rcnz "secret name '$nm' refused"; done
run -- status; has "status lists the secret" 'secrets rhobound-demo/\*: rhobound-demo/judge-key'
for f in "$W"/out*.txt "$W/state/calls.log"; do hasnt "value still absent from ${f##*/}" "7f3a9c1e5b2d4f60a8e1" "$f"; done

section "secret-rm NAME"
IN=/dev/null run -- secret-rm judge-key; rcnz "secret-rm without a yes is aborted"
run YES=1 -- secret-rm judge-key; rcz "secret-rm judge-key"
eq "7-day recovery window" "$(pyw "print(W['secrets']['rhobound-demo/judge-key']['window'])")" "7"
run YES=1 -- secret-rm judge-key; rcz "secret-rm again"; has "already pending" 'already pending deletion'
run YES=1 -- secret-rm nothere; rcz "secret-rm of a missing secret is a no-op"
IN=$T/secret.in run -- secret judge-key; rcz "secret restores a deleted one"
has "restored" 'was pending deletion: restored'
eq "live again" "$(pyw "print(W['secrets']['rhobound-demo/judge-key']['deleted'])")" "None"

# ------------------------------------------------------------------------------------------------------------------------ down, destroy
section "down"
run YES=1 -- down; rcz "down exits 0"
eq "every machine shutting down or gone" "$(pyw "print(sorted({i['State']['Name'] for i in W['instances']}))")" "['shutting-down', 'terminated']"
eq "roles stay after down" "$(pyw "print(sorted(W['roles']))")" "['rbd-demo1-node', 'rbd-demo1-tools']"
run YES=1 -- down; rcz "down again"; has "nothing left to terminate" 'no machines of demo1'

section "destroy (interactive: keep the ECR repo and the secrets)"
world keep
run ORCH_IP=$ORCH YES=1 -- up; rcz "up"
IN=$T/secret.in run -- secret model-key; rcz "a secret"
printf 'demo1\ny\nn\nn\n' > "$W/answers"
IN=$W/answers run -- destroy; rcz "destroy with answers demo1 / y / n / n"
eq "ECR kept" "$(pyw "print(list(W['repos']))")" "['rhobound-demo/kshop']"
eq "secret kept" "$(pyw "print(W['secrets']['rhobound-demo/model-key']['deleted'])")" "None"
eq "roles gone" "$(pyw "print(W['roles'], W['profiles'])")" "{} {}"
eq "alias gone, key pending deletion (7 days)" "$(pyw "print(W['aliases'], [(k['state'], k['window']) for k in W['keys'].values()])")" "{} [('PendingDeletion', 7)]"
printf 'n\n' > "$W/no"
world abort
run ORCH_IP=$ORCH YES=1 -- up; rcz "up"
: > "$W/state/muts.log"
IN=$W/no run -- destroy; rcnz "destroy aborted on 'n' at the campaign prompt"
nomuts "aborted destroy changed nothing"

section "destroy (YES=1): everything but the bucket"
W=$T/main
pyw "W['repos']['rhobound-demo/kshop']['images'] = ['sha256:' + 'ab' * 32]; json.dump(W, open(sys.argv[1], 'w'))"
IN=$T/secret.in run -- secret model-key; rcz "one more secret"
run ORCH_IP=198.18.0.9 YES=1 -- up; rcz "machines back up before destroy"
run YES=1 -- destroy; rcz "destroy exits 0"
eq "all machines terminated" "$(pyw "print(sorted({i['State']['Name'] for i in W['instances']}))")" "['terminated']"
eq "network gone" "$(pyw "print(W['sgs'], W['have'].get('vpcs'), W['have'].get('subnets'), W['have'].get('internet-gateways'), W['have'].get('keys'))")" "{} [] [] [] []"
eq "roles and profiles gone" "$(pyw "print(W['roles'], W['profiles'])")" "{} {}"
eq "ECR repo (with an image) deleted" "$(pyw "print(W['repos'])")" "{}"
has "ECR deleted with --force" 'ecr delete-repository --repository-name rhobound-demo/kshop --force' "$W/state/muts.log"
eq "alias gone; key pending deletion, 7 days" "$(pyw "print(W['aliases'], [(k['state'], k['window']) for k in W['keys'].values()])")" "{} [('PendingDeletion', 7)]"
eq "secrets pending deletion, 7 days" "$(pyw "print(sorted((n, s['window']) for n, s in W['secrets'].items() if s['deleted']))")" "[('rhobound-demo/judge-key', 7), ('rhobound-demo/model-key', 7)]"
hasnt "the bucket was never written" '^s3(api)? ' "$W/state/muts.log"
cw bucket-untouched
has "destroy says what stays" 'what stays: the bucket'
run YES=1 -- destroy; rcz "destroy again is a clean no-op"
run -- inventory; rcnz "inventory with no machines fails loudly"

section "missing research bucket: up refuses unless CREATE_BUCKET=1, then asks, creates it private and tagged"
world nobucket
run ORCH_IP=$ORCH FAKE_BUCKET=0 YES=1 -- up; rcnz "up with YES=1 but no CREATE_BUCKET refuses a missing bucket"
has "the refusal names CREATE_BUCKET" 'CREATE_BUCKET=1'
nomuts "nothing mutated by the refusal"
IN=$W/no run ORCH_IP=$ORCH FAKE_BUCKET=0 CREATE_BUCKET=1 -- up; rcnz "up stops at a 'no' to the bucket or the first question"
run ORCH_IP=$ORCH FAKE_BUCKET=0 CREATE_BUCKET=1 YES=1 -- up; rcz "up with CREATE_BUCKET=1 YES=1 creates the bucket"
eq "bucket private + tagged" "$(pyw "b=W['buckets']['$BUCKET']; print(b['pab'], b['tags'])")" "BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true TagSet=[{Key=project,Value=rhobound-demo}]"

section "AWS faults: KMS role lag, profile lag, no capacity, odd failure"
world kmslag
run ORCH_IP=$ORCH YES=1 FAKE_KMS_LAG=2 -- up; rcz "up survives KMS not seeing the new role yet"
count "it retried twice" 'KMS does not see role' "$OUT" 2
cw kms
world proflag
run ORCH_IP=$ORCH YES=1 FAKE_PROFILE_LAG=2 -- up; rcz "up survives a slow instance profile"
cw machines
world nocap
run ORCH_IP=$ORCH YES=1 FAKE_NOCAP=m6a.xlarge -- up; rcz "up with no m6a.xlarge capacity"
eq "xlarge machines fell back to m6i.xlarge" "$(pyw "print(sorted({i['InstanceType'] for i in W['instances']}))")" "['m6a.2xlarge', 'm6a.large', 'm6i.xlarge']"
world oddfail
run ORCH_IP=$ORCH YES=1 FAKE_FAILRUN=3 -- up; rcnz "an odd run-instances error stops up loudly"
has "it says how to continue" 'run  bash .* up  again to continue'
run ORCH_IP=$ORCH YES=1 -- up; rcz "the next up fills the gap"
cw machines
world vcpulimit
run ORCH_IP=$ORCH YES=1 FAKE_VCPULIMIT_AFTER=5 -- up; eq "a partial launch exits 3" "$RC" "3"
has "it names the missing machines" 'NOT LAUNCHED: '

section "the policy checker is not vacuous"
W=$T/kmslag
pyw "W['roles']['rbd-demo1-node']['policies']['rbd-node']['Statement'].append({'Effect':'Allow','Action':'ecr:BatchGetImage','Resource':'*'}); json.dump(W, open(sys.argv[1]+'.bad1','w'))"
chkn "a node ECR grant is caught" python3 -I "$TESTS/check_world.py" "$W/state/world.json.bad1" policies
pyw "W['roles']['rbd-demo1-tools']['policies']['rbd-tools']['Statement'][1]['Action'].append('s3:DeleteObject'); json.dump(W, open(sys.argv[1]+'.bad2','w'))"
chkn "a Delete action is caught" python3 -I "$TESTS/check_world.py" "$W/state/world.json.bad2" policies
pyw "k=list(W['keys'])[0]; W['keys'][k]['policy']['Statement'].append({'Effect':'Allow','Principal':{'AWS':'arn:aws:iam::123456789012:role/rbd-demo1-node'},'Action':'kms:Sign','Resource':'*'}); json.dump(W, open(sys.argv[1]+'.bad3','w'))"
chkn "a node key grant is caught" python3 -I "$TESTS/check_world.py" "$W/state/world.json.bad3" kms

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
if ((FAIL)); then printf '  %s\n' "${FAILED[@]}"; exit 1; fi
echo "plan output kept in $T/plan-output.txt (KEEP=1 to keep it)"
