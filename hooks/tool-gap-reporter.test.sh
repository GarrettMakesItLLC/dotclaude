#!/usr/bin/env bash
# Self-test for tool-gap-reporter.sh. Drives the hook with canned PostToolUse
# payloads against a throwaway state dir, and asserts (a) it never blocks,
# (b) it stays silent on a first failure, a success, a non-MCP tool, and a result
# that merely mentions an error, and (c) it fires exactly once on the second
# failure of the same MCP tool. Run locally or in CI:
#   bash hooks/tool-gap-reporter.test.sh
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HOOK="$HERE/tool-gap-reporter.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
export TOOL_GAP_STATE_DIR="$TMP/state"
fail=0

# event, tool, response-json, [session]
payload() {
  python3 -c '
import json, sys
print(json.dumps({
    "hook_event_name": sys.argv[1],
    "tool_name": sys.argv[2],
    "tool_response": json.loads(sys.argv[3]),
    "session_id": sys.argv[4],
}))' "$1" "$2" "$3" "${4:-s1}"
}

# want: "quiet" | "fires"; then the payload args
run() {
  local want="$1"; shift
  local out code
  out="$(payload "$@" | "$HOOK" 2>/dev/null)"; code=$?
  if [ "$code" != 0 ]; then
    echo "FAIL: hook must always exit 0, got $code for $2"
    fail=1
  fi
  case "$want" in
    quiet)
      [ -z "$out" ] || { echo "FAIL: expected silence for $2, got: $out"; fail=1; } ;;
    fires)
      printf '%s' "$out" | grep -q '"hookEventName": "PostToolUse"' \
        || { echo "FAIL: expected a PostToolUse payload for $2, got: $out"; fail=1; }
      printf '%s' "$out" | grep -q "$2" \
        || { echo "FAIL: report should name the failing tool $2"; fail=1; }
      printf '%s' "$out" | grep -q 'dotclaude' \
        || { echo "FAIL: report should name where to file"; fail=1; } ;;
  esac
}

ERR='{"isError": true, "content": [{"type": "text", "text": "MCP error -32602: no such tool"}]}'
OK='{"content": [{"type": "text", "text": "{\"ok\": true}"}]}'
# A successful result whose TEXT talks about errors — the false positive to avoid.
CHATTY_OK='{"content": [{"type": "text", "text": "Error: budget exceeded (from the log I fetched)"}]}'

# --- first failure: counted, silent (one error is usually the caller's)
run quiet PostToolUse mcp__plugin_supabase_supabase__list_tables "$ERR"

# --- second failure of the same tool: fires once...
run fires PostToolUse mcp__plugin_supabase_supabase__list_tables "$ERR"
# ...and then stays quiet, because the point is one issue per gap
run quiet PostToolUse mcp__plugin_supabase_supabase__list_tables "$ERR"
run quiet PostToolUse mcp__plugin_supabase_supabase__list_tables "$ERR"

# --- a different tool has its own count, and a different session starts fresh
run quiet PostToolUse mcp__github-rest__issue_open "$ERR"
run quiet PostToolUse mcp__plugin_supabase_supabase__list_tables "$ERR" s2

# --- successes never count, however many
for _ in 1 2 3; do
  run quiet PostToolUse mcp__plugin_vercel_vercel__list_projects "$OK"
done
run quiet PostToolUse mcp__plugin_vercel_vercel__list_projects "$CHATTY_OK"
run quiet PostToolUse mcp__plugin_vercel_vercel__list_projects "$CHATTY_OK"

# --- non-MCP tools are ordinary work going wrong, not a missing capability
run quiet PostToolUse Bash "$ERR"
run quiet PostToolUse Bash "$ERR"
run quiet PostToolUse Edit "$ERR"
run quiet PostToolUse Edit "$ERR"

# --- a different hook event is not ours
run quiet PreToolUse mcp__github-rest__issue_open "$ERR"
run quiet PreToolUse mcp__github-rest__issue_open "$ERR"

# --- a bare error string is still a failure (the second one fires)
run quiet PostToolUse mcp__claude_ai_Notion__notion-fetch '"MCP error -32603: upstream"'
run fires PostToolUse mcp__claude_ai_Notion__notion-fetch '"MCP error -32603: upstream"'

# --- malformed input and a missing state dir must never break a turn
out="$(printf 'not json' | "$HOOK" 2>/dev/null)"; code=$?
[ "$code" = 0 ] && [ -z "$out" ] || { echo "FAIL: malformed input must exit 0 silently"; fail=1; }
for _ in 1 2; do
  out="$(payload PostToolUse mcp__github-rest__branch_list "$ERR" \
    | TOOL_GAP_STATE_DIR="/dev/null/not-a-dir" "$HOOK" 2>/dev/null)"; code=$?
  [ "$code" = 0 ] && [ -z "$out" ] || { echo "FAIL: unusable state dir must exit 0 silently"; fail=1; }
done

if [ "$fail" = 0 ]; then
  echo "tool-gap-reporter: all cases passed"
fi
exit "$fail"
