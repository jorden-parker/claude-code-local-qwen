#!/bin/sh
# shellcheck disable=SC2016
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

setup_env() {
  env -i HOME="$fake_home" PATH="$fake_bin:$PATH" MODELS_DIR="$models_dir" "$@"
}

has_argument_pair() {
  jq -e --arg flag "$1" --arg value "$2" \
    '.ProgramArguments | . as $arguments | any(range(0; length - 1); $arguments[.] == $flag and $arguments[. + 1] == $value)' \
    "$agent_json"
}

mkdir -p "$fake_home/.claude"
echo '{"theme":"dark"}' > "$fake_home/.claude/settings.json"

fake_bin="$fake_home/bin"
mkdir -p "$fake_bin"
printf '#!/bin/sh\n' > "$fake_bin/llama-server"
chmod +x "$fake_bin/llama-server"

models_dir="$fake_home/models"
gguf_path="$models_dir/Qwen3.8-27B-GGUF/Qwen3.8-27B-UD-Q4_K_XL.gguf"
draft_path="$models_dir/Qwen3.8-27B-DFlash2-GGUF/Qwen3.8-27B-DFlash2-Q4_K_M.gguf"
mkdir -p "$(dirname "$gguf_path")" "$(dirname "$draft_path")"
touch "$gguf_path" "$draft_path"

profile="$fake_home/.claude/local-qwen.json"
launcher="$fake_home/.local/bin/claude-local"
launch_agent="$fake_home/Library/LaunchAgents/local.qwen.llama-server.plist"
agent_json="$fake_home/llama-server-agent.json"

profile_output=$(setup_env MODEL_ID=test-model "$repo_dir/setup.sh" profile)

check "profile is valid JSON" jq -e . "$profile"
check "profile lists the local model in availableModels" jq -e '.availableModels == ["test-model"]' "$profile"
check "profile stage logs the available models" sh -c 'printf "%s\n" "$1" | grep -q "^available models: test-model$"' sh "$profile_output"
check "base URL points at local llama-server" jq -e '.env.ANTHROPIC_BASE_URL == "http://127.0.0.1:8080"' "$profile"
check "every model alias uses the local model" jq -e '[.env.ANTHROPIC_MODEL, .env.ANTHROPIC_DEFAULT_OPUS_MODEL, .env.ANTHROPIC_DEFAULT_SONNET_MODEL, .env.ANTHROPIC_DEFAULT_HAIKU_MODEL, .env.CLAUDE_CODE_SUBAGENT_MODEL] | all(. == "test-model")' "$profile"
check "profile env matches the llama-server setup" jq -e --arg model test-model '.env == {ANTHROPIC_BASE_URL: "http://127.0.0.1:8080", ANTHROPIC_AUTH_TOKEN: "local", ANTHROPIC_API_KEY: "", ANTHROPIC_MODEL: $model, ANTHROPIC_DEFAULT_OPUS_MODEL: $model, ANTHROPIC_DEFAULT_SONNET_MODEL: $model, ANTHROPIC_DEFAULT_HAIKU_MODEL: $model, CLAUDE_CODE_SUBAGENT_MODEL: $model, CLAUDE_CODE_MAX_CONTEXT_TOKENS: "131072", CLAUDE_CODE_AUTO_COMPACT_WINDOW: "100000", CLAUDE_CODE_MAX_OUTPUT_TOKENS: "24576", API_TIMEOUT_MS: "1800000", CLAUDE_CODE_ATTRIBUTION_HEADER: "0", CLAUDE_CODE_DISABLE_EXPERIMENTAL_BETAS: "1", CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC: "1"}' "$profile"
check "thinking budget is not capped" jq -e '.env | has("MAX_THINKING_TOKENS") | not' "$profile"
check "launcher is executable" test -x "$launcher"
check "launcher passes the profile" grep -q 'local-qwen.json' "$launcher"
check "main settings.json is untouched" jq -e '. == {"theme":"dark"}' "$fake_home/.claude/settings.json"

