#!/usr/bin/env bash
# Self-test for worktree-reap.sh against throwaway repos with a real bare origin.
# Nothing here touches the caller's repos or ~/.claude.
#   bash bin/worktree-reap.test.sh
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REAP="$HERE/worktree-reap.sh"
fail=0
ok() { echo "ok: $1"; }
bad() { echo "FAIL: $1"; fail=1; }

export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null
# The sweep asks `gh` whether a branch's PR merged; a throwaway repo has no
# GitHub remote, so stub it to fail fast rather than reach the network.
STUBS="$(mktemp -d)"
printf '#!/bin/sh\nexit 1\n' >"$STUBS/gh"
chmod +x "$STUBS/gh"
export PATH="$STUBS:$PATH"
# No fixture runs a long-lived process inside a tree, and the scan costs wall clock.
export WORKTREE_REAP_SKIP_PROC_SCAN=1 WORKTREE_REAP_MIN_AGE_SECS=0 WORKTREE_REAP_MIN_IDLE_SECS=0

ROOTS=("$STUBS")
trap 'rm -rf "${ROOTS[@]}"' EXIT

# make_repo <trunk>: sets REPO to a clone of a bare origin whose trunk is <trunk>.
make_repo() {
  local trunk="$1" root
  root="$(mktemp -d)"
  ROOTS+=("$root")
  git init -q --bare -b "$trunk" "$root/origin.git"
  git clone -q "$root/origin.git" "$root/repo" 2>/dev/null
  REPO="$root/repo"
  git -C "$REPO" checkout -q -b "$trunk" 2>/dev/null
  git -C "$REPO" commit -q --allow-empty -m init
  git -C "$REPO" push -q origin "$trunk" 2>/dev/null
  mkdir -p "$REPO/.worktrees"
}

# finished_tree <name>: a worktree whose branch was merged into the trunk and
# deleted on origin, i.e. exactly what a sweep may reclaim.
finished_tree() {
  local name="$1" trunk
  trunk="$(git -C "$REPO" symbolic-ref --short HEAD)"
  git -C "$REPO" worktree add -q "$REPO/.worktrees/$name" -b "$name" 2>/dev/null
  git -C "$REPO/.worktrees/$name" commit -q --allow-empty -m "work $name"
  git -C "$REPO/.worktrees/$name" push -q origin "$name" 2>/dev/null
  git -C "$REPO" merge -q --ff-only "$name" 2>/dev/null
  git -C "$REPO" push -q origin "$trunk" 2>/dev/null
  git -C "$REPO" push -q origin ":$name" 2>/dev/null
}

sweep() { (cd "$REPO" && "$REAP" "$@" 2>&1); }

# --- a finished, clean tree is reapable; the dry run changes nothing ---
make_repo dev
finished_tree merged
out="$(sweep)"
grep -q "REAP  $REPO/.worktrees/merged" <<<"$out" && [ -d "$REPO/.worktrees/merged" ] \
  && ok "dry run reports a finished tree and leaves it" || bad "dry run: $out"
sweep --apply >/dev/null
[ ! -d "$REPO/.worktrees/merged" ] && ok "--apply removes a finished tree" || bad "finished tree survived --apply"

# --- a registered worktree with uncommitted work is never touched ---
make_repo dev
finished_tree dirty
echo wip >"$REPO/.worktrees/dirty/wip.txt"
out="$(sweep --apply)"
[ -f "$REPO/.worktrees/dirty/wip.txt" ] && grep -q "KEEP  $REPO/.worktrees/dirty — dirty" <<<"$out" \
  && ok "dirty registered tree kept under --apply" || bad "dirty tree: $out"
# The named-path form is the same story: --force is what waives it, nothing else.
out="$(sweep --apply "$REPO/.worktrees/dirty")"
[ -f "$REPO/.worktrees/dirty/wip.txt" ] && ok "dirty tree kept when named without --force" || bad "named dirty tree: $out"

