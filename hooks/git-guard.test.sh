#!/usr/bin/env bash
# Self-test for git-guard.sh. Feeds commands through the hook and asserts the
# exit code (2 = blocked, 0 = allowed). Run locally or in CI:
#   bash hooks/git-guard.test.sh
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GUARD="$HERE/git-guard.sh"
fail=0

# Failures are recorded in a FILE, not a variable.
#
# Most cases below run inside `( … )` subshells (one per temp repo). A
# `fail=1` there is set in the subshell and discarded when it exits, and the
# `) || fail=1` that follows only fires when the subshell's LAST command
# exited non-zero — which is a passing `check 0` in every block. So every
# failing case except a trailing one was invisible, the suite printed "all
# cases passed", and it exited 0. Verified: four deliberately-failing cases
# printed FAIL and the run still exited 0.
#
# A file crosses the subshell boundary, so the verdict is whatever actually
# happened rather than whatever the last line happened to return (#383).
FAIL_MARKER="$(mktemp)"
trap 'rm -f "$FAIL_MARKER"' EXIT

# wrap a raw command string as the PreToolUse stdin JSON, run the guard.
check() {
  local want="$1" cmd="$2"
  local got
  printf '%s' "$cmd" \
    | python3 -c 'import json,sys; print(json.dumps({"tool_name":"Bash","tool_input":{"command":sys.stdin.read()}}))' \
    | "$GUARD" >/dev/null 2>&1
  got=$?
  if [ "$got" != "$want" ]; then
    echo "FAIL: want exit $want, got $got for: $cmd"
    echo x >> "$FAIL_MARKER"
  fi
}

# Should BLOCK (exit 2)
check 2 'git commit --no-verify -m "x"'
check 2 'git commit -nm "x"'
check 2 'git commit -n -m "x"'
check 2 'git push --no-verify'
check 2 'git push --force origin main'
check 2 'git push -f origin main'
check 2 'git push --force-with-lease origin master'
check 2 'git add .env'
check 2 'git add config/.env.production'
check 2 'git commit .env -m "x"'
check 2 'git -c core.hooksPath=/dev/null commit -m "x"'
check 2 'git push --force origin refs/heads/main'
check 2 'git push origin +main'
check 2 'git push origin +HEAD:main'
check 2 'rm -rf /'
check 2 'rm -rf ~'
check 2 'rm -rf $HOME'
check 2 'rm -rf /usr/local/bin'
check 2 'rm -rf /etc'
check 2 'rm -rf ../sibling'
# Quoted paths — quotes must not let the dangerous arg slip past the scrubber.
check 2 'rm -rf "$HOME"'
check 2 'rm -rf "/"'
check 2 "rm -rf '/'"
check 2 'rm -rf "/home/garrett"'
check 2 'rm -rf ${HOME}'
# Flag variants: capital -R, long --recursive, separated flags, -- separator.
check 2 'rm -Rf /'
check 2 'rm --recursive --force /'
check 2 'rm -r --force /'
check 2 'rm -f -r /'
check 2 'rm -rf -- /'

# Should ALLOW — flag/path tokens that appear only inside a -m MESSAGE body.
check 0 'git commit -m "fix: load .env before init"'
check 0 'git commit -am "chore: add .env to gitignore"'
check 0 'git commit -m "stop using --no-verify in scripts"'
# A -n belonging to another command in the same line is not commit's -n.
check 0 'grep -n labels_audit README.md && git commit -q -F -'
check 0 'git add -A; git commit -m "x"; grep -rn TODO src'
check 0 'git log --oneline -n 5'
# ...but commit's own still blocks, wherever it sits in the pipeline.
check 2 'grep -n x README.md && git commit -n -m "x"'
check 0 'git commit -m "force-push to main is now blocked"'
check 0 'git commit -m "document core.hooksPath bypass"'

