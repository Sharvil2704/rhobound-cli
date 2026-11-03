#!/usr/bin/env bash
# spawn_two.sh: TWO identical maze beds for the Muse experiment (bed 1 = Muse + rhobound plugin, bed 2 = Muse alone), made from
# the one-bed demo's spawn script (spawn_demo.sh, not kept) with one new setting, BED (1 or 2, required). Each bed is a full cluster (k3s, Collector, load, 3 app nodes,
# A/B node, rbd-tools1) in its own VPC; both use the same machine names, roles, key pair, ECR repository, KMS key and secrets.
#   bed 1: cluster tag demo1    (as the one-bed demo), VPC 10.82.0.0/16, uploads to s3://BUCKET/demo1/KC/NAME/
#   bed 2: cluster tag demo1-b2,                     VPC 10.83.0.0/16, uploads to s3://BUCKET/demo1/b2/KC/NAME/
# Every command acts on the one bed BED names. `destroy` is refused here (the two beds share roles, key and repository): use
# `down` for each bed.
# Spot: the roles in SPOT_ROLES (default "load ab": the load generator and the A/B node) launch as one-time spot instances
# (terminated if AWS reclaims them); the core (k3s server, Collector, app nodes, tools) stays on-demand. Per bed on-demand:
# 2 + 4 + 3x4 + 8 = 26 vCPUs (52 for both beds); spot: load 4 (+ ab 4 on bed 1). Bed 2 has no A/B node by default.
#
#   ORCH_IP=<ip> BED=1 bash spawn_two.sh up     then     ORCH_IP=<ip> BED=2 bash spawn_two.sh up
#   BED=1 bash spawn_two.sh inventory           then     BED=2 bash spawn_two.sh inventory        (paste both)
#   BED=1 bash spawn_two.sh down                and      BED=2 bash spawn_two.sh down
#
# The commands below act on the bed BED names; read "bed BED" for "cluster d" and "demo1".
#
# rhobound demo1 on AWS (ap-south-1 in the experiments; REGION= for another): the machines, roles, ECR repository, KMS signing key and secrets of the
# one-day live demo, created by YOU in AWS CloudShell. `plan` creates nothing. Your workstation (ORCH_IP; the scripts call it the orchestrator) only connects
# to the machines over ssh; it never holds AWS credentials.
#
#   ORCH_IP=<workstation public IPv4> BED=1 bash spawn_two.sh plan   # machines, zone, price vs budget, vCPU quota, bucket, roles, ECR, KMS
#   ORCH_IP=<workstation public IPv4> BED=1 bash spawn_two.sh up     # create roles, KMS key, ECR repo, network, missing machines (asks; YES=1 skips); run again to fill gaps
#   BED=1 bash spawn_two.sh inventory        # the block to copy to your workstation (machines, IPs, ECR repo, KMS alias, bucket, account; no secret)
#   BED=1 bash spawn_two.sh status           # machines, states, hours up, hours left of the time cap, vCPUs in use, ECR and KMS state
#   BED=1 bash spawn_two.sh extend HOURS     # prints the command your WORKSTATION runs to move the time cap (CloudShell cannot ssh to the machines)
#   BED=1 bash spawn_two.sh allow-ip IP      # let one more address ssh in (your workstation's new public IP, e.g. after a stop/start)
#   BED=1 bash spawn_two.sh deny-ip IP       # take that address out again
#   BED=1 bash spawn_two.sh secret NAME      # type a value (hidden) and store it as the secret rhobound-demo/NAME (only rbd-tools1 may read it)
#   BED=1 bash spawn_two.sh secret-rm NAME   # schedule rhobound-demo/NAME for deletion (7-day recovery window; asks)
#   BED=1 bash spawn_two.sh down             # terminate every machine (asks). Network, roles, ECR, KMS key and secrets stay
#   (destroy: refused by spawn_two.sh, see above)  # spawn_demo.sh's destroy: terminate the machines; delete network, key pair, roles, the KMS alias (the key is scheduled for
#                                       # deletion in 7 days), the ECR repo (asks) and the secrets (7-day window; asks). THE S3 BUCKET IS NEVER TOUCHED
#
# The machines (one cluster d, tagged project=rhobound-demo cluster=demo1; names are the Kubernetes node names):
#   rbd-d-cp1      k3s server                       m6a.large    2 vCPU   40 GB   profile rbd-demo1-node   IMDS hop limit 1
#   rbd-d-edge1    OpenTelemetry Collector          m6a.xlarge   4 vCPU  100 GB   profile rbd-demo1-node   hop 1
#   rbd-d-load1    load generator                   m6a.xlarge   4 vCPU   40 GB   profile rbd-demo1-node   hop 1
#   rbd-d-app1..3  maze services                   m6a.xlarge   4 vCPU   60 GB   profile rbd-demo1-node   hop 1
#   rbd-d-ab1..N   A/B arms (role ab), one A/B each m6a.xlarge   4 vCPU   60 GB   profile rbd-demo1-node   hop 1
#   rbd-tools1     CI runner, builds, CLI, MCP      m6a.2xlarge  8 vCPU  200 GB   profile rbd-demo1-tools  hop 1
# 34 vCPU on-demand, Ubuntu 24.04 amd64, one zone, own VPC 10.82.0.0/16 (subnet 10.82.1.0/24), public IPs, IMDSv2 required.
# ssh only from ORCH_IP/32 (+ ADMIN_CIDR); all traffic between members. No capacity: the same size of the next FALLBACK family.
#
# Rights, no delete permission anywhere. rbd-demo1-node: list s3://BUCKET/demo1/d/ and put objects under it. rbd-demo1-tools: get, put,
# list under demo1/; push/pull/describe the ECR repo rhobound-demo/maze; Sign/Verify/GetPublicKey/DescribeKey on the KMS key
# alias/rhobound-demo-verdict; GetSecretValue on rhobound-demo/*. The research bucket is never changed (no policy, lifecycle or
# setting); if it is missing, `up` refuses unless CREATE_BUCKET=1 (then it asks and creates it private, tagged). Each machine uploads /var/lib/rb/out to s3://BUCKET/demo1/KC/NAME/.
#
# Time cap: every machine powers itself off MAX_HOURS after its launch and is then TERMINATED (disk deleted after the last upload).
# Your workstation may move the cap over ssh with `sudo rb-deadline extend HOURS`, never past HARD_MAX_HOURS after launch (fixed here).
#
# Settings (environment; defaults in brackets):
#   ORCH_IP [REQUIRED for plan and up, no default: your workstation's public IPv4]  ADMIN_CIDR [none: e.g. x.x.x.x/32]
#   BED [REQUIRED: 1 or 2]  AB_NODE [1 on bed 1, 0 on bed 2: how many A/B nodes, 0..3, rbd-d-ab1..abN, which only bed 1's gate uses; the gate runs one A/B per node at once]  SPOT_ROLES ["load ab"]  MAX_HOURS [8]  HARD_MAX_HOURS [24]  BUDGET [2.5 USD per hour for everything: `up` refuses above it]  RESERVE_VCPU [0]  REGION [ap-south-1]
#   CP_TYPE [m6a.large]  EDGE_TYPE LOAD_TYPE APP_TYPE AB_TYPE [m6a.xlarge]  TOOLS_TYPE [m6a.2xlarge]  FALLBACK ["m6i m7a m7i m5a m5"]
#   DISK_CP [40]  DISK_EDGE [100]  DISK_LOAD [40]  DISK_APP [60]  DISK_AB [60]  DISK_TOOLS [200] (GB, gp3, encrypted)  AZ [chosen]
#   BUCKET [rhobound-research-ACCOUNT-REGION]  CREATE_BUCKET [0: 1 lets up create a missing bucket; YES=1 does not imply it]  AMI_ID [Ubuntu 24.04 amd64, found through SSM]  ORCH_PUBKEY_FILE [built in]
#   DRYRUN [0: 1 prints every mutating call and runs none]  YES [0: 1 answers yes to every question]  FORCE [0: 1 overrides quota/budget refusals]
set -euo pipefail

say() { echo "[$(date -u +%H:%M:%S)] $*" >&2; }
die() { echo "error: $*" >&2; exit 1; }
need() { command -v "$1" > /dev/null 2>&1 || die "$1 is required"; }

CMD=${1:-help}
ARG=${2:-}
if [[ $CMD == help || $CMD == -h || $CMD == --help ]]; then sed -n '2,/^set -euo/p' "$0" | sed '$d' | sed 's/^# \{0,1\}//'; exit 0; fi

REGION=${REGION:-ap-south-1}
MAX_HOURS=${MAX_HOURS:-8}
HARD_MAX_HOURS=${HARD_MAX_HOURS:-24}
BED=${BED:-}
AB_NODE=${AB_NODE:-}
SPOT_ROLES=${SPOT_ROLES-load ab}
BUDGET=${BUDGET:-2.5}
RESERVE_VCPU=${RESERVE_VCPU:-0}
ORCH_IP=${ORCH_IP:-}
ADMIN_CIDR=${ADMIN_CIDR:-}
CP_TYPE=${CP_TYPE:-m6a.large}
EDGE_TYPE=${EDGE_TYPE:-m6a.xlarge}
LOAD_TYPE=${LOAD_TYPE:-m6a.xlarge}
APP_TYPE=${APP_TYPE:-m6a.xlarge}
AB_TYPE=${AB_TYPE:-m6a.xlarge}
TOOLS_TYPE=${TOOLS_TYPE:-m6a.2xlarge}
FALLBACK=${FALLBACK:-"m6i m7a m7i m5a m5"}
DISK_CP=${DISK_CP:-40}
DISK_EDGE=${DISK_EDGE:-100}
DISK_LOAD=${DISK_LOAD:-40}
DISK_APP=${DISK_APP:-60}
DISK_AB=${DISK_AB:-60}
DISK_TOOLS=${DISK_TOOLS:-200}
AZ=${AZ:-}
BUCKET=${BUCKET:-}
CREATE_BUCKET=${CREATE_BUCKET:-0}
DRYRUN=${DRYRUN:-0}
YES=${YES:-0}
FORCE=${FORCE:-0}
OD_EST_PER_VCPU=${OD_EST_PER_VCPU:-0.055}   # used only when the price list cannot be read: deliberately on the high side
EBS_GB_MONTH=0.0912                        # gp3 USD per GB-month (an estimate)
IPV4_HOUR=0.005                            # one public IPv4 address, USD per hour
# fixed by the one-bed demo's spec (other parts use these names)
CAMPAIGN=demo1
PREFIX=rbd
KC=d
N_APP=3
PROJECT=rhobound-demo
case $BED in
  1) CLUSTER_TAG=$CAMPAIGN S3BASE=$CAMPAIGN VPC_CIDR=10.82.0.0/16 SUBNET_CIDR=10.82.1.0/24 ;;
  2) CLUSTER_TAG=$CAMPAIGN-b2 S3BASE=$CAMPAIGN/b2 VPC_CIDR=10.83.0.0/16 SUBNET_CIDR=10.83.1.0/24 ;;
  *) die "BED must be 1 or 2 (bed 1: Muse + rhobound, bed 2: Muse alone), got '$BED'. Run:  BED=1 bash $0 $CMD" ;;
esac
KEY_NAME=$PREFIX-$CAMPAIGN-orchestrator
SG_NAME=$PREFIX-$CLUSTER_TAG-sg
NODE_ROLE=$PREFIX-$CAMPAIGN-node
TOOLS_ROLE=$PREFIX-$CAMPAIGN-tools
NODE_POLICY=rbd-node
TOOLS_POLICY=rbd-tools
ECR_REPO=rhobound-demo/maze
KMS_ALIAS=alias/rhobound-demo-verdict
SECRET_PREFIX=rhobound-demo/
KEY_DELETE_DAYS=7
SECRET_DELETE_DAYS=7
SSM_AMI=/aws/service/canonical/ubuntu/server/24.04/stable/current/amd64/hvm/ebs-gp3/ami-id
QUOTA_OD_CODE=L-1216C47A     # Running On-Demand Standard (A, C, D, H, I, M, R, T, Z) instances, in vCPUs
QUOTA_SPOT_CODE=L-34B43A08   # All Standard (A, C, D, H, I, M, R, T, Z) Spot Instance Requests, in vCPUs
is_spot() { [[ " $SPOT_ROLES " == *" $1 "* ]]; }

