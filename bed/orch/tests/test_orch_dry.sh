#!/usr/bin/env bash
# test_orch_dry.sh: rbd_connect.sh seed on fake pastes (fake IPs 203.0.113.x / 10.82.1.x, account 123456789012) and its refusals;
# then RBD_DRY=1 rbd_bootstrap.sh all and rbd.sh against that seed: every remote command printed, on the right machine, in order,
# with no token in any command line, the kit/rbd.env/main tree as they would be sent. ssh, gh, aws, docker are stubs that fail.
# Also: myip asks no outside service; rbd.env's policy pin; main = GitHub main (a local bare repo here) at RBD_MAIN_SHA or
# state/main.sha, cloned and archived at exactly that commit, and the refusals (not on main, unknown, another policy, none at all);
# src/main.sha on rbd-tools1 (the upload run here); RBD_POLICY_DIGEST (the workstation's CLI, then the tools1 re-check as sent, run here);
# (the kshop runbook's 4b snippet test went with that runbook).
# shellcheck disable=SC1090,SC1091,SC2012,SC2015,SC2016,SC2088,SC2155  # test code
set -uo pipefail
# shellcheck source=lib.sh
. "$(dirname "$(readlink -f "$0")")/lib.sh"
export RBD_STATE=$T/state RBD_SSHC=$T/ssh/rbd_aws_config RBD_KH=$T/ssh/rbd_known_hosts RBD_KEY=$T/key RBD_TMP=$T/scratch
mkdir -p "$T/ssh"; : > "$RBD_KEY"
C=$DEMO/orch/rbd_connect.sh B=$DEMO/orch/rbd_bootstrap.sh R=$DEMO/orch/rbd.sh
userc_before=$(stat -c %Y "$HOME/.ssh/config" 2> /dev/null || echo none)
paste() {   # PREFIX -> a fake inventory
  local p=$1 i=11 n
  printf '# rhobound demo campaign demo1 in ap-south-1, printed 2026-10-30 08:00:00Z\n%s_REGION=ap-south-1\n%s_CAMPAIGN=demo1\n' "$p" "$p"
  printf '%s_BUCKET=rhobound-research-123456789012-ap-south-1\n%s_MAX_HOURS=16\n%s_HARD_MAX_HOURS=48\n%s_SSH_USER=ubuntu\n%s_ORCH_IP=203.0.113.10\n' "$p" "$p" "$p" "$p" "$p"
  for n in cp:cp1:m6a.large edge:edge1:m6a.xlarge load:load1:m6a.xlarge app:app1:m6a.xlarge app:app2:m6a.xlarge app:app3:m6a.xlarge ab:ab1:m6a.xlarge; do
    printf '%s_NODE rbd-d-%s kc=d role=%s type=%s public=203.0.113.%d private=10.82.1.%d id=i-0123456789abcd%03d state=running zone=ap-south-1a launch=2026-10-30T08:00:00Z\n' \
      "$p" "$(cut -d: -f2 <<< "$n")" "$(cut -d: -f1 <<< "$n")" "$(cut -d: -f3 <<< "$n")" "$i" "$i" "$i"; i=$((i + 1))
  done
  printf '%s_NODE rbd-tools1 kc=tools role=tools type=m6a.2xlarge public=203.0.113.30 private=10.82.1.30 id=i-0123456789abcd030 state=running zone=ap-south-1a launch=2026-10-30T08:00:00Z\n' "$p"
  printf 'ecr_repo=123456789012.dkr.ecr.ap-south-1.amazonaws.com/rhobound-demo/maze\nkms_alias=alias/rhobound-demo-verdict\nbucket=rhobound-research-123456789012-ap-south-1\naccount=123456789012\n'
}
echo "-- seed"
paste RS3 > "$T/p-rs3.txt"; out=$(bash "$C" seed "$T/p-rs3.txt" 2>&1); check "an RS3_-style paste seeds" bash -c "[ $? = 0 ]" && check "...8 machines" grep -q "seed: 8 machine" <<< "$out"
paste RBD > "$T/p.txt"; out=$(bash "$C" seed "$T/p.txt" 2>&1); rc=$?
check "an RBD_-style paste seeds (rc $rc)" [ $rc = 0 ]
check "seed.json: ecr_repo, kms_alias, account, bucket" [ "$(jq -r '"\(.ecr_repo) \(.kms_alias) \(.account) \(.bucket)"' "$RBD_STATE/seed.json")" = "123456789012.dkr.ecr.ap-south-1.amazonaws.com/rhobound-demo/maze alias/rhobound-demo-verdict 123456789012 rhobound-research-123456789012-ap-south-1" ]
check "seed.json: roles cp edge load app app app ab tools" [ "$(jq -r '[.nodes[].role] | sort | join(" ")' "$RBD_STATE/seed.json")" = "ab app app app cp edge load tools" ]
check "seed.json is 0600" [ "$(stat -c %a "$RBD_STATE/seed.json")" = 600 ]
check "ssh config written to RBD_SSHC with its own known hosts" bash -c "grep -q 'Host rbd-tools1' '$RBD_SSHC' && grep -q 'UserKnownHostsFile $RBD_KH' '$RBD_SSHC'"
check "~/.ssh/config untouched" [ "$(stat -c %Y "$HOME/.ssh/config" 2> /dev/null || echo none)" = "$userc_before" ]
badseed() { local what=$1 sedx=$2; sed -E "$sedx" "$T/p.txt" > "$T/bad.txt"; out=$(bash "$C" seed "$T/bad.txt" 2>&1); local rc=$?; check "refused: $what (rc $rc: ${out:0:90})" [ $rc = 2 ]; }
cp "$RBD_STATE/seed.json" "$T/seed.good"
badseed "no ecr_repo line" '/^ecr_repo=/d'
badseed "ecr_repo of another account" 's/^ecr_repo=123456789012/ecr_repo=111122223333/'
badseed "ecr_repo of another region" 's/^ecr_repo=(.*)ap-south-1(.*)/ecr_repo=\1eu-west-1\2/'
badseed "two buckets" 's/^bucket=.*/bucket=another-bucket/'
badseed "an unknown role" 's/role=ab /role=gpu /'
badseed "two tools machines" 's/rbd-d-ab1 kc=d role=ab/rbd-d-ab1 kc=d role=tools/'
badseed "a bad private IP" 's/private=10.82.1.11 /private=10.82.1 /'
badseed "no account" '/^account=/d'
check "a refused paste leaves the good seed in place" cmp -s "$RBD_STATE/seed.json" "$T/seed.good"
sed 's/ launch=/ ami=ami-0abc launch=/' "$T/p.txt" > "$T/extra.txt"; out=$(bash "$C" seed "$T/extra.txt" 2>&1); rc=$?
check "an unknown node field is ignored with a warning (rc $rc)" bash -c "[ $rc = 0 ] && grep -q 'ignoring unknown field' <<< '$out'"
bash "$C" seed "$T/p.txt" > /dev/null 2>&1
out=$(RBD_DRY=1 bash "$C" test 2>&1); check "test (DRY) probes 8 machines" [ "$(grep -c '^\[.*\] DRY ssh ' <<< "$out")" = 8 ]
out=$(RBD_DRY=1 bash "$C" exec ab 'uptime' 2>&1); check "exec ab (DRY) -> rbd-d-ab1 only" bash -c "grep -q 'DRY ssh rbd-d-ab1: uptime' <<< '$out' && [ \$(grep -c 'DRY ssh' <<< '$out') = 1 ]"
cp "$TESTS/stubs/fail-loudly" "$T/bin/curl"; chmod +x "$T/bin/curl"; : > "$STUB_LOG"
bash "$C" myip > "$T/myip.out" 2>&1; rc=$?
check "myip: the seed's ORCH_IP and where to read this workstation's own (rc $rc)" bash -c "[ $rc = 0 ] && grep -q 'allow ssh from: 203.0.113.10' '$T/myip.out' && grep -q 'EC2 console' '$T/myip.out' && grep -q 'spawn_two.sh allow-ip' '$T/myip.out'"
check "...no outside service asked (no curl)" [ ! -s "$STUB_LOG" ]
rm -f "$T/bin/curl"

