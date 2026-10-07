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
  local payload
  # Build the payload first and check it: a JSON wrapper killed under load fed
  # the guard nothing, and the case then read as the guard allowing it (#524).
  payload="$(printf '%s' "$cmd" \
    | python3 -c 'import json,sys; print(json.dumps({"tool_name":"Bash","tool_input":{"command":sys.stdin.read()}}))')" \
    || { echo "FAIL: could not build the payload for: $cmd"; echo x >> "$FAIL_MARKER"; return; }
  printf '%s' "$payload" | "$GUARD" >/dev/null 2>&1
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

# A multi-line quoted -m message must not hide a hook bypass that follows it (#436).
NL=$'\n'
check 2 "git commit -q -m \"subject${NL}${NL}body\" --no-verify"
check 2 "git commit -q -m \"subject${NL}${NL}body\" -n"
check 2 "cd /x && git add -A && git commit -q -m \"subject${NL}${NL}Co-Authored-By: A\" --no-verify && git log --oneline -1"
check 2 "git commit -m 'subject${NL}body' --no-verify"
# ...and the message body itself still can't trip it.
check 0 "git commit -m \"subject${NL}${NL}stop using --no-verify and -n${NL}and .env\""

# The --no-verify refusal points at the wrapper that solves the slow-hook drop (#439).
out="$(printf '%s' 'git push --no-verify origin x' \
  | python3 -c 'import json,sys; print(json.dumps({"tool_name":"Bash","tool_input":{"command":sys.stdin.read()}}))' \
  | "$GUARD" 2>&1 >/dev/null)"
case "$out" in
  *bin/git-push.sh*) : ;;
  *) echo "FAIL: the --no-verify refusal does not name bin/git-push.sh: $out"; echo x >> "$FAIL_MARKER" ;;
esac

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

# --- #477/#514: the escape the block message advertises is the inline prefix,
# because an agent cannot set the hook's own environment. Driven with the var
# UNSET in the hook env, exactly as the Bash tool delivers it.
check_env 0 '' 'GIT_GUARD_HOOK_PROVEN_KILLED=1 git commit --no-verify -m "x"'
check_env 0 '' 'GIT_GUARD_HOOK_PROVEN_KILLED=1 git commit -nm "x"'
check_env 0 '' 'cd /tmp/wt && GIT_GUARD_HOOK_PROVEN_KILLED=1 git push --no-verify -q origin HEAD'
check_env 0 '' 'GIT_GUARD_HOOK_PROVEN_KILLED=1 git -C /tmp/wt push --no-verify origin HEAD'
# ...and lifts nothing it does not prefix, nothing when it is not a prefix,
# and nothing beyond the --no-verify / -n block.
check_env 2 '' 'GIT_GUARD_HOOK_PROVEN_KILLED=1 git status && git commit --no-verify -m "x"'
check_env 2 '' 'GIT_GUARD_HOOK_PROVEN_KILLED=1 git commit --no-verify -m "x" && git push --no-verify'
check_env 2 '' 'GIT_GUARD_HOOK_PROVEN_KILLED=0 git commit --no-verify -m "x"'
check_env 2 '' 'echo GIT_GUARD_HOOK_PROVEN_KILLED=1 git; git commit --no-verify -m "x"'
check_env 2 '' 'git commit --no-verify -m "GIT_GUARD_HOOK_PROVEN_KILLED=1 git"'
check_env 2 '' 'export GIT_GUARD_HOOK_PROVEN_KILLED=1; git commit --no-verify -m "x"'
check_env 2 '' 'GIT_GUARD_HOOK_PROVEN_KILLED=1 git push --force origin main'
# The advice text names the inline form it now honours.
msg="$(printf '%s' 'git commit --no-verify -m x' \
  | python3 -c 'import json,sys; print(json.dumps({"tool_name":"Bash","tool_input":{"command":sys.stdin.read()}}))' \
  | env -u GIT_GUARD_HOOK_PROVEN_KILLED "$GUARD" 2>&1 >/dev/null)"
