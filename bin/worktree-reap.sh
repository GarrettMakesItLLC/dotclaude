#!/usr/bin/env bash
# The ONLY sanctioned way to remove a `.worktrees/*` checkout on this box.
# Lives in dotclaude (`~/.claude/bin/worktree-reap.sh`) and works in any repo that
# keeps its worktrees under `.worktrees/`.
#
# 20+ agent sessions run concurrently here, each in its own worktree. A generic
# "delete the worktrees whose branches are gone" sweep — `clean_gone`, a hand-run
# `git worktree remove --force`, a `git worktree prune` next to an `rm -rf` —
# cannot tell an abandoned tree from one a session is actively building in, and
# deleting the live one destroys its uncommitted work. Worse, the victim never
# learns why: the running tool just dies with
# `ENOENT: process.cwd failed ... uv_cwd` from whatever happened to be executing
#.
#
# So removal asks six questions first, and keeps the worktree if ANY of them
# says it is live:
#
#   1. Locked BY HAND — `git worktree lock` carrying a reason this sweep did not
#                    write. The lock dotclaude's `bin/setup-worktree.sh` applies at creation
#                    is deliberately NOT consulted here: it is the load-bearing
#                    guard against a THIRD-PARTY remover (`git worktree remove
#                    --force` refuses a locked tree; it takes --force twice),
#                    and it is on every agent tree from the moment it exists, so
#                    it says "an agent made this" and never "a session is using
#                    this". Honouring it made this sweep a no-op on exactly the
#                    trees it exists to reclaim. The checks below protect
#                    this script's own callers; the lock protects everyone else's.
#   2. Dirty       — `git status --porcelain` non-empty: uncommitted work that
#                    exists nowhere else.
#   3. Unpushed    — commits not reachable from any remote ref: same, one layer up.
#                    Waived when the trunk already CONTAINS this branch's own
#                    contribution: the repo squash-merges and GitHub deletes the
#                    head branch, so a merged worktree's originals are reachable
#                    from nowhere while everything they said is already on the trunk.
#                    Answered by reverse-applying the branch's patch to the trunk, so
#                    a later merge touching the same files does not re-strand it.
#                    Also waived when the branch's PR merged, or when HEAD is an
#                    ancestor of a merged or closed PR's `refs/pull/<N>/head`
#                    (a batch folded into an integration wave has no PR of its own).
#   4. In use      — some process's cwd is inside the tree, so a build is running
#                    in it right now.
#   5. Recently active — something touched the tree inside
#                    `WORKTREE_REAP_MIN_IDLE_SECS` (default 3600). An agent BETWEEN
#                    commands has no process with a cwd inside its worktree, and
#                    a tree it has just committed and pushed is clean and
#                    reachable — so checks 2-4 cannot tell a live session from an
#                    abandoned one, and one was reaped mid-session on exactly
#                    that reading.
#   6. Starting up — the branch has no commits of its own AND the worktree is
#                    younger than `WORKTREE_REAP_MIN_AGE_SECS` (default 900). A claim
#                    lock branch is created AT the trunk's head, so until the first
#                    commit it is trivially an ancestor of the trunk and every "is it
#                    finished?" signal reads yes while meaning nothing has
#                    happened. Age is the only thing that separates that from a
#                    genuinely empty abandoned tree, since the ref graph cannot.
#                    In a sweep that deleted a live agent's worktree while it was
#                    still reading, before its first edit.
#
# Dry-run is the DEFAULT. A sweep that mutates by default is one typo away from
# being the bug this script exists to prevent, so `--apply` is explicit.
#
# Usage:
#   worktree-reap.sh                    # sweep: report what is reapable, change nothing
#   worktree-reap.sh --apply            # sweep: remove the reapable ones
#   worktree-reap.sh --apply <path>...  # remove these specific worktrees
#   worktree-reap.sh --apply --force <path>   # ...ignoring dirty/unpushed (never in a sweep)
#
# A SWEEP also reports and removes `.worktrees/<dir>` entries that are neither
# registered worktrees nor git checkouts (see `orphan_keep_reason` for what keeps one).
#
# A SWEEP additionally only considers a worktree whose branch is gone from the
# remote or already merged into the trunk — being idle is not evidence that work
# is finished. Naming a path explicitly skips that question (you are asserting it)
# but still runs the other liveness checks; `--force` waives 2 and 3 for a named
# path only, and never waives "in use".
set -euo pipefail

apply=0
force=0
paths=()
while (($#)); do
  case "$1" in
    --apply) apply=1 ;;
    --force) force=1 ;;
    --help | -h)
      sed -n '2,/^set -/p' "$0" | sed '$d' | sed 's/^# \?//'
      exit 0
      ;;
    -*)
      echo "[worktree-reap] unknown flag: $1" >&2
      exit 2
      ;;
    *) paths+=("$1") ;;
  esac
  shift
done

