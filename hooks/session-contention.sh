#!/usr/bin/env bash
# SessionStart hook: say what this box is already carrying, before the session
# adds to it.
#
# The cheapest lever against check contention is fewer simultaneous sessions, and
# nothing reported the count — so a session started at 15 linked worktrees and
# load 29 looked exactly like one started on an idle box, right up until its unit
# tests timed out in files its diff never touched. `work_in_flight` shows what is
# claimed on the remote; this shows what is running on the metal.
#
# Reporting only. The semaphore in `bin/with-check-lock.sh` is what actually
# bounds the box; a session that has to start anyway should start, and this makes
# the cost visible rather than deciding for anyone.
#
# ALWAYS exits 0 — a stat line must never block a session.
set -uo pipefail

repo_dir="${CLAUDE_PROJECT_DIR:-$PWD}"

# One worktree per concurrent session, roughly: the main checkout plus one per
# claimed issue. `git worktree list` prints the main tree first.
worktrees="$(git -C "$repo_dir" worktree list 2>/dev/null | wc -l)" || exit 0
[ "$worktrees" -gt 0 ] || exit 0
linked=$((worktrees - 1))

cores="$(nproc 2>/dev/null || echo 4)"
load="$(awk '{print $1}' /proc/loadavg 2>/dev/null || echo 0)"
load_int="$(awk '{print int($1)}' /proc/loadavg 2>/dev/null || echo 0)"

# Both thresholds are the measured peak scaled back: 15 worktrees at load 29-30
# on 8 cores was where checks started failing on timeouts rather than on code.
busy=0
[ "$linked" -ge 6 ] && busy=1
[ "$load_int" -gt $((cores * 2)) ] && busy=1

if [ "$busy" -eq 1 ]; then
  cat <<EOF
⚠️  This box is already busy: $linked linked worktrees, load $load on $cores cores.
    Checks here will queue, and above load $((cores * 2)) the check semaphore
    narrows to one holder — expect a push to take minutes. Prefer finishing or
    releasing an existing claim to starting another in parallel.
EOF
else
  echo "🟢 Box is quiet: $linked linked worktrees, load $load on $cores cores."
fi

exit 0