# --- a tree with commits on no remote is kept ---
make_repo dev
git -C "$REPO" worktree add -q "$REPO/.worktrees/ahead" -b ahead 2>/dev/null
echo change >"$REPO/.worktrees/ahead/change.txt"
git -C "$REPO/.worktrees/ahead" add change.txt
git -C "$REPO/.worktrees/ahead" commit -q -m unpushed
out="$(sweep --apply)"
[ -d "$REPO/.worktrees/ahead" ] && ok "unpushed tree kept" || bad "unpushed tree reaped: $out"

# --- a branch still open on origin is kept, and the reason names the trunk ---
make_repo dev
git -C "$REPO" worktree add -q "$REPO/.worktrees/open" -b open 2>/dev/null
git -C "$REPO/.worktrees/open" commit -q --allow-empty -m open
git -C "$REPO/.worktrees/open" push -q origin open 2>/dev/null
out="$(sweep --apply)"
[ -d "$REPO/.worktrees/open" ] && grep -q "not merged into dev" <<<"$out" \
  && ok "open branch kept, judged against dev" || bad "open branch: $out"

# --- a single-tier repo judges against its default branch ---
make_repo main
finished_tree single
out="$(sweep)"
grep -q "REAP  $REPO/.worktrees/single" <<<"$out" \
  && ok "single-tier repo reaps against main" || bad "single-tier: $out"
git -C "$REPO" worktree add -q "$REPO/.worktrees/open" -b open 2>/dev/null
git -C "$REPO/.worktrees/open" commit -q --allow-empty -m open
git -C "$REPO/.worktrees/open" push -q origin open 2>/dev/null
out="$(sweep)"
grep -q "not merged into main" <<<"$out" && ok "reason names main" || bad "main reason: $out"

# --- a tree recently touched is kept even when finished ---
make_repo dev
finished_tree busy
out="$(WORKTREE_REAP_MIN_IDLE_SECS=3600 sweep --apply)"
[ -d "$REPO/.worktrees/busy" ] && grep -q "active" <<<"$out" \
  && ok "recently active tree kept" || bad "active tree: $out"

# --- --force is only for a named path ---
make_repo dev
(cd "$REPO" && "$REAP" --apply --force >/dev/null 2>&1); rc=$?
[ "$rc" = 2 ] && ok "--force without a path is refused" || bad "--force without path exited $rc"

# --- orphan directories: neither registered nor git checkouts ---
age() { find "$1" -exec touch -d '3 days ago' {} +; }
make_repo dev
mkdir -p "$REPO/.worktrees/scratch/sub"
echo x >"$REPO/.worktrees/scratch/sub/file"
age "$REPO/.worktrees/scratch"
out="$(sweep)"
grep -q "REAP  $REPO/.worktrees/scratch — not a git checkout" <<<"$out" && [ -d "$REPO/.worktrees/scratch" ] \
  && ok "git-less directory reported, not removed, in a dry run" || bad "orphan dry run: $out"
out="$(sweep --apply)"
[ ! -d "$REPO/.worktrees/scratch" ] && grep -q "removed $REPO/.worktrees/scratch" <<<"$out" \
  && ok "git-less directory removed with --apply" || bad "orphan --apply: $out"

make_repo dev
mkdir -p "$REPO/.worktrees/fresh"
echo x >"$REPO/.worktrees/fresh/file"
out="$(WORKTREE_REAP_MIN_IDLE_SECS=3600 sweep --apply)"
[ -d "$REPO/.worktrees/fresh" ] && grep -q "KEEP  $REPO/.worktrees/fresh — active" <<<"$out" \
  && ok "recently written orphan kept" || bad "fresh orphan: $out"

make_repo dev
mkdir -p "$REPO/.worktrees/holder/inner"
git init -q "$REPO/.worktrees/holder/inner"
age "$REPO/.worktrees/holder"
out="$(sweep --apply)"
[ -d "$REPO/.worktrees/holder/inner/.git" ] && grep -q "KEEP  $REPO/.worktrees/holder — holds a .git entry" <<<"$out" \
  && ok "directory holding a checkout kept" || bad "nested checkout: $out"

