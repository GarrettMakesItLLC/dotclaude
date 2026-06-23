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
# git push to a feature branch, a commit message that mentions "--no-verify");
# only block the genuinely dangerous shape.

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

# Scrub commit/-m message bodies so their prose can't trip flag/path checks
# (e.g. a commit message that literally says "--no-verify" or "rm -rf /").
# Chained commands outside the message are preserved and still inspected.
scrubbed="$(printf '%s' "$cmd" | sed -E "s/(-m|--message)[[:space:]]*(\"[^\"]*\"|'[^']*'|=[^[:space:]]*)/\1/g")"

block() {
  echo "BLOCKED by dotclaude guard: $1" >&2
  echo "(This is a hard safety rule. If it's genuinely intended, ask Garrett to run it.)" >&2
  exit 2
}

# 1. --no-verify bypasses git hooks (gitleaks, lint-staged, typecheck).
#    -n means --no-verify on commit, but --dry-run on push, so only treat
#    -n as a violation for commit.
if printf '%s' "$scrubbed" | grep -Eq 'git[[:space:]].*commit.*([[:space:]]--no-verify([[:space:]]|=|$)|[[:space:]]-[a-z]*n[a-z]*([[:space:]]|$))' \
   || printf '%s' "$scrubbed" | grep -Eq 'git[[:space:]].*push.*--no-verify'; then
  block "git commit/push with --no-verify skips pre-commit hooks. Fix the underlying lint/type/secret failure instead."
fi

# 2. Staging or committing a real .env file (.env.example is always fine).
#    Drop any .env.example mention first, so it can't excuse a sibling real
#    .env file staged in the same command (git add .env.local .env.example).
if printf '%s' "$scrubbed" | grep -Eq 'git[[:space:]]+(add|commit)'; then
  cleaned="$(printf '%s' "$scrubbed" | sed 's/\.env\.example//g')"
  if printf '%s' "$cleaned" | grep -Eq '(^|[[:space:]/])\.env([[:space:]]|$|\.[^[:space:]/]*)'; then
    block ".env must never be committed — only .env.example is tracked. Use 'vercel env pull' for local values."
  fi
fi

# 3. Force-push to a protected branch (main/master).
if printf '%s' "$scrubbed" | grep -Eq 'git[[:space:]]+push' \
   && printf '%s' "$scrubbed" | grep -Eq '(--force([[:space:]=]|$)|--force-with-lease|[[:space:]]-f([[:space:]]|$))' \
   && printf '%s' "$scrubbed" | grep -Eq '(^|[[:space:]/])(main|master)([[:space:]]|$|:)'; then
  block "force-push to main/master is destructive and owner-only. Push to a feature branch and open a PR."
fi

# 4. Reckless recursive delete of a root / home / system / parent path.
#    Requires a recursive flag (cluster containing r). Allowed by design:
#    relative paths (node_modules, dist, .worktrees/x), /tmp/..., and deeper
#    project paths — only root/home/system/parent roots are blocked.
if printf '%s' "$scrubbed" | grep -Eq 'rm[[:space:]]+-[a-zA-Z]*r[a-zA-Z]*[[:space:]]+(-[a-zA-Z]+[[:space:]]+)*((/|~|\$HOME)([[:space:]]|$|\*)|(~|\$HOME)/|/(home|root|usr|etc|var|bin|sbin|lib|lib64|opt|boot|sys|proc|dev|Users)([[:space:]]|$|/)|\.\.([[:space:]]|$|/))'; then
  block "recursive delete targeting a root / home / system / parent path. Delete specific project subpaths (relative, or under /tmp) explicitly instead."
fi

exit 0
