#!/usr/bin/env bash
# kit-install.sh STAGE   (root, on rbd-tools1) the kit uploaded by rbd_bootstrap.sh (STAGE = its extracted tarball: tools1's
#   folders + bin/rhobound, bin/rhobound-mcp) -> /opt/rbd, root-owned. Files are replaced by rename (rsync --delay-updates), so a
#   step running at that moment keeps its old copy. Writes /opt/rbd/bin/SHA256SUMS. Idempotent. RBD_KIT_ROOT (tests) replaces /opt/rbd.
# shellcheck disable=SC2015
set -euo pipefail
S=${1:-}
O=${RBD_KIT_ROOT:-/opt/rbd}
[ "$(id -u)" = 0 ] || [ -n "${RBD_KIT_ROOT:-}" ] || { echo "kit-install: run as root" >&2; exit 1; }
own_root() { if [ "$(id -u)" = 0 ]; then chown -R root:root "$@"; fi; }
[ -d "$S" ] && [ -d "$S/lib" ] && [ -d "$S/ci" ] || { echo "usage: kit-install.sh STAGE (a folder with lib/ and ci/)" >&2; exit 1; }
command -v rsync > /dev/null || { apt-get -o DPkg::Lock::Timeout=600 update -q > /dev/null && apt-get -o DPkg::Lock::Timeout=600 install -y -q rsync > /dev/null; } || { echo "kit-install: no rsync" >&2; exit 1; }
# etc/ itself only: its files keep their owners (the kubeconfig is rbd's, 0400; a chown -R here made a second kit run
# break every kubectl of rbd: found live on 2026-10-30 when the gate's A/B could not read it)
install -d -m 0755 "$O" "$O/bin" "$O/etc" && own_root "$O/bin" && { [ "$(id -u)" != 0 ] || chown root:root "$O/etc"; }
for d in "$S"/*/; do
  n=$(basename "$d")
  case $n in bin | etc | tests) continue ;; esac
  rsync -rlpt --delete --delay-updates --chmod=go-w,a+rX --exclude tests/ --exclude __pycache__/ "$d" "$O/$n/"
  find "$O/$n" -type f \( -name '*.sh' -o -name '*.py' \) -exec chmod 0755 {} +
  own_root "$O/$n"
done
for b in rhobound rhobound-mcp; do
  [ -f "$S/bin/$b" ] || continue
  install -m 0755 "$S/bin/$b" "$O/bin/.$b.new" && own_root "$O/bin/.$b.new" && mv -f "$O/bin/.$b.new" "$O/bin/$b"
done
# abdrive (part C): the linux/amd64 binary shipped in abdrive/
ab=""
if [ -d "$O/abdrive" ]; then
  while IFS= read -r f; do
    # ELF magic, 64-bit, little endian, e_machine 0x3e (x86-64): read with od, `file` may not be installed yet
    if [ "$(od -An -tx1 -N6 "$f" | tr -d ' \n')" = 7f454c460201 ] && [ "$(od -An -tx1 -j18 -N2 "$f" | tr -d ' \n')" = 3e00 ]; then ab=$f; break; fi
  done < <(find "$O/abdrive" -maxdepth 2 -type f -size +500k)
fi
if [ -n "$ab" ]; then install -m 0755 "$ab" "$O/bin/.abdrive.new" && own_root "$O/bin/.abdrive.new" && mv -f "$O/bin/.abdrive.new" "$O/bin/abdrive"
else echo "kit-install: WARNING no linux/amd64 abdrive binary in $O/abdrive (part C)" >&2; fi
( cd "$O/bin" && find . -maxdepth 1 -type f ! -name SHA256SUMS ! -name '.*' -printf '%f\n' | sort | xargs -r sha256sum > .SHA256SUMS.new && mv -f .SHA256SUMS.new SHA256SUMS )
echo "kit-install: $O updated; bin: $(cd "$O/bin" && find . -maxdepth 1 -type f ! -name '.*' -printf '%f ' )"