case "$msg" in *'prefix that one git command with GIT_GUARD_HOOK_PROVEN_KILLED=1'*) ;; *) echo "FAIL: --no-verify advice does not name the inline prefix: $msg"; fail=1 ;; esac

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

  # The `--`-less forms git treats as path restores are blocked too: git is
  # asked whether the argument resolves to a commit.
  check 2 'git checkout tracked.txt'
  check 2 'git checkout .'
  check 2 'GIT_GUARD_ALLOW_DISCARD=0 git checkout tracked.txt'
  check 2 'GIT_GUARD_ALLOW_DISCARD=1 git status && git checkout -- tracked.txt'
  check 2 'echo "GIT_GUARD_ALLOW_DISCARD=1" && git checkout -- tracked.txt'
  check 0 'git status && GIT_GUARD_ALLOW_DISCARD=1 git checkout -- tracked.txt'
  check 0 'GIT_GUARD_ALLOW_DISCARD=1 git checkout -- tracked.txt'

  # The tree the discard LANDS in is the one judged: `git -C` and a leading
  # `cd` both name it, whatever the session cwd is.
  here="$PWD"
  ( cd / && check 2 "git -C $here checkout -- tracked.txt" )
  ( cd / && check 2 "cd $here && git checkout -- tracked.txt" )
  ( cd / && check 0 "git -C $here checkout -- untouched-elsewhere.txt" )

  # A path in a loop variable is expanded from the loop's word list.
  check 2 'for f in tracked.txt; do git checkout -- "$f"; done'
  check 2 'git checkout -- "$SOME_UNKNOWN_VAR"'

  # #451: spellings ported from MuscleBuddy's hook corpus. A forced switch
  # discards the whole tree; a plain one is refused by git itself.
  git branch other HEAD~1
  for c in 'git checkout -f' 'git checkout --force other' 'git checkout -f other' \
           'git checkout -fb scratch' 'git checkout -f -b scratch' 'git switch -f other' \
           'git switch --force other' 'git switch --discard-changes other' \
           'git switch -fc scratch' "$(printf '# force it\ngit checkout -f other')"; do
    check 2 "$c"
  done
  # Wrappers that run their argument as a command.
  for c in 'env git checkout -- tracked.txt' 'nohup git checkout -- tracked.txt' \
           'timeout 30 git checkout -- tracked.txt' '! git checkout -- tracked.txt' \
           'eval git checkout -- tracked.txt' 'eval "git checkout -- tracked.txt"' \
           'echo tracked.txt | xargs git checkout --' 'command git checkout -- tracked.txt' \
           'time git checkout -- tracked.txt' 'FOO=bar BAZ=1 git restore tracked.txt' \
           'env -u X FOO=1 git checkout -- tracked.txt' 'timeout -s KILL 5 git restore tracked.txt'; do
    check 2 "$c"
  done
  # Lead-ins: a shell -c, a subshell, a case arm, and every line of a
  # multi-line command.
  for c in 'bash -c "git checkout -- tracked.txt"' 'sh -lc "git restore tracked.txt"' \
           '(git checkout -- tracked.txt)' 'case x in x) git checkout -- tracked.txt;; esac' \
           'case x in x) git restore tracked.txt;; esac' \
           "$(printf 'echo start\ngit checkout -- tracked.txt')" \
           "$(printf '# one\n# two\n\ngit restore tracked.txt')" \
           "$(printf 'echo a && \\\n  git checkout -- tracked.txt')" \
           "$(printf "cat > notes.md <<'EOF'\nprose\nEOF\ngit checkout -- tracked.txt")" \
           'git -c a=b -c c=d checkout tracked.txt' 'git checkout @ tracked.txt'; do
    check 2 "$c"
  done
  # Still allowed: plain switches (git guards those itself), a named ref,
  # prose, and the escape hatch.
  for c in 'git checkout other' 'git switch other' 'git switch -c scratch' \
           'git checkout -b scratch' 'git checkout other -- tracked.txt' \
           'git -c a=b checkout other' "$(printf '# comment\ngit status')" \
           'echo "git checkout -f is dangerous"' 'command -v git' \
           'GIT_GUARD_ALLOW_DISCARD=1 git checkout -f other' 'bash scripts/x.sh' \
           "$(printf "cat > n.md <<'EOF'\nNever run git checkout -- tracked.txt here.\nEOF")"; do
    check 0 "$c"
  done

  # A staged-only change survives a restore from the index, not a reset from
  # the commit you are on. Untracked files are never at risk.
  git add tracked.txt
  check 0 'git checkout -- tracked.txt'
  check 0 'git restore tracked.txt'
  check 2 'git checkout HEAD -- tracked.txt'
  check 2 'git restore --staged --worktree tracked.txt'
  git reset -q tracked.txt
  echo new > untracked.txt
  check 0 'git restore untracked.txt'
  rm -f untracked.txt

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
  # An env prefix is still that git call.
  check 2 'FOO=1 git checkout -B integration/w3 origin/main'
  check 2 'cd . && env A=b git branch -f integration/w3 HEAD'
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
  # The advertised inline form (#514), scoped to the git call it prefixes.
  check_worktree_steal_env 0 '' 'GIT_GUARD_ALLOW_WORKTREE_STEAL=1 git checkout -B integration/w3 origin/main'
  check_worktree_steal_env 2 '' 'GIT_GUARD_ALLOW_WORKTREE_STEAL=1 git fetch && git checkout -B integration/w3 origin/main'
  check_worktree_steal_env 2 '' 'git checkout -B integration/w3 origin/main # GIT_GUARD_ALLOW_WORKTREE_STEAL=1 git'
) || fail=1
rm -rf "$(dirname "$wt_repo")"

# A parser killed on a real payload fails closed (#524): shim python3 so the
# guard's extraction dies the way an OOM kill does, on a should-block command.
SHIM="$(mktemp -d)"
cat > "$SHIM/python3" <<'SH'
#!/usr/bin/env bash
# Die the way an OOM kill does, whenever the guard runs it.
kill -9 $$
SH
chmod +x "$SHIM/python3"
PAYLOAD='{"tool_name":"Bash","tool_input":{"command":"git push --force origin main"}}'
printf '%s' "$PAYLOAD" | PATH="$SHIM:$PATH" "$GUARD" >/dev/null 2>&1; got=$?
if [ "$got" != 2 ]; then
  echo "FAIL: a killed parser must fail closed (want 2, got $got)"
  echo x >> "$FAIL_MARKER"
fi
rm -rf "$SHIM"

if [ -s "$FAIL_MARKER" ]; then
  echo "git-guard: $(wc -l < "$FAIL_MARKER" | tr -d ' ') case(s) FAILED"
  fail=1
fi

if [ "$fail" = 0 ]; then
  echo "git-guard: all cases passed"
fi
exit "$fail"
