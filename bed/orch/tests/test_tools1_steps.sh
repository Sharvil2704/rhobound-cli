#!/usr/bin/env bash
# test_tools1_steps.sh: the tools1-side steps against stubs (a fake ECR kept in a folder; aws, docker and part D's build.sh faked):
# images.sh (11 builds, the mirrors, abdrive, images.json, baseline.json; a second run builds nothing and keeps baseline.json),
# ecr-secret.sh (the password reaches the Secret, never an argv), collector.sh (no placeholder left, images by digest; the config
# validated by the Collector image before anything is applied; the Collector's log tail when it does not become ready), app.sh,
# bgload.sh ensure (only when the lock is free), rbd-env.sh's rbd.env.local (root-owned, not group/other-writable, never a pin or
# path of rbd.env) and its test-only overrides (ignored under sudo). AWS CLI signature check: the real 2.37.13 status line.
# shellcheck disable=SC1090,SC1091,SC2012,SC2015,SC2016,SC2088,SC2155  # test code
set -uo pipefail
# shellcheck source=lib.sh
. "$(dirname "$(readlink -f "$0")")/lib.sh"
mk_env
ECR=123456789012.dkr.ecr.ap-south-1.amazonaws.com/rhobound-demo/maze
REG=$T/registry; mkdir -p "$REG"; export FAKE_REG=$REG
cat > "$T/bin/aws" << 'EOF'
#!/usr/bin/env bash
echo "aws $*" >> "$STUB_LOG"
case "$1 $2" in
  "ecr get-login-password") echo "FAKE-ECR-PASSWORD-s3cr3t" ;;
  "ecr describe-images") t=$(sed -n 's/.*imageTag=\([^ ]*\).*/\1/p' <<< "$*"); [ -f "$FAKE_REG/$t" ] && cat "$FAKE_REG/$t" || { echo "ImageNotFoundException" >&2; exit 254; } ;;
  *) echo "aws stub: $*" >&2; exit 97 ;;
esac
EOF
cat > "$T/bin/docker" << 'EOF'
#!/usr/bin/env bash
echo "docker $*" >> "$STUB_LOG"
case $1 in
  login) cat > /dev/null ;;
  pull | tag | build) : ;;
  run) prev=""; for a in "$@"; do [ "$prev" != -v ] || cp "${a%%:*}/config.yaml" "$STUB_DIR/validated.yaml"; prev=$a; done
       [ "${STUB_DOCKER_RUN_RC:-0}" = 0 ] || echo "Error: invalid configuration: processors::k8sattributes: has invalid keys: bad_key" >&2
       exit "${STUB_DOCKER_RUN_RC:-0}" ;;
  push) ref=${*: -1}; echo "sha256:$(printf '%s' "$ref" | sha256sum | cut -d' ' -f1)" > "$FAKE_REG/${ref##*:}" ;;
  *) exit 97 ;;
esac
EOF
chmod +x "$T/bin/aws" "$T/bin/docker"
O=$T/opt; mkdir -p "$O/ci" "$O/abdrive" "$O/bin"
for d in lib maze k8s setup mcp; do ln -s "$DEMO/tools1/$d" "$O/$d"; done
cat > "$O/ci/build.sh" << 'EOF'
#!/usr/bin/env bash
# fake part D build.sh CHECKOUT SHA SERVICE: "pushes" RBD_ECR:SERVICE-<SHA> (all 40 hex), prints its JSON line
echo "build.sh $*" >> "$STUB_LOG"
d="sha256:$(printf '%s-%s' "$3" "$2" | sha256sum | cut -d' ' -f1)"
echo "$d" > "$FAKE_REG/$3-$2"
echo "building $3 ..."
echo "{\"step\":\"build\",\"ok\":true,\"service\":\"$3\",\"digest\":\"$d\"}"
EOF
chmod +x "$O/ci/build.sh"
echo "FROM scratch" > "$O/abdrive/Dockerfile"; head -c 1000 /dev/urandom > "$O/bin/abdrive"; chmod +x "$O/bin/abdrive"
export RBD_OPT=$O
mkdir -p "$T/main/maze/app"
SHA=0123456789abcdef0123456789abcdef01234567

