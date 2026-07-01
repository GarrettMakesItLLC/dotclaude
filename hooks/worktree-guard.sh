#!/usr/bin/env bash
# dotclaude worktree-guard — PreToolUse hook for file-mutating tools
# (Edit | Write | MultiEdit | NotebookEdit).
#
# Turns the "Worktree-first for code changes" rule in ~/dotclaude/CLAUDE.md from
# prose Claude follows probabilistically into a hard, deterministic block. Wired
# in settings.json under hooks.PreToolUse. On a policy hit it exits 2, which
# blocks the edit and feeds stderr back to Claude.
#
# THE PROBLEM IT SOLVES: multiple agents running in one checkout write to the
# MAIN working tree instead of an isolated worktree, so their uncommitted
# changes bleed into every other agent's view. This blocks main-tree edits in
# repos that use the worktree convention, forcing agents onto `.worktrees/`.
#
# WHAT COUNTS AS "uses the worktree convention": the repo gitignores
# `.worktrees/` (checked via `git check-ignore`, so a global gitignore counts
# too). Repos that don't gitignore it are untouched.
#
# ALWAYS ALLOWED (exit 0):
#   - Edits already inside a linked worktree (detected structurally via
#     git-dir != git-common-dir — NOT by matching ".worktrees" in the path, so
#     a worktree placed anywhere still passes).
#   - The dotclaude config repo itself. Its hooks/skills/settings ARE the live
#     config (via the ~/.claude symlinks); editing them in a throwaway worktree
#     would not take effect. Self-identified by locating this script's own repo.
#   - Any edit when WORKTREE_GUARD_OFF is set to a non-empty value — the escape
#     hatch for a deliberate main-tree edit or a solo main session. Export it in
#     your shell profile to opt a whole session out.
#
# Fail-open by design: unparseable input, no python3, no git, or any ambiguity
# exits 0 and lets the edit through. A guard that bricks every edit is far worse
# than one that occasionally misses — it is a backstop, not the only boundary.
#
# KNOWN GAPS (by design — backstop, not a sandbox):
#   - Cannot distinguish a subagent from the main session (no such flag in hook
#     input). Both are guarded; the escape hatch + config-repo exemption cover
#     the legitimate main-session cases.
#   - An agent can still write via the Bash tool (`echo > file`, `sed -i`).
#     Bash file-mangling is out of scope here; this guards the first-class edit
#     tools, which is how agents overwhelmingly write.

set -uo pipefail

# Drain stdin first so the producing side never sees a broken pipe, then apply
# the escape hatch: opt out entirely.
input="$(cat)"
[ -n "${WORKTREE_GUARD_OFF:-}" ] && exit 0

# Need python3 to parse the tool_input JSON. No parser -> fail open.
command -v python3 >/dev/null 2>&1 || exit 0
# Edit/Write/MultiEdit use file_path; NotebookEdit uses notebook_path.
file_path="$(printf '%s' "$input" | python3 -c 'import json,sys
try:
    ti = json.load(sys.stdin).get("tool_input", {})
    sys.stdout.write(ti.get("file_path") or ti.get("notebook_path") or "")
except Exception:
    pass' 2>/dev/null)"

[ -z "$file_path" ] && exit 0

# Need git to reason about worktrees at all.
command -v git >/dev/null 2>&1 || exit 0

# Resolve the nearest existing directory at/above the target (the file may not
# exist yet on a Write). git -C needs a real directory to run in.
dir="$file_path"
[ -d "$dir" ] || dir="$(dirname "$dir")"
while [ ! -d "$dir" ] && [ "$dir" != "/" ] && [ "$dir" != "." ]; do
  dir="$(dirname "$dir")"
done
[ -d "$dir" ] || exit 0

# Outside any git work tree -> not our concern.
[ "$(git -C "$dir" rev-parse --is-inside-work-tree 2>/dev/null)" = "true" ] || exit 0

# Already inside a LINKED worktree? git-dir and git-common-dir diverge there
# (e.g. .git/worktrees/foo vs .git). Equal => main working tree. Both resolved
# to absolute paths so the comparison is robust.
gitdir="$(git -C "$dir" rev-parse --absolute-git-dir 2>/dev/null)"
common_rel="$(git -C "$dir" rev-parse --git-common-dir 2>/dev/null)"
case "$common_rel" in
  /*) commondir="$common_rel" ;;
  *)  commondir="$(cd "$dir" 2>/dev/null && cd "$common_rel" 2>/dev/null && pwd)" ;;
esac
if [ -n "$gitdir" ] && [ -n "$commondir" ] && [ "$gitdir" != "$commondir" ]; then
  exit 0  # in a linked worktree — exactly what we want
fi

# Main working tree from here down. Find its root.
root="$(git -C "$dir" rev-parse --show-toplevel 2>/dev/null)"
[ -z "$root" ] && exit 0

# Exempt the dotclaude config repo itself (see header). Locate this script's own
# repo root via its real path (this file is reached through a ~/.claude symlink).
self="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}" 2>/dev/null || echo "${BASH_SOURCE[0]}")")" 2>/dev/null && pwd)"
if [ -n "$self" ]; then
  selfroot="$(git -C "$self" rev-parse --show-toplevel 2>/dev/null)"
  [ -n "$selfroot" ] && [ "$root" = "$selfroot" ] && exit 0
fi

# Does this repo use the worktree convention (.worktrees/ gitignored)?
git -C "$root" check-ignore -q ".worktrees/.probe" 2>/dev/null || exit 0

# Main tree + worktree-convention repo + not exempted -> block.
echo "⛔ dotclaude worktree-guard blocked this edit." >&2
echo "Reason: '$file_path' is in the MAIN working tree of a repo that uses the" >&2
echo "  .worktrees/ convention. Parallel agents editing the main tree collide —" >&2
echo "  uncommitted changes leak into every other agent's checkout." >&2
echo "Fix: work in an isolated worktree, then edit there:" >&2
echo "    git worktree add .worktrees/<short-name> -b feature/<short-name>" >&2
echo "    cd .worktrees/<short-name>" >&2
echo "Policy: ~/dotclaude/CLAUDE.md (Worktree-first). Deliberate main-tree edit?" >&2
echo "  Re-run with WORKTREE_GUARD_OFF=1 set, or ask the user to run it via ! prefix." >&2
exit 2
