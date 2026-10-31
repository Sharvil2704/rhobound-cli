#!/usr/bin/env bash
# status.sh   (as rbd on rbd-tools1; rbd_bootstrap.sh status) what runs where: nodes, pods, baseline, images, lock, timers, services.
# shellcheck disable=SC2015
set -uo pipefail
RBD_OPT=${RBD_OPT:-/opt/rbd}
# shellcheck source=../lib/rbd-env.sh
. "$RBD_OPT/lib/rbd-env.sh"
# shellcheck source=../lib/lock.sh
. "$RBD_OPT/lib/lock.sh"
echo "== nodes"; kubectl get nodes -L rhobound.io/pool --no-headers 2>&1 | awk '{printf "  %-16s %-9s %s\n", $1, $2, $NF}'
echo "== pods"
for ns in "$RBD_NS" "$RBD_OBS_NS" "$RBD_AB_NS"; do
  echo "  $ns: $(kubectl -n "$ns" get pods --no-headers 2> /dev/null | awk '{print $3}' | sort | uniq -c | awk '{printf "%s %s  ", $1, $2}')"
done
echo "== baseline: $(jq -c '{capture, fit: .fit.digest, updated_at, services: (.services | length)}' "$RBD_HOME/baseline.json" 2>&1)"
echo "== images:"; jq -r 'to_entries[] | select(.value | type == "string" and test("@sha256:")) | "  \(.key) \(.value | split("@")[1][0:19])"' "$RBD_HOME/images.json" 2>&1
echo "== lock: $(rbd_lock_holder)"
echo "== $("$RBD_OPT/kshop/bgload.sh" status 2>&1)"
for u in rbd-ecr-secret.timer rbd-bgload.timer rhobound-mcp.service rbd-imds-block.service; do echo "  $u: $(systemctl is-active "$u" 2>&1)"; done
ru=$(sed -n 1p /opt/actions-runner/.service 2> /dev/null)
echo "  runner: ${ru:-not registered} $( [ -n "$ru" ] && systemctl is-active "$ru" 2>&1)"
echo "== disk: $(df -h --output=avail,pcent /var/lib/rbd | tail -n 1 | tr -s ' ')"
