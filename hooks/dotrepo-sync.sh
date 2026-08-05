#!/usr/bin/env bash
# dotrepo-sync — SessionStart hook. Fast-forwards dotclaude and dotfiles when
# they are cleanly behind their remote; reports when they can't be (dirty
# working tree, or local history has diverged). Never force-touches either.
#
# Runs before link-doctor.sh in settings.json so a freshly-pulled dotclaude is
# what the symlink check verifies in the same session start.
#
# Fail-open by design: missing repo, no network, no upstream configured ->
# silent, exit 0. A sync check must never be the reason a session can't start.

set -uo pipefail

DOTCLAUDE_DIR="${DOTCLAUDE_DIR:-$HOME/dotclaude}"
DOTFILES_DIR="${DOTFILES_DIR:-$HOME/workspace/dotfiles}"

notes=()

sync_repo() {
  local dir="$1" label="$2"
  [ -d "$dir/.git" ] || return 0

  git -C "$dir" fetch --quiet 2>/dev/null || return 0

  local upstream
  upstream="$(git -C "$dir" rev-parse --abbrev-ref --symbolic-full-name '@{u}' 2>/dev/null)" || return 0

  local counts ahead behind
  counts="$(git -C "$dir" rev-list --left-right --count "HEAD...$upstream" 2>/dev/null)" || return 0
  ahead="$(printf '%s' "$counts" | awk '{print $1}')"
  behind="$(printf '%s' "$counts" | awk '{print $2}')"
  [ -n "$ahead" ] && [ -n "$behind" ] || return 0

  [ "$behind" = 0 ] && return 0

  if [ "$ahead" != 0 ]; then
    notes+=("$label: $behind commit(s) behind, $ahead ahead — diverged, resolve by hand")
    return 0
  fi

  if [ -n "$(git -C "$dir" status --porcelain 2>/dev/null)" ]; then
    notes+=("$label: $behind commit(s) behind, local changes uncommitted — resolve by hand")
    return 0
  fi

  if git -C "$dir" pull --ff-only --quiet 2>/dev/null; then
    notes+=("$label: pulled $behind new commit(s)")
  else
    notes+=("$label: $behind commit(s) behind, fast-forward failed — resolve by hand")
  fi
}

sync_repo "$DOTCLAUDE_DIR" "dotclaude"
sync_repo "$DOTFILES_DIR" "dotfiles"

[ "${#notes[@]}" -gt 0 ] || exit 0

command -v python3 >/dev/null 2>&1 || exit 0

msg="$(printf '%s\n' "${notes[@]}")"
DOTREPO_SYNC_NOTES="$msg" python3 -c '
import json, os
print(json.dumps({
    "hookSpecificOutput": {
        "hookEventName": "SessionStart",
        "additionalContext": os.environ.get("DOTREPO_SYNC_NOTES", ""),
    }
}))'

exit 0
