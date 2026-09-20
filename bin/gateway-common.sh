#!/usr/bin/env bash
# Shared plumbing for bin/gateway-{up,down,status}.sh. Sourced, never run.
#
# Everything here is about one property: a class is either LIVE with its real
# credential, or it is absent and someone said so by name. There is no third
# state where a request for `frontier` is quietly answered by a flash model.

# Where the proxy's runtime state lives. Outside the repo — it holds a minted
# master key, a PID, and a log of who called what.
: "${CLAUDE_GATEWAY_HOME:=$HOME/.claude/gateway}"
: "${GATEWAY_PORT:=4000}"
: "${GATEWAY_HOST:=127.0.0.1}"
: "${GATEWAY_SECRETS_DIR:=$HOME/.config/secrets}"

# Consumed by the three entry points that source this file, not here.
# shellcheck disable=SC2034
GATEWAY_PID_FILE="$CLAUDE_GATEWAY_HOME/gateway.pid"
# shellcheck disable=SC2034
GATEWAY_LOG_FILE="$CLAUDE_GATEWAY_HOME/gateway.log"
# shellcheck disable=SC2034
GATEWAY_RUNTIME_CONFIG="$CLAUDE_GATEWAY_HOME/runtime-config.yaml"
# shellcheck disable=SC2034
GATEWAY_STATE_FILE="$CLAUDE_GATEWAY_HOME/state.env"
# shellcheck disable=SC2034
GATEWAY_MASTER_KEY_FILE="$CLAUDE_GATEWAY_HOME/master.key"

# Resolve the repo even when this script is reached through the ~/.claude
# symlink farm, and even from a linked worktree.
gateway_repo_root() {
  local here
  here="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
  dirname "$here"
}

GATEWAY_REPO="${GATEWAY_REPO:-$(gateway_repo_root)}"
GATEWAY_CONFIG_DIR="${GATEWAY_CONFIG_DIR:-$GATEWAY_REPO/gateway}"
GATEWAY_MANIFEST="$GATEWAY_CONFIG_DIR/classes.manifest"

gateway_url() { echo "http://$GATEWAY_HOST:$GATEWAY_PORT"; }

# Pull provider keys into the environment. Each file is `export VAR=value`;
# sourcing is what the rest of the fleet already does with these.
gateway_load_secrets() {
  local f
  [ -d "$GATEWAY_SECRETS_DIR" ] || return 0
  for f in "$GATEWAY_SECRETS_DIR"/*.env; do
    [ -r "$f" ] || continue
    # shellcheck source=/dev/null
    . "$f"
  done
  return 0
}

# Emit the manifest's data rows: name|keys|fallbacks|probe
gateway_classes() {
  [ -r "$GATEWAY_MANIFEST" ] || return 1
  grep -v '^[[:space:]]*#' "$GATEWAY_MANIFEST" | grep -v '^[[:space:]]*$'
}

# Why a class cannot run, or empty if it can. Printed verbatim by the callers,
# so it has to name the thing to fix.
gateway_class_blocker() {
  local keys="$1" probe="$2" key
  for key in $keys; do
    if [ -z "${!key:-}" ]; then
      echo "\$$key is not set"
      return 0
    fi
  done
  if [ -n "$probe" ]; then
    if ! curl -fsS -m 3 -o /dev/null "$probe" 2>/dev/null; then
      echo "no server answering at $probe"
      return 0
    fi
  fi
  echo ""
}

gateway_pid() {
  local pid
  [ -r "$GATEWAY_PID_FILE" ] || return 1
  pid="$(cat "$GATEWAY_PID_FILE" 2>/dev/null)"
  case "$pid" in ''|*[!0-9]*) return 1 ;; esac
  # A recycled PID belonging to something else must not be reported as the
  # gateway, and must never be killed by gateway-down.
  grep -qa litellm "/proc/$pid/cmdline" 2>/dev/null || return 1
  echo "$pid"
}

gateway_is_up() { gateway_pid >/dev/null 2>&1; }

gateway_ready() {
  curl -fsS -m 3 -o /dev/null "$(gateway_url)/health/readiness" 2>/dev/null
}
