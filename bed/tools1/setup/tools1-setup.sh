#!/usr/bin/env bash
# tools1-setup.sh   (root, on rbd-tools1; rbd_bootstrap.sh tools1 runs it after kit-install.sh) SPEC 4, idempotent:
#   packages; users rbd (system, docker, owns /var/lib/rbd, may use IMDS) and ghrunner (not in docker, no kubeconfig, IMDS blocked);
#   AWS CLI v2, kubectl, cosign, all by sha256 from pins.env (cosign is not fatal: the core path does not need it, SPEC 0b; sign.sh
#   and deploy.sh fail loudly without it); the iptables owner rule for ghrunner (rbd-imds-block.service, again at every boot,
#   before the network); the sudoers drop-in (env_reset, secure_path, the 7 steps; checked with visudo -cf before it is
#   installed); /var/lib/rbd layout. The GitHub Actions runner's files come with its registration (runner-register.sh,
#   rbd_bootstrap.sh runner), not here.
#   Last line: "tools1-setup: ok ...". Exit 0 / 1.
# shellcheck disable=SC2015
set -euo pipefail
# shellcheck source=pins.env
. /opt/rbd/setup/pins.env
die() { echo "tools1-setup: $1" >&2; exit 1; }
say() { echo "tools1-setup: $*" >&2; }
[ "$(id -u)" = 0 ] || die "run as root"
export DEBIAN_FRONTEND=noninteractive
T=$(mktemp -d /var/tmp/rbd-setup.XXXXXX); trap 'rm -rf "$T"' EXIT

