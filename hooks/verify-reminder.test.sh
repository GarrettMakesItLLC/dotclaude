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
check_tool() {
  local want="$1" tool="$2" out code
  out="$(python3 -c "import json; print(json.dumps({'tool_name': '$tool', 'tool_input': {}}))" \
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

# Should stay SILENT — not a PR-creation action.
check_bash silent 'gh pr view 7'
check_bash silent 'gh pr list'
check_bash silent 'gh pr checks'
check_bash silent 'git push origin feature/foo'
check_bash silent 'git commit -m "feat: open a pr later"'
check_bash silent 'ls -la && echo done'
check_tool silent 'mcp__github-rest__pr_view'
check_tool silent 'mcp__github-rest__pr_list'

if [ "$fail" = 0 ]; then
  echo "verify-reminder: all cases passed"
fi
exit "$fail"
