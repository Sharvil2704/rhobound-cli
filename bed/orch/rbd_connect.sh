#!/usr/bin/env bash
# rbd_connect.sh: the orchestrator's side of the demo1 machines (spawned from CloudShell with spawn_demo.sh). ssh only; no AWS credentials here.
#
#   rbd_connect.sh seed FILE|-          read the pasted output of `spawn_demo.sh inventory`; writes the seed and an ssh config of its own
#   rbd_connect.sh list                 the machines in the seed, and the ECR repository, KMS alias, bucket
#   rbd_connect.sh test [TARGET]        connect to each machine at once: base ready, type, CPUs, memory, disk, clock, time cap, S3 upload
#   rbd_connect.sh ssh NODE [CMD...]    a shell (or one command) on a machine
#   rbd_connect.sh exec TARGET CMD...   one command on several machines at once; output per machine (logs in STATE/logs)
#   rbd_connect.sh myip                 the address the machines allow ssh from (the seed's ORCH_IP); this box's own public IPv4
#                                       is read in the EC2 console (this box never asks an outside service, SPEC 0)
# TARGET: a node name, a cluster (d, tools), a role (cp, edge, load, app, ab, tools), or all (the default).
# The paste: KEY=VALUE lines with any upper-case prefix (RBD_REGION=, RS3_REGION=, ...: REGION CAMPAIGN BUCKET ORCH_IP MAX_HOURS
# HARD_MAX_HOURS SSH_USER), "<PREFIX>_NODE name kc=.. role=.. type=.. public=.. private=.. id=.. state=.. zone=.. launch=.." rows,
# and the lines ecr_repo=, kms_alias=, bucket=, account= (SPEC 2). Files: see rbd_lib.sh. RBD_DRY=1: remote commands are printed.
# shellcheck disable=SC2015,SC2016
set -uo pipefail
RBD_ME=rbd_connect
# shellcheck source=rbd_lib.sh
. "$(dirname "$(readlink -f "$0")")/rbd_lib.sh"
MAX_NODES=16
IPRE='^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$'

res() {   # TARGET -> node names, one per line
  local a=${1:-all} out
  case $a in
    all) out=$(running) ;;
    *) out=$(jq -r --arg a "$a" '.nodes | to_entries[] | select(.value.state == "running" and .value.public != "-")
                                 | select(.key == $a or .value.kc == $a or .value.role == $a) | .key' "$SEED") ;;
  esac
  [ -n "$out" ] || die "no running machine matches '$a' (known: $(running | tr '\n' ' '))" 2
  echo "$out"
}
par() {   # par FUNCTION NODE...: runs FUNCTION for every node at once; prints each node's output afterwards; 1 if any failed
  local fn=$1 d n rc=0; shift
  mkdir -p "$STATE/logs"; d=$(mktemp -d "$STATE/.par.XXXXXX") || return 1
  for n in "$@"; do ( "$fn" "$n" > "$d/$n.out" 2>&1; echo $? > "$d/$n.rc" ) & done
  wait
  for n in "$@"; do
    cp "$d/$n.out" "$STATE/logs/$fn-$n.log"
    sed "s/^/[$n] /" "$d/$n.out"
    [ "$(cat "$d/$n.rc" 2> /dev/null)" = 0 ] || { rc=1; echo "[$n] FAILED ($fn; log $STATE/logs/$fn-$n.log)"; }
  done
  rm -rf "$d"; return $rc
}

