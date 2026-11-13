#!/bin/sh
set -u

service="gui/$(id -u)/local.qwen.llama-server"
server_log="$HOME/Library/Logs/qwen-llama-server.log"
line_count=${LINE_COUNT:-50}

echo "==> Service $service"
if service_details=$(launchctl print "$service" 2>/dev/null); then
  printf '%s\n' "$service_details" | grep -E 'state =|last exit code|pid ='
else
  echo "not loaded. Start it with: ./setup.sh start"
  echo
  echo "==> macOS launchd messages from the last 10 minutes"
  log show --last 10m --style compact --predicate 'process == "launchd" AND eventMessage CONTAINS "local.qwen.llama-server"' 2>/dev/null | grep -v '^Timestamp' | tail -n 20
fi

echo
echo "==> Last $line_count lines of $server_log"
if [ -f "$server_log" ]; then
  tail -n "$line_count" "$server_log"
else
  echo "no server log yet. The server has not started."
fi

if [ "${1:-}" = "-f" ] && [ -f "$server_log" ]; then
  echo
  echo "==> Following $server_log (Ctrl-C to stop)"
  tail -n 0 -f "$server_log"
fi