echo "-- RBD_DRY=1 rbd_bootstrap.sh all"
mkdir -p "$T/repo/maze/app" "$T/repo/policy" "$T/save"
echo 'package main' > "$T/repo/maze/app/main.go"
# repo/'s policy as one compact line: other bytes (another RBD_POLICY_SHA256), the same effect (the same RBD_POLICY_DIGEST)
python3 -I -c 'import json,sys; print(json.dumps(json.load(open(sys.argv[1])), separators=(",", ":")))' "$DEMO/repo/policy/gate.json" > "$T/repo/policy/gate.json"
# GitHub main stands as a local bare repo (what orch/publish_main.sh pushed): repo/'s tree, one commit
gq() { git -c user.name=t -c user.email=t@example.invalid -c commit.gpgsign=false -C "$T/mk" "$@"; }
mkdir -p "$T/mk" && cp -a "$T/repo/." "$T/mk/" && gq init -q -b main && gq add -A && gq commit -q -m main && git clone -q --bare "$T/mk" "$T/main.git"
MSHA=$(gq rev-parse HEAD)
export RBD_REPO_DIR=$T/repo RBD_MAIN_SHA=$MSHA RBD_MAIN_URL=$T/main.git RBD_DRY_SAVE=$T/save
: > "$STUB_LOG"
# the kit packs the build step's binaries (build/linux-amd64, tools1/abdrive/bin) and the tools1 step computes
# RBD_POLICY_DIGEST with this machine's build (build/rhobound-local): a fresh checkout runs the build step first
if [ ! -x "$DEMO/build/linux-amd64/rhobound" ] || [ ! -x "$DEMO/build/rhobound-local" ] || [ ! -x "$DEMO/tools1/abdrive/bin/abdrive" ]; then
  echo "  (no binaries yet: bash orch/rbd_bootstrap.sh build, the real build, about 2 min)"
  env -u RBD_DRY bash "$B" build > "$T/build.out" 2>&1 || { echo "  FAIL rbd_bootstrap.sh build: $(tail -n 2 "$T/build.out")"; }
