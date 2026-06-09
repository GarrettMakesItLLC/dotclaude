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
#
# KNOWN GAPS (by design — this is a backstop, not a sandbox; don't expand into a
# regex arms race):
#   - Env-var hook bypasses: `HUSKY=0 git commit`, or core.hooksPath set via
#     GIT_CONFIG_* env vars rather than `-c`. Same class as --no-verify.
#   - `git add -A` / `git add .` that sweeps an unmentioned .env — left to
#     project gitleaks/pre-commit.
#   - Anything non-git (rm -rf, curl | sh, writes outside the repo) — entirely
#     out of scope; bypassPermissions does not gate those either.

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

# Strip quoted spans ('...' and "...") before matching so a commit MESSAGE that
# merely mentions --no-verify / .env / main can't trip the guards. Flags and
# paths that actually matter are unquoted; only message/-m bodies are quoted.
# (Trade-off: a deliberately quoted branch name could slip a force-push past —
# acceptable, since this is a backstop and quoted branch names are rare while
# quoted messages are universal.)
scrubbed="$(printf '%s' "$cmd" | sed -E "s/'[^']*'/ /g; s/\"[^\"]*\"/ /g")"

# Only inspect git invocations.
printf '%s' "$scrubbed" | grep -Eq '(^|[^[:alnum:]_./-])git([[:space:]]|$)' || exit 0

# 1) Never bypass git hooks: --no-verify, commit -n, or -c core.hooksPath=...
if printf '%s' "$scrubbed" | grep -Eq -- '--no-verify'; then
  block "git --no-verify is forbidden. Fix the failing hook (gitleaks/lint/typecheck) and commit normally — then make a NEW commit."
fi
if printf '%s' "$scrubbed" | grep -Eiq -- '-c[[:space:]=]*core\.hookspath'; then
  block "git -c core.hooksPath=... disables hooks (same effect as --no-verify). Forbidden — fix the hook and retry."
fi
# (push -n is --dry-run, harmless — only commit's -n means --no-verify.)
if printf '%s' "$scrubbed" | grep -Eq 'git[[:space:]]+commit([[:space:]]|$)' \
   && printf '%s' "$scrubbed" | grep -Eq '[[:space:]]-[a-zA-Z]*n[a-zA-Z]*([[:space:]]|$)'; then
  block "git commit -n bypasses hooks (short for --no-verify). Forbidden — fix the hook and retry."
fi

# 2) Force-push to main/master is the user's call, never Claude's. Covers
# --force / -f / --force-with-lease AND the leading-'+' refspec force form, and
# matches main/master written bare, as origin main, refs/heads/main, or :main.
if printf '%s' "$scrubbed" | grep -Eq 'git[[:space:]].*push'; then
  has_force=0
  printf '%s' "$scrubbed" | grep -Eq -- '(--force([[:space:]=]|$)|--force-with-lease|[[:space:]]-f([[:space:]]|$))' && has_force=1
  printf '%s' "$scrubbed" | grep -Eq '[[:space:]]\+[^[:space:]]*(main|master)' && has_force=1
  if [ "$has_force" = 1 ] \
     && printf '%s' "$scrubbed" | grep -Eq '([[:space:]:/+]|origin[[:space:]]+)(main|master)([[:space:]:]|$)'; then
    block "force-pushing to main/master is reserved for the user (CLAUDE.md). Push a feature branch, or ask first."
  fi
fi

# 3) Never stage/commit a real .env file (.env.example is fine). Catches
# explicit .env references; blanket 'git add -A' that sweeps a .env is left to
# project-level gitleaks/pre-commit, which this does not replace.
if printf '%s' "$scrubbed" | grep -Eq 'git[[:space:]]+(add|commit|stage|rm)([[:space:]]|$)'; then
  if printf '%s' "$scrubbed" | grep -Eq '(^|[[:space:]/=])\.env([[:space:]]|$)' \
     || printf '%s' "$scrubbed" | grep -Eq '\.env\.(local|production|prod|development|dev|staging)'; then
    block ".env files must never be committed — only .env.example is tracked (CLAUDE.md). Use 'vercel env pull' for local values."
  fi
fi

exit 0
