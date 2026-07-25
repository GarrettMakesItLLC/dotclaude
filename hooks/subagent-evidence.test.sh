#!/usr/bin/env bash
# Self-test for subagent-evidence.sh. Feeds SubagentStop payloads through the hook
# and asserts (a) it always exits 0 and (b) it blocks exactly on the two-sided
# signal: the report claims completed work AND shows no command output. Run
# locally or in CI:
#   bash hooks/subagent-evidence.test.sh
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HOOK="$HERE/subagent-evidence.sh"
fail=0

# want=block|pass. The report travels via stdin so quotes/backslashes in it can
# never break the JSON the harness builds.
check() {
  local want="$1" agent="$2" active="$3" report="$4" out code
  out="$(printf '%s' "$report" | AGENT="$agent" ACTIVE="$active" python3 -c '
import json, os, sys
print(json.dumps({
    "hook_event_name": "SubagentStop",
    "stop_hook_active": os.environ["ACTIVE"] == "1",
    "agent_type": os.environ["AGENT"],
    "last_assistant_message": sys.stdin.read(),
}))' | "$HOOK" 2>/dev/null)"
  code=$?
  if [ "$code" != 0 ]; then
    echo "FAIL: hook must always exit 0, got $code for: $report"
    fail=1
    return
  fi
  if printf '%s' "$out" | grep -q '"decision": "block"'; then
    [ "$want" = block ] || { echo "FAIL: unexpected block for: $report"; fail=1; }
  else
    [ "$want" = pass ] || { echo "FAIL: expected a block for: $report"; fail=1; }
  fi
}

# --- BLOCK: claims completed work, no command output anywhere ---
check block general-purpose 0 'Implemented the retry logic in client.ts. Everything is working.'
check block general-purpose 0 'Fixed the null deref and updated the caller. Done.'
check block '' 0 'Added the migration and wired up the new column.'

# --- PASS: claims work AND shows evidence ---
check pass general-purpose 0 'Implemented the retry logic. Ran `pnpm test` — 14 passed, 0 failed.'
check pass general-purpose 0 'Fixed the null deref. tsc: 0 errors. vitest: all suites passing.'
check pass general-purpose 0 'Added the parser. $ npm run typecheck  ✓ no issues found'
check pass general-purpose 0 'Refactored the module; bash hooks/git-guard.test.sh reports all cases passed.'

# --- PASS: no claim of completed work (research / investigation reports) ---
check pass general-purpose 0 'The bug originates in src/auth.ts:42 where the token is compared by reference.'
check pass general-purpose 0 'Three candidate approaches, with tradeoffs for each. I recommend the second.'
# Plans are proposals, not completion claims.
check pass general-purpose 0 'I will add a guard clause and should fix the caller next.'

# --- PASS: the subagent pre-empted the block by stating it had nothing to run ---
check pass general-purpose 0 'Updated the README — docs only, nothing to run.'
check pass general-purpose 0 'Added the architecture section. Documentation-only change, no tests to run.'
# ...but an unqualified docs claim still blocks: the hook cannot tell it from code.
check block general-purpose 0 'Updated the README with the new architecture section.'

# --- PASS: read-only agent types are exempt even when they claim work ---
check pass Explore 0 'Implemented nothing; found the caller and updated my understanding.'
check pass Plan 0 'Created the plan. Added five steps.'

# --- PASS: the retry must never be blocked a second time (no loop) ---
check pass general-purpose 1 'Implemented the retry logic in client.ts. Everything is working.'

# --- PASS: nothing to judge ---
check pass general-purpose 0 ''
check pass general-purpose 0 '   '

# --- The block reason has to tell the subagent what to do about it ---
blocked="$(printf '%s' 'Implemented the feature. Done.' | python3 -c '
import json, sys
print(json.dumps({"hook_event_name":"SubagentStop","stop_hook_active":False,
                  "agent_type":"general-purpose","last_assistant_message":sys.stdin.read()}))' | "$HOOK")"
printf '%s' "$blocked" | grep -q 'do not fabricate' \
  || { echo "FAIL: block reason must forbid fabricating output"; fail=1; }
printf '%s' "$blocked" | grep -q 'nothing to run' \
  || { echo "FAIL: block reason must offer the legitimate no-checks escape"; fail=1; }

# --- Other events and malformed input pass through silently ---
for payload in \
  '{"hook_event_name":"Stop","last_assistant_message":"Implemented it. Done."}' \
  '{"hook_event_name":"PreToolUse","tool_name":"Bash"}' \
  'not json at all' \
  '{}' ; do
  out="$(printf '%s' "$payload" | "$HOOK" 2>/dev/null)"; code=$?
  [ "$code" = 0 ] || { echo "FAIL: must exit 0 for: $payload"; fail=1; }
  [ -z "$out" ] || { echo "FAIL: must stay silent for: $payload"; fail=1; }
done

if [ "$fail" = 0 ]; then
  echo "subagent-evidence: all cases passed"
fi
exit "$fail"
