#!/usr/bin/env bash
# Self-test for link-doctor.sh. Points the hook at a throwaway HOME so the real
# ~/.claude is never touched, and asserts (a) it exits 0 in every case, (b) it is
# silent when links are healthy, and (c) it names the broken ones when they are
# not. Run locally or in CI:
#   bash hooks/link-doctor.test.sh
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HOOK="$HERE/link-doctor.sh"
# The main checkout, which is what bootstrap targets even when this test runs from
# a linked worktree — links built against the worktree would read as drift.
REPO="$(dirname "$HERE")"
if common="$(git -C "$REPO" rev-parse --path-format=absolute --git-common-dir 2>/dev/null)"; then
  common="${common%/.git}"
  [ -n "$common" ] && [ -f "$common/bootstrap.sh" ] && REPO="$common"
fi
fail=0

# Everything bootstrap links whole, read from bootstrap.sh itself — a hardcoded
# copy here leaves the fixture reporting drift the moment a shared file or
# directory is added, which reads as a failure of the case under test.
shared_names() {
  awk '/^SHARED_(FILES|DIRS)=\(/ {inside = 1; next} inside && /^\)/ {inside = 0} inside' \
    "$REPO/bootstrap.sh" | sed -n 's/^[[:space:]]*"\([^"]*\)".*/\1/p'
}

# A fake HOME whose ~/.claude is linked to the real repo, minus whatever the
# caller asks to leave unlinked.
make_home() {
  local skip="${1:-}" h name
  h="$(mktemp -d)"
  mkdir -p "$h/.claude/skills"
  for name in $(shared_names); do
    [ -e "$REPO/$name" ] || continue
    ln -s "$REPO/$name" "$h/.claude/$name"
  done
  for name in "$REPO"/skills/*; do
    [ -d "$name" ] || continue
    [ "$(basename "$name")" = "$skip" ] && continue
    ln -s "$name" "$h/.claude/skills/$(basename "$name")"
  done
  printf '%s' "$h"
}

run() { HOME="$1" "$HOOK" 2>/dev/null; }

# --- healthy: silent, exit 0 ---
h="$(make_home)"
out="$(run "$h")"; code=$?
[ "$code" = 0 ] || { echo "FAIL: must exit 0 when healthy, got $code"; fail=1; }
[ -z "$out" ] || { echo "FAIL: must stay silent when healthy, got: $out"; fail=1; }
rm -rf "$h"

# --- drift: reports the unlinked skill and the fix command, still exit 0 ---
skill="$(basename "$(find "$REPO/skills" -mindepth 1 -maxdepth 1 -type d | head -1)")"
h="$(make_home "$skill")"
out="$(run "$h")"; code=$?
[ "$code" = 0 ] || { echo "FAIL: must exit 0 on drift, got $code"; fail=1; }
printf '%s' "$out" | grep -q "skills/$skill" \
  || { echo "FAIL: drift report should name skills/$skill, got: $out"; fail=1; }
printf '%s' "$out" | grep -q 'bootstrap.sh' \
  || { echo "FAIL: drift report should carry the fix command"; fail=1; }
printf '%s' "$out" | grep -q '"hookEventName": "SessionStart"' \
  || { echo "FAIL: output should be a SessionStart hook payload"; fail=1; }
# The ✓ lines are noise and must not be forwarded.
printf '%s' "$out" | grep -q '✓' \
  && { echo "FAIL: healthy links should not appear in the drift report"; fail=1; }
rm -rf "$h"

# --- no repo reachable: silent, exit 0 (never blocks a session start) ---
h="$(mktemp -d)"
out="$(run "$h")"; code=$?
[ "$code" = 0 ] || { echo "FAIL: must exit 0 with no repo, got $code"; fail=1; }
[ -z "$out" ] || { echo "FAIL: must stay silent with no repo, got: $out"; fail=1; }
rm -rf "$h"

if [ "$fail" = 0 ]; then
  echo "link-doctor: all cases passed"
fi
exit "$fail"