crush_config="$fake_home/.config/crush-local/crushrc"
crush_launcher="$fake_home/.local/bin/crush-local"
check "crush config points the llamacpp provider at the local server" grep -q 'provider add llamacpp .*--type llamacpp --base-url "http://127.0.0.1:8080"' "$crush_config"
check "crush model uses the server context window" grep -q 'model add llamacpp/test-model .*--context-window 131072' "$crush_config"
check "crush large and small slots use the local model" sh -c "grep -q '^model large llamacpp/test-model' '$crush_config' && grep -q '^model small llamacpp/test-model' '$crush_config'"
check "crush launcher is executable" test -x "$crush_launcher"
check "crush launcher uses its own config and data dirs" sh -c "grep -q 'CRUSH_GLOBAL_CONFIG=\"\$HOME/.config/crush-local\"' '$crush_launcher' && grep -q 'CRUSH_GLOBAL_DATA=\"\$HOME/.local/share/crush-local\"' '$crush_launcher'"
check "main crush config is untouched" test ! -e "$fake_home/.config/crush"
if command -v crush >/dev/null 2>&1; then
  check "crush lists only the local model" sh -c "[ \"\$(HOME='$fake_home' '$crush_launcher' models)\" = llamacpp/test-model ]"
fi

check "launch-agent stage writes the plist" setup_env "$repo_dir/setup.sh" launch-agent
plutil -convert json -o "$agent_json" "$launch_agent" 2>/dev/null || true
check "LaunchAgent plist lints" plutil -lint "$launch_agent"
check "LaunchAgent plist is XML" grep -q '<plist' "$launch_agent"
check "LaunchAgent runs the installed llama-server" jq -e --arg server "$fake_bin/llama-server" '.ProgramArguments[0] == $server' "$agent_json"
check "LaunchAgent serves the downloaded GGUF" jq -e --arg gguf "$gguf_path" '.ProgramArguments | any(. == $gguf)' "$agent_json"
check "LaunchAgent listens on 127.0.0.1:8080" has_argument_pair --host 127.0.0.1
check "LaunchAgent port is 8080" has_argument_pair --port 8080
check "context window is 131072" has_argument_pair -c 131072
check "KV cache is q8_0" has_argument_pair --cache-type-k q8_0
check "V cache is q8_0" has_argument_pair --cache-type-v q8_0
chat_template="$fake_home/.config/local-qwen/qwen3.8-27b-chat-template.jinja"
check "LaunchAgent uses the installed chat template" has_argument_pair --chat-template-file "$chat_template"
check "installed chat template matches the repo copy" cmp "$repo_dir/qwen3.8-27b-chat-template.jinja" "$chat_template"
check "chat template accepts system messages after the first user message" sh -c "test -f '$repo_dir/qwen3.8-27b-chat-template.jinja' && ! grep -q 'System message must be at the beginning' '$repo_dir/qwen3.8-27b-chat-template.jinja'"
check "no draft model by default" jq -e '.ProgramArguments | any(. == "-md") | not' "$agent_json"
check "LaunchAgent runs at load and stays alive" jq -e '.RunAtLoad == true and .KeepAlive == true' "$agent_json"
check "LaunchAgent logs to the server log" jq -e --arg log "$fake_home/Library/Logs/qwen-llama-server.log" '.StandardOutPath == $log and .StandardErrorPath == $log' "$agent_json"

setup_env SPEC_DECODING=dflash "$repo_dir/setup.sh" launch-agent
plutil -convert json -o "$agent_json" "$launch_agent" 2>/dev/null || true
check "dflash LaunchAgent plist lints" plutil -lint "$launch_agent"
check "dflash LaunchAgent loads the downloaded draft GGUF" has_argument_pair -md "$draft_path"
check "dflash LaunchAgent selects draft-dflash decoding" has_argument_pair --spec-type draft-dflash
check "dflash LaunchAgent sets 7 draft tokens" has_argument_pair --spec-draft-n-max 7

start_bin="$fake_home/start-bin"
unload_polls_left="$fake_home/unload-polls-left"
mkdir -p "$start_bin"
cat > "$start_bin/launchctl" <<EOF
#!/bin/sh
polls=\$(cat "$unload_polls_left" 2>/dev/null || echo 0)
case "\$1" in
  bootout) echo 3 > "$unload_polls_left" ;;
  print) [ "\$polls" -gt 0 ] || exit 1; echo \$((polls - 1)) > "$unload_polls_left" ;;
  bootstrap) [ "\$polls" -eq 0 ] || { echo "Bootstrap failed: 5: Input/output error" >&2; exit 5; } ;;
