# shellcheck shell=bash
# rbd-env.sh: sourced by every step on rbd-tools1:   . /opt/rbd/lib/rbd-env.sh
# Exports /opt/rbd/etc/rbd.env (RBD_REGION RBD_ACCOUNT RBD_BUCKET RBD_ECR RBD_KMS KUBECONFIG RHOBOUND_STATE RBD_HOME RBD_REPO
# RBD_POLICY_SHA256 RBD_POLICY_DIGEST AB_LOCK_WAIT), then the optional /opt/rbd/etc/rbd.env.local (the owner's knobs: AB_SECONDS,
# JUDGE_CMD, ...; written by hand, never by the bootstrap; its values win over rbd.env's). The .local must be root-owned and not
# group/other-writable, and must leave the pins and paths below (_rbd_pinned) as rbd.env set them: refused (exit 1) otherwise.
# Defines: log, die, rbd_result, json_last_line, ecr_login, sha256_of, atomic_write, now_utc, need_cmd, images_get.
# Overrides (tests only: honoured when SUDO_USER is empty; sudo's env_reset never passes them, and under sudo they are ignored):
# RBD_ENV_FILE (the env file; the local one is RBD_ENV_FILE.local), RBD_CLI, RBD_ENV_LOCAL_UID (the .local's owner, 0).
# RBD_OPT (the kit root, /opt/rbd): the caller sets it before sourcing this file.
if [ -z "${SUDO_USER:-}" ]; then
  _rbd_env_file=${RBD_ENV_FILE:-/opt/rbd/etc/rbd.env} _rbd_local_uid=${RBD_ENV_LOCAL_UID:-0}
else
  _rbd_env_file=/opt/rbd/etc/rbd.env _rbd_local_uid=0; unset RBD_CLI
fi
_rbd_pinned="RBD_POLICY_SHA256 RBD_POLICY_DIGEST RBD_KMS RBD_HOME RBD_ECR RBD_REGION RBD_ACCOUNT RBD_BUCKET KUBECONFIG RHOBOUND_STATE"
_rbd_pins() { local v; for v in $_rbd_pinned; do printf '%s=%s:%s\n' "$v" "${!v+set}" "${!v-}"; done; }
if [ ! -r "$_rbd_env_file" ]; then echo "rbd-env: cannot read $_rbd_env_file (bootstrap tools1 writes it)" >&2; exit 1; fi
set -a
# shellcheck disable=SC1090
. "$_rbd_env_file"
set +a
if [ -e "$_rbd_env_file.local" ]; then
  read -r _o _m < <(stat -L -c '%u %a' -- "$_rbd_env_file.local" 2> /dev/null) || true
  if [ "${_o:-}" != "$_rbd_local_uid" ] || (( 8#${_m:-0} & 8#022 )); then
    echo "rbd-env: $_rbd_env_file.local must be owned by uid $_rbd_local_uid and not group/other-writable (uid ${_o:-?}, mode ${_m:-?}): refused" >&2; exit 1
  fi
  if [ ! -r "$_rbd_env_file.local" ]; then echo "rbd-env: cannot read $_rbd_env_file.local" >&2; exit 1; fi
  _rbd_was=$(_rbd_pins)
  set -a
  # shellcheck disable=SC1090,SC1091
  . "$_rbd_env_file.local"
  set +a
  _rbd_bad=$(_rbd_pins | grep -vxF -f <(printf '%s\n' "$_rbd_was") | cut -d= -f1 | tr '\n' ' ') || true   # grep: 1 = none changed
  if [ -n "$_rbd_bad" ]; then
    echo "rbd-env: $_rbd_env_file.local changes ${_rbd_bad% }: those come from rbd.env only (rbd_bootstrap.sh tools1): refused" >&2; exit 1
  fi
  unset _o _m _rbd_was _rbd_bad
fi
unset -f _rbd_pins; unset _rbd_pinned _rbd_local_uid
for _v in RBD_REGION RBD_ACCOUNT RBD_ECR RBD_HOME KUBECONFIG RHOBOUND_STATE; do
  if [ -z "${!_v:-}" ]; then echo "rbd-env: $_v is not set in $_rbd_env_file" >&2; exit 1; fi
done
unset _v
export RBD_OPT=${RBD_OPT:-/opt/rbd}
export RBD_CLI=${RBD_CLI:-$RBD_OPT/bin/rhobound}
export AWS_REGION=${AWS_REGION:-$RBD_REGION} AWS_DEFAULT_REGION=${AWS_DEFAULT_REGION:-$RBD_REGION}
case ":$PATH:" in *":$RBD_OPT/bin:"*) ;; *) export PATH="$RBD_OPT/bin:$PATH" ;; esac
export RBD_NS=${RBD_NS:-kshop} RBD_OBS_NS=${RBD_OBS_NS:-kshop-obs} RBD_AB_NS=${RBD_AB_NS:-rbd-ab}

