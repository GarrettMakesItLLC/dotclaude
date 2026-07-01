#!/usr/bin/env bash
# Self-test for worktree-guard.sh. Builds throwaway git repos, feeds a
# PreToolUse payload through the hook, and asserts the exit code
# (2 = blocked, 0 = allowed). Run locally or in CI:
#   bash hooks/worktree-guard.test.sh
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GUARD="$HERE/worktree-guard.sh"
fail=0

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t

# want, tool_name, path-key, path, [WORKTREE_GUARD_OFF value]
check() {
  local want="$1" tool="$2" key="$3" path="$4" off="${5:-}" got
  WORKTREE_GUARD_OFF="$off" python3 -c '
import json,sys
print(json.dumps({"tool_name":sys.argv[1],"tool_input":{sys.argv[2]:sys.argv[3]}}))
' "$tool" "$key" "$path" | WORKTREE_GUARD_OFF="$off" "$GUARD" >/dev/null 2>&1
  got=$?
  if [ "$got" != "$want" ]; then
    echo "FAIL: want $want, got $got for $tool $key=$path off='$off'"
    fail=1
  fi
}

# --- convention repo: .worktrees/ gitignored, one commit, one linked worktree
CONV="$TMP/conv"
mkdir -p "$CONV"
git -C "$CONV" init -q
printf '.worktrees/\n' > "$CONV/.gitignore"
git -C "$CONV" add .gitignore
git -C "$CONV" commit -qm init
git -C "$CONV" worktree add -q "$CONV/.worktrees/wt" -b feat 2>/dev/null
mkdir -p "$CONV/src"

# --- non-convention repo: no .worktrees/ ignore
PLAIN="$TMP/plain"
mkdir -p "$PLAIN/src"
git -C "$PLAIN" init -q
git -C "$PLAIN" commit -qm init --allow-empty

# Should BLOCK (main tree of a convention repo)
check 2 Edit         file_path     "$CONV/src/existing.ts"
check 2 Write        file_path     "$CONV/src/brand-new.ts"      # file need not exist yet
check 2 NotebookEdit notebook_path "$CONV/src/nb.ipynb"

# Should BLOCK — quoting/path-resolution edge cases in the main tree.
mkdir -p "$CONV/dir with space"
check 2 Edit file_path "$CONV/dir with space/x.ts"    # space in path must not break quoting
check 2 Write file_path "$CONV/a/b/c/deep.ts"         # many missing ancestor dirs -> climb to root

# Should BLOCK — convention detected via a GLOBAL gitignore, not the repo's own.
GLOBALIGN="$TMP/globalignore"
printf '.worktrees/\n' > "$GLOBALIGN"
GCONV="$TMP/gconv"
mkdir -p "$GCONV/src"
git -C "$GCONV" init -q
git -C "$GCONV" config core.excludesFile "$GLOBALIGN"   # .worktrees/ ignored globally, not in-repo
git -C "$GCONV" commit -qm init --allow-empty
check 2 Edit file_path "$GCONV/src/app.ts"

# Should ALLOW
check 0 Edit  file_path "$CONV/.worktrees/wt/x.ts"   # inside a linked worktree
check 0 Edit  file_path "$CONV/src/existing.ts" 1     # escape hatch set
check 0 Edit  file_path "$PLAIN/src/app.ts"           # repo doesn't use the convention
check 0 Write file_path "$TMP/loose.txt"              # not in any git repo
check 0 Edit  file_path "$HERE/../CLAUDE.md"          # the dotclaude config repo itself

# Should ALLOW — a linked worktree placed OUTSIDE the repo's .worktrees/ dir.
# The header claims detection is structural (git-dir != git-common-dir), not
# path-name based; this proves it.
git -C "$CONV" worktree add -q "$TMP/external-wt" -b feat-ext 2>/dev/null
check 0 Edit file_path "$TMP/external-wt/x.ts"

# Should ALLOW — the config-repo exemption reached THROUGH a directory symlink,
# exactly as production does (~/.claude/hooks -> dotclaude/hooks). Invokes the
# guard via a symlinked parent dir so readlink -f must resolve the chain to find
# the real repo root. A regression here would silently block edits to ~/dotclaude.
ln -s "$HERE" "$TMP/hooks-link"
printf '{"tool_name":"Edit","tool_input":{"file_path":"%s"}}' "$HERE/../CLAUDE.md" \
  | "$TMP/hooks-link/worktree-guard.sh" >/dev/null 2>&1
if [ "$?" != 0 ]; then
  echo "FAIL: config-repo exemption did not fire through a symlinked hooks dir"
  fail=1
fi

if [ "$fail" = 0 ]; then
  echo "worktree-guard: all cases passed"
fi
exit "$fail"
