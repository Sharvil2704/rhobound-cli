#!/usr/bin/env bash
# ecr-secret.sh   (as rbd on rbd-tools1; rbd-ecr-secret.service, every 4 h) SPEC 3: the imagePullSecret "ecr" in maze, maze-obs and
#   rbd-ab (namespaces made when missing), on each namespace's default ServiceAccount. The ECR password (12 h) goes from
#   `aws ecr get-login-password` into the Secret through pipes and shell builtins only, never an argv (other users see argv).
# shellcheck disable=SC2015
set -euo pipefail
RBD_OPT=${RBD_OPT:-/opt/rbd}
# shellcheck source=../lib/rbd-env.sh
. "$RBD_OPT/lib/rbd-env.sh"
export RBD_STEP=ecr-secret
host=${RBD_ECR%%/*}
pw=$(aws ecr get-login-password --region "$RBD_REGION") || die "aws ecr get-login-password failed (the tools role?)"
[ -n "$pw" ] || die "empty ECR password"
auth=$(printf 'AWS:%s' "$pw" | base64 -w0)
cfg=$(printf '{"auths":{"%s":{"username":"AWS","password":"%s","auth":"%s"}}}' "$host" "$pw" "$auth" | base64 -w0)
unset pw auth
for ns in "$RBD_NS" "$RBD_OBS_NS" "$RBD_AB_NS"; do
  kubectl create namespace "$ns" --dry-run=client -o yaml | kubectl apply -f - > /dev/null || die "cannot create namespace $ns"
  printf 'apiVersion: v1\nkind: Secret\nmetadata:\n  name: ecr\n  namespace: %s\n  labels:\n    rbd/refreshed-by: rbd-ecr-secret\ntype: kubernetes.io/dockerconfigjson\ndata:\n  .dockerconfigjson: %s\n' "$ns" "$cfg" \
    | kubectl apply -f - > /dev/null || die "cannot write secret $ns/ecr"
  for _ in 1 2 3 4 5 6 7 8 9 10; do
    kubectl -n "$ns" patch serviceaccount default -p '{"imagePullSecrets":[{"name":"ecr"}]}' > /dev/null 2>&1 && break
    sleep 2
  done || true
  kubectl -n "$ns" get serviceaccount default -o jsonpath='{.imagePullSecrets[*].name}' | grep -qw ecr || die "default ServiceAccount of $ns does not name ecr"
done
log "secret ecr refreshed in $RBD_NS $RBD_OBS_NS $RBD_AB_NS (valid 12 h)"