echo "-- images.sh"
out=$(bash "$DEMO/tools1/setup/images.sh" "$T/main" "$SHA" 2> "$T/i1.err"); rc=$?
check "images.sh exit 0 (rc $rc)" [ $rc = 0 ] || tail -5 "$T/i1.err"
check "build.sh ran for the 32 services and maze-load" [ "$(grep -c '^build.sh ' "$STUB_LOG")" = 33 ]
check "...each with MAIN SHA SERVICE" grep -qx "build.sh $T/main $SHA maze-load" "$STUB_LOG"
I=$T/home/images.json
check "images.json: load, collector, busybox, abdrive by digest in RBD_ECR" [ "$(jq -r '[.load, .collector, .busybox, .abdrive] | map(test("^'"$ECR"'@sha256:[0-9a-f]{64}$")) | all' "$I")" = true ]
check "images.json: load = maze-load-<sha>'s digest (the full 40-hex tag build.sh pushes)" [ "$(jq -r .load "$I")" = "$ECR@$(cat "$REG/maze-load-$SHA")" ]
check "the Collector mirrored from its pinned digest" grep -q "docker pull -q docker.io/otel/opentelemetry-collector-contrib@sha256:39923a8e431bd1f57be82411999d389fcfe40857492e4365456d97a4c1f74be6" "$STUB_LOG"
check "...pushed as otelcol-contrib-0.162.0, digest read back from ECR" [ "$(jq -r .collector "$I")" = "$ECR@$(cat "$REG/otelcol-contrib-0.162.0")" ]
check "busybox mirrored as busybox-1.37.0" [ "$(jq -r .busybox "$I")" = "$ECR@$(cat "$REG/busybox-1.37.0")" ]
check "abdrive built from /opt/rbd/abdrive, tagged by its binary" grep -q "docker build -q -t $ECR:abdrive-$(sha256sum "$O/bin/abdrive" | cut -c1-12) $O/abdrive" "$STUB_LOG"
B=$T/home/baseline.json
check "baseline.json: rbd.baseline/v1, 32 services = main's digests, no fit yet" [ "$(jq -r '"\(.schema) \(.services | length) \(.fit) \(.image_ref)"' "$B")" = "rbd.baseline/v1 32 null $ECR" ]
check "baseline auth = auth-<sha> in ECR" [ "$(jq -r .services.auth "$B")" = "$(cat "$REG/auth-$SHA")" ]
check "last line: step images ok" [ "$(tail -n 1 <<< "$out" | jq -r '"\(.step) \(.ok)"')" = "images true" ]
check "logged in to ECR with the password on stdin" bash -c "grep -q 'docker login --username AWS --password-stdin 123456789012.dkr.ecr.ap-south-1.amazonaws.com' '$STUB_LOG' && ! grep -q s3cr3t '$STUB_LOG'"
jq '.fit = {dir: "/x", digest: "sha256:abc"} | .capture = "prod-1"' "$B" > "$B.new" && mv "$B.new" "$B"; cp "$B" "$T/b.before"
: > "$STUB_LOG"
bash "$DEMO/tools1/setup/images.sh" "$T/main" "$SHA" > /dev/null 2> "$T/i2.err"; rc=$?
check "a second run: exit 0, nothing built or pushed (rc $rc)" bash -c "[ $rc = 0 ] && ! grep -qE '^build.sh |docker (push|build)' '$STUB_LOG'"
check "...and baseline.json (with its fit) kept" cmp -s "$B" "$T/b.before"
echo "sha256:$(printf %064d 5)" > "$REG/auth-$SHA"
bash "$DEMO/tools1/setup/images.sh" "$T/main" "$SHA" > /dev/null 2> "$T/i3.err"
check "a main whose digests differ from production: baseline.json kept, said so" bash -c "cmp -s '$B' '$T/b.before' && grep -q 'baseline.json kept' '$T/i3.err'"
cat > "$O/ci/build.sh" << 'EOF'
#!/usr/bin/env bash
echo "boom" >&2; echo '{"step":"build","ok":false,"error":"docker build failed"}'; exit 1
EOF
bash "$DEMO/tools1/setup/images.sh" "$T/main" fedcba9876543210fedcba9876543210fedcba98 > /dev/null 2> "$T/i4.err"; rc=$?
check "a failing build.sh stops images.sh (exit $rc) with its message" bash -c "[ $rc = 1 ] && grep -q 'build.sh .* failed (exit 1)' '$T/i4.err'"
bash "$DEMO/tools1/setup/images.sh" "$T/main" notasha > /dev/null 2>&1; check "a bad sha is refused" [ $? = 1 ]

