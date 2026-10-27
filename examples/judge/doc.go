// SPDX-License-Identifier: Apache-2.0

// Package judge holds the example CI judge steps (docs/mcp/ARCHITECTURE.md 7): bedrock-converse.sh for Amazon Bedrock,
// openai-compatible.sh for any OpenAI-compatible endpoint, and the prompt they send, review_latency_impact.txt. It has
// no Go API; its tests check the scripts, and run each against a stand-in for the model.
package judge
