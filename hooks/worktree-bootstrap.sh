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
#
# Matched on the two words in sequence rather than the literal string
# "git worktree add", because a global flag sits between them in the form that
# creates a worktree in ANOTHER repo — `git -C <dir> worktree add …` — which is
# exactly the case #312 is about, and which the substring test never fired on.
case "$command_str" in
  *worktree*add*) ;;
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
# `worktree` immediately followed by `add`, so the loose shell prefilter above
# cannot be satisfied by the two words appearing anywhere in a command — a
# commit message, or `git worktree list && mkdir add`.
pair = next(
    (i for i in range(len(toks) - 1) if toks[i] == "worktree" and toks[i + 1] == "add"),
    None,
)
if pair is None:
    sys.exit(0)
rest = toks[pair + 2:]
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

# The script belongs to the repo the WORKTREE was created in, which is not
# necessarily the session's project (#312). A session whose project is
# MuscleBuddy running `cd ~/workspace/platform && git worktree add …` created a
# platform worktree and then primed it with MuscleBuddy's setup script —
# installing the wrong repo's dependencies into it, or, when MuscleBuddy had a
# script and platform did not, priming a tree that should have been left alone.
#
# Ask git which repo actually owns the new worktree. `--show-toplevel` from
# inside it gives the worktree's own root; `--git-common-dir` resolves to the
# MAIN checkout's `.git`, whose parent is the repo whose `bin/` holds the
# script — a linked worktree does not carry one of its own.
# Falls back to the project dir when git cannot answer — an unusual layout, or
# a target that is not in a repo at all. That is the prior behaviour, so this
# is never worse than before, only better where git does know.
owner_repo="$(git -C "$target" rev-parse --path-format=absolute --git-common-dir 2>/dev/null)"
if [ -n "$owner_repo" ]; then
  owner_repo="$(dirname "$owner_repo")"
else
  owner_repo="$project_dir"
fi
[ -d "$owner_repo" ] || exit 0

script="$owner_repo/bin/setup-worktree.sh"
[ -x "$script" ] || exit 0

# Surface the script's own output to the user; never fail the hook on its exit.
#
# But do NOT swallow the exit code. An install that half-ran leaves a worktree
# that looks usable and is not: with an empty `node_modules`, Node resolution
# and `npx` walk UP the real filesystem past the worktree and bind to the main
# checkout's install instead — so the tree runs, against another checkout's
# dependencies, and the first sign is a phantom type error or a Prisma client
# that does not match the schema in front of you (#175). Nothing about that
# reads as "the install did not happen".
#
# Still exit 0 — this hook must never block a shell — but say so.
if ! "$script" "$target"; then
  rc=$?
  echo "⚠ dotclaude worktree-bootstrap: $script exited $rc for $target." >&2
  echo "  That worktree is primed INCOMPLETELY. An empty node_modules does not fail" >&2
  echo "  loudly — Node resolves upward to the main checkout and the tree runs against" >&2
  echo "  another checkout's dependencies. Re-run the script by hand before trusting a" >&2
  echo "  typecheck, lint or test result from it." >&2
fi
exit 0
