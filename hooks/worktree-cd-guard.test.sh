#!/usr/bin/env bash
# Self-test for worktree-cd-guard.sh: a cd/pushd into a missing worktree path is
# blocked (absolute and ~/ forms, every separator), while an existing tree, a
# tree the same command creates, a non-worktree path, a relative path, an
# unevaluated expansion, prose and heredoc bodies all pass.
#   bash hooks/worktree-cd-guard.test.sh
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GUARD="$HERE/worktree-cd-guard.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
fail=0

export HOME="$TMP/home"
mkdir -p "$HOME/repo/.worktrees/live" "$TMP/repo/.claude/worktrees/agent-1"

check() {
  local want="$1" cmd="$2" got
  printf '%s' "$cmd" \
    | python3 -c 'import json,sys; print(json.dumps({"tool_name":"Bash","tool_input":{"command":sys.stdin.read()}}))' \
    | "$GUARD" >/dev/null 2>&1
  got=$?
  if [ "$got" != "$want" ]; then
    echo "FAIL: want exit $want, got $got for: $cmd"
    fail=1
  fi
}

GONE="$TMP/repo/.worktrees/gone"
check 2 "cd $GONE && npm test"
check 2 "cd $GONE; npm test"
check 2 "cd \"$GONE\" && git status"
check 2 "pushd $GONE && make"
check 2 "cd ~/repo/.worktrees/gone && ls"
check 2 "cd $TMP/repo/.claude/worktrees/agent-9/sub && ls"
check 2 "echo hi && cd $GONE && ls"
check 2 "bash -c 'cd $GONE && ls'"
# #451: options and builtins before the path, and a cd on a later line.
check 2 "cd -- $GONE"
check 2 "cd -P $GONE"
check 2 "cd -L -e $GONE"
check 2 "builtin cd $GONE"
check 2 "command cd $GONE"
check 2 "time cd $GONE"
check 2 "pushd -- $GONE"
check 2 "$(printf 'echo x\ncd -P %s' "$GONE")"

check 0 "cd $HOME/repo/.worktrees/live && npm test"
check 0 "cd ~/repo/.worktrees/live && ls"
check 0 "cd $TMP/repo/.claude/worktrees/agent-1 && ls"
check 0 "cd -P $HOME/repo/.worktrees/live && ls"
check 0 "builtin cd -- $HOME/repo/.worktrees/live"
check 0 "time cd $HOME/repo/.worktrees/live"
check 0 "cd - && ls"
check 0 "git worktree add $GONE -b feat/x && cd $GONE && npm ci"
check 0 "git -C $TMP/repo worktree add -b feat/y $GONE && cd $GONE"
check 0 "mkdir -p $GONE && cd $GONE"
check 0 "cd /definitely/not/a/worktree && ls"
check 0 "cd .worktrees/gone && ls"
check 0 'cd "$WT"/.worktrees/gone && ls'
check 0 "echo 'cd $GONE' >> notes.md"
check 0 "$(printf 'cat > runbook.md <<EOF\ncd %s\nEOF' "$GONE")"
check 0 "git status"

printf 'not json' | "$GUARD" >/dev/null 2>&1 || { echo "FAIL: garbage input did not fail open"; fail=1; }

[ "$fail" = 0 ] && echo "worktree-cd-guard: all cases passed"
exit "$fail"