echo "-- ecr-secret.sh"
: > "$STUB_LOG"; rm -f "$STUB_DIR"/apply.*
cat > "$T/bin/kubectl" << 'EOF'
#!/usr/bin/env bash
echo "kubectl $*" >> "$STUB_LOG"
case "$*" in
  *"get serviceaccount default -o jsonpath"*) echo ecr ;;
  "apply -f -") cat > "$(mktemp "$STUB_DIR/apply.XXXXXX")" ;;
  *"create namespace"*) echo "apiVersion: v1"; echo "kind: Namespace" ;;
esac
EOF
chmod +x "$T/bin/kubectl"
bash "$DEMO/tools1/setup/ecr-secret.sh" 2> "$T/e.err"; rc=$?
check "ecr-secret.sh exit 0 (rc $rc)" [ $rc = 0 ] || cat "$T/e.err"
check "the password is in no command line" bash -c "! grep -q s3cr3t '$STUB_LOG'"
sec=$(grep -l 'kind: Secret' "$STUB_DIR"/apply.* | head -n 1)
check "3 Secrets named ecr (maze, maze-obs, rbd-ab)" [ "$(grep -l 'kind: Secret' "$STUB_DIR"/apply.* | xargs grep -h '  namespace:' | sort | tr -d ' ' | tr '\n' ' ')" = "namespace:maze namespace:maze-obs namespace:rbd-ab " ]
cfg=$(sed -n 's/^  .dockerconfigjson: //p' "$sec" | base64 -d)
check "the Secret's dockerconfigjson: AWS / the password for the registry host" [ "$(jq -r '.auths["123456789012.dkr.ecr.ap-south-1.amazonaws.com"] | "\(.username) \(.password) \(.auth | @base64d)"' <<< "$cfg")" = "AWS FAKE-ECR-PASSWORD-s3cr3t AWS:FAKE-ECR-PASSWORD-s3cr3t" ]
check "default ServiceAccounts patched with ecr" [ "$(grep -c 'patch serviceaccount default' "$STUB_LOG")" = 3 ]

