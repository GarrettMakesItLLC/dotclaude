#!/usr/bin/env bash
# dotclaude claude-accounts-report — SessionStart hook.
#
# THE PROBLEM THIS SOLVES
#   Three Claude Pro accounts, 4+ agents per machine, three machines, and no
#   endpoint that reports remaining subscription quota. The only signal a limit
#   exists is the error that announces it, and that error arrives by killing
#   whatever was running: one weekly limit took out six agents mid-edit, with no
#   warning and nothing written down.
#
#   bin/claude-accounts.sh is the ledger someone writes that observation into.
#   This hook is what makes the ledger worth keeping — it puts the state in
#   front of the session BEFORE it dispatches anything, so "account A is limited
#   until Sunday, B and C are clear" is a fact the session starts with rather
#   than one it discovers by dying.
#
# Deliberately silent when every account is clear. A banner on every session is
# a banner that gets ignored, and then disabled.
#
# Cost: one python3 run against a small local JSON file — no network, no git,
# no second interpreter start (which is why the CLI, not this hook, renders the
# SessionStart envelope). A session hook that costs seconds is a hook that gets
# turned off.
#
# ALWAYS exits 0. No ledger, no python3, a corrupt file, a slow disk — none of
# that is worth blocking a session over.
set -uo pipefail

HOOK_DIR="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
LEDGER_CLI="$(dirname "$HOOK_DIR")/bin/claude-accounts.sh"

[ -x "$LEDGER_CLI" ] || exit 0
command -v python3 >/dev/null 2>&1 || exit 0

# Prints nothing at all when no account has a live limit window.
timeout 5 "$LEDGER_CLI" report --hook-json 2>/dev/null || true

exit 0