if ((force && ${#paths[@]} == 0)); then
  echo "[worktree-reap] --force applies only to explicitly named worktrees, never to a sweep." >&2
  exit 2
fi

common_dir="$(git rev-parse --path-format=absolute --git-common-dir)"
main_tree="$(cd "$(dirname "$common_dir")" && pwd)"
self_cwd="$PWD"

# Every git call runs from the main tree: this script routinely removes the
# directory it was invoked from, and a `git -C .` after that fails with the same
# uv_cwd error it exists to prevent.
g() { git -C "$main_tree" "$@"; }

# `git worktree list --porcelain` is read ONCE. It is the source of both the
# worktree set and the lock state, and re-running it per worktree turned an O(n)
# sweep into O(n²) git invocations.
# The branch "merged" is judged against: the trunk in a two-tier repo (feature -> dev
# -> main), else the remote's default branch. `WORKTREE_REAP_TRUNK` overrides.
detect_trunk() {
  local t
  if [[ -n "${WORKTREE_REAP_TRUNK:-}" ]]; then printf '%s\n' "$WORKTREE_REAP_TRUNK"; return; fi
  if g show-ref --verify --quiet refs/remotes/origin/dev || g show-ref --verify --quiet refs/heads/dev; then
    echo dev; return
  fi
  t="$(g symbolic-ref --quiet --short refs/remotes/origin/HEAD 2>/dev/null || true)"
  if [[ -n "$t" ]]; then printf '%s\n' "${t#origin/}"; return; fi
  echo main
}
TRUNK="$(detect_trunk)"
TRUNK_REF="refs/remotes/origin/$TRUNK"

# The lock reason this sweep placed itself, and the marker it recognises it by.
# shellcheck source=lib/agent-worktree-lock.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/agent-worktree-lock.sh"

# The trunk's tracking ref has been seen missing from a shared repo with no
# deleter found. Every verdict below reads it, and a missing ref makes
# `merge-base`/`diff` fail, which the callers read as "not merged, keep" or,
# worse, as "no evidence, proceed". So record it before the fetch below (whose
# default refspec recreates it) and name what else was running, so a recurrence
# identifies the deleter.
if ! g rev-parse --verify --quiet "$TRUNK_REF" >/dev/null; then
  {
    echo "$(date -u +%FT%TZ) $TRUNK_REF missing at sweep start (pid $$)"
    ps -eo pid,lstart,args 2>/dev/null | grep -E '[g]it |[w]orktree-reap|[g]c --auto' || true
  } >>"$(g rev-parse --git-common-dir)/origin-trunk-vanished.log" 2>/dev/null || true
  echo "[worktree-reap] NOTE: $TRUNK_REF was missing; the fetch below restores it (see the origin-trunk-vanished.log in the git dir)." >&2
fi

# Refresh the remote view before judging anything against it.
#
# Every verdict below rests on `refs/remotes/origin/*`: "gone from origin" is
# read as a MISSING tracking ref, and "already merged" is read against
# the trunk. Neither is a fact about the remote — they are facts about
# whatever the last fetch left behind, and on a box where a dozen sessions push
# and GitHub deletes head branches on merge, that view goes stale in minutes.
#
# Stale in the safe direction only costs a tree kept one sweep too long. Stale in
# the other direction is the failure this script exists to prevent: a branch alive on origin whose tracking ref
# was pruned locally reads as "gone", and its worktree gets removed. One fetch
# makes the whole sweep answer questions about the remote rather than about its
# own memory of it. Failure is non-fatal — a sweep on a box with no network
# should still reclaim what it can prove locally — but it is said out loud, so a
# verdict computed from a stale view is never silent.
if ! g fetch --quiet --prune origin 2>/dev/null; then
  echo "[worktree-reap] NOTE: could not fetch origin — every \"gone from origin\" and \"merged\" verdict below is computed from a possibly stale remote view." >&2
fi
if ! g rev-parse --verify --quiet "$TRUNK_REF" >/dev/null; then
  echo "[worktree-reap] NOTE: $TRUNK_REF is missing and could not be restored — \"merged\" verdicts below are unreliable." >&2
fi

worktree_list="$(g worktree list --porcelain)"

# A sweep considers the trees this repo's conventions create, and only those: a
# linked worktree somewhere else was made deliberately, by someone who knows
# where it is, and an automated sweep has no business guessing at its lifecycle.
# Naming such a path explicitly still works.
#
# TWO conventions, not one. `.worktrees/<name>` is this repo's; the
# global instructions prescribe `.claude/worktrees/<agent-id>/issue-N` for a
# harness-isolated agent, and nest a second worktree INSIDE the agent's own —
# so the shapes that actually exist on this box include
# `.worktrees/issue-6633/.claude/worktrees/issue-6633/issue-6753`. Matching one
# path segment under `.worktrees/` saw none of them, and because
# `setup-worktree.sh` locks every tree it makes, `git worktree prune` skipped
# them too: 2.5 GB of registrations with no automatic path out, each still
# pinning its branch as "checked out".
#
# `sort -r` is load-bearing, not tidiness: a nested worktree's path is its
# parent's plus a suffix, so reverse order puts the child first — and
# `git worktree remove` refuses a parent whose child directory is still there.
list_worktrees() {
  local escaped
  escaped="$(printf '%s' "$main_tree" | sed 's/[][\\.^$*+?(){}|\/]/\\&/g')"
  printf '%s\n' "$worktree_list" \
    | sed -n 's|^worktree ||p' \
    | grep -E "^$escaped/(\.worktrees|\.claude/worktrees)/.+" \
    | sort -r || true
}

# A target named explicitly must resolve to a REGISTERED worktree. Without this,
# a name that resolves to no worktree at all falls through to reap()'s "already
# gone from disk" branch, which reports success and removes nothing — a typo, or
# a bare name that missed `.worktrees/`, then looks exactly like a completed
# reap.
#
# Collected first and grepped as a here-string, never piped into `grep -q`:
# under pipefail, `grep -q` closing the pipe at its first match SIGPIPEs a
# writer that is still going, and the pipeline then reports "not registered"
# for a worktree that is.
is_registered() {
  local paths
  paths=$(printf '%s\n' "$worktree_list" | sed -n 's|^worktree ||p')
  grep -Fxq -- "$1" <<<"$paths"
}

# Resolve one explicitly named target to an absolute path. A bare name is a
# `.worktrees/<name>` checkout — this repo's convention, and the only shape the
# sweep considers — so that is tried before treating the name as relative to the
# main tree.
resolve_target() {
  local p="$1" candidate
  if [[ -d "$p" ]]; then (cd "$p" && pwd); return 0; fi
  if [[ "$p" == /* ]]; then printf '%s\n' "$p"; return 0; fi
  for candidate in "$main_tree/.worktrees/$p" "$main_tree/$p"; do
    if [[ -d "$candidate" ]]; then printf '%s\n' "$candidate"; return 0; fi
  done
  printf '%s\n' "$main_tree/.worktrees/$p"
}

# Whether this tree carries a lock this sweep did not place itself.
#
# `setup-worktree.sh` locks EVERY agent worktree at creation, with the reason in
# `bin/lib/agent-worktree-lock.sh`. That lock's job is to stop third-party
# removers — `git worktree remove`, `prune`, a hand-run `clean_gone` — which is
# the fault this script exists to prevent. It is not a statement that a session is using the tree
# right now, because it is applied before any work happens and never lifted.
#
# Honouring it here made this sweep a no-op on exactly the trees it exists to
# reclaim: 51 of 62 kept as "locked — a session holds it", under a lock whose own
# text says to remove the tree with this script. So the reaper looks past
# its own marker and answers the question properly, with the checks below —
# dirty, unpushed-and-unmerged, in use — every one of which fails closed.
#
# A lock with any other reason is a person saying hands off, and still wins.
has_foreign_lock() {
  # A locked tree's stanza carries a bare `locked` (or `locked <reason>`) line.
  # Read the stanza rather than probing the private `.git/worktrees/<id>/locked`
  # file, whose path is an implementation detail rather than API.
  printf '%s\n' "$worktree_list" | awk -v target="$1" -v marker="$AGENT_WORKTREE_LOCK_MARKER" '
    /^worktree /  { current = substr($0, 10) }
    /^locked/     { if (current == target && index($0, marker) == 0) { found = 1 } }
    END           { exit(found ? 0 : 1) }
  '
}

# Reading /proc is the only check here that sees a *running build* rather than
# its leftovers — a tree can be clean, pushed and unlocked while
# `npm run build` is halfway through it.
#
# Scanned once, up front, and time-bounded. `readlink /proc/<pid>/cwd` takes the
# target process's mmap lock, so on a box with 30 agents mid-build it blocks:
# measured at 49s for 469 processes, which per-worktree would have made the
# sweep unusable. A truncated scan is still useful and never unsafe on its own —
# the creation-time `git worktree lock` is the guard that must hold, and this is
# the backstop under it — so a partial result is reported rather than trusted
# silently.
#
# `WORKTREE_REAP_SKIP_PROC_SCAN=1` skips the scan outright rather than bounding it —
# for a caller that has already established nothing is live in any fixture tree
# (the liveness test suite spawns no long-running process inside one, so the
# scan there only ever answers "nothing found" at the cost of a `timeout`-bound
# wall-clock wait that a loaded box can stretch well past its own budget, since
# a SIGTERM is not delivered until a blocked `readlink` returns). `timeout 0`
# is NOT the same thing — coreutils reads a zero duration as "no timeout",
# which would make the scan unbounded instead of skipped.
proc_scan_complete=1
if [[ "${WORKTREE_REAP_SKIP_PROC_SCAN:-0}" == "1" ]]; then
  proc_cwds=""
else
  proc_cwds="$(
    timeout "${WORKTREE_REAP_PROC_SCAN_SECS:-30}" bash -c '
      for p in /proc/[0-9]*; do
        printf "%s\t%s\n" "${p#/proc/}" "$(readlink "$p/cwd" 2>/dev/null)"
      done
    ' 2>/dev/null
  )" || proc_scan_complete=0
fi

in_use_by() {
  local wt="$1"
  # A process sharing THIS script's cwd is the invocation itself — the shell that
  # ran it, the agent above that, the `git` it just forked. Excluding by cwd
  # rather than by pid catches all three without walking the process tree.
  printf '%s\n' "$proc_cwds" | awk -F'\t' -v wt="$wt" -v self="$self_cwd" '
    $2 == self { next }
    $2 == wt || index($2, wt "/") == 1 { print $1; found = 1; exit }
    END { exit(found ? 0 : 1) }
  '
}

# Commits that exist only here. `--remotes` covers the case a branch was pushed
# under a different name or its upstream was deleted out from under it — the
# question is "would removing this lose commits", not "is the upstream configured".
# Fails CLOSED: when git cannot answer it prints `unknown`, which callers treat as unpushed work.
unpushed_count() {
  git -C "$1" rev-list --count HEAD --not --remotes 2>/dev/null || echo unknown
}

# Whether this tree's own WORK is already in the trunk, regardless of ancestry.
#
# This repo squash-merges, and GitHub deletes the head branch on merge. Both
# together are what break the ancestry test above: the branch's original commits
# survive only in this worktree, reachable from no remote, while everything they
# said is already on the trunk inside one squashed commit. `unpushed_count` then
# reports work at risk on a tree that has none, and every squash-merged worktree
# is stranded — which on a box carrying dozens of them is the whole point of the
# sweep defeated.
#
# The comparison is scoped to the paths THIS branch touched, which is the part
# that makes it usable. A whole-tree `diff <trunk> HEAD` also answers "is my
# work merged", but only while the worktree is exactly level with the trunk — and on
# a box where a dozen agents merge into the trunk continuously, that window is
# seconds long. Every merged worktree then reads as unpushed again the moment
# somebody else's PR lands, which is the same stranding one step removed.
#
# So: take the paths the branch changed against its own merge base, and ask
# whether the trunk and `HEAD` agree on those. the trunk having moved on elsewhere is
# irrelevant — those changes are the trunk's, not this branch's, and are not at risk
# from removing this tree.
#
# It fails CLOSED. A path this branch touched that the trunk has since changed again
# reads as disagreement, so the tree is kept. Keeping a tree that could have
# been removed costs disk; removing one holding unmerged work costs the work.
work_merged_into_trunk() {
  local wt="$1" base rc
  base="$(git -C "$wt" merge-base "$TRUNK_REF" HEAD 2>/dev/null)" || return 1
  local -a paths
  mapfile -t paths < <(git -C "$wt" diff --name-only "$base" HEAD 2>/dev/null)
  # No paths means the branch changed nothing against its base — nothing to lose.
  if ((${#paths[@]} == 0)); then return 0; fi

  # Fast path: the trunk and `HEAD` agree on every path this branch touched. True of
  # a tree merged recently enough that nothing else has edited those files.
  if git -C "$wt" diff --quiet "$TRUNK_REF" HEAD -- "${paths[@]}" 2>/dev/null; then
    return 0
  fi

  # Slow path, and the one that reclaims most of them.
  #
  # The path compare fails the moment a LATER merge touches any of the same
  # files, which on a repo where a dozen agents share the trunk is the common case,
  # not the exception: after the imaging epic landed, three of four measured
  # trees were merged in fact and kept anyway, because a sibling PR had since
  # amended a shared spec. Reading that as "unmerged work" is what stranded 39
  # of 49 trees once the lock stopped masking them.
  #
  # The honest question is whether the trunk CONTAINS this branch's contribution,
  # and `git diff <merge-base> HEAD` is exactly that contribution. If it
  # reverse-applies to the trunk, the trunk has it. `git merge-tree --write-tree` states
  # this more directly and needs git >= 2.38; this box runs 2.34, so the patch
  # test is what is available.
  #
  # `--cached` against a scratch `GIT_INDEX_FILE` seeded with the trunk's tree is
  # what makes it apply to a commit rather than to this worktree: nothing on
  # disk is touched, and `--check` means nothing is written at all. `--binary`
  # so a branch that changed an image is answered rather than erroring.
  #
  # It fails CLOSED, and in three ways worth naming. A branch only PARTIALLY
  # merged fails, because a reverse-apply is all-or-nothing. Anything the patch
  # machinery cannot answer — a missing index file, a malformed diff — is a
  # non-zero exit, so the tree is kept. And git's default three lines of context
  # are kept deliberately: `-C1` or `--unidiff-zero` would reclaim a few more
  # trees whose hunks sit right beside a later edit, at the price of letting a
  # patch match somewhere it does not belong. A tree kept one sweep too long
  # costs disk; a tree removed on a wrong match costs the work. So a
  # later edit IMMEDIATELY adjacent to this branch's own hunk still reads as
  # unmerged, and that tree waits for the next sweep after the trunk settles.
  local scratch_index
  scratch_index="$(mktemp)" || return 1
  if ! GIT_INDEX_FILE="$scratch_index" git -C "$wt" read-tree "$TRUNK_REF" 2>/dev/null; then
    rm -f "$scratch_index"
    return 1
  fi
  git -C "$wt" diff --binary "$base" HEAD 2>/dev/null \
    | GIT_INDEX_FILE="$scratch_index" git -C "$wt" apply --cached --reverse --check - 2>/dev/null
  rc=$?
  rm -f "$scratch_index"
  return "$rc"
}

# The authoritative answer the local patch test cannot give: did this branch's
# PR merge?
#
# `work_merged_into_trunk` fails closed on an adjacent edit — deliberately, and it
# is right to — but on a repo a dozen agents share, the trunk moves under a branch
# within minutes of its merge. The result is that a FINISHED tree is kept for
# the same reason an abandoned one is, and the population only grows: measured
# here at 43 kept, with `pr-5378` reported as "unpushed — 8 commit(s) reachable
# from no remote" while its PR was merged and its content demonstrably on
# the trunk.
#
# GitHub knows. A squash merge is still a merge, and `state: MERGED` is a fact
# about the PR rather than an inference from the commit graph, so it answers
# exactly the question the reachability test is a proxy for.
#
# **It fails closed on every uncertainty**, which is what makes it safe to add
# to a remover: no `gh`, not authenticated, no network, a request that times
# out, no PR for this branch, or a PR in any state other than `MERGED` all
# return non-zero, and the tree is kept on whatever the local checks decided.
# The timeout is short because a sweep asks this once per tree the local test
# already declined, and a hung API must not hang the sweep.
#
# Only ever consulted as an ADDITIONAL waiver, never as a reason to remove on
# its own: a dirty tree, a hand lock, a live cwd and the starting-up floor are
# all checked before this is reached.
pr_is_merged() {
  local wt="$1" branch state
  command -v gh >/dev/null 2>&1 || return 1
  branch="$(git -C "$wt" symbolic-ref --quiet --short HEAD 2>/dev/null || true)"
  [[ -n "$branch" ]] || return 1

  # `timeout` guards a hung API; where coreutils has none, run it bare rather
  # than refusing to ask.
  local -a runner=()
  command -v timeout >/dev/null 2>&1 && runner=(timeout "${WORKTREE_REAP_GH_TIMEOUT:-15}")

  state="$("${runner[@]}" gh pr list --head "$branch" --state merged --limit 1 \
    --json state --jq '.[0].state // empty' 2>/dev/null)" || return 1

  [[ "$state" == "MERGED" ]]
}

# The waiver `pr_is_merged` cannot give when the branch never had a PR of its
# own: is HEAD inside the head of a finished PR under ANY branch name?
#
# In a degraded-mode wave a batch branch is merged into an integration branch,
# and the integration PR is what lands. `gh pr list --head <batch-branch>` finds
# nothing, and once a later wave edits the same files the reverse-apply fails
# too, so every folded batch tree read as "unpushed" on every sweep: 11 of them
# at once, each HEAD an ancestor of a merged wave PR's head.
#
# `refs/pull/<N>/head` is permanent on GitHub whether the PR merged or was
# closed, so a HEAD reachable from it is reachable from a remote ref, which is
# exactly the guarantee check 3 exists to ask for. GitHub's search finds the PR
# by commit SHA; the ref is then fetched and the ancestry verified locally, so
# the search result is a candidate and never the verdict.
#
# Fails closed like `pr_is_merged`: no `gh`, a failed or timed-out search, a
# non-numeric answer, a failed fetch, or an ancestry miss all keep the tree. The
# fetched ref lives under a private namespace and is deleted after the check.
head_in_finished_pr() {
  local wt="$1" sha n tmp_ref ok=1
  command -v gh >/dev/null 2>&1 || return 1
  sha="$(git -C "$wt" rev-parse --verify --quiet HEAD 2>/dev/null)" || return 1

  local -a runner=()
  command -v timeout >/dev/null 2>&1 && runner=(timeout "${WORKTREE_REAP_GH_TIMEOUT:-15}")

  local -a prs
  mapfile -t prs < <("${runner[@]}" gh pr list --state all --search "$sha" --limit 5 \
    --json number,state --jq '.[] | select(.state == "MERGED" or .state == "CLOSED") | .number' \
    2>/dev/null) || return 1

  for n in "${prs[@]}"; do
    [[ "$n" =~ ^[0-9]+$ ]] || continue
    tmp_ref="refs/worktree-reap/pull-$n-$$"
    if "${runner[@]}" git -C "$wt" fetch --quiet --no-write-fetch-head origin \
      "+refs/pull/$n/head:$tmp_ref" 2>/dev/null \
      && git -C "$wt" merge-base --is-ancestor "$sha" "$tmp_ref" 2>/dev/null; then
      ok=0
    fi
    git -C "$wt" update-ref -d "$tmp_ref" 2>/dev/null || true
    if ((ok == 0)); then return 0; fi
  done
  return 1
}

# A sweep's extra question: is this branch actually finished? Gone from the
# remote (the clean_gone criterion) or already merged into the trunk.
branch_is_done() {
  local wt="$1" branch
  branch="$(git -C "$wt" symbolic-ref --quiet --short HEAD 2>/dev/null || true)"
  # A detached HEAD names no branch, so "is this branch finished?" has no answer
  # — treat that as not-finished rather than guessing.
  if [[ -z "$branch" ]]; then return 1; fi
  if ! g show-ref --verify --quiet "refs/remotes/origin/$branch"; then
    return 0
  fi
  g merge-base --is-ancestor "refs/remotes/origin/$branch" "$TRUNK_REF" 2>/dev/null
}

# How long a tree that has contributed nothing is presumed to be starting up
# rather than abandoned. Overridable so a caller can sweep immediately, which is
# what the liveness suite does.
MIN_AGE_SECS="${WORKTREE_REAP_MIN_AGE_SECS:-900}"

# Has this branch contributed anything at all yet?
#
# `branch_is_done`'s ancestor arm is true for any branch level with the trunk, and a
# claim lock branch is CREATED at the trunk's head — so between `git worktree add`
# and the first commit it is trivially an ancestor, and "already merged" is true
# while meaning only that nothing has happened yet. `work_merged_into_trunk`
# answers the same way for the same reason: an empty patch reverse-applies to
# anything.
#
# Fails CLOSED: any error reading the count is treated as no contribution, which
# combined with the age floor below keeps the tree.
branch_contributed_nothing() {
  local wt="$1" base
  base="$(git -C "$wt" merge-base "$TRUNK_REF" HEAD 2>/dev/null)" || return 0
  [[ "$(git -C "$wt" rev-list --count "$base"..HEAD 2>/dev/null || echo 0)" == 0 ]]
}

# Seconds since this worktree was registered, from its admin directory's mtime.
#
# Age is what separates the two states "contributed nothing" collapses together:
# a tree created a minute ago is an agent that has not written its first file, a
# tree in that shape for an hour is abandoned. Nothing in the ref graph can tell
# them apart — a branch merged by a fast-forward is also an ancestor of the trunk
# with nothing of its own — so the discriminator has to come from outside it.
#
# Fails CLOSED: an unreadable mtime reports 0, which reads as brand new and keeps
# the tree.
worktree_age_secs() {
  local wt="$1" admin mtime
  admin="$(git -C "$wt" rev-parse --absolute-git-dir 2>/dev/null)" || { echo 0; return 0; }
  mtime="$(stat -c %Y "$admin" 2>/dev/null)" || { echo 0; return 0; }
  echo $(($(date +%s) - mtime))
}

# Seconds since anything happened in this worktree.
#
# The gap the five existing checks leave: an agent BETWEEN COMMANDS has no
# process with its cwd in the tree, and a tree it has just committed and pushed
# is clean and reachable — so a live, actively-owned worktree is byte-for-byte
# indistinguishable from an abandoned one. One was reaped mid-session on exactly
# that reading. Nothing was lost, because every safety predicate was working;
# what it cost was the agent's next command, which ran `cd <worktree> && <test>`
# in the MAIN CHECKOUT after the `cd` failed, passed on the trunk where the defect
# was never present, and read as "cannot reproduce".
#
# Age already separates "starting up" from "abandoned" for a tree that has
# contributed nothing. This is the same discriminator for a tree that has: a
# session that committed four minutes ago is working, whatever the ref graph
# says about it. The signals are the files git itself touches — the per-worktree
# `logs/HEAD` on any ref update, the `index` on any `git add`/`status` refresh,
# and the admin directory itself — so nothing has to remember to write a
# heartbeat, which is the part a touch-file scheme gets wrong.
#
# Fails CLOSED: an unreadable admin dir reports 0, which reads as "just now" and
# keeps the tree.
worktree_idle_secs() {
  local wt="$1" admin newest=0 f mtime
  admin="$(git -C "$wt" rev-parse --absolute-git-dir 2>/dev/null)" || { echo 0; return 0; }
  for f in "$admin" "$admin/logs/HEAD" "$admin/index"; do
    [[ -e "$f" ]] || continue
    mtime="$(stat -c %Y "$f" 2>/dev/null)" || continue
    # `if`, not `((…)) && …`: under `set -e` a false `&&` list is the command's
    # own non-zero status, and this is the loop body's last command — so the
    # first file that is NOT newer than the running maximum would abort the
    # whole script. The same trap `reap()` below already documents.
    if ((mtime > newest)); then newest="$mtime"; fi
  done
  if ((newest == 0)); then echo 0; return 0; fi
  echo $(($(date +%s) - newest))
}

# How long a worktree must have been quiet before a sweep may consider it
# finished. Overridable so the liveness suite can sweep immediately.
MIN_IDLE_SECS="${WORKTREE_REAP_MIN_IDLE_SECS:-3600}"

# Print the reason this worktree is live, or nothing if it is safe to remove.
# `$2` non-empty means the caller named this path explicitly.
keep_reason() {
  local wt="$1" explicit="$2" pid n idle
  if [[ ! -d "$wt" ]]; then
    # Registered but gone from disk: nothing to protect, prune will clear it.
    return 1
  fi
  # FIRST, before any git command below — `git status` and `git diff` refresh
  # the index and rewrite its file, so a sweep that read the mtime afterwards
  # would be reading its own footprint and calling every tree active from the
  # second sweep on. `--no-optional-locks` on the status call below is the
  # second half of that; both, because either alone is one refactor from
  # silently inverting this check.
  if ((explicit == 0)); then
    idle="$(worktree_idle_secs "$wt")"
    if ((idle < MIN_IDLE_SECS)); then
      printf 'active %ss ago — a session is working in it' "$idle"
      return 0
    fi
  fi
  if pid="$(in_use_by "$wt")"; then
    printf 'in use — pid %s has its cwd inside it' "$pid"
    return 0
  fi
  if ((explicit == 0)) && has_foreign_lock "$wt"; then
    # A lock this sweep did not place outranks every heuristic below: somebody
    # locked this tree by hand and meant it. Naming the path explicitly is that
    # person speaking. The reaper's OWN lock is not consulted here — see
    # `has_foreign_lock`.
    printf 'locked by hand — a lock this sweep did not place'
    return 0
  fi
  if ((force && explicit)); then
    return 1
  fi
  if [[ -n "$(git -C "$wt" --no-optional-locks status --porcelain 2>/dev/null)" ]]; then
    printf 'dirty — uncommitted changes'
    return 0
  fi
  n="$(unpushed_count "$wt")"
  if [[ "$n" != 0 ]] && ! work_merged_into_trunk "$wt" && ! pr_is_merged "$wt" \
    && ! head_in_finished_pr "$wt"; then
    printf 'unpushed — %s commit(s) reachable from no remote' "$n"
    return 0
  fi
  local age
  if ((explicit == 0)) && branch_contributed_nothing "$wt"; then
    age="$(worktree_age_secs "$wt")"
    if ((age < MIN_AGE_SECS)); then
      printf 'no commits yet and only %ss old — starting up, not finished' "$age"
      return 0
    fi
  fi
  if ((explicit == 0)) && ! branch_is_done "$wt"; then
    printf 'branch still open on origin and not merged into %s' "$TRUNK"
    return 0
  fi
  return 1
}

reap() {
  local wt="$1"
  local -a flags=()
  if [[ ! -d "$wt" ]]; then
    # "prune will clear its registration" was not true for an agent worktree
    #. `git worktree prune` skips a LOCKED stanza, and
    # dotclaude's `bin/setup-worktree.sh` locks every tree it creates — so four trees whose
    # directories went with their reaped parent stayed registered indefinitely,
    # each still pinning its branch as checked out. Lifting this sweep's OWN
    # lock is what lets prune finish the job; a lock somebody else placed is
    # still a person saying hands off, even over an empty path.
    if has_foreign_lock "$wt"; then
      echo "[worktree-reap] $wt is gone from disk but carries a lock this sweep did not place — leaving its registration." >&2
      return 1
    fi
    g worktree unlock "$wt" >/dev/null 2>&1 || true
    echo "[worktree-reap] $wt was already gone from disk — unlocked so prune can clear its registration."
    return 0
  fi
  # git refuses to remove a tree with untracked or modified files. Reaching for
  # --force is only ever correct where keep_reason already waived that check —
  # i.e. an explicitly named path under --force. A sweep must never carry it.
  # `if`, not `((…)) && …`: under `set -e` a false `&&` list is the command's own
  # non-zero status and kills the script — the same trap ~/.claude/bin/setup-worktree.sh
  # documents.
  if ((force && explicit)); then flags+=(--force); fi
  g worktree unlock "$wt" >/dev/null 2>&1 || true
  g worktree remove "${flags[@]}" "$wt" 2>&1 || {
    echo "[worktree-reap] git refused to remove $wt — left in place." >&2
    return 1
  }
  echo "[worktree-reap] removed $wt"
}

# `.worktrees/<dir>` entries that are neither registered worktrees nor git
# checkouts: what is left when a tree is removed by `rm -rf` after its
# registration was pruned, or a scratch directory made by hand. `git worktree`
# cannot see them, so they pin disk (hundreds of MB each) forever.
#
# Only a top-level `.worktrees/<dir>` qualifies, and every check fails closed:
# a symlink, a `.git` entry anywhere near the top of the tree (a checkout nested
# in a scratch dir), a registered worktree beneath it, a process whose cwd is
# inside it, or any file touched within MIN_IDLE_SECS keeps it. `--force` does
# not waive any of them.
orphan_dirs() {
  local d
  [[ -d "$main_tree/.worktrees" ]] || return 0
  for d in "$main_tree"/.worktrees/*/; do
    d="${d%/}"
    [[ -d "$d" ]] || continue
    is_registered "$d" && continue
    printf '%s\n' "$d"
  done
}

# Whether `$1` is a top-level `.worktrees/<dir>` that no registered worktree
# claims. Explicit targets pass through it before being treated as orphans.
is_orphan_dir() {
  local d="$1"
  [[ "$(dirname "$d")" == "$main_tree/.worktrees" && -d "$d" && ! -L "$d" ]] || return 1
  ! is_registered "$d"
}

orphan_keep_reason() {
  local d="$1" pid mins registered_below
  if [[ -L "$d" ]]; then printf 'a symlink'; return 0; fi
  if [[ -n "$(find "$d" -maxdepth 3 -name .git -print -quit 2>/dev/null)" ]]; then
    printf 'holds a .git entry — a checkout lives inside it'
    return 0
  fi
  registered_below="$(printf '%s\n' "$worktree_list" | sed -n 's|^worktree ||p' | grep -F -- "$d/" | head -1 || true)"
  if [[ -n "$registered_below" ]]; then
    printf 'registered worktree %s lives inside it' "$registered_below"
    return 0
  fi
  if [[ "$self_cwd" == "$d" || "$self_cwd" == "$d"/* ]]; then
    printf 'this command is running inside it'
    return 0
  fi
  if pid="$(in_use_by "$d")"; then
    printf 'in use — pid %s has its cwd inside it' "$pid"
    return 0
  fi
  mins=$(((MIN_IDLE_SECS + 59) / 60))
  if ((mins > 0)) && [[ -n "$(find "$d" -mmin "-$mins" -print -quit 2>/dev/null)" ]]; then
    printf 'active within %ss — something is writing to it' "$MIN_IDLE_SECS"
    return 0
  fi
  return 1
}

reap_orphan() {
  local d="$1"
  # The path is rebuilt, not trusted: never `rm -rf` anything but a direct child
  # of this repo's `.worktrees/`.
  if [[ "$(dirname "$d")" != "$main_tree/.worktrees" || "$d" == *..* ]]; then
    echo "[worktree-reap] refusing to remove $d — not a direct child of .worktrees/." >&2
    return 1
  fi
  rm -rf -- "$d" || { echo "[worktree-reap] could not remove $d — left in place." >&2; return 1; }
  echo "[worktree-reap] removed $d (not a git checkout)"
}

# Settle one orphan directory: KEEP, REAP (dry run) or remove.
settle_orphan() {
  local d="$1" reason
  if reason="$(orphan_keep_reason "$d")"; then
    echo "[worktree-reap] KEEP  $d — $reason"
    kept=$((kept + 1))
    return 0
  fi
  if ((apply)); then
    reap_orphan "$d" && reaped=$((reaped + 1))
  else
    echo "[worktree-reap] REAP  $d — not a git checkout"
    would+=("$d")
  fi
}

targets=()
if ((${#paths[@]})); then
  for p in "${paths[@]}"; do
    targets+=("$(resolve_target "$p")")
  done
  explicit=1
else
  while IFS= read -r wt; do targets+=("$wt"); done < <(list_worktrees)
  explicit=0
fi

if ((proc_scan_complete == 0)); then
  echo "[worktree-reap] NOTE: the /proc cwd scan hit its ${WORKTREE_REAP_PROC_SCAN_SECS:-30}s budget and is partial, so \"in use\" may be under-reported. The lock guard is unaffected. Raise WORKTREE_REAP_PROC_SCAN_SECS to widen it." >&2
fi

kept=0
reaped=0
would=()
unknown=0
for wt in "${targets[@]}"; do
  if ((explicit)) && ! is_registered "$wt" && is_orphan_dir "$wt"; then
    settle_orphan "$wt"
    continue
  fi
  if ((explicit)) && ! is_registered "$wt"; then
    echo "[worktree-reap] $wt is not a registered worktree — refusing. Name one from \`git worktree list\`." >&2
    unknown=$((unknown + 1))
    continue
  fi
  if reason="$(keep_reason "$wt" "$explicit")"; then
    echo "[worktree-reap] KEEP  $wt — $reason"
    kept=$((kept + 1))
    continue
  fi
  if ((apply)); then
    reap "$wt" && reaped=$((reaped + 1))
  else
    echo "[worktree-reap] REAP  $wt"
    would+=("$wt")
  fi
done

if ((explicit == 0)); then
  while IFS= read -r d; do settle_orphan "$d"; done < <(orphan_dirs)
fi

if ((apply)); then
  # Only ever prunes stanzas whose directory is already gone; a locked worktree
  # is never prunable, which is the second thing the creation-time lock buys.
  g worktree prune
  echo "[worktree-reap] $reaped removed, $kept kept."
else
  echo "[worktree-reap] dry run — ${#would[@]} reapable, $kept kept. Re-run with --apply to remove."
fi

# A named target that matched no worktree is a failed request, not a clean run:
# exiting 0 there is what let a silent no-op read as a completed reap.
if ((unknown)); then exit 2; fi
