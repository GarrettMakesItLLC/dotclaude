#!/usr/bin/env bash
# Stop the model gateway started by bin/gateway-up.sh.
#
# Kills the recorded PID and nothing else. Never a pattern kill: several agent
# sessions share this box, and a `pkill litellm` would take out a sibling's
# proxy along with this one.
set -euo pipefail

HERE="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
# shellcheck source=gateway-common.sh
. "$HERE/gateway-common.sh"

pid="$(gateway_pid 2>/dev/null || true)"
if [ -z "$pid" ]; then
  if [ -e "$GATEWAY_PID_FILE" ]; then
    rm -f "$GATEWAY_PID_FILE"
    echo "gateway-down: not running (cleared a stale PID file)."
  else
    echo "gateway-down: not running."
  fi
  exit 0
fi

kill "$pid" 2>/dev/null || true
for _ in $(seq 1 20); do
  kill -0 "$pid" 2>/dev/null || break
  sleep 0.5
done
if kill -0 "$pid" 2>/dev/null; then
  kill -9 "$pid" 2>/dev/null || true
  sleep 1
fi
rm -f "$GATEWAY_PID_FILE"
echo "gateway-down: stopped (pid $pid)."