echo "-- collector.sh, app.sh, bgload.sh"
cp "$TESTS/stubs/kubectl" "$T/bin/kubectl"; : > "$STUB_LOG"; rm -f "$STUB_DIR"/apply.*
bash "$DEMO/tools1/k8s/collector.sh" 2> "$T/c.err"; rc=$?
check "collector.sh exit 0 (rc $rc)" [ $rc = 0 ] || cat "$T/c.err"
man=$(grep -l '"*kind: Deployment' "$STUB_DIR"/apply.* | xargs grep -l otel-collector | head -n 1)
check "the manifest: no placeholder left" bash -c "! grep -q '@[A-Z_]*@' '$man'"
check "the Collector image = images.json's (by digest)" grep -q "image: \"$(jq -r .collector "$I")\"" "$man"
check "busybox (init, reader, janitor) = images.json's" [ "$(grep -c "image: \"$(jq -r .busybox "$I")\"" "$man")" = 3 ]
check "the k8sattributes config extracts container.image.repo_digests" grep -q 'container.image.repo_digests' "$DEMO/tools1/k8s/collector-config.yaml"
check "the configuration was validated by the Collector image (docker run ... validate), logged in to ECR first" bash -c "grep -q 'docker login --username AWS' '$STUB_LOG' && grep -qE '^docker run --rm --network none -v $T/home/runs/.collector-conf.[A-Za-z0-9]+:/conf:ro $(jq -r .collector "$I") validate --config=/conf/config.yaml$' '$STUB_LOG'"
check "...before anything was applied" [ "$(grep -nE '^docker run |^kubectl apply -f ' "$STUB_LOG" | head -n 1 | cut -d: -f2 | cut -d' ' -f1-2)" = "docker run" ]
check "...on the ConfigMap's config.yaml, unindented" bash -c '[ "$(head -n 1 "$1")" = receivers: ] && grep -qx exporters: "$1" && grep -qx "    path: /data/spans.jsonl" "$1" && [ "$(tail -n 1 "$1")" = "      exporters: [file]" ] && [ "$(wc -l < "$1")" = "$(( $(wc -l < "$2") - 10 ))" ]' _ "$STUB_DIR/validated.yaml" "$DEMO/tools1/k8s/collector-config.yaml"
check "...and the temporary folder removed" bash -c "! ls -d '$T'/home/runs/.collector-conf.* > /dev/null 2>&1"
: > "$STUB_LOG"; cp "$T/home/lock.holder" "$T/holder.before"
STUB_DOCKER_RUN_RC=1 bash "$DEMO/tools1/k8s/collector.sh" 2> "$T/c2.err"; rc=$?
check "a configuration the image rejects: exit 1 (rc $rc), its message and ours" bash -c "[ $rc = 1 ] && grep -q 'has invalid keys: bad_key' '$T/c2.err' && grep -q 'rejects collector-config.yaml' '$T/c2.err'"
check "...nothing applied, the lock never taken" bash -c "! grep -q 'kubectl.* apply' '$STUB_LOG' && cmp -s '$T/home/lock.holder' '$T/holder.before'"
: > "$STUB_LOG"
STUB_COLLECTOR_ROLLOUT_FAIL=1 bash "$DEMO/tools1/k8s/collector.sh" 2> "$T/c3.err"; rc=$?
check "a Collector that does not become ready: exit 1 (rc $rc) with its last log lines" bash -c "[ $rc = 1 ] && grep -q 'fake-otelcol: error decoding' '$T/c3.err' && grep -q 'did not become ready (its last log lines are above' '$T/c3.err' && grep -q 'logs deploy/otel-collector --tail=20' '$STUB_LOG'"
: > "$STUB_LOG"; rm -f "$STUB_DIR"/apply.*
bash "$DEMO/tools1/maze/app.sh" 2> "$T/a.err"; rc=$?
check "app.sh exit 0 (rc $rc)" [ $rc = 0 ] || cat "$T/a.err"
app=$T/home/runs/.maze-app.json
check "app.sh rendered auth at baseline.json's digest" grep -q "\"image\": \"$ECR@$(jq -r .services.auth "$B")\"" "$app"
check "app.sh waited for 32 rollouts" [ "$(grep -c 'rollout status deploy/' "$STUB_LOG")" = 32 ]
: > "$STUB_LOG"
( RBD_HOME=$T/home; . "$DEMO/tools1/lib/lock.sh"; rbd_lock 5 a-capture; sleep 3 ) & hp=$!; sleep 0.5
STUB_BG_ACTIVE="" bash "$DEMO/tools1/maze/bgload.sh" ensure 2> "$T/b1.err"
check "ensure with the lock held: nothing touched" bash -c "! grep -q maze-bgload '$STUB_LOG' && grep -q 'lock held' '$T/b1.err'"
wait $hp
STUB_BG_ACTIVE="" bash "$DEMO/tools1/maze/bgload.sh" ensure 2> /dev/null
check "ensure with the lock free and no Job: started" grep -q "delete job maze-bgload" "$STUB_LOG"
: > "$STUB_LOG"; STUB_BG_ACTIVE=1 bash "$DEMO/tools1/maze/bgload.sh" ensure 2> /dev/null
check "ensure with the Job running: nothing done" bash -c "! grep -q 'delete job' '$STUB_LOG'"

