#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
#
# A CI judge step on Amazon Bedrock (docs/mcp/ARCHITECTURE.md 7): send the judge packet of a prediction to a pinned
# model through the Converse API, check the reply with `rhobound judge-check`, and record it in the gate's artifacts.
#
#   JUDGE_MODEL_ID=<model id> bash bedrock-converse.sh PREDICTION.json POLICY.json OUT_DIR
#
# Needs the AWS CLI v2 with credentials for bedrock:InvokeModel on that one model (the AWS_REGION of the endpoint set),
# jq, sha256sum and rhobound on PATH (or RHOBOUND). POLICY_NAME is the policy's configured name (default: the file's
# base name); FIT, the fit record the prediction was made from, adds budgets and leverage to the packet. This
# repository's CI never runs it.
set -euo pipefail

if [ "$#" -ne 3 ]; then
  echo "usage: JUDGE_MODEL_ID=<model id> $0 PREDICTION.json POLICY.json OUT_DIR" >&2
  exit 2
fi
prediction=$1 policy=$2 out=$3
rhobound=${RHOBOUND:-rhobound}
model=${JUDGE_MODEL_ID:?set JUDGE_MODEL_ID to the pinned model id}
policy_name=${POLICY_NAME:-$(basename "$policy" .json)}
prompt_file="$(cd "$(dirname "$0")" && pwd)/review_latency_impact.txt"
mkdir -p "$out"

# 1. The packet (with the fit's budgets and leverage when FIT names the fit record), and the digest the answer cites.
fit_args=()
if [ -n "${FIT:-}" ]; then fit_args=(--fit "$FIT"); fi
"$rhobound" judge-packet "$prediction" --policy "$policy" --policy-name "$policy_name" ${fit_args[@]+"${fit_args[@]}"} --json >"$out/packet.json"
packet_digest="sha256:$(tr -d '\n' <"$out/packet.json" | sha256sum | cut -d' ' -f1)"

# 2. The request: the prompt as the system text, the packet and its digest as the user message, temperature 0.
jq -n --rawfile system "$prompt_file" --rawfile packet "$out/packet.json" --arg digest "$packet_digest" '{
  system: [{text: $system}],
  messages: [{role: "user", content: [{text: ($packet + "\npacket digest: " + $digest)}]}],
  inferenceConfig: {maxTokens: 2048, temperature: 0}
}' >"$out/request.json"
request_digest="sha256:$(sha256sum "$out/request.json" | cut -d' ' -f1)"

aws bedrock-runtime converse --model-id "$model" \
  --system "$(jq -c .system "$out/request.json")" \
  --messages "$(jq -c .messages "$out/request.json")" \
  --inference-config "$(jq -c .inferenceConfig "$out/request.json")" \
  --output json >"$out/response.json"

# 3. The answer: the model's text, without a Markdown fence if it added one.
jq -r '.output.message.content[0].text' "$out/response.json" | sed -e '/^```/d' >"$out/judge-answer.json"

# 4. Only typed fields go on. An answer judge-check refuses (exit 1) or cannot read (exit 2) is "judge unavailable":
#    recorded in OUT/judge-unavailable.json, never retried into another answer, and the gate runs without it, so a
#    judge that answers badly cannot stop a release (or pass one) on its own.
judge_args=()
if "$rhobound" judge-check "$out/judge-answer.json" --packet "$out/packet.json" --json >"$out/judge-check.json" 2>"$out/judge-check.err"; then
  judge_args=(--judge-answer "$out/judge-answer.json" --judge-packet "$out/packet.json" \
    --judge-model "$model" --judge-request "$request_digest")
else
  check_status=$?
  jq -n --arg model "$model" --arg request "$request_digest" --argjson status "$check_status" \
    --rawfile check "$out/judge-check.json" --rawfile err "$out/judge-check.err" \
    '{judge: "unavailable", model_id: $model, request: $request, judge_check_status: $status, judge_check: $check, stderr: $err}' \
    >"$out/judge-unavailable.json"
fi

# 5. The gate, with a checked answer recorded as ci-judge (model id and request digest in gate.json). Its exit status is
#    the script's: 0 pass, 1 block, 2 error, 3 inconclusive.
"$rhobound" gate "$prediction" --policy "$policy" --out "$out/gate" --json ${judge_args[@]+"${judge_args[@]}"}
