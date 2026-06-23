#!/usr/bin/env bash
# PreToolUse(Bash) safety guard for Claude Code.
#
# Reads the hook JSON on stdin, inspects the proposed shell command, and
# BLOCKS (exit 2) anything that violates a hard safety rule. stderr is shown
# to the agent so it understands why and can correct course.
#
# WHY THIS EXISTS: settings.json runs in `bypassPermissions` mode, where the
# allow/deny permission system is skipped entirely. Hooks still fire in that
# mode — so this script, not the permission list, is the real guardrail.
#
# Design goals: zero false positives on everyday commands (rm -rf node_modules,
# git push to a feature branch, etc.); only block the genuinely dangerous shape.

set -uo pipefail

input="$(cat)"

# Extract the proposed command. Prefer a real JSON parser (jq, then python3);
# fall back to a sed extractor only if neither is installed.
if command -v jq >/dev/null 2>&1; then
  cmd="$(printf '%s' "$input" | jq -r '.tool_input.command // empty')"
elif command -v python3 >/dev/null 2>&1; then
  cmd="$(printf '%s' "$input" | python3 -c 'import sys,json
try: print(json.load(sys.stdin).get("tool_input",{}).get("command","") or "")
except Exception: pass' 2>/dev/null)"
else
  cmd="$(printf '%s' "$input" | sed -n 's/.*"command"[[:space:]]*:[[:space:]]*"\(.*\)".*/\1/p')"
fi

# Nothing to inspect → allow.
[ -z "${cmd:-}" ] && exit 0

block() {
  echo "BLOCKED by dotclaude guard: $1" >&2
  echo "(This is a hard safety rule. If it's genuinely intended, ask Garrett to run it.)" >&2
  exit 2
}

# 1. --no-verify bypasses git hooks (gitleaks, lint-staged, typecheck).
#    -n means --no-verify on commit, but --dry-run on push, so only treat
#    -n as a violation for commit.
if printf '%s' "$cmd" | grep -Eq 'git[[:space:]].*commit.*([[:space:]]--no-verify([[:space:]]|=|$)|[[:space:]]-[a-z]*n[a-z]*([[:space:]]|$))' \
   || printf '%s' "$cmd" | grep -Eq 'git[[:space:]].*push.*--no-verify'; then
  block "git commit/push with --no-verify skips pre-commit hooks. Fix the underlying lint/type/secret failure instead."
fi

# 2. Staging or committing a real .env file (.env.example is always fine).
if printf '%s' "$cmd" | grep -Eq 'git[[:space:]]+(add|commit)'; then
  if printf '%s' "$cmd" | grep -Eq '(^|[[:space:]/])\.env([[:space:]]|$|\.local|\.production|\.development)' \
     && ! printf '%s' "$cmd" | grep -Eq '\.env\.example'; then
    block ".env must never be committed — only .env.example is tracked. Use 'vercel env pull' for local values."
  fi
fi

# 3. Force-push to a protected branch (main/master).
if printf '%s' "$cmd" | grep -Eq 'git[[:space:]]+push' \
   && printf '%s' "$cmd" | grep -Eq '(--force([[:space:]=]|$)|--force-with-lease|[[:space:]]-f([[:space:]]|$))' \
   && printf '%s' "$cmd" | grep -Eq '(^|[[:space:]/])(main|master)([[:space:]]|$|:)'; then
  block "force-push to main/master is destructive and owner-only. Push to a feature branch and open a PR."
fi

# 4. Reckless recursive force-delete of a root / home / parent path.
#    Narrow on purpose: rm -rf node_modules / .worktrees/x / build are allowed.
if printf '%s' "$cmd" | grep -Eq 'rm[[:space:]]+-[a-zA-Z]*[rf][a-zA-Z]*[[:space:]]' \
   && printf '%s' "$cmd" | grep -Eq 'rm[[:space:]]+-[a-zA-Z]+[[:space:]]+(/|~|\$HOME|/\*|\.\.|/[A-Za-z._-]+)([[:space:]]|/?\*?$)'; then
  block "recursive force-delete targeting a root/home/parent path. Delete specific subpaths explicitly instead."
fi

exit 0
