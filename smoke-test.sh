#!/bin/sh
set -eu

profile="$HOME/.claude/local-qwen.json"
[ -f "$profile" ] || { echo "ERROR: $profile missing. Run ./setup.sh first." >&2; exit 1; }

base_url=$(jq -r .env.ANTHROPIC_BASE_URL "$profile")
auth_token=$(jq -r .env.ANTHROPIC_AUTH_TOKEN "$profile")
model_id=$(jq -r .env.ANTHROPIC_MODEL "$profile")

echo "==> 1/2 Direct /v1/messages call to $model_id"
start=$(date +%s)
response=$(curl -sf "$base_url/v1/messages" \
  -H "content-type: application/json" \
  -H "anthropic-version: 2023-06-01" \
  -H "x-api-key: $auth_token" \
  -H "authorization: Bearer $auth_token" \
  -d "$(jq -n --arg model "$model_id" '{model: $model, max_tokens: 64, messages: [{role: "user", content: "Reply with exactly: OK"}]}')") \
  || { echo "ERROR: server did not answer. Is oMLX running? brew services info omlx" >&2; exit 1; }
echo "reply: $(echo "$response" | jq -r '[.content[] | select(.type == "text") | .text] | join("")')"
echo "took:  $(( $(date +%s) - start )) s"

echo "==> 2/2 Claude Code through the local profile (first call reads the full system prompt, so expect ~30-60 s)"
start=$(date +%s)
"$HOME/.local/bin/claude-local" -p "Reply with exactly: OK"
echo "took:  $(( $(date +%s) - start )) s"

echo
echo "Smoke test passed. Next: run claude-local in a repo, send two messages, and check the oMLX log shows a cache hit on the second."