# ------------------------------------------------------------------------------------------------------------------------------ seed
seed() {
  local src=${1:-} line name rest kv k v rows="" nrows=0 region="" camp="" bucket="" bucket2="" orch="" maxh="" hardh="" tmp
  local ecr="" kms="" account="" warned=""
  [ -n "$src" ] || die "usage: $0 seed FILE   (or - to read the paste from stdin)" 2
  [[ $src == - || -f $src ]] || die "no such file: $src" 2
  mkdir -p "$STATE" "$(dirname "$SSHC")"
  while IFS= read -r line || [ -n "$line" ]; do
    line=${line%$'\r'}
    case $line in
      [A-Z]*_REGION=*) region=${line#*=}; [[ $region =~ ^[a-z]{2}-[a-z]+-[0-9]$ ]] || die "bad region: $region" 2 ;;
      [A-Z]*_CAMPAIGN=*) camp=${line#*=}; [[ $camp =~ ^[a-z][a-z0-9]{1,11}$ ]] || die "bad campaign: $camp" 2 ;;
      [A-Z]*_BUCKET=*) bucket=${line#*=}; [[ $bucket =~ ^[a-z0-9][a-z0-9.-]{2,62}$ ]] || die "bad bucket: $bucket" 2 ;;
      [A-Z]*_ORCH_IP=*) orch=${line#*=}; [[ $orch =~ $IPRE ]] || die "bad orchestrator IP: $orch" 2 ;;
      [A-Z]*_HARD_MAX_HOURS=*) hardh=${line#*=}; [[ $hardh =~ ^[0-9]+$ ]] || die "bad HARD_MAX_HOURS" 2 ;;
      [A-Z]*_MAX_HOURS=*) maxh=${line#*=}; [[ $maxh =~ ^[0-9]+$ ]] || die "bad MAX_HOURS" 2 ;;
      [A-Z]*_SSH_USER=*) [ "${line#*=}" = ubuntu ] || die "unexpected SSH_USER: ${line#*=}" 2 ;;
      ecr_repo=*) ecr=${line#*=}; [[ $ecr =~ ^[0-9]{12}\.dkr\.ecr\.[a-z]{2}-[a-z]+-[0-9]\.amazonaws\.com/rhobound-demo/kshop$ ]] || die "bad ecr_repo: $ecr" 2 ;;
      kms_alias=*) kms=${line#*=}; [[ $kms =~ ^alias/[A-Za-z0-9/_-]{1,250}$ ]] || die "bad kms_alias: $kms" 2 ;;
      bucket=*) bucket2=${line#*=}; [[ $bucket2 =~ ^[a-z0-9][a-z0-9.-]{2,62}$ ]] || die "bad bucket: $bucket2" 2 ;;
      account=*) account=${line#*=}; [[ $account =~ ^[0-9]{12}$ ]] || die "bad account: $account" 2 ;;
      [A-Z]*_NODE" "*)
        read -r _ name rest <<< "$line"
        [[ $name =~ ^[a-z][a-z0-9-]{1,40}$ ]] || die "bad node name in: $line" 2
        local kc="" role="" type="" pub="" priv="" id="" state="" zone="" launch=""
        for kv in $rest; do
          k=${kv%%=*}; v=${kv#*=}
          case $k in
            kc) [[ $v =~ ^[a-z][a-z0-9]{0,5}$ ]] || die "bad kc in: $line" 2; kc=$v ;;
            role) [[ $v =~ ^(cp|edge|load|app|ab|tools)$ ]] || die "bad role in: $line" 2; role=$v ;;
            type) [[ $v =~ ^[a-z0-9-]+\.[a-z0-9]+$ ]] || die "bad type in: $line" 2; type=$v ;;
            public) [[ $v == - || $v =~ $IPRE ]] || die "bad public ip in: $line" 2; pub=$v ;;
            private) [[ $v == - || $v =~ $IPRE ]] || die "bad private ip in: $line" 2; priv=$v ;;
            id) [[ $v =~ ^i-[0-9a-f]{8,17}$ ]] || die "bad instance id in: $line" 2; id=$v ;;
            state) [[ $v =~ ^[a-z-]{3,20}$ ]] || die "bad state in: $line" 2; state=$v ;;
            zone) [[ $v == - || $v =~ ^[a-z]{2}-[a-z]+-[0-9][a-z]$ ]] || die "bad zone in: $line" 2; zone=$v ;;
            launch) [[ $v =~ ^[0-9T:+Z.-]{10,32}$ ]] || die "bad launch in: $line" 2; launch=$v ;;
            *) [ -n "$warned" ] || echo "seed: ignoring unknown field '$k' (and any others) in the node rows" >&2; warned=1 ;;
          esac
        done
        [ -n "$kc" ] && [ -n "$role" ] && [ -n "$type" ] && [ -n "$pub" ] && [ -n "$priv" ] && [ -n "$id" ] && [ -n "$state" ] || die "incomplete row: $line" 2
        rows+="$name"$'\t'"$kc"$'\t'"$role"$'\t'"$type"$'\t'"$pub"$'\t'"$priv"$'\t'"$id"$'\t'"$state"$'\t'"$zone"$'\t'"$launch"$'\n'; nrows=$((nrows + 1)) ;;
    esac
  done < <(if [ "$src" = - ]; then cat; else cat "$src"; fi)
  [ -n "$bucket" ] || bucket=$bucket2
  [ -z "$bucket2" ] || [ "$bucket2" = "$bucket" ] || die "two different buckets in the paste: $bucket and $bucket2" 2
  [ -n "$region" ] && [ -n "$camp" ] && [ -n "$bucket" ] || die "the paste has no REGION= / CAMPAIGN= / BUCKET= line (is it the output of 'spawn_demo.sh inventory'?)" 2
  [ -n "$ecr" ] && [ -n "$kms" ] && [ -n "$account" ] || die "the paste has no ecr_repo= / kms_alias= / account= line (spawn_demo.sh inventory of demo1)" 2
  [ "${ecr%%.*}" = "$account" ] || die "ecr_repo is not in account $account" 2
  [[ $ecr == *".dkr.ecr.$region.amazonaws.com/"* ]] || die "ecr_repo is not in region $region" 2
  [ "$nrows" -ge 1 ] || die "the paste has no NODE row" 2
  [ "$nrows" -le $MAX_NODES ] || die "$nrows machines in the paste: the limit is $MAX_NODES" 2
  [ "$(cut -f1 <<< "${rows%$'\n'}" | sort -u | wc -l)" = "$nrows" ] || die "a machine name appears twice" 2
  [ "$(cut -f3 <<< "${rows%$'\n'}" | grep -cx tools)" = 1 ] || die "the paste must hold exactly one machine with role tools" 2
  [ -f "$KEY" ] || die "no ssh key at $KEY" 2
  tmp=$(mktemp "$STATE/.seed.XXXXXX")
  printf '%s' "$rows" | jq -Rn --arg region "$region" --arg camp "$camp" --arg bucket "$bucket" --arg orch "$orch" --arg maxh "$maxh" --arg hardh "$hardh" \
    --arg ecr "$ecr" --arg kms "$kms" --arg account "$account" \
    '{region: $region, campaign: $camp, bucket: $bucket, orch_ip: $orch, max_hours: $maxh, hard_max_hours: $hardh,
      ecr_repo: $ecr, kms_alias: $kms, account: $account,
      nodes: ([inputs | split("\t") | {key: .[0], value: {kc: .[1], role: .[2], type: .[3], public: .[4], private: .[5], id: .[6], state: .[7], zone: .[8], launch: .[9]}}] | from_entries)}' \
    > "$tmp" && chmod 600 "$tmp" && mv "$tmp" "$SEED" || die "could not write $SEED"
  tmp=$(mktemp "$(dirname "$SSHC")/.rbdcfg.XXXXXX")
  {
    echo "# written by rbd_connect.sh seed $(date -u +%FT%TZ): campaign $camp in $region. Use it with ssh -F $SSHC"
    jq -r '.nodes | to_entries[] | select(.value.public != "-") | "Host \(.key)\n  HostName \(.value.public)"' "$SEED" | while IFS= read -r l; do
      echo "$l"
      if [[ $l == "  HostName "* ]]; then
        printf '  User ubuntu\n  IdentityFile %s\n  IdentitiesOnly yes\n  UserKnownHostsFile %s\n  StrictHostKeyChecking accept-new\n  ServerAliveInterval 30\n  ConnectTimeout 15\n' "$KEY" "$KH"
      fi
    done
  } > "$tmp" && chmod 600 "$tmp" && mv "$tmp" "$SSHC" || die "could not write $SSHC"
  # an address that was another machine before (a re-launch) must not trip the host-key check: forget old keys of these addresses
  if [ -f "$KH" ]; then for v in $(jq -r '.nodes[] | .public' "$SEED"); do [ "$v" = - ] || ssh-keygen -R "$v" -f "$KH" > /dev/null 2>&1 || true; done; fi
  echo "seed: $nrows machine(s) of $camp in $region; bucket $bucket; ECR ${ecr#*/}; ssh config $SSHC"
  list
}