# Should ALLOW (exit 0)
check 0 'git commit -m "feat: normal commit about main flow"'
check 0 'git commit --amend -m "x"'
check 0 'git commit --no-edit'
check 0 'git commit -am "fix main"'
check 0 'git push origin feature/foo'
check 0 'git push --force origin feature/foo'
check 0 'git push -n origin main'
# `-f` is a force flag only inside `git push`'s own arguments. These pass a
# FIELD to a later command in the same compound line, and the whole-line scan
# they used to hit blocked repo bootstrap outright.
check 0 'git push -u origin main && gh api repos/o/r/git/refs -f ref=refs/heads/dev -f sha="$MAIN"'
check 0 'gh api repos/o/r -f default_branch=main && git push origin feature/foo'
# …but a real force-push still blocks when it shares a line with anything else.
check 2 'echo starting && git push --force origin main'
check 2 'git push -f origin main && gh api repos/o/r -f x=1'
check 0 'git add .env.example'
check 0 'git add src/app.ts'
check 0 'git log -n 5'
check 0 'git clean -n'
check 0 'git status'
check 0 'npm run main'
check 0 'ls -la && echo done'
check 0 'rm -rf node_modules'
check 0 'rm -rf dist .next'
check 0 'rm -rf .worktrees/feature-x'
check 0 'rm -rf /tmp/claude-scratch'
check 0 'rm -f config.local'
check 0 'rm -rf ./build'
# Quoted safe paths must still be allowed after quote-stripping.
check 0 'rm -rf "node_modules"'
check 0 'rm -rf "/tmp/x"'
# Not a recursive delete, and not the `rm` command at all.
check 0 'rm -f /etc/foo'
check 0 'rrm -rf /'

# --- git stash where refs/stash is shared with sibling worktrees (#297, #275).
# `refs/stash` is ONE repo-wide stack: a linked worktree isolates the working
# tree and the index, never the ref namespace. Two agents interleaving push/pop
# meant one popped the other's entry, with no error from git either time.
#
# Run from PURPOSE-BUILT repos, not from wherever the suite happens to be
# invoked. The rule keys on `git worktree list`, so an ambient cwd makes the
# answer depend on the developer's shell — green from a worktree, red from a
# plain checkout, and CI is a plain checkout (#269).
stash_repo="$(mktemp -d)/multi"
git init -q "$stash_repo"
git -C "$stash_repo" -c user.email=t@t -c user.name=t commit -q --allow-empty -m init
git -C "$stash_repo" worktree add -q "$stash_repo/.worktrees/wt" -b feat 2>/dev/null
(
  cd "$stash_repo" || exit 1
  check 2 'git stash'
  check 2 'git stash push -m wip'
  check 2 'git stash -u'
  check 2 'git stash pop'
  check 2 'git stash apply'
  check 2 'git stash drop'
  # Reads are fine — seeing the stack is how you discover somebody else's entry.
  check 0 'git stash list'
  check 0 'git stash show'
  # Not a stash at all, and prose that merely mentions one.
  check 0 'git status'
  check 0 'echo git stash is repo-wide >> notes.md'
) || fail=1
rm -rf "$(dirname "$stash_repo")"

# A repo with a single worktree has no sibling to collide with, so stashing is
# the operator's own business.
solo="$(mktemp -d)/solo"
git init -q "$solo"
git -C "$solo" -c user.email=t@t -c user.name=t commit -q --allow-empty -m init
(
  cd "$solo" || exit 1
  check 0 'git stash push -m wip'
  check 0 'git stash pop'
) || fail=1
rm -rf "$(dirname "$solo")"

# --- #185: GIT_GUARD_HOOK_PROVEN_KILLED narrows ONLY the --no-verify/-n
# block, and only when actually set.
check_env() {
  local want="$1" envval="$2" cmd="$3"
  local got
  printf '%s' "$cmd" \
    | python3 -c 'import json,sys; print(json.dumps({"tool_name":"Bash","tool_input":{"command":sys.stdin.read()}}))' \
    | GIT_GUARD_HOOK_PROVEN_KILLED="$envval" "$GUARD" >/dev/null 2>&1
  got=$?
  if [ "$got" != "$want" ]; then
    echo "FAIL: want exit $want, got $got for (GIT_GUARD_HOOK_PROVEN_KILLED=$envval): $cmd"
    fail=1
  fi
}

# Should ALLOW — the escape hatch lifts --no-verify/-n when actually set.
check_env 0 1 'git commit --no-verify -m "x"'
check_env 0 1 'git commit -nm "x"'
check_env 0 1 'git push --no-verify'

# Should still BLOCK — unset (or empty) leaves the normal block in place.
check_env 2 '' 'git commit --no-verify -m "x"'

