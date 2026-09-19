#!/usr/bin/env bash
# What the gateway is doing right now, and which classes it can actually serve.
#
#   bin/gateway-status.sh            # human-readable
#   bin/gateway-status.sh --quiet    # exit 0 if up and ready, 1 otherwise
#
# The class table is the point. "Up" is not the useful answer when the
# Anthropic key expired an hour ago and every frontier request has been
# 404ing since.
set -uo pipefail

HERE="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
# shellcheck source=gateway-common.sh
. "$HERE/gateway-common.sh"

QUIET=0
[ "${1:-}" = "--quiet" ] && QUIET=1

pid="$(gateway_pid 2>/dev/null || true)"
ready=1
gateway_ready && ready=0

if [ "$QUIET" = 1 ]; then
  [ -n "$pid" ] && [ "$ready" = 0 ] && exit 0
  exit 1
fi

if [ -n "$pid" ]; then
  if [ "$ready" = 0 ]; then
    echo "gateway: UP and ready — $(gateway_url) (pid $pid)"
  else
    echo "gateway: process alive (pid $pid) but not answering $(gateway_url)/health/readiness"
  fi
else
  echo "gateway: DOWN. Start it with bin/gateway-up.sh"
fi

if [ -r "$GATEWAY_STATE_FILE" ]; then
  # shellcheck source=/dev/null
  . "$GATEWAY_STATE_FILE"
  echo "  started: ${GATEWAY_STARTED_AT:-unknown}"
  echo "  serving: ${GATEWAY_LIVE_CLASSES:-none}"
  [ -n "${GATEWAY_SKIPPED:-}" ] && echo "$GATEWAY_SKIPPED" | tr '|' '\n' | sed '/^$/d;s/^/  skipped on purpose: /'
fi

gateway_load_secrets
echo "  classes:"
while IFS='|' read -r name keys _fallbacks probe; do
  [ -n "$name" ] || continue
  blocker="$(gateway_class_blocker "$keys" "$probe")"
  if [ -z "$blocker" ]; then
    printf '    ✓ %-15s ready\n' "$name"
  else
    printf '    ✗ %-15s %s\n' "$name" "$blocker"
  fi
done < <(gateway_classes)

echo "  config:  $GATEWAY_RUNTIME_CONFIG"
echo "  log:     $GATEWAY_LOG_FILE"
[ -n "$pid" ] || exit 1
[ "$ready" = 0 ] || exit 1
