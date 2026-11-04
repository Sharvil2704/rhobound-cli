#!/usr/bin/env bash
# live_mcp.sh: rhobound's MCP server live on AWS for a demo: one small arm64 machine behind HTTPS, one bearer token.
# Run it in AWS CloudShell:
#   bash live_mcp.sh up       # launch (asks; YES=1 does not), then print the URL, the token and Muse's settings entry
#   bash live_mcp.sh status   # the machine, its boot log's last lines, and a check of the endpoint with the token
#   bash live_mcp.sh token    # print the token again
#   bash live_mcp.sh down     # terminate the machine and delete its security group (asks; YES=1 does not)
# What up makes, all tagged project=rhobound-live, in the region's default VPC:
#   - a security group with 80 and 443 open (Let's Encrypt and HTTPS) and nothing else: no ssh;
#   - one TYPE machine (Ubuntu 24.04, arm64) with no IAM role and IMDSv2 only, which shuts down, and so terminates,
#     after HOURS hours.
# The machine runs live_mcp_boot.sh, fetched from this repository at the commit REF names (resolved here to its sha): it
# builds rhobound and rhobound-mcp at that commit and serves the repository's sample traces on
# https://<public IP, dashed>.sslip.io/mcp. The token is made here, kept in STATE (0600), and the machine stores only
# its sha256. About 3-5 minutes after up, status says READY.
# Env: REGION [$AWS_REGION, else ap-south-1]  REF [rhobound-mcp]  TYPE [t4g.small]  HOURS [8]  YES [0]
#      STATE [~/.rhobound-live]  DRYRUN [0; 1 = print every AWS change instead of making it]
#      BOOT [tests: a local live_mcp_boot.sh instead of the one at REF's commit]
set -euo pipefail
REGION=${REGION:-${AWS_REGION:-ap-south-1}}
REF=${REF:-rhobound-mcp}
TYPE=${TYPE:-t4g.small}
HOURS=${HOURS:-8}
YES=${YES:-0}
DRYRUN=${DRYRUN:-0}
STATE=${STATE:-$HOME/.rhobound-live}
REPO=Sharvil2704/rhobound-cli
SSM_AMI=/aws/service/canonical/ubuntu/server/24.04/stable/current/arm64/hvm/ebs-gp3/ami-id
TAG=rhobound-live

say() { echo "[$(date -u +%H:%M:%S)] $*" >&2; }
die() { echo "error: $*" >&2; exit 1; }
awsr() { aws --region "$REGION" "$@"; }
awsm() {   # mutations; with DRYRUN=1 they are only printed
  if [[ $DRYRUN == 1 ]]; then echo "DRYRUN aws --region $REGION $*" >&2; echo "dryrun-id"; return 0; fi
  awsr "$@"
}
confirm() { [[ $YES == 1 || $DRYRUN == 1 ]] && return 0; read -r -p "$1 [y/N] " a; [[ $a == y || $a == Y ]]; }
if ! [[ $HOURS =~ ^[0-9]+$ ]] || ((HOURS < 1 || HOURS > 24)); then die "HOURS must be 1 to 24"; fi
for c in aws jq curl openssl; do command -v "$c" > /dev/null || die "$c is required (AWS CloudShell has them)"; done
install -d -m 0700 "$STATE"
st() { [[ -f $STATE/state.env ]] && sed -n "s/^$1=//p" "$STATE/state.env"; }

