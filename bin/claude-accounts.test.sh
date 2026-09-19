#!/usr/bin/env bash
# Self-test for bin/claude-accounts.sh — the subscription-account ledger.
#
# The properties that matter: a recorded limit survives a round trip and is
# reported with its reset time; an EXPIRED window reads as clear without being
# hand-cleared; `suggest` never recommends a limited account while a clear one
# exists; and every command refuses a label it does not know rather than
# inventing one. Run:  bash bin/claude-accounts.test.sh
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CLI="$HERE/claude-accounts.sh"
fail=0

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
export CLAUDE_ACCOUNTS_FILE="$TMP/accounts.json"
export CLAUDE_MACHINE="test-box"
export CLAUDE_SESSION_LABEL="test-session"

check() { # check <description> <expected-substring> <actual>
  case "$3" in *"$2"*) return 0 ;; esac
  echo "FAIL ($1): expected to find '$2' in:"; echo "$3" | sed 's/^/    /'; fail=1
}

# --- init seeds placeholders, and is idempotent. ---
out="$("$CLI" init)"
check "init" "seeded 3 placeholder accounts" "$out"
out="$("$CLI" init)"
check "init twice" "already has 3 account(s)" "$out"

# --- A fresh ledger says nothing at session start. ---
out="$("$CLI" report)"
[ -z "$out" ] || { echo "FAIL (report, nothing limited): expected silence, got: $out"; fail=1; }

# --- add / rm. ---
"$CLI" add work-a --email a@example.com --note primary >/dev/null
"$CLI" rm account-a >/dev/null; "$CLI" rm account-b >/dev/null; "$CLI" rm account-c >/dev/null
"$CLI" add work-b >/dev/null
out="$("$CLI" list)"
check "list" "work-a" "$out"
check "list carries the note" "primary" "$out"
case "$out" in *account-a*) echo "FAIL (rm): account-a survived removal"; fail=1 ;; esac

# --- rm/claim/limit on an unknown label must fail, not create one. ---
rc=0; "$CLI" rm nope >/dev/null 2>&1 || rc=$?
[ "$rc" != 0 ] || { echo "FAIL (rm unknown): exited 0"; fail=1; }
rc=0; "$CLI" limit nope --until "+1 hour" >/dev/null 2>&1 || rc=$?
[ "$rc" != 0 ] || { echo "FAIL (limit unknown): exited 0"; fail=1; }
rc=0; "$CLI" claim nope >/dev/null 2>&1 || rc=$?
[ "$rc" != 0 ] || { echo "FAIL (claim unknown): exited 0"; fail=1; }

# --- `limit` without --until is refused: a limit with no reset time is the
#     thing this whole ledger exists to stop guessing at. ---
rc=0; "$CLI" limit work-a >/dev/null 2>&1 || rc=$?
[ "$rc" != 0 ] || { echo "FAIL (limit with no --until): exited 0"; fail=1; }
rc=0; "$CLI" limit work-a --until "no such time" >/dev/null 2>&1 || rc=$?
[ "$rc" != 0 ] || { echo "FAIL (limit with unparseable --until): exited 0"; fail=1; }

# --- claim is recorded against this machine and session. ---
out="$("$CLI" claim work-a)"
check "claim" "claimed by test-box/test-session" "$out"
check "claim shows in list" "test-box/test-session" "$("$CLI" list)"

# --- A recorded limit round-trips, and names the other clear accounts. ---
out="$("$CLI" limit work-a --window weekly --until "+40 hours")"
check "limit" "weekly-limited until" "$out"
check "limit names alternatives" "clear right now: work-b" "$out"
check "limit shows in list" "weekly limit" "$("$CLI" list)"

# --- suggest prefers a clear, unheld account. ---
check "suggest" "work-b" "$("$CLI" suggest)"

# --- report names both sides. ---
out="$("$CLI" report)"
check "report names the limited account" "work-a is limited until" "$out"
check "report names the clear account" "work-b" "$out"

# --- --hook-json emits a SessionStart envelope carrying the same message. ---
"$CLI" report --hook-json | python3 -c '
import json, sys
doc = json.load(sys.stdin)
assert doc["hookSpecificOutput"]["hookEventName"] == "SessionStart", doc
assert "work-a" in doc["hookSpecificOutput"]["additionalContext"], doc
' || { echo "FAIL (report --hook-json): bad envelope"; fail=1; }

# --- Every account limited: say so, and say when the first one frees up. ---
"$CLI" limit work-b --window 5h --until "+2 hours" >/dev/null
check "suggest, all limited" "none are clear" "$("$CLI" suggest)"
check "suggest names the soonest" "work-b" "$("$CLI" suggest)"
check "report, all limited" "Every account is limited" "$("$CLI" report)"

# --- An EXPIRED window reads as clear with no manual clear. This is the case
#     that decides whether the ledger is worth keeping: a stale entry that
#     still reads as "limited" trains everyone to ignore the banner. ---
"$CLI" clear work-b >/dev/null
"$CLI" limit work-b --window 5h --until "-1 hour" >/dev/null
out="$("$CLI" list)"
grep -q '^work-b .*clear' <<<"$out" || { echo "FAIL (expired window): work-b should read clear:"; echo "$out"; fail=1; }
check "suggest ignores an expired window" "work-b" "$("$CLI" suggest)"

# --- clear and release. ---
"$CLI" clear work-a >/dev/null
"$CLI" release work-a >/dev/null
out="$("$CLI" list)"
grep -q '^work-a .*clear .*-' <<<"$out" || { echo "FAIL (clear/release):"; echo "$out"; fail=1; }

# --- The ledger is 0600: it names accounts and which box is on which. ---
mode="$(stat -c %a "$CLAUDE_ACCOUNTS_FILE" 2>/dev/null || stat -f %Lp "$CLAUDE_ACCOUNTS_FILE")"
[ "$mode" = "600" ] || { echo "FAIL (permissions): ledger is $mode, want 600"; fail=1; }

# --- A corrupt ledger is replaced, not crashed on. ---
echo 'garbage{{{' > "$CLAUDE_ACCOUNTS_FILE"
rc=0; "$CLI" list >/dev/null 2>&1 || rc=$?
[ "$rc" = 0 ] || { echo "FAIL (corrupt ledger): list exited $rc"; fail=1; }

# --- Unknown command / unknown flag are refused. ---
rc=0; "$CLI" frobnicate >/dev/null 2>&1 || rc=$?
[ "$rc" = 2 ] || { echo "FAIL (unknown command): exit $rc, want 2"; fail=1; }
rc=0; "$CLI" report --nonsense >/dev/null 2>&1 || rc=$?
[ "$rc" = 2 ] || { echo "FAIL (unknown flag): exit $rc, want 2"; fail=1; }

if [ "$fail" = 0 ]; then
  echo "claude-accounts: all cases passed"
fi
exit "$fail"
