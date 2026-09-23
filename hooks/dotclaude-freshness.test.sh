#!/usr/bin/env bash
# Self-test for dotclaude-freshness.sh. Builds throwaway bare + clone repo
# pairs so the real ~/dotclaude is never touched, and asserts: silent when on
# main and current, a one-line warning off main (no network needed), a
# one-line warning when behind main by more than the threshold, silence
# within the threshold, and that a warm cache skips the fetch entirely.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HOOK="$HERE/dotclaude-freshness.sh"
fail=0

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# A bare "remote" plus a clone of it, main-branched, with git identity set so
# commits work in CI with no global config.
make_pair() {
  local base origin clone
  base="$(mktemp -d -p "$TMP")"
  origin="$base/origin.git"
  clone="$base/clone"
  # Named explicitly: the bare repo's HEAD decides what a later clone checks
  # out, and `init.defaultBranch` is `master` on a stock runner.
  git init --quiet --bare --initial-branch=main "$origin"
  git clone --quiet "$origin" "$clone"
  git -C "$clone" config user.email test@example.com
  git -C "$clone" config user.name test
  git -C "$clone" checkout --quiet -b main
  echo one > "$clone/file"
  git -C "$clone" add file
  git -C "$clone" commit --quiet -m one
  git -C "$clone" push --quiet -u origin main
  printf '%s' "$clone"
}

# Push N more commits to the shared remote from a second clone, simulating
# "the remote moved on" without touching the first clone's working tree.
advance_remote() {
  local clone="$1" n="$2" second i
  second="$(mktemp -d -p "$TMP")/second"
  git clone --quiet "$(git -C "$clone" remote get-url origin)" "$second"
  git -C "$second" config user.email test@example.com
  git -C "$second" config user.name test
  for ((i = 0; i < n; i++)); do
    echo "line $i" >> "$second/file"
    git -C "$second" commit --quiet -am "advance $i"
  done
  git -C "$second" push --quiet origin main
  rm -rf "$(dirname "$second")"
}

run() {
  local dir="$1" cache="$TMP/cache-$RANDOM"
  shift
  DOTCLAUDE_DIR="$dir" \
    DOTCLAUDE_FRESHNESS_CACHE_DIR="$cache" \
    DOTCLAUDE_FRESHNESS_BEHIND_THRESHOLD="${THRESHOLD:-5}" \
    DOTCLAUDE_FRESHNESS_TTL="${TTL_OVERRIDE:-1800}" \
    "$@" "$HOOK" 2>&1
}

echo "dotclaude-freshness: on main, up to date — silent"
c="$(make_pair)"
out="$(run "$c")"; code=$?
[ "$code" = 0 ] || { echo "FAIL: must exit 0, got $code"; fail=1; }
[ -z "$out" ] || { echo "FAIL: must stay silent when current, got: $out"; fail=1; }

echo "dotclaude-freshness: on main, behind past the threshold — warns"
advance_remote "$c" 7
out="$(THRESHOLD=5 run "$c")"; code=$?
[ "$code" = 0 ] || { echo "FAIL: must exit 0 even when warning, got $code"; fail=1; }
grep -q '7 commit(s) behind' <<<"$out" \
  || { echo "FAIL: should name the count, got: $out"; fail=1; }
grep -q 'pull --ff-only' <<<"$out" \
  || { echo "FAIL: should name the fix command, got: $out"; fail=1; }

echo "dotclaude-freshness: behind, but within the threshold — silent"
c2="$(make_pair)"
advance_remote "$c2" 3
out="$(THRESHOLD=5 run "$c2")"; code=$?
[ "$code" = 0 ] || { echo "FAIL: must exit 0, got $code"; fail=1; }
[ -z "$out" ] || { echo "FAIL: must stay silent within the threshold, got: $out"; fail=1; }

echo "dotclaude-freshness: not on main — warns without touching the network"
c3="$(make_pair)"
git -C "$c3" checkout --quiet -b fix/some-branch
# No origin reachable at all — a bogus URL — so any attempt to fetch would
# fail loudly. The "not on main" check must never need it.
git -C "$c3" remote set-url origin "file:///nonexistent/$RANDOM"
out="$(run "$c3")"; code=$?
[ "$code" = 0 ] || { echo "FAIL: must exit 0, got $code"; fail=1; }
grep -q 'fix/some-branch, not main' <<<"$out" \
  || { echo "FAIL: should name the branch, got: $out"; fail=1; }

echo "dotclaude-freshness: a detached HEAD is reported as such"
c4="$(make_pair)"
git -C "$c4" checkout --quiet --detach HEAD
out="$(run "$c4")"; code=$?
[ "$code" = 0 ] || { echo "FAIL: must exit 0, got $code"; fail=1; }
grep -q 'detached HEAD, not main' <<<"$out" \
  || { echo "FAIL: should say detached HEAD, got: $out"; fail=1; }

echo "dotclaude-freshness: a warm cache never fetches again within the TTL"
c5="$(make_pair)"
advance_remote "$c5" 9
cache5="$TMP/cache-warm"
DOTCLAUDE_DIR="$c5" DOTCLAUDE_FRESHNESS_CACHE_DIR="$cache5" \
  DOTCLAUDE_FRESHNESS_BEHIND_THRESHOLD=5 DOTCLAUDE_FRESHNESS_TTL=1800 \
  "$HOOK" >/dev/null 2>&1
first_fetch_head="$(git -C "$c5" rev-parse 'refs/remotes/origin/main')"
# Move the remote again — a fresh fetch inside the TTL would see it; a cached
# read must not.
advance_remote "$c5" 2
out="$(DOTCLAUDE_DIR="$c5" DOTCLAUDE_FRESHNESS_CACHE_DIR="$cache5" \
  DOTCLAUDE_FRESHNESS_BEHIND_THRESHOLD=5 DOTCLAUDE_FRESHNESS_TTL=1800 \
  "$HOOK" 2>&1)"; code=$?
[ "$code" = 0 ] || { echo "FAIL: must exit 0, got $code"; fail=1; }
grep -q '9 commit(s) behind' <<<"$out" \
  || { echo "FAIL: warm cache should still report the ORIGINAL count (9), got: $out"; fail=1; }
[ "$(git -C "$c5" rev-parse 'refs/remotes/origin/main')" = "$first_fetch_head" ] \
  || { echo "FAIL: a warm-cache run must not have fetched again"; fail=1; }

echo "dotclaude-freshness: no ~/dotclaude checkout at all — silent"
out="$(run "$TMP/does-not-exist")"; code=$?
[ "$code" = 0 ] || { echo "FAIL: must exit 0, got $code"; fail=1; }
[ -z "$out" ] || { echo "FAIL: must stay silent with no checkout, got: $out"; fail=1; }

if [ "$fail" = 0 ]; then
  echo "dotclaude-freshness: all cases passed"
fi
exit "$fail"
