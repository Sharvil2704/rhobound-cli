#!/usr/bin/env bash
# rbd_bootstrap.sh STEP...   demo1 from this box over ssh (SPEC 3, 4, 8). Every step is idempotent; run them in this order:
#   build        (local) rhobound + rhobound-mcp for linux/amd64 from a clean git archive of this repository (RBD_SRC_REF, default HEAD) -> build/linux-amd64/
#   kit          upload tools1/ (+ the two binaries) -> rbd-tools1:/opt/rbd (root-owned; also after another part changed tools1/)
#   tools1       kit + /opt/rbd/etc/rbd.env from the seed (+ RBD_POLICY_SHA256 = sha256 of repo/policy/gate.json, RBD_POLICY_DIGEST
#                = the effective-policy digest build/rhobound-arm64's `gate` writes for it on orch/fixtures/policy-digest-prediction.json,
#                which the INSTALLED CLI on rbd-tools1 must reproduce before rbd.env is written there, AB_LOCK_WAIT; the owner's
#                knobs live in rbd.env.local, never written here) + setup/tools1-setup.sh (users, packages, aws, kubectl, cosign (a
#                WARNING when it fails), IMDS rule for ghrunner, sudoers)
#   k3s          k3s v1.36.5+k3s1: server on cp1, agents edge1/load1/app1-3/ab1 with their pool labels and taints
#   kubeconfig   cp1's kubeconfig (address = cp1's private IP) -> rbd-tools1:/opt/rbd/etc/kubeconfig (user rbd only)
#   ecr-secret   namespaces kshop, kshop-obs, rbd-ab + the "ecr" imagePullSecret, and its 4-h timer (rbd-ecr-secret.timer)
#   images       main -> rbd-tools1:/var/lib/rbd/src/main (+ src/main.sha, written after the tree); setup/images.sh: build.sh x 11,
#                mirror Collector + busybox, abdrive. main = GitHub main at RBD_MAIN_SHA or state/main.sha (orch/publish_main.sh
#                writes it): cloned from RBD_MAIN_URL [https://github.com/RBD_GH_REPO.git] and that exact commit archived; without a
#                sha: refused (RBD_ALLOW_UNPUBLISHED=1, tests only: repo/ with a WARNING)
#   collector    tools1/k8s: the Collector on edge1 + spans-reader
#   kshop        the 10 services at baseline.json's digests
#   bgload       the background load + its 5-min "ensure" timer
#   mcp          rhobound-mcp http on 127.0.0.1:8765 (token, config, unit)
#   runner       the GitHub runner: its files (pinned release) + a registration token minted HERE (gh api), passed on ssh's stdin
#   verify       part E's verify/{truth.sh,aa.sh,collect.sh,vlib.sh} -> rbd-tools1:/opt/rbd/verify (root-owned; not in all)
#   all          every step above in this order (build first);   core = tools1 .. bgload (SPEC 0b: the core path first)
#   status       what runs where;   env   (local) print the rbd.env the seed gives
# RBD_DRY=1 prints every remote command instead of running it (no ssh, no gh, no build). Uses orch/rbd_lib.sh (seed, ssh config).
# shellcheck disable=SC2015,SC2016,SC2029
set -uo pipefail
RBD_ME=rbd_bootstrap
HERE=$(dirname "$(readlink -f "$0")")
# shellcheck source=rbd_lib.sh
. "$HERE/rbd_lib.sh"
INSTALLER=${RBD_K3S_INSTALLER:-$HOME/rbd-dev/k3s-install-v1.36.5_k3s1.sh}
INSTALLER_SHA=46177d4c99440b4c0311b67233823a8e8a2fc09693f6c89af1a7161e152fbfad
K3S_VER='v1.36.5+k3s1'
SRC_REPO=${RBD_MCP_SRC:-$(cd "$DEMO/.." && pwd)}
SRC_REF=${RBD_SRC_REF:-HEAD}   # the commit of this repository to build for the machines
SRC_SHA=${RBD_SRC_SHA:-$(git -C "$SRC_REPO" rev-parse "$SRC_REF^{commit}" 2> /dev/null)}   # set RBD_SRC_SHA to pin it
VERSION=0.1.0+${SRC_SHA:0:7}
BIN=$DEMO/build/linux-amd64
GO=${RBD_GO:-$(command -v go)}
CAPPED=${RBD_CAPPED:-$HOME/rbd-dev/capped.sh}
SCRATCH=${RBD_TMP:-$HOME/rbd-dev/tmp}
GH_REPO=${RBD_GH_REPO:-Sharvil2704/rhobound-demo}
REPO_DIR=${RBD_REPO_DIR:-$DEMO/repo}
LCLI=${RBD_LOCAL_CLI:-$DEMO/build/rhobound-arm64}   # this box's build of the same source, for RBD_POLICY_DIGEST
PFIX=$HERE/fixtures/policy-digest-prediction.json
SUBNET_RE=${RBD_SUBNET_RE:-^10\.82\.1\.[0-9]+$}
AS_RBD='sudo -u rbd -H'