# The key the machines trust when ORCH_PUBKEY_FILE is not set: the authors' workstation key (~/.ssh/id_ed25519_rhobound.pub
# there). Set ORCH_PUBKEY_FILE to your own public key. A public key is not a secret.
ORCH_PUBKEY_BUILTIN='ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIHqk31PYoy8pRICeNSbezHLACtndXUwV3a1K8YrsBH+L rhobound-workstation'
ORCH_FPR='SHA256:u5TBLEp1mFqasjidVncfuiIRza9GeyoDbrUC//25ku0'
if [[ -n ${ORCH_PUBKEY_FILE:-} ]]; then   # your key: its own fingerprint is the one printed
  [[ -r $ORCH_PUBKEY_FILE ]] || die "ORCH_PUBKEY_FILE=$ORCH_PUBKEY_FILE: no such readable file (upload your public key first)"
  ORCH_FPR=$(ssh-keygen -lf "$ORCH_PUBKEY_FILE" 2> /dev/null | awk '{print $2}')
  ORCH_FPR=${ORCH_FPR:-"the key in $ORCH_PUBKEY_FILE"}
fi

# ------------------------------------------------------------------------------------------------------------------- checks of the settings
# public_ipv4 IP: a well-formed IPv4 that can be an EC2 public address (private, loopback, link-local, CGNAT, multicast and the
# documentation ranges 192.0.2/24, 198.51.100/24, 203.0.113/24 are refused: a pasted example must not open ssh)
public_ipv4() {
  local o a b c
  [[ $1 =~ ^([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})$ ]] || return 1
  for o in "${BASH_REMATCH[@]:1}"; do [[ $o == 0 || $o != 0* ]] && ((10#$o <= 255)) || return 1; done
  a=${BASH_REMATCH[1]}; b=${BASH_REMATCH[2]}; c=${BASH_REMATCH[3]}
  ((a == 0 || a == 10 || a == 127 || a >= 224)) && return 1
  ((a == 169 && b == 254)) && return 1
  ((a == 172 && b >= 16 && b <= 31)) && return 1
  ((a == 192 && b == 168)) && return 1
  ((a == 100 && b >= 64 && b <= 127)) && return 1
  [[ $a.$b.$c == 192.0.2 || $a.$b.$c == 198.51.100 || $a.$b.$c == 203.0.113 ]] && return 1
  return 0
}
cidr_ok() { [[ $1 =~ ^([0-9.]+)/(2[4-9]|3[0-2])$ ]] && public_ipv4 "${BASH_REMATCH[1]}"; }
require_orch() {
  [[ -n $ORCH_IP ]] || die "ORCH_IP is required (no default): your workstation's public IPv4. Run:  ORCH_IP=<that address> bash $0 $CMD"
  public_ipv4 "$ORCH_IP" || die "ORCH_IP '$ORCH_IP' is not a public IPv4 address (private, documentation and malformed addresses are refused)"
}
[[ $MAX_HOURS =~ ^[0-9]+$ && $MAX_HOURS -ge 1 ]] || die "MAX_HOURS must be a whole number of hours, at least 1"
[[ $HARD_MAX_HOURS =~ ^[0-9]+$ && $HARD_MAX_HOURS -ge $MAX_HOURS && $HARD_MAX_HOURS -le 168 ]] || die "HARD_MAX_HOURS must be between MAX_HOURS ($MAX_HOURS) and 168"
[[ $BUDGET =~ ^[0-9]+\.?[0-9]*$ ]] || die "BUDGET must be a number (USD per hour)"
[[ $RESERVE_VCPU =~ ^[0-9]+$ ]] || die "RESERVE_VCPU must be a whole number"
[[ -n $AB_NODE ]] || { if [[ ${BED:-} == 2 ]]; then AB_NODE=0; else AB_NODE=1; fi; }
[[ $AB_NODE =~ ^[0-3]$ ]] || die "AB_NODE must be 0, 1, 2 or 3 (A/B nodes)"
for r in $SPOT_ROLES; do [[ $r =~ ^(cp|edge|load|app|ab|tools)$ ]] || die "SPOT_ROLES holds roles (cp edge load app ab tools), got '$r'"; done
[[ $REGION =~ ^[a-z]{2}-[a-z]+-[0-9]$ ]] || die "REGION must look like ap-south-1, got '$REGION'"
[[ -z $ADMIN_CIDR ]] || cidr_ok "$ADMIN_CIDR" || die "ADMIN_CIDR must be a public address like x.x.x.x/32 (a /24 at the widest), got '$ADMIN_CIDR'"
for d in "$DISK_CP" "$DISK_EDGE" "$DISK_LOAD" "$DISK_APP" "$DISK_AB" "$DISK_TOOLS"; do [[ $d =~ ^[0-9]+$ && $d -ge 20 && $d -le 2000 ]] || die "disk sizes must be 20..2000 GB, got '$d'"; done
for t in "$CP_TYPE" "$EDGE_TYPE" "$LOAD_TYPE" "$APP_TYPE" "$AB_TYPE" "$TOOLS_TYPE"; do [[ $t =~ ^[a-z][a-z0-9-]*\.[a-z0-9]+$ ]] || die "not an instance type: '$t'"; done
for f in $FALLBACK; do [[ $f =~ ^[a-z][a-z0-9-]*$ ]] || die "FALLBACK holds families like m6i, got '$f'"; done
[[ -z $BUCKET || $BUCKET =~ ^[a-z0-9][a-z0-9.-]{2,62}$ ]] || die "BUCKET is not a bucket name: '$BUCKET'"
need aws; need jq; need python3

# redact: what a DRYRUN line may show (a secret travels as a file:// path, but never print what follows --secret-string)
redact() {
  local a next=0 out=()
  for a in "$@"; do
    if ((next)); then out+=("<redacted>"); next=0; continue; fi
    [[ $a == --secret-string || $a == --secret-binary ]] && next=1
    out+=("$a")
  done
  printf '%s' "${out[*]}"
}
awsr() { aws --region "$REGION" "$@"; }                       # reads
awsm() {                                                       # mutations; with DRYRUN=1 they are only printed
  if [[ $DRYRUN == 1 ]]; then echo "DRYRUN aws --region $REGION $(redact "$@")" >&2; echo "dryrun-id"; return 0; fi
  awsr "$@"
}
WORK=$(mktemp -d)
chmod 700 "$WORK"
trap 'rm -rf "$WORK"' EXIT

confirm() {   # confirm QUESTION: yes with YES=1 or DRYRUN=1, else a typed y
  local a=""
  if [[ $YES == 1 || $DRYRUN == 1 ]]; then return 0; fi
  read -r -p "$1 [y/N] " a || a=""
  [[ $a == y || $a == Y || $a == yes ]]
}
ts() { echo "ResourceType=$1,Tags=[{Key=Name,Value=$PREFIX-$CLUSTER_TAG-$2},{Key=project,Value=$PROJECT},{Key=cluster,Value=$CLUSTER_TAG}]"; }
tagged() {   # $1 describe command (e.g. describe-vpcs), $2 jq path; prints the value or nothing
  awsr ec2 "$1" --filters "Name=tag:project,Values=$PROJECT" "Name=tag:cluster,Values=$CLUSTER_TAG" --output json | jq -r "$2 // empty"
}
init_account() {
  ACCOUNT=$(awsr sts get-caller-identity --query Account --output text 2> /dev/null || true)
  [[ $ACCOUNT =~ ^[0-9]{12}$ ]] || die "cannot read the account id (aws sts get-caller-identity failed): are you logged in?"
  BUCKET=${BUCKET:-rhobound-research-$ACCOUNT-$REGION}
  ECR_URI=$ACCOUNT.dkr.ecr.$REGION.amazonaws.com/$ECR_REPO
}

# ---------------------------------------------------------------------------------------------------------------------------- the machine list
# one line per machine: name kc role type disk
nodes() {
  local i
  echo "$PREFIX-$KC-cp1 $KC cp $CP_TYPE $DISK_CP"
  echo "$PREFIX-$KC-edge1 $KC edge $EDGE_TYPE $DISK_EDGE"
  echo "$PREFIX-$KC-load1 $KC load $LOAD_TYPE $DISK_LOAD"
  for i in $(seq 1 "$N_APP"); do echo "$PREFIX-$KC-app$i $KC app $APP_TYPE $DISK_APP"; done
  for i in $(seq 1 "$AB_NODE"); do echo "$PREFIX-$KC-ab$i $KC ab $AB_TYPE $DISK_AB"; done   # AB_NODE=0: no A/B node (bed 2 has no gate)
  echo "$PREFIX-tools1 tools tools $TOOLS_TYPE $DISK_TOOLS"
}
# the types to try for one machine: its own type, then the same size in each FALLBACK family
types_for() {
  local t=$1 size f; size=${t#*.}
  echo "$t"
  for f in $FALLBACK; do [[ $f.$size == "$t" ]] || echo "$f.$size"; done
}

vcpus_of() {
  local t=$1 v
  v=$(grep -m1 "^$t " "$WORK/vcpu" 2> /dev/null | cut -d' ' -f2 || true)
  if [[ -z $v ]]; then
    v=$(awsr ec2 describe-instance-types --instance-types "$t" --output json 2> /dev/null | jq -r '.InstanceTypes[0].VCpuInfo.DefaultVCpus // empty' || true)
    [[ $v =~ ^[0-9]+$ ]] || die "cannot read the vCPU count of $t in $REGION (is it a real type?)"
    echo "$t $v" >> "$WORK/vcpu"
  fi
  echo "$v"
}
# on-demand USD per hour from AWS's price list (the Pricing API answers in us-east-1); a high estimate if it cannot be read. Prints "price live|est"
od_price() {
  local t=$1 f="$WORK/od-$1" v
  if [[ ! -s $f ]]; then
    v=$(aws --region us-east-1 pricing get-products --service-code AmazonEC2 --max-results 1 \
          --filters "Type=TERM_MATCH,Field=instanceType,Value=$t" "Type=TERM_MATCH,Field=regionCode,Value=$REGION" \
                    "Type=TERM_MATCH,Field=operatingSystem,Value=Linux" "Type=TERM_MATCH,Field=tenancy,Value=Shared" \
                    "Type=TERM_MATCH,Field=preInstalledSw,Value=NA" "Type=TERM_MATCH,Field=capacitystatus,Value=Used" --output json 2> /dev/null \
        | jq -r '.PriceList[0] | fromjson | .terms.OnDemand | to_entries[0].value.priceDimensions | to_entries[0].value.pricePerUnit.USD' 2> /dev/null || true)
    if [[ $v =~ ^[0-9]+\.?[0-9]*$ ]] && python3 -c "import sys; sys.exit(0 if float('$v') > 0 else 1)"; then echo "$v live" > "$f"
    else echo "$(python3 -c "print(round($(vcpus_of "$t") * $OD_EST_PER_VCPU, 4))") est" > "$f"; fi
  fi
  cat "$f"
}

find_instance() {
  awsr ec2 describe-instances --filters "Name=tag:Name,Values=$1" "Name=tag:project,Values=$PROJECT" "Name=tag:cluster,Values=$CLUSTER_TAG" \
       "Name=instance-state-name,Values=pending,running,stopping,stopped" --output json | jq -r '[.Reservations[].Instances[].InstanceId] | join(" ")'
}
cluster_json() {
  awsr ec2 describe-instances --filters "Name=tag:project,Values=$PROJECT" "Name=tag:cluster,Values=$CLUSTER_TAG" \
       "Name=instance-state-name,Values=pending,running,stopping,stopped,shutting-down" --output json
}

# ------------------------------------------------------------------------------------------------------------------------------ the vCPU quota
# sets QUOTA, USED (on-demand standard-family vCPUs pending or running in the region, your workstation's included if it runs here), NEED (missing machines), TOTAL
quota_check() {
  local name kc role type disk v q
  q=$(awsr service-quotas get-service-quota --service-code ec2 --quota-code "$QUOTA_OD_CODE" --query 'Quota.Value' --output text 2> /dev/null || true)
  [[ -n $q && $q != None ]] || q=$(awsr service-quotas get-aws-default-service-quota --service-code ec2 --quota-code "$QUOTA_OD_CODE" --query 'Quota.Value' --output text 2> /dev/null || true)
  if [[ -n $q && $q != None ]]; then QUOTA=${q%.*}; else QUOTA=""; fi
  USED=$(awsr ec2 describe-instances --filters "Name=instance-state-name,Values=pending,running" --output json \
    | jq '[.Reservations[].Instances[] | select(.InstanceLifecycle != "spot") | select(.InstanceType | test("^[acdhimrtz]"))
           | select(.InstanceType | test("^(inf|trn|dl|hpc|mac)") | not) | .CpuOptions | .CoreCount * .ThreadsPerCore] | add // 0')
  NEED=0; TOTAL=0; SNEED=0
  while read -r name kc role type disk; do
    v=$(vcpus_of "$type"); TOTAL=$((TOTAL + v))
    [[ -z $(find_instance "$name") ]] || continue
    if is_spot "$role"; then SNEED=$((SNEED + v)); else NEED=$((NEED + v)); fi
  done < <(nodes)
  if ((SNEED > 0)); then
    local sq sused
    sq=$(awsr service-quotas get-service-quota --service-code ec2 --quota-code "$QUOTA_SPOT_CODE" --query 'Quota.Value' --output text 2> /dev/null || true)
    [[ -n $sq && $sq != None ]] || sq=$(awsr service-quotas get-aws-default-service-quota --service-code ec2 --quota-code "$QUOTA_SPOT_CODE" --query 'Quota.Value' --output text 2> /dev/null || true)
    sused=$(awsr ec2 describe-instances --filters "Name=instance-state-name,Values=pending,running" --output json \
      | jq '[.Reservations[].Instances[] | select(.InstanceLifecycle == "spot") | .CpuOptions | .CoreCount * .ThreadsPerCore] | add // 0')
    if [[ -n $sq && $sq != None ]]; then
      say "spot vCPU quota: ${sq%.*}. Spot in use now: $sused. This plan adds $SNEED spot vCPUs (roles: $SPOT_ROLES)."
      if ((sused + SNEED > ${sq%.*})); then say "SPOT QUOTA TOO LOW: $SNEED needed, $((${sq%.*} - sused)) free"; SPOT_OK=0; else SPOT_OK=1; fi
    else
      say "could not read the spot vCPU quota; this plan adds $SNEED spot vCPUs (roles: $SPOT_ROLES)"; SPOT_OK=1
    fi
  else SPOT_OK=1; fi
  QUOTA_OK=1
  if [[ -z $QUOTA ]]; then
    say "could not read the vCPU quota (permissions?). Check Service Quotas > EC2 > Running On-Demand Standard instances: it must be at least $((USED + NEED + RESERVE_VCPU))."
    QUOTA_OK=unknown; return 0
  fi
  say "on-demand vCPU quota: $QUOTA. In use now in $REGION (your workstation included, if it runs here): $USED. This plan adds $NEED (the whole plan is $TOTAL). Kept free: $RESERVE_VCPU."
  if ((SPOT_OK == 0)); then QUOTA_OK=0; fi
  if ((QUOTA_OK == 1 && USED + NEED + RESERVE_VCPU <= QUOTA)); then say "QUOTA OK: $((QUOTA - USED - NEED - RESERVE_VCPU)) on-demand vCPUs would be left."
  else
    QUOTA_OK=0
    say "QUOTA TOO LOW: the plan needs $NEED more vCPUs but only $((QUOTA - USED - RESERVE_VCPU)) are free. Stop other instances, or raise the quota (Service Quotas > EC2)."
  fi
}

# one zone where every primary type is offered (then each machine's fallbacks are filtered to that zone)
choose_az() {
  local types all t a ok
  types=$(nodes | awk '{print $4}' | sort -u)
  all=$(for t in $types; do types_for "$t"; done | sort -u | paste -sd, -)
  awsr ec2 describe-instance-type-offerings --location-type availability-zone --filters "Name=instance-type,Values=$all" --output json > "$WORK/offers.json"
  if [[ -n $AZ ]]; then return 0; fi
  local zones; zones=$(awsr ec2 describe-availability-zones --filters Name=state,Values=available --output json | jq -r '.AvailabilityZones[] | select(.ZoneType == "availability-zone") | .ZoneName' | sort)
  for a in $zones; do   # pass 1: a zone that offers every machine's own type
    ok=1
    for t in $types; do offered_in "$a" "$t" || { ok=0; break; }; done
    if [[ $ok == 1 ]]; then AZ=$a; return 0; fi
  done
  for a in $zones; do   # pass 2: a zone where every machine has at least one of its types
    ok=1
    for t in $types; do
      local any=0 c; for c in $(types_for "$t"); do offered_in "$a" "$c" && { any=1; break; }; done
      [[ $any == 1 ]] || { ok=0; break; }
    done
    if [[ $ok == 1 ]]; then AZ=$a; say "no zone offers every first-choice type; zone $AZ has a fallback for each machine (types are in the inventory)"; return 0; fi
  done
  die "no availability zone in $REGION offers, for every machine, its type or a fallback: $(tr '\n' ' ' <<< "$types")(FALLBACK: $FALLBACK). Set other types or FALLBACK."
}
offered_in() { jq -e --arg a "$1" --arg t "$2" '[.InstanceTypeOfferings[] | select(.Location==$a and .InstanceType==$t)] | length > 0' "$WORK/offers.json" > /dev/null; }
offered() { offered_in "$AZ" "$1"; }

ami() { if [[ -n ${AMI_ID:-} ]]; then echo "$AMI_ID"; else awsr ssm get-parameter --name "$SSM_AMI" --query 'Parameter.Value' --output text; fi; }

# the price of the whole plan per hour (compute at each machine's first type + disks + public IPs); sets EST and EST_SRC
estimate() {
  local name kc role type disk p src c=0 gb=0 n=0 any_est=0
  printf '\n  %-16s %-5s %-5s %-12s %5s %7s %9s\n' name kc role type vCPU diskGB usd/h >&2
  while read -r name kc role type disk; do
    read -r p src <<< "$(od_price "$type")"
    [[ $src == live ]] || any_est=1
    printf '  %-16s %-5s %-5s %-12s %5s %7s %9s\n' "$name" "$kc" "$role$(is_spot "$role" && echo '*')" "$type" "$(vcpus_of "$type")" "$disk" "$p" >&2
    c=$(python3 -c "print($c + $p)"); gb=$((gb + disk)); n=$((n + 1))
  done < <(nodes)
  EST=$(python3 -c "print(round($c + $gb * $EBS_GB_MONTH / 730 + $n * $IPV4_HOUR, 3))")
  EST_SRC=$([[ $any_est == 1 ]] && echo "partly estimated on the high side: the price list could not be read for every type" || echo "AWS list prices")
  python3 - "$c" "$gb" "$n" "$MAX_HOURS" "$HARD_MAX_HOURS" "$EBS_GB_MONTH" "$IPV4_HOUR" << 'PY' >&2
import sys
c, gb, n, cap, hard, ebs_m, ip_h = float(sys.argv[1]), int(sys.argv[2]), int(sys.argv[3]), float(sys.argv[4]), float(sys.argv[5]), float(sys.argv[6]), float(sys.argv[7])
ebs = gb * ebs_m / 730
ip = n * ip_h
h = c + ebs + ip
print("\n  %d machines, %d GB of disk: compute %.3f + disks %.3f + public IPs %.3f = about %.2f USD per hour" % (n, gb, c, ebs, ip, h))
print("  per day (24 h): about %.1f USD; to the %g-hour cap: about %.1f USD; to the hard ceiling (%g h): about %.1f USD." % (24 * h, cap, cap * h, hard, hard * h))
print("  Also: S3 storage (about 0.025 USD per GB-month), the KMS key (1 USD per month, prorated), each secret (0.40 USD per month).")
PY
}

# ------------------------------------------------------------------------------------------------------------------- reads of IAM, KMS, ECR
key_state() {   # sets KID KSTATE KSPEC KUSAGE from the alias (all empty when there is none); 1 when it cannot be read
  local j
  KID=""; KSTATE=""; KSPEC=""; KUSAGE=""
  if j=$(awsr kms describe-key --key-id "$KMS_ALIAS" --output json 2> "$WORK/kms.err"); then
    KID=$(jq -r '.KeyMetadata.KeyId // empty' <<< "$j"); KSTATE=$(jq -r '.KeyMetadata.KeyState // empty' <<< "$j")
    KSPEC=$(jq -r '.KeyMetadata.KeySpec // .KeyMetadata.CustomerMasterKeySpec // empty' <<< "$j"); KUSAGE=$(jq -r '.KeyMetadata.KeyUsage // empty' <<< "$j")
    return 0
  fi
  grep -q NotFoundException "$WORK/kms.err" && return 0
  cat "$WORK/kms.err" >&2
  return 1
}
ecr_state() {   # sets ECR_FOUND (1/0) and ECR_JSON; 1 when it cannot be read
  ECR_FOUND=0; ECR_JSON=""
  if ECR_JSON=$(awsr ecr describe-repositories --repository-names "$ECR_REPO" --output json 2> "$WORK/ecr.err"); then ECR_FOUND=1; return 0; fi
  grep -q RepositoryNotFoundException "$WORK/ecr.err" && return 0
  cat "$WORK/ecr.err" >&2
  return 1
}
ecr_ours() {   # the repository carries project=PROJECT
  local arn; arn=$(jq -r '.repositories[0].repositoryArn' <<< "$ECR_JSON")
  awsr ecr list-tags-for-resource --resource-arn "$arn" --output json | jq -e --arg p "$PROJECT" 'any(.tags[]?; .Key == "project" and .Value == $p)' > /dev/null
}
role_exists() { awsr iam get-role --role-name "$1" > /dev/null 2>&1; }
our_secrets() {   # names of the live (not pending deletion) secrets rhobound-demo/* tagged project=PROJECT
  awsr secretsmanager list-secrets --filters "Key=name,Values=$SECRET_PREFIX" --output json \
    | jq -r --arg p "$PROJECT" --arg pre "$SECRET_PREFIX" '.SecretList[]? | select(.Name | startswith($pre)) | select(.DeletedDate == null)
                                                          | select(any(.Tags[]?; .Key == "project" and .Value == $p)) | .Name'
}

# ------------------------------------------------------------------------------------------------------------------------------------- plan
plan() {
  require_orch
  init_account
  choose_az
  estimate
  say "prices: $EST_SRC. Budget: $BUDGET USD per hour."
  if python3 -c "import sys; sys.exit(0 if $EST <= $BUDGET else 1)"; then BUDGET_OK=1; else BUDGET_OK=0; say "OVER BUDGET: about $EST > $BUDGET USD per hour (set BUDGET, or smaller types)"; fi
  say "account $ACCOUNT, region $REGION, zone $AZ. Machines power off (and are terminated) $MAX_HOURS h after launch; your workstation may extend that up to $HARD_MAX_HOURS h."
  say "ssh only from $ORCH_IP/32${ADMIN_CIDR:+ and $ADMIN_CIDR}: check that $ORCH_IP is your workstation's CURRENT public IP. Its key: $ORCH_FPR"
  bucket_report
  quota_check
  local out r
  out=$(awsr ec2 create-vpc --dry-run --cidr-block "$VPC_CIDR" 2>&1 || true)
  if grep -q DryRunOperation <<< "$out"; then say "permissions: ec2:CreateVpc would succeed"; else say "permissions: the dry run said: ${out:0:300}"; fi
  for r in "$NODE_ROLE" "$TOOLS_ROLE"; do
    if role_exists "$r"; then say "role $r exists (its policy is rewritten by up)"; else say "role $r will be created"; fi
  done
  if ecr_state; then
    if [[ $ECR_FOUND == 1 ]]; then say "ECR repository $ECR_URI exists"; else say "ECR repository $ECR_URI will be created (tags mutable, scan on push, AES256)"; fi
  else say "WARNING: cannot read the ECR repository (permissions?)"; fi
  if key_state; then
    if [[ -n $KID ]]; then say "KMS key $KID ($KMS_ALIAS) exists, state $KSTATE"; else say "KMS key $KMS_ALIAS will be created (ECC_NIST_P256, SIGN_VERIFY)"; fi
  else say "WARNING: cannot read the KMS alias (permissions?)"; fi
  say "secrets $SECRET_PREFIX*: $(our_secrets 2> /dev/null | paste -sd' ' - | sed 's/^$/none/')"
  if [[ $QUOTA_OK != 0 && $BUDGET_OK == 1 ]]; then say "plan done: nothing was created. Next: ORCH_IP=$ORCH_IP bash $0 up"; else say "plan done: it does NOT fit (see above); nothing was created"; fi
}
bucket_report() {
  local loc n
  if awsr s3api head-bucket --bucket "$BUCKET" > /dev/null 2>&1; then
    loc=$(awsr s3api get-bucket-location --bucket "$BUCKET" --query LocationConstraint --output text 2> /dev/null || true)
    [[ $loc == None || -z $loc ]] && loc=us-east-1
    n=$(awsr s3api list-objects-v2 --bucket "$BUCKET" --prefix "$CAMPAIGN/" --max-items 1 --output json 2> /dev/null | jq '.Contents // [] | length' || echo "?")
    say "bucket $BUCKET exists (region $loc); it is not changed. Objects under $CAMPAIGN/ already: $([[ $n == 0 ]] && echo none || echo yes). The machines write only under s3://$BUCKET/$CAMPAIGN/"
    [[ $loc == "$REGION" ]] || say "WARNING: the bucket is in $loc, not $REGION: uploads would cross regions (set BUCKET to a bucket in $REGION)"
    BUCKET_EXISTS=1
  else
    say "bucket $BUCKET does not exist (or is not yours): up refuses unless CREATE_BUCKET=1 (then it asks and creates it private, tagged)"
    BUCKET_EXISTS=0
  fi
}

# ------------------------------------------------------------------------------------------------------------------------- policy documents
pol_trust() { jq -nc '{Version:"2012-10-17",Statement:[{Effect:"Allow",Principal:{Service:"ec2.amazonaws.com"},Action:"sts:AssumeRole"}]}'; }
pol_node() {   # cluster nodes: list demo1/d/ and put objects under it (their own sync prefix); nothing else, so no node can touch demo1/ledger/
  # the node role is shared by both beds: it may list and put under bed 1's prefix (demo1/d/) and bed 2's (demo1/b2/d/)
  jq -nc --arg b "$BUCKET" --arg c "$CAMPAIGN/$KC" --arg c2 "$CAMPAIGN/b2/$KC" '{Version:"2012-10-17",Statement:[
    {Sid:"ListClusterPrefix",Effect:"Allow",Action:"s3:ListBucket",Resource:"arn:aws:s3:::\($b)",Condition:{StringLike:{"s3:prefix":["\($c)/","\($c)/*","\($c2)/","\($c2)/*"]}}},
    {Sid:"PutClusterObjects",Effect:"Allow",Action:"s3:PutObject",Resource:["arn:aws:s3:::\($b)/\($c)/*","arn:aws:s3:::\($b)/\($c2)/*"]}]}'
}
pol_tools() {   # $1 the KMS key ARN. rbd-tools1: S3 under demo1/, the one ECR repo, the one key, the rhobound-demo/* secrets
  jq -nc --arg b "$BUCKET" --arg c "$CAMPAIGN" --arg r "$REGION" --arg a "$ACCOUNT" --arg repo "$ECR_REPO" --arg key "$1" --arg sp "$SECRET_PREFIX" '{Version:"2012-10-17",Statement:[
    {Sid:"ListCampaignPrefix",Effect:"Allow",Action:"s3:ListBucket",Resource:"arn:aws:s3:::\($b)",Condition:{StringLike:{"s3:prefix":["\($c)/","\($c)/*"]}}},
    {Sid:"CampaignObjects",Effect:"Allow",Action:["s3:GetObject","s3:PutObject"],Resource:"arn:aws:s3:::\($b)/\($c)/*"},
    {Sid:"EcrToken",Effect:"Allow",Action:"ecr:GetAuthorizationToken",Resource:"*"},
    {Sid:"EcrRepo",Effect:"Allow",Action:["ecr:BatchCheckLayerAvailability","ecr:GetDownloadUrlForLayer","ecr:BatchGetImage","ecr:InitiateLayerUpload",
      "ecr:UploadLayerPart","ecr:CompleteLayerUpload","ecr:PutImage","ecr:DescribeImages","ecr:ListImages","ecr:DescribeRepositories"],
     Resource:"arn:aws:ecr:\($r):\($a):repository/\($repo)"},
    {Sid:"VerdictKey",Effect:"Allow",Action:["kms:Sign","kms:Verify","kms:GetPublicKey","kms:DescribeKey"],Resource:$key},
    {Sid:"DemoSecrets",Effect:"Allow",Action:"secretsmanager:GetSecretValue",Resource:"arn:aws:secretsmanager:\($r):\($a):secret:\($sp)*"}]}'
}
pol_key() {   # the KMS key policy: the account root (standard admin statement, keeps the key manageable) and the tools role
  jq -nc --arg a "$ACCOUNT" --arg role "$TOOLS_ROLE" '{Version:"2012-10-17",Id:"rhobound-demo-verdict",Statement:[
    {Sid:"AccountRootAdmin",Effect:"Allow",Principal:{AWS:"arn:aws:iam::\($a):root"},Action:"kms:*",Resource:"*"},
    {Sid:"ToolsRoleSignVerify",Effect:"Allow",Principal:{AWS:"arn:aws:iam::\($a):role/\($role)"},
     Action:["kms:Sign","kms:Verify","kms:GetPublicKey","kms:DescribeKey"],Resource:"*"}]}'
}