make_repo dev
git -C "$REPO" worktree add -q "$REPO/.worktrees/parent" -b parent 2>/dev/null
mkdir -p "$REPO/.worktrees/nest"
git -C "$REPO" worktree add -q "$REPO/.worktrees/nest/child" -b child 2>/dev/null
git -C "$REPO" worktree list >/dev/null
# `nest` itself has no .git, but a registered worktree lives inside it.
rm -rf "$REPO/.worktrees/nest/child/.git"
age "$REPO/.worktrees/nest"
out="$(sweep --apply)"
[ -d "$REPO/.worktrees/nest" ] && grep -q "KEEP  $REPO/.worktrees/nest" <<<"$out" \
  && ok "directory containing a registered worktree kept" || bad "registered below: $out"

make_repo dev
mkdir -p "$REPO/.worktrees/named"
echo x >"$REPO/.worktrees/named/file"
age "$REPO/.worktrees/named"
sweep --apply named >/dev/null
[ ! -d "$REPO/.worktrees/named" ] && ok "a named orphan directory is removed" || bad "named orphan survived"

make_repo dev
ln -s "$(mktemp -d)" "$REPO/.worktrees/link"
ROOTS+=("$(readlink "$REPO/.worktrees/link")")
echo keep >"$(readlink "$REPO/.worktrees/link")/f"
sweep --apply >/dev/null
[ -f "$(readlink "$REPO/.worktrees/link")/f" ] && ok "symlink target never followed" || bad "symlink target removed"

# --- a path that is neither registered nor under .worktrees is refused ---
make_repo dev
mkdir -p "$REPO/elsewhere"
out="$(sweep --apply "$REPO/elsewhere")"; rc=$?
[ -d "$REPO/elsewhere" ] && [ "$rc" = 2 ] && ok "arbitrary directory refused" || bad "arbitrary dir: rc=$rc $out"

marker="$(bash -c 'source "$1"; printf "%s" "$AGENT_WORKTREE_LOCK_MARKER"' _ "$HERE/lib/agent-worktree-lock.sh")"

# --- helpers for the cases below ---

# with_gh <stub-body> [args...]: a sweep with a stub `gh` whose body is given.
with_gh() {
  local body="$1" d; shift
  d="$(mktemp -d)"; ROOTS+=("$d")
  printf '#!/bin/sh\n%s\n' "$body" >"$d/gh"
  chmod +x "$d/gh"
  (cd "$REPO" && PATH="$d:$PATH" "$REAP" "$@" 2>&1)
}

# squash_shape <name>: a clean tree whose commit is on no remote and not in the
# trunk, the shape a squash merge leaves behind.
squash_shape() {
  git -C "$REPO" worktree add -q "$REPO/.worktrees/$1" -b "$1" 2>/dev/null
  echo work >"$REPO/.worktrees/$1/work.txt"
  git -C "$REPO/.worktrees/$1" add work.txt
  git -C "$REPO/.worktrees/$1" commit -q -m work
}

# --- merged-PR waiver ---
make_repo dev
squash_shape finished
out="$(with_gh 'exit 1')"
grep -Eq "KEEP  .*finished — unpushed" <<<"$out" \
  && ok "gh unable to answer keeps an unpushed tree" || bad "gh failure: $out"
out="$(with_gh "printf ''")"
grep -Eq "KEEP  .*finished — unpushed" <<<"$out" \
  && ok "no merged PR keeps an unpushed tree" || bad "no PR: $out"
out="$(with_gh "printf 'MERGED'")"
grep -q "REAP  $REPO/.worktrees/finished" <<<"$out" \
  && ok "a MERGED pull request releases an unpushed tree" || bad "merged PR: $out"
for state in OPEN CLOSED merged MERGED_SOMETHING; do
  out="$(with_gh "printf '%s' '$state'")"
  grep -Eq "KEEP  .*finished — unpushed" <<<"$out" \
    && ok "PR state $state is not accepted as merged" || bad "state $state: $out"