tools() { one_role tools; }
step() { log "=== $1"; }

# ------------------------------------------------------------------------------------------------------------------------- build (local)
build() {
  step build
  local sha tmp b
  sha=$(git -C "$SRC_REPO" rev-parse "$SRC_REF^{commit}" 2> /dev/null) || die "no $SRC_REF in $SRC_REPO"
  [ "$sha" = "$SRC_SHA" ] || die "$SRC_REF is $sha, not the pinned $SRC_SHA: refusing to build"
  if [ -n "$DRY" ]; then echo "DRY local: git archive $SRC_SHA | go build (linux/amd64, capped) ./cmd/rhobound and mcp ./cmd/rhobound-mcp -> $BIN" >&2; return 0; fi
  mkdir -p "$SCRATCH" "$BIN"
  tmp=$(mktemp -d "$SCRATCH/partB-build.XXXXXX") || die "mktemp"
  git -C "$SRC_REPO" archive --format=tar "$SRC_SHA" | tar -x -C "$tmp" || { rm -rf "$tmp"; die "git archive failed"; }
  for b in rhobound:. rhobound-mcp:mcp; do
    local name=${b%%:*} dir=${b#*:}
    log "go build $name (linux/amd64, $VERSION)"
    ( cd "$tmp/$dir" && GOTMPDIR=$SCRATCH RB_MEM_MAX=2G GOMAXPROCS=2 GOOS=linux GOARCH=amd64 CGO_ENABLED=0 \
        bash "$CAPPED" "$GO" build -trimpath -buildvcs=false -ldflags "-s -w -X main.Version=$VERSION" -o "$BIN/.$name.new" "./cmd/$name" ) \
      || { rm -rf "$tmp"; die "go build $name failed"; }
    file -b "$BIN/.$name.new" | grep -q 'ELF 64-bit LSB.*x86-64' || { rm -rf "$tmp"; die "$name is not a linux/amd64 binary"; }
    mv -f "$BIN/.$name.new" "$BIN/$name"
  done
  rm -rf "$tmp"
  ( cd "$BIN" && sha256sum rhobound rhobound-mcp > SHA256SUMS )
  log "built from $SRC_SHA: $(tr '\n' ' ' < "$BIN/SHA256SUMS" | sed 's/  / /g')"
}

# ------------------------------------------------------------------------------------------------------------------------- kit, tools1
kit() {
  step kit
  need_seed
  local t st; t=$(tools)
  [ -x "$BIN/rhobound" ] && [ -x "$BIN/rhobound-mcp" ] || { [ -n "$DRY" ] || die "no $BIN/rhobound(-mcp): run $0 build first"; }
  mkdir -p "$SCRATCH"; st=$(mktemp -d "$SCRATCH/partB-kit.XXXXXX") || die "mktemp"
  tar -C "$DEMO/tools1" --exclude=tests --exclude=__pycache__ --exclude='*.pyc' -cf - . | tar -x -C "$st" || { rm -rf "$st"; die "cannot stage the kit"; }
  mkdir -p "$st/bin"; cp -p "$BIN/rhobound" "$BIN/rhobound-mcp" "$st/bin/" 2> /dev/null || [ -n "$DRY" ] || { rm -rf "$st"; die "cannot stage the binaries"; }
  tar -C "$st" -czf - . | rsh_in "$t" 'set -e; rm -rf /var/tmp/rbd-kit; mkdir -p /var/tmp/rbd-kit; tar -xzf - -C /var/tmp/rbd-kit; sudo bash /var/tmp/rbd-kit/setup/kit-install.sh /var/tmp/rbd-kit; rm -rf /var/tmp/rbd-kit' \
    || { rm -rf "$st"; die "kit upload/install on $t failed"; }
  rm -rf "$st"
}

policy_digest() {   # RBD_POLICY_DIGEST: gate.json digests.policy as this box's build of the CLI writes it for repo/policy/gate.json
  local g
  [ -x "$LCLI" ] && [ -s "$PFIX" ] || { log "ERROR: no $LCLI or $PFIX: RBD_POLICY_DIGEST cannot be computed"; return 1; }
  mkdir -p "$SCRATCH"
  g=$(RBD_TMP=$SCRATCH RB_MEM_MAX=1G GOMAXPROCS=2 bash "$CAPPED" bash "$DEMO/tools1/setup/policy-digest.sh" "$LCLI" "$PFIX" "$REPO_DIR/policy/gate.json") \
    && [[ $g =~ ^sha256:[0-9a-f]{64}$ ]] || { log "ERROR: $LCLI computed no policy digest for $REPO_DIR/policy/gate.json (RBD_POLICY_DIGEST)"; return 1; }
  echo "$g"
}

rbd_env() {   # /opt/rbd/etc/rbd.env from the seed (no secret in it) + the policy pins; owner knobs go to rbd.env.local, never written here
  local pin pdig
  pin=$(sha256sum < "$REPO_DIR/policy/gate.json" 2> /dev/null | cut -d' ' -f1)
  [[ $pin =~ ^[0-9a-f]{64}$ ]] || { log "ERROR: no $REPO_DIR/policy/gate.json to pin (RBD_POLICY_SHA256)"; return 1; }
  pdig=$(policy_digest) || return 1
  jq -r '"RBD_REGION=\(.region)\nRBD_ACCOUNT=\(.account)\nRBD_BUCKET=\(.bucket)\nRBD_ECR=\(.ecr_repo)\nRBD_KMS=awskms:///\(.kms_alias)\n" +
         "KUBECONFIG=/opt/rbd/etc/kubeconfig\nRHOBOUND_STATE=/var/lib/rbd/state\nRBD_HOME=/var/lib/rbd\nRBD_REPO='"$GH_REPO"'\n" +
         "AWS_REGION=\(.region)\nAWS_DEFAULT_REGION=\(.region)"' "$SEED" || return 1
  # pr-check.sh, predict.sh, sign.sh and deploy.sh refuse any other policy (the bytes, then the effective policy the gate used);
  # a gate job waits on a truth bracket (~33 min)
  printf 'RBD_POLICY_SHA256=%s\nRBD_POLICY_DIGEST=%s\nAB_LOCK_WAIT=3000\n' "$pin" "$pdig"
}

tools1() {
  kit
  step tools1
  local t env pdig st; t=$(tools)
  env=$(rbd_env) || die "cannot make rbd.env"
  pdig=$(sed -n 's/^RBD_POLICY_DIGEST=//p' <<< "$env")
  # the installed linux/amd64 CLI must write the same digest for the same bytes, or rbd.env is not written (every gate would refuse)
  mkdir -p "$SCRATCH"; st=$(mktemp -d "$SCRATCH/partB-pdigest.XXXXXX") || die "mktemp"
  cp "$PFIX" "$st/prediction.json" && cp "$REPO_DIR/policy/gate.json" "$st/policy.json" || { rm -rf "$st"; die "cannot stage the policy digest check"; }
  tar -C "$st" -cf - prediction.json policy.json | rsh_in "$t" 'd=$(mktemp -d /var/tmp/rbd-pdigest.XXXXXX) || exit 1; rc=0; tar -xf - -C "$d" && RBD_TMP=$d bash /opt/rbd/setup/policy-digest.sh /opt/rbd/bin/rhobound "$d/prediction.json" "$d/policy.json" '"$pdig"' || rc=1; rm -rf "$d"; exit $rc' \
    || { rm -rf "$st"; die "the installed rhobound on $t does not write RBD_POLICY_DIGEST $pdig for repo/policy/gate.json: rbd.env not written"; }
  rm -rf "$st"
  [ -n "$DRY" ] || log "RBD_POLICY_DIGEST $pdig (this box's CLI and $t's agree)"
  printf '%s\n' "$env" | rsh_in "$t" 'sudo install -d -m 0755 /opt/rbd/etc && sudo tee /opt/rbd/etc/.rbd.env.new > /dev/null && sudo chmod 0644 /opt/rbd/etc/.rbd.env.new && sudo mv -f /opt/rbd/etc/.rbd.env.new /opt/rbd/etc/rbd.env' \
    || die "cannot write rbd.env on $t"
  rsh "$t" 'sudo /opt/rbd/setup/tools1-setup.sh' || die "tools1-setup.sh failed on $t"
}

# ------------------------------------------------------------------------------------------------------------------------- k3s
k3s() {
  step k3s
  need_seed
  local cp cpip exec tok n role ip flags rc=0 want
  [ "$(sha256sum "$INSTALLER" | cut -d' ' -f1)" = "$INSTALLER_SHA" ] || die "the k3s installer's sha256 differs: refusing"
  cp=$(one_role cp); cpip=$(priv "$cp")
  [[ $cpip =~ $SUBNET_RE ]] || die "no private IP of $cp in the cluster subnet ($cpip)"
  if [ -z "$DRY" ] && rsh "$cp" 'systemctl is-active k3s' 2> /dev/null | grep -qx active; then
    log "k3s already active on $cp"
  else
    exec="server --node-name $cp --node-ip $cpip --tls-san $cpip --tls-san 127.0.0.1 --disable=traefik --disable=servicelb --cluster-cidr 10.42.0.0/16 --service-cidr 10.43.0.0/16 --cluster-dns 10.43.0.10 --node-taint node-role.kubernetes.io/control-plane:NoSchedule --write-kubeconfig-mode 600 --kubelet-arg=container-log-max-size=100Mi"
    log "server on $cp ($cpip)"
    rsh_in "$cp" 'cat > /tmp/k3s-install.sh && chmod +x /tmp/k3s-install.sh' < "$INSTALLER" || die "cannot upload the installer to $cp"
    rsh "$cp" "sudo INSTALL_K3S_VERSION='$K3S_VER' INSTALL_K3S_EXEC='$exec' sh /tmp/k3s-install.sh > /tmp/k3s-install.log 2>&1; rc=\$?; tail -3 /tmp/k3s-install.log; exit \$rc" || die "k3s server install failed on $cp"
    if [ -z "$DRY" ]; then
      local ok=""; for _ in $(seq 1 60); do rsh "$cp" 'sudo k3s kubectl get --raw /readyz' 2> /dev/null | grep -qx ok && { ok=1; break; }; sleep 3; done
      [ -n "$ok" ] || die "the k3s API on $cp is not ready after 180 s"
    fi
  fi
  tok=$(rsh "$cp" 'sudo cat /var/lib/rancher/k3s/server/node-token') || die "cannot read the join token on $cp"
  [ -n "$DRY" ] && tok="DRY-TOKEN"
  [ -n "$tok" ] || die "empty join token"
  for n in $(jq -r '.nodes | to_entries[] | select(.value.state == "running" and (.value.role | IN("edge", "load", "app", "ab"))) | .key' "$SEED"); do
    role=$(jq -r --arg n "$n" '.nodes[$n].role' "$SEED"); ip=$(priv "$n")
    [[ $ip =~ $SUBNET_RE ]] || { log "$n: private IP $ip not in the cluster subnet"; rc=1; continue; }
    case $role in
      edge) flags="--node-label rhobound.io/pool=edge --node-taint rhobound.io/pool=edge:NoSchedule" ;;
      load) flags="--node-label rhobound.io/pool=load --node-taint rhobound.io/pool=load:NoSchedule" ;;
      app) flags="--node-label rhobound.io/pool=app" ;;
      ab) flags="--node-label rhobound.io/pool=ab --node-taint rhobound.io/pool=ab:NoSchedule" ;;
    esac
    if [ -z "$DRY" ] && rsh "$n" 'systemctl is-active k3s-agent' 2> /dev/null | grep -qx active; then log "$n: k3s-agent already active"; continue; fi
    rsh_in "$n" 'cat > /tmp/k3s-install.sh && chmod +x /tmp/k3s-install.sh' < "$INSTALLER" || { rc=1; continue; }
    # the token arrives on stdin and stays in the remote shell's variable
    if printf '%s\n' "$tok" | rsh_in "$n" "read -r T; sudo K3S_URL='https://$cpip:6443' K3S_TOKEN=\"\$T\" INSTALL_K3S_VERSION='$K3S_VER' INSTALL_K3S_EXEC='agent --node-name $n --node-ip $ip $flags --kubelet-arg=container-log-max-size=100Mi' sh /tmp/k3s-install.sh > /tmp/k3s-install.log 2>&1; r=\$?; tail -2 /tmp/k3s-install.log; exit \$r"; then
      log "$n joined ($role)"
    else log "$n: join failed"; rc=1; fi
  done
  unset tok
  [ $rc = 0 ] || die "some agents did not join"
  [ -n "$DRY" ] && return 0
  want=$(jq '[.nodes[] | select(.state == "running" and (.role | IN("cp", "edge", "load", "app", "ab")))] | length' "$SEED")
  local ready=0; for _ in $(seq 1 40); do
    ready=$(rsh "$cp" 'sudo k3s kubectl get nodes --no-headers' 2> /dev/null | awk '$2 == "Ready"' | wc -l)
    [ "$ready" -ge "$want" ] && break; sleep 5
  done
  [ "$ready" -ge "$want" ] || die "$ready of $want nodes Ready after 200 s"
  log "$ready nodes Ready"
}

