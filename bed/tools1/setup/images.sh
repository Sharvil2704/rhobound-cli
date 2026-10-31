#!/usr/bin/env bash
# images.sh MAIN_DIR GIT_SHA   (as rbd on rbd-tools1) every image the cluster runs, in ECR by digest (SPEC 3, 6):
#   the 10 kshop services and kshop-load from the repo's main tree (part D's /opt/rbd/ci/build.sh MAIN_DIR GIT_SHA SERVICE, which
#   pushes RBD_ECR:SERVICE-<GIT_SHA> (40 hex)); the Collector and busybox mirrored from Docker Hub by digest; abdrive built from
#   /opt/rbd/abdrive (part C's Dockerfile + binary). A tag already in ECR is not built again. Digests are read from ECR itself.
#   Writes RBD_HOME/images.json (rbd.images/v1: load, collector, busybox, abdrive, services) and, when there is none yet,
#   RBD_HOME/baseline.json (services = main's digests). Under the cluster lock. Exit 0 / 1.
# shellcheck disable=SC2015
set -euo pipefail
RBD_OPT=${RBD_OPT:-/opt/rbd}
# shellcheck source=../lib/rbd-env.sh
. "$RBD_OPT/lib/rbd-env.sh"
# shellcheck source=../lib/lock.sh
. "$RBD_OPT/lib/lock.sh"
# shellcheck source=pins.env
. "$RBD_OPT/setup/pins.env"
export RBD_STEP=images
MAIN=${1:-} SHA=${2:-}
[ -d "$MAIN/kshop/app" ] && [[ $SHA =~ ^[0-9a-f]{40}$ ]] || die "usage: images.sh MAIN_DIR GIT_SHA(40 hex) (MAIN_DIR/kshop/app must exist)"
REPO=${RBD_ECR#*/}
need_cmd aws docker jq
rbd_lock "${RBD_LOCK_WAIT:-3600}" || exit 1
ecr_login || exit 1

ecr_digest() {   # TAG -> sha256:... of that tag in ECR, or nothing
  local d
  d=$(aws ecr describe-images --region "$RBD_REGION" --repository-name "$REPO" --image-ids "imageTag=$1" --query 'imageDetails[0].imageDigest' --output text 2> /dev/null) || return 0
  [[ $d =~ ^sha256:[0-9a-f]{64}$ ]] && echo "$d"
  return 0
}

declare -A DIG
mapfile -t SVCS < <(jq -r '.services | keys[]' "$RBD_OPT/kshop/spec.json")
[ "${#SVCS[@]}" = 10 ] || die "spec.json lists ${#SVCS[@]} services, want 10"
for s in "${SVCS[@]}" kshop-load; do
  tag="$s-$SHA" d=$(ecr_digest "$s-$SHA")
  if [ -z "$d" ]; then
    log "build $s at ${SHA:0:12}"
    blog="$RBD_HOME/runs/.images-build-$s.log"
    brc=0; "$RBD_OPT/ci/build.sh" "$MAIN" "$SHA" "$s" > "$blog" || brc=$?
    out=$(json_last_line "$blog") || out='{}'
    [ "$brc" = 0 ] && [ "$(jq -r .ok <<< "$out")" = true ] || die "build.sh $s failed (exit $brc): $(tail -c 400 "$blog")"
    d=$(ecr_digest "$tag")
    [ -n "$d" ] || die "build.sh $s succeeded but ECR has no tag $tag"
    jd=$(jq -r '.digest // empty' <<< "$out")
    [ -z "$jd" ] || [ "$jd" = "$d" ] || die "build.sh $s says $jd, ECR says $d for $tag"
  else
    log "$tag already in ECR ($d)"
  fi
  DIG[$s]=$d
done

mirror() {   # SRC@sha256 TAG -> digest in ECR
  local d; d=$(ecr_digest "$2")
  if [ -z "$d" ]; then
    docker pull -q "$1" > /dev/null || die "docker pull $1 failed (Docker Hub limit?)"
    docker tag "$1" "$RBD_ECR:$2" && docker push -q "$RBD_ECR:$2" > /dev/null || die "docker push $RBD_ECR:$2 failed"
    d=$(ecr_digest "$2"); [ -n "$d" ] || die "ECR has no $2 after the push"
  fi
  echo "$d"
}
col=$(mirror "$RBD_OTELCOL_SRC" "$RBD_OTELCOL_TAG")
bb=$(mirror "$RBD_BUSYBOX_SRC" "$RBD_BUSYBOX_TAG")
ab=null
if [ -f "$RBD_OPT/abdrive/Dockerfile" ] && [ -x "$RBD_OPT/bin/abdrive" ]; then
  atag="abdrive-$(sha256sum "$RBD_OPT/bin/abdrive" | cut -c1-12)" ad=$(ecr_digest "abdrive-$(sha256sum "$RBD_OPT/bin/abdrive" | cut -c1-12)")
  if [ -z "$ad" ]; then
    docker build -q -t "$RBD_ECR:$atag" "$RBD_OPT/abdrive" > /dev/null && docker push -q "$RBD_ECR:$atag" > /dev/null || die "abdrive image build/push failed"
    ad=$(ecr_digest "$atag"); [ -n "$ad" ] || die "ECR has no $atag after the push"
  fi
  ab="\"$RBD_ECR@$ad\""
elif [ -z "${RBD_SKIP_ABDRIVE:-}" ]; then
  die "no /opt/rbd/abdrive/Dockerfile or /opt/rbd/bin/abdrive (part C): ship them and run rbd_bootstrap.sh kit, or RBD_SKIP_ABDRIVE=1"
else
  log "WARNING: abdrive skipped (RBD_SKIP_ABDRIVE)"
fi

svcjson=$(for s in "${SVCS[@]}"; do printf '%s\t%s\n' "$s" "${DIG[$s]}"; done | jq -Rn '[inputs | split("\t") | {key: .[0], value: .[1]}] | from_entries')
jq -n --arg r "$RBD_ECR" --arg sha "$SHA" --arg load "$RBD_ECR@${DIG[kshop-load]}" --arg col "$RBD_ECR@$col" --arg bb "$RBD_ECR@$bb" \
  --argjson ab "$ab" --argjson svc "$svcjson" --arg t "$(now_utc)" \
  '{schema: "rbd.images/v1", image_ref: $r, main_sha: $sha, load: $load, collector: $col, busybox: $bb, abdrive: $ab, services: $svc, updated_at: $t}' \
  | atomic_write "$RBD_HOME/images.json" || die "cannot write images.json"
BL=$RBD_HOME/baseline.json
if [ -s "$BL" ] && [ -z "${RBD_RESET_BASELINE:-}" ]; then
  if [ "$(jq -cS .services "$BL")" != "$(jq -cS . <<< "$svcjson")" ]; then
    log "baseline.json kept (production differs from main's build: deployed changes); RBD_RESET_BASELINE=1 resets it"
  fi
else
  jq -n --arg r "$RBD_ECR" --argjson svc "$svcjson" --arg t "$(now_utc)" --arg sha "$SHA" \
    '{schema: "rbd.baseline/v1", services: $svc, image_ref: $r, fit: null, capture: null, main_sha: $sha, updated_at: $t}' \
    | atomic_write "$BL" || die "cannot write baseline.json"
  log "baseline.json: main ${SHA:0:12}'s 10 digests (no fit yet: refit.sh)"
fi
rbd_result images true "$(jq -c '{main_sha, load, collector, busybox, abdrive}' "$RBD_HOME/images.json")"