up() {
  [[ -z $(st instance) ]] || die "a live endpoint is already recorded ($(st instance)): bash live_mcp.sh down first"
  local sha ami vpc subnet sg token tsha expires boot ud iid ip host
  sha=$(curl -fsS "https://api.github.com/repos/$REPO/commits/$REF" | jq -r .sha)
  [[ $sha =~ ^[0-9a-f]{40}$ ]] || die "cannot resolve $REF on $REPO"
  ami=$(awsr ssm get-parameter --name "$SSM_AMI" --query Parameter.Value --output text)
  vpc=$(awsr ec2 describe-vpcs --filters Name=is-default,Values=true --query 'Vpcs[0].VpcId' --output text)
  [[ $vpc == vpc-* ]] || die "no default VPC in $REGION (aws ec2 create-default-vpc --region $REGION makes one)"
  subnet=$(awsr ec2 describe-subnets --filters "Name=vpc-id,Values=$vpc" Name=default-for-az,Values=true \
    --query 'Subnets[0].SubnetId' --output text)
  [[ $subnet == subnet-* ]] || die "no default subnet in $vpc"
  say "region $REGION, $TYPE from $ami in $subnet, rhobound at $sha (${REF}), terminates itself after $HOURS h"
  confirm "Launch it (about 0.02 USD per hour)?" || die "nothing launched"
  boot=$STATE/live_mcp_boot.sh
  if [[ -n ${BOOT:-} ]]; then cp "$BOOT" "$boot"; else
    curl -fsS "https://raw.githubusercontent.com/$REPO/$sha/bed/aws/live_mcp_boot.sh" -o "$boot"
  fi
  token=$(openssl rand -hex 32)
  tsha=$(printf '%s' "$token" | openssl dgst -sha256 | sed 's/.*= *//')
  expires=$(date -u -d "+$((HOURS + 1)) hours" +%Y-%m-%dT%H:%M:%SZ)
  ud=$STATE/user-data.sh
  { echo '#!/bin/bash'
    printf 'export LIVE_SHA=%s LIVE_TOKEN_SHA=%s LIVE_EXPIRES=%s LIVE_HOURS=%s\n' "$sha" "$tsha" "$expires" "$HOURS"
    tail -n +2 "$boot"; } > "$ud"
  sg=$(awsm ec2 create-security-group --group-name "$TAG-$(date -u +%Y%m%d%H%M%S)" --vpc-id "$vpc" \
    --description "rhobound live MCP demo: HTTPS and Let's Encrypt only" \
    --tag-specifications "ResourceType=security-group,Tags=[{Key=project,Value=$TAG}]" --query GroupId --output text)
  for p in 80 443; do
    awsm ec2 authorize-security-group-ingress --group-id "$sg" --protocol tcp --port "$p" --cidr 0.0.0.0/0 > /dev/null
  done
  iid=$(awsm ec2 run-instances --image-id "$ami" --instance-type "$TYPE" --subnet-id "$subnet" --security-group-ids "$sg" \
    --associate-public-ip-address --user-data "file://$ud" --instance-initiated-shutdown-behavior terminate \
    --metadata-options HttpTokens=required,HttpPutResponseHopLimit=1,HttpEndpoint=enabled \
    --tag-specifications "ResourceType=instance,Tags=[{Key=Name,Value=$TAG},{Key=project,Value=$TAG}]" \
    --query 'Instances[0].InstanceId' --output text) ||
    { awsm ec2 delete-security-group --group-id "$sg" > /dev/null || true; die "run-instances failed; $sg was deleted"; }
  printf '%s' "$token" > "$STATE/token" && chmod 0600 "$STATE/token"
  if [[ $DRYRUN == 1 ]]; then ip=192.0.2.10; else
    awsr ec2 wait instance-running --instance-ids "$iid"
    ip=$(awsr ec2 describe-instances --instance-ids "$iid" --query 'Reservations[0].Instances[0].PublicIpAddress' --output text)
  fi
  host=${ip//./-}.sslip.io
  printf 'instance=%s\nsg=%s\nhost=%s\nsha=%s\nregion=%s\n' "$iid" "$sg" "$host" "$sha" "$REGION" > "$STATE/state.env"
  say "launched $iid; it builds for about 3-5 minutes: run 'bash live_mcp.sh status' until it says READY"
  show
}

show() {   # the URL, the token, and the command that points Muse Code's rhobound entry at this endpoint
  local host; host=$(st host); [[ -n $host ]] || die "nothing recorded: bash live_mcp.sh up"
  echo "URL    https://$host/mcp"
  echo "token  $(cat "$STATE/token")"
  echo
  echo "On your laptop, keep the token in the environment (Muse expands \${RHOBOUND_TOKEN} in its settings):"
  echo "  export RHOBOUND_TOKEN=<the token>"
  echo "and make Muse's rhobound entry this endpoint, under the key the settings file already uses (after"
  echo "'muse plugins approve' it is mcpServers; a file with both keys turns MCP off):"
  printf "  f=~/.config/muse/settings.json && jq --arg u '%s' '(if has(\"mcpServers\") then \"mcpServers\" else \"mcp_servers\" end) as \$k | .[\$k].rhobound = {transport: \"streamable_http\", url: \$u, headers: {Authorization: \"Bearer \${RHOBOUND_TOKEN}\"}, enabled: true, mode: \"optional\"}' \"\$f\" > \"\$f.new\" && mv \"\$f.new\" \"\$f\"\n" "https://$host/mcp"
}

status() {
  local iid host code; iid=$(st instance); host=$(st host)
  [[ -n $iid ]] || die "nothing recorded: bash live_mcp.sh up"
  echo "machine  $iid: $(awsr ec2 describe-instances --instance-ids "$iid" --query 'Reservations[0].Instances[0].State.Name' --output text 2> /dev/null || echo unknown)"
  echo "boot     $(awsr ec2 get-console-output --instance-id "$iid" --latest --output text 2> /dev/null | grep -a 'rhobound-live:' | tail -n 3 | sed 's/.*rhobound-live: //' | paste -sd'|' - | sed 's/|/ | /g')"
  code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 10 "https://$host/healthz" || true)
  echo "healthz  https://$host/healthz: HTTP $code"
  code=$(curl -s -o "$STATE/tools.json" -w '%{http_code}' --max-time 20 -X POST "https://$host/mcp" \
    -H "Authorization: Bearer $(cat "$STATE/token")" -H 'Content-Type: application/json' -H 'Accept: application/json, text/event-stream' \
    -d '{"jsonrpc":"2.0","id":1,"method":"tools/list","params":{}}' || true)
  echo "tools    HTTP $code: $(jq -r '[.result.tools[].name] | join(" ")' "$STATE/tools.json" 2> /dev/null || echo none)"
}

down() {
  local iid sg; iid=$(st instance); sg=$(st sg)
  [[ -n $iid ]] || die "nothing recorded"
  confirm "Terminate $iid and delete $sg?" || die "nothing changed"
  awsm ec2 terminate-instances --instance-ids "$iid" > /dev/null
  [[ $DRYRUN == 1 ]] || awsr ec2 wait instance-terminated --instance-ids "$iid"
  awsm ec2 delete-security-group --group-id "$sg" > /dev/null
  rm -f "$STATE/state.env" "$STATE/token" "$STATE/tools.json"
  say "terminated $iid, deleted $sg"
}

case ${1:-} in
  up) up ;;
  status) status ;;
  token) show ;;
  down) down ;;
  *) sed -n '2,/^set -euo/p' "$0" | sed '$d' | sed 's/^# \{0,1\}//'; exit 2 ;;
esac
