#!/bin/sh
set -eu

MODEL_VARIANT=${MODEL_VARIANT:-6bit}
WITH_4BIT=${WITH_4BIT:-0}
SERVER_URL=${SERVER_URL:-http://localhost:8000}
CONTEXT_TOKENS=${CONTEXT_TOKENS:-131072}
MODELS_DIR=${MODELS_DIR:-$HOME/.omlx/models}
MODEL_REPO_PREFIX=mlx-community/Qwen3.6-35B-A3B
MIN_MEMORY_BYTES=51539607552
MIN_FREE_DISK_KB=73400320

say() { printf '\n==> %s\n' "$*"; }
fail() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

run_preflight() {
  say "Checking this Mac"
  [ "$(uname -m)" = "arm64" ] || fail "Apple Silicon (arm64) required"
  macos_major=$(sw_vers -productVersion | cut -d. -f1)
  [ "$macos_major" -ge 15 ] || fail "macOS 15 or later required (oMLX requirement), found $(sw_vers -productVersion)"
  memory_bytes=$(sysctl -n hw.memsize)
  [ "$memory_bytes" -ge "$MIN_MEMORY_BYTES" ] || fail "48 GB unified memory required, found $((memory_bytes / 1073741824)) GB"
  free_disk_kb=$(df -k "$HOME" | awk 'NR==2 {print $4}')
  [ "$free_disk_kb" -ge "$MIN_FREE_DISK_KB" ] || fail "70 GB free disk required, found $((free_disk_kb / 1048576)) GB"
  echo "chip:   $(sysctl -n machdep.cpu.brand_string)"
  echo "memory: $((memory_bytes / 1073741824)) GB"
  echo "disk:   $((free_disk_kb / 1048576)) GB free"
  echo "macOS:  $(sw_vers -productVersion)"
  echo "GPU wired limit (0 = macOS default): $(sysctl -n iogpu.wired_limit_mb 2>/dev/null || echo unknown) MB"
}

run_install() {
  say "Installing tools"
  command -v brew >/dev/null 2>&1 || fail "Homebrew not found. Install it from https://brew.sh, then re-run"
  command -v claude >/dev/null 2>&1 || fail "Claude Code not found. Install it from https://code.claude.com, then re-run"
  brew tap jundot/omlx
  brew install jundot/omlx/omlx hf
  command -v jq >/dev/null 2>&1 || brew install jq
  claude update || echo "claude update failed; continuing with the installed version"
}

download_variant() {
  variant=$1
  repo="$MODEL_REPO_PREFIX-$variant"
  target="$MODELS_DIR/$(basename "$repo")"
  say "Downloading $repo to $target"
  mkdir -p "$MODELS_DIR"
  hf download "$repo" --local-dir "$target"
}

run_download() {
  download_variant "$MODEL_VARIANT"
  if [ "$WITH_4BIT" = "1" ] && [ "$MODEL_VARIANT" != "4bit" ]; then
    download_variant 4bit
  fi
}

run_start_server() {
  say "Starting oMLX"
  brew services restart omlx
  attempts=0
  until curl -sf "$SERVER_URL/v1/models" >/dev/null 2>&1; do
    attempts=$((attempts + 1))
    [ "$attempts" -le 60 ] || fail "oMLX did not answer at $SERVER_URL within 60 s. Check: brew services info omlx"
    sleep 1
  done
  echo "oMLX is up at $SERVER_URL"
}

resolve_model_id() {
  if [ -n "${MODEL_ID:-}" ]; then
    echo "$MODEL_ID"
    return
  fi
  model_id=$(curl -sf "$SERVER_URL/v1/models" | jq -r --arg variant "$MODEL_VARIANT" '[.data[].id | select(test("Qwen3.6-35B-A3B"; "i")) | select(endswith($variant))][0] // empty')
  [ -n "$model_id" ] || fail "oMLX lists no Qwen3.6-35B-A3B $MODEL_VARIANT model. Run: curl -s $SERVER_URL/v1/models"
  echo "$model_id"
}

run_profile() {
  model_id=$(resolve_model_id)
  profile="$HOME/.claude/local-qwen.json"
  launcher_dir="$HOME/.local/bin"
  launcher="$launcher_dir/claude-local"
  say "Writing Claude Code profile for $model_id"
  mkdir -p "$HOME/.claude" "$launcher_dir"
  jq -n \
    --arg base_url "$SERVER_URL" \
    --arg auth_token "${OMLX_API_KEY:-omlx}" \
    --arg model "$model_id" \
    --arg context "$CONTEXT_TOKENS" \
    '{env: {
      ANTHROPIC_BASE_URL: $base_url,
      ANTHROPIC_AUTH_TOKEN: $auth_token,
      ANTHROPIC_API_KEY: "",
      ANTHROPIC_MODEL: $model,
      ANTHROPIC_DEFAULT_OPUS_MODEL: $model,
      ANTHROPIC_DEFAULT_SONNET_MODEL: $model,
      ANTHROPIC_DEFAULT_HAIKU_MODEL: $model,
      CLAUDE_CODE_SUBAGENT_MODEL: $model,
      CLAUDE_CODE_ATTRIBUTION_HEADER: "0",
      CLAUDE_CODE_MAX_CONTEXT_TOKENS: $context,
      CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC: "1"
    }}' > "$profile"
  # shellcheck disable=SC2016
  printf '%s\n' '#!/bin/sh' 'exec claude --settings "$HOME/.claude/local-qwen.json" "$@"' > "$launcher"
  chmod +x "$launcher"
  echo "profile:  $profile"
  echo "launcher: $launcher"
  case ":$PATH:" in
    *":$launcher_dir:"*) ;;
    *) echo "NOTE: $launcher_dir is not on your PATH. Add it, or run $launcher directly." ;;
  esac
}

run_all() {
  run_preflight
  run_install
  run_download
  run_start_server
  run_profile
  say "Done with the scripted part"
  echo "Next: open $SERVER_URL/admin and set context length $CONTEXT_TOKENS and sampling (see README step 4)."
  echo "Then: ./smoke-test.sh"
}

case "${1:-all}" in
  preflight) run_preflight ;;
  install) run_install ;;
  download) run_download ;;
  start) run_start_server ;;
  profile) run_profile ;;
  all) run_all ;;
  *) fail "usage: $0 [all|preflight|install|download|start|profile]" ;;
esac