kubeconfig() {
  step kubeconfig
  need_seed
  local cp cpip t; cp=$(one_role cp); cpip=$(priv "$cp"); t=$(tools)
  rsh "$cp" 'sudo cat /etc/rancher/k3s/k3s.yaml' | sed "s#https://127.0.0.1:6443#https://$cpip:6443#" \
    | rsh_in "$t" 'sudo sh -c "umask 077; cat > /opt/rbd/etc/.kubeconfig.new && [ -s /opt/rbd/etc/.kubeconfig.new ] && grep -q \"server: https://\" /opt/rbd/etc/.kubeconfig.new && chown rbd:rbd /opt/rbd/etc/.kubeconfig.new && chmod 0400 /opt/rbd/etc/.kubeconfig.new && mv -f /opt/rbd/etc/.kubeconfig.new /opt/rbd/etc/kubeconfig"' \
    || die "could not copy the kubeconfig to $t"
  rsh "$t" "$AS_RBD /opt/rbd/bin/kubectl --kubeconfig /opt/rbd/etc/kubeconfig get nodes -L rhobound.io/pool" || die "rbd on $t cannot reach the cluster"
}

# ------------------------------------------------------------------------------------------------------------------------- cluster content
ecr_secret() {
  step ecr-secret
  need_seed
  rsh "$(tools)" 'set -e; sudo install -m 0644 /opt/rbd/setup/rbd-ecr-secret.service /opt/rbd/setup/rbd-ecr-secret.timer /etc/systemd/system/; sudo systemctl daemon-reload; sudo systemctl enable --now rbd-ecr-secret.timer > /dev/null 2>&1; sudo systemctl start rbd-ecr-secret.service || { sudo journalctl -u rbd-ecr-secret.service -n 15 --no-pager; exit 1; }; systemctl list-timers rbd-ecr-secret.timer --no-pager | sed -n 2p' \
    || die "the ecr secret step failed"
}

