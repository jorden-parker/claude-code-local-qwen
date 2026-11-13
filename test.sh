#!/bin/sh
set -eu

repo_dir=$(cd "$(dirname "$0")" && pwd)
fake_home=$(mktemp -d)
trap 'rm -rf "$fake_home"' EXIT
failures=0

check() {
  description=$1
  shift
  if "$@" >/dev/null 2>&1; then
    echo "ok   - $description"
  else
    echo "FAIL - $description"
    failures=$((failures + 1))
  fi
}

mkdir -p "$fake_home/.claude"
echo '{"theme":"dark"}' > "$fake_home/.claude/settings.json"

HOME="$fake_home" MODEL_ID="test-model-6bit" "$repo_dir/setup.sh" profile

profile="$fake_home/.claude/local-qwen.json"
launcher="$fake_home/.local/bin/claude-local"

check "profile is valid JSON" jq -e . "$profile"
check "base URL points at local oMLX" jq -e '.env.ANTHROPIC_BASE_URL == "http://localhost:8000"' "$profile"
check "every model alias uses the local model" jq -e '[.env.ANTHROPIC_MODEL, .env.ANTHROPIC_DEFAULT_OPUS_MODEL, .env.ANTHROPIC_DEFAULT_SONNET_MODEL, .env.ANTHROPIC_DEFAULT_HAIKU_MODEL, .env.CLAUDE_CODE_SUBAGENT_MODEL] | all(. == "test-model-6bit")' "$profile"
check "attribution header is off" jq -e '.env.CLAUDE_CODE_ATTRIBUTION_HEADER == "0"' "$profile"
check "context window matches server" jq -e '.env.CLAUDE_CODE_MAX_CONTEXT_TOKENS == "131072"' "$profile"
check "launcher is executable" test -x "$launcher"
check "launcher passes the profile" grep -q 'local-qwen.json' "$launcher"
check "main settings.json is untouched" jq -e '. == {"theme":"dark"}' "$fake_home/.claude/settings.json"
check "gpu-limit rejects non-numeric values" sh -c "! '$repo_dir/gpu-limit.sh' abc"
check "gpu-limit rejects values that starve macOS" sh -c "! '$repo_dir/gpu-limit.sh' 46000"

if command -v shellcheck >/dev/null 2>&1; then
  check "shellcheck passes" shellcheck "$repo_dir"/*.sh
fi

if [ "$failures" -ne 0 ]; then
  echo "$failures test(s) failed"
  exit 1
fi
echo "all tests passed"
