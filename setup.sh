#!/bin/sh
set -eu

SERVER_URL=${SERVER_URL:-http://127.0.0.1:8080}
SERVER_PORT=${SERVER_PORT:-8080}
CONTEXT_TOKENS=${CONTEXT_TOKENS:-131072}
MODEL_REPO=${MODEL_REPO:-unsloth/Qwen3.8-27B-GGUF}
MODEL_QUANT=${MODEL_QUANT:-UD-Q4_K_XL}
MODEL_ALIAS=${MODEL_ALIAS:-qwen3.8-27b}
MODELS_DIR=${MODELS_DIR:-$HOME/models}
SPEC_DECODING=${SPEC_DECODING:-none}
DRAFT_REPO=${DRAFT_REPO:-z-lab/Qwen3.8-27B-DFlash2-GGUF}
DRAFT_QUANT=${DRAFT_QUANT:-Q4_K_M}
MIN_MEMORY_BYTES=${MIN_MEMORY_BYTES:-51539607552}
MIN_FREE_DISK_KB=31457280
launch_agent="$HOME/Library/LaunchAgents/local.qwen.llama-server.plist"
server_log="$HOME/Library/Logs/qwen-llama-server.log"

say() { printf '\n==> %s\n' "$*"; }
fail() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

run_preflight() {
  say "Checking this Mac"
  [ "$(uname -m)" = "arm64" ] || fail "Apple Silicon (arm64) required"
  memory_bytes=$(sysctl -n hw.memsize)
  [ "$memory_bytes" -ge "$MIN_MEMORY_BYTES" ] || fail "48 GB unified memory required, found $((memory_bytes / 1073741824)) GB"
  free_disk_kb=$(df -k "$HOME" | awk 'NR==2 {print $4}')
  [ "$free_disk_kb" -ge "$MIN_FREE_DISK_KB" ] || fail "30 GB free disk required, found $((free_disk_kb / 1048576)) GB"
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
  brew install llama.cpp hf jq
  brew upgrade llama.cpp
  claude update || echo "claude update failed; continuing with the installed version"
}

download_gguf() {
  repo=$1
  quant=$2
  say "Downloading $repo ($quant) to $MODELS_DIR"
  hf download "$repo" --include "*$quant*.gguf" --local-dir "$MODELS_DIR/$(basename "$repo")"
}

use_draft() {
  case "$SPEC_DECODING" in
    dflash) return 0 ;;
    none) return 1 ;;
    *) fail "SPEC_DECODING must be none or dflash, found $SPEC_DECODING" ;;
  esac
}

run_download() {
  download_gguf "$MODEL_REPO" "$MODEL_QUANT"
  if use_draft; then
    download_gguf "$DRAFT_REPO" "$DRAFT_QUANT"
  fi
}

resolve_gguf() {
  directory="$MODELS_DIR/$(basename "$1")"
  found=$(find "$directory" -name "*$2*.gguf" 2>/dev/null | sort)
  file=$(printf '%s\n' "$found" | grep -- '-00001-of-' | head -n 1)
  [ -n "$file" ] || file=$(printf '%s\n' "$found" | head -n 1)
  [ -n "$file" ] || fail "no $2 .gguf in $directory. Run ./setup.sh download"
  echo "$file"
}

write_launch_agent() {
  say "Writing LaunchAgent $launch_agent"
  llama_server=$(command -v llama-server) || fail "llama-server not found. Run ./setup.sh install"
  gguf=$(resolve_gguf "$MODEL_REPO" "$MODEL_QUANT")
  draft=""
  if use_draft; then
    draft=$(resolve_gguf "$DRAFT_REPO" "$DRAFT_QUANT")
  fi
  mkdir -p "$(dirname "$launch_agent")" "$(dirname "$server_log")"
  jq -n \
    --arg server "$llama_server" \
    --arg gguf "$gguf" \
    --arg model_alias "$MODEL_ALIAS" \
    --arg port "$SERVER_PORT" \
    --arg context "$CONTEXT_TOKENS" \
    --arg draft "$draft" \
    --arg log "$server_log" \
    '{
      Label: "local.qwen.llama-server",
      ProgramArguments: ([$server, "-m", $gguf, "--alias", $model_alias, "--host", "127.0.0.1", "--port", $port, "-c", $context, "-ngl", "99", "-fa", "on", "--cache-type-k", "q8_0", "--cache-type-v", "q8_0", "--jinja", "--parallel", "1", "--temp", "1.0", "--top-p", "0.95", "--top-k", "20", "--min-p", "0", "--presence-penalty", "0"]
        + (if $draft == "" then [] else ["-md", $draft, "--spec-type", "draft-dflash", "--spec-draft-n-max", "7"] end)),
      RunAtLoad: true,
      KeepAlive: true,
      StandardOutPath: $log,
      StandardErrorPath: $log
    }' > "$launch_agent"
  plutil -convert xml1 "$launch_agent"
}

