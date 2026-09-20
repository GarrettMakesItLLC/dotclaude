#!/usr/bin/env bash
# dotclaude fleet-mode-report — SessionStart hook.
#
# THE PROBLEM THIS SOLVES
#   `skills/operating-a-fleet` has two modes, and which one a repo is in decides
#   what authorizes a merge. Until now the only way a machine learned that was a
#   human saying so — so a session could spend an hour producing work for a gate
#   that had been refusing jobs since before it started, and read an empty check
#   list as a green one.
#
#   This puts the answer in front of the session BEFORE it opens anything, for
#   the repo the session is actually in, and tells it what to DO rather than
#   only what the state is.
#
# Deliberately silent when CI is healthy and no degraded mode is declared. A
# banner on every session is a banner that gets ignored, and then disabled.
#
# Cost: a cache read (one small file, one python3 start — tens of milliseconds).
# The bounded `gh api` probe behind it runs at most once per repo per hard TTL,
# and a soft-stale cache is served immediately while a detached refresh updates
# it for the next session. Nothing here ever waits on the network in the steady
# state.
#
# ALWAYS exits 0. No CLI, no python3, no gh, no network, a corrupt cache — none
# of that is worth blocking a session over.
set -uo pipefail

HOOK_DIR="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
CLI="$(dirname "$HOOK_DIR")/bin/fleet-mode.sh"

[ -x "$CLI" ] || exit 0
command -v python3 >/dev/null 2>&1 || exit 0

# The repo the session is in. CLAUDE_PROJECT_DIR is what the harness sets; PWD
# is the fallback, and the CLI resolves the GitHub slug from that directory's
# own origin remote, so a worktree answers for its repo rather than for this one.
timeout 12 "$CLI" report --dir "${CLAUDE_PROJECT_DIR:-$PWD}" --hook-json 2>/dev/null || true

exit 0
