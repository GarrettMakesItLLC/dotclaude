#!/usr/bin/env bash
# dotclaude worktree-install-check — SessionStart hook.
#
# `worktree-bootstrap.sh` primes a worktree by watching for `git worktree add`
# in a Bash call. A worktree the HARNESS creates — `.claude/worktrees/agent-*`
# for a dispatched agent — never passes through a Bash call, so the hook never
# fires and the tree is never primed. Nothing announces that.
#
# It matters because an empty `node_modules` does not fail; it resolves. Node
# and `npx` walk UP the real filesystem past the worktree and bind to the main
# checkout's install, so the tree runs against another checkout's dependencies
# and the first symptom is a phantom type error or a Prisma client that does not
# match the schema in front of you. The session that hit this ran for a while
# before anyone thought to look at `node_modules` (#175).
#
# Reports; never blocks. Fail-open on everything: not a worktree, no git, no
# python3, a repo that has no install to speak of -> silent, exit 0.
set -uo pipefail

exit_quiet() { exit 0; }

command -v git >/dev/null 2>&1 || exit_quiet
[ "$(git rev-parse --is-inside-work-tree 2>/dev/null)" = "true" ] || exit_quiet

gitdir="$(git rev-parse --absolute-git-dir 2>/dev/null)" || exit_quiet
common="$(git rev-parse --path-format=absolute --git-common-dir 2>/dev/null)" || exit_quiet
[ -n "$gitdir" ] && [ -n "$common" ] || exit_quiet
# Same dir means this IS the main working tree — nothing to compare against.
[ "$gitdir" != "$common" ] || exit_quiet

here="$(git rev-parse --show-toplevel 2>/dev/null)" || exit_quiet
owner="$(dirname "$common")"
[ -d "$owner" ] || exit_quiet

# Only repos that opt into priming at all. A repo with no setup script has no
# expectation this hook can check.
[ -x "$owner/bin/setup-worktree.sh" ] || exit_quiet

# Top-level packages, ignoring npm's own dot-directories (`.package-lock.json`,
# `.vite-temp`, `.bin`) — those are exactly what an empty-but-not-absent
# `node_modules` is made of, and counting them is how this reads as populated.
count_packages() {
  local dir="$1"
  [ -d "$dir" ] || { echo 0; return; }
  find "$dir" -maxdepth 1 -mindepth 1 ! -name '.*' 2>/dev/null | wc -l
}

owner_n="$(count_packages "$owner/node_modules")"
here_n="$(count_packages "$here/node_modules")"

# The owner having no install either means this is not a node repo, or the whole
# checkout is uninstalled — a different problem, and not one this can diagnose.
[ "$owner_n" -gt 0 ] || exit_quiet
[ "$here_n" -eq 0 ] || exit_quiet

command -v python3 >/dev/null 2>&1 || exit_quiet

MSG="⚠ This worktree has no node_modules, but the main checkout does ($owner_n packages).

  worktree: $here
  main:     $owner

Node and npx will resolve UPWARD past this worktree and bind to the main
checkout's install, so commands run — against another checkout's dependencies.
A typecheck, lint or test result from here is not about this tree until the
install exists. Run: $owner/bin/setup-worktree.sh $here"

WORKTREE_INSTALL_MSG="$MSG" python3 -c '
import json, os
print(json.dumps({
    "hookSpecificOutput": {
        "hookEventName": "SessionStart",
        "additionalContext": os.environ.get("WORKTREE_INSTALL_MSG", ""),
    }
}))'

exit 0
