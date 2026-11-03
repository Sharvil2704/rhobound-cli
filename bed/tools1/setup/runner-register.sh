#!/usr/bin/env bash
# runner-register.sh   (root, on rbd-tools1) the GitHub Actions runner in /opt/actions-runner: its files (pinned release by
#   sha256 from pins.env, installdependencies.sh; here and not in tools1-setup.sh, so a GitHub download never blocks the core
#   path, SPEC 0b), its registration for RBD_REPO (labels self-hosted, linux, x64 + rbd-demo, --disableupdate) and its service as
#   user ghrunner, ordered after rbd-imds-block.service (a drop-in: no job runs before the IMDS rule exists). The registration
#   token comes on STDIN (minted on your workstation by gh api, carried by ssh); it is read before anything else runs (so no
#   installer can swallow it) and reaches config.sh as ACTIONS_RUNNER_INPUT_TOKEN, which the runner reads (Runner.Listener
#   CommandSettings), never an argv or a file. Already registered: stdin is ignored, the service is started.
# ghrunner owns the runner's own files (bin/, .credentials, .runner): a job can modify them and so reach later jobs. Accepted for
#   a bed whose repository only you can push to; --disableupdate keeps the pinned version.
# shellcheck disable=SC2015
set -euo pipefail
# shellcheck disable=SC1091
. /opt/rbd/etc/rbd.env
# shellcheck source=pins.env
. /opt/rbd/setup/pins.env
R=/opt/actions-runner
NAME=${RBD_RUNNER_NAME:-rbd-tools1}
die() { echo "runner-register: $1" >&2; exit 1; }
say() { echo "runner-register: $*" >&2; }
[ "$(id -u)" = 0 ] || die "run as root"
unit() { sed -n '1p' "$R/.service" 2> /dev/null; }
tok=""
if [ -f "$R/.runner" ]; then
  cat > /dev/null
else
  IFS= read -r tok || true
  [[ ${tok:-} =~ ^[A-Za-z0-9_-]{20,}$ ]] || die "no registration token on stdin"
fi

# ---------------------------------------------------------------------------------------------------------------- the runner's files
fetch() {   # URL SHA256 DEST: download to DEST, refuse a different sha256
  curl -fsSL --retry 3 -o "$3" "$1" < /dev/null || die "download failed: $1"
  [ "$(sha256sum "$3" | cut -d' ' -f1)" = "$2" ] || die "sha256 of $1 is not the pinned $2: refusing it"
}
if [ "$(cat "$R/.rbd-version" 2> /dev/null)" != "$RBD_RUNNER_VERSION" ]; then
  [ ! -f "$R/.runner" ] || die "$R holds a registered runner of another version: remove it first (svc.sh uninstall; config.sh remove)"
  T=$(mktemp -d /var/tmp/rbd-runner.XXXXXX); trap 'rm -rf "$T"' EXIT
  fetch "$RBD_RUNNER_URL" "$RBD_RUNNER_SHA256" "$T/runner.tgz"
  install -d -m 0755 -o ghrunner -g ghrunner "$R"
  tar -xzf "$T/runner.tgz" -C "$R" && chown -R ghrunner:ghrunner "$R"
  "$R/bin/installdependencies.sh" < /dev/null > "$T/deps.log" 2>&1 || { tail -5 "$T/deps.log" >&2; die "the runner's installdependencies.sh failed"; }
  echo "$RBD_RUNNER_VERSION" > "$R/.rbd-version"
  say "runner $RBD_RUNNER_VERSION unpacked in $R (sha256 checked)"
fi
chmod 0755 "$R"; install -d -m 0755 -o ghrunner -g ghrunner "$R/_work"   # rbd reads the checkouts there (build.sh, pr-check.sh)
[ -x "$R/config.sh" ] || die "no runner in $R"

# ---------------------------------------------------------------------------------------------------------------- registration, service
if [ -f "$R/.runner" ]; then
  echo "runner-register: already registered ($(jq -r '.agentName + " -> " + .gitHubUrl' "$R/.runner" 2> /dev/null))"
else
  export ACTIONS_RUNNER_INPUT_TOKEN=$tok
  unset tok
  ( cd "$R" && sudo -u ghrunner -H --preserve-env=ACTIONS_RUNNER_INPUT_TOKEN ./config.sh --unattended --url "https://github.com/$RBD_REPO" \
      --name "$NAME" --labels rbd-demo --work _work --replace --disableupdate ) < /dev/null > /var/tmp/rbd-runner-config.log 2>&1 \
    || { unset ACTIONS_RUNNER_INPUT_TOKEN; tail -5 /var/tmp/rbd-runner-config.log >&2; die "config.sh failed"; }
  unset ACTIONS_RUNNER_INPUT_TOKEN
fi
if [ -z "$(unit)" ] || ! systemctl cat "$(unit)" > /dev/null 2>&1; then ( cd "$R" && ./svc.sh install ghrunner > /dev/null ) || die "svc.sh install failed"; fi
# no job before the IMDS rule for ghrunner: the runner's unit requires rbd-imds-block.service and starts after it (also at boot)
systemctl is-enabled --quiet rbd-imds-block.service || die "rbd-imds-block.service is not enabled (rbd_bootstrap.sh tools1 first)"
D=/etc/systemd/system/$(unit).d
install -d -m 0755 "$D"
printf '[Unit]\n# demo1: no job before the IMDS rule for ghrunner exists (rbd-imds-block.service)\nRequires=rbd-imds-block.service\nAfter=rbd-imds-block.service\n' > "$D/.imds.conf.new"
chmod 0644 "$D/.imds.conf.new" && mv -f "$D/.imds.conf.new" "$D/imds.conf"
systemctl daemon-reload
systemctl is-active --quiet rbd-imds-block.service || systemctl start rbd-imds-block.service || die "rbd-imds-block.service does not start"
systemctl is-active --quiet "$(unit)" || ( cd "$R" && ./svc.sh start > /dev/null ) || die "svc.sh start failed"
sleep 2
systemctl is-active --quiet "$(unit)" || die "$(unit) is not active (journalctl -u $(unit))"
echo "runner-register: $(unit) active as ghrunner (after rbd-imds-block.service), labels self-hosted,linux,x64,rbd-demo"
