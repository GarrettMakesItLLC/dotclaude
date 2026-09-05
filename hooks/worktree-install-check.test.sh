#!/usr/bin/env bash
# Self-test for worktree-install-check.sh. Builds throwaway repos so the real
# ones are never touched, and runs the hook from a chosen cwd — the verdict
# depends entirely on where it runs, so every case sets that explicitly (#269).
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HOOK="$HERE/worktree-install-check.sh"
fail=0

export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t

# A repo with a setup script, an install in the main tree, and one worktree.
make_repo() {
  local base main
  base="$(mktemp -d)"
  main="$base/main"
  git init -q "$main"
  git -C "$main" commit -q --allow-empty -m init
  mkdir -p "$main/bin"
  printf '#!/bin/sh\nexit 0\n' > "$main/bin/setup-worktree.sh"
  chmod +x "$main/bin/setup-worktree.sh"
  mkdir -p "$main/node_modules/react" "$main/node_modules/.bin"
  git -C "$main" worktree add -q "$base/wt" -b feat
  printf '%s' "$base"
}

# want: "quiet" (no output) or "warn" (says something)
run_in() {
  local dir="$1" out
  out="$(cd "$dir" && "$HOOK" 2>/dev/null)"
  printf '%s' "$out"
}

expect() {
  local want="$1" dir="$2" label="$3" out
  out="$(run_in "$dir")"
  if [ "$want" = quiet ] && [ -n "$out" ]; then
    echo "FAIL($label): expected silence, got: $out"; fail=1
  elif [ "$want" = warn ] && [ -z "$out" ]; then
    echo "FAIL($label): expected a warning, got silence"; fail=1
  fi
}

# --- an unprimed worktree beside a primed main tree: warns ------------------
base="$(make_repo)"
expect warn "$base/wt" "unprimed worktree"
# The message must name both trees and the remedy, or it is not actionable.
out="$(run_in "$base/wt")"
for needle in "$base/wt" "$base/main" "setup-worktree.sh" "resolve"; do
  printf '%s' "$out" | grep -q -- "$needle" \
    || { echo "FAIL(message): should mention '$needle', got: $out"; fail=1; }
done
rm -rf "$base"

# --- the same worktree, once primed: silent ---------------------------------
base="$(make_repo)"
mkdir -p "$base/wt/node_modules/react"
expect quiet "$base/wt" "primed worktree"
rm -rf "$base"

# --- node_modules present but holding only npm's dot-dirs: still warns ------
# This is the exact shape the reported tree had — 632K of cache directories and
# zero packages — and it is why the check counts packages, not the directory.
base="$(make_repo)"
mkdir -p "$base/wt/node_modules/.vite-temp" "$base/wt/node_modules/.bin"
expect warn "$base/wt" "dot-dirs only"
rm -rf "$base"

# --- the main working tree itself: nothing to compare against ---------------
base="$(make_repo)"
expect quiet "$base/main" "main tree"
rm -rf "$base"

# --- a repo that does not opt into priming: not this hook's business --------
base="$(make_repo)"
rm -f "$base/main/bin/setup-worktree.sh"
expect quiet "$base/wt" "no setup script"
rm -rf "$base"

# --- the main tree has no install either: a different problem ---------------
# Silent, because this cannot tell "not a node repo" from "nobody has installed
# anything yet", and warning on both would train the warning away.
base="$(make_repo)"
rm -rf "$base/main/node_modules"
expect quiet "$base/wt" "main uninstalled"
rm -rf "$base"

# --- not a git repo at all --------------------------------------------------
outside="$(mktemp -d)"
expect quiet "$outside" "outside a repo"
rm -rf "$outside"

if [ "$fail" = 0 ]; then
  echo "worktree-install-check: all cases passed"
fi
exit "$fail"
