#!/usr/bin/env bash
# collector.sh   (as rbd on rbd-tools1) the trace pipeline in maze-obs: collector-config.yaml + collector.yaml with the ECR images
#   of images.json (collector, busybox) by digest; waits for the Collector and spans-reader. Under the cluster lock. Idempotent.
#   The configuration is first checked by the pinned Collector image itself (docker run ... validate): a key that version does
#   not know stops here with its message, not as a CrashLoopBackOff after the 300-s rollout wait.
# shellcheck disable=SC2015
set -euo pipefail
RBD_OPT=${RBD_OPT:-/opt/rbd}
# shellcheck source=../lib/rbd-env.sh
. "$RBD_OPT/lib/rbd-env.sh"
# shellcheck source=../lib/lock.sh
. "$RBD_OPT/lib/lock.sh"
export RBD_STEP=collector
col=$(images_get collector) bb=$(images_get busybox)
need_cmd docker
# config.yaml out of the ConfigMap (the block under "  config.yaml: |", 4 spaces of indent), read-only to the image's UID 10001
conf=$(mktemp -d "$RBD_HOME/runs/.collector-conf.XXXXXX") || die "mktemp"
trap 'rm -rf "$conf"' EXIT
awk '/^  config\.yaml: \|$/ {f = 1; next} f && /^    / {print substr($0, 5); next} f && /^[[:space:]]*$/ {print ""; next} f {exit}' \
  "$RBD_OPT/k8s/collector-config.yaml" > "$conf/config.yaml"
grep -qx 'receivers:' "$conf/config.yaml" || die "no config.yaml block in $RBD_OPT/k8s/collector-config.yaml"
chmod 0755 "$conf"; chmod 0644 "$conf/config.yaml"
ecr_login || die "cannot log in to ECR to run the Collector image"
docker run --rm --network none -v "$conf:/conf:ro" "$col" validate --config=/conf/config.yaml >&2 \
  || die "the Collector image ($col) rejects collector-config.yaml (its message is above): fix tools1/k8s/collector-config.yaml, rbd_bootstrap.sh kit collector"
log "collector-config.yaml validated by $col"
rbd_lock "${RBD_LOCK_WAIT:-3600}" || exit 1
cfgsha=$(sha256sum "$RBD_OPT/k8s/collector-config.yaml" | cut -c1-16)
man=$(sed -e "s#@COLLECTOR_IMAGE@#$col#g" -e "s#@BUSYBOX_IMAGE@#$bb#g" -e "s#@CONFIG_SHA@#$cfgsha#g" "$RBD_OPT/k8s/collector.yaml")
grep -q '@[A-Z_]*@' <<< "$man" && die "a placeholder is left in collector.yaml"
# a bare Pod's image cannot change in place: a spans-reader of other images goes first
cur=$(kubectl -n "$RBD_OBS_NS" get pod spans-reader -o jsonpath='{.spec.containers[0].image}' 2> /dev/null || true)
if [ -n "$cur" ] && [ "$cur" != "$bb" ]; then kubectl -n "$RBD_OBS_NS" delete pod spans-reader --wait=true > /dev/null; fi
kubectl create namespace "$RBD_OBS_NS" --dry-run=client -o yaml | kubectl apply -f - > /dev/null || die "could not create namespace $RBD_OBS_NS"
kubectl apply -f "$RBD_OPT/k8s/collector-config.yaml" > /dev/null || die "could not apply the Collector's configuration"
kubectl apply -f - <<< "$man" > /dev/null || die "could not apply collector.yaml"
if ! kubectl -n "$RBD_OBS_NS" rollout status deploy/otel-collector --timeout=300s > /dev/null; then
  kubectl -n "$RBD_OBS_NS" logs deploy/otel-collector --tail=20 >&2 || true
  die "the Collector did not become ready (its last log lines are above; kubectl -n $RBD_OBS_NS describe pod -l app=otel-collector)"
fi
kubectl -n "$RBD_OBS_NS" wait --for=condition=Ready pod/spans-reader --timeout=180s > /dev/null || die "spans-reader did not become ready"
own=$(kubectl -n "$RBD_OBS_NS" exec spans-reader -c reader -- stat -c '%u %a' /data) || die "spans-reader cannot read /data"
[ "$own" = "10001 750" ] || die "/var/lib/rbd/traces on edge1 is '$own', want '10001 750'"
log "Collector ($col) and spans-reader ready; /var/lib/rbd/traces owned by 10001"
