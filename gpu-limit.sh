#!/bin/sh
set -eu

MAX_SAFE_LIMIT_MB=43008

current=$(sysctl -n iogpu.wired_limit_mb 2>/dev/null || echo unknown)
echo "Current GPU wired limit: $current MB (0 = macOS default, about 75% of RAM)"

requested=${1:-40960}

if [ "$requested" = "reset" ]; then
  requested=0
fi

case "$requested" in
  ''|*[!0-9]*) echo "ERROR: limit must be a number of MB, or 'reset'" >&2; exit 1 ;;
esac

if [ "$requested" -gt "$MAX_SAFE_LIMIT_MB" ]; then
  echo "ERROR: $requested MB leaves too little memory for macOS on a 48 GB Mac (max $MAX_SAFE_LIMIT_MB)" >&2
  exit 1
fi

echo "This sets iogpu.wired_limit_mb=$requested with sudo. It resets on reboot."
printf 'Continue? [y/N] '
read -r answer
case "$answer" in
  y|Y) sudo sysctl "iogpu.wired_limit_mb=$requested" ;;
  *) echo "Cancelled." ;;
esac
