#!/usr/bin/env bash
# Self-test for claude-accounts-report.sh. Asserts: (a) silent when no account
# is limited, (b) a valid SessionStart envelope naming the limited account when
# one is, (c) always exits 0 — no ledger, no CLI, a corrupt ledger, a ledger
# with no accounts. Run:  bash hooks/claude-accounts-report.test.sh
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HOOK="$HERE/claude-accounts-report.sh"
CLI="$(dirname "$HERE")/bin/claude-accounts.sh"
fail=0

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

run_hook() { CLAUDE_ACCOUNTS_FILE="$1" "$HOOK" 2>/dev/null; }
rc_of() { CLAUDE_ACCOUNTS_FILE="$1" "$HOOK" >/dev/null 2>&1; echo $?; }

# --- No ledger at all -> silent, exit 0. ---
out="$(run_hook "$TMP/absent.json")"
[ -z "$out" ] || { echo "FAIL (no ledger): expected silence, got: $out"; fail=1; }
[ "$(rc_of "$TMP/absent.json")" = 0 ] || { echo "FAIL (no ledger): non-zero exit"; fail=1; }

# --- Accounts, none limited -> still silent. A banner every session is a
#     banner that gets disabled. ---
LEDGER="$TMP/ledger.json"
CLAUDE_ACCOUNTS_FILE="$LEDGER" "$CLI" add work-a >/dev/null
CLAUDE_ACCOUNTS_FILE="$LEDGER" "$CLI" add work-b >/dev/null
out="$(run_hook "$LEDGER")"
[ -z "$out" ] || { echo "FAIL (all clear): expected silence, got: $out"; fail=1; }

# --- One limited -> a parseable SessionStart envelope that names it. ---
CLAUDE_ACCOUNTS_FILE="$LEDGER" "$CLI" limit work-a --window weekly --until "+30 hours" >/dev/null
out="$(run_hook "$LEDGER")"
[ -n "$out" ] || { echo "FAIL (limited): expected output"; fail=1; }
echo "$out" | python3 -c '
import json, sys
doc = json.load(sys.stdin)
ctx = doc["hookSpecificOutput"]["additionalContext"]
assert doc["hookSpecificOutput"]["hookEventName"] == "SessionStart", doc
assert "work-a" in ctx and "limited" in ctx, ctx
assert "work-b" in ctx and "clear" in ctx, ctx
' || { echo "FAIL (limited): envelope did not carry the account state"; fail=1; }

# --- An expired window is over, not news. ---
CLAUDE_ACCOUNTS_FILE="$LEDGER" "$CLI" clear work-a >/dev/null
CLAUDE_ACCOUNTS_FILE="$LEDGER" "$CLI" limit work-a --window weekly --until "-1 hour" >/dev/null
out="$(run_hook "$LEDGER")"
[ -z "$out" ] || { echo "FAIL (expired limit): expected silence, got: $out"; fail=1; }

# --- A corrupt ledger must not block a session. ---
echo 'not json {{{' > "$TMP/corrupt.json"
[ "$(rc_of "$TMP/corrupt.json")" = 0 ] || { echo "FAIL (corrupt ledger): non-zero exit"; fail=1; }
out="$(run_hook "$TMP/corrupt.json")"
[ -z "$out" ] || { echo "FAIL (corrupt ledger): expected silence, got: $out"; fail=1; }

# --- The CLI being absent (a partial checkout) must fail open, not error. ---
FAKE="$TMP/fakehooks"; mkdir -p "$FAKE"
cp "$HOOK" "$FAKE/claude-accounts-report.sh"
rc=0; CLAUDE_ACCOUNTS_FILE="$LEDGER" "$FAKE/claude-accounts-report.sh" >/dev/null 2>&1 || rc=$?
[ "$rc" = 0 ] || { echo "FAIL (no CLI alongside): exit $rc"; fail=1; }

if [ "$fail" = 0 ]; then
  echo "claude-accounts-report: all cases passed"
fi
exit "$fail"