done
echo scratch >"$REPO/.worktrees/finished/scratch.txt"
out="$(with_gh "printf 'MERGED'")"
grep -Eq "KEEP  .*finished — dirty" <<<"$out" \
  && ok "a dirty tree is kept even when its PR merged" || bad "dirty+merged: $out"

# --- finished-PR-head waiver ---
# folded_shape <contains|unrelated>: commits only reachable from refs/pull/7/head
# while the trunk has since rewritten the same file, so reverse-apply fails.
folded_shape() {
  local wt="$REPO/.worktrees/folded"
  git -C "$REPO" worktree add -q "$wt" -b folded 2>/dev/null
  echo "batch work" >"$wt/work.txt"
  git -C "$wt" add work.txt
  git -C "$wt" commit -q -m "batch work"
  if [ "$1" = contains ]; then
    git -C "$wt" commit -q --allow-empty -m "integration resolution"
    git -C "$wt" push -q origin HEAD:refs/pull/7/head 2>/dev/null
    git -C "$wt" reset -q --hard HEAD~1
  else
    git -C "$REPO" push -q origin dev:refs/pull/7/head 2>/dev/null
  fi
  echo "rewritten by a later wave" >"$REPO/work.txt"
  git -C "$REPO" add work.txt
  git -C "$REPO" commit -q -m "later wave"
  git -C "$REPO" push -q origin dev 2>/dev/null
}
search_gh() { printf 'case "$*" in *--search*) printf "%%s\\n" "%s" ;; esac\nexit 0' "$1"; }

make_repo dev
folded_shape contains
out="$(with_gh "$(search_gh '')")"
grep -Eq "KEEP  .*folded — unpushed" <<<"$out" \
  && ok "no finished PR found keeps a folded tree" || bad "folded, empty search: $out"
out="$(with_gh "$(search_gh 7)")"
grep -q "REAP  $REPO/.worktrees/folded" <<<"$out" && [ -z "$(git -C "$REPO" for-each-ref refs/worktree-reap)" ] \
  && ok "HEAD inside a finished PR head releases it, leaving no scratch ref" || bad "folded, PR 7: $out"
out="$(with_gh "$(search_gh MERGED)")"
grep -Eq "KEEP  .*folded — unpushed" <<<"$out" \
  && ok "a non-numeric search answer keeps the tree" || bad "folded, non-numeric: $out"

make_repo dev
folded_shape unrelated
out="$(with_gh "$(search_gh 7)")"
grep -Eq "KEEP  .*folded — unpushed" <<<"$out" \
  && ok "an unrelated PR head keeps the tree" || bad "folded, unrelated head: $out"

# --- .claude/worktrees, nested at any depth ---
LOCK_REASON="$(bash -c 'source "$1"; printf "%s" "$AGENT_WORKTREE_LOCK_REASON"' _ "$HERE/lib/agent-worktree-lock.sh")"
add_agent_tree() {
  mkdir -p "$(dirname "$REPO/$1")"
  git -C "$REPO" worktree add -q "$REPO/$1" -b "$2" 2>/dev/null
  git -C "$REPO" worktree lock --reason "$LOCK_REASON" "$REPO/$1"
}

make_repo dev
add_agent_tree .claude/worktrees/rma-1/issue-1 issue-1
out="$(sweep)"
grep -q "REAP  $REPO/.claude/worktrees/rma-1/issue-1" <<<"$out" \
  && ok "a .claude/worktrees tree is swept" || bad ".claude/worktrees sweep: $out"

make_repo dev
git -C "$REPO" worktree add -q "$REPO/.worktrees/issue-9" -b issue-9 2>/dev/null
add_agent_tree .worktrees/issue-9/.claude/worktrees/issue-9/issue-10 issue-10
out="$(sweep --apply)"
grep -q "removed $REPO/.worktrees/issue-9/.claude/worktrees/issue-9/issue-10" <<<"$out" \
  && grep -q "removed $REPO/.worktrees/issue-9\$" <<<"$out" && grep -q "2 removed" <<<"$out" \
  && ! git -C "$REPO" worktree list --porcelain | grep -q '.claude/worktrees' \
  && ok "a nested worktree is removed child first, then its parent" || bad "nested: $out"

