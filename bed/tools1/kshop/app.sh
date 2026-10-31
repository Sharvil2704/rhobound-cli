#!/usr/bin/env bash
# app.sh   (as rbd on rbd-tools1) kshop at baseline.json's images: render.py app --image svc=RBD_ECR@DIGEST for the 10 services,
#   kubectl apply, rollout wait. Under the cluster lock. Idempotent (the same digests change nothing).
# shellcheck disable=SC2015
set -euo pipefail
RBD_OPT=${RBD_OPT:-/opt/rbd}
# shellcheck source=../lib/rbd-env.sh
. "$RBD_OPT/lib/rbd-env.sh"
# shellcheck source=../lib/lock.sh
. "$RBD_OPT/lib/lock.sh"
export RBD_STEP=kshop
BL=$RBD_HOME/baseline.json
mapfile -t args < <(jq -r --arg r "$RBD_ECR" '.services | to_entries[] | "--image=\(.key)=\($r)@\(.value)"' "$BL" 2> /dev/null)
[ "${#args[@]}" -ge 10 ] || die "$BL holds ${#args[@]} service digests, want 10 (rbd_bootstrap.sh images)"
rbd_lock "${RBD_LOCK_WAIT:-3600}" || exit 1
python3 -I "$RBD_OPT/kshop/render.py" app "${args[@]}" > "$RBD_HOME/runs/.kshop-app.json" || die "render.py app failed"
kubectl apply -f "$RBD_HOME/runs/.kshop-app.json" > /dev/null || die "kubectl apply failed"
for d in $(jq -r '.services | keys[]' "$BL"); do
  kubectl -n "$RBD_NS" rollout status "deploy/$d" --timeout=300s > /dev/null || die "deploy/$d did not roll out (kubectl -n $RBD_NS describe deploy/$d)"
done
log "kshop ready: $(kubectl -n "$RBD_NS" get pods --no-headers 2> /dev/null | awk '$3 == "Running"' | wc -l) pods running"
