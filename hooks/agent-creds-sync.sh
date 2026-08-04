#!/usr/bin/env bash
# dotclaude agent-creds-sync — SessionStart hook.
#
# THE PROBLEM THIS SOLVES
#   App runtime secrets live in per-app `.env` files or a cloud project (Vercel /
#   Railway); an agent's ad-hoc shell (curl, a one-off script, a psql-equivalent)
#   sees none of that unless something exports it first. Left manual, a freshly
#   added secret only reaches a machine when someone remembers to re-pull it, and
#   agents burn a turn concluding "I can't do that" when they simply couldn't see
#   the key.
#
# WHAT THIS DOES
#   Two opt-in, repo-owned scripts, run IF they exist — this hook is inert in any
#   repo that hasn't opted in:
#     • bin/agent-env-build.sh — regenerates the local-cred file from the repo's
#       own `.env` files. Local + cheap (no network), so it runs every session and
#       picks up any `.env` edit for free.
#     • bin/ops-pull.sh — syncs secrets from wherever the repo keeps them (Vercel,
#       Railway, ...). A network round-trip, so it's gated behind a 12h staleness
#       stamp kept in the repo's OWN git dir (`ops-pull-stamp`, gitignored by
#       construction, private per machine) — this hook doesn't need to know the
#       repo's actual secrets-file path or naming convention, only whether it was
#       asked to sync recently.
#   Both scripts are expected to be idempotent, side-effect their own home-dir
#   output, and be safe to run from any worktree — this hook resolves the MAIN
#   checkout via the shared git common dir so a session opened in a linked
#   worktree still finds and runs the repo's real scripts.
#
# ALWAYS exits 0 — a refresh must never block a session. Offline, an unlinked
# cloud project, or a missing script just leaves the last-good creds in place.
set -uo pipefail

MAX_AGE_SECS=$((12 * 3600))

repo_dir="${CLAUDE_PROJECT_DIR:-$PWD}"
common_dir="$(git -C "$repo_dir" rev-parse --path-format=absolute --git-common-dir 2>/dev/null || true)"
[ -z "$common_dir" ] && exit 0
main_tree="$(dirname "$common_dir")"

# 1. Regenerate local-cred file every session (cheap, offline, idempotent).
build_script="$main_tree/bin/agent-env-build.sh"
[ -x "$build_script" ] && ( cd "$main_tree" && timeout 30 bash "$build_script" ) >/dev/null 2>&1 || true

# 2. Refresh cloud-synced ops secrets only when stale or never pulled (network).
pull_script="$main_tree/bin/ops-pull.sh"
if [ -x "$pull_script" ]; then
  stamp="$common_dir/ops-pull-stamp"
  stale=1
  if [ -f "$stamp" ]; then
    now=$(date +%s)
    mtime=$(stat -c %Y "$stamp" 2>/dev/null || stat -f %m "$stamp" 2>/dev/null || echo 0)
    [ $((now - mtime)) -lt "$MAX_AGE_SECS" ] && stale=0
  fi
  if [ "$stale" = 1 ]; then
    if ( cd "$main_tree" && timeout 60 bash "$pull_script" ) >/dev/null 2>&1; then
      touch "$stamp" 2>/dev/null || true
    fi
  fi
fi

exit 0