make_repo dev
add_agent_tree .claude/worktrees/gone/issue-2 issue-2
rm -rf "$REPO/.claude/worktrees/gone/issue-2"
out="$(sweep --apply)"
if grep -q "unlocked so prune can clear its registration" <<<"$out" \
  && ! git -C "$REPO" worktree list --porcelain | grep -q "gone/issue-2" \
  && git -C "$REPO" worktree add -q "$REPO/.worktrees/reuse" issue-2 2>/dev/null; then
  ok "a vanished registration is unlocked and pruned, freeing its branch"
else bad "vanished registration: $out"; fi

make_repo dev
mkdir -p "$REPO/.claude/worktrees/handheld"
git -C "$REPO" worktree add -q "$REPO/.claude/worktrees/handheld/issue-3" -b issue-3 2>/dev/null
git -C "$REPO" worktree lock --reason "hands off, bisecting" "$REPO/.claude/worktrees/handheld/issue-3"
rm -rf "$REPO/.claude/worktrees/handheld/issue-3"
out="$(sweep --apply)"
grep -q "carries a lock this sweep did not place" <<<"$out" \
  && git -C "$REPO" worktree list --porcelain | grep -q "handheld/issue-3" \
  && ok "a hand-locked vanished registration is left alone" || bad "hand-locked vanished: $out"

# --- the /proc cwd scan ---
make_repo dev
finished_tree running
(cd "$REPO/.worktrees/running" && exec sleep 300) &
HOLDER=$!
out="$(cd "$REPO" && env -u WORKTREE_REAP_SKIP_PROC_SCAN "$REAP" 2>&1)"
grep -q "KEEP  $REPO/.worktrees/running — in use — pid $HOLDER" <<<"$out" \
  && ok "a tree with a live process cwd is kept, naming the pid" || bad "in use: $out"
out="$(cd "$REPO" && env -u WORKTREE_REAP_SKIP_PROC_SCAN "$REAP" --apply --force "$REPO/.worktrees/running" 2>&1)"
[ -d "$REPO/.worktrees/running" ] \
  && ok "--force does not waive an in-use tree" || bad "force removed an in-use tree: $out"
kill "$HOLDER" 2>/dev/null; wait "$HOLDER" 2>/dev/null
out="$(cd "$REPO" && env -u WORKTREE_REAP_SKIP_PROC_SCAN "$REAP" 2>&1)"
grep -q "REAP  $REPO/.worktrees/running" <<<"$out" \
  && ok "the same tree is reapable once the process exits" || bad "after exit: $out"

TDIR="$(mktemp -d)"; ROOTS+=("$TDIR")
printf '#!/bin/sh\nprintf "%%s\\n" "$*" >> "%s/calls.log"\nexec "%s" "$@"\n' "$TDIR" "$(command -v timeout)" >"$TDIR/timeout"
chmod +x "$TDIR/timeout"
(cd "$REPO" && PATH="$TDIR:$PATH" "$REAP" >/dev/null 2>&1)
grep -q readlink "$TDIR/calls.log" 2>/dev/null && bad "scan ran despite WORKTREE_REAP_SKIP_PROC_SCAN=1" \
  || ok "WORKTREE_REAP_SKIP_PROC_SCAN=1 bypasses the scan outright"
(cd "$REPO" && env -u WORKTREE_REAP_SKIP_PROC_SCAN PATH="$TDIR:$PATH" "$REAP" >/dev/null 2>&1)
grep -q readlink "$TDIR/calls.log" 2>/dev/null \
  && ok "the scan runs when the skip is not set" || bad "scan did not run"

