#!/usr/bin/env bash
# dotclaude git-guard — PreToolUse hook for the Bash tool.
#
# Turns the non-negotiable git rules in ~/dotclaude/CLAUDE.md from prose that
# Claude follows probabilistically into hard, deterministic blocks. Wired in
# settings.json under hooks.PreToolUse (matcher "Bash"). On a policy hit it
# exits 2, which blocks the command and feeds stderr back to Claude.
#
# This matters most because settings.json runs defaultMode "bypassPermissions":
# without a hook there is no other gate between Claude and the shell.
#
# Fail-open by design: if the input can't be parsed (no python3, malformed
# JSON), we exit 0 and let the command through. A guard that bricks every Bash
# call is far worse than one that occasionally misses — it is a backstop, not
# the only safety boundary (project-level gitleaks/pre-commit still apply).

set -uo pipefail

input="$(cat)"

# Extract tool_input.command. jq is NOT guaranteed on every machine, so parse
# with python3 (ubiquitous on Linux/macOS). No parser -> fail open.
if ! command -v python3 >/dev/null 2>&1; then
  exit 0
fi
cmd="$(printf '%s' "$input" | python3 -c 'import json,sys
try:
    sys.stdout.write(json.load(sys.stdin).get("tool_input", {}).get("command", "") or "")
except Exception:
    pass' 2>/dev/null)"

[ -z "$cmd" ] && exit 0

block() {
  echo "⛔ dotclaude git-guard blocked this command." >&2
  echo "Reason: $1" >&2
  echo "Policy: ~/dotclaude/CLAUDE.md. False positive? Run it yourself with the ! prefix, or edit hooks/git-guard.sh." >&2
  exit 2
}

# Only inspect git invocations.
printf '%s' "$cmd" | grep -Eq '(^|[^[:alnum:]_./-])git([[:space:]]|$)' || exit 0

# 1) Never bypass git hooks (--no-verify, or -n on commit/push).
if printf '%s' "$cmd" | grep -Eq -- '--no-verify'; then
  block "git --no-verify is forbidden. Fix the failing hook (gitleaks/lint/typecheck) and commit normally — then make a NEW commit."
fi
# (push -n is --dry-run, harmless — only commit's -n means --no-verify.)
if printf '%s' "$cmd" | grep -Eq 'git[[:space:]]+commit([[:space:]]|$)' \
   && printf '%s' "$cmd" | grep -Eq '[[:space:]]-[a-zA-Z]*n[a-zA-Z]*([[:space:]]|$)'; then
  block "git commit -n bypasses hooks (short for --no-verify). Forbidden — fix the hook and retry."
fi

# 2) Force-push to main/master is the user's call, never Claude's.
if printf '%s' "$cmd" | grep -Eq 'git[[:space:]].*push' \
   && printf '%s' "$cmd" | grep -Eq -- '(--force([[:space:]=]|$)|--force-with-lease|[[:space:]]-f([[:space:]]|$))'; then
  if printf '%s' "$cmd" | grep -Eq '([[:space:]:]|origin[[:space:]]+)(main|master)([[:space:]:]|$)'; then
    block "force-pushing to main/master is reserved for the user (CLAUDE.md). Push a feature branch, or ask first."
  fi
fi

# 3) Never stage/commit a real .env file (.env.example is fine). Catches
# explicit .env references; blanket 'git add -A' that sweeps a .env is left to
# project-level gitleaks/pre-commit, which this does not replace.
if printf '%s' "$cmd" | grep -Eq 'git[[:space:]]+(add|commit|stage|rm)([[:space:]]|$)'; then
  if printf '%s' "$cmd" | grep -Eq '(^|[[:space:]/=])\.env([[:space:]]|$)' \
     || printf '%s' "$cmd" | grep -Eq '\.env\.(local|production|prod|development|dev|staging)'; then
    block ".env files must never be committed — only .env.example is tracked (CLAUDE.md). Use 'vercel env pull' for local values."
  fi
fi

exit 0