now_utc() { date -u +%Y-%m-%dT%H:%M:%SZ; }
log() { echo "[$(date -u +%H:%M:%S)] ${RBD_STEP:-$(basename "$0")}: $*" >&2; }
die() { log "ERROR: $1"; exit "${2:-1}"; }
need_cmd() { local c; for c in "$@"; do command -v "$c" > /dev/null 2>&1 || die "$c is not installed"; done; }

# rbd_result STEP true|false [JSON-OBJECT]: the step's last line, {"step": STEP, "ok": ..., <the object's keys>}
rbd_result() {
  local extra=${3:-'{}'}
  jq -cn --arg step "$1" --argjson ok "$2" --argjson extra "$extra" '{step: $step, ok: $ok} + $extra' 2> /dev/null \
    || printf '{"step":"%s","ok":%s,"note":"extra fields were not JSON"}\n' "$1" "$2"
}

# json_last_line [FILE]: the last line of FILE (or stdin) that is a JSON object; 1 when there is none
json_last_line() {
  local l
  while IFS= read -r l; do
    if [ -n "$l" ] && jq -e 'type == "object"' <<< "$l" > /dev/null 2>&1; then printf '%s\n' "$l"; return 0; fi
  done < <(if [ $# -ge 1 ]; then tac -- "$1"; else tac; fi)
  return 1
}

# ecr_login: docker (as the calling user) logged in to the registry of RBD_ECR; the password goes through a pipe only
ecr_login() {
  local host=${RBD_ECR%%/*}
  aws ecr get-login-password --region "$RBD_REGION" | docker login --username AWS --password-stdin "$host" > /dev/null \
    || { log "ERROR: docker login to $host failed"; return 1; }
}

sha256_of() { local h; h=$(sha256sum -- "$1" | cut -d' ' -f1) || return 1; [ -n "$h" ] && echo "sha256:$h"; }

# atomic_write DEST: stdin -> DEST (a temporary file beside it, then rename); an empty input is refused
atomic_write() {
  local dest=$1 tmp
  tmp=$(mktemp "$(dirname -- "$dest")/.$(basename -- "$dest").XXXXXX") || return 1
  if ! cat > "$tmp" || [ ! -s "$tmp" ]; then rm -f "$tmp"; log "ERROR: nothing to write to $dest"; return 1; fi
  chmod 0644 "$tmp" && mv -f "$tmp" "$dest"
}

# images_get KEY: an image reference (REF@sha256:...) from RBD_HOME/images.json (load, collector, busybox, abdrive)
images_get() {
  local v
  v=$(jq -r --arg k "$1" '.[$k] // empty' "$RBD_HOME/images.json" 2> /dev/null)
  [[ $v == *@sha256:* ]] || { log "ERROR: no image '$1' in $RBD_HOME/images.json (run: rbd_bootstrap.sh images)"; return 1; }
  echo "$v"
}
