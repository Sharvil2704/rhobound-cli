#!/usr/bin/env bash
# imds-block.sh   (root; rbd-imds-block.service at every boot) the GitHub runner's user may not reach the instance metadata (SPEC 4):
#   iptables -I OUTPUT -m owner --uid-owner ghrunner -d 169.254.169.254 -j REJECT, once (and the IPv6 address when ip6tables exists).
set -euo pipefail
r=(OUTPUT -m owner --uid-owner ghrunner -d 169.254.169.254 -j REJECT)
iptables -C "${r[@]}" 2> /dev/null || iptables -I "${r[@]}"
if command -v ip6tables > /dev/null; then
  r6=(OUTPUT -m owner --uid-owner ghrunner -d fd00:ec2::254 -j REJECT)
  ip6tables -C "${r6[@]}" 2> /dev/null || ip6tables -I "${r6[@]}" 2> /dev/null || true
fi