# Should still BLOCK — the escape is narrow: force-push and .env rules are
# UNAFFECTED even with the var set.
check_env 2 1 'git push --force origin main'
check_env 2 1 'git add .env'
check_env 2 1 'git -c core.hooksPath=/tmp/x commit -m "y"'

# --- #363: heredoc scrub must consume a `<<-'EOF'` heredoc nested inside a
# `$(...)` command substitution even when the closing delimiter is indented
# (the `<<-` form strips leading tabs and allows an indented terminator).
check 0 "$(printf 'git commit -m "$(cat <<-'"'"'EOF'"'"'\n\tmentions .env.local in prose here\n\tEOF\n)"')"
check 0 "$(printf 'git commit -m "$(cat <<'"'"'EOF'"'"'\ntest(web): isolate env-whitespace-guard.test.ts from ambient VITE_* env\n\nmentions .env.local in prose here\nEOF\n)"')"
# A REAL staged .env file must still block even through the same $(...) shape.
check 2 "$(printf 'git add .env && git commit -m "$(cat <<'"'"'EOF'"'"'\nnormal message\nEOF\n)"')"

check_discard_env() {
  local want="$1" envval="$2" cmd="$3"
  local got
  printf '%s' "$cmd" \
    | python3 -c 'import json,sys; print(json.dumps({"tool_name":"Bash","tool_input":{"command":sys.stdin.read()}}))' \
    | GIT_GUARD_ALLOW_DISCARD="$envval" "$GUARD" >/dev/null 2>&1
  got=$?
  if [ "$got" != "$want" ]; then
    echo "FAIL: want exit $want, got $got for (GIT_GUARD_ALLOW_DISCARD=$envval): $cmd"
    echo x >> "$FAIL_MARKER"
  fi
}

# --- #353: a path-scoped discard that would drop UNCOMMITTED work.
# `git checkout <ref-other-than-HEAD> -- <path>` and `--staged`/`--source=`
# restores are the safe, unimpeded forms; only the bare discard forms against
# a DIRTY path are blocked, and only when the escape hatch isn't set.
discard_repo="$(mktemp -d)/discard"
git init -q "$discard_repo"
git -C "$discard_repo" -c user.email=t@t -c user.name=t commit -q --allow-empty -m init
(
  cd "$discard_repo" || exit 1
  echo committed > tracked.txt
  git add tracked.txt
  git -c user.email=t@t -c user.name=t commit -q -m "add tracked.txt"

  # Dirty the file — this is the uncommitted work a discard would silently drop.
  echo "uncommitted change" > tracked.txt

  check 2 'git checkout -- tracked.txt'
  check 2 'git checkout HEAD -- tracked.txt'
  check 2 'git restore tracked.txt'

  # Every spelling of HEAD is blocked, not just the word. `HEAD~0` was
  # asserted here as a SAFE form and is not one: it resolves to the commit
  # already checked out, so it discards uncommitted work exactly as the
  # blocked `git checkout HEAD -- <path>` does. The test encoded the
  # matcher's behaviour rather than the property the guard exists to hold
  # (#383).
  check 2 'git checkout @ -- tracked.txt'
  check 2 'git checkout HEAD~0 -- tracked.txt'
  check 2 'git checkout HEAD^0 -- tracked.txt'
  check 2 'git checkout @~0 -- tracked.txt'

  # Safe forms stay unimpeded even though the path is dirty. These name a
  # DIFFERENT commit, which is the whole point — they fetch an older version
  # of the file rather than overwriting it with the one you already have.
  check 0 'git checkout HEAD~1 -- tracked.txt'
  check 0 'git checkout origin/main -- tracked.txt'
  check 0 'git restore --staged tracked.txt'
  check 0 'git restore --source=HEAD~1 tracked.txt'
  check 0 'git checkout main'

  # The escape hatch lifts ONLY this block, loudly.
  check_discard_env 0 1 'git checkout -- tracked.txt'
  check_discard_env 2 '' 'git checkout -- tracked.txt'

  # A CLEAN path is never blocked.
  git checkout -q -- tracked.txt
  check 0 'git checkout -- tracked.txt'
  check 0 'git restore tracked.txt'
) || fail=1
rm -rf "$(dirname "$discard_repo")"