esac
EOF
printf '#!/bin/sh\n' > "$start_bin/curl"
chmod +x "$start_bin/launchctl" "$start_bin/curl"
check "start waits for the old server to unload before bootstrapping" env -i HOME="$fake_home" PATH="$start_bin:$fake_bin:$PATH" MODELS_DIR="$models_dir" "$repo_dir/setup.sh" start

low_memory_home="$fake_home/low-memory"
mkdir -p "$low_memory_home"
setup_status=0
env -i HOME="$low_memory_home" PATH="$fake_bin:/usr/bin:/bin" MIN_MEMORY_BYTES=999999999999999 "$repo_dir/setup.sh" >/dev/null 2>&1 || setup_status=$?
check "setup stops when preflight fails" test "$setup_status" -ne 0
check "launcher exists even when preflight fails" test -x "$low_memory_home/.local/bin/claude-local"
resolved_launcher=$(env -i HOME="$low_memory_home" PATH=/usr/bin:/bin zsh -c 'PATH="$1:$PATH"; command -v claude-local' zsh "$low_memory_home/.local/bin")
check "zsh resolves claude-local to the fake launcher" test "$resolved_launcher" = "$low_memory_home/.local/bin/claude-local"

logs_home="$fake_home/logs"
logs_bin="$logs_home/bin"
server_log="$logs_home/Library/Logs/qwen-llama-server.log"
logs_output_file="$logs_home/logs-output"
mkdir -p "$logs_home/Library/Logs" "$logs_bin"

stream_logs_then_append() {
  env -i HOME="$logs_home" PATH="$logs_bin:/usr/bin:/bin" "$repo_dir/logs.sh" > "$logs_output_file" 2>&1 &
  logs_pid=$!
  sleep 1
  printf '%s\n' "$1" >> "$server_log"
  sleep 2
  kill "$logs_pid" 2>/dev/null || true
  wait "$logs_pid" 2>/dev/null || true
  cat "$logs_output_file"
}

printf 'first line\nsrv  load_model: loaded\n' > "$server_log"
printf '#!/bin/sh\nprintf "\\tstate = running\\n\\tlast exit code = 0\\n"\n' > "$logs_bin/launchctl"
chmod +x "$logs_bin/launchctl"
logs_output=$(stream_logs_then_append "srv  appended while streaming")
check "logs shows the service state" sh -c 'printf "%s\n" "$1" | grep -q "state = running"' sh "$logs_output"
check "logs shows the end of the server log" sh -c 'printf "%s\n" "$1" | grep -q "srv  load_model: loaded"' sh "$logs_output"
check "logs keeps streaming lines written after it starts" sh -c 'printf "%s\n" "$1" | grep -q "srv  appended while streaming"' sh "$logs_output"

printf '#!/bin/sh\n[ "$1" = print ] && exit 113\nprintf "launchd: local.qwen.llama-server bootstrap failed\\n"\n' > "$logs_bin/launchctl"
printf '#!/bin/sh\nprintf "launchd: local.qwen.llama-server bootstrap failed\\n"\n' > "$logs_bin/log"
chmod +x "$logs_bin/launchctl" "$logs_bin/log"
rm "$server_log"
logs_output=$(stream_logs_then_append "srv  server started later")
check "logs says when the service is not loaded" sh -c 'printf "%s\n" "$1" | grep -q "not loaded"' sh "$logs_output"
check "logs says when the server log is missing" sh -c 'printf "%s\n" "$1" | grep -q "no server log"' sh "$logs_output"
check "logs streams the server log once it appears" sh -c 'printf "%s\n" "$1" | grep -q "srv  server started later"' sh "$logs_output"
check "logs shows macOS launchd messages when the service is not loaded" sh -c 'printf "%s\n" "$1" | grep -q "bootstrap failed"' sh "$logs_output"

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
