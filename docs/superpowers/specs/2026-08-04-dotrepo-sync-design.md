# dotrepo-sync: keep dotfiles/dotclaude current without being asked

Tracks: [GarrettMakesItLLC/dotfiles#5](https://github.com/GarrettMakesItLLC/dotfiles/issues/5)

## Problem

Garrett runs agents on two machines against the same `dotfiles` and `dotclaude` repos.
Both are pulled by hand today — `dotclaude` via the manual `/dotclaude-sync` slash
command, `dotfiles` not at all. He regularly edits one on machine A and forgets to
pull on machine B before starting work there, so that machine silently runs stale
shell config, hooks, or skills.

`link-doctor.sh` (existing SessionStart hook) already catches one specific symptom —
`~/.claude` symlinks pointing at nothing, or a committed skill that was never linked
— but it never checks whether the repo itself is behind its remote, and it doesn't
touch `dotfiles` at all.

## Goal

A SessionStart hook that keeps both repos current automatically when it's safe to do
so, and says something the one time it isn't — with zero AI/agent involvement and no
noticeable session-start latency.

## Non-goals

- Branching behavior on cwd (pull the whole repo fleet from `$HOME` vs. just the
  current repo elsewhere) — explicitly deferred; not needed to solve the staleness
  problem.
- Handling repos other than `dotfiles` and `dotclaude` — per the issue, these are the
  only two repos synced across machines this way today.
- Auto-resolving divergent history or dirty working trees — those need a human.

## Design

New hook: `hooks/dotrepo-sync.sh`, registered in `settings.json` under `SessionStart`
(`matcher: "startup|resume"`), running before `link-doctor.sh` so a freshly-pulled
`dotclaude` is what the symlink check verifies.

For each of `~/dotclaude` and `~/workspace/dotfiles` (skip a repo if its directory
doesn't exist — e.g. a machine that hasn't bootstrapped `dotfiles` yet):

1. `git fetch` the remote (`--quiet`).
2. Compare local `HEAD` against `@{upstream}`:
   - **Up to date** — nothing to do, say nothing.
   - **Behind, clean fast-forward possible** (working tree clean, no local commits
     ahead of upstream) — `git pull --ff-only` silently. On success, emit a single
     terse note via `additionalContext`: `dotclaude: pulled 2 new commits`. Combine
     both repos into one message if both pulled.
   - **Can't fast-forward cleanly** (dirty working tree, or local commits diverged
     from upstream) — never touch it. Emit a note naming the repo and the reason
     (`dotfiles: 3 commits behind, local changes uncommitted — resolve by hand`),
     in the same terse, indented style `link-doctor.sh` already uses for drift.
3. Any git failure (no network, no upstream configured, detached HEAD) — fail open,
   say nothing. A sync check must never be the reason a session can't start, same
   rule `link-doctor.sh` already follows.

Runs unconditionally on every session start, regardless of cwd — two `git fetch`
calls is well under the cost budget for something off the per-turn path, so the
cwd-branching idea in the issue isn't needed to hit "cheap enough to run always."

### Interaction with `link-doctor.sh`

Order matters: `dotrepo-sync.sh` runs first and may change `~/dotclaude`'s contents
(new hooks, new skills, a changed `bootstrap.sh`). `link-doctor.sh` then runs
`bootstrap.sh --check` against the now-current tree, so a newly-added skill or hook
that also needs (re-)linking is caught in the same session start rather than one
session late.

### Testing

Follows this repo's existing hook convention: a sibling `dotrepo-sync.test.sh`
covering — up to date (silent), clean fast-forward (pulls, reports), dirty tree
behind (reports, doesn't touch), diverged history (reports, doesn't touch), missing
`~/workspace/dotfiles` directory (silent skip), no network / fetch failure (silent,
fail open).

## Open question for the plan

None — this is a small, self-contained hook with the same shape as `link-doctor.sh`
and `agent-creds-sync.sh` next to it.
