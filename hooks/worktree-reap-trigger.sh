#!/usr/bin/env bash
# SessionStart hook: give `bin/worktree-reap.sh` the trigger it never had.
#
# The reaper was correct and fired only when a human remembered
# it, so dead worktrees accumulated in the only direction they can: 113 reapable
# out of 135, 62 GB, over a week old. Nothing was wrong with the sweep — nothing
# ran it.
#
# A GitHub Actions schedule cannot be that trigger. Worktrees are directories on
# this box; a runner has no view of them. The only place with both the trees and
# a regular heartbeat is a session starting on the machine that made them.
#
# Three properties make an automatic sweep safe to arm, and none of them is the
# sweep's own liveness logic — that is `bin/worktree-reap.sh`'s, unchanged here,
# and every check in it fails closed (dirty, unpushed-and-unmerged, in use,
# foreign lock, too young). This hook adds only the parts that come from being
# automatic:
#
#   - It never passes `--force` and never names a path. Both are the escape
#     hatches that waive "dirty" and "unpushed", and both exist for a person
#     asserting something about ONE tree. A sweep gets the safe form or nothing.
#   - One sweep at a time, box-wide, via a non-blocking `flock`. Twenty sessions
#     starting together would otherwise run twenty concurrent sweeps over the
#     same trees, each judging a tree another is mid-`git worktree remove` on.
#     Losing the lock is a no-op, not a wait: this is a background chore.
#   - Throttled to one run per `WORKTREE_REAP_INTERVAL_SECS` (default 6h) against a
#     stamp in the shared git dir, so the cost lands a few times a day rather
#     than on every session start.
#
# It DETACHES. The sweep fetches, then reverse-applies each branch's patch and
# reads /proc for cwds — tens of seconds to minutes across 100+ trees, and a
# SessionStart hook that blocks for that is a worse defect than the one it fixes.
# The run logs to `$git_common_dir/worktree-reap.log`, which is where to look for
# what a sweep decided; this hook's own output is the one line saying it started.
#
# ALWAYS exits 0. Reclaiming disk must never block a session.
set -uo pipefail

repo_dir="${CLAUDE_PROJECT_DIR:-$PWD}"

# dotclaude's reaper, resolved from this hook's own path so it is found whichever
# repo the session is in.
self="$(readlink -f "${BASH_SOURCE[0]}")" || exit 0
reaper="$(dirname "$(dirname "$self")")/bin/worktree-reap.sh"
[ -x "$reaper" ] || exit 0

common_dir="$(git -C "$repo_dir" rev-parse --path-format=absolute --git-common-dir 2>/dev/null)" || exit 0
[ -n "$common_dir" ] || exit 0
main_tree="$(dirname "$common_dir")"

# Inert in a repo that does not keep worktrees under `.worktrees/`: the sweep
# would have nothing to judge, and a fetch there is a cost for no benefit.
[ -d "$main_tree/.worktrees" ] || exit 0

# `WORKTREE_REAP_TRIGGER_OFF=1` disables the sweep without editing settings.json —
# the escape hatch a box under an unusual workload needs, and the one a debugging
# session reaches for instead of deleting the hook.
[ "${WORKTREE_REAP_TRIGGER_OFF:-0}" = "1" ] && exit 0

stamp="$common_dir/worktree-reap.stamp"
log="$common_dir/worktree-reap.log"
lock="$common_dir/worktree-reap.lock"
interval="${WORKTREE_REAP_INTERVAL_SECS:-21600}"

now="$(date +%s)"
if [ -f "$stamp" ]; then
  last="$(cat "$stamp" 2>/dev/null || echo 0)"
  case "$last" in
    '' | *[!0-9]*) last=0 ;;
  esac
  if [ $((now - last)) -lt "$interval" ]; then exit 0; fi
fi

command -v flock >/dev/null 2>&1 || exit 0

# The stamp is written by the sweep's own subshell AFTER it takes the lock, so a
# session that loses the race does not mark the interval as spent on a sweep that
# never ran.
(
  exec 9>"$lock"
  flock -n 9 || exit 0
  date +%s > "$stamp"
  {
    echo "── $(date -Is) sweep started by SessionStart hook"
    (cd "$main_tree" && "$reaper" --apply)
    echo "── exit $?"
  } >> "$log" 2>&1
) </dev/null >/dev/null 2>&1 &
disown 2>/dev/null || true

echo "🧹 worktree-reap: sweeping dead worktrees in the background — see $log"
exit 0
