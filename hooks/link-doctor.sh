#!/usr/bin/env bash
# dotclaude link-doctor — SessionStart hook. Runs `bootstrap.sh --check` and, only
# when a link is broken, tells the session which ones and how to fix them.
#
# Why this exists: adding a skill or a directory to the repo needs a bootstrap
# re-run to link it into ~/.claude. Nothing forces that, so a committed skill can
# sit unlinked indefinitely — present in the repo, invisible to every session, and
# silent about it. The doctor already detects this; this hook is what runs it.
#
# Why SessionStart and not per-turn: link state changes when the repo changes, not
# between turns. The check is ~0.3s of stat calls, off the per-turn path, and
# costs zero context while everything is healthy.
#
# Fail-open by design: repo not found, doctor missing, doctor crashing -> exit 0
# and say nothing. A config doctor must never be the reason a session can't start.

set -uo pipefail

# Locate the main checkout via the link the doctor itself maintains, so this works
# whatever the repo is called or wherever it was cloned.
repo=""
if [ -L "$HOME/.claude/CLAUDE.md" ]; then
  target="$(readlink -f "$HOME/.claude/CLAUDE.md" 2>/dev/null || true)"
  [ -n "$target" ] && repo="$(dirname "$target")"
fi
[ -n "$repo" ] && [ -f "$repo/bootstrap.sh" ] || repo="$HOME/dotclaude"
[ -f "$repo/bootstrap.sh" ] || exit 0

out="$(bash "$repo/bootstrap.sh" --check 2>&1)" && exit 0

# Non-zero means drift. Keep only the indented per-item ✗ lines: the ✓ list is
# noise and the doctor's unindented summary line repeats the fix command below.
problems="$(printf '%s\n' "$out" | grep -E '^[[:space:]]+✗' || true)"
[ -n "$problems" ] || exit 0

command -v python3 >/dev/null 2>&1 || exit 0

DOTCLAUDE_DOCTOR_PROBLEMS="$problems" DOTCLAUDE_REPO="$repo" python3 -c '
import json, os
msg = (
    "dotclaude config drift — ~/.claude is not fully linked to the repo, so the items below "
    "are NOT active in this session even though they are committed:\n"
    + os.environ.get("DOTCLAUDE_DOCTOR_PROBLEMS", "")
    + "\nFix with: bash " + os.environ.get("DOTCLAUDE_REPO", "~/dotclaude") + "/bootstrap.sh"
    + "  (idempotent; backs up any real file it replaces to ~/.claude.bak.<timestamp>/)."
    + "\nTell Garrett before running it, then re-check. Linking applies on the NEXT session."
)
print(json.dumps({
    "hookSpecificOutput": {
        "hookEventName": "SessionStart",
        "additionalContext": msg,
    }
}))'

exit 0