# ---------------------------------------------------------------------------------------------------------------- packages
pk=(docker.io docker-buildx jq python3 git curl unzip gnupg ca-certificates iptables rsync file)
miss=(); for p in "${pk[@]}"; do dpkg-query -W -f='${Status}' "$p" 2> /dev/null | grep -q 'install ok installed' || miss+=("$p"); done
if [ ${#miss[@]} -gt 0 ]; then
  say "installing ${miss[*]}"
  apt-get -o DPkg::Lock::Timeout=600 update -q > /dev/null
  apt-get -o DPkg::Lock::Timeout=600 install -y -q "${miss[@]}" > /dev/null || die "apt-get install ${miss[*]} failed"
fi
systemctl enable --now docker > /dev/null 2>&1 || die "docker does not start"

# ---------------------------------------------------------------------------------------------------------------- users, layout
id rbd > /dev/null 2>&1 || useradd --system --create-home --home-dir /home/rbd --shell /bin/bash rbd
usermod -aG docker rbd
id ghrunner > /dev/null 2>&1 || useradd --create-home --home-dir /home/ghrunner --shell /bin/bash ghrunner
if id -nG ghrunner | tr ' ' '\n' | grep -qx docker; then gpasswd -d ghrunner docker > /dev/null; fi
install -d -m 0755 -o root -g root /opt/rbd /opt/rbd/bin /opt/rbd/etc
install -d -m 0750 -o rbd -g rbd /var/lib/rbd
for d in state captures runs ledger src mcp logs; do install -d -m 0750 -o rbd -g rbd "/var/lib/rbd/$d"; done
[ -e /var/lib/rbd/lock ] || install -m 0640 -o rbd -g rbd /dev/null /var/lib/rbd/lock

# ---------------------------------------------------------------------------------------------------------------- downloads
fetch() {   # URL SHA256 DEST: download to DEST, refuse a different sha256
  curl -fsSL --retry 3 -o "$3" "$1" || die "download failed: $1"
  [ "$(sha256sum "$3" | cut -d' ' -f1)" = "$2" ] || die "sha256 of $1 is not the pinned $2: refusing it"
}
have() { [ -f "$1" ] && [ "$(sha256sum "$1" | cut -d' ' -f1)" = "$2" ]; }
have /opt/rbd/bin/kubectl "$RBD_KUBECTL_SHA256" || { fetch "$RBD_KUBECTL_URL" "$RBD_KUBECTL_SHA256" "$T/kubectl"; install -m 0755 "$T/kubectl" /opt/rbd/bin/kubectl; }
cosign=$RBD_COSIGN_VERSION
if ! have /opt/rbd/bin/cosign "$RBD_COSIGN_SHA256"; then   # not fatal: fetch's die ends the subshell only
  ( fetch "$RBD_COSIGN_URL" "$RBD_COSIGN_SHA256" "$T/cosign" && install -m 0755 "$T/cosign" /opt/rbd/bin/cosign ) || {
    cosign=MISSING
    say "WARNING: cosign $RBD_COSIGN_VERSION is NOT installed (download or sha256 failed, see above): the core path goes on, sign.sh and deploy.sh will refuse; re-run rbd_bootstrap.sh tools1 before the runner"; }
fi

# The AWS CLI rbd uses for KMS, ECR and S3: user-data may have put an unchecked "latest" in the same place (even of the same
# version string), so only a marker written after OUR verified install counts; without it the CLI is removed and installed again.
AWSM=/usr/local/aws-cli/.rbd-verified
if [ "$(cat "$AWSM" 2> /dev/null)" != "$RBD_AWSCLI_SHA256" ] || ! /usr/local/bin/aws --version 2> /dev/null | grep -q "^aws-cli/$RBD_AWSCLI_VERSION "; then
  fetch "$RBD_AWSCLI_URL" "$RBD_AWSCLI_SHA256" "$T/awscli.zip"
  curl -fsSL --retry 3 -o "$T/awscli.zip.sig" "$RBD_AWSCLI_URL.sig" || die "no signature at $RBD_AWSCLI_URL.sig"
  install -d -m 0700 "$T/gnupg"
  gpg --homedir "$T/gnupg" --batch --quiet --import /opt/rbd/setup/awscli-pubkey.asc 2> /dev/null || die "cannot import the AWS CLI key"
  st=$(gpg --homedir "$T/gnupg" --batch --status-fd 1 --verify "$T/awscli.zip.sig" "$T/awscli.zip" 2> /dev/null || true)
  grep -q "^\[GNUPG:\] VALIDSIG .* $RBD_AWSCLI_KEY_FPR\$" <<< "$st" || die "the AWS CLI zip's signature does not verify with key $RBD_AWSCLI_KEY_FPR"
  unzip -q -o "$T/awscli.zip" -d "$T" || die "cannot unzip the AWS CLI"
  # the installer skips a version folder that exists ("Found same AWS CLI version"): the unchecked one goes first
  rm -f "$AWSM"; rm -rf /usr/local/aws-cli; rm -f /usr/local/bin/aws /usr/local/bin/aws_completer
  "$T/aws/install" --update -i /usr/local/aws-cli -b /usr/local/bin > /dev/null || die "the AWS CLI did not install"
  /usr/local/bin/aws --version 2> /dev/null | grep -q "^aws-cli/$RBD_AWSCLI_VERSION " || die "aws is not $RBD_AWSCLI_VERSION after the install"
  echo "$RBD_AWSCLI_SHA256" > "$AWSM"
  say "AWS CLI $RBD_AWSCLI_VERSION installed (sha256 and signature checked; marker $AWSM)"
fi
/usr/local/bin/aws --version 2> /dev/null | grep -q "^aws-cli/$RBD_AWSCLI_VERSION " || die "aws is not $RBD_AWSCLI_VERSION"

# ---------------------------------------------------------------------------------------------------------------- IMDS, sudoers
install -m 0644 /opt/rbd/setup/rbd-imds-block.service /etc/systemd/system/rbd-imds-block.service
systemctl daemon-reload
systemctl enable rbd-imds-block.service > /dev/null 2>&1
systemctl restart rbd-imds-block.service || die "rbd-imds-block.service failed"
iptables -C OUTPUT -m owner --uid-owner ghrunner -d 169.254.169.254 -j REJECT 2> /dev/null || die "the IMDS rule for ghrunner is missing"
if sudo -u ghrunner curl -s -m 3 -o /dev/null -X PUT -H 'X-aws-ec2-metadata-token-ttl-seconds: 60' http://169.254.169.254/latest/api/token; then
  die "ghrunner can still reach IMDS"
fi
cat > /etc/sudoers.d/.rbd-ghrunner.new << 'EOF'
# demo1 (SPEC 4): the GitHub runner may run the gate and deploy steps as rbd, nothing else (not refit, capture or judge);
# its environment is reset and PATH is the system's (not the AMI's /etc/sudoers defaults); no SETENV, no env_keep
Defaults:ghrunner env_reset
Defaults:ghrunner secure_path="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
ghrunner ALL=(rbd) NOPASSWD: /opt/rbd/ci/pr-check.sh, /opt/rbd/ci/build.sh, /opt/rbd/ci/ab.sh, /opt/rbd/ci/predict.sh, /opt/rbd/ci/sign.sh, /opt/rbd/ci/report.sh, /opt/rbd/ci/deploy.sh
EOF
chmod 0440 /etc/sudoers.d/.rbd-ghrunner.new
visudo -cf /etc/sudoers.d/.rbd-ghrunner.new > /dev/null || { rm -f /etc/sudoers.d/.rbd-ghrunner.new; die "visudo refuses the sudoers line"; }
mv -f /etc/sudoers.d/.rbd-ghrunner.new /etc/sudoers.d/rbd-ghrunner
visudo -c > /dev/null || die "visudo -c fails with rbd-ghrunner installed"

( cd /opt/rbd/bin && find . -maxdepth 1 -type f ! -name SHA256SUMS ! -name '.*' -printf '%f\n' | sort | xargs -r sha256sum > .SHA256SUMS.new && mv -f .SHA256SUMS.new SHA256SUMS )
echo "tools1-setup: ok (aws $RBD_AWSCLI_VERSION, kubectl $RBD_KUBECTL_VERSION, cosign $cosign; users rbd, ghrunner; IMDS blocked for ghrunner; sudoers checked; the runner comes with rbd_bootstrap.sh runner)"
