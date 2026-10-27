#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
#
# A CI judge step on any OpenAI-compatible endpoint (docs/mcp/ARCHITECTURE.md 7): send the judge packet of a prediction
# to a pinned model through /chat/completions, check the reply with `rhobound judge-check`, and record it in the
# gate's artifacts.
#
#   JUDGE_ENDPOINT=https://api.example.com/v1 JUDGE_API_KEY=... JUDGE_MODEL_ID=<model id> \
#     bash openai-compatible.sh PREDICTION.json POLICY.json OUT_DIR
#
# Needs curl, jq, sha256sum and rhobound on PATH (or RHOBOUND). Keep the key in the CI system's secret store; it is
# read from the environment only and never written to OUT_DIR. POLICY_NAME is the policy's configured name (default:
# the file's base name); FIT, the fit record the prediction was made from, adds budgets and leverage to the packet.
# This repository's CI never runs it.
set -euo pipefail

if [ "$#" -ne 3 ]; then
  echo "usage: JUDGE_ENDPOINT=... JUDGE_API_KEY=... JUDGE_MODEL_ID=... $0 PREDICTION.json POLICY.json OUT_DIR" >&2
  exit 2
fi
prediction=$1 policy=$2 out=$3
rhobound=${RHOBOUND:-rhobound}
endpoint=${JUDGE_ENDPOINT:?set JUDGE_ENDPOINT to the API base URL, ending before /chat/completions}
model=${JUDGE_MODEL_ID:?set JUDGE_MODEL_ID to the pinned model id}
: "${JUDGE_API_KEY:?set JUDGE_API_KEY}"
policy_name=${POLICY_NAME:-$(basename "$policy" .json)}
prompt_file="$(cd "$(dirname "$0")" && pwd)/review_latency_impact.txt"
mkdir -p "$out"

# 1. The packet (with the fit's budgets and leverage when FIT names the fit record), and the digest the answer cites.
fit_args=()
if [ -n "${FIT:-}" ]; then fit_args=(--fit "$FIT"); fi
"$rhobound" judge-packet "$prediction" --policy "$policy" --policy-name "$policy_name" ${fit_args[@]+"${fit_args[@]}"} --json >"$out/packet.json"
packet_digest="sha256:$(tr -d '\n' <"$out/packet.json" | sha256sum | cut -d' ' -f1)"

# 2. The request: the prompt as the system message, the packet and its digest as the user message, temperature 0.
jq -n --arg model "$model" --rawfile system "$prompt_file" --rawfile packet "$out/packet.json" --arg digest "$packet_digest" '{
  model: $model,
  temperature: 0,
  max_tokens: 2048,
  messages: [{role: "system", content: $system}, {role: "user", content: ($packet + "\npacket digest: " + $digest)}]
}' >"$out/request.json"
request_digest="sha256:$(sha256sum "$out/request.json" | cut -d' ' -f1)"

curl --fail --silent --show-error "${endpoint%/}/chat/completions" \
  -H "Authorization: Bearer $JUDGE_API_KEY" -H "Content-Type: application/json" \
  --data @"$out/request.json" >"$out/response.json"

# 3. The answer: the model's text, without a Markdown fence if it added one.
jq -r '.choices[0].message.content' "$out/response.json" | sed -e '/^```/d' >"$out/judge-answer.json"

# 4. Only typed fields go on; a refused answer stops here (exit 1), recorded as "judge unavailable".
"$rhobound" judge-check "$out/judge-answer.json" --packet "$out/packet.json" --json >"$out/judge-check.json"

# 5. The gate, with the answer recorded as ci-judge (model id and request digest in gate.json).
"$rhobound" gate "$prediction" --policy "$policy" --out "$out/gate" --json \
  --judge-answer "$out/judge-answer.json" --judge-packet "$out/packet.json" \
  --judge-model "$model" --judge-request "$request_digest"