main_tree() {   # prints the main sha on stdout, the tar stream goes to the file $1
  local sha="" src="" url d pin
  if [ -n "${RBD_MAIN_SHA:-}" ]; then sha=$RBD_MAIN_SHA src=RBD_MAIN_SHA
  elif [ -s "$STATE/main.sha" ]; then sha=$(tr -d '[:space:]' < "$STATE/main.sha") src=$STATE/main.sha; fi
  if [ -n "$sha" ]; then   # GitHub main (orch/publish_main.sh): exactly that commit is built, so production == main by construction
    [[ $sha =~ ^[0-9a-f]{40}$ ]] || { log "ERROR: $src holds '$sha', not a 40-hex commit"; return 1; }
    url=${RBD_MAIN_URL:-https://github.com/$GH_REPO.git}
    if [ -n "$DRY" ] && [[ $url == http* ]]; then   # DRY reaches no remote: the plan, and repo/ stands in for the bytes
      echo "DRY local: git clone --bare $url; git archive $sha" >&2
      tar -C "$REPO_DIR" --exclude=.git -cf "$1" . || return 1
      echo "$sha"; return 0
    fi
    d=$(mktemp -d "$SCRATCH/partB-mainclone.XXXXXX") || return 1
    if ! git -c credential.helper= -c 'credential.helper=!gh auth git-credential' clone -q --bare "$url" "$d/m.git" 2> "$d/err"; then
      log "ERROR: cannot clone $url: $(head -c 300 "$d/err")"; rm -rf "$d"; return 1
    fi
    if ! git --git-dir="$d/m.git" cat-file -e "$sha^{commit}" 2> /dev/null || ! git --git-dir="$d/m.git" merge-base --is-ancestor "$sha" refs/heads/main 2> /dev/null; then
      log "ERROR: $sha ($src) is not a commit on $url's main"; rm -rf "$d"; return 1
    fi
    pin=$(git --git-dir="$d/m.git" show "$sha:policy/gate.json" 2> /dev/null | sha256sum | cut -d' ' -f1)
    if [ "$pin" != "$(sha256sum < "$REPO_DIR/policy/gate.json" 2> /dev/null | cut -d' ' -f1)" ]; then
      log "ERROR: policy/gate.json at $sha is not repo/'s, which rbd.env pins (RBD_POLICY_SHA256): every gate would refuse"; rm -rf "$d"; return 1
    fi
    git --git-dir="$d/m.git" archive --format=tar -o "$1" "$sha" || { rm -rf "$d"; return 1; }
    rm -rf "$d"
  elif [ "${RBD_ALLOW_UNPUBLISHED:-}" != 1 ]; then   # production == GitHub main, never a local tree
    log "ERROR: no GitHub main: run orch/publish_main.sh first (it writes $STATE/main.sha), or set RBD_MAIN_SHA to main's commit"; return 1
  elif [ "$(git -C "$REPO_DIR" rev-parse --show-toplevel 2> /dev/null)" = "$(readlink -f "$REPO_DIR")" ]; then
    sha=$(git -C "$REPO_DIR" rev-parse HEAD) || return 1
    log "WARNING: RBD_ALLOW_UNPUBLISHED (tests only): main = $REPO_DIR's HEAD, not GitHub main"
    [ -z "$(git -C "$REPO_DIR" status --porcelain)" ] || log "WARNING: $REPO_DIR has uncommitted changes: they are NOT uploaded (HEAD is)"
    git -C "$REPO_DIR" archive --format=tar -o "$1" HEAD || return 1
  else
    tar -C "$REPO_DIR" --exclude=.git --sort=name --mtime=@0 --owner=0 --group=0 --numeric-owner -cf "$1" . || return 1
    sha=$(sha1sum "$1" | cut -d' ' -f1)
    log "WARNING: RBD_ALLOW_UNPUBLISHED (tests only): no GitHub main and $REPO_DIR is not its own git repository: main = sha1 of its tar ($sha)"
  fi
  echo "$sha"
}

images() {
  step images
  need_seed
  local t sha tarf; t=$(tools)
  [ -d "$REPO_DIR/kshop/app" ] || die "no $REPO_DIR/kshop/app (part D's repo/)"
  mkdir -p "$SCRATCH"; tarf=$(mktemp "$SCRATCH/partB-main.XXXXXX") || die "mktemp"
  sha=$(main_tree "$tarf") || { rm -f "$tarf"; die "cannot pack main (see above)"; }
  # main.sha (sha + newline, rbd 0644) goes first and comes back last, by rename: build.sh takes the plain tree src/main only as that sha
  rsh_in "$t" "$AS_RBD sh -c 'set -e; cd /var/lib/rbd/src; rm -f main.sha .main.sha.new; rm -rf .main.new; mkdir .main.new; tar -xf - -C .main.new; rm -rf main; mv .main.new main; echo $sha > .main.sha.new; chmod 0644 .main.sha.new; mv -f .main.sha.new main.sha'" < "$tarf" \
    || { rm -f "$tarf"; die "cannot upload main to $t"; }
  rm -f "$tarf"
  # RBD_IMAGES_UPLOAD_ONLY=1 (demo2, between bench tasks): main's tree and main.sha only, no build (a merged PR's images
  # are already built and deployed by its gate and deploy.sh); RBD_RESET_BASELINE=1 is passed on to images.sh
  if [ "${RBD_IMAGES_UPLOAD_ONLY:-0}" = 1 ]; then log "main ${sha:0:12} -> $t:/var/lib/rbd/src/main (upload only)"; return 0; fi
  log "main ${sha:0:12} -> $t:/var/lib/rbd/src/main; building and mirroring (10-20 min)"
  local reset=""; [ "${RBD_RESET_BASELINE:-0}" = 1 ] && reset="env RBD_RESET_BASELINE=1 "
  rsh "$t" "$AS_RBD ${reset}/opt/rbd/setup/images.sh /var/lib/rbd/src/main $sha" || die "images.sh failed"
}

collector() { step collector; need_seed; rsh "$(tools)" "$AS_RBD /opt/rbd/k8s/collector.sh" || die "collector.sh failed"; }
kshop() { step kshop; need_seed; rsh "$(tools)" "$AS_RBD /opt/rbd/kshop/app.sh" || die "app.sh failed"; }
bgload() {
  step bgload
  need_seed
  rsh "$(tools)" "set -e; $AS_RBD /opt/rbd/kshop/bgload.sh start; sudo install -m 0644 /opt/rbd/setup/rbd-bgload.service /opt/rbd/setup/rbd-bgload.timer /etc/systemd/system/; sudo systemctl daemon-reload; sudo systemctl enable --now rbd-bgload.timer > /dev/null 2>&1; $AS_RBD /opt/rbd/kshop/bgload.sh status" \
    || die "bgload failed"
}
verify() {
  step verify
  need_seed
  local f; for f in truth.sh aa.sh collect.sh vlib.sh; do [ -f "$DEMO/verify/$f" ] || die "no $DEMO/verify/$f (part E)"; done
  tar -C "$DEMO/verify" -czf - truth.sh aa.sh collect.sh vlib.sh | rsh_in "$(tools)" 'set -e; rm -rf /var/tmp/rbd-verify; mkdir -p /var/tmp/rbd-verify; tar -xzf - -C /var/tmp/rbd-verify; sudo install -d -m 0755 -o root -g root /opt/rbd/verify; for f in /var/tmp/rbd-verify/*; do sudo install -m 0755 -o root -g root "$f" "/opt/rbd/verify/.$(basename "$f").new"; sudo mv -f "/opt/rbd/verify/.$(basename "$f").new" "/opt/rbd/verify/$(basename "$f")"; done; rm -rf /var/tmp/rbd-verify; ls /opt/rbd/verify' \
    || die "verify install failed"
}
mcp() { step mcp; need_seed; rsh "$(tools)" 'sudo /opt/rbd/mcp/mcp-setup.sh' || die "mcp-setup.sh failed"; }

runner() {
  step runner
  need_seed
  local t tok; t=$(tools)
  if [ -z "$DRY" ] && rsh "$t" 'test -f /opt/actions-runner/.runner' 2> /dev/null; then
    log "runner already registered: (re)starting its service only"
    rsh_in "$t" 'sudo /opt/rbd/setup/runner-register.sh' < /dev/null || die "runner-register.sh failed"
    return 0
  fi
  if [ -n "$DRY" ]; then
    echo "DRY local: gh api -X POST repos/$GH_REPO/actions/runners/registration-token --jq .token" >&2; tok="DRY-RUNNER-TOKEN-0123456789"
  else
    gh api "repos/$GH_REPO" --jq .full_name > /dev/null 2>&1 || die "gh cannot see $GH_REPO (does it exist? gh auth status)"
    tok=$(gh api -X POST "repos/$GH_REPO/actions/runners/registration-token" --jq .token) || die "gh could not mint a registration token (admin on $GH_REPO?)"
  fi
  printf '%s\n' "$tok" | rsh_in "$t" 'sudo /opt/rbd/setup/runner-register.sh' || { unset tok; die "runner-register.sh failed"; }
  unset tok
}

status() { need_seed; rsh "$(tools)" "$AS_RBD /opt/rbd/setup/status.sh"; }

[ $# -ge 1 ] || { sed -n '2,/^set -uo/p' "$0" | sed '$d' | sed 's/^# \{0,1\}//'; exit 2; }
for s in "$@"; do
  case $s in
    build | kit | tools1 | k3s | kubeconfig | images | collector | kshop | bgload | mcp | runner | verify | status) ;;
    env) need_seed; rbd_env || exit 1; echo; exit 0 ;;
    ecr-secret | all | core) ;;
    *) die "unknown step '$s' (build kit tools1 k3s kubeconfig ecr-secret images collector kshop bgload mcp runner verify all core status env)" 2 ;;
  esac
done
for s in "$@"; do
  case $s in
    all) build; tools1; k3s; kubeconfig; ecr_secret; images; collector; kshop; bgload; mcp; runner ;;
    core) tools1; k3s; kubeconfig; ecr_secret; images; collector; kshop; bgload ;;
    ecr-secret) ecr_secret ;;
    *) "$s" ;;
  esac
done
log "done: $*"
