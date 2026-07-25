#!/usr/bin/env bash
# Self-test for verify-reminder.sh. Feeds PreToolUse payloads through the hook
# and asserts (a) it always exits 0 (it never blocks) and (b) the reminder is
# emitted only for PR-creation actions. Run locally or in CI:
#   bash hooks/verify-reminder.test.sh
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HOOK="$HERE/verify-reminder.sh"
fail=0

# Build the PreToolUse stdin JSON for a Bash command and run the hook.
# want=nudge|silent — whether additionalContext (the reminder) should appear.
check_bash() {
  local want="$1" cmd="$2" out code
  out="$(printf '%s' "$cmd" \
    | python3 -c 'import json,sys; print(json.dumps({"tool_name":"Bash","tool_input":{"command":sys.stdin.read()}}))' \
    | "$HOOK" 2>/dev/null)"
  code=$?
  assert "$want" "$code" "$out" "Bash: $cmd"
}

# Build the stdin JSON for an MCP tool call (no command field) and run the hook.
# The tool name is piped via stdin (not interpolated into the python source) so
# a name with a quote/backslash can't break the JSON the harness builds.
check_tool() {
  local want="$1" tool="$2" out code
  out="$(printf '%s' "$tool" \
    | python3 -c 'import json,sys; print(json.dumps({"tool_name": sys.stdin.read(), "tool_input": {}}))' \
    | "$HOOK" 2>/dev/null)"
  code=$?
  assert "$want" "$code" "$out" "tool: $tool"
}

assert() {
  local want="$1" code="$2" out="$3" label="$4"
  if [ "$code" != 0 ]; then
    echo "FAIL: hook must never block (exit 0), got $code for: $label"
    fail=1
    return
  fi
  if printf '%s' "$out" | grep -q "Verification check"; then
    [ "$want" = nudge ] || { echo "FAIL: unexpected reminder for: $label"; fail=1; }
  else
    [ "$want" = silent ] || { echo "FAIL: expected a reminder for: $label"; fail=1; }
  fi
}

# Should NUDGE — opening a PR.
check_bash nudge 'gh pr create --fill'
check_bash nudge 'gh pr create -t "feat: x" -b "body" --base main'
check_bash nudge 'git push origin HEAD && gh pr create --fill'
check_tool nudge 'mcp__github-rest__pr_create'

# --- issue linkage: pr_create nudge mentions issue linking ---
out="$(printf '%s' '{"tool_name":"mcp__github-rest__pr_create","tool_input":{}}' | "$HOOK")"
if printf '%s' "$out" | grep -q "Closes #"; then
  :
else
  echo "FAIL: pr_create nudge should mention 'Closes #'"
  fail=1
fi

# Should stay SILENT — not a PR-creation action.
check_bash silent 'gh pr view 7'
check_bash silent 'gh pr list'
check_bash silent 'gh pr checks'
check_bash silent 'git push origin feature/foo'
check_bash silent 'git commit -m "feat: open a pr later"'
# `gh pr create` only inside a quoted string must NOT nudge (quote-scrubbed).
check_bash silent 'git commit -m "todo: gh pr create later"'
check_bash silent 'echo "run gh pr create when ready"'
check_bash silent 'ls -la && echo done'
check_tool silent 'mcp__github-rest__pr_view'
check_tool silent 'mcp__github-rest__pr_list'

# --- follow-through: the nudge always demands every finding be accounted for ---
out="$(printf '%s' '{"tool_name":"mcp__github-rest__pr_create","tool_input":{}}' | "$HOOK")"
printf '%s' "$out" | grep -q "Finish what you find" \
  || { echo "FAIL: nudge should carry the Finish-what-you-find accounting"; fail=1; }

# --- deferred-work scan: markers this branch ADDS are named with file:line ---
# A throwaway repo so the assertion depends on nothing about the host checkout.
scan_repo="$(mktemp -d)"
(
  cd "$scan_repo" || exit 1
  git init -q -b main .
  git config user.email t@t; git config user.name t
  printf 'ok = 1  # TODO: pre-existing, must NOT be reported\n' > base.py
  git add -A && git commit -qm base
  git checkout -qb feature
  printf 'a = 1\nb = 2  # FIXME: added here\n' > added.py
  printf "it.skip('added here', () => {})\n" > added.test.js
  printf 'clean = 1\n' >> base.py
  git add -A && git commit -qm work
) >/dev/null 2>&1

scan_out="$(cd "$scan_repo" && printf '%s' '{"tool_name":"mcp__github-rest__pr_create","tool_input":{}}' | "$HOOK")"
scan_code=$?
[ "$scan_code" = 0 ] || { echo "FAIL: hook must exit 0 with a marker scan, got $scan_code"; fail=1; }
printf '%s' "$scan_out" | grep -q 'added.py:2' \
  || { echo "FAIL: scan should report the added FIXME as added.py:2"; fail=1; }
printf '%s' "$scan_out" | grep -q 'added.test.js:1' \
  || { echo "FAIL: scan should report the added .skip( as added.test.js:1"; fail=1; }
printf '%s' "$scan_out" | grep -q 'pre-existing' \
  && { echo "FAIL: scan must not report markers the base branch already carried"; fail=1; }

# A branch with no added markers gets the base nudge and no marker block.
clean_out="$(cd "$scan_repo" && git checkout -q main && printf '%s' '{"tool_name":"mcp__github-rest__pr_create","tool_input":{}}' | "$HOOK")"
printf '%s' "$clean_out" | grep -q "Verification check" \
  || { echo "FAIL: clean branch should still get the base nudge"; fail=1; }
printf '%s' "$clean_out" | grep -q "deferred-work markers" \
  && { echo "FAIL: clean branch should not get a marker block"; fail=1; }

# Outside a git repo the scan drops silently and the nudge still fires.
nogit_out="$(cd "$(mktemp -d)" && printf '%s' '{"tool_name":"mcp__github-rest__pr_create","tool_input":{}}' | "$HOOK")"
printf '%s' "$nogit_out" | grep -q "Verification check" \
  || { echo "FAIL: nudge must survive running outside a git repo"; fail=1; }

rm -rf "$scan_repo"

if [ "$fail" = 0 ]; then
  echo "verify-reminder: all cases passed"
fi
exit "$fail"