fi
export RBD_LOCAL_CLI=${RBD_LOCAL_CLI:-$DEMO/build/rhobound-local}
RBD_DRY=1 bash "$B" all > "$T/all.out" 2>&1; rc=$?
check "DRY all exit 0 (rc $rc)" [ $rc = 0 ] || tail -5 "$T/all.out"
steps=$(grep -o '=== [a-z0-9-]*' "$T/all.out" | cut -c5- | tr '\n' ' ')
check "steps in order: $steps" [ "$steps" = "build kit tools1 k3s kubeconfig ecr-secret images collector maze bgload mcp runner " ]
check "no real ssh/gh/aws/docker was run" [ ! -s "$STUB_LOG" ]
check "k3s server on rbd-d-cp1 with flannel CIDRs and the control-plane taint" grep -q "DRY ssh rbd-d-cp1: sudo INSTALL_K3S_VERSION='v1.36.5+k3s1' INSTALL_K3S_EXEC='server --node-name rbd-d-cp1 --node-ip 10.82.1.11 .*--cluster-cidr 10.42.0.0/16 --service-cidr 10.43.0.0/16 .*control-plane:NoSchedule" "$T/all.out"
for nr in edge1:edge:NoSchedule load1:load:NoSchedule ab1:ab:NoSchedule; do
  n=${nr%%:*} r=$(cut -d: -f2 <<< "$nr")
  check "agent rbd-d-$n: label + taint pool=$r" grep -q "DRY ssh rbd-d-$n: read -r T; .*--node-label rhobound.io/pool=$r --node-taint rhobound.io/pool=$r:NoSchedule" "$T/all.out"