# ------------------------------------------------------------------------------------------------------------------------- building blocks
ensure_bucket() {
  bucket_report
  [[ $BUCKET_EXISTS == 1 ]] && return 0
  [[ $CREATE_BUCKET == 1 ]] || die "bucket $BUCKET not found: set BUCKET to your bucket, or CREATE_BUCKET=1 to create it (YES=1 does not)"
  confirm "Create the bucket $BUCKET in $REGION (private)?" || die "aborted (no bucket, nothing created)"
  if [[ $REGION == us-east-1 ]]; then awsm s3api create-bucket --bucket "$BUCKET" > /dev/null
  else awsm s3api create-bucket --bucket "$BUCKET" --create-bucket-configuration "LocationConstraint=$REGION" > /dev/null; fi
  awsm s3api put-public-access-block --bucket "$BUCKET" \
    --public-access-block-configuration "BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true" > /dev/null
  awsm s3api put-bucket-tagging --bucket "$BUCKET" --tagging "TagSet=[{Key=project,Value=$PROJECT}]" > /dev/null
  say "created bucket $BUCKET (private)"
}
FRESH=0
ensure_role() {   # $1 role (and instance profile) name
  local name=$1 n
  if ! role_exists "$name"; then
    awsm iam create-role --role-name "$name" --assume-role-policy-document "file://$WORK/trust.json" --tags "Key=project,Value=$PROJECT" "Key=cluster,Value=$CAMPAIGN" > /dev/null
    FRESH=1; say "created role $name"
  else say "role $name exists"; fi
  if ! awsr iam get-instance-profile --instance-profile-name "$name" > /dev/null 2>&1; then
    awsm iam create-instance-profile --instance-profile-name "$name" --tags "Key=project,Value=$PROJECT" "Key=cluster,Value=$CAMPAIGN" > /dev/null
    FRESH=1; say "created instance profile $name"
  fi
  n=$(awsr iam get-instance-profile --instance-profile-name "$name" --query 'length(InstanceProfile.Roles)' --output text 2> /dev/null || echo 0)
  if [[ $n == 0 || $n == None ]]; then awsm iam add-role-to-instance-profile --instance-profile-name "$name" --role-name "$name" > /dev/null; fi
}
ensure_iam() {
  pol_trust > "$WORK/trust.json"
  pol_node > "$WORK/pol-node.json"
  ensure_role "$NODE_ROLE"
  ensure_role "$TOOLS_ROLE"
  awsm iam put-role-policy --role-name "$NODE_ROLE" --policy-name "$NODE_POLICY" --policy-document "file://$WORK/pol-node.json" > /dev/null
  say "policy $NODE_POLICY on $NODE_ROLE: list and put under s3://$BUCKET/$CAMPAIGN/$KC/ only"
}
# kms_call ARGS...: a KMS mutation that names the tools role; retried while a new role is not yet visible to KMS. Its output on stdout.
kms_call() {
  local attempt out
  for attempt in 1 2 3 4 5 6 7 8 9; do
    if out=$(awsm "$@" 2> "$WORK/kms.err"); then
      if [[ $DRYRUN == 1 ]]; then cat "$WORK/kms.err" >&2; fi
      printf '%s\n' "$out"; return 0
    fi
    cat "$WORK/kms.err" >&2
    if grep -q MalformedPolicyDocumentException "$WORK/kms.err" && ((attempt < 9)); then
      say "KMS does not see role $TOOLS_ROLE yet; waiting 10 s (attempt $attempt of 9)"; sleep 10; continue
    fi
    return 1
  done
}
ensure_kms() {
  pol_key > "$WORK/key-policy.json"
  key_state || die "cannot read the KMS alias $KMS_ALIAS (see above)"
  if [[ -n $KID ]]; then
    [[ $KSPEC == ECC_NIST_P256 && $KUSAGE == SIGN_VERIFY ]] || die "$KMS_ALIAS points to key $KID ($KSPEC, $KUSAGE), not an ECC_NIST_P256 SIGN_VERIFY key: refusing to use it"
    if [[ $KSTATE == PendingDeletion ]]; then
      awsm kms cancel-key-deletion --key-id "$KID" > /dev/null; KSTATE=Disabled; say "KMS key $KID was pending deletion: deletion cancelled"
    fi
    if [[ $KSTATE == Disabled ]]; then awsm kms enable-key --key-id "$KID" > /dev/null; say "KMS key $KID enabled"; fi
    kms_call kms put-key-policy --key-id "$KID" --policy-name default --policy "file://$WORK/key-policy.json" > /dev/null || die "the key policy of $KID was refused (above)"
    say "KMS key $KID ($KMS_ALIAS) exists; its policy re-applied (account root + $TOOLS_ROLE: Sign, Verify, GetPublicKey, DescribeKey)"
  else
    KID=$(kms_call kms create-key --key-spec ECC_NIST_P256 --key-usage SIGN_VERIFY --description "rhobound $CAMPAIGN: signs the gate verdicts (cosign)" \
            --policy "file://$WORK/key-policy.json" --tags "TagKey=project,TagValue=$PROJECT" "TagKey=cluster,TagValue=$CAMPAIGN" \
            --query KeyMetadata.KeyId --output text) || die "creating the KMS key failed (above)"
    [[ $DRYRUN == 1 || $KID =~ ^[0-9a-f-]{36}$|^mrk-[0-9a-f]{32}$ ]] || die "create-key answered an unexpected key id '$KID'"
    if ! awsm kms create-alias --alias-name "$KMS_ALIAS" --target-key-id "$KID" > /dev/null; then
      awsm kms schedule-key-deletion --key-id "$KID" --pending-window-in-days "$KEY_DELETE_DAYS" > /dev/null || true
      die "could not name the new key $KMS_ALIAS: key $KID scheduled for deletion; run up again"
    fi
    say "created KMS key $KID (ECC_NIST_P256, SIGN_VERIFY) as $KMS_ALIAS"
  fi
  KEY_ARN=arn:aws:kms:$REGION:$ACCOUNT:key/$KID
}
ensure_tools_policy() {
  pol_tools "$KEY_ARN" > "$WORK/pol-tools.json"
  awsm iam put-role-policy --role-name "$TOOLS_ROLE" --policy-name "$TOOLS_POLICY" --policy-document "file://$WORK/pol-tools.json" > /dev/null
  say "policy $TOOLS_POLICY on $TOOLS_ROLE: S3 under $CAMPAIGN/, ECR $ECR_REPO, KMS $KMS_ALIAS, secrets $SECRET_PREFIX*"
}
ensure_ecr() {
  local mut scan enc
  ecr_state || die "cannot read the ECR repository $ECR_REPO (see above)"
  if [[ $ECR_FOUND == 1 ]]; then
    ecr_ours || die "the ECR repository $ECR_REPO exists but is not tagged project=$PROJECT: refusing to touch it"
    mut=$(jq -r '.repositories[0].imageTagMutability' <<< "$ECR_JSON"); scan=$(jq -r '.repositories[0].imageScanningConfiguration.scanOnPush' <<< "$ECR_JSON")
    enc=$(jq -r '.repositories[0].encryptionConfiguration.encryptionType' <<< "$ECR_JSON")
    [[ $mut == MUTABLE ]] || { awsm ecr put-image-tag-mutability --repository-name "$ECR_REPO" --image-tag-mutability MUTABLE > /dev/null; say "ECR tags made MUTABLE"; }
    [[ $scan == true ]] || { awsm ecr put-image-scanning-configuration --repository-name "$ECR_REPO" --image-scanning-configuration scanOnPush=true > /dev/null; say "ECR scan on push enabled"; }
    [[ $enc == AES256 ]] || say "WARNING: ECR $ECR_REPO is encrypted with $enc, not AES256 (cannot be changed; destroy and up again for AES256)"
    ECR_URI=$(jq -r '.repositories[0].repositoryUri' <<< "$ECR_JSON")
    say "ECR repository $ECR_URI exists"
  else
    awsm ecr create-repository --repository-name "$ECR_REPO" --image-tag-mutability MUTABLE --image-scanning-configuration scanOnPush=true \
      --encryption-configuration encryptionType=AES256 --tags "Key=project,Value=$PROJECT" "Key=cluster,Value=$CAMPAIGN" > /dev/null
    say "created ECR repository $ECR_URI (tags mutable, scan on push, AES256)"
  fi
}
ensure_key() {
  if awsr ec2 describe-key-pairs --key-names "$KEY_NAME" > /dev/null 2>&1; then
    say "key pair $KEY_NAME exists: its key is kept${ORCH_PUBKEY_FILE:+ (ORCH_PUBKEY_FILE is not re-imported; delete the key pair in the EC2 console to change it)}"
    return 0
  fi
  local f="$WORK/pub"
  if [[ -n ${ORCH_PUBKEY_FILE:-} ]]; then cp "$ORCH_PUBKEY_FILE" "$f"; else echo "$ORCH_PUBKEY_BUILTIN" > "$f"; fi
  grep -q '^ssh-' "$f" || die "the public key does not look like a public key"
  awsm ec2 import-key-pair --key-name "$KEY_NAME" --public-key-material "fileb://$f" --tag-specifications "ResourceType=key-pair,Tags=[{Key=project,Value=$PROJECT},{Key=cluster,Value=$CAMPAIGN}]" > /dev/null
  say "imported key pair $KEY_NAME (your workstation's key, $ORCH_FPR)"
}
sg_id() { awsr ec2 describe-security-groups --filters "Name=group-name,Values=$SG_NAME" "Name=tag:project,Values=$PROJECT" "Name=tag:cluster,Values=$CLUSTER_TAG" --output json | jq -r '.SecurityGroups[0].GroupId // empty'; }
sg_ssh_cidrs() {   # $1 group id: "CIDR DESCRIPTION" per ssh rule
  awsr ec2 describe-security-groups --group-ids "$1" --output json \
    | jq -r '.SecurityGroups[0].IpPermissions[]? | select(.IpProtocol == "tcp" and .FromPort == 22) | .IpRanges[]? | "\(.CidrIp) \(.Description // "-")"'
}
sg_add_ssh() {   # $1 group $2 cidr $3 description
  awsm ec2 authorize-security-group-ingress --group-id "$1" --ip-permissions "IpProtocol=tcp,FromPort=22,ToPort=22,IpRanges=[{CidrIp=$2,Description=$3}]" > /dev/null
}
# sg_converge: members talk to each other, ssh from ORCH_IP/32 (+ ADMIN_CIDR); other ssh sources are reported, never removed here
sg_converge() {
  local sg=$1 perms c d
  if [[ $sg == dryrun-id ]]; then perms='[]'; else perms=$(awsr ec2 describe-security-groups --group-ids "$sg" --output json | jq -c '.SecurityGroups[0].IpPermissions // []'); fi
  if ! jq -e --arg g "$sg" 'any(.[]; .IpProtocol == "-1" and any(.UserIdGroupPairs[]?; .GroupId == $g))' <<< "$perms" > /dev/null; then
    awsm ec2 authorize-security-group-ingress --group-id "$sg" --ip-permissions "IpProtocol=-1,UserIdGroupPairs=[{GroupId=$sg}]" > /dev/null; say "all traffic allowed between members"
  fi
  for c in "$ORCH_IP/32" ${ADMIN_CIDR:+"$ADMIN_CIDR"}; do
    d="orchestrator"; [[ $c == "$ORCH_IP/32" ]] || d="admin"
    if ! jq -e --arg c "$c" 'any(.[]; .IpProtocol == "tcp" and .FromPort == 22 and any(.IpRanges[]?; .CidrIp == $c))' <<< "$perms" > /dev/null; then
      sg_add_ssh "$sg" "$c" "$d"; say "ssh allowed from $c ($d)"
    fi
  done
  for c in $(jq -r '.[] | select(.IpProtocol == "tcp" and .FromPort == 22) | .IpRanges[]? | .CidrIp' <<< "$perms"); do
    [[ $c == "$ORCH_IP/32" || $c == "$ADMIN_CIDR" ]] || say "NOTE: ssh is also allowed from $c (an older address?). Remove it with:  bash $0 deny-ip $c"
  done
}
ensure_net() {
  local rt has
  VPC=$(tagged describe-vpcs '.Vpcs[0].VpcId')
  if [[ -z $VPC ]]; then
    VPC=$(awsm ec2 create-vpc --cidr-block "$VPC_CIDR" --tag-specifications "$(ts vpc vpc)" --query Vpc.VpcId --output text); say "created VPC $VPC ($VPC_CIDR)"
  else say "VPC $VPC exists"; fi
  IGW=$(tagged describe-internet-gateways '.InternetGateways[0].InternetGatewayId')
  if [[ -z $IGW ]]; then
    IGW=$(awsm ec2 create-internet-gateway --tag-specifications "$(ts internet-gateway igw)" --query InternetGateway.InternetGatewayId --output text)
    awsm ec2 attach-internet-gateway --internet-gateway-id "$IGW" --vpc-id "$VPC" > /dev/null; say "created internet gateway $IGW"
  else
    say "internet gateway $IGW exists"
    if ! tagged describe-internet-gateways '.InternetGateways[0].Attachments[]?.VpcId' | grep -qx "$VPC"; then
      awsm ec2 attach-internet-gateway --internet-gateway-id "$IGW" --vpc-id "$VPC" > /dev/null; say "attached $IGW to $VPC"
    fi
  fi
  SUBNET=$(tagged describe-subnets '.Subnets[0].SubnetId')
  if [[ -z $SUBNET ]]; then
    SUBNET=$(awsm ec2 create-subnet --vpc-id "$VPC" --cidr-block "$SUBNET_CIDR" --availability-zone "$AZ" --tag-specifications "$(ts subnet subnet)" --query Subnet.SubnetId --output text)
    say "created subnet $SUBNET ($SUBNET_CIDR, $AZ)"
  else
    local saz; saz=$(tagged describe-subnets '.Subnets[0].AvailabilityZone')
    say "subnet $SUBNET exists ($saz)"
    [[ $DRYRUN == 1 || -z $saz ]] || AZ=$saz       # machines go where the subnet is
  fi
  rt=$(awsr ec2 describe-route-tables --filters "Name=vpc-id,Values=$VPC" "Name=association.main,Values=true" --output json 2> /dev/null | jq -r '.RouteTables[0].RouteTableId // empty' || true)
  if [[ -n $rt ]]; then
    has=$(awsr ec2 describe-route-tables --route-table-ids "$rt" --output json | jq -r '[.RouteTables[0].Routes[] | select(.DestinationCidrBlock=="0.0.0.0/0")] | length')
    if [[ $has == 0 ]]; then awsm ec2 create-route --route-table-id "$rt" --destination-cidr-block 0.0.0.0/0 --gateway-id "$IGW" > /dev/null; say "default route to $IGW"; fi
  elif [[ $DRYRUN == 1 ]]; then awsm ec2 create-route --route-table-id main-of-new-vpc --destination-cidr-block 0.0.0.0/0 --gateway-id "$IGW" > /dev/null
  else die "no main route table found for $VPC"; fi
  SG=$(awsr ec2 describe-security-groups --filters "Name=group-name,Values=$SG_NAME" "Name=vpc-id,Values=$VPC" --output json 2> /dev/null | jq -r '.SecurityGroups[0].GroupId // empty' || true)
  if [[ -z $SG ]]; then
    SG=$(awsm ec2 create-security-group --group-name "$SG_NAME" --description "rhobound demo $CAMPAIGN" --vpc-id "$VPC" --tag-specifications "$(ts security-group sg)" --query GroupId --output text)
    say "created security group $SG_NAME ($SG)"
  else say "security group $SG exists"; fi
  sg_converge "$SG"
}