list() {
  need_seed
  jq -r '"campaign \(.campaign) in \(.region), bucket \(.bucket), ECR repository \(.ecr_repo | sub("^[^/]*/"; "")), KMS \(.kms_alias), caps \(.max_hours) h (hard \(.hard_max_hours) h)",
         (.nodes | to_entries | sort_by(.value.kc == "tools", .value.kc, .key)[] |
          "  \(.key | . + (" " * (16 - length)))  \(.value.kc)\t\(.value.role)\t\(.value.type)\t\(.value.public)\t\(.value.private)\t\(.value.state)\t\(.value.zone)")' "$SEED"
}

# ------------------------------------------------------------------------------------------------------------------------------ test
PROBE='set -u
    b=$(cat /var/lib/rb/base-ready-at 2>/dev/null || echo NOT-YET)
    ci=$(cloud-init status 2>/dev/null | sed -n "s/^status: //p")
    t=$(jq -r ".instance_type // \"?\"" /var/lib/rb/out/_node/boot.json 2>/dev/null || echo "?")
    m=$(free -g | awk "/^Mem:/ {print \$2}")
    df=$(df -BG --output=avail / | tail -n 1 | tr -d " ")
    off=$(chronyc tracking 2>/dev/null | sed -n "s/^System time *: \([0-9.e-]*\) seconds \(slow\|fast\).*/\1 s \2/p")
    src=$(chronyc -n sources 2>/dev/null | awk "/^\^\*/ {print \$2}")
    dl=$(rb-deadline show 2>/dev/null | sed "s/; hard.*//")
    sy=$(cat /var/lib/rb/last-sync-ok 2>/dev/null || echo never)
    echo "base=$b cloud-init=${ci:-?} type=$t cpus=$(nproc) mem=${m}G disk_free=$df clock=${off:-?} via ${src:-?} | ${dl:-no deadline} | s3 last upload $sy"
    [ "$b" != NOT-YET ]'