done
check "agents app1..3: label pool=app, no taint" [ "$(grep -c "DRY ssh rbd-d-app[123]: read -r T; .*--node-label rhobound.io/pool=app --kubelet-arg" "$T/all.out")" = 3 ]
check "the join token is never in a command line" bash -c "! grep 'DRY ssh' '$T/all.out' | grep -q 'DRY-TOKEN'"
check "...it goes on stdin" bash -c "grep -l '^DRY-TOKEN$' '$T'/save/stdin.* > /dev/null"
check "the runner token is never in a command line" bash -c "! grep 'DRY ssh' '$T/all.out' | grep -q 'DRY-RUNNER-TOKEN'"
check "...it goes on stdin to runner-register.sh" grep -q "DRY ssh rbd-tools1: sudo /opt/rbd/setup/runner-register.sh <<< (stdin: 28 bytes" "$T/all.out"
envf=$(grep -l '^RBD_ECR=' "$T"/save/stdin.* | head -n 1)
check "rbd.env as SPEC 4 names it" bash -c "grep -qx 'RBD_ECR=123456789012.dkr.ecr.ap-south-1.amazonaws.com/rhobound-demo/maze' '$envf' && grep -qx 'RBD_KMS=awskms:///alias/rhobound-demo-verdict' '$envf' && grep -qx 'KUBECONFIG=/opt/rbd/etc/kubeconfig' '$envf' && grep -qx 'RHOBOUND_STATE=/var/lib/rbd/state' '$envf' && grep -qx 'RBD_HOME=/var/lib/rbd' '$envf' && grep -qx 'RBD_REPO=Sharvil2704/rhobound-maze-bed' '$envf' && grep -qx 'RBD_ACCOUNT=123456789012' '$envf' && grep -qx 'RBD_REGION=ap-south-1' '$envf' && grep -qx 'RBD_BUCKET=rhobound-research-123456789012-ap-south-1' '$envf'"
check "rbd.env pins the policy: RBD_POLICY_SHA256 = sha256 of repo/policy/gate.json; AB_LOCK_WAIT=3000" bash -c "grep -qx 'RBD_POLICY_SHA256=$(sha256sum < "$T/repo/policy/gate.json" | cut -d' ' -f1)' '$envf' && grep -qx 'AB_LOCK_WAIT=3000' '$envf' && [ \$(grep -c '^RBD_POLICY_SHA256=' '$envf') = 1 ]"
check "the bootstrap never writes rbd.env.local (your knobs)" bash -c "! grep -q 'rbd.env.local' '$T/all.out'"
check "rbd.env pins the effective policy: RBD_POLICY_DIGEST = the CLI's gate.json digests.policy ($PIN_DIGEST)" bash -c "grep -qx 'RBD_POLICY_DIGEST=$PIN_DIGEST' '$envf' && [ \$(grep -c '^RBD_POLICY_DIGEST=' '$envf') = 1 ]"
check "...the test's one-line policy has other bytes than repo/'s (another RBD_POLICY_SHA256), the same effect (the same digest)" [ "$(sed -n 's/^RBD_POLICY_SHA256=//p' "$envf")" != "$PIN_SHA" ]
out=$(RBD_REPO_DIR=$DEMO/repo bash "$B" env 2> /dev/null)
check "repo/policy/gate.json itself: RBD_POLICY_SHA256 $PIN_SHA, RBD_POLICY_DIGEST $PIN_DIGEST (the policy since 2026-10-30 21:15Z; the offline proof predates it)" bash -c "grep -qx 'RBD_POLICY_SHA256=$PIN_SHA' <<< '$out' && grep -qx 'RBD_POLICY_DIGEST=$PIN_DIGEST' <<< '$out'"
mkdir -p "$T/loose/maze/app" "$T/loose/policy"; echo '{"schema":"rhobound.policy/v1","max_entry_mean_change_pct":50}' > "$T/loose/policy/gate.json"
out=$(RBD_REPO_DIR=$T/loose bash "$B" env 2> /dev/null); ld=$(sed -n 's/^RBD_POLICY_DIGEST=//p' <<< "$out")
check "another policy (50 %): another RBD_POLICY_DIGEST ($ld)" bash -c "[[ '$ld' =~ ^sha256:[0-9a-f]{64}\$ ]] && [ '$ld' != '$PIN_DIGEST' ]"
out=$(RBD_LOCAL_CLI=$T/no-such-cli bash "$B" env 2>&1); rc=$?
check "no CLI here to compute it: env refuses (rc $rc)" bash -c "[ $rc = 1 ] && grep -q 'RBD_POLICY_DIGEST cannot be computed' <<< '$out' && ! grep -q '^RBD_POLICY_SHA256=' <<< '$out'"
out=$(RBD_LOCAL_CLI=$T/no-such-cli RBD_DRY=1 bash "$B" tools1 2>&1); rc=$?
check "...and the tools1 step sends no rbd.env (rc $rc)" bash -c "[ $rc = 1 ] && ! grep -q 'rbd.env.new' <<< '$out'"
printf '#!/bin/sh\necho broken >&2; exit 2\n' > "$T/bad-cli"; chmod +x "$T/bad-cli"
out=$(RBD_LOCAL_CLI=$T/bad-cli bash "$B" env 2>&1); rc=$?
check "a CLI whose gate fails: env refuses (rc $rc)" bash -c "[ $rc = 1 ] && grep -q 'gate exit 2: broken' <<< '$out' && grep -q 'computed no policy digest' <<< '$out'"
pdl=$(grep -n 'policy-digest.sh /opt/rbd/bin/rhobound' "$T/all.out" | head -n 1 | cut -d: -f1); envl=$(grep -n 'rbd.env.new' "$T/all.out" | head -n 1 | cut -d: -f1)
check "tools1: the INSTALLED CLI re-computes RBD_POLICY_DIGEST on rbd-tools1 before rbd.env is written (lines $pdl < $envl)" bash -c "[ -n '$pdl' ] && [ -n '$envl' ] && [ '$pdl' -lt '$envl' ]"
check "...expecting the workstation's digest" grep -qF "policy-digest.sh /opt/rbd/bin/rhobound \"\$d/prediction.json\" \"\$d/policy.json\" $PIN_DIGEST" "$T/all.out"
pdf=$(grep 'policy-digest.sh /opt/rbd/bin/rhobound' "$T/all.out" | grep -o -- '-> [^)]*' | cut -c4-)
check "...on the same bytes: its stdin holds the fixture prediction and repo/'s policy" bash -c "cmp -s <(tar -xOf '$pdf' prediction.json) '$DEMO/orch/fixtures/policy-digest-prediction.json' && cmp -s <(tar -xOf '$pdf' policy.json) '$T/repo/policy/gate.json'"
# the re-check as sent, run here: /opt/rbd/setup -> the kit's, /opt/rbd/bin/rhobound -> the workstation's CLI, /var/tmp -> T/vt
pdc=$(grep 'DRY ssh rbd-tools1: .*policy-digest.sh /opt/rbd/bin/rhobound' "$T/all.out" | sed 's/^DRY ssh rbd-tools1: //; s/ <<< (stdin: .*$//')
mkdir -p "$T/vt"; ln -s "$RBD_LOCAL_CLI" "$T/cli-amd64-standin"
here() { sed -e "s#/var/tmp/#$T/vt/#g" -e "s#/opt/rbd/setup/#$DEMO/tools1/setup/#g" -e "s#/opt/rbd/bin/rhobound#$T/cli-amd64-standin#g" <<< "$1"; }
bash -c "$(here "$pdc")" < "$pdf" > "$T/pd.out" 2>&1; rc=$?
check "...run as sent: the CLIs agree, exit 0 (rc $rc), its scratch removed" bash -c "[ $rc = 0 ] && grep -qx '$PIN_DIGEST' '$T/pd.out' && [ -z \"\$(ls -A '$T/vt')\" ]"
bash -c "$(here "${pdc/$PIN_DIGEST/sha256:$(printf %064d 0)}")" < "$pdf" > "$T/pd2.out" 2>&1; rc=$?
check "...a CLI that writes another digest: exit 1 (rc $rc), said so" bash -c "[ $rc = 1 ] && grep -q 'not sha256:0000' '$T/pd2.out'"
mkdir -p "$T/nopol/maze/app"; out=$(RBD_REPO_DIR=$T/nopol bash "$B" env 2>&1); rc=$?
check "no policy/gate.json to pin: env refuses (rc $rc)" bash -c "[ $rc = 1 ] && grep -q 'no $T/nopol/policy/gate.json to pin' <<< '$out'"
out=$(RBD_REPO_DIR=$T/nopol RBD_DRY=1 bash "$B" tools1 2>&1); rc=$?
check "...and the tools1 step sends no rbd.env without the pin (rc $rc)" bash -c "[ $rc = 1 ] && ! grep -q 'rbd.env.new' <<< '$out'"
check "env subcommand prints the same rbd.env" bash -c "diff <(bash '$B' env | sed '/^\$/d') <(cat '$envf'; echo) > /dev/null || diff <(bash '$B' env | sed '/^\$/d') '$envf' > /dev/null"
kitf=$(grep -o "stdin: [0-9]* bytes -> [^)]*" "$T/all.out" | sed -n 1p | sed 's/.*-> //')
tar -tzf "$kitf" > "$T/kit.list" 2> /dev/null
check "the kit holds lib/ ci/ setup/ k8s/ maze/ mcp/ and bin/rhobound(-mcp)" bash -c "for f in ./lib/rbd-env.sh ./lib/lock.sh ./lib/copy_traces.sh ./ci/capture.sh ./ci/refit.sh ./setup/tools1-setup.sh ./setup/policy-digest.sh ./setup/pins.env ./k8s/collector.yaml ./maze/render.py ./maze/Dockerfile ./mcp/mcp-setup.sh ./bin/rhobound ./bin/rhobound-mcp; do grep -qx \"\$f\" '$T/kit.list' || { echo missing \$f; exit 1; }; done"
check "the kit holds no tests/" bash -c "! grep -q '/tests/' '$T/kit.list'"
echo "-- kit-install.sh on the kit as sent (RBD_KIT_ROOT in place of /opt/rbd)"
mkdir -p "$T/stage" && tar -xzf "$kitf" -C "$T/stage"
KO=$T/optroot
RBD_KIT_ROOT=$KO bash "$T/stage/setup/kit-install.sh" "$T/stage" > "$T/ki.out" 2>&1; rc=$?
check "kit-install exit 0 (rc $rc)" [ $rc = 0 ] || cat "$T/ki.out"
check "layout: lib ci maze k8s setup mcp abdrive + bin etc" bash -c "cd '$KO' && ls -d lib ci maze k8s setup mcp abdrive bin etc > /dev/null"
check "bin: rhobound, rhobound-mcp, and part C's abdrive found by its ELF header" bash -c "cd '$KO/bin' && [ -x rhobound ] && [ -x rhobound-mcp ] && [ -x abdrive ] && cmp -s abdrive '$DEMO/tools1/abdrive/bin/abdrive'"
check "SHA256SUMS lists the three binaries" bash -c "cd '$KO/bin' && sha256sum -c --quiet SHA256SUMS && [ \$(wc -l < SHA256SUMS) = 3 ]"
check "scripts are executable" bash -c "[ -x '$KO/ci/capture.sh' ] && [ -x '$KO/lib/copy_traces.sh' ] && [ -x '$KO/maze/render.py' ]"
ino=$(stat -c %i "$KO/ci/capture.sh"); echo "# changed" >> "$T/stage/ci/capture.sh"; rm "$T/stage/k8s/collector.sh"
RBD_KIT_ROOT=$KO bash "$T/stage/setup/kit-install.sh" "$T/stage" > /dev/null 2>&1
check "an update replaces a script by rename (a running copy keeps its inode)" bash -c "[ \$(stat -c %i '$KO/ci/capture.sh') != $ino ] && tail -n 1 '$KO/ci/capture.sh' | grep -q changed"
check "a file gone from the kit is removed" [ ! -e "$KO/k8s/collector.sh" ]
check "kit installed by kit-install.sh on rbd-tools1" grep -q "DRY ssh rbd-tools1: set -e; rm -rf /var/tmp/rbd-kit; .*sudo bash /var/tmp/rbd-kit/setup/kit-install.sh" "$T/all.out"
check "kubeconfig: cp1's k3s.yaml -> rbd-tools1 /opt/rbd/etc/kubeconfig (0400 rbd)" bash -c "grep -q 'DRY ssh rbd-d-cp1: sudo cat /etc/rancher/k3s/k3s.yaml' '$T/all.out' && grep -q 'chown rbd:rbd /opt/rbd/etc/.kubeconfig.new && chmod 0400' '$T/all.out'"
check "images: main uploaded, then images.sh MAIN SHA as rbd (GitHub main's sha)" grep -q "DRY ssh rbd-tools1: sudo -u rbd -H /opt/rbd/setup/images.sh /var/lib/rbd/src/main $MSHA" "$T/all.out"
mainf=$(grep "/var/lib/rbd/src; rm -f main.sha" "$T/all.out" | grep -o -- '-> [^)]*' | cut -c4-)
check "the main tree sent is the archive of exactly that commit (maze/app, policy)" bash -c "tar -tf '$mainf' | grep -qx 'maze/app/main.go' && tar -tf '$mainf' | grep -qx 'policy/gate.json' && cmp -s <(tar -xOf '$mainf' policy/gate.json) '$T/repo/policy/gate.json'"
# the upload as sent, run here (sudo -u rbd dropped, /var/lib/rbd/src -> a folder holding an older main and main.sha)
upc=$(grep "DRY ssh rbd-tools1: sudo -u rbd -H sh -c 'set -e; cd /var/lib/rbd/src;" "$T/all.out" | sed 's/^DRY ssh rbd-tools1: sudo -u rbd -H //; s/ <<< (stdin: .*$//')
mkdir -p "$T/rsrc/main/old" && echo old > "$T/rsrc/main/old/x" && printf 'e%.0s' $(seq 40) > "$T/rsrc/main.sha"
( umask 077; bash -c "${upc//\/var\/lib\/rbd\/src/$T/rsrc}" < "$mainf" ) > "$T/up.err" 2>&1; rc=$?
check "images: the main upload as sent (run here, umask 077): exit 0 (rc $rc)" [ $rc = 0 ] || cat "$T/up.err"
check "...src/main is the new tree, the old one gone" bash -c "[ -f '$T/rsrc/main/maze/app/main.go' ] && [ ! -e '$T/rsrc/main/old' ]"
check "...src/main.sha = the uploaded commit + a newline, mode 0644, no temporaries left" bash -c "[ \"\$(cat '$T/rsrc/main.sha')\" = '$MSHA' ] && [ \$(stat -c %s '$T/rsrc/main.sha') = 41 ] && [ \$(stat -c %a '$T/rsrc/main.sha') = 644 ] && ! ls -A '$T/rsrc' | grep -q '^[.]main'"
a=${upc%%rm -f main.sha*} b=${upc%%tar -xf -*} m=${upc%%mv .main.new main;*} w=${upc%%mv -f .main.sha.new main.sha*}
check "...the old main.sha goes before the tree changes; the new one comes by rename after the tree is complete" bash -c "[ ${#a} -lt ${#b} ] && [ ${#m} -lt ${#w} ] && [ ${#w} -lt ${#upc} ]"
for s in "sudo -u rbd -H /opt/rbd/k8s/collector.sh" "sudo -u rbd -H /opt/rbd/maze/app.sh" "sudo -u rbd -H /opt/rbd/maze/bgload.sh start" "sudo /opt/rbd/mcp/mcp-setup.sh" "sudo systemctl start rbd-ecr-secret.service"; do
  check "rbd-tools1 runs: $s" grep -q "DRY ssh rbd-tools1: .*$s" "$T/all.out"