run_start_server() {
  say "Starting llama-server"
  write_launch_agent
  launchctl bootout "gui/$(id -u)/local.qwen.llama-server" 2>/dev/null || true
  launchctl bootstrap "gui/$(id -u)" "$launch_agent"
  attempts=0
  until curl -sf "$SERVER_URL/health" >/dev/null 2>&1; do
    attempts=$((attempts + 1))
    [ "$attempts" -le 300 ] || fail "llama-server did not answer at $SERVER_URL within 300 s. Check: tail -n 50 $server_log"
    sleep 1
  done
  echo "llama-server is up at $SERVER_URL"
}

run_profile() {
  model_id=${MODEL_ID:-$MODEL_ALIAS}
  profile="$HOME/.claude/local-qwen.json"
  launcher_dir="$HOME/.local/bin"
  launcher="$launcher_dir/claude-local"
  say "Writing Claude Code profile for $model_id"
  mkdir -p "$HOME/.claude" "$launcher_dir"
  jq -n \
    --arg base_url "$SERVER_URL" \
    --arg model "$model_id" \
    --arg context "$CONTEXT_TOKENS" \
    '{availableModels: [$model], env: {
      ANTHROPIC_BASE_URL: $base_url,
      ANTHROPIC_AUTH_TOKEN: "local",
      ANTHROPIC_API_KEY: "",
      ANTHROPIC_MODEL: $model,
      ANTHROPIC_DEFAULT_OPUS_MODEL: $model,
      ANTHROPIC_DEFAULT_SONNET_MODEL: $model,
      ANTHROPIC_DEFAULT_HAIKU_MODEL: $model,
      CLAUDE_CODE_SUBAGENT_MODEL: $model,
      CLAUDE_CODE_MAX_CONTEXT_TOKENS: $context,
      CLAUDE_CODE_AUTO_COMPACT_WINDOW: "100000",
      CLAUDE_CODE_MAX_OUTPUT_TOKENS: "8192",
      API_TIMEOUT_MS: "1800000",
      CLAUDE_CODE_ATTRIBUTION_HEADER: "0",
      CLAUDE_CODE_DISABLE_EXPERIMENTAL_BETAS: "1",
      CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC: "1"
    }}' > "$profile"
  # shellcheck disable=SC2016
  printf '%s\n' '#!/bin/sh' 'exec claude --settings "$HOME/.claude/local-qwen.json" "$@"' > "$launcher"
  chmod +x "$launcher"
  echo "profile:  $profile"
  echo "available models: $(jq -r '.availableModels | join(", ")' "$profile")"
  echo "launcher: $launcher"
  if [ "$(command -v claude-local 2>/dev/null || true)" != "$launcher" ]; then
    cat <<'EOF'
NOTE: claude-local is not on your PATH yet. Add ~/.local/bin, then open a new shell:
  zsh:  echo 'export PATH="$HOME/.local/bin:$PATH"' >> ~/.zshrc && source ~/.zshrc
  fish: fish_add_path ~/.local/bin
EOF
  fi
}

run_all() {
  run_profile
  run_preflight
  run_install
  run_download
  run_start_server
  say "Done with the scripted part"
  echo "Then: ./smoke-test.sh"
}

case "${1:-all}" in
  preflight) run_preflight ;;
  install) run_install ;;
  download) run_download ;;
  start) run_start_server ;;
  profile) run_profile ;;
  launch-agent) write_launch_agent ;;
  all) run_all ;;
  *) fail "usage: $0 [all|preflight|install|download|start|profile|launch-agent]" ;;
esac
