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
DOTFILES_DIR="${DOTFILES_DIR:-$HOME/dotfiles}"

notes=()

# Paths the running app writes to, which are ALSO tracked in the repo.
#
# `settings.json` is the live Claude Code settings file, so `/model`,
# `/output-style` and the dialog settings rewrite it in place. That left the
# checkout permanently dirty, the dirty-tree guard below permanently refused to
# fast-forward, and dotclaude froze at one commit for a week while nine piled up
# behind it — including fixes that were then still being hit in live sessions
# because they had never deployed (#325).
#
# Excluded from the DIRTINESS TEST only. The fast-forward itself is still git's
# to refuse: if an incoming commit touches one of these, git declines rather
# than clobbering local state, and that refusal is reported with the file named.
LIVE_PATHS=("settings.json")

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

  # Dirtiness, ignoring the files the app itself maintains.
  local exclusions=() p
  for p in "${LIVE_PATHS[@]}"; do exclusions+=(":(exclude)$p"); done
  local dirty
  dirty="$(git -C "$dir" status --porcelain -- . "${exclusions[@]}" 2>/dev/null)"
  if [ -n "$dirty" ]; then
    notes+=("$label: $behind commit(s) behind, local changes uncommitted — resolve by hand")
    return 0
  fi

  local before after err
  before="$(git -C "$dir" rev-parse HEAD 2>/dev/null)"
  err="$(git -C "$dir" pull --ff-only --quiet 2>&1)"
  if [ $? -eq 0 ]; then
    notes+=("$label: pulled $behind new commit(s)")
    after="$(git -C "$dir" rev-parse HEAD 2>/dev/null)"
    rebuild_artifacts "$dir" "$label" "$before" "$after"
    return 0
  fi

  # Distinguish the one refusal this change makes reachable — an incoming
  # commit touching a live path the app has since edited — from every other
  # fast-forward failure, because the remedy is different and specific.
  local blocker=""
  for p in "${LIVE_PATHS[@]}"; do
    case "$err" in *"$p"*) blocker="$p"; break ;; esac
  done
  if [ -n "$blocker" ]; then
    notes+=("$label: $behind commit(s) behind — an incoming commit changes \`$blocker\`, which the app has edited locally. Nothing was overwritten. Commit or discard your \`$blocker\` and the next session pulls.")
  else
    notes+=("$label: $behind commit(s) behind, fast-forward failed — resolve by hand")
  fi
}

# Compiled artifacts that are NOT tracked, so a pull updates their sources and
# leaves the thing actually executed untouched.
#
# The github MCP runs from `mcp/github/dist/index.js`, and `dist/` is
# gitignored. Pulling therefore deploys every hook (they run from the checkout)
# and none of the MCP (#325): the dist stayed four weeks and sixteen commits
# stale while agents kept hitting bugs whose fixes had merged. Nothing said so,
# because a stale build is a working build.
#
# Rebuilt only when the pull actually touched the sources, and only when the
# install is already present — a first-run `npm ci` is minutes of session start,
# and this hook must never be why a session is slow to open. Failure is a note,
# never a non-zero exit.
rebuild_artifacts() {
  local dir="$1" label="$2" before="$3" after="$4"
  [ -n "$before" ] && [ -n "$after" ] && [ "$before" != "$after" ] || return 0

  local mcp="$dir/mcp/github"
  [ -f "$mcp/package.json" ] || return 0
  [ -d "$mcp/node_modules" ] || return 0

  git -C "$dir" diff --quiet "$before" "$after" -- mcp/github/src mcp/github/package.json 2>/dev/null && return 0

  if (cd "$mcp" && npm run --silent build >/dev/null 2>&1); then
    notes+=("$label: rebuilt github MCP (sources changed) — restart the session to pick it up")
  else
    notes+=("$label: github MCP sources changed but \`npm run build\` failed in \`$mcp\` — it is running STALE code until you build it by hand")
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