probe() { rsh "$1" "$PROBE"; }
test_all() {
  need_seed
  local -a ns; local out; out=$(res "${1:-all}") || return 2; mapfile -t ns <<< "$out"
  echo "connecting to ${#ns[@]} machine(s) as ubuntu with $KEY (first contact records each host key in $KH)"
  par probe "${ns[@]}"; local rc=$?
  if [ $rc != 0 ]; then
    echo "some machines failed. 'base=NOT-YET' = cloud-init still running (wait 3-5 min). 'Connection timed out' = the security group does not let this box in: $0 myip"
  fi
  return $rc
}

myip() {   # no probe of any outside service from here (SPEC 0): the seed's address and where to read this box's own
  local want=""
  [ -s "$SEED" ] && want=$(jq -r '.orch_ip // ""' "$SEED")
  echo "the machines allow ssh from: ${want:-(no seed yet: the owner sets ORCH_IP in CloudShell)}"
  echo "this box's public IPv4: read it in the EC2 console (this instance > Details > Public IPv4 address)."
  echo "if the two differ, the owner runs in CloudShell:   bash spawn_demo.sh allow-ip <this box's public IPv4>"
}

case ${1:-help} in
  seed) shift; seed "$@" ;;
  list) list ;;
  test) shift; test_all "$@" ;;
  ssh) shift; need_seed; [ $# -ge 1 ] || die "usage: $0 ssh NODE [CMD...]" 2; n=$(res "$1") || exit 2; [ "$(wc -l <<< "$n")" = 1 ] || die "'$1' is more than one machine" 2
       shift; if [ -n "$DRY" ]; then rsh "$n" "${*:-<interactive shell>}"; elif [ $# -gt 0 ]; then exec ssh "${SSHO[@]}" "$n" "$@"; else exec ssh -F "$SSHC" "$n"; fi ;;
  exec) shift; need_seed; [ $# -ge 2 ] || die "usage: $0 exec TARGET CMD..." 2; t=$1; shift; RBD_CMD="$*"
        runcmd() { rsh "$1" "$RBD_CMD"; }
        out=$(res "$t") || exit 2; mapfile -t ns <<< "$out"; par runcmd "${ns[@]}" ;;
  myip) myip ;;
  help | -h | --help) sed -n '2,/^set -uo/p' "$0" | sed '$d' | sed 's/^# \{0,1\}//' ;;
  *) die "unknown command '$1' (seed | list | test | ssh | exec | myip | help)" 2 ;;
esac
