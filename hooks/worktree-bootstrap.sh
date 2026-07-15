#!/usr/bin/env bash
# dotclaude worktree-bootstrap — PostToolUse hook (matcher: Bash).
#
# The COMPLEMENT to worktree-guard.sh: the guard FORCES agents into an isolated
# `.worktrees/` checkout, but a fresh worktree has no `.env.local`, no generated
# Prisma client, etc. — so the agent's very first typecheck/lint/test fails on a
# missing environment instead of on real code. This hook primes it.
#
# Fires after every Bash call, cheaply no-ops unless the command was a
# `git worktree add`, and on a match runs the repo's `bin/setup-worktree.sh`
# against the new worktree IF that script exists. The trigger is repo-agnostic;
# the priming logic is per-repo and lives in that script. No script -> no-op, so
# this hook is inert in every repo that hasn't opted in.
#
# Fail-open by design: no python3, unparseable input, no match, or any error
# exits 0 and stays silent. A bootstrap hook that blocks a shell is far worse
# than one that occasionally misses — `bin/setup-worktree.sh` is always runnable
# by hand as the fallback.
set -uo pipefail

input="$(cat)"

# Need python3 to parse the payload; without it, fail open.
command -v python3 >/dev/null 2>&1 || exit 0

# Pull the command string out of the PostToolUse payload.
command_str="$(printf '%s' "$input" | python3 -c '
import json, sys
try:
    print(json.load(sys.stdin).get("tool_input", {}).get("command", ""))
except Exception:
    print("")
' 2>/dev/null)" || exit 0

# Only care about `git worktree add`. Anything else: silent no-op.
case "$command_str" in
  *"git worktree add"*) ;;
  *) exit 0 ;;
esac

# Extract the target path: the first non-flag token after `add`. Handles both
# `git worktree add <path> -b <branch>` and `git worktree add -b <branch> <path>`.
target="$(printf '%s' "$command_str" | python3 -c '
import shlex, sys
try:
    toks = shlex.split(sys.stdin.read())
except Exception:
    sys.exit(0)
if "add" not in toks:
    sys.exit(0)
rest = toks[toks.index("add") + 1:]
skip_next = False
flags_with_arg = {"-b", "-B", "--reason", "--lock"}
for t in rest:
    if skip_next:
        skip_next = False
        continue
    if t in flags_with_arg:
        skip_next = True
        continue
    if t.startswith("-"):
        continue
    print(t)
    break
' 2>/dev/null)" || exit 0

[ -z "$target" ] && exit 0

# Resolve relative to the project dir the hook ran in.
project_dir="${CLAUDE_PROJECT_DIR:-$PWD}"
case "$target" in
  /*) ;;
  *) target="$project_dir/$target" ;;
esac
[ -d "$target" ] || exit 0

script="$project_dir/bin/setup-worktree.sh"
[ -x "$script" ] || exit 0

# Surface the script's own output to the user; never fail the hook on its exit.
"$script" "$target" || true
exit 0