echo "-- rbd-env.sh: rbd.env, then rbd.env.local"
envq() { bash -c '. "$1/tools1/lib/rbd-env.sh" && echo "${AB_SECONDS:-unset}|${JUDGE_CMD:-unset}|${AB_LOCK_WAIT:-unset}|$RBD_REGION|$(bash -c "echo \${AB_SECONDS:-unset}")"' _ "$DEMO"; }
export RBD_ENV_LOCAL_UID=$(id -u)   # the .local's owner here (root on rbd-tools1)
printf 'AB_LOCK_WAIT=3000\n' >> "$T/rbd.env"
out=$(envq 2>&1); check "no rbd.env.local: rbd.env alone ($out)" [ "$out" = "unset|unset|3000|ap-south-1|unset" ]
out=$(bash -c '. "$1/tools1/lib/rbd-env.sh" && echo "$RBD_POLICY_SHA256 $(bash -c "echo \$RBD_POLICY_DIGEST")"' _ "$DEMO" 2>&1)
check "both policy pins of rbd.env are exported ($out)" [ "$out" = "$PIN_SHA $PIN_DIGEST" ]
printf 'AB_SECONDS=300\nJUDGE_CMD="/opt/judge/run.sh --fast"\nAB_LOCK_WAIT=60\n' > "$T/rbd.env.local"; chmod 0644 "$T/rbd.env.local"
out=$(envq 2>&1); check "rbd.env.local is read after rbd.env (its values win) and exported ($out)" [ "$out" = "300|/opt/judge/run.sh --fast|60|ap-south-1|300" ]
cp "$T/rbd.env.local" "$T/local.good"
chmod 0664 "$T/rbd.env.local"; out=$(envq 2>&1); rc=$?
check "a group-writable rbd.env.local is refused (rc $rc)" bash -c "[ $rc = 1 ] && grep -q 'not group/other-writable (uid [0-9]*, mode 664): refused' <<< '$out'"
chmod 0646 "$T/rbd.env.local"; out=$(envq 2>&1); rc=$?
check "...an other-writable one too (rc $rc)" bash -c "[ $rc = 1 ] && grep -q 'mode 646): refused' <<< '$out'"
chmod 0644 "$T/rbd.env.local"; out=$(RBD_ENV_LOCAL_UID="" envq 2>&1); rc=$?
check "...and one not owned by root (rc $rc)" bash -c "[ $rc = 1 ] && grep -q 'must be owned by uid 0 ' <<< '$out'"
bad=""; for v in RBD_POLICY_SHA256 RBD_POLICY_DIGEST RBD_KMS RBD_HOME RBD_ECR RBD_REGION RBD_ACCOUNT RBD_BUCKET KUBECONFIG RHOBOUND_STATE; do
  { cat "$T/local.good"; echo "$v=changed"; } > "$T/rbd.env.local"
  out=$(envq 2>&1); rc=$?; [ $rc = 1 ] && grep -q "rbd.env.local changes $v: those come from rbd.env only" <<< "$out" || bad+="$v "
