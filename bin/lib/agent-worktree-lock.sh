#!/usr/bin/env bash
# The lock dotclaude's `bin/setup-worktree.sh` puts on every agent worktree, and the marker
# `bin/worktree-reap.sh` recognises it by.
#
# The shared script reads the reason from `.claude/repo.json`'s
# `worktree.lockWorktree`, which must equal AGENT_WORKTREE_LOCK_REASON below
# (`bin/worktree-reap.test.sh` holds that value against docs/repo-manifest.md).
# The marker is a substring of the reason, so a lock placed with a longer, older
# reason still matches. The two do NOT agree on what the lock means, and that
# asymmetry is the whole point:
#
#   - To every OTHER remover on this box the lock is a hard stop, which is what
#     it exists for: `git worktree remove` refuses a locked tree unless
#     --force is passed twice, and `git worktree prune` skips it outright.
#   - To `bin/worktree-reap.sh` it is not evidence of anything. Every agent tree
#     carries it from the moment `setup-worktree.sh` runs, so it says "an agent
#     made this", never "a session is using this right now". Treating it as
#     ownership left 51 of 62 trees stranded under "locked — a session holds it"
#     while the sweep reclaimed three — and the lock's own text told the
#     reader to remove the tree with the tool that was declining to.
#
# A lock carrying any OTHER reason is a person saying hands off, and still
# outranks every check the reaper makes.
# shellcheck disable=SC2034 # the reason .claude/repo.json must carry; the test reads it here
readonly AGENT_WORKTREE_LOCK_REASON='agent session worktree — remove via bin/worktree-reap.sh'

# What to MATCH on, which is not the same string.
#
# `git worktree list --porcelain` renders a lock reason quoted and C-escaped, so
# the em dash above comes back as `\342\200\224` and a literal comparison against
# the reason never fires. This marker is the reason's ASCII tail: unique to it,
# and identical either side of the escaping.
# shellcheck disable=SC2034 # used by scripts that source this file (bin/worktree-reap.sh)
readonly AGENT_WORKTREE_LOCK_MARKER='remove via bin/worktree-reap.sh'