done
check "every tools step runs on rbd-tools1" bash -c "! grep 'DRY ssh' '$T/all.out' | grep -E '/opt/rbd|rbd-ecr|rbd-bgload' | grep -v 'DRY ssh rbd-tools1:'"

echo "-- main_tree: which main is built"
imgs() { rm -f "$T"/save/stdin.*; RBD_DRY=1 bash "$B" images > "$T/img.out" 2>&1; }
sentf() { grep "/var/lib/rbd/src; rm -f main.sha" "$T/img.out" | grep -o -- '-> [^)]*' | cut -c4-; }
echo "$MSHA" > "$RBD_STATE/main.sha"
RBD_MAIN_SHA="" imgs; rc=$?
check "state/main.sha (orch/publish_main.sh) is used without RBD_MAIN_SHA (rc $rc)" bash -c "[ $rc = 0 ] && grep -q 'images.sh /var/lib/rbd/src/main $MSHA' '$T/img.out' && tar -tf \"\$(grep '/var/lib/rbd/src; rm -f main.sha' '$T/img.out' | grep -o -- '-> [^)]*' | cut -c4-)\" | grep -qx 'maze/app/main.go'"
echo "// local edit, not on GitHub" >> "$T/repo/maze/app/main.go"
imgs; f=$(sentf)
check "a local repo/ edit is NOT what is built (production == GitHub main)" bash -c "[ -s '$f' ] && tar -xOf '$f' maze/app/main.go | grep -qx 'package main' && ! tar -xOf '$f' maze/app/main.go | grep -q 'local edit'"
gq checkout -q -b other && echo x > "$T/mk/x.txt" && gq add -A && gq commit -q -m other && git -C "$T/mk" push -q "$T/main.git" other 2> /dev/null
OSHA=$(gq rev-parse HEAD)
RBD_MAIN_SHA=$OSHA imgs; rc=$?
check "a sha that is not on main is refused (rc $rc)" bash -c "[ $rc = 1 ] && grep -q '$OSHA (RBD_MAIN_SHA) is not a commit on .*main' '$T/img.out' && ! grep -q 'images.sh /var' '$T/img.out'"
RBD_MAIN_SHA=$(printf 'f%.0s' $(seq 40)) imgs; rc=$?
check "a sha the repo does not have is refused (rc $rc)" bash -c "[ $rc = 1 ] && grep -q 'is not a commit on' '$T/img.out'"
gq checkout -q main && echo '{"schema":"rhobound.policy/v1","max_entry_mean_change_pct":50}' > "$T/mk/policy/gate.json" && gq commit -q -am "loose policy" && git -C "$T/mk" push -q "$T/main.git" main 2> /dev/null
RBD_MAIN_SHA=$(gq rev-parse HEAD) imgs; rc=$?
check "a main whose policy/gate.json is not the pinned one is refused (rc $rc)" bash -c "[ $rc = 1 ] && grep -q 'policy/gate.json at .* is not repo/.s, which rbd.env pins' '$T/img.out'"
RBD_MAIN_SHA=0123 imgs; rc=$?
check "a malformed sha is refused (rc $rc)" bash -c "[ $rc = 1 ] && grep -q \"RBD_MAIN_SHA holds '0123', not a 40-hex commit\" '$T/img.out'"
RBD_MAIN_URL=https://example.invalid/r.git imgs; rc=$?
check "DRY with GitHub's URL reaches no remote (rc $rc)" bash -c "[ $rc = 0 ] && grep -q 'DRY local: git clone --bare https://example.invalid/r.git; git archive $MSHA' '$T/img.out'"
rm -f "$RBD_STATE/main.sha"; RBD_MAIN_SHA="" imgs; rc=$?
check "no GitHub main at all (no state/main.sha, no RBD_MAIN_SHA): refused, nothing sent (rc $rc)" bash -c "[ $rc = 1 ] && grep -q 'no GitHub main: run orch/publish_main.sh first' '$T/img.out' && ! grep -q 'DRY ssh' '$T/img.out'"
RBD_ALLOW_UNPUBLISHED=1 RBD_MAIN_SHA="" imgs; rc=$?
check "...RBD_ALLOW_UNPUBLISHED=1 (tests only): repo/ itself, with a WARNING (rc $rc)" bash -c "[ $rc = 0 ] && grep -q 'WARNING: RBD_ALLOW_UNPUBLISHED (tests only): no GitHub main' '$T/img.out' && grep -q 'images.sh /var/lib/rbd/src/main' '$T/img.out'"