# ------------------------------------------------------------------------------------------------------------------------------- user data
# cloud-init, first boot only: the time cap FIRST, then the base, the S3 upload, a boot record. k3s and the rest come later from your workstation.
render_userdata() {   # $1 name  $2 kc  $3 role
  cat << 'USERDATA' | sed -e "s|__NAME__|$1|g" -e "s|__KC__|$2|g" -e "s|__ROLE__|$3|g" -e "s|__MINUTES__|$((MAX_HOURS * 60))|g" \
                         -e "s|__HARD_MINUTES__|$((HARD_MAX_HOURS * 60))|g" -e "s|__BUCKET__|$BUCKET|g" -e "s|__PREFIX__|$S3BASE/$2/$1|g" \
                         -e "s|__REGION__|$REGION|g" -e "s|__CAMPAIGN__|$CAMPAIGN|g"
#!/bin/bash
# rhobound demo node (__CAMPAIGN__): base preparation (cloud-init, first boot)
exec >> /var/log/rb-base.log 2>&1
set -x
mkdir -p /var/lib/rb
# the time cap: the deadline (epoch) and the hard ceiling are written once; a timer re-reads the deadline every minute, so a reboot does not lose it
now=$(date +%s)
[ -s /var/lib/rb/deadline ] || echo $(( now + __MINUTES__ * 60 )) > /var/lib/rb/deadline
[ -s /var/lib/rb/hard-deadline ] || echo $(( now + __HARD_MINUTES__ * 60 )) > /var/lib/rb/hard-deadline
shutdown -h +__MINUTES__ "rhobound __CAMPAIGN__: time cap reached"      # EC2 TERMINATES a machine that shuts itself down
cat > /usr/local/bin/rb-deadline << 'EOF'
#!/bin/bash
# rb-deadline [show | extend HOURS | check]: the time cap of this machine. extend never goes past /var/lib/rb/hard-deadline (fixed at launch).
f=/var/lib/rb/deadline; h=/var/lib/rb/hard-deadline
d=$(cat "$f" 2> /dev/null); hd=$(cat "$h" 2> /dev/null); now=$(date +%s)
case ${1:-show} in
  show) echo "deadline $(date -u -d "@$d" +%FT%TZ) ($(( (d - now) / 60 )) min left); hard ceiling $(date -u -d "@$hd" +%FT%TZ)" ;;
  extend)
    [ "$(id -u)" = 0 ] || { echo "run it with sudo" >&2; exit 2; }
    [[ ${2:-} =~ ^[0-9]+$ ]] || { echo "usage: rb-deadline extend HOURS" >&2; exit 2; }
    n=$(( d + $2 * 3600 )); if [ "$n" -gt "$hd" ]; then n=$hd; echo "capped at the hard ceiling" >&2; fi
    echo "$n" > "$f.new" && mv "$f.new" "$f"
    shutdown -c 2> /dev/null || true
    m=$(( (n - now) / 60 )); [ "$m" -ge 1 ] || m=1
    shutdown -h "+$m" "rhobound: time cap reached"
    d=$n; echo "deadline $(date -u -d "@$d" +%FT%TZ) ($(( (d - now) / 60 )) min left)" ;;
  check)
    [[ $d =~ ^[0-9]+$ ]] || d=$hd
    [[ $d =~ ^[0-9]+$ ]] || exit 0
    if [ "$now" -ge "$d" ] || { [[ $hd =~ ^[0-9]+$ ]] && [ "$now" -ge "$hd" ]; }; then logger -t rb-deadline "time cap reached: powering off"; systemctl poweroff; fi ;;
  *) echo "usage: rb-deadline [show | extend HOURS | check]" >&2; exit 2 ;;
