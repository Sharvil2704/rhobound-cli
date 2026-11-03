#!/usr/bin/env bash
# sandbox.sh   (root, on rbd-tools1)   let Muse Code's own sandbox run, so that the agents can build and test.
#   Muse's sandbox is built into the muse binary (its log: backend="linux_embedded"): the muse process itself creates the
#   user and network namespaces. Ubuntu 24.04 sets kernel.apparmor_restrict_unprivileged_userns=1, which strips an
#   unprivileged user namespace of its capabilities unless an AppArmor profile allows it, so every agent command failed
#   at "bwrap: loopback: Failed RTM_NEWADDR: Operation not permitted" (experiment 1, and the 2026-11-03 probe).
#   This loads one profile, as Ubuntu does for its own bwrap: unconfined, with userns, attached to the root-owned
#   /opt/muse/bin/muse only. The system-wide restriction stays on for everything else (2026-11-03).
set -euo pipefail
[ "$(id -u)" = 0 ] || { echo "sandbox.sh: run as root" >&2; exit 2; }
M=/opt/muse/bin/muse
P=/etc/apparmor.d/muse-code
cat > "$P" << 'EOF'
# Muse Code (the with/without-rhobound experiment): its embedded sandbox (backend linux_embedded) creates user namespaces;
# Ubuntu 24.04's apparmor_restrict_unprivileged_userns=1 strips their capabilities unless a profile allows it. Only this
# root-owned binary is allowed (tools1/muse/sandbox.sh).
abi <abi/4.0>,
include <tunables/global>
profile muse-code /opt/muse/bin/muse flags=(unconfined) {
  userns,
  include if exists <local/muse-code>
}
EOF
apparmor_parser -r "$P"
echo "[sandbox.sh] loaded $P (userns for $M only); kernel.apparmor_restrict_unprivileged_userns=$(sysctl -n kernel.apparmor_restrict_unprivileged_userns)"
if [ -e "$M" ]; then
  [ "$(stat -c '%u %a' "$M")" = "0 755" ] || { echo "[sandbox.sh] $M must be root 0755" >&2; exit 1; }
fi