echo "-- rbd.sh (DRY)"
out=$(RBD_DRY=1 bash "$R" capture c1 2>&1); check "capture c1 -> capture.sh c1 600 <seed of c1> as rbd" grep -q "DRY ssh rbd-tools1: sudo -u rbd -H bash -c '. /opt/rbd/lib/rbd-env.sh; cd /var/lib/rbd; \"\$@\"' rbd /opt/rbd/ci/capture.sh c1 600 $(( 16#$(printf c1 | sha256sum | cut -c1-7) % 1000000 + 1 ))" <<< "$out"
out=$(RBD_DRY=1 bash "$R" run echo "a b; rm -rf /" 2>&1); check "run quotes its arguments (no remote word splitting)" grep -qF "rbd echo a\\ b\\;\\ rm\\ -rf\\ /" <<< "$out"
RBD_DRY=1 bash "$R" put "$T/p.txt" /etc > /dev/null 2>&1; check "put outside /var/lib/rbd is refused" [ $? = 2 ]
out=$(RBD_DRY=1 bash "$R" step ab.sh RUN1 auth sha256:a sha256:b 2>&1); check "step ab.sh -> /opt/rbd/ci/ab.sh as rbd" grep -q "rbd /opt/rbd/ci/ab.sh RUN1 auth sha256:a sha256:b" <<< "$out"
RBD_DRY=1 bash "$R" step ../../bin/sh > /dev/null 2>&1; check "step with a path is refused" [ $? = 2 ]
# the exact strings rbd.sh sends, run by a local shell in place of ssh (the remote prefix swapped for a local folder)
mkdir -p "$T/rhome"
pre="sudo -u rbd -H bash -c '. /opt/rbd/lib/rbd-env.sh; cd /var/lib/rbd; \"\$@\"' rbd"
loc() { local c; c=$(RBD_DRY=1 bash "$R" "$@" 2>&1 | sed -n 's/^DRY ssh rbd-tools1: //p'); [[ $c == "$pre"* ]] || { echo "unexpected: $c" >&2; return 1; }; bash -c "cd '$T/rhome' && bash -c '\"\$@\"' rbd${c#"$pre"}"; }
out=$(loc run echo "a b; rm -rf /x" '$HOME' 2>&1); check "run: the remote shell sees the arguments as given ($out)" [ "$out" = 'a b; rm -rf /x $HOME' ]
out=$(loc bg job1 bash -c 'echo "a b"; echo err >&2; exit 3' 2>&1); check "bg: started ($out)" grep -q "^started job1 (pid" <<< "$out"
for _ in $(seq 1 30); do [ -s "$T/rhome/logs/job1.rc" ] && break; sleep 0.2; done
check "bg: output and exit code kept" bash -c "[ \"\$(cat '$T/rhome/logs/job1.rc')\" = 3 ] && grep -qx 'a b' '$T/rhome/logs/job1.out' && grep -qx err '$T/rhome/logs/job1.out'"
out=$(loc tail job1 5 2>&1); check "tail: done, exit 3, and the lines" bash -c "grep -q '== job1: done, exit 3' <<< '$out' && grep -qx 'a b' <<< '$out'"

finish