esac
EOF
chmod 755 /usr/local/bin/rb-deadline
cat > /etc/systemd/system/rb-deadline.service << 'EOF'
[Unit]
Description=rhobound time cap check
[Service]
Type=oneshot
ExecStart=/usr/local/bin/rb-deadline check
EOF
cat > /etc/systemd/system/rb-deadline.timer << 'EOF'
[Unit]
Description=rhobound time cap check every minute
[Timer]
OnBootSec=2min
OnUnitActiveSec=60s
AccuracySec=10s
[Install]
WantedBy=timers.target
EOF
systemctl daemon-reload
systemctl enable --now rb-deadline.timer
[ -f /var/lib/rb-base.done ] && exit 0
hostnamectl set-hostname __NAME__
grep -q " __NAME__\$" /etc/hosts || echo "127.0.1.1 __NAME__" >> /etc/hosts
grep -q '^preserve_hostname' /etc/cloud/cloud.cfg && sed -i 's/^preserve_hostname:.*/preserve_hostname: true/' /etc/cloud/cloud.cfg || echo 'preserve_hostname: true' >> /etc/cloud/cloud.cfg
export DEBIAN_FRONTEND=noninteractive
systemctl disable --now unattended-upgrades apt-daily.timer apt-daily-upgrade.timer 2> /dev/null || true
apt-get -o DPkg::Lock::Timeout=600 update
apt-get -o DPkg::Lock::Timeout=600 install -y chrony curl jq ca-certificates rsync tmux unzip zstd htop sysstat
# clocks: the Amazon Time Sync Service (the span timestamps of different machines are compared)
mkdir -p /etc/chrony/sources.d
echo "server 169.254.169.123 prefer iburst minpoll 4 maxpoll 4" > /etc/chrony/sources.d/aws.sources
systemctl enable --now chrony
chronyc reload sources || systemctl restart chrony
if ! { curl -fsSL "https://awscli.amazonaws.com/awscli-exe-linux-$(uname -m).zip" -o /tmp/awscliv2.zip && unzip -q -o /tmp/awscliv2.zip -d /tmp && /tmp/aws/install --update; }; then
  snap install aws-cli --classic && ln -sf /snap/bin/aws /usr/local/bin/aws     # systemd units do not search /snap/bin
