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
#   - Other non-git footguns (curl | sh, writes outside the repo) — out of
#     scope; bypassPermissions does not gate those either. (Reckless `rm -rf` of
#     root/home/system/parent paths IS blocked below — the one non-git rule.)
#   - `rm -rf *` / `rm -rf .` whose danger depends on the current directory
#     (e.g. `cd / && rm -rf *`) — we can't know CWD, so a bare glob/dot is not
#     blocked. Only explicit dangerous path arguments are.

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

# Strip message bodies before matching so a commit MESSAGE that merely mentions
# --no-verify / .env / main can't trip the guards. Flags and paths that actually
# matter live outside them.
#
# Two carriers, both scrubbed:
#   - quoted spans ('...' and "..."), which carry a `-m` message;
#   - heredoc bodies (`git commit -F - <<'EOF' … EOF`), which carry a long one.
# The heredoc case was missing, so a message that named `.env.production` — the
# very thing rule 3 exists to describe — blocked its own fix. Both are message
# text by construction: nothing that decides what a git command DOES can live
# inside a heredoc body.
#
# (Trade-off, unchanged: a deliberately quoted branch name could slip a
# force-push past — acceptable for a backstop, since quoted branch names are
# rare while quoted messages are universal.)
scrubbed="$(printf '%s' "$cmd" | perl -0777 -pe "s/<<-?\s*(['\"]?)([A-Za-z_][A-Za-z0-9_]*)\1.*?^\2\$/ /gms" \
  | sed -E "s/'[^']*'/ /g; s/\"[^\"]*\"/ /g")"

# 0) Reckless recursive delete of a root / home / system / parent path. The one
# non-git rule, so it runs before the git-only gate below. Matched against a
# quote-STRIPPED copy of the raw command (quotes removed, content kept) — not
# the message-scrubbed string — so a quoted argument like `rm -rf "$HOME"` is
# still caught. Requires a recursive flag (-r/-R/-rf/... in any order, or
# --recursive) AND a dangerous path argument. Allowed by design: relative paths
# (node_modules, dist, .worktrees/x), /tmp/..., deeper project paths.
# Trade-off: a commit MESSAGE that literally contains `rm -rf /` could trip this
# (quote chars are stripped, not the whole span) — rare, and recoverable with
# the ! prefix; blocking an accidental home/root wipe is worth that.
nq="$(printf '%s' "$cmd" | tr -d "\"'")"
if printf '%s' "$nq" | grep -Eq '(^|[^[:alnum:]_./-])rm[[:space:]]+((-[a-zA-Z]+|--[a-z-]+|--)[[:space:]]+)*(-[a-zA-Z]*[rR][a-zA-Z]*|--recursive)([[:space:]]+(-[a-zA-Z]+|--[a-z-]+|--))*[[:space:]]+(/([[:space:]]|$|\*)|/(home|root|usr|etc|var|bin|sbin|lib|lib64|opt|boot|sys|proc|dev|Users)([[:space:]/]|$)|~([[:space:]/*]|$)|\$\{?HOME\}?([[:space:]/*]|$)|\.\.([[:space:]/]|$))'; then
  block "recursive delete targeting a root / home / system / parent path. Delete specific project subpaths (relative, or under /tmp) explicitly instead."
fi

# Only inspect git invocations beyond this point.
printf '%s' "$scrubbed" | grep -Eq '(^|[^[:alnum:]_./-])git([[:space:]]|$)' || exit 0

# 1) Never bypass git hooks: --no-verify, commit -n, or -c core.hooksPath=...
if printf '%s' "$scrubbed" | grep -Eq -- '--no-verify'; then
  block "git --no-verify is forbidden. Fix the failing hook (gitleaks/lint/typecheck) and commit normally — then make a NEW commit."
fi
if printf '%s' "$scrubbed" | grep -Eiq -- '-c[[:space:]=]*core\.hookspath'; then
  block "git -c core.hooksPath=... disables hooks (same effect as --no-verify). Forbidden — fix the hook and retry."
fi
# (push -n is --dry-run, harmless — only commit's -n means --no-verify.)
# Scan only `git commit`'s OWN arguments, up to the next command separator: a
# `-n` anywhere else in a compound command (`grep -n … && git commit …`) is not
# this flag, and blocking on it makes the guard something to work around.
commit_args="$(printf '%s' "$scrubbed" \
  | perl -0777 -ne 'while (/git\s+commit((?:(?!\s*(?:;|&&|\|\||\||\n)).)*)/gs) { print "$1\n" }')"
if [ -n "$commit_args" ] \
   && printf '%s' "$commit_args" | grep -Eq '(^|[[:space:]])-[a-zA-Z]*n[a-zA-Z]*([[:space:]]|$)'; then
  block "git commit -n bypasses hooks (short for --no-verify). Forbidden — fix the hook and retry."
fi

# 2) Force-push to main/master is the user's call, never Claude's. Covers
# --force / -f / --force-with-lease AND the leading-'+' refspec force form, and
# matches main/master written bare, as origin main, refs/heads/main, or :main.
#
# Scoped to `git push`'s OWN arguments for the same reason `git commit -n` is:
# `-f` is a force flag only here. `gh api … -f ref=refs/heads/dev` in the same
# compound command passes a FIELD, and blocking on it makes the guard something
# to work around rather than something to satisfy.
push_args="$(printf '%s' "$scrubbed" \
  | perl -0777 -ne 'while (/git\s+(?:-[^\s]+\s+)*push((?:(?!\s*(?:;|&&|\|\||\||\n)).)*)/gs) { print "$1\n" }')"
if [ -n "$push_args" ]; then
  has_force=0
  printf '%s' "$push_args" | grep -Eq -- '(--force([[:space:]=]|$)|--force-with-lease|[[:space:]]-f([[:space:]]|$))' && has_force=1
  printf '%s' "$push_args" | grep -Eq '[[:space:]]\+[^[:space:]]*(main|master)' && has_force=1
  if [ "$has_force" = 1 ] \
     && printf '%s' "$push_args" | grep -Eq '([[:space:]:/+]|origin[[:space:]]+)(main|master)([[:space:]:]|$)'; then
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

# 4) `git stash` in a repo that has sibling worktrees. `refs/stash` lives in the
# common `.git` and is a single repo-wide STACK: a linked worktree isolates the
# working tree and the index, never the ref namespace. So concurrent agents push
# onto and pop from one stack, and `stash@{0}` is whoever pushed last.
#
# Two agents interleaving push/pop is not hypothetical — one popped the other's
# entry, a worktree received a foreign change, and the original fix left
# `refs/stash` for ~248 dangling commits. Neither agent saw an error, because
# nothing about it is an error to git (#297, #275).
#
# Blocked only where the hazard exists: a repo with more than one worktree. A
# solo checkout stashes freely. `list`/`show` are reads and stay allowed.
# Anchored to a COMMAND position — start of the string or just after a
# separator — so `echo git stash is repo-wide >> notes.md` is prose, not an
# invocation. Reading a command out of running text is how a guard becomes
# something to work around.
if printf '%s' "$scrubbed" | grep -Eq '(^|[;&|]|^[[:space:]]*)[[:space:]]*git([[:space:]]+-[^[:space:]]+)*[[:space:]]+stash([[:space:]]|$)'; then
  stash_verb="$(printf '%s' "$scrubbed" \
    | perl -0777 -ne 'if (/git(?:\s+-\S+)*\s+stash\s*([a-z-]*)/) { print $1 }')"
  case "$stash_verb" in
    list | show) ;;
    *)
      if [ "$(git worktree list 2>/dev/null | wc -l)" -gt 1 ]; then
        block "git stash shares one repo-wide \`refs/stash\` with every worktree of this repo, so a concurrent agent can pop your entry (or you theirs) with no error — that has already cost real work. Commit to your branch instead: a WIP commit is per-branch, visible, and \`git reset --soft HEAD~1\` undoes it. If you genuinely need a stash, name it and pop it by message rather than by index: \`git stash push -m ISSUE\` then \`git stash pop stash@{/ISSUE}\`."
      fi
      ;;
  esac
fi

exit 0
