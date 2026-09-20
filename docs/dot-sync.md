# dot-sync: bringing a machine up to date

Two repos are shared across machines by hand: `dotclaude` (this repo) and
`dotfiles`. There is exactly one sync path for both, in two parts that share
one engine:

- **`hooks/dotrepo-sync.sh`** — a SessionStart hook. Runs on every Claude Code
  session start, silently. Fast-forwards both repos when cleanly behind their
  remote, rebuilds the vendored `github-rest` MCP's gitignored `dist/` if the
  pull touched its sources, and says nothing when there's nothing to say. It
  never applies a fix to a dirty tree or diverged history — only reports.

- **`bin/dot-sync.sh`** — the explicit command (`/dotclaude-sync`, or the
  `dsync` shell alias in `dotfiles/shell/git.sh`). Sources the hook to reuse
  its exact pull/rebuild logic (`DOTREPO_SYNC_SOURCED=1`), then does the
  slower or more consequential things a session start must not pay for on
  every launch: `bootstrap.sh --check` for dotclaude, dotfiles' own
  `install.sh`, a github MCP dist staleness check with an explicit
  `--build-mcp` to fix it, an optional `--kb` Obsidian vault refresh, a
  read-only report of the agent gateway / Claude account ledger state (owned
  by other tooling — never created or edited here), and a report of anything
  the machine still needs (a missing `gh` auth, an absent credential file the
  roster in `integrations.md` expects, and so on).

## The rest of the fleet

The two dot repos are pulled on every session start. The repos everything
*builds against* are not, and that is where drift actually hides: one machine's
`platform` checkout sat 52 commits behind its default branch for three weeks
with nothing broken enough to notice.

`bin/repo-sweep.sh` fast-forwards them, and `dot-sync.sh` runs it as step 4.
Pulling the fleet had been attempted before and was dropped after intermittent
errors, so **the failure handling is the deliverable, not the pull**. Every repo
either moves, is already current, or is skipped with one line naming the reason,
and the run never aborts on any of them — a sweep that stops at the first
awkward checkout tells you nothing about the other nine. The
skipped-with-reason rows are the product.

What it refuses to do:

- **`--ff-only`, always.** Never a merge, rebase, force, branch switch or stash.
  `refs/stash` is shared by every worktree of a repo, so a sweep that stashed
  would pop a sibling agent's work.
- **Never a checkout with active linked worktrees.** Sibling agents resolve
  `node_modules` upward from the main checkout, so moving it under them
  invalidates installs in trees that are mid-flight. On this box that is most
  repos, most days — which is why those rows are the normal output, not an
  error.
- **Never assume `main`.** Each repo's default branch is read from its own
  remote; `platform`'s is `dev`, and that one assumption is enough to make a
  sweep wrong everywhere.
- **No retry loop.** An intermittent network or auth failure is a skip with a
  reason. Retrying is what turned the previous attempt at this into something
  that hung instead of reporting.

Dependency installs are behind `--deps`, off by default, and only run where a
repo actually moved. With no GitHub Packages token in the environment the
install is skipped rather than run — an empty token does not 401, it exits 0
having silently omitted every `@gmi/*` package.

The repo list is dotfiles' `bootstrap/repos.tsv`, with discovery under
`$WORKSPACE` as the fallback for a machine whose dotfiles checkout predates a
repo. One implementation, two entry points: `dot-sync.sh` calls it, and
dotfiles' `bootstrap/device.sh` calls it instead of its own inline pull.

```bash
bin/repo-sweep.sh --dry-run     # decide and report, change nothing
bin/repo-sweep.sh --only ci     # one repo
dsync --deps                    # sweep and install where something moved
dsync --no-repos                # dot repos only
```

One engine, not two copies of the fast-forward-or-report logic: `dot-sync.sh`
sources `hooks/dotrepo-sync.sh` rather than reimplementing `sync_repo`.
`DOTSYNC_VERBOSE=1` (set by `dot-sync.sh`, unset for the hook) makes that
shared function report the quiet cases too — "up to date", "no upstream",
"fetch failed" — instead of staying silent, since a hook should never say
"all good" on every session start but an explicit sync command someone just
ran should.

## Why not fold this into `dplc`

`dplc` (`dotfiles/shell/git.sh`) is `dev && claude` — it's what gets typed at
the start of nearly every session, in every repo, so it's the obvious hook.
It stays untouched on purpose: it currently means "switch *this* repo to
`dev` and pull it", and overloading it to also sync two unrelated global
repos, check MCP build staleness, and report on credentials would surprise
anyone reading it, and would add real latency (a `bootstrap.sh --check` pass,
an `install.sh` run, network round-trips) to a command whose whole point is
speed at the start of a session. The SessionStart hook already covers "keep
current automatically" for the part that's cheap enough to run unconditionally
(two `git fetch`s and a conditional rebuild); `dsync` is the separate, deliberately
manual command for the heavier and more consequential checks. One command,
typed when it's wanted, not layered onto one that's typed by reflex.

## Verifying

```
bash hooks/dotrepo-sync.test.sh   # the shared pull/rebuild engine
bash bin/dot-sync.test.sh         # the full command built on it
bash bootstrap.sh --check         # confirms the MCP-dist check stays green
```

See `docs/superpowers/specs/2026-08-04-dotrepo-sync-design.md` for the
original hook design and `docs/superpowers/plans/2026-08-04-dotrepo-sync.md`
for its implementation plan — both predate `bin/dot-sync.sh` and the MCP
rebuild step, which extended rather than replaced them.