fi
install -d -m 1777 /var/lib/rb/out /var/lib/rb/out/_events
install -d -m 755 /var/lib/rb/out/_node
cat > /etc/rb.env << 'EOF'
RB_CAMPAIGN=__CAMPAIGN__
RB_BUCKET=__BUCKET__
RB_PREFIX=__PREFIX__
RB_KC=__KC__
RB_ROLE=__ROLE__
AWS_DEFAULT_REGION=__REGION__
EOF
# upload /var/lib/rb/out to S3: new and changed files only, never a delete; "rb-sync now" waits for a running upload, then uploads
cat > /usr/local/bin/rb-sync << 'EOF'
#!/bin/bash
set -a; . /etc/rb.env; set +a
exec 9> /run/rb-sync.lock
if [ "${1:-}" = now ]; then flock -w 100 9 || exit 1; else flock -n 9 || exit 0; fi
aws s3 sync /var/lib/rb/out "s3://$RB_BUCKET/$RB_PREFIX/" --only-show-errors --exclude '*.open' --exclude '*.tmp' --exclude '.tmp/*' && date -u +%FT%TZ > /var/lib/rb/last-sync-ok
EOF
chmod 755 /usr/local/bin/rb-sync
cat > /etc/systemd/system/rb-sync.service << 'EOF'
[Unit]
Description=upload rhobound files to S3
[Service]
Type=oneshot
Environment=HOME=/root
ExecStart=/usr/local/bin/rb-sync
EOF
cat > /etc/systemd/system/rb-sync.timer << 'EOF'
[Unit]
Description=upload rhobound files to S3 every 30 s
[Timer]
OnBootSec=60
OnUnitActiveSec=30
AccuracySec=1s
[Install]
WantedBy=timers.target
EOF
cat > /etc/systemd/system/rb-final-sync.service << 'EOF'
[Unit]
Description=last upload of rhobound files at shutdown
After=network-online.target
Wants=network-online.target
[Service]
Type=oneshot
RemainAfterExit=yes
Environment=HOME=/root
ExecStart=/bin/true
ExecStop=/usr/local/bin/rb-sync now
TimeoutStopSec=110
[Install]
WantedBy=multi-user.target
EOF
systemctl daemon-reload
systemctl enable --now rb-sync.timer rb-final-sync.service
# a record of the machine (type, zone, CPU, kernel, AMI), uploaded with the data so every capture says where it was taken
M=http://169.254.169.254/latest
tok=$(curl -fsS -m 3 -X PUT "$M/api/token" -H 'X-aws-ec2-metadata-token-ttl-seconds: 60' || true)
md() { curl -fsS -m 3 -H "X-aws-ec2-metadata-token: $tok" "$M/meta-data/$1" 2> /dev/null || echo unknown; }
jq -n --arg name __NAME__ --arg kc __KC__ --arg role __ROLE__ --arg id "$(md instance-id)" --arg type "$(md instance-type)" --arg az "$(md placement/availability-zone)" \
      --arg ami "$(md ami-id)" --arg kernel "$(uname -r)" --arg cpu "$(lscpu | sed -n 's/^Model name: *//p' | head -n 1)" --arg ncpu "$(nproc)" \
      --arg mem_mb "$(free -m | awk '/^Mem:/ {print $2}')" --arg boot "$(date -u +%FT%TZ)" --arg deadline "$(date -u -d "@$(cat /var/lib/rb/deadline)" +%FT%TZ)" \
      '{name:$name, kc:$kc, role:$role, instance_id:$id, instance_type:$type, zone:$az, ami:$ami, kernel:$kernel, cpu_model:$cpu, vcpus:($ncpu|tonumber), mem_mb:($mem_mb|tonumber), base_boot:$boot, deadline:$deadline}' \
      > /var/lib/rb/out/_node/boot.json
date -u +%FT%TZ > /var/lib/rb/base-ready-at
touch /var/lib/rb-base.done
/usr/local/bin/rb-sync now || true
echo "RB: base done on __NAME__" > /dev/console
USERDATA
}

# --------------------------------------------------------------------------------------------------------------------------------- launch
LAUNCHED=(); MISSING=(); GOT=(); NOCAP=" "
launch_node() {   # $1 name $2 kc $3 role $4 type $5 disk: its type first, then the fallbacks offered in the zone
  local name=$1 kc=$2 role=$3 type=$4 disk=$5 ex ud errf t id attempt args profile=$NODE_ROLE hop=1
  if [[ $role == tools ]]; then profile=$TOOLS_ROLE; fi     # hop limit 1 everywhere: no pod needs AWS (images come through the ecr pull secret)
  local market=() life=on-demand
  if is_spot "$role"; then market=(--instance-market-options 'MarketType=spot,SpotOptions={SpotInstanceType=one-time,InstanceInterruptionBehavior=terminate}'); life=spot; fi
  ex=$(find_instance "$name"); if [[ -n $ex ]]; then say "$name exists ($ex): not re-created"; return 0; fi
  ud="$WORK/ud-$name"; errf="$WORK/err-$name"; render_userdata "$name" "$kc" "$role" > "$ud"
  for t in $(types_for "$type"); do
    offered "$t" || continue
    [[ $NOCAP != *" $t "* ]] || continue          # no capacity earlier in this run: do not ask again
    [[ $(vcpus_of "$t") == "$(vcpus_of "$type")" ]] || continue
    for attempt in 1 2 3 4 5 6; do
      args=(ec2 run-instances --image-id "$AMI" --instance-type "$t" --key-name "$KEY_NAME" --subnet-id "$SUBNET" --security-group-ids "$SG"
            --associate-public-ip-address --count 1 --iam-instance-profile "Name=$profile" --instance-initiated-shutdown-behavior terminate
            --block-device-mappings "DeviceName=/dev/sda1,Ebs={VolumeSize=$disk,VolumeType=gp3,DeleteOnTermination=true,Encrypted=true}"
            --metadata-options "HttpTokens=required,HttpEndpoint=enabled,HttpPutResponseHopLimit=$hop" --user-data "file://$ud" "${market[@]}"
            --tag-specifications "ResourceType=instance,Tags=[{Key=Name,Value=$name},{Key=project,Value=$PROJECT},{Key=cluster,Value=$CLUSTER_TAG},{Key=kc,Value=$kc},{Key=role,Value=$role},{Key=lifecycle,Value=$life},{Key=max_hours,Value=$MAX_HOURS}]"
                                 "ResourceType=volume,Tags=[{Key=Name,Value=$name},{Key=project,Value=$PROJECT},{Key=cluster,Value=$CLUSTER_TAG}]"
            --query 'Instances[0].InstanceId' --output text)
      if id=$(awsm "${args[@]}" 2> "$errf"); then
        if [[ $DRYRUN == 1 ]]; then cat "$errf" >&2; fi
        say "launched $name ($t $life, ${disk} GB, profile $profile) as $id"; LAUNCHED+=("$id"); GOT+=("$name=$t"); return 0
      fi
      cat "$errf" >&2
      if grep -qiE 'Invalid IAM Instance Profile|iamInstanceProfile' "$errf"; then say "the instance profile is not usable yet; waiting 10 s (attempt $attempt of 6)"; sleep 10; continue; fi
      if grep -qiE 'InsufficientInstanceCapacity|capacity-not-available|Unsupported|SpotMaxPriceTooLow|capacity-oversubscribed' "$errf"; then say "no $life capacity for $t in $AZ: trying the next type"; NOCAP+="$t "; break; fi
      if grep -qiE 'VcpuLimitExceeded|MaxSpotInstanceCountExceeded' "$errf"; then say "the $life vCPU quota is full: $name is not launched"; MISSING+=("$name"); return 0; fi
      say "launching $name failed (see the message above). Machines launched so far stay; run  bash $0 up  again to continue, or  bash $0 down"
      exit 1
    done
  done
  say "WARNING: no type with capacity for $name ($(types_for "$type" | paste -sd' ' -)) in $AZ. Run  bash $0 up  again later."
  MISSING+=("$name")
}