# --- the starting-up floor ---
# A claim branch is created AT the trunk's head, so before its first commit it
# reads as already merged; only age separates it from an abandoned empty tree.
aged() { local age="$1"; shift; (cd "$REPO" && WORKTREE_REAP_MIN_AGE_SECS="$age" "$REAP" "$@" 2>&1); }
make_repo dev
git -C "$REPO" worktree add -q "$REPO/.worktrees/starting-up" -b starting-up 2>/dev/null
git -C "$REPO" push -q origin starting-up 2>/dev/null
git -C "$REPO" fetch -q origin
out="$(aged 900 --apply)"
grep -q "KEEP  $REPO/.worktrees/starting-up" <<<"$out" && grep -q "starting up" <<<"$out" \
  && git -C "$REPO" worktree list | grep -q "starting-up" \
  && ok "a just-created tree with no commits is kept" || bad "starting up: $out"
out="$(aged 0)"
grep -q "REAP  $REPO/.worktrees/starting-up" <<<"$out" \
  && ok "the same tree is reapable once past the floor" || bad "past floor: $out"
aged 0 --apply >/dev/null
git -C "$REPO" worktree list | grep -q "starting-up" \
  && bad "abandoned empty tree survived --apply" || ok "an abandoned empty tree is removed"

make_repo dev
git -C "$REPO" worktree add -q "$REPO/.worktrees/clean-pushed" -b clean-pushed 2>/dev/null
git -C "$REPO" push -q origin clean-pushed 2>/dev/null
git -C "$REPO" fetch -q origin
out="$(sweep --apply)"
git -C "$REPO" worktree list | grep -q "clean-pushed" \
  && bad "a merged, clean, pushed tree survived: $out" || ok "a merged, clean, pushed tree is removed"

# --- the idle floor ---
# live_looking <name>: clean, pushed, merged into the trunk, nothing running in
# it; the shape of a live agent between two commands.
live_looking() {
  local wt="$REPO/.worktrees/$1"
  git -C "$REPO" worktree add -q "$wt" -b "$1" 2>/dev/null
  echo work >"$wt/f.txt"
  git -C "$wt" add -A
  git -C "$wt" commit -q -m work
  git -C "$wt" push -q -u origin "$1" 2>/dev/null
  git -C "$REPO" fetch -q origin
  git -C "$REPO" merge -q --ff-only "$1" 2>/dev/null
  git -C "$REPO" push -q origin dev 2>/dev/null
  git -C "$REPO" fetch -q --prune origin
}
backdate() {
  local admin f
  admin="$(git -C "$1" rev-parse --absolute-git-dir)"
  for f in "$admin" "$admin/logs/HEAD" "$admin/index"; do [ -e "$f" ] && touch -d '2 hours ago' "$f"; done
}
idle() { (cd "$REPO" && WORKTREE_REAP_MIN_IDLE_SECS=3600 "$REAP" "$@" 2>&1); }

make_repo dev
live_looking live
out="$(idle)"
grep -Eq "KEEP  $REPO/.worktrees/live — active [0-9]+s ago" <<<"$out" \
  && ok "a recently touched tree is kept however finished it looks" || bad "idle floor: $out"
backdate "$REPO/.worktrees/live"
out="$(idle)"
grep -q "REAP  $REPO/.worktrees/live" <<<"$out" \
  && ok "the idle floor is not a blanket refusal: a quiet tree is reapable" || bad "quiet tree: $out"
out="$(idle)"
grep -q "REAP  $REPO/.worktrees/live" <<<"$out" \
  && ok "a second sweep does not read its own footprint as activity" || bad "second sweep: $out"

make_repo dev
live_looking named
out="$(idle --apply "$REPO/.worktrees/named")"
grep -q "removed $REPO/.worktrees/named" <<<"$out" \
  && ok "an explicitly named path skips the idle floor" || bad "named, idle: $out"

# --- a vanished trunk tracking ref is recorded, then restored by the fetch ---
make_repo dev
git -C "$REPO" update-ref -d refs/remotes/origin/dev
out="$(sweep)"
grep -q "refs/remotes/origin/dev was missing" <<<"$out" \
  && grep -q "refs/remotes/origin/dev missing at sweep start" "$REPO/.git/origin-trunk-vanished.log" \
  && git -C "$REPO" rev-parse --verify -q refs/remotes/origin/dev >/dev/null \
  && ok "a vanished origin/dev is logged and restored" || bad "vanished ref: $out"
