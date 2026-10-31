#!/usr/bin/env bash
# judge (STUB, not wired into gate.yml): the gate's bounded packet -> a judge model -> the CLI's check of its answer.
#   sudo -n -u rbd /opt/rbd/ci/judge.sh RUN
# 1. rhobound judge-packet runs/RUN/prediction.json --policy runs/RUN/policy.json --fit <baseline fit> --now T --json > judge/packet.json
# 2. $JUDGE_CMD judge/packet.json > judge/answer.json   (any provider: a script that sends the packet with the
#    review_latency_impact prompt and prints the model's JSON answer; see the CLI's examples/judge/. JUDGE_CMD comes from
#    rbd.env: sudo's env_reset drops the caller's environment. Credentials: Secrets Manager rhobound-demo/<name>.)
# 3. rhobound judge-check judge/answer.json --packet judge/packet.json --json > judge/check.json
# predict.sh runs the judge inside the gate step when JUDGE_CMD is set (rbd.env.local); this stub stays for a by-hand review.
# Exit 0 answer admitted, 1 refused or failed, 2 not configured (JUDGE_CMD unset). Last stdout line: one JSON object.
set -euo pipefail
STEP=judge
ci_jstr() { python3 -I -c 'import json,sys; print(json.dumps(sys.argv[1]))' "$1"; }
ci_fail() { echo "$STEP: error: $1" >&2; printf '{"step":"%s","ok":false,"error":%s}\n' "$STEP" "$(ci_jstr "$1")"; exit "${2:-1}"; }
[[ $# -eq 1 ]] || ci_fail "usage: judge.sh RUN"
RUNID=$1
[[ $RUNID =~ ^[0-9a-f]{40}$ ]] || ci_fail "RUN must be a 40-hex commit id"
RBD_ROOT=/opt/rbd
NOW=$(date -u +%Y-%m-%dT%H:%M:%SZ)
if [[ -z ${SUDO_USER:-} ]]; then   # tests only; sudo never passes these
  [[ -n ${RBD_OPT:-} ]] && RBD_ROOT=$RBD_OPT
  [[ -n ${RBD_TEST_NOW:-} ]] && NOW=$RBD_TEST_NOW
fi
[[ -r $RBD_ROOT/lib/rbd-env.sh ]] || ci_fail "$RBD_ROOT/lib/rbd-env.sh missing"
# shellcheck source=/dev/null
ci_msg=$(. "$RBD_ROOT/lib/rbd-env.sh" 2>&1 > /dev/null) || ci_fail "rbd-env.sh: $ci_msg"
# shellcheck source=/dev/null
. "$RBD_ROOT/lib/rbd-env.sh"
PATH=$RBD_ROOT/bin:$PATH
[[ -n ${JUDGE_CMD:-} ]] || ci_fail "judge not configured: set JUDGE_CMD in rbd.env (a provider command: JUDGE_CMD PACKET > ANSWER)" 2
for v in RBD_HOME RHOBOUND_STATE; do [[ -n ${!v:-} ]] || ci_fail "$v not set by rbd-env.sh"; done
export RHOBOUND_STATE
RUN=$RBD_HOME/runs/$RUNID
[[ -r $RUN/prediction.json && -r $RUN/policy.json ]] || ci_fail "no prediction/policy in runs/$RUNID (predict.sh first)"
fitdir=$(python3 -I -c 'import json,sys; print(json.load(open(sys.argv[1]))["fit"]["dir"])' "$RBD_HOME/baseline.json") ||
  ci_fail "no fit in baseline.json"
J=$RUN/judge
mkdir -p "$J"
rhobound judge-packet "$RUN/prediction.json" --policy "$RUN/policy.json" --fit "$fitdir/fit.json" --now "$NOW" --json \
  > "$J/packet.json" 2> "$J/packet.err" || ci_fail "rhobound judge-packet failed: $(tail -n 1 "$J/packet.err")"
read -r -a cmd <<< "$JUDGE_CMD"
"${cmd[@]}" "$J/packet.json" > "$J/answer.json" 2> "$J/provider.err" || ci_fail "the judge command failed: $(tail -n 1 "$J/provider.err")"
rc=0
rhobound judge-check "$J/answer.json" --packet "$J/packet.json" --json > "$J/check.json" 2> "$J/check.err" || rc=$?
[[ $rc -eq 0 ]] || ci_fail "judge-check refused the answer (exit $rc): $(tail -n 1 "$J/check.err")"
echo "judge: answer admitted (judge/check.json)" >&2
printf '{"step":"judge","ok":true,"run":"%s"}\n' "$RUNID"