up() {
  local name kc role type disk
  require_orch
  init_account
  choose_az
  estimate
  quota_check
  if [[ $QUOTA_OK == 0 && $FORCE != 1 ]]; then die "the machines do not fit the on-demand vCPU quota (nothing was created)"; fi
  if [[ $QUOTA_OK == unknown ]]; then confirm "The vCPU quota could not be read. Continue anyway?" || die "aborted"; fi
  if ! python3 -c "import sys; sys.exit(0 if $EST <= $BUDGET else 1)" && [[ $FORCE != 1 ]]; then die "about $EST USD per hour is over the budget of $BUDGET (nothing was created; set BUDGET or use smaller types)"; fi
  AMI=$(ami); [[ $DRYRUN == 1 || $AMI =~ ^ami-[0-9a-f]+$ ]] || die "could not find the Ubuntu 24.04 AMI (got '$AMI')"; say "AMI $AMI"
  confirm "Create the demo in $REGION ($AZ), about $EST USD/hour? Machines terminate themselves after $MAX_HOURS h (at most $HARD_MAX_HOURS h)." || die "aborted (nothing was created)"
  ensure_bucket
  ensure_iam
  ensure_kms
  ensure_tools_policy
  if [[ $FRESH == 1 && $DRYRUN != 1 ]]; then say "waiting 15 s for the new roles to be usable"; sleep 15; fi
  ensure_ecr
  ensure_key
  ensure_net
  while read -r name kc role type disk; do launch_node "$name" "$kc" "$role" "$type" "$disk"; done < <(nodes)
  if [[ ${#LAUNCHED[@]} -gt 0 && $DRYRUN != 1 ]]; then
    say "waiting for ${#LAUNCHED[@]} machine(s) to run"
    awsr ec2 wait instance-running --instance-ids "${LAUNCHED[@]}" || say "not all machines reached running: check  bash $0 status"
    local id; for id in "${LAUNCHED[@]}"; do awsr ec2 modify-instance-attribute --instance-id "$id" --no-source-dest-check || say "could not turn off the source/dest check of $id"; done
  fi
  [[ ${#GOT[@]} -eq 0 ]] || say "types: ${GOT[*]}"
  if [[ ${#MISSING[@]} -gt 0 ]]; then say "NOT LAUNCHED: ${MISSING[*]}. Run  ORCH_IP=$ORCH_IP bash $0 up  again later to fill them."; exit 3; fi
  say "done. cloud-init needs about 3-5 minutes per machine. Next: bash $0 inventory   and copy ALL of its output to your workstation"
}

# ------------------------------------------------------------------------------------------------------------------------ inventory, status
read -r -d '' INV_PY << 'PY' || true
import json, sys, datetime
mode, project, campaign, region, orch_ip, maxh, hardh, bucket, account, ecr, kms, warns = sys.argv[1:13]
d = json.load(sys.stdin)
rows = []
for r in d.get("Reservations", []):
    for i in r["Instances"]:
        t = {x["Key"]: x["Value"] for x in i.get("Tags", [])}
        rows.append(dict(name=t.get("Name", "?"), kc=t.get("kc", "?"), role=t.get("role", "?"), id=i["InstanceId"], priv=i.get("PrivateIpAddress", "") or "-",
                         pub=i.get("PublicIpAddress", "") or "-", type=i["InstanceType"], state=i["State"]["Name"],
                         zone=i.get("Placement", {}).get("AvailabilityZone", "-"), launch=i["LaunchTime"], maxh=float(t.get("max_hours", maxh))))
order = {"cp": 0, "edge": 1, "load": 2, "app": 3, "ab": 4, "tools": 5}
rows.sort(key=lambda x: (x["kc"] == "tools", x["kc"], order.get(x["role"], 9), x["name"]))
now = datetime.datetime.now(datetime.timezone.utc)
def up_h(x):
    return (now - datetime.datetime.fromisoformat(x["launch"].replace("Z", "+00:00"))).total_seconds() / 3600
if mode == "table":
    print("%-16s %-5s %-5s %-12s %-13s %-14s %-15s %-15s %6s %7s" % ("name", "kc", "role", "type", "state", "zone", "private", "public", "up_h", "left_h*"))
    for x in rows:
        print("%-16s %-5s %-5s %-12s %-13s %-14s %-15s %-15s %6.1f %7.1f" % (x["name"], x["kc"], x["role"], x["type"], x["state"], x["zone"], x["priv"], x["pub"], up_h(x), max(x["maxh"] - up_h(x), 0)))
    print("* left_h is the cap set at launch; your workstation may have moved it (sudo rb-deadline show on a machine).")
    sys.exit(0)
live = [x for x in rows if x["state"] in ("pending", "running")]
if not live:
    sys.exit("no running machines tagged project=%s cluster=%s in %s" % (project, campaign, region))
print("# ---- copy everything from here to your workstation ------------------------------------------------------")
print("# rhobound demo %s in %s, printed %s. ssh is allowed from %s. No secret in this block." % (campaign, region, now.strftime("%F %TZ"), orch_ip or "(see the security group)"))
for w in [w for w in warns.split("|") if w]:
    print("# WARNING: " + w)
print("RS3_REGION=%s" % region)
print("RS3_CAMPAIGN=%s" % campaign)
print("RS3_BUCKET=%s" % bucket)
print("RS3_MAX_HOURS=%s" % maxh)
print("RS3_HARD_MAX_HOURS=%s" % hardh)
print("RS3_SSH_USER=ubuntu")
if orch_ip:
    print("RS3_ORCH_IP=%s" % orch_ip)
for x in live:
    print("RS3_NODE %s kc=%s role=%s type=%s public=%s private=%s id=%s state=%s zone=%s launch=%s" % (
        x["name"], x["kc"], x["role"], x["type"], x["pub"], x["priv"], x["id"], x["state"], x["zone"], x["launch"].replace("+00:00", "Z")))
print("ecr_repo=%s" % ecr)
print("kms_alias=%s" % kms)
print("bucket=%s" % bucket)
print("account=%s" % account)
print("# ---- end -------------------------------------------------------------------------------------------------")
PY
inv_py() { python3 -c "$INV_PY" "$1" "$PROJECT" "$CLUSTER_TAG" "$REGION" "${2:-}" "$MAX_HOURS" "$HARD_MAX_HOURS" "$BUCKET" "$ACCOUNT" "$ECR_URI" "$KMS_ALIAS" "${3:-}"; }
inventory() {
  local orch="" sg warns="" c d all=()
  init_account
  sg=$(sg_id)
  if [[ -n $sg ]]; then
    while read -r c d; do if [[ $d == orchestrator ]]; then all+=("$c"); fi; done < <(sg_ssh_cidrs "$sg")
    if [[ ${#all[@]} -gt 0 ]]; then orch=${all[0]%/32}; fi
    [[ ${#all[@]} -le 1 ]] || warns+="ssh is open to several workstation addresses (${all[*]}): remove the old one with deny-ip|"
  fi
  if [[ -n $ORCH_IP ]]; then
    public_ipv4 "$ORCH_IP" || die "ORCH_IP '$ORCH_IP' is not a public IPv4 address"
    [[ -z $orch || $orch == "$ORCH_IP" ]] || warns+="ssh is open to $orch (the workstation rule), not ORCH_IP=$ORCH_IP: run allow-ip $ORCH_IP|"
    orch=$ORCH_IP
  fi
  [[ -n $orch ]] || warns+="no workstation ssh rule found in $SG_NAME: run up (or allow-ip) first|"
  if ecr_state; then
    if [[ $ECR_FOUND == 1 ]]; then ECR_URI=$(jq -r '.repositories[0].repositoryUri' <<< "$ECR_JSON"); else warns+="the ECR repository $ECR_REPO does not exist yet: run up|"; fi
  else warns+="the ECR repository could not be read|"; fi
  if key_state; then
    if [[ -z $KID ]]; then warns+="the KMS alias $KMS_ALIAS does not exist yet: run up|"; elif [[ $KSTATE != Enabled ]]; then warns+="the KMS key is $KSTATE, not Enabled|"; fi
  else warns+="the KMS alias could not be read|"; fi
  cluster_json | inv_py paste "$orch" "$warns"
}
status() {
  local spent n
  init_account
  cluster_json | inv_py table
  quota_check || true
  spent=$(cluster_json | python3 -c '
import json, sys, datetime
d = json.load(sys.stdin); now = datetime.datetime.now(datetime.timezone.utc); tot = 0.0
for r in d.get("Reservations", []):
    for i in r["Instances"]:
        if i["State"]["Name"] not in ("pending", "running", "stopping", "shutting-down"): continue
        h = (now - datetime.datetime.fromisoformat(i["LaunchTime"].replace("Z", "+00:00"))).total_seconds() / 3600
        c = i.get("CpuOptions", {})
        tot += h * c.get("CoreCount", 0) * c.get("ThreadsPerCore", 1)
print(round(tot, 1))')
  say "vCPU-hours of the running machines since their launch: $spent (at about 0.028 USD per vCPU-hour for m6a, plus disks and IPs)"
  if ecr_state && [[ $ECR_FOUND == 1 ]]; then
    n=$(awsr ecr list-images --repository-name "$ECR_REPO" --output json 2> /dev/null | jq '.imageIds | length' || echo "?")
    say "ECR $ECR_URI: $n image ids"
  else say "ECR $ECR_REPO: none"; fi
  if key_state && [[ -n $KID ]]; then say "KMS $KMS_ALIAS: key $KID, $KSTATE"; else say "KMS $KMS_ALIAS: none"; fi
  say "secrets $SECRET_PREFIX*: $(our_secrets 2> /dev/null | paste -sd' ' - | sed 's/^$/none/')"
}

# ------------------------------------------------------------------------------------------------------------- extend (printed, not run)
extend() {
  local names
  [[ $ARG =~ ^[0-9]+$ && $ARG -ge 1 && $ARG -le $HARD_MAX_HOURS ]] || die "usage: bash $0 extend HOURS   (1..$HARD_MAX_HOURS)"
  names=$(cluster_json | jq -r '[.Reservations[].Instances[] | select(.State.Name == "running" or .State.Name == "pending")
                                 | ((.Tags // []) | map(select(.Key == "Name")) | .[0].Value // empty)] | sort | join(" ")')
  [[ -n $names ]] || die "no running machines of bed $BED ($CLUSTER_TAG) in $REGION"
  say "CloudShell cannot reach the machines (ssh is open to your workstation only). Run these lines on your workstation:"
  echo "for n in $names; do ssh -F ~/.ssh/rbd_aws_config \"\$n\" sudo rb-deadline extend $ARG; done"
  echo "for n in $names; do ssh -F ~/.ssh/rbd_aws_config \"\$n\" sudo rb-deadline show; done"
  say "each machine moves its deadline by $ARG h, never past $HARD_MAX_HOURS h after its own launch."
}

# ----------------------------------------------------------------------------------------------------------------------- ssh access changes
allow_ip() {
  local cidr=$ARG sg; [[ $cidr == */* ]] || cidr=$cidr/32
  cidr_ok "$cidr" || die "usage: bash $0 allow-ip <public IPv4>   (or x.x.x.x/32; private and documentation addresses are refused)"
  sg=$(sg_id); [[ -n $sg ]] || die "no security group $SG_NAME in $REGION: run up first"
  if sg_ssh_cidrs "$sg" | awk '{print $1}' | grep -qxF "$cidr"; then say "ssh is already allowed from $cidr"; return 0; fi
  sg_add_ssh "$sg" "$cidr" added
  say "ssh now also allowed from $cidr"
}
deny_ip() {
  [[ $ARG =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+(/[0-9]+)?$ ]] || die "usage: bash $0 deny-ip x.x.x.x"
  local cidr=$ARG sg; [[ $cidr == */* ]] || cidr=$cidr/32
  sg=$(sg_id); [[ -n $sg ]] || die "no security group $SG_NAME in $REGION"
  if ! sg_ssh_cidrs "$sg" | awk '{print $1}' | grep -qxF "$cidr"; then say "ssh is not allowed from $cidr: nothing to remove"; return 0; fi
  awsm ec2 revoke-security-group-ingress --group-id "$sg" --ip-permissions "IpProtocol=tcp,FromPort=22,ToPort=22,IpRanges=[{CidrIp=$cidr}]" > /dev/null
  say "ssh no longer allowed from $cidr"
}

# -------------------------------------------------------------------------------------------------------------------------------- secrets
# The value is read with read -s (or one line from a pipe), written with printf (a builtin: in no process's argv) to a mode-600 file
# and given to the CLI as file://. It is never echoed, logged or read back.
secret_name() {
  [[ $ARG =~ ^[A-Za-z0-9][A-Za-z0-9_-]{0,47}$ ]] || die "usage: bash $0 $CMD NAME   (NAME: letters, digits, - and _, e.g. judge-key)"
  SECRET_ID=$SECRET_PREFIX$ARG
}
secret_describe() {   # sets SEC_JSON; 0 found, 1 not found; dies on other errors
  if SEC_JSON=$(awsr secretsmanager describe-secret --secret-id "$SECRET_ID" --output json 2> "$WORK/sec.err"); then return 0; fi
  grep -q ResourceNotFoundException "$WORK/sec.err" && return 1
  cat "$WORK/sec.err" >&2; die "cannot read the secret $SECRET_ID (see above)"
}
secret_ours() { jq -e --arg p "$PROJECT" 'any(.Tags[]?; .Key == "project" and .Value == $p)' <<< "$SEC_JSON" > /dev/null; }
secret() {
  local f="$WORK/secret.val" val=""
  secret_name
  init_account
  set +x
  if [[ -t 0 ]]; then read -r -s -p "Value for $SECRET_ID (input hidden; Enter ends it): " val || true; echo >&2
  else IFS= read -r val || true; fi
  val=${val%$'\r'}
  val=${val#"${val%%[![:space:]]*}"}; val=${val%"${val##*[![:space:]]}"}
  [[ -n $val ]] || die "the value is empty: nothing was stored"
  (umask 077; printf '%s' "$val" > "$f")
  val=""
  if secret_describe; then
    secret_ours || die "the secret $SECRET_ID exists but is not tagged project=$PROJECT: refusing to touch it"
    if [[ -n $(jq -r '.DeletedDate // empty' <<< "$SEC_JSON") ]]; then
      awsm secretsmanager restore-secret --secret-id "$SECRET_ID" > /dev/null; say "$SECRET_ID was pending deletion: restored"
    fi
    awsm secretsmanager put-secret-value --secret-id "$SECRET_ID" --secret-string "file://$f" > /dev/null
    say "stored a new value in $SECRET_ID"
  else
    awsm secretsmanager create-secret --name "$SECRET_ID" --description "rhobound $CAMPAIGN: $ARG (read by role $TOOLS_ROLE only)" \
      --secret-string "file://$f" --tags "Key=project,Value=$PROJECT" "Key=cluster,Value=$CAMPAIGN" > /dev/null
    say "created $SECRET_ID (tagged project=$PROJECT)"
  fi
  rm -f "$f"
  say "only rbd-tools1 (role $TOOLS_ROLE) may read it: aws secretsmanager get-secret-value --secret-id $SECRET_ID. The value was not printed."
}
secret_rm() {
  secret_name
  init_account
  secret_describe || { say "no secret $SECRET_ID: nothing to remove"; return 0; }
  secret_ours || die "the secret $SECRET_ID is not tagged project=$PROJECT: refusing to touch it"
  [[ -z $(jq -r '.DeletedDate // empty' <<< "$SEC_JSON") ]] || { say "$SECRET_ID is already pending deletion"; return 0; }
  confirm "Delete $SECRET_ID (recoverable for $SECRET_DELETE_DAYS days)?" || die "aborted"
  awsm secretsmanager delete-secret --secret-id "$SECRET_ID" --recovery-window-in-days "$SECRET_DELETE_DAYS" > /dev/null
  say "$SECRET_ID scheduled for deletion in $SECRET_DELETE_DAYS days (bash $0 secret $ARG restores it with a new value). Revoke the key at its provider too."
}

# ------------------------------------------------------------------------------------------------------------------------ down, destroy
live_ids() { cluster_json | jq -r '[.Reservations[].Instances[] | select(.State.Name != "terminated" and .State.Name != "shutting-down") | .InstanceId] | join(" ")'; }
down() {
  local ids a
  init_account
  ids=$(live_ids)
  [[ -n $ids ]] || { say "no machines of bed $BED ($CLUSTER_TAG) to terminate"; return 0; }
  cluster_json | inv_py table >&2
  say "This TERMINATES every machine above. Each uploads once more to S3 while it shuts down; what was not uploaded is lost with its disk."
  if [[ $YES != 1 && $DRYRUN != 1 ]]; then read -r -p "Type the bed's id ($CLUSTER_TAG) to confirm: " a || a=""; [[ $a == "$CLUSTER_TAG" ]] || die "aborted"; fi
  # shellcheck disable=SC2086
  awsm ec2 terminate-instances --instance-ids $ids > /dev/null
  say "terminating: $ids. Network, roles, ECR, KMS key and secrets stay (the two beds share them; delete them in the console once both beds are down); the bucket is never touched."
}
del_role() {   # $1 role (and instance profile) $2 inline policy; appends to LEFT what could not be removed
  local r=$1 p=$2
  if awsr iam get-instance-profile --instance-profile-name "$r" > /dev/null 2>&1; then
    if [[ $(awsr iam get-instance-profile --instance-profile-name "$r" --query 'length(InstanceProfile.Roles)' --output text 2> /dev/null || echo 0) != 0 ]]; then
      awsm iam remove-role-from-instance-profile --instance-profile-name "$r" --role-name "$r" > /dev/null || LEFT+=("role $r in profile $r")
    fi
    awsm iam delete-instance-profile --instance-profile-name "$r" > /dev/null || LEFT+=("instance profile $r")
  fi
  if role_exists "$r"; then
    if awsr iam get-role-policy --role-name "$r" --policy-name "$p" > /dev/null 2>&1; then
      awsm iam delete-role-policy --role-name "$r" --policy-name "$p" > /dev/null || LEFT+=("policy $p of $r")
    fi
    awsm iam delete-role --role-name "$r" > /dev/null || LEFT+=("role $r")
  fi
}
destroy() {
  local ids sg sub igw vpc i s secs
  LEFT=()
  init_account
  ids=$(live_ids)
  if [[ -n $ids ]]; then
    down
    # shellcheck disable=SC2086
    if [[ $DRYRUN != 1 ]]; then say "waiting for the machines to terminate"; awsr ec2 wait instance-terminated --instance-ids $ids || say "not all terminated yet"; fi
  fi
  confirm "Delete the network, key pair $KEY_NAME, roles $NODE_ROLE and $TOOLS_ROLE, and $KMS_ALIAS (its key is scheduled for deletion in $KEY_DELETE_DAYS days)? The S3 bucket is NOT touched." || die "aborted"
  sg=$(sg_id)
  if [[ -n $sg ]]; then
    for i in 1 2 3 4 5 6 7; do
      if awsm ec2 delete-security-group --group-id "$sg" > /dev/null 2> "$WORK/sg.err"; then sg=""; break; fi
      ((i < 7)) || { cat "$WORK/sg.err" >&2; break; }
      say "security group still in use (attempt $i of 6); retrying in 15 s"; sleep 15
    done
    [[ -z $sg ]] || LEFT+=("security group $sg")
  fi
  for sub in $(tagged describe-subnets '.Subnets[].SubnetId'); do awsm ec2 delete-subnet --subnet-id "$sub" > /dev/null || LEFT+=("subnet $sub"); done
  vpc=$(tagged describe-vpcs '.Vpcs[0].VpcId'); igw=$(tagged describe-internet-gateways '.InternetGateways[0].InternetGatewayId')
  if [[ -n $igw && -n $vpc ]]; then awsm ec2 detach-internet-gateway --internet-gateway-id "$igw" --vpc-id "$vpc" > /dev/null 2>&1 || true; fi
  if [[ -n $igw ]]; then awsm ec2 delete-internet-gateway --internet-gateway-id "$igw" > /dev/null || LEFT+=("internet gateway $igw"); fi
  if [[ -n $vpc ]]; then awsm ec2 delete-vpc --vpc-id "$vpc" > /dev/null || LEFT+=("VPC $vpc"); fi
  if awsr ec2 describe-key-pairs --key-names "$KEY_NAME" > /dev/null 2>&1; then awsm ec2 delete-key-pair --key-name "$KEY_NAME" > /dev/null || LEFT+=("key pair $KEY_NAME"); fi
  if key_state; then
    if [[ -n $KID ]]; then
      if [[ $KSTATE != PendingDeletion ]]; then
        awsm kms schedule-key-deletion --key-id "$KID" --pending-window-in-days "$KEY_DELETE_DAYS" > /dev/null || LEFT+=("KMS key $KID (deletion not scheduled)")
      fi
      awsm kms delete-alias --alias-name "$KMS_ALIAS" > /dev/null || LEFT+=("KMS alias $KMS_ALIAS")
      say "KMS key $KID: deletion scheduled in $KEY_DELETE_DAYS days (cancel it in the KMS console to keep it); alias removed"
    fi
  else LEFT+=("KMS (the alias could not be read)"); fi
  del_role "$NODE_ROLE" "$NODE_POLICY"
  del_role "$TOOLS_ROLE" "$TOOLS_POLICY"
  if ecr_state; then
    if [[ $ECR_FOUND == 1 ]]; then
      if ! ecr_ours; then say "ECR $ECR_REPO is not tagged project=$PROJECT: left alone"
      elif confirm "Delete the ECR repository $ECR_REPO with ALL its images and signatures?"; then
        awsm ecr delete-repository --repository-name "$ECR_REPO" --force > /dev/null || LEFT+=("ECR repository $ECR_REPO")
        say "deleted the ECR repository $ECR_REPO"
      else say "kept the ECR repository $ECR_REPO (bash $0 destroy again deletes it)"; fi
    fi
  else LEFT+=("ECR (the repository could not be read)"); fi
  secs=$(our_secrets) || { LEFT+=("secrets (could not be listed)"); secs=""; }
  if [[ -n $secs ]]; then
    if confirm "Schedule deletion ($SECRET_DELETE_DAYS-day recovery window) of the secrets: $(paste -sd' ' - <<< "$secs")?"; then
      for s in $secs; do awsm secretsmanager delete-secret --secret-id "$s" --recovery-window-in-days "$SECRET_DELETE_DAYS" > /dev/null || LEFT+=("secret $s"); done
    else say "kept the secrets: $(paste -sd' ' - <<< "$secs")"; fi
  fi
  if [[ ${#LEFT[@]} -gt 0 ]]; then die "NOT removed: $(printf '%s; ' "${LEFT[@]}")run  bash $0 destroy  again in a minute"; fi
  say "removed: machines, security group, subnet, internet gateway, VPC, key pair, roles, KMS alias (key pending deletion), ECR repo and secrets (unless kept above)."
  say "what stays: the bucket $BUCKET and its $CAMPAIGN/ objects (never touched), the KMS key until its deletion date, deleted secrets for $SECRET_DELETE_DAYS days."
}

case $CMD in
  plan) plan ;;
  up) up ;;
  inventory) inventory ;;
  status) status ;;
  extend) extend ;;
  allow-ip) allow_ip ;;
  deny-ip) deny_ip ;;
  secret) secret ;;
  secret-rm) secret_rm ;;
  down) down ;;
  destroy) die "destroy is refused in spawn_two.sh: the two beds share roles, key pair, ECR repository, KMS key and secrets. Run  BED=1 bash $0 down  and  BED=2 bash $0 down" ;;
  *) die "unknown command '$CMD' (plan | up | inventory | status | extend HOURS | allow-ip IP | deny-ip IP | secret NAME | secret-rm NAME | down | destroy | help)" ;;
esac