make_repo dev
out="$(sweep)"
! grep -q "was missing" <<<"$out" && [ ! -e "$REPO/.git/origin-trunk-vanished.log" ] \
  && ok "silent when the trunk ref is present" || bad "spurious vanished report: $out"

# --- the lock text is written once and matched everywhere it is sourced ---
# The reason dotclaude's setup-worktree.sh applies comes from a repo's manifest
# `worktree.lockWorktree`; every such value shipped here must contain the marker
# the reaper matches, or its own trees read as hand-locked and the sweep stalls.
ROOT_DIR="$(cd "$HERE/.." && pwd)"
grep -q 'manifest_get worktree.lockWorktree' "$ROOT_DIR/bin/setup-worktree.sh" \
  && grep -q 'worktree lock --reason "$reason"' "$ROOT_DIR/bin/setup-worktree.sh" \
  && ok "setup-worktree.sh locks with the manifest's lockWorktree" || bad "setup-worktree.sh no longer locks from the manifest"
checked=0
while IFS= read -r f; do
  while IFS= read -r val; do
    checked=$((checked + 1))
    [[ "$val" == *"$marker"* ]] || bad "$f: lockWorktree \"$val\" lacks the reaper's marker \"$marker\""
  done < <(sed -n 's/.*"lockWorktree": *"\([^"]*\)".*/\1/p' "$ROOT_DIR/$f")
done < <(git -C "$ROOT_DIR" ls-files | grep -v '\.test\.sh$' | grep -E '\.(md|json|sh)$')
[ "$checked" -ge 1 ] && ok "every shipped lockWorktree value ($checked) contains the marker" || bad "no lockWorktree value found to check"

# --- the lock reason documented for repo.json is the one the reaper owns ---
reason="$(bash -c 'source "$1"; printf "%s" "$AGENT_WORKTREE_LOCK_REASON"' _ "$HERE/lib/agent-worktree-lock.sh")"
marker="$(bash -c 'source "$1"; printf "%s" "$AGENT_WORKTREE_LOCK_MARKER"' _ "$HERE/lib/agent-worktree-lock.sh")"
grep -qF "\"lockWorktree\": \"$reason\"" "$HERE/../docs/repo-manifest.md" \
  && ok "docs/repo-manifest.md carries the reaper's lock reason" || bad "manifest doc lock reason drifted from lib"
[[ "$reason" == *"$marker"* ]] && ok "the marker is a substring of the reason" || bad "marker not in reason"

# --- a hand-placed lock outranks everything; the reaper's own lock does not ---
make_repo dev
finished_tree own
git -C "$REPO" worktree lock --reason "$reason" "$REPO/.worktrees/own"
finished_tree hand
git -C "$REPO" worktree lock --reason "hands off" "$REPO/.worktrees/hand"
sweep --apply >/dev/null
[ ! -d "$REPO/.worktrees/own" ] && [ -d "$REPO/.worktrees/hand" ] \
  && ok "own lock reaped, hand lock kept" || bad "lock handling: own=$([ -d "$REPO/.worktrees/own" ] && echo kept) hand=$([ -d "$REPO/.worktrees/hand" ] && echo kept)"

# --- an unanswerable unpushed count reads as unpushed, never as zero ---
fn="$(sed -n '/^unpushed_count() {/,/^}/p' "$REAP")"
grep -q '|| echo unknown' <<<"$fn" && ! grep -q '|| echo 0' <<<"$fn" \
  && ok "unpushed_count fails closed" || bad "unpushed_count must print unknown on error"

# --- --help prints the header only ---
out="$("$REAP" --help)"
grep -q "Usage:" <<<"$out" && ! grep -q "^set -" <<<"$out" && ok "--help prints the usage header" || bad "--help output"

[ "$fail" = 0 ] && echo "worktree-reap: all cases passed"
exit "$fail"
