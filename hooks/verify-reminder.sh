#!/usr/bin/env bash
# dotclaude verify-reminder — PreToolUse hook for the Bash tool and the
# github-rest MCP. Fires ONLY when an agent is about to open a pull request
# (`gh pr create`, or the `pr_create` MCP tool). On a match it injects a
# non-blocking reminder asking the agent to confirm it ran the verification
# relevant to its change (typecheck + affected tests) and to report the output.
#
# Why this exists: "Verify before claiming done" lives in CLAUDE.md as prose, so
# subagents follow it only probabilistically. This turns the rule into a
# deterministic nudge at the one handoff that matters — opening the PR.
#
# Why PR-create and NOT every push: pushes are constant (many parallel worktree
# agents commit/push all day); nudging each one is alarm fatigue and undoes the
# "fast hooks" standard. The PR is the infrequent, meaningful handoff. See
# GarrettMakesItLLC/dotclaude#7.
#
# Why non-blocking (additionalContext, exit 0) and NOT a block (exit 2): a
# stateless exit-2 would block the agent's verified retry identically and
# deadlock PR creation. This nudge runs NOTHING slow — it never invokes
# typecheck/test/build — so it fully respects the fast-hooks decision: the agent
# does the change-scoped check itself, the hook only reminds.
#
# Fail-open by design: no python3, or malformed JSON, or a tool we don't care
# about -> exit 0 silently and let the call through. This is a nudge, never a gate.

set -uo pipefail

input="$(cat)"

# No JSON parser -> fail open. python3 is ubiquitous on Linux/macOS.
if ! command -v python3 >/dev/null 2>&1; then
  exit 0
fi

# Pull tool_name and (for Bash) the command in one parse.
read -r tool_name cmd_present < <(printf '%s' "$input" | python3 -c 'import json,sys
try:
    d = json.load(sys.stdin)
except Exception:
    print(""); sys.exit(0)
name = d.get("tool_name", "") or ""
print(name, 1 if d.get("tool_input", {}).get("command") else 0)' 2>/dev/null)

[ -z "${tool_name:-}" ] && exit 0

nudge() {
  # Emit a non-blocking PreToolUse reminder. permissionDecision "allow" is
  # required by the schema; additionalContext is shown to the agent beside the
  # tool result. python3 builds the JSON so the message can't break quoting.
  python3 -c '
import json
msg = (
    "Verification check before this PR hands off (CLAUDE.md: \"Verify before you push or open a PR\"). "
    "Confirm you have run the checks relevant to your change on THIS branch'\''s current state and they pass:\n"
    "  - Always: typecheck + the tests affected by your change.\n"
    "  - Only if you touched build-affecting code (config, deps, codegen, bundler/routes): the build.\n"
    "If you have not run them yet, run them now and report the command output. "
    "If anything fails, fix it (or open the PR as a draft) before calling this done. "
    "Scope to your diff — this is a fast local check, not the full suite."
)
print(json.dumps({
    "hookSpecificOutput": {
        "hookEventName": "PreToolUse",
        "permissionDecision": "allow",
        "additionalContext": msg,
    }
}))'
  exit 0
}

case "$tool_name" in
  mcp__github-rest__pr_create)
    nudge
    ;;
  Bash)
    # Only the Bash tool carries a command; narrow to actual PR creation so we
    # don't fire on `gh pr view` / `gh pr list` / unrelated commands.
    [ "${cmd_present:-0}" = "1" ] || exit 0
    cmd="$(printf '%s' "$input" | python3 -c 'import json,sys
try:
    sys.stdout.write(json.load(sys.stdin).get("tool_input", {}).get("command", "") or "")
except Exception:
    pass' 2>/dev/null)"
    # Strip quoted spans first (like git-guard) so a `gh pr create` that only
    # appears inside a commit message / echo string can't trip a false nudge.
    cmd="$(printf '%s' "$cmd" | sed -E "s/'[^']*'/ /g; s/\"[^\"]*\"/ /g")"
    # Match `gh pr create` as its own command segment (start of string, or after
    # a separator / whitespace) so a substring like `foogh pr create` can't match.
    if printf '%s' "$cmd" | grep -Eq '(^|[;&|[:space:](])gh[[:space:]]+pr[[:space:]]+create([[:space:]]|$)'; then
      nudge
    fi
    ;;
esac

exit 0