# --- #411: a worktree-stealing branch operation. Plain `checkout <branch>` /
# `switch <branch>` already refuse this; the forcing/renaming forms accept it
# with no warning and rewrite the OTHER worktree's HEAD out from under it.
#
# Purpose-built repo, like the stash section: the rule keys on
# `git worktree list`, so it must not depend on wherever the suite is invoked.
wt_repo="$(mktemp -d)/wt"
git init -q "$wt_repo"
git -C "$wt_repo" -c user.email=t@t -c user.name=t commit -q --allow-empty -m init
git -C "$wt_repo" branch -M main
git -C "$wt_repo" worktree add -q "$wt_repo/.worktrees/w1" -b integration/w3 2>/dev/null
git -C "$wt_repo" worktree add -q "$wt_repo/.worktrees/w2" -b feature/other 2>/dev/null
(
  cd "$wt_repo/.worktrees/w2" || exit 1
  # w1 holds integration/w3; every one of these, run from w2, would steal it.
  check 2 'git checkout -B integration/w3 origin/main'
  check 2 'git switch -C integration/w3 origin/main'
  check 2 'git branch -f integration/w3 HEAD'
  check 2 'git branch -m integration/w3 integration/perf'
  check 2 'git branch -M integration/w3 integration/perf'
  check 2 'git update-ref refs/heads/integration/w3 HEAD'
  # Safe forms: w2's OWN branch, or a brand-new one, is nobody else's tree.
  check 0 'git checkout -b brand-new-branch'
  check 0 'git branch -f feature/other HEAD'
  check 0 'git status'
) || fail=1
(
  cd "$wt_repo" || exit 1
  # -C names the own tree as w2, not the cwd — still a steal of w1's branch.
  check 2 'git -C .worktrees/w2 checkout -B integration/w3 origin/main'
) || fail=1
(
  # Run FROM w1 itself: renaming w1's own current branch (the one-arg form,
  # which names it nowhere in the command) is the tree's own business.
  cd "$wt_repo/.worktrees/w1" || exit 1
  check 0 'git branch -m integration/perf'
) || fail=1

# The one-arg rename form names no branch at all — it renames whatever the
# OWN tree currently has checked out. Reaching that collision for real needs a
# branch checked out in two worktrees at once, which is exactly the bug #411
# fixes: reproduce the incident's actual mechanism, not just its symptom, by
# force-pointing a THIRD worktree's HEAD at w1's branch the same way a bare
# `checkout -B`/`switch -C`/`symbolic-ref` from outside this guard would.
git -C "$wt_repo" worktree add -q "$wt_repo/.worktrees/w3" -b feature/third 2>/dev/null
git -C "$wt_repo/.worktrees/w3" symbolic-ref HEAD refs/heads/integration/w3
(
  cd "$wt_repo/.worktrees/w3" || exit 1
  check 2 'git branch -m renamed-elsewhere'
) || fail=1
# The escape hatch lifts ONLY this block, loudly.
check_worktree_steal_env() {
  local want="$1" envval="$2" cmd="$3"
  local got
  printf '%s' "$cmd" \
    | python3 -c 'import json,sys; print(json.dumps({"tool_name":"Bash","tool_input":{"command":sys.stdin.read()}}))' \
    | GIT_GUARD_ALLOW_WORKTREE_STEAL="$envval" "$GUARD" >/dev/null 2>&1
  got=$?
  if [ "$got" != "$want" ]; then
    echo "FAIL: want exit $want, got $got for (GIT_GUARD_ALLOW_WORKTREE_STEAL=$envval): $cmd"
    echo x >> "$FAIL_MARKER"
  fi
}
(
  cd "$wt_repo/.worktrees/w2" || exit 1
  check_worktree_steal_env 0 1 'git checkout -B integration/w3 origin/main'
  check_worktree_steal_env 2 '' 'git checkout -B integration/w3 origin/main'
) || fail=1
rm -rf "$(dirname "$wt_repo")"

if [ -s "$FAIL_MARKER" ]; then
  echo "git-guard: $(wc -l < "$FAIL_MARKER" | tr -d ' ') case(s) FAILED"
  fail=1
fi

if [ "$fail" = 0 ]; then
  echo "git-guard: all cases passed"
fi
exit "$fail"
