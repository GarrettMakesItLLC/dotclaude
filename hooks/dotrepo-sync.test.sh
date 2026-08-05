#!/usr/bin/env bash
# Self-test for dotrepo-sync.sh. Builds throwaway bare + clone repo pairs so
# real dotclaude/dotfiles are never touched, and asserts every staleness case
# is handled without ever forcing a change onto a dirty or diverged tree.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HOOK="$HERE/dotrepo-sync.sh"
fail=0

# A bare "remote" plus a clone of it, both throwaway, with git identity set
# so commits work in CI with no global config.
make_pair() {
  local base origin clone
  base="$(mktemp -d)"
  origin="$base/origin.git"
  clone="$base/clone"
  git init --quiet --bare "$origin"
  git clone --quiet "$origin" "$clone"
  git -C "$clone" config user.email test@example.com
  git -C "$clone" config user.name test
  echo one > "$clone/file"
  git -C "$clone" add file
  git -C "$clone" commit --quiet -m one
  git -C "$clone" push --quiet origin "$(git -C "$clone" rev-parse --abbrev-ref HEAD)"
  printf '%s' "$clone"
}

# Push one more commit to the shared remote from a second clone, simulating
# "someone else pushed" without touching the first clone's working tree.
advance_remote() {
  local clone="$1" second
  second="$(mktemp -d)/second"
  git clone --quiet "$(git -C "$clone" remote get-url origin)" "$second"
  git -C "$second" config user.email test@example.com
  git -C "$second" config user.name test
  echo two >> "$second/file"
  git -C "$second" commit --quiet -am two
  git -C "$second" push --quiet origin "HEAD:$(git -C "$clone" rev-parse --abbrev-ref HEAD)"
  rm -rf "$(dirname "$second")"
}

run() { DOTCLAUDE_DIR="$1" DOTFILES_DIR="$2" "$HOOK" 2>/dev/null; }

# --- up to date: silent, exit 0 ---
c1="$(make_pair)"; c2="$(make_pair)"
out="$(run "$c1" "$c2")"; code=$?
[ "$code" = 0 ] || { echo "FAIL: must exit 0 up to date, got $code"; fail=1; }
[ -z "$out" ] || { echo "FAIL: must stay silent up to date, got: $out"; fail=1; }
rm -rf "$(dirname "$c1")" "$(dirname "$c2")"

# --- clean fast-forward: pulls, reports count ---
c1="$(make_pair)"; c2="$(make_pair)"
advance_remote "$c1"
out="$(run "$c1" "$c2")"; code=$?
[ "$code" = 0 ] || { echo "FAIL: must exit 0 on clean pull, got $code"; fail=1; }
printf '%s' "$out" | grep -q 'pulled 1 new commit' \
  || { echo "FAIL: should report pulling 1 commit, got: $out"; fail=1; }
[ "$(git -C "$c1" rev-parse HEAD)" = "$(git -C "$c1" rev-parse '@{u}')" ] \
  || { echo "FAIL: c1 should now be at upstream HEAD"; fail=1; }
rm -rf "$(dirname "$c1")" "$(dirname "$c2")"

# --- behind + dirty tree: reports, does not pull ---
c1="$(make_pair)"; c2="$(make_pair)"
advance_remote "$c1"
echo local-edit >> "$c1/file"
before="$(git -C "$c1" rev-parse HEAD)"
out="$(run "$c1" "$c2")"; code=$?
[ "$code" = 0 ] || { echo "FAIL: must exit 0 when dirty, got $code"; fail=1; }
printf '%s' "$out" | grep -q 'uncommitted' \
  || { echo "FAIL: should report uncommitted local changes, got: $out"; fail=1; }
[ "$(git -C "$c1" rev-parse HEAD)" = "$before" ] \
  || { echo "FAIL: dirty repo must not be pulled"; fail=1; }
rm -rf "$(dirname "$c1")" "$(dirname "$c2")"

# --- diverged (ahead and behind): reports, does not pull ---
c1="$(make_pair)"; c2="$(make_pair)"
advance_remote "$c1"
git -C "$c1" config user.email test@example.com
git -C "$c1" config user.name test
echo local-commit >> "$c1/file"
git -C "$c1" commit --quiet -am local-commit
before="$(git -C "$c1" rev-parse HEAD)"
out="$(run "$c1" "$c2")"; code=$?
[ "$code" = 0 ] || { echo "FAIL: must exit 0 when diverged, got $code"; fail=1; }
printf '%s' "$out" | grep -q 'diverged' \
  || { echo "FAIL: should report diverged history, got: $out"; fail=1; }
[ "$(git -C "$c1" rev-parse HEAD)" = "$before" ] \
  || { echo "FAIL: diverged repo must not be pulled"; fail=1; }
rm -rf "$(dirname "$c1")" "$(dirname "$c2")"

# --- missing directory: silent, exit 0 ---
out="$(run "/nonexistent-dotclaude-$$" "/nonexistent-dotfiles-$$")"; code=$?
[ "$code" = 0 ] || { echo "FAIL: must exit 0 with missing repos, got $code"; fail=1; }
[ -z "$out" ] || { echo "FAIL: must stay silent with missing repos, got: $out"; fail=1; }

if [ "$fail" = 0 ]; then
  echo "dotrepo-sync: all cases passed"
fi
exit "$fail"
