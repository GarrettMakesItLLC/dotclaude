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

# --- --help prints the header only ---
out="$("$REAP" --help)"
grep -q "Usage:" <<<"$out" && ! grep -q "^set -" <<<"$out" && ok "--help prints the usage header" || bad "--help output"

[ "$fail" = 0 ] && echo "worktree-reap: all cases passed"
exit "$fail"
