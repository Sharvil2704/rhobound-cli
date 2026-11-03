#!/usr/bin/env bash
# install.sh ARM CAPTURE_DIR   (root, on rbd-tools1)   Muse Code for the experiment, from the files your workstation put
#   under /var/lib/rbd/muse (bin/muse-1.4.14-R7309.1 [downloaded and checked on tools1], kit/muse/*, tix/T*, verifykit/
#   verify/*; for arm R also bin/rhobound-mcp, muse-code/ and fixtures/). Idempotent. The first experiment's live checks as one
#   script:
#   - users muser (arm R) and musec (arm C): no groups, private homes, no cron, instance metadata rejected for both
#     (iptables/ip6tables owner rules, kept across reboots by /opt/rbd/setup/imds-block.sh);
#   - /opt/muse: the muse binary, Go 1.27.3 (sha256 checked), run.sh, mkws.sh, task.sh, hidden.sh, hide.sh,
#     export.py, the tickets (root 0700, no refs/), truthx.sh and candidate.sh in /opt/rbd/verify;
#   - arm R only: rhobound-mcp, the plugin, the capture CAPTURE_DIR (the bed's fresh production fit's cut/) and the bed
#     policy, the plugin installed and approved for muser, `rhobound-mcp init --write`. Arm C: none of rhobound's files,
#     only empty stand-ins where hide.sh mounts over them.
set -euo pipefail
ARM=${1:?usage: install.sh R|C [CAPTURE_DIR]} CAP=${2:-}
case $ARM in R | C) ;; *) echo "install.sh: ARM must be R or C" >&2; exit 2 ;; esac
[ "$(id -u)" = 0 ] || { echo "install.sh: run as root" >&2; exit 2; }
S=/var/lib/rbd/muse V=1.4.14-R7309.1
[ -x "$S/bin/muse-$V" ] || { echo "install.sh: no $S/bin/muse-$V (download it first)" >&2; exit 1; }
say() { echo "[install.sh] $*"; }

for u in muser musec; do
  id "$u" > /dev/null 2>&1 || useradd -m -s /bin/bash "$u"
  chmod 0750 "/home/$u"
done
touch /etc/cron.deny
for u in muser musec; do grep -qx "$u" /etc/cron.deny || echo "$u" >> /etc/cron.deny; crontab -r -u "$u" 2> /dev/null || true; done
if ! grep -q 'muser musec' /opt/rbd/setup/imds-block.sh; then
  cat >> /opt/rbd/setup/imds-block.sh << 'X'
# Muse Code's users (the with/without-rhobound experiment): no instance metadata either
for u in muser musec; do
  id "$u" > /dev/null 2>&1 || continue
  r=(OUTPUT -m owner --uid-owner "$u" -d 169.254.169.254 -j REJECT); iptables -C "${r[@]}" 2> /dev/null || iptables -I "${r[@]}"
  if command -v ip6tables > /dev/null; then r6=(OUTPUT -m owner --uid-owner "$u" -d fd00:ec2::254 -j REJECT); ip6tables -C "${r6[@]}" 2> /dev/null || ip6tables -I "${r6[@]}" 2> /dev/null || true; fi
done
X
fi
bash -n /opt/rbd/setup/imds-block.sh && /opt/rbd/setup/imds-block.sh
for u in muser musec; do iptables -C OUTPUT -m owner --uid-owner "$(id -u "$u")" -d 169.254.169.254 -j REJECT; done
say "users and metadata block ok"

install -d -o root -g root -m 0755 /opt/muse /opt/muse/bin /opt/muse/plugin /opt/muse/rb /opt/muse/rb/captures /opt/muse/fixtures
install -o root -g root -m 0755 "$S/bin/muse-$V" /opt/muse/bin/muse
if [ ! -x /opt/muse/go/bin/go ]; then
  t=$(mktemp -d); curl -fsSL --proto =https -o "$t/go.tgz" https://go.dev/dl/go1.27.3.linux-amd64.tar.gz
  [ "$(sha256sum "$t/go.tgz" | cut -d' ' -f1)" = 65efbc80fdc1fa2cd2631cad5b481777a68e8725f34e89f50fc6ac714e379b40 ] || { echo "go: checksum mismatch" >&2; exit 1; }
  tar -C /opt/muse -xzf "$t/go.tgz"; rm -rf "$t"
