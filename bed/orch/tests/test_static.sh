#!/usr/bin/env bash
# test_static.sh: bash -n and shellcheck on every part B script, Python syntax (python3 -I, no bytecode written), the pins' shape,
# the manifests' placeholders, tools1 setup's root-only parts (the sudoers list, the IMDS unit ordering, the runner and cosign off
# the core path, the AWS CLI marker), and that no real IP, AWS account id or key sits in a part B file.
# shellcheck disable=SC1090,SC1091,SC2012,SC2015,SC2016,SC2088,SC2155  # test code
set -uo pipefail
# shellcheck source=lib.sh
. "$(dirname "$(readlink -f "$0")")/lib.sh"
cd "$DEMO" || exit 2
mapfile -t SH < <(ls orch/*.sh orch/tests/*.sh orch/tests/stubs/* tools1/lib/rbd-env.sh tools1/lib/lock.sh tools1/lib/copy_traces.sh \
  tools1/ci/capture.sh tools1/ci/refit.sh tools1/setup/*.sh tools1/k8s/*.sh tools1/maze/*.sh tools1/mcp/*.sh tools1/setup/pins.env)
for f in "${SH[@]}"; do
  bash -n "$f" 2> "$T/n.err"; check "bash -n $f" [ ! -s "$T/n.err" ]
  shellcheck -x -P SCRIPTDIR "$f" > "$T/sc.out" 2>&1; check "shellcheck $f" [ ! -s "$T/sc.out" ] || head -5 "$T/sc.out"
done
for f in orch/mcp_call.py orch/tests/test_render.py tools1/maze/render.py tools1/maze/loadlog.py tools1/maze/loadmix.py; do
  check "python syntax $f" python3 -I -c "import ast, sys; ast.parse(open(sys.argv[1]).read(), sys.argv[1])" "$f"
done
for v in KUBECTL COSIGN RUNNER AWSCLI; do
  check "pins.env: RBD_${v}_SHA256 is 64 hex" grep -Eq "^RBD_${v}_SHA256=[0-9a-f]{64}$" tools1/setup/pins.env
done
check "pins.env: images by digest" [ "$(grep -cE '^RBD_(OTELCOL|BUSYBOX)_SRC=docker\.io/[a-z/-]+@sha256:[0-9a-f]{64}$' tools1/setup/pins.env)" = 2 ]
check "kit Dockerfile: golang base by digest (ARG GO_IMAGE, default today's 1.26.9 builder)" grep -Eq '^ARG GO_IMAGE=golang:1\.26\.9-bookworm@sha256:[0-9a-f]{64}$' tools1/maze/Dockerfile
check "...FROM \${GO_IMAGE} AS build, the only FROM before the scratch stage" bash -c "[ \"\$(grep '^FROM ' tools1/maze/Dockerfile | tr '\n' '|')\" = 'FROM \${GO_IMAGE} AS build|FROM scratch|' ]"
check "...the default is bases.json's go1269; every bases.json value (keys not starting with _) is golang:<ver>-bookworm@sha256:<64 hex>" python3 -I -c '
import json, re, sys
b = json.load(open("tools1/maze/bases.json"))
d = re.search(r"^ARG GO_IMAGE=(\S+)$", open("tools1/maze/Dockerfile").read(), re.M).group(1)
ok = d == b.get("go1269") and "go127" in b and all(re.fullmatch(r"golang:1\.\d+\.\d+-bookworm@sha256:[0-9a-f]{64}", v) for k, v in b.items() if not k.startswith("_"))
sys.exit(0 if ok else 1)'
check "kit Dockerfile: go build without VCS stamping (-buildvcs=false: a .hg in a PR never runs hg)" grep -Eq '^RUN .*go build .*-buildvcs=false ' tools1/maze/Dockerfile
check "kit Dockerfile: GOTOOLCHAIN=local GOFLAGS=-mod=readonly (no toolchain download)" grep -qx 'ENV GOTOOLCHAIN=local GOFLAGS=-mod=readonly' tools1/maze/Dockerfile
check "repo Dockerfile: go build without VCS stamping too" grep -Eq '^RUN .*go build .*-buildvcs=false ' repo/maze/Dockerfile
check "collector.yaml: only the 3 known placeholders" [ "$(grep -o '@[A-Z_]*@' tools1/k8s/collector.yaml | sort -u | tr '\n' ' ')" = "@BUSYBOX_IMAGE@ @COLLECTOR_IMAGE@ @CONFIG_SHA@ " ]
# tools1 setup (root scripts, not run here): the sudoers list, the IMDS ordering, the runner and cosign off the core path
S7='/opt/rbd/ci/pr-check.sh, /opt/rbd/ci/build.sh, /opt/rbd/ci/ab.sh, /opt/rbd/ci/predict.sh, /opt/rbd/ci/sign.sh, /opt/rbd/ci/report.sh, /opt/rbd/ci/deploy.sh'
check "sudoers: ghrunner may run exactly the 7 gate/deploy steps as rbd" [ "$(grep -c '^ghrunner ' tools1/setup/tools1-setup.sh)" = 1 ] && check "...the line is the list" grep -qxF "ghrunner ALL=(rbd) NOPASSWD: $S7" tools1/setup/tools1-setup.sh
check "...no wildcard, no refit/capture/judge" bash -c "! grep '^ghrunner ' tools1/setup/tools1-setup.sh | grep -qE '\*|refit|capture|judge'"
# the drop-in as tools1-setup.sh writes it: env_reset and the system's secure_path for ghrunner, no SETENV or env_keep; visudo -cf
sed -n "/^cat > \/etc\/sudoers.d\/.rbd-ghrunner.new << 'EOF'\$/,/^EOF\$/p" tools1/setup/tools1-setup.sh | sed '1d;$d' > "$T/sudoers"
VISUDO=$(command -v visudo || echo /usr/sbin/visudo)
check "sudoers drop-in: visudo -cf parses it" bash -c "'$VISUDO' -cf '$T/sudoers' > /dev/null"
check "...exactly 3 lines: Defaults:ghrunner env_reset, Defaults:ghrunner secure_path (the system's), the 7 steps" bash -c "[ \"\$(grep -v '^#' '$T/sudoers')\" = \"\$(printf '%s\\n' 'Defaults:ghrunner env_reset' 'Defaults:ghrunner secure_path=\"/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin\"' 'ghrunner ALL=(rbd) NOPASSWD: $S7')\" ]"
check "...no SETENV, env_keep, !env_reset or other Defaults" bash -c "! grep -v '^#' '$T/sudoers' | grep -qE 'SETENV|env_keep|!env_reset|env_check|env_delete|setenv'"
wf=$(grep -ho 'sudo -n -u rbd /opt/rbd/ci/[a-z-]*\.sh' repo/.github/workflows/*.yml | sed 's#.* ##' | sort -u | tr '\n' ' ')
check "the workflows sudo only listed steps ($wf)" bash -c "for c in $wf; do grep -qF \"\$c\" <<< '$S7' || { echo \"not in sudoers: \$c\"; exit 1; }; done; [ -n '$wf' ]"
check "rbd-imds-block.service runs before the network (DefaultDependencies=no, Before= and Wants=network-pre.target)" bash -c "u=tools1/setup/rbd-imds-block.service; grep -qx 'DefaultDependencies=no' \$u && grep -qx 'Before=network-pre.target' \$u && grep -qE '^Wants=.*network-pre.target' \$u"
check "runner-register.sh: the runner's unit Requires= and After= rbd-imds-block.service (drop-in)" bash -c "f=tools1/setup/runner-register.sh; grep -qF 'Requires=rbd-imds-block.service' \$f && grep -qF 'After=rbd-imds-block.service' \$f && grep -qF 'D=/etc/systemd/system/\$(unit).d' \$f"
check "runner-register.sh: --disableupdate, the token read before the download, installdependencies without stdin" bash -c "f=tools1/setup/runner-register.sh; grep -q -- '--disableupdate' \$f && [ \$(grep -n 'IFS= read -r tok' \$f | cut -d: -f1) -lt \$(grep -n 'fetch \"\$RBD_RUNNER_URL\"' \$f | cut -d: -f1) ] && grep -q 'installdependencies.sh\" < /dev/null' \$f"
check "tools1-setup.sh: no runner download (the runner step brings it); cosign failure is a WARNING" bash -c "f=tools1/setup/tools1-setup.sh; ! grep -q 'RBD_RUNNER_URL' \$f && grep -q 'WARNING: cosign' \$f && ! grep -qE '^have /opt/rbd/bin/cosign .*\|\| \{ fetch' \$f"
check "tools1-setup.sh: the AWS CLI is trusted only with the verified-install marker" bash -c "f=tools1/setup/tools1-setup.sh; grep -qF 'AWSM=/usr/local/aws-cli/.rbd-verified' \$f && grep -qF 'echo \"\$RBD_AWSCLI_SHA256\" > \"\$AWSM\"' \$f && [ \$(grep -n 'VALIDSIG' \$f | cut -d: -f1) -lt \$(grep -n '> \"\$AWSM\"' \$f | cut -d: -f1) ]"
# RBD_POLICY_DIGEST: the bootstrap's fixture prediction (a report v2, small; scanned for IPs and account ids below with orch/)
fx=orch/fixtures/policy-digest-prediction.json
check "orch/fixtures: the policy-digest prediction is a report v2 under 64 KB" bash -c "[ \$(stat -c %s $fx) -lt 65536 ] && python3 -I -c 'import json, sys; d = json.load(open(sys.argv[1])); sys.exit(0 if d[\"version\"] == \"rhobound-cli.report/v2\" else 1)' $fx"
check "rbd_bootstrap.sh: rbd.env is computed (pins included) before tools1 sends it, and the tools1 re-check comes before rbd.env is written" bash -c "f=orch/rbd_bootstrap.sh; a=\$(grep -n 'env=\$(rbd_env)' \$f | cut -d: -f1); b=\$(grep -n 'policy-digest.sh /opt/rbd/bin/rhobound' \$f | cut -d: -f1); c=\$(grep -n '.rbd.env.new' \$f | head -n 1 | cut -d: -f1); [ -n \"\$a\" ] && [ -n \"\$b\" ] && [ -n \"\$c\" ] && [ \$a -lt \$b ] && [ \$b -lt \$c ]"
check "units: ExecStart paths exist in the kit" bash -c 'for u in tools1/setup/*.service tools1/mcp/*.service; do p=$(sed -n "s/^ExecStart=\([^ ]*\).*/\1/p" "$u"); case $p in /opt/rbd/bin/*) continue ;; esac; f=tools1/${p#/opt/rbd/}; [ -f "$f" ] || { echo "$u -> $p"; exit 1; }; done'
# no real IP / account id / key: only the documentation ranges (192.0.2, 198.51.100, 203.0.113), 10.82/10.42/10.43, loopback, the
# private ranges' own names in publish_main.sh's leak scan (10/8, 172.16/12, 192.168/16), the example account 123456789012
ips=$(grep -rhoE '\b[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\b' orch tools1/{lib,ci/capture.sh,ci/refit.sh,setup,k8s,maze,mcp} 2> /dev/null \
  | grep -vE '^(10\.(82|42|43)\.|203\.0\.113\.|192\.0\.2\.|198\.51\.100\.|127\.|0\.0\.0\.0$|169\.254\.169\.(254|123)$|1\.(1|2)[0-9]\.|0\.1\.0$|2\.(3[0-9]|338)\.)' \
  | grep -vE '^(10\.0\.0\.0|172\.16\.0\.0|192\.168\.0\.0|192\.168\.1\.1)$' | sort -u | tr '\n' ' ')
check "no real IP address in part B files (${ips:-none})" [ -z "$ips" ]
acct=$(grep -rhoE '\b[0-9]{12}\b' orch tools1/{lib,ci/capture.sh,ci/refit.sh,setup,k8s,maze,mcp} 2> /dev/null | grep -vE '^(123456789012|111122223333)$' | grep -vE '^(0123456789|[0-9]{0,3}(0{9}|9{9}))' | sort -u | tr '\n' ' ')
check "no AWS account id but the examples 123456789012, 111122223333 (${acct:-none})" [ -z "$acct" ]
check "no private key or AWS key id" bash -c "! grep -rlE 'BEGIN (RSA|OPENSSH|EC) PRIVATE KEY|AKIA[0-9A-Z]{16}' orch tools1/{lib,setup,k8s,maze,mcp}"
finish