done
check "an rbd.env.local that sets a pin or path of rbd.env is refused, for each of the 10 (${bad:-all refused})" [ -z "$bad" ]
printf 'AB_SECONDS=300\nRBD_POLICY_DIGEST=sha256:%064d\nunset RBD_KMS\n' 0 > "$T/rbd.env.local"; out=$(envq 2>&1); rc=$?
check "...one that unsets one too, all named (rc $rc)" bash -c "[ $rc = 1 ] && grep -q 'changes RBD_POLICY_DIGEST RBD_KMS: ' <<< '$out'"
{ cat "$T/local.good"; echo "RBD_REGION=ap-south-1"; } > "$T/rbd.env.local"; out=$(envq 2>&1)
check "...one that re-states rbd.env's own value is accepted ($out)" [ "$out" = "300|/opt/judge/run.sh --fast|60|ap-south-1|300" ]
cp "$T/local.good" "$T/rbd.env.local"
out=$(SUDO_USER=ghrunner bash -c '. "$1/tools1/lib/rbd-env.sh"' _ "$DEMO" 2>&1); rc=$?
check "under sudo (SUDO_USER set) RBD_ENV_FILE is ignored: /opt/rbd/etc/rbd.env is read (rc $rc)" bash -c "[ $rc = 1 ] && grep -q 'cannot read /opt/rbd/etc/rbd.env ' <<< '$out'"
sed "s#/opt/rbd/etc/rbd.env#$T/rbd.env#" "$DEMO/tools1/lib/rbd-env.sh" > "$T/rbd-env-at-T.sh"   # the same file, its fixed path moved here
out=$(RBD_CLI=/x/evil SUDO_USER=ghrunner bash -c 'rm -f "$1.local"; . "$2"; echo "$RBD_CLI"' _ "$T/rbd.env" "$T/rbd-env-at-T.sh" 2>&1)
check "...RBD_CLI too: the kit's CLI ($out)" [ "$out" = "$RBD_OPT/bin/rhobound" ]
cp "$T/local.good" "$T/rbd.env.local"; out=$(SUDO_USER=ghrunner bash -c '. "$1"' _ "$T/rbd-env-at-T.sh" 2>&1); rc=$?
check "...and RBD_ENV_LOCAL_UID: the .local must be root's (rc $rc)" bash -c "[ $rc = 1 ] && grep -q 'must be owned by uid 0 ' <<< '$out'"
chmod 000 "$T/rbd.env.local"
out=$(envq 2>&1); rc=$?
check "an unreadable rbd.env.local is refused, not skipped (rc $rc)" bash -c "[ $rc = 1 ] && grep -q 'cannot read $T/rbd.env.local' <<< '$out'"
rm -f "$T/rbd.env.local"

echo "-- AWS CLI signature check"
st='[GNUPG:] VALIDSIG FB5DB77FD5C118B80511ADA8A6310ACC4672475C 2026-10-12 1791828781 0 4 0 1 10 00 FB5DB77FD5C118B80511ADA8A6310ACC4672475C'
fpr=$(sed -n 's/^RBD_AWSCLI_KEY_FPR=//p' "$DEMO/tools1/setup/pins.env")
check "tools1-setup's VALIDSIG test accepts the real 2.37.13 status line" grep -q "^\[GNUPG:\] VALIDSIG .* $fpr\$" <<< "$st"
check "...and refuses another key's" bash -c "! grep -q '^\[GNUPG:\] VALIDSIG .* $fpr\$' <<< '[GNUPG:] VALIDSIG 0000 2026-10-12 1 0 4 0 1 10 00 1111'"
check "the embedded key is the AWS CLI Team key, valid past 2026-10-30" bash -c "d=\$(mktemp -d '$T/g.XXXXXX'); chmod 700 \$d; gpg --homedir \$d --batch --quiet --import '$DEMO/tools1/setup/awscli-pubkey.asc' 2>/dev/null; gpg --homedir \$d --with-colons --fixed-list-mode --list-keys 2>/dev/null | awk -F: '/^pub/ {e=\$7} /^fpr/ && !f {f=\$10} END {exit !(f == \"$fpr\" && e > $(date +%s))}'"
finish