fi
for f in run.sh mkws.sh task.sh hidden.sh hide.sh export.py; do install -o root -g root -m 0755 "$S/kit/muse/$f" "/opt/muse/$f"; done
rm -rf /opt/muse/tickets; install -d -o root -g root -m 0700 /opt/muse/tickets
for t in "$S"/tix/T*; do cp -r --no-preserve=mode "$t" /opt/muse/tickets/; done
chown -R root:root /opt/muse/tickets; chmod -R go-rwx /opt/muse/tickets; chmod 0700 /opt/muse/tickets
[ -z "$(find /opt/muse/tickets -name refs)" ] || { echo "refs/ must not be on tools1" >&2; exit 1; }
install -d -o root -g root -m 0755 /opt/rbd/verify
for f in truthx.sh candidate.sh; do install -o root -g root -m 0755 "$S/verifykit/verify/$f" "/opt/rbd/verify/$f"; done
say "muse, go, kit, tickets ($(ls /opt/muse/tickets | tr '\n' ' ')) and verify ok"

if [ "$ARM" = R ]; then
  [ -d "$CAP" ] || { echo "install.sh: arm R needs the capture folder (the fresh production fit's cut/), got '$CAP'" >&2; exit 2; }
  install -o root -g root -m 0755 "$S/bin/rhobound-mcp" /opt/muse/bin/rhobound-mcp
  rm -rf /opt/muse/plugin/muse-code /opt/muse/rb/captures/prod
  cp -r "$S/muse-code" /opt/muse/plugin/muse-code
  cp -r "$CAP" /opt/muse/rb/captures/prod
  cp /var/lib/rbd/src/main/policy/gate.json /opt/muse/rb/policy.json
  cp "$S"/fixtures/*.json /opt/muse/fixtures/ 2> /dev/null || true
  chown -R root:root /opt/muse; chmod -R a+rX,go-w /opt/muse; chmod 0700 /opt/muse/tickets
  sudo -u muser -H bash -c '
    set -e; cd ~; M=/opt/muse/bin/muse R=/opt/muse/bin/rhobound-mcp
    $M plugins install /opt/muse/plugin/muse-code --json > /dev/null 2>&1 || true
    $M plugins approve rhobound --json > /dev/null
    $R init --engine /opt/rbd/bin/rhobound --capture prod=/opt/muse/rb/captures/prod --policy default=/opt/muse/rb/policy.json --server $R --write > /dev/null
    $M plugins approve rhobound --json > /dev/null
    mkdir -p ~/.local/bin; ln -sfn $R ~/.local/bin/rhobound-mcp
    $R init > /tmp/init-check.json; python3 -I -c "import json; r=json.load(open(\"/tmp/init-check.json\")); a=(r[\"config\"][\"action\"], r[\"muse_settings\"][\"action\"]); print(\"init keep check:\", a); assert a == (\"keep\", \"keep\"), a"; rm -f /tmp/init-check.json
    $M plugins list --json | python3 -I -c "import json,sys; d=json.load(sys.stdin); ps=d.get(\"plugins\", d if isinstance(d, list) else []); print(\"plugins:\", [(p.get(\"id\") or p.get(\"plugin\",{}).get(\"id\"), p.get(\"enabled\")) for p in ps])"
    $R version'
else
  # arm C: none of rhobound's files; empty, inert stand-ins where hide.sh mounts over them
  rm -rf /opt/muse/plugin/muse-code /opt/muse/rb/captures/prod /opt/muse/rb/policy.json
  install -o root -g root -m 0644 /dev/null /opt/muse/bin/rhobound-mcp
  chown -R root:root /opt/muse; chmod -R a+rX,go-w /opt/muse; chmod 0700 /opt/muse/tickets
  sudo -u musec -H /opt/muse/bin/muse plugins list --json 2>/dev/null | head -c 200; echo
fi
say "arm $ARM installed: $(sudo -u "$( [ "$ARM" = R ] && echo muser || echo musec)" -H /opt/muse/bin/muse --version 2>&1 | head -1)"
