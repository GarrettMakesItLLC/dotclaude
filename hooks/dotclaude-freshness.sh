#!/usr/bin/env bash
# dotclaude-freshness — SessionStart hook (#409).
#
# `~/.claude/bin`, `hooks` and `skills` resolve into the `~/dotclaude`
# checkout, so EVERY session on a machine runs whatever that checkout has on
# disk right now — with no error, ever. On DESKTOP-LPT6M7Q the checkout sat
# on a deleted branch, 10 commits behind origin/main, and every session ran
# stale tooling without knowing it: `fleet-lease.sh` still ran a pre-push
# hook #376 had already fixed, and a lease renew sat 15+ min behind a check
# lock until it timed out and the lease went STALE mid-wave (filed as #405
# before the cause was found).
#
# Two independent checks, both cheap:
#   1. Is HEAD on `main`? Purely local — no network, never cached, never
#      skipped. Off main is off the branch dotrepo-sync.sh (runs earlier in
#      the same SessionStart chain) fast-forwards toward, so nothing else in
#      the chain catches this case.
#   2. Is `main` behind `origin/main` by more than a threshold? dotrepo-sync.sh
#      already fast-forwards this silently whenever the tree is clean, so by
#      the time this hook runs the common case is already caught up and this
#      stays silent. It only has anything to say when the fast-forward
#      couldn't happen — a dirty tree, or history that diverged — which
#      dotrepo-sync reports only under DOTSYNC_VERBOSE, and a session start
#      never sets that.
#
# The network part of check 2 is TTL-cached (soft-stale, like fleet-mode.sh):
# a fetch happens at most once per TTL, never once per session start.
#
# ALWAYS exits 0 and prints at most one line. Fail-open by design: no repo,
# no git, no network, an unreadable cache — none of that is worth blocking a
# session over.
set -uo pipefail

HOOK_DIR="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
DOTCLAUDE_DIR="${DOTCLAUDE_DIR:-$(dirname "$HOOK_DIR")}"

THRESHOLD="${DOTCLAUDE_FRESHNESS_BEHIND_THRESHOLD:-5}"
TTL="${DOTCLAUDE_FRESHNESS_TTL:-1800}"
FETCH_TIMEOUT="${DOTCLAUDE_FRESHNESS_FETCH_TIMEOUT:-8}"
CACHE_DIR="${DOTCLAUDE_FRESHNESS_CACHE_DIR:-${XDG_CACHE_HOME:-$HOME/.cache}/dotclaude/freshness}"
CACHE_FILE="$CACHE_DIR/state"

[ -d "$DOTCLAUDE_DIR/.git" ] || exit 0
command -v git >/dev/null 2>&1 || exit 0

fix="git -C $DOTCLAUDE_DIR checkout main && git -C $DOTCLAUDE_DIR pull --ff-only (or: /dotclaude-sync)"

branch="$(git -C "$DOTCLAUDE_DIR" symbolic-ref --short -q HEAD 2>/dev/null || true)"

if [ "$branch" != main ]; then
  where="${branch:-a detached HEAD}"
  echo "⚠ dotclaude: $DOTCLAUDE_DIR is on $where, not main — every session on this machine runs whatever that checkout has. Fix: $fix" >&2
  exit 0
fi

# --- check 2: behind origin/main, TTL-cached fetch --------------------------
mkdir -p "$CACHE_DIR" 2>/dev/null || exit 0

now="$(date +%s)"
cached_at="$(grep -m1 '^checked_at=' "$CACHE_FILE" 2>/dev/null | cut -d= -f2)"
cached_behind="$(grep -m1 '^behind=' "$CACHE_FILE" 2>/dev/null | cut -d= -f2)"
case "$cached_at" in '' | *[!0-9]*) cached_at=0 ;; esac

age=$((now - cached_at))
if [ "$age" -ge "$TTL" ] || [ -z "$cached_behind" ]; then
  if timeout "$FETCH_TIMEOUT" git -C "$DOTCLAUDE_DIR" fetch --quiet origin main 2>/dev/null; then
    fetched_behind="$(git -C "$DOTCLAUDE_DIR" rev-list --count HEAD..origin/main 2>/dev/null)"
    case "$fetched_behind" in '' | *[!0-9]*) fetched_behind="" ;; esac
    if [ -n "$fetched_behind" ]; then
      { echo "checked_at=$now"; echo "behind=$fetched_behind"; } > "$CACHE_FILE" 2>/dev/null || true
      cached_behind="$fetched_behind"
    fi
  fi
  # Fetch failed (no network, no remote) or produced nothing usable: fall
  # through with whatever cached_behind already held — possibly still empty,
  # in which case there is nothing yet to warn about.
fi

case "$cached_behind" in '' | *[!0-9]*) cached_behind=0 ;; esac

if [ "$cached_behind" -gt "$THRESHOLD" ]; then
  echo "⚠ dotclaude: $DOTCLAUDE_DIR main is $cached_behind commit(s) behind origin/main. Fix: $fix" >&2
fi

exit 0
